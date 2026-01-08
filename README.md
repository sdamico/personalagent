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
- **Token Auth**: Secure authentication between iOS app and agent

## Architecture

```
iOS App ──(WebSocket)──► Tailscale ──► Personal Agent (Mac Mini)
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

3. For development with hot reload:
   ```bash
   npm run dev
   ```

4. Build distributable:
   ```bash
   npm run dist:mac
   ```

## iOS App Connection

1. Ensure both devices are on the same Tailscale network
2. Get the Mac Mini's Tailscale IP (e.g., `100.x.x.x`)
3. Copy the auth token from the agent (tray menu → Copy Auth Token)
4. Connect from iOS app to `ws://100.x.x.x:9876`
5. Authenticate with the token

## WebSocket Protocol

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
    "rows": 24,
    "shell": "/bin/zsh"
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

The iOS app natively supports [Wispr Flow API](https://wispr.com) for voice dictation. Transcribed text is sent directly to the active PTY session:

```json
{
  "type": "pty",
  "action": "write",
  "payload": {
    "sessionId": "session-uuid",
    "data": "transcribed voice command here",
    "source": "wispr-flow"
  }
}
```

This enables hands-free interaction with Claude Code and other terminal sessions.

## Configuration

Config is stored in:
- macOS: `~/Library/Application Support/personal-agent/config.json`

Example config:
```json
{
  "connection": {
    "mode": "tailscale",
    "directPort": 9876,
    "authToken": "auto-generated"
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

## Security

- Auth tokens are generated using cryptographically secure random bytes
- Token comparison uses constant-time comparison to prevent timing attacks
- All connections require authentication within 10 seconds
- Tailscale provides end-to-end encrypted networking
