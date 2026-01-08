import SwiftUI
import SwiftTerm
import Combine

struct TerminalView: View {
    let session: PTYSession
    @ObservedObject var connection: AgentConnection

    var body: some View {
        TerminalUIViewRepresentable(
            session: session,
            connection: connection
        )
    }
}

extension Notification.Name {
    static let terminalCopyRequested = Notification.Name("terminalCopyRequested")
    static let terminalKeyboardToggle = Notification.Name("terminalKeyboardToggle")
}

struct TerminalUIViewRepresentable: UIViewRepresentable {
    let session: PTYSession
    let connection: AgentConnection

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminalView = SwiftTerm.TerminalView(frame: .zero)

        // Configure terminal appearance
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

        // Disable built-in input accessory view (we have our own)
        terminalView.inputAccessoryView = nil

        // Add bottom content inset so the cursor can sit above the FABs (~25% from bottom)
        // This allows scrolling "past" the content, giving visual space below the cursor
        let screenHeight = UIScreen.main.bounds.height
        let bottomInset = screenHeight * 0.28  // Room for FABs
        terminalView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        terminalView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)

        // Set delegate for input
        terminalView.terminalDelegate = context.coordinator
        context.coordinator.terminalView = terminalView

        // Add double-tap gesture for showing keyboard
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        terminalView.addGestureRecognizer(doubleTap)

        // Add single-tap gesture that blocks first responder but allows double-tap
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)  // Only fire if not a double-tap
        terminalView.addGestureRecognizer(singleTap)

        return terminalView
    }

    func updateUIView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.updateSession(session)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, connection: connection)
    }

    @MainActor
    class Coordinator: NSObject, TerminalViewDelegate {
        var session: PTYSession
        let connection: AgentConnection
        private var cancellables = Set<AnyCancellable>()
        private var dataSubscription: AnyCancellable?
        weak var terminalView: SwiftTerm.TerminalView?
        private var lastConnectionState: AgentConnection.ConnectionState = .disconnected

        init(session: PTYSession, connection: AgentConnection) {
            self.session = session
            self.connection = connection
            super.init()

            // Subscribe to incoming data
            setupDataSubscription()

            // Monitor connection state to refresh subscription after reconnect
            connection.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newState in
                    guard let self = self else { return }
                    // If we just connected (from any other state), refresh subscription
                    if newState == .connected && self.lastConnectionState != .connected {
                        self.setupDataSubscription()
                    }
                    self.lastConnectionState = newState
                }
                .store(in: &cancellables)

            // Listen for copy requests
            NotificationCenter.default.publisher(for: .terminalCopyRequested)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self = self,
                          let sessionId = notification.object as? String,
                          sessionId == self.session.id,
                          let terminal = self.terminalView else { return }
                    // Get selected text and copy to clipboard
                    if let selectedText = terminal.getSelection(), !selectedText.isEmpty {
                        UIPasteboard.general.string = selectedText
                    }
                }
                .store(in: &cancellables)

            // Listen for keyboard toggle requests
            NotificationCenter.default.publisher(for: .terminalKeyboardToggle)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self = self,
                          let sessionId = notification.object as? String,
                          sessionId == self.session.id,
                          let terminal = self.terminalView else { return }
                    if terminal.isFirstResponder {
                        terminal.resignFirstResponder()
                    } else {
                        terminal.becomeFirstResponder()
                    }
                }
                .store(in: &cancellables)
        }

        private func setupDataSubscription() {
            dataSubscription?.cancel()
            dataSubscription = connection.dataPublisher(for: session.id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] data in
                    guard let self = self, let terminalView = self.terminalView else { return }
                    terminalView.feed(text: data)
                }
        }

        func updateSession(_ newSession: PTYSession) {
            if session.id != newSession.id {
                session = newSession
                setupDataSubscription()
            }
        }

        @objc func handleDoubleTap() {
            terminalView?.becomeFirstResponder()
        }

        @objc func handleSingleTap() {
            // Do nothing - this intercepts single taps to prevent auto-keyboard
            // Selection via long-press still works
        }

        // MARK: - TerminalViewDelegate

        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let string = String(bytes: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connection.write(to: self.session.id, data: string)
            }
        }

        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            // Handle scrollback if needed
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connection.updateSessionTitle(self.session.id, title: title)
            }
        }

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connection.resize(sessionId: self.session.id, cols: newCols, rows: newRows)
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            // Track current directory if needed
        }

        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) {
                Task { @MainActor in
                    UIApplication.shared.open(url)
                }
            }
        }

        nonisolated func bell(source: SwiftTerm.TerminalView) {
            // Play haptic feedback
            Task { @MainActor in
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
            }
        }

        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let string = String(data: content, encoding: .utf8) {
                Task { @MainActor in
                    UIPasteboard.general.string = string
                }
            }
        }

        nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {
            // Handle iTerm2 OSC 1337 content if needed
        }

        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            // Handle selection range changes
        }
    }
}

// MARK: - Preview

#Preview {
    TerminalView(
        session: PTYSession(
            id: "preview",
            name: "Preview",
            cols: 80,
            rows: 24,
            cwd: "/",
            shell: "/bin/zsh",
            createdAt: Date().timeIntervalSince1970
        ),
        connection: AgentConnection()
    )
}
