# Personal Agent iOS App

SwiftUI app for remote control of your Personal Agent on Mac Mini via Tailscale.

## Features

- **Multi-tab terminal sessions** - Run multiple Claude Code instances simultaneously
- **Native terminal rendering** - SwiftTerm for fast, native terminal emulation
- **Wispr Flow voice input** - Dictate commands hands-free
- **Tailscale connectivity** - Secure access through your private network
- **Background audio** - Keep voice input active when app is backgrounded

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

1. Ensure both your iPhone and Mac Mini are on the same Tailscale network
2. Get your Mac Mini's Tailscale IP (e.g., `100.x.x.x`)
3. Copy the auth token from the Mac Mini agent (tray menu → Copy Auth Token)
4. In the iOS app, tap Connect and enter the IP, port (9876), and token

## Voice Input

The app supports two voice input modes:

### Wispr Flow (Recommended)
High-quality dictation optimized for technical content. Set your API key in Settings.

### iOS Native Speech
Fallback using Apple's Speech framework. Works offline with on-device recognition.

To use voice input:
1. Tap the microphone button while in a terminal session
2. Speak your command
3. The transcribed text is sent to the active terminal

## Project Structure

```
PersonalAgent/
├── Sources/
│   ├── App/
│   │   ├── PersonalAgentApp.swift  # App entry point
│   │   ├── Info.plist
│   │   └── PersonalAgent.entitlements
│   ├── Models/
│   │   ├── Session.swift           # PTY session model
│   │   └── Messages.swift          # WebSocket message types
│   ├── Services/
│   │   ├── AgentConnection.swift   # WebSocket client
│   │   └── VoiceInputManager.swift # Speech/Wispr Flow
│   └── Views/
│       ├── MainView.swift          # Main UI with connection
│       ├── TerminalView.swift      # SwiftTerm wrapper
│       └── SessionTabBar.swift     # Tab navigation
├── project.yml                      # XcodeGen config
└── Package.swift                    # SPM for dependencies
```

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulator
