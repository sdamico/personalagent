import Foundation
import AVFoundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.personalagent.app", category: "WisprFlow")

/// Voice input manager using Wispr Flow API
@MainActor
final class VoiceInputManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isListening = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var partialText = ""
    @Published private(set) var error: String?

    // MARK: - Wispr Flow Configuration

    /// Wispr Flow API key - stored securely in Keychain
    var apiKey: String? {
        get { KeychainHelper.wisprFlowAPIKey }
        set { KeychainHelper.wisprFlowAPIKey = newValue }
    }

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var packetCount = 0
    private let packetDuration: Double = 0.1  // 100ms chunks

    init() {}

    // MARK: - Context Configuration

    struct VoiceContext {
        var appName: String = "Terminal"
        var appType: String = "other"  // email|ai|other
        var dictionary: [String] = []
        var recentText: String = ""
        var lowercaseFirst: Bool = false  // For terminal/code contexts

        static let terminal = VoiceContext(
            appName: "Terminal",
            appType: "other",
            dictionary: ["git", "cd", "ls", "grep", "awk", "sed", "curl", "ssh", "sudo", "npm", "yarn", "pip", "python", "node", "docker", "kubectl", "zsh", "bash", "nano", "cat", "echo", "mkdir", "rm", "cp", "mv"],
            lowercaseFirst: true
        )

        static let claudeCode = VoiceContext(
            appName: "Claude Code",
            appType: "ai",
            dictionary: ["refactor", "implement", "function", "class", "interface", "async", "await", "const", "let", "var", "import", "export", "typescript", "javascript", "python", "rust", "swift"],
            lowercaseFirst: false  // Claude Code expects natural language prompts
        )

        static let vim = VoiceContext(
            appName: "Vim",
            appType: "other",
            dictionary: ["escape", "insert", "visual", "yank", "paste", "delete", "undo", "redo", "write", "quit", "search", "replace", "buffer", "split", "tab"],
            lowercaseFirst: true
        )
    }

    private var currentContext = VoiceContext.terminal

    // MARK: - Public API

    func startListening(context: VoiceContext? = nil) {
        guard !isListening else {
            logger.info("Already listening, ignoring start request")
            return
        }
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            logger.error("Wispr Flow API key not configured")
            self.error = "Wispr Flow API key not configured - add it in Settings"
            return
        }

        if let context = context {
            currentContext = context
        }

        Task {
            do {
                try await startWisprFlow(apiKey: apiKey)
                isListening = true
                error = nil
            } catch {
                logger.error("Failed to start: \(error.localizedDescription)")
                self.error = error.localizedDescription
                isListening = false
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        sendCommitMessage()
        isListening = false
    }

    // MARK: - Wispr Flow Implementation

    private func startWisprFlow(apiKey: String) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Connect to Wispr Flow WebSocket (API key in query param, no Bearer prefix)
        let urlString = "wss://api.wisprflow.ai/api/v1/dash/ws?api_key=\(trimmedKey)"
        guard let url = URL(string: urlString) else {
            throw VoiceInputError.invalidURL
        }

        urlSession = URLSession(configuration: .default)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        // Wait for connection to establish
        try await Task.sleep(nanoseconds: 1_000_000_000)

        if webSocket?.state == .suspended || webSocket?.state == .canceling {
            throw VoiceInputError.connectionFailed
        }

        try await sendAuthMessage()
        Task { await receiveTranscriptions() }

        packetCount = 0
        try startAudioCapture()
    }

    private func sendAuthMessage() async throws {
        var authMessage: [String: Any] = [
            "type": "auth",
            "language": ["en"]
        ]

        // Build context for better transcription accuracy
        var context: [String: Any] = [
            "app": [
                "name": currentContext.appName,
                "type": currentContext.appType
            ]
        ]

        if !currentContext.dictionary.isEmpty {
            context["dictionary_context"] = currentContext.dictionary
        }

        if !currentContext.recentText.isEmpty {
            context["textbox_contents"] = [
                "before_text": currentContext.recentText,
                "selected_text": "",
                "after_text": ""
            ]
        }

        authMessage["context"] = context

        guard let data = try? JSONSerialization.data(withJSONObject: authMessage),
              let jsonString = String(data: data, encoding: .utf8) else {
            throw VoiceInputError.encodingFailed
        }

        try await webSocket?.send(.string(jsonString))
    }

    private func startAudioCapture() throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw VoiceInputError.audioEngineSetupFailed
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz, mono, 16-bit PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw VoiceInputError.audioFormatFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceInputError.converterSetupFailed
        }

        // Calculate buffer size for ~100ms chunks at 16kHz
        let samplesPerChunk = Int(16000 * packetDuration)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(samplesPerChunk), format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        // Convert to 16kHz mono PCM
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        guard error == nil,
              let channelData = convertedBuffer.int16ChannelData else { return }

        // Convert to Data with WAV header (required by Wispr Flow)
        let byteCount = Int(convertedBuffer.frameLength) * 2  // 16-bit = 2 bytes per sample
        let pcmData = Data(bytes: channelData[0], count: byteCount)
        let wavData = createWavData(from: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let base64Audio = wavData.base64EncodedString()

        // Calculate volume (RMS)
        var sum: Float = 0
        for i in 0..<Int(convertedBuffer.frameLength) {
            let sample = Float(channelData[0][i]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(convertedBuffer.frameLength))
        let volume = min(1.0, rms * 10)  // Scale for visibility

        // Send append message
        sendAppendMessage(audio: base64Audio, volume: volume)
    }

    private func createWavData(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var wavData = Data()

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let chunkSize = 36 + dataSize

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // Subchunk1Size (16 for PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // AudioFormat (1 = PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }

    private func sendAppendMessage(audio: String, volume: Float) {
        let currentPosition = packetCount
        packetCount += 1

        // Append message format per Wispr Flow API docs
        let appendMessage: [String: Any] = [
            "type": "append",
            "position": currentPosition,
            "audio_packets": [
                "packets": [audio],
                "volumes": [volume],
                "packet_duration": packetDuration,
                "audio_encoding": "wav",
                "byte_encoding": "base64"
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: appendMessage),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(jsonString)) { _ in }
    }

    private func sendCommitMessage() {
        let commitMessage: [String: Any] = [
            "type": "commit",
            "total_packets": packetCount
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: commitMessage),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(jsonString)) { [weak self] _ in
            // Stop audio capture but keep WebSocket open for transcription response
            Task { @MainActor in
                self?.audioEngine?.stop()
                self?.audioEngine?.inputNode.removeTap(onBus: 0)
                self?.audioEngine = nil
            }
        }
    }

    private func receiveTranscriptions() async {
        while let webSocket = webSocket {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .string(let text):
                    await handleResponse(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleResponse(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
    }

    private func handleResponse(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard let status = json["status"] as? String else {
            // Check for error format without status field
            if let errorStr = json["error"] as? String {
                logger.error("Error: \(errorStr)")
                await MainActor.run {
                    self.error = errorStr
                    self.cleanup()
                    self.isListening = false
                }
            }
            return
        }

        switch status {
        case "auth", "info":
            break

        case "text":
            guard let body = json["body"] as? [String: Any],
                  var transcription = body["text"] as? String else { return }

            // Lowercase first character for terminal/code contexts
            if currentContext.lowercaseFirst, let first = transcription.first, first.isUppercase {
                transcription = first.lowercased() + transcription.dropFirst()
            }

            let isFinal = json["final"] as? Bool ?? false
            logger.info("Transcription: \(transcription)")

            await MainActor.run {
                if isFinal {
                    self.transcribedText = transcription
                    self.partialText = ""
                } else {
                    self.partialText = transcription
                }
            }

        case "error":
            var errorMsg = "Unknown error"
            if let body = json["body"] as? [String: Any] {
                errorMsg = (body["message"] as? String) ?? (body["error"] as? String) ?? errorMsg
            } else if let msg = json["message"] as? String {
                errorMsg = msg
            }
            logger.error("Server error: \(errorMsg)")
            await MainActor.run {
                self.error = errorMsg
                self.cleanup()
                self.isListening = false
            }

        default:
            break
        }
    }

    private func cleanup() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession = nil
    }
}

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case invalidURL
    case encodingFailed
    case audioEngineSetupFailed
    case audioFormatFailed
    case converterSetupFailed
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Wispr Flow URL"
        case .encodingFailed: return "Failed to encode message"
        case .audioEngineSetupFailed: return "Failed to setup audio engine"
        case .audioFormatFailed: return "Failed to create audio format"
        case .converterSetupFailed: return "Failed to create audio converter"
        case .connectionFailed: return "Failed to connect to Wispr Flow"
        }
    }
}
