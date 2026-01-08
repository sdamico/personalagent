import Foundation
import Combine
import UIKit
import CryptoKit

@MainActor
final class AgentConnection: ObservableObject {
    // MARK: - Published State

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var sessions: [PTYSession] = []
    @Published private(set) var services: [ServiceStatus] = []
    @Published private(set) var error: String?
    @Published private(set) var sessionTitles: [String: String] = [:]  // Track active terminal titles

    func updateSessionTitle(_ sessionId: String, title: String) {
        sessionTitles[sessionId] = title
    }

    // MARK: - Session Data Streams

    private var sessionDataSubjects: [String: PassthroughSubject<String, Never>] = [:]

    func dataPublisher(for sessionId: String) -> AnyPublisher<String, Never> {
        if sessionDataSubjects[sessionId] == nil {
            sessionDataSubjects[sessionId] = PassthroughSubject()
        }
        return sessionDataSubjects[sessionId]!.eraseToAnyPublisher()
    }

    // MARK: - Private

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var config: ConnectionConfig?
    private let clientId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let deviceName = UIDevice.current.name
    private var pendingRequests: [String: CheckedContinuation<IncomingMessage, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var sslPinningDelegate: SSLPinningDelegate?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case error(String)
    }

    // MARK: - Connection

    func connect(config: ConnectionConfig) async throws {
        self.config = config
        connectionState = .connecting
        error = nil

        // Use wss:// for TLS-encrypted connection
        guard let url = URL(string: "wss://\(config.host):\(config.port)") else {
            throw ConnectionError.invalidURL
        }

        // SSL pinning is REQUIRED - reject connections without cert fingerprint
        guard let fingerprint = config.certFingerprint, !fingerprint.isEmpty else {
            throw ConnectionError.noCertFingerprint
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        sessionConfig.timeoutIntervalForRequest = 30

        sslPinningDelegate = SSLPinningDelegate(expectedFingerprint: fingerprint)
        urlSession = URLSession(
            configuration: sessionConfig,
            delegate: sslPinningDelegate,
            delegateQueue: nil
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        // Start receiving messages
        receiveTask = Task { await receiveLoop() }

        // Authenticate
        connectionState = .authenticating
        try await authenticate(token: config.authToken)

        connectionState = .connected
    }

    func disconnect() {
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession = nil
        connectionState = .disconnected
        sessions = []
        services = []
        sessionDataSubjects.removeAll()
    }

    private func authenticate(token: String) async throws {
        let payload: [String: Any] = [
            "token": token,
            "clientId": clientId,
            "deviceName": deviceName
        ]

        let response = try await sendRequest(type: "auth", action: "authenticate", payload: payload)

        guard response.action == "success" else {
            throw ConnectionError.authenticationFailed
        }

        // Parse initial state from auth response
        if let dict = response.payload?.dictionary {
            if let sessionsData = dict["sessions"] as? [[String: Any]] {
                self.sessions = sessionsData.compactMap { decodeSession($0) }
                // Re-subscribe to all existing sessions and refresh their displays
                for session in self.sessions {
                    subscribe(to: session.id)
                    // Send Ctrl+L to redraw the terminal after reconnect
                    write(to: session.id, data: "\u{0C}")
                }
            }
            if let servicesData = dict["services"] as? [[String: Any]] {
                self.services = servicesData.compactMap { decodeService($0) }
            }
        }
    }

    // MARK: - PTY Operations

    func createSession(name: String? = nil, cols: Int = 80, rows: Int = 24) async throws -> PTYSession {
        var payload: [String: Any] = ["cols": cols, "rows": rows]
        if let name = name {
            payload["name"] = name
        }

        let response = try await sendRequest(type: "pty", action: "create", payload: payload)

        guard let dict = response.payload?.dictionary,
              let session = decodeSession(dict) else {
            throw ConnectionError.invalidResponse
        }

        sessions.append(session)
        subscribe(to: session.id)
        return session
    }

    func write(to sessionId: String, data: String, source: String? = nil) {
        var payload: [String: Any] = ["sessionId": sessionId, "data": data]
        if let source = source {
            payload["source"] = source
        }
        sendMessage(type: "pty", action: "write", payload: payload)
    }

    func resize(sessionId: String, cols: Int, rows: Int) {
        sendMessage(type: "pty", action: "resize", payload: [
            "sessionId": sessionId,
            "cols": cols,
            "rows": rows
        ])
    }

    func closeSession(_ sessionId: String) async throws {
        _ = try await sendRequest(type: "pty", action: "close", payload: ["sessionId": sessionId])
        sessions.removeAll { $0.id == sessionId }
        sessionDataSubjects.removeValue(forKey: sessionId)
    }

    private func subscribe(to sessionId: String) {
        sendMessage(type: "pty", action: "subscribe", payload: ["sessionId": sessionId])
    }

    // MARK: - Service Operations

    func startService(_ serviceId: String) async throws {
        _ = try await sendRequest(type: "service", action: "start", payload: ["serviceId": serviceId])
    }

    func stopService(_ serviceId: String) async throws {
        _ = try await sendRequest(type: "service", action: "stop", payload: ["serviceId": serviceId])
    }

    func restartService(_ serviceId: String) async throws {
        _ = try await sendRequest(type: "service", action: "restart", payload: ["serviceId": serviceId])
    }

    // MARK: - Messaging

    private func sendMessage(type: String, action: String, payload: [String: Any]? = nil) {
        let message = RemoteMessage(type: type, action: action, payload: payload)
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket?.send(.string(string)) { _ in }
    }

    private func sendRequest(type: String, action: String, payload: [String: Any]? = nil) async throws -> IncomingMessage {
        let requestId = UUID().uuidString
        let message = RemoteMessage(type: type, action: action, payload: payload, requestId: requestId)

        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation

            webSocket?.send(.string(string)) { [weak self] error in
                if let error = error {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: error)
                }
            }

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let cont = self.pendingRequests.removeValue(forKey: requestId) {
                    cont.resume(throwing: ConnectionError.timeout)
                }
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let webSocket = webSocket else { break }
                let message = try await webSocket.receive()

                switch message {
                case .string(let text):
                    await handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.connectionState = .disconnected
                        self.error = "Connection lost"
                    }
                }
                break
            }
        }
    }

    /// Force reconnect - used when returning from background
    func forceReconnect() async {
        guard let config = config else { return }

        // Always clean up and reconnect when coming from background
        // WebSocket state isn't reliable after backgrounding
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        connectionState = .disconnected

        do {
            try await connect(config: config)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(IncomingMessage.self, from: data) else {
            return
        }

        // Check if this is a response to a pending request
        if let requestId = message.requestId,
           let continuation = pendingRequests.removeValue(forKey: requestId) {
            continuation.resume(returning: message)
            return
        }

        // Handle broadcast messages
        await MainActor.run {
            switch message.type {
            case "pty":
                handlePTYMessage(message)
            case "service":
                handleServiceMessage(message)
            case "system":
                handleSystemMessage(message)
            default:
                break
            }
        }
    }

    private func handlePTYMessage(_ message: IncomingMessage) {
        guard let dict = message.payload?.dictionary else { return }

        switch message.action {
        case "data":
            if let sessionId = dict["sessionId"] as? String,
               let data = dict["data"] as? String {
                sessionDataSubjects[sessionId]?.send(data)
            }
        case "exit":
            if let sessionId = dict["sessionId"] as? String {
                sessions.removeAll { $0.id == sessionId }
                sessionDataSubjects.removeValue(forKey: sessionId)
            }
        default:
            break
        }
    }

    private func handleServiceMessage(_ message: IncomingMessage) {
        guard let dict = message.payload?.dictionary,
              let service = decodeService(dict) else { return }

        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        }
    }

    private func handleSystemMessage(_ message: IncomingMessage) {
        if message.action == "error",
           let dict = message.payload?.dictionary,
           let errorMsg = dict["error"] as? String {
            error = errorMsg
        }
    }

    // MARK: - Decoding Helpers

    private func decodeSession(_ dict: [String: Any]) -> PTYSession? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let cols = dict["cols"] as? Int,
              let rows = dict["rows"] as? Int,
              let cwd = dict["cwd"] as? String,
              let shell = dict["shell"] as? String else {
            return nil
        }
        // Handle createdAt as either Int or Double (JS Date.now() returns integer milliseconds)
        let createdAt: TimeInterval
        if let intValue = dict["createdAt"] as? Int {
            createdAt = TimeInterval(intValue) / 1000.0  // Convert ms to seconds
        } else if let doubleValue = dict["createdAt"] as? Double {
            createdAt = doubleValue / 1000.0  // Convert ms to seconds
        } else {
            return nil
        }
        return PTYSession(id: id, name: name, cols: cols, rows: rows, cwd: cwd, shell: shell, createdAt: createdAt)
    }

    private func decodeService(_ dict: [String: Any]) -> ServiceStatus? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let status = dict["status"] as? String else {
            return nil
        }
        return ServiceStatus(
            id: id,
            name: name,
            status: status,
            pid: dict["pid"] as? Int,
            uptime: dict["uptime"] as? TimeInterval,
            lastError: dict["lastError"] as? String
        )
    }
}

