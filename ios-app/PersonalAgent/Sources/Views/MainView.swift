import SwiftUI

struct MainView: View {
    @StateObject private var connection = AgentConnection()
    @StateObject private var voiceInput = VoiceInputManager()
    @State private var selectedSessionId: String?
    @State private var showingSettings = false
    @State private var showingConnectionSheet = false

    @State private var isCursorDragging = false

    var body: some View {
        VStack(spacing: 0) {
            if connection.connectionState == .connected {
                // Session tabs with settings gear and status dot
                SessionTabBar(
                    sessions: .init(
                        get: { connection.sessions },
                        set: { _ in }
                    ),
                    selectedSessionId: $selectedSessionId,
                    isConnected: true,
                    onNewSession: createNewSession,
                    onCloseSession: closeSession,
                    onSettings: { showingSettings = true }
                )

                Divider()

                // Terminal content - keep all sessions alive, show selected
                GeometryReader { geometry in
                    ZStack {
                        ForEach(connection.sessions) { session in
                            TerminalView(session: session, connection: connection)
                                .opacity(session.id == selectedSessionId ? 1 : 0)
                                .allowsHitTesting(session.id == selectedSessionId)
                        }

                        if connection.sessions.isEmpty {
                            emptyState
                        }

                        // FAB stack overlay
                        if selectedSessionId != nil {
                            FABStack(
                                isCursorDragging: $isCursorDragging,
                                isListening: voiceInput.isListening,
                                hasError: voiceInput.error != nil,
                                onArrow: { direction in
                                    hideKeyboard()
                                    switch direction {
                                    case .up: sendKey("\u{1B}[A")
                                    case .down: sendKey("\u{1B}[B")
                                    case .left: sendKey("\u{1B}[D")
                                    case .right: sendKey("\u{1B}[C")
                                    }
                                },
                                onEnter: { sendKey("\r") },
                                onCtrlKey: { char in sendCtrlKey(char) },
                                onEscape: { sendKey("\u{1B}") },
                                onTab: { sendKey("\t") },
                                onBackspace: { sendKey("\u{7F}") },  // DEL character (backspace)
                                onCopy: { copySelection() },
                                onPaste: { pasteFromClipboard() },
                                onKeyboardToggle: { toggleKeyboard() },
                                onMicTap: {
                                    hideKeyboard()
                                    toggleVoiceInput()
                                }
                            )
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                connectionView
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(connection: connection)
        }
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionSheet(connection: connection)
        }
        .onChange(of: connection.sessions) { _, newSessions in
            // Auto-select first session if none selected
            if selectedSessionId == nil, let first = newSessions.first {
                selectedSessionId = first.id
            }
            // Clear selection if session was removed
            if let selected = selectedSessionId,
               !newSessions.contains(where: { $0.id == selected }) {
                selectedSessionId = newSessions.first?.id
            }
        }
        .onChange(of: voiceInput.transcribedText) { _, newText in
            sendVoiceInput(newText)
        }
        .task {
            await autoConnectIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Force reconnect when app returns from background
            // WebSocket connections don't survive backgrounding reliably
            Task {
                await connection.forceReconnect()
            }
        }
    }

    private func autoConnectIfPossible() async {
        // Check for saved credentials
        guard let host = KeychainHelper.serverHost,
              let token = KeychainHelper.authToken,
              !host.isEmpty,
              !token.isEmpty else {
            return
        }

        let port = KeychainHelper.serverPort ?? 9876
        let config = ConnectionConfig(
            host: host,
            port: port,
            authToken: token,
            certFingerprint: KeychainHelper.certFingerprint
        )

        do {
            try await connection.connect(config: config)
        } catch {
            // Silent fail - user can manually connect
            print("Auto-connect failed: \(error)")
        }
    }

    // MARK: - Subviews

    private var connectionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "network")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Not Connected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Connect to your Personal Agent on your Mac Mini")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Connect") {
                showingConnectionSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Sessions")
                .font(.headline)

            Button("New Session") {
                createNewSession()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendKey(_ key: String) {
        guard let sessionId = selectedSessionId else { return }
        connection.write(to: sessionId, data: key)
    }

    private func sendCtrlKey(_ char: Character) {
        // Convert character to control code (Ctrl+A = 0x01, Ctrl+Z = 0x1A)
        let lower = char.lowercased().first ?? char
        guard let ascii = lower.asciiValue, ascii >= 97, ascii <= 122 else { return }  // a-z
        let ctrlCode = ascii - 96  // 'a' (97) -> 1, 'z' (122) -> 26
        sendKey(String(UnicodeScalar(ctrlCode)))
    }

    // MARK: - Actions

    private func createNewSession() {
        Task {
            do {
                let session = try await connection.createSession(name: "Terminal")
                selectedSessionId = session.id
            } catch {
                print("Failed to create session: \(error)")
            }
        }
    }

    private func closeSession(_ sessionId: String) {
        Task {
            try? await connection.closeSession(sessionId)
        }
    }

    private func toggleVoiceInput() {
        if voiceInput.isListening {
            voiceInput.stopListening()
        } else {
            // Detect context from session name
            let context = detectVoiceContext()
            voiceInput.startListening(context: context)
        }
    }

    private func detectVoiceContext() -> VoiceInputManager.VoiceContext {
        guard let sessionId = selectedSessionId else {
            return .terminal
        }

        // Use terminal title which reflects the active process
        let title = (connection.sessionTitles[sessionId] ?? "").lowercased()

        if title.contains("claude") {
            return .claudeCode
        } else if title.contains("vim") || title.contains("nvim") || title.contains("neovim") {
            return .vim
        } else if title.contains("python") || title.contains("node") || title.contains("irb") {
            // REPL mode - could add a specific context for this
            return .terminal
        } else {
            return .terminal
        }
    }

    private func sendVoiceInput(_ text: String) {
        guard !text.isEmpty, let sessionId = selectedSessionId else { return }
        connection.write(to: sessionId, data: text, source: "wispr-flow")
    }

    private func pasteFromClipboard() {
        guard let sessionId = selectedSessionId,
              let text = UIPasteboard.general.string,
              !text.isEmpty else { return }
        connection.write(to: sessionId, data: text)
    }

    private func copySelection() {
        guard let sessionId = selectedSessionId else { return }
        NotificationCenter.default.post(name: .terminalCopyRequested, object: sessionId)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func toggleKeyboard() {
        // Post notification to toggle keyboard in the terminal view
        NotificationCenter.default.post(name: .terminalKeyboardToggle, object: selectedSessionId)
    }
}

// MARK: - Connection Sheet

struct ConnectionSheet: View {
    @ObservedObject var connection: AgentConnection
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var port: Int = 9876
    @State private var authToken: String = ""
    @State private var certFingerprint: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showingScanner = false
    @State private var showingTailscaleHelp = false

    var body: some View {
        NavigationStack {
            Form {
                // QR Code Scanner Section
                Section {
                    Button(action: { showingScanner = true }) {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text("Scan QR Code")
                                    .font(.headline)
                                Text("Fastest way to connect")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Quick Connect")
                } footer: {
                    Text("Open the Connection tab in the desktop app to see the QR code")
                }

                // Tailscale Info
                Section {
                    Button(action: { showingTailscaleHelp.toggle() }) {
                        HStack {
                            Image(systemName: "network")
                            Text("Both devices need Tailscale")
                            Spacer()
                            Image(systemName: showingTailscaleHelp ? "chevron.up" : "chevron.down")
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)

                    if showingTailscaleHelp {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tailscale creates a secure network between your devices.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Button(action: openAppStore) {
                                HStack {
                                    Image(systemName: "arrow.down.app")
                                    Text("Get Tailscale for iPhone")
                                }
                            }

                            Button(action: openTailscale) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.app")
                                    Text("Open Tailscale")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Manual Entry
                Section {
                    TextField("Tailscale IP (e.g. 100.64.x.x)", text: $host)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.numbersAndPunctuation)

                    Stepper("Port: \(port)", value: $port, in: 1...65535)

                    SecureField("Auth Token", text: $authToken)
                        .textContentType(.password)
                        .autocapitalization(.none)

                    TextField("TLS Fingerprint", text: $certFingerprint)
                        .autocapitalization(.none)
                        .font(.system(.caption, design: .monospaced))
                } header: {
                    Text("Manual Entry")
                } footer: {
                    Text("Copy the TLS fingerprint from the Connection tab in the desktop app")
                }

                // Error Display
                if let error = errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .foregroundColor(.red)
                            }

                            if error.contains("Could not connect") || error.contains("timed out") {
                                Text("Make sure Tailscale is running and connected on both devices.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    Button("Get Tailscale") {
                                        openAppStore()
                                    }
                                    .font(.caption)

                                    Button("Open Tailscale") {
                                        openTailscale()
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                // Connect Button
                Section {
                    Button(action: connect) {
                        if isConnecting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Connect")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(host.isEmpty || authToken.isEmpty || isConnecting)
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                loadSavedCredentials()
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { pairingInfo in
                    // Auto-fill from QR code
                    host = pairingInfo.host
                    port = pairingInfo.port
                    authToken = pairingInfo.token
                    certFingerprint = pairingInfo.certFingerprint ?? ""
                    // Save cert fingerprint for SSL pinning
                    KeychainHelper.certFingerprint = pairingInfo.certFingerprint
                    // Auto-connect
                    connect()
                }
            }
        }
    }

    private func loadSavedCredentials() {
        if let savedHost = KeychainHelper.serverHost {
            host = savedHost
        }
        if let savedPort = KeychainHelper.serverPort {
            port = savedPort
        }
        if let savedToken = KeychainHelper.authToken {
            authToken = savedToken
        }
        if let savedFingerprint = KeychainHelper.certFingerprint {
            certFingerprint = savedFingerprint
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil

        // Save credentials to Keychain
        KeychainHelper.serverHost = host
        KeychainHelper.serverPort = port
        KeychainHelper.authToken = authToken
        // Save fingerprint if manually entered (non-empty)
        if !certFingerprint.isEmpty {
            KeychainHelper.certFingerprint = certFingerprint
        }

        Task {
            do {
                let config = ConnectionConfig(
                    host: host,
                    port: port,
                    authToken: authToken,
                    certFingerprint: KeychainHelper.certFingerprint
                )
                try await connection.connect(config: config)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func openTailscale() {
        // Try to open Tailscale app using its URL scheme
        // If that fails, open the App Store page
        if let url = URL(string: "tailscale://") {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    openAppStore()
                }
            }
        } else {
            openAppStore()
        }
    }

    private func openAppStore() {
        // Try multiple URL formats
        let urls = [
            "itms-apps://apps.apple.com/app/id1470499037",
            "https://apps.apple.com/app/tailscale/id1470499037"
        ]

        for urlString in urls {
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }

        // Fallback: copy URL to clipboard and show message (useful for simulator)
        UIPasteboard.general.string = "https://apps.apple.com/app/tailscale/id1470499037"
        // The error message will guide them
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var connection: AgentConnection
    @Environment(\.dismiss) private var dismiss
    @State private var wisprAPIKey = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Status", value: statusText)

                    if connection.connectionState == .connected {
                        Button("Disconnect", role: .destructive) {
                            connection.disconnect()
                        }
                    }
                }

                Section {
                    SecureField("API Key", text: $wisprAPIKey)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .onChange(of: wisprAPIKey) { _, newValue in
                            KeychainHelper.wisprFlowAPIKey = newValue.isEmpty ? nil : newValue
                        }
                } header: {
                    Text("Wispr Flow")
                } footer: {
                    Text("Get your API key from wisprflow.ai/developers")
                }

                Section("Services") {
                    if connection.services.isEmpty {
                        Text("No services")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(connection.services) { service in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(service.name)
                                    Text(service.status)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if service.status == "running" {
                                    Button("Stop") {
                                        Task { try? await connection.stopService(service.id) }
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button("Start") {
                                        Task { try? await connection.startService(service.id) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                wisprAPIKey = KeychainHelper.wisprFlowAPIKey ?? ""
            }
        }
    }

    private var statusText: String {
        switch connection.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .disconnected: return "Disconnected"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Preview

#Preview {
    MainView()
}
