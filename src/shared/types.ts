// Shared types for Personal Agent

export interface ServiceConfig {
  id: string;
  name: string;
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  autoStart: boolean;
  restartOnFailure: boolean;
}

export interface ServiceStatus {
  id: string;
  name: string;
  status: 'stopped' | 'starting' | 'running' | 'error';
  pid?: number;
  uptime?: number;
  lastError?: string;
}

export interface PTYSession {
  id: string;
  name: string;
  cols: number;
  rows: number;
  cwd: string;
  shell: string;
  createdAt: number;
}

export interface PTYMessage {
  type: 'data' | 'resize' | 'close';
  sessionId: string;
  data?: string;
  cols?: number;
  rows?: number;
}

export interface RemoteMessage {
  type: 'auth' | 'pty' | 'service' | 'system';
  action: string;
  payload: unknown;
  requestId?: string;
}

export interface AuthPayload {
  token: string;
  clientId: string;
  deviceName: string;
}

export interface ConnectionConfig {
  mode: 'tailscale' | 'relay' | 'direct';
  tailscaleIp?: string;
  relayUrl?: string;
  directPort?: number;
  authToken?: string; // Optional - stored in Keychain instead of JSON
  restrictToTailscale?: boolean; // Only allow connections from localhost and Tailscale IP (default: true)
}

export interface AgentConfig {
  connection: ConnectionConfig;
  services: ServiceConfig[];
  autoLaunch: boolean;
  startMinimized: boolean;
}

export const DEFAULT_CONFIG: AgentConfig = {
  connection: {
    mode: 'tailscale',
    directPort: 9876,
    authToken: '',
    restrictToTailscale: true,
  },
  services: [],
  autoLaunch: true,
  startMinimized: true,
};

export interface TailscaleStatus {
  installed: boolean;
  running: boolean;
  loggedIn: boolean;
  ip: string | null;
  hostname: string | null;
  error?: string;
}

export interface PairingInfo {
  host: string;
  port: number;
  token: string;
  certFingerprint?: string;  // SHA-256 fingerprint for TLS pinning
}
