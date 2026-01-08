# Personal Agent iOS App

SwiftUI app for remote control of your Personal Agent on Mac Mini via Tailscale.

## Features

- **QR Code Pairing** - Scan to securely connect with TLS certificate pinning
- **Multi-tab terminal sessions** - Run multiple Claude Code instances simultaneously
- **Native terminal rendering** - SwiftTerm for fast, native terminal emulation
- **FAB Controls** - Floating action button for arrow keys, Ctrl sequences, and more
- **Wispr Flow voice input** - Dictate commands hands-free
- **Tailscale connectivity** - Secure access through your private network
- **Copy/Paste support** - Full clipboard integration

## Requirements

- iOS 17.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

## Setup

1. Install XcodeGen:
   ```bash
   brew install xcodegen
   ```

2. Generate Xcode project:
   ```bash
   cd PersonalAgent
   xcodegen generate
   ```

3. Open in Xcode:
   ```bash
   open PersonalAgent.xcodeproj
   ```

4. Set your development team in project settings

5. Build and run on your device

## Connecting to Personal Agent

### QR Code Pairing (Recommended)

1. Ensure both your iPhone and Mac Mini are on the same Tailscale network
2. Open the Personal Agent desktop app on your Mac
3. Go to the **Connection** tab - you'll see a QR code
4. In the iOS app, tap **Connect** → **Scan QR Code**
5. The app will automatically connect with TLS certificate pinning

### Manual Connection

1. Get your Mac Mini's Tailscale IP (e.g., `100.x.x.x`)
2. Copy the auth token from the desktop app (Connection tab)
3. Copy the TLS fingerprint from the desktop app
4. Enter all details in the iOS app's manual connection form

## Security

- **TLS Encryption**: All connections use wss:// with certificate pinning
- **Certificate Pinning**: Server certificate fingerprint validated against QR code
- **Keychain Storage**: Auth tokens and API keys stored in iOS Keychain
- **Tailscale Network**: Only accessible within your private Tailscale network

## FAB Controls

The floating action button provides quick access to terminal controls:

**Drag gestures:**
- Drag in any direction for arrow keys (with key repeat on hold)

**Long press menu:**
- `del` - Backspace
- `copy` - Copy terminal selection
- `paste` - Paste from clipboard
- `kbd` - Toggle software keyboard
- `esc` - Escape key
- `tab` - Tab key
- `^C` - Ctrl+C (interrupt)
- `^Z` - Ctrl+Z (suspend)
- `^?` - Custom Ctrl+key input

**Other gestures:**
- Double tap: Enter key
- Triple tap: Reposition FAB

## Voice Input

The app supports two voice input modes:

### Wispr Flow (Recommended)
High-quality dictation optimized for technical content. Set your API key in Settings.

### iOS Native Speech
Fallback using Apple's Speech framework. Works offline with on-device recognition.

To use voice input:
1. Tap the microphone FAB while in a terminal session
2. Speak your command
3. The transcribed text is sent to the active terminal

## Project Structure

```
PersonalAgent/
├── Sources/
│   ├── App/
│   │   ├── PersonalAgentApp.swift    # App entry point
│   │   ├── Info.plist
│   │   └── PersonalAgent.entitlements
│   ├── Models/
│   │   ├── Session.swift             # PTY session model
│   │   └── Messages.swift            # WebSocket message types
│   ├── Services/
│   │   ├── AgentConnection.swift     # WebSocket client + TLS pinning
│   │   ├── KeychainHelper.swift      # Secure credential storage
│   │   └── VoiceInputManager.swift   # Speech/Wispr Flow
│   └── Views/
│       ├── MainView.swift            # Main UI + connection sheet
│       ├── TerminalView.swift        # SwiftTerm wrapper
│       ├── SessionTabBar.swift       # Tab navigation
│       ├── FABStack.swift            # Floating action buttons
│       ├── CursorFAB.swift           # Cursor control FAB
│       └── QRScannerView.swift       # QR code scanner
├── Assets.xcassets/                  # App icons
├── project.yml                       # XcodeGen config
└── Package.swift                     # SPM for dependencies
```

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulator
