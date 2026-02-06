import WebSocket from 'ws';
import { EventEmitter } from 'events';
import * as crypto from 'crypto';

function uuidv4(): string {
  return crypto.randomUUID();
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

export interface RemoteMessage {
  type: 'auth' | 'pty' | 'service' | 'system';
  action: string;
  payload: any;
  requestId?: string;
}

export interface ConnectOptions {
  host: string;
  port: number;
  authToken: string;
  useTLS: boolean;
  rejectUnauthorized: boolean;
  deviceName: string;
}

/**
 * WebSocket client that connects to the Personal Agent's RemoteServer.
 *
 * Events:
 *   connected(sessions: PTYSession[]) - authenticated and ready
 *   disconnected()
 *   error(err: Error)
 *   pty:data(sessionId: string, data: string)
 *   pty:exit(sessionId: string, exitCode: number, signal: number)
 *   pty:created(session: PTYSession)
 */
export class AgentClient extends EventEmitter {
  private ws: WebSocket | null = null;
  private deviceId: string;
  private pendingRequests: Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }> = new Map();
  private reconnectTimer: NodeJS.Timeout | null = null;
  private _connected = false;
  private connectOptions: ConnectOptions | null = null;

  constructor() {
    super();
    this.deviceId = uuidv4();
  }

  get connected(): boolean {
    return this._connected;
  }

  connect(options: ConnectOptions): void {
    this.connectOptions = options;
    this.doConnect(options);
  }

  private doConnect(options: ConnectOptions): void {
    const protocol = options.useTLS ? 'wss' : 'ws';
    const url = `${protocol}://${options.host}:${options.port}`;

    this.ws = new WebSocket(url, {
      rejectUnauthorized: options.rejectUnauthorized,
    });

    this.ws.on('open', () => {
      this.send({
        type: 'auth',
        action: 'authenticate',
        payload: {
          token: options.authToken,
          clientId: this.deviceId,
          deviceName: options.deviceName,
        },
      });
    });

    this.ws.on('message', (data) => {
      try {
        const message: RemoteMessage = JSON.parse(data.toString());
        this.handleMessage(message);
      } catch {
        // ignore parse errors
      }
    });

    this.ws.on('close', () => {
      const wasConnected = this._connected;
      this._connected = false;
      this.ws = null;
      if (wasConnected) {
        this.emit('disconnected');
      }
    });

    this.ws.on('error', (err) => {
      this.emit('error', err);
    });
  }

  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.connectOptions = null;
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this._connected = false;
  }

  private handleMessage(message: RemoteMessage): void {
    // Handle request/response pattern
    if (message.requestId && this.pendingRequests.has(message.requestId)) {
      const pending = this.pendingRequests.get(message.requestId)!;
      this.pendingRequests.delete(message.requestId);
      pending.resolve(message.payload);
      return;
    }

    if (message.type === 'auth' && message.action === 'success') {
      this._connected = true;
      const sessions: PTYSession[] = message.payload?.sessions || [];
      this.emit('connected', sessions);
      return;
    }

    if (message.type === 'system' && message.action === 'error') {
      this.emit('error', new Error(message.payload?.error || 'Unknown error'));
      return;
    }

    if (message.type === 'pty') {
      switch (message.action) {
        case 'data': {
          const { sessionId, data } = message.payload;
          this.emit('pty:data', sessionId, data);
          break;
        }
        case 'exit': {
          const { sessionId, exitCode, signal } = message.payload;
          this.emit('pty:exit', sessionId, exitCode, signal);
          break;
        }
        case 'created': {
          this.emit('pty:created', message.payload as PTYSession);
          break;
        }
      }
    }
  }

  private send(message: RemoteMessage): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    }
  }

  private request(message: Omit<RemoteMessage, 'requestId'>): Promise<any> {
    return new Promise((resolve, reject) => {
      const requestId = uuidv4();
      this.pendingRequests.set(requestId, { resolve, reject });
      this.send({ ...message, requestId });

      // Timeout after 10 seconds
      setTimeout(() => {
        if (this.pendingRequests.has(requestId)) {
          this.pendingRequests.delete(requestId);
          reject(new Error('Request timed out'));
        }
      }, 10000);
    });
  }

  async listSessions(): Promise<PTYSession[]> {
    return this.request({
      type: 'pty',
      action: 'list',
      payload: {},
    });
  }

  async createSession(options: {
    name?: string;
    cols?: number;
    rows?: number;
    cwd?: string;
  } = {}): Promise<PTYSession> {
    return this.request({
      type: 'pty',
      action: 'create',
      payload: options,
    });
  }

  subscribe(sessionId: string): void {
    this.send({
      type: 'pty',
      action: 'subscribe',
      payload: { sessionId },
    });
  }

  unsubscribe(sessionId: string): void {
    this.send({
      type: 'pty',
      action: 'unsubscribe',
      payload: { sessionId },
    });
  }

  writeToSession(sessionId: string, data: string): void {
    this.send({
      type: 'pty',
      action: 'write',
      payload: { sessionId, data },
    });
  }

  resizeSession(sessionId: string, cols: number, rows: number): void {
    this.send({
      type: 'pty',
      action: 'resize',
      payload: { sessionId, cols, rows },
    });
  }

  closeSession(sessionId: string): void {
    this.send({
      type: 'pty',
      action: 'close',
      payload: { sessionId },
    });
  }
}
