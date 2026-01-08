# Security Fixes Task List

## Overview
Fix critical security issues identified in the security review. Each task is independent and can be worked on in parallel.

---

## Task 1: Mac Token Storage - Use macOS Keychain
**Files**: `src/main/ConfigStore.ts`, `package.json`
**Priority**: Critical

### Current State
- Auth token stored in plaintext JSON at `~/Library/Application Support/personal-agent/config.json`

### Required Changes
1. Install `keytar` package for native Keychain access
2. Modify `ConfigStore.ts` to:
   - Store auth token in macOS Keychain using service name `com.personal-agent`
   - Keep other config (port, autoLaunch, etc.) in JSON file
   - Migrate existing plaintext tokens to Keychain on first run
3. Update `getAuthToken()` and `regenerateAuthToken()` to use Keychain

### Keytar API
```typescript
import * as keytar from 'keytar';
await keytar.setPassword('com.personal-agent', 'authToken', token);
const token = await keytar.getPassword('com.personal-agent', 'authToken');
```

---

## Task 2: Shell Path Validation - Prevent Command Injection
**Files**: `src/services/PTYManager.ts`
**Priority**: Critical

### Current State
- Client can specify arbitrary shell path in `createSession()` options

### Required Changes
1. Add whitelist of allowed shells at top of file:
```typescript
const ALLOWED_SHELLS = ['/bin/zsh', '/bin/bash', '/bin/sh', '/usr/bin/zsh', '/usr/bin/bash'];
```
2. In `createSession()`, validate shell option:
   - If `options.shell` provided but not in whitelist, use `this.defaultShell`
   - Log warning when rejecting invalid shell
3. Also validate `cwd` is a real directory path (no path traversal)

---

## Task 3: iOS Wispr Flow API Key - Move to Keychain
**Files**: `ios-app/PersonalAgent/Sources/Services/VoiceInputManager.swift`
**Priority**: Critical

### Current State
- API key stored in UserDefaults (unencrypted)

### Required Changes
1. Update `wisprFlowAPIKey` property to use `KeychainHelper`:
```swift
var wisprFlowAPIKey: String? {
    get { KeychainHelper.readString(service: "com.personalagent.app", account: "wisprFlowAPIKey") }
    set {
        if let value = newValue {
            try? KeychainHelper.saveString(value, service: "com.personalagent.app", account: "wisprFlowAPIKey")
        } else {
            KeychainHelper.delete(service: "com.personalagent.app", account: "wisprFlowAPIKey")
        }
    }
}
```
2. Add convenience property to `KeychainHelper` extension for Wispr API key

---

## Task 4: TLS with Self-Signed Cert in QR Code
**Files**:
- `src/main/index.ts`
- `src/main/CertManager.ts` (new)
- `src/services/RemoteServer.ts`
- `src/main/preload.ts`
- `ios-app/PersonalAgent/Sources/Services/AgentConnection.swift`
- `ios-app/PersonalAgent/Sources/Models/Session.swift`
- `ios-app/PersonalAgent/Sources/Views/QRScannerView.swift`

**Priority**: High

### Current State
- WebSocket uses `ws://` (unencrypted)
- QR code contains `{host, port, token}`

### Required Changes

#### Mac Agent Side
1. Create `CertManager.ts`:
   - Generate self-signed cert on first run using Node's `crypto` module
   - Store cert and private key in app data directory
   - Cert should be valid for Tailscale IP and localhost
   - Export function to get cert fingerprint (SHA-256)

2. Update `RemoteServer.ts`:
   - Use `https.createServer()` with cert instead of `http.createServer()`
   - WebSocket server attaches to HTTPS server

3. Update QR code generation:
   - Include cert fingerprint in pairing info: `{host, port, token, certFingerprint}`

#### iOS Side
1. Update `PairingInfo` model to include `certFingerprint: String`

2. Update `AgentConnection.swift`:
   - Use `wss://` instead of `ws://`
   - Implement `URLSessionDelegate` for SSL pinning
   - In `urlSession(_:didReceive:completionHandler:)`, validate server cert fingerprint matches QR code

3. Store cert fingerprint in Keychain alongside host/port/token

### Cert Generation (Node.js)
```typescript
import { generateKeyPairSync, createSign } from 'crypto';
import forge from 'node-forge'; // May need this for easier X.509 cert creation
```

---

## Task 5: Session-Level Authorization
**Files**: `src/services/RemoteServer.ts`
**Priority**: Medium

### Current State
- Any authenticated client can write to any PTY session
- Service output broadcasts to all clients

### Required Changes
1. Track session ownership in `AuthenticatedClient`:
```typescript
interface AuthenticatedClient {
  // ... existing fields
  ownedSessions: Set<string>;  // Sessions this client created
}
```

2. In `handlePTYMessage()`:
   - For `write`, `resize`, `close`: verify client owns session OR is subscribed
   - Add session to `ownedSessions` when client creates it

3. In `setupServiceForwarding()`:
   - Only send service output to clients who have subscribed to that service
   - Add service subscription tracking similar to session subscriptions

4. Add `subscribe` action for services

---

## Execution Order
Tasks 1, 2, 3, 5 are independent - can run in parallel.
Task 4 (TLS) is larger and should be done after 1-3 complete.