// MARK: - Errors

enum ConnectionError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case invalidResponse
    case encodingFailed
    case timeout
    case sslPinningFailed
    case noCertFingerprint

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .authenticationFailed: return "Authentication failed"
        case .invalidResponse: return "Invalid server response"
        case .encodingFailed: return "Failed to encode message"
        case .timeout: return "Request timed out"
        case .sslPinningFailed: return "SSL certificate verification failed. Please re-scan the QR code from the desktop app."
        case .noCertFingerprint: return "No certificate fingerprint. Please scan the QR code from the desktop app to connect securely."
        }
    }
}

// MARK: - SSL Pinning Delegate

/// URLSession delegate that implements SSL pinning by verifying the server certificate
/// fingerprint matches the expected fingerprint from the QR code pairing.
final class SSLPinningDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        // Normalize fingerprint - remove colons and convert to uppercase
        self.expectedFingerprint = expectedFingerprint
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        print("[SSLPinning] Initialized with expected fingerprint: \(self.expectedFingerprint)")
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        print("[SSLPinning] Received auth challenge: \(challenge.protectionSpace.authenticationMethod)")

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            print("[SSLPinning] Not a server trust challenge, cancelling")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // For self-signed certs, we need to set a policy that doesn't validate the chain
        let policy = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(serverTrust, policy)

        // Get the server's certificate
        guard let serverCert = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            print("[SSLPinning] Could not get server certificate")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Calculate fingerprint of server certificate
        let certData = SecCertificateCopyData(serverCert) as Data
        let fingerprint = SHA256.hash(data: certData)
            .map { String(format: "%02X", $0) }
            .joined()

        print("[SSLPinning] Server fingerprint: \(fingerprint)")
        print("[SSLPinning] Expected fingerprint: \(expectedFingerprint)")

        // Compare fingerprints
        if fingerprint == expectedFingerprint {
            print("[SSLPinning] Fingerprint matches! Accepting connection.")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            print("[SSLPinning] Fingerprint mismatch! Rejecting connection.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
