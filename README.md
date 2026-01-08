# Personal Agent

A personal agent system with a Mac Mini background service (Electron) and iOS remote control app. Run multiple Claude Code instances and other terminal sessions, controllable via voice (Wispr Flow) from anywhere through Tailscale.

## Components

- **[Mac Agent](.)** - Electron app running on Mac Mini (this directory)
- **[iOS App](./ios-app)** - SwiftUI app for iPhone/iPad remote control

## Features

- **System Tray**: Runs minimized to tray, auto-starts on login
- **Remote PTY**: Multiple concurrent terminal sessions accessible via WebSocket
- **Service Management**: Configure and manage background services (Claude Code, etc.)
- **Tailscale Integration**: Secure remote access through your Tailscale network
- **TLS Encryption**: Self-signed certificates with certificate pinning
- **QR Code Pairing**: Scan a QR code to securely pair iOS app with Mac agent
- **Voice Input**: Wispr Flow integration for hands-free terminal control

## Architecture

```
iOS App ──(TLS/WSS)──► Tailscale ──► Personal Agent (Mac Mini)
                                            │
                                            ├── PTY Sessions (tabs)
                                            │   ├── Claude Code #1
                                            │   ├── Claude Code #2
                                            │   └── ...
                                            │
                                            └── Managed Services
```

## Setup

1. Install dependencies:
   ```bash
   npm install
   ```

2. Build and run:
   ```bash
   npm start
   ```

3. Build distributable DMG:
   ```bash
   npm run dist
   ```

## Connecting the iOS App

1. Ensure both devices are on the same Tailscale network
2. Open the Personal Agent desktop app
3. Go to the **Connection** tab to see the QR code
4. Open the iOS app and tap **Connect** → **Scan QR Code**
5. The QR code contains: Tailscale IP, port, auth token, and TLS certificate fingerprint

The QR code pairing automatically configures TLS certificate pinning for secure connections.

## Security

### TLS Encryption
- All connections use TLS (wss://) with self-signed certificates
- Certificate fingerprint is embedded in QR code for pinning
- iOS app validates server certificate matches the paired fingerprint

### Authentication
- Auth tokens stored in macOS Keychain (not plaintext files)
- 64-character cryptographically random tokens
- Constant-time comparison prevents timing attacks
- 10-second authentication timeout

### Network Restrictions
- By default, only accepts connections from:
  - Localhost (127.0.0.1, ::1)
  - Tailscale CGNAT range (100.64.0.0/10)
- Toggle in Settings → Security → "Restrict to Tailscale"

## WebSocket Protocol

All messages use JSON over secure WebSocket (wss://).

### Authentication
```json
{
  "type": "auth",
  "action": "authenticate",
  "payload": {
    "token": "your-auth-token",
    "clientId": "ios-app-uuid",
    "deviceName": "iPhone"
  }
}
```

### Create PTY Session
```json
{
  "type": "pty",
  "action": "create",
  "payload": {
    "name": "Claude Code",
    "cols": 80,
    "rows": 24
  }
}
```

### Write to PTY
```json
{
  "type": "pty",
  "action": "write",
  "payload": {
    "sessionId": "session-uuid",
    "data": "claude --help\n"
  }
}
```

### Resize PTY
```json
{
  "type": "pty",
  "action": "resize",
  "payload": {
    "sessionId": "session-uuid",
    "cols": 120,
    "rows": 40
  }
}
```

## Voice Input (Wispr Flow)

The iOS app supports [Wispr Flow](https://wisprflow.ai) for voice dictation. Configure your API key in Settings.

Voice-transcribed text is sent to the active terminal with a source tag:
```json
{
  "type": "pty",
  "action": "write",
  "payload": {
    "sessionId": "session-uuid",
    "data": "transcribed voice command",
    "source": "wispr-flow"
  }
}
```

## Configuration

Config stored at: `~/Library/Application Support/personal-agent/config.json`

**Note**: Auth token is stored separately in macOS Keychain, not in the config file.

```json
{
  "connection": {
    "mode": "tailscale",
    "directPort": 9876,
    "restrictToTailscale": true
  },
  "services": [
    {
      "id": "claude-code",
      "name": "Claude Code Server",
      "command": "claude",
      "args": ["--server"],
      "autoStart": true,
      "restartOnFailure": true
    }
  ],
  "autoLaunch": true,
  "startMinimized": true
}
```

## File Structure

```
├── src/
│   ├── main/
│   │   ├── index.ts          # Main Electron process
│   │   ├── preload.ts        # IPC bridge
│   │   ├── ConfigStore.ts    # Config + Keychain storage
│   │   └── CertManager.ts    # TLS certificate management
│   ├── renderer/
│   │   └── index.html        # Desktop UI
│   ├── services/
│   │   ├── PTYManager.ts     # Terminal session management
│   │   ├── RemoteServer.ts   # WebSocket server (TLS)
│   │   ├── ServiceManager.ts # Background service management
│   │   └── TailscaleService.ts
│   └── shared/
│       └── types.ts          # Shared TypeScript types
├── ios-app/                  # iOS SwiftUI app
├── assets/                   # App icons
└── build/                    # Build configuration
```
