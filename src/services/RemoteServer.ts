import { WebSocketServer, WebSocket } from 'ws';
import { EventEmitter } from 'events';
import { createServer as createHttpServer, Server as HttpServer } from 'http';
import { createServer as createHttpsServer, Server as HttpsServer } from 'https';
import { v4 as uuidv4 } from 'uuid';
import { RemoteMessage, AuthPayload, PTYMessage } from '../shared/types';
import { PTYManager } from './PTYManager';
import { ServiceManager } from './ServiceManager';
import * as crypto from 'crypto';

export interface TLSCredentials {
  cert: string;
  key: string;
}

interface AuthenticatedClient {
  id: string;
  ws: WebSocket;
  deviceId: string;  // Persistent device identifier for reconnection
  deviceName: string;
  authenticatedAt: number;
  sessionSubscriptions: Set<string>;
  ownedSessions: Set<string>;  // Sessions this client created
  serviceSubscriptions: Set<string>;  // Services this client subscribes to
  isLocal: boolean;  // True if connected from localhost (trusted for full session access)
}

// Track session ownership by device ID so it persists across reconnects
const sessionOwnership: Map<string, string> = new Map();  // sessionId -> deviceId

export interface ServerOptions {
  port: number;
  authToken: string;
  ptyManager: PTYManager;
  serviceManager: ServiceManager;
  tlsCredentials?: TLSCredentials;
  restrictToTailscale?: boolean;  // If true, only allow connections from localhost or Tailscale range
}

export class RemoteServer extends EventEmitter {
  private server: HttpServer | HttpsServer;
  private wss: WebSocketServer;
  private clients: Map<string, AuthenticatedClient> = new Map();
  private authToken: string;
  private ptyManager: PTYManager;
  private serviceManager: ServiceManager;
  private useTLS: boolean;
  private restrictToTailscale: boolean;

  constructor(options: ServerOptions) {
    const { port, authToken, ptyManager, serviceManager, tlsCredentials, restrictToTailscale } = options;
    super();
    this.authToken = authToken;
    this.ptyManager = ptyManager;
    this.serviceManager = serviceManager;
    this.useTLS = !!tlsCredentials;
    this.restrictToTailscale = restrictToTailscale ?? false;

    if (this.restrictToTailscale) {
      console.log(`[RemoteServer] Restricting connections to localhost and Tailscale range (100.64.0.0/10)`);
    }

    // Create HTTPS server if TLS credentials provided, otherwise HTTP
    if (tlsCredentials) {
      this.server = createHttpsServer({
        cert: tlsCredentials.cert,
        key: tlsCredentials.key,
      });
      console.log('[RemoteServer] Using TLS (wss://)');
    } else {
      this.server = createHttpServer();
      console.log('[RemoteServer] Using plaintext (ws://) - NOT RECOMMENDED');
    }

    this.wss = new WebSocketServer({ server: this.server });

    this.setupPTYForwarding();
    this.setupServiceForwarding();
    this.setupWebSocket();

    this.server.listen(port, '0.0.0.0', () => {
      const protocol = this.useTLS ? 'wss' : 'ws';
      console.log(`Remote server listening on ${protocol}://0.0.0.0:${port}`);
      this.emit('listening', port);
    });
  }

  isUsingTLS(): boolean {
    return this.useTLS;
  }

  private setupWebSocket(): void {
    this.wss.on('connection', (ws, req) => {
      const clientId = uuidv4();
      const ip = req.socket.remoteAddress;

      // Check if connection is from allowed source
      if (this.restrictToTailscale && ip) {
        const normalizedIP = this.normalizeIP(ip);
        const isLocalhost = normalizedIP === '127.0.0.1' || normalizedIP === '::1';
        const isTailscale = this.isInTailscaleRange(normalizedIP);

        if (!isLocalhost && !isTailscale) {
          console.log(`[RemoteServer] Rejected connection from ${ip} (not localhost or Tailscale)`);
          ws.close(4000, 'Connection not allowed from this address');
          return;
        }
      }

      console.log(`New connection from ${ip}, awaiting auth...`);

      // Require authentication within 10 seconds
      const authTimeout = setTimeout(() => {
        if (!this.clients.has(clientId)) {
          ws.close(4001, 'Authentication timeout');
        }
      }, 10000);

      // Track whether this is a local connection for session sharing
      const normalizedIP = ip ? this.normalizeIP(ip) : '';
      const isLocal = normalizedIP === '127.0.0.1' || normalizedIP === '::1';

      ws.on('message', (data) => {
        try {
          const message: RemoteMessage = JSON.parse(data.toString());
          this.handleMessage(clientId, ws, message, authTimeout, isLocal);
        } catch (error) {
          this.sendError(ws, 'Invalid message format');
        }
      });

      ws.on('close', () => {
        const client = this.clients.get(clientId);
        if (client) {
          console.log(`Client ${client.deviceName} disconnected`);
          this.clients.delete(clientId);
          this.emit('client:disconnected', clientId);
        }
      });

      ws.on('error', (error) => {
        console.error(`WebSocket error for client ${clientId}:`, error);
      });
    });
  }

  private handleMessage(
    clientId: string,
    ws: WebSocket,
    message: RemoteMessage,
    authTimeout?: NodeJS.Timeout,
    isLocal?: boolean
  ): void {
    // Handle authentication
    if (message.type === 'auth') {
      this.handleAuth(clientId, ws, message.payload as AuthPayload, message.requestId, authTimeout, isLocal);
      return;
    }

    // All other messages require authentication
    const client = this.clients.get(clientId);
    if (!client) {
      this.sendError(ws, 'Not authenticated');
      return;
    }

    switch (message.type) {
      case 'pty':
        this.handlePTYMessage(client, message);
        break;
      case 'service':
        this.handleServiceMessage(client, message);
        break;
      case 'system':
        this.handleSystemMessage(client, message);
        break;
      default:
        this.sendError(ws, `Unknown message type: ${message.type}`);
    }
  }

  private handleAuth(
    clientId: string,
    ws: WebSocket,
    payload: AuthPayload,
    requestId?: string,
    authTimeout?: NodeJS.Timeout,
    isLocal?: boolean
  ): void {
    // Constant-time comparison to prevent timing attacks
    const tokenBuffer = Buffer.from(this.authToken);
    const payloadBuffer = Buffer.from(payload.token);

    if (tokenBuffer.length !== payloadBuffer.length ||
        !crypto.timingSafeEqual(tokenBuffer, payloadBuffer)) {
      ws.close(4003, 'Invalid authentication token');
      return;
    }

    if (authTimeout) {
      clearTimeout(authTimeout);
    }

    // Use payload.clientId as persistent device identifier for session ownership
    const deviceId = payload.clientId || clientId;

    // Restore owned sessions for reconnecting devices
    const ownedSessions = new Set<string>();
    for (const [sessionId, ownerId] of sessionOwnership.entries()) {
      if (ownerId === deviceId) {
        ownedSessions.add(sessionId);
      }
    }

    const client: AuthenticatedClient = {
      id: clientId,
      ws,
      deviceId,
      deviceName: payload.deviceName,
      authenticatedAt: Date.now(),
      sessionSubscriptions: new Set(ownedSessions),  // Auto-subscribe to owned sessions
      ownedSessions,
      serviceSubscriptions: new Set(),
      isLocal: isLocal ?? false,
    };

    this.clients.set(clientId, client);
    console.log(`Client ${payload.deviceName} authenticated (deviceId: ${deviceId}, restored ${ownedSessions.size} sessions)`);

    // Local clients get all sessions; remote clients get only their owned sessions
    const deviceSessions = client.isLocal
      ? this.ptyManager.getAllSessions()
      : this.ptyManager.getAllSessions().filter(
          (s) => sessionOwnership.get(s.id) === deviceId
        );

    this.send(ws, {
      type: 'auth',
      action: 'success',
      payload: {
        clientId,
        sessions: deviceSessions,
        services: this.serviceManager.getAllStatuses(),
      },
      requestId,
    });

    this.emit('client:authenticated', client);
  }

  private canAccessSession(client: AuthenticatedClient, sessionId: string): boolean {
    // Local clients (e.g. VS Code extension on same machine) can access all sessions
    if (client.isLocal) return true;
    return client.ownedSessions.has(sessionId) || client.sessionSubscriptions.has(sessionId);
  }

  private handlePTYMessage(client: AuthenticatedClient, message: RemoteMessage): void {
    const { action, payload, requestId } = message;

    switch (action) {
      case 'create': {
        const session = this.ptyManager.createSession(payload as Record<string, unknown>);
        client.sessionSubscriptions.add(session.id);
        client.ownedSessions.add(session.id);
        // Track ownership globally so it persists across reconnects
        sessionOwnership.set(session.id, client.deviceId);
        this.send(client.ws, {
          type: 'pty',
          action: 'created',
          payload: session,
          requestId,
        });
        break;
      }
      case 'write': {
        const { sessionId, data } = payload as { sessionId: string; data: string };
        if (!this.canAccessSession(client, sessionId)) {
          this.sendError(client.ws, `Access denied: You don't have permission to write to session ${sessionId}`);
          return;
        }
        this.ptyManager.write(sessionId, data);
        break;
      }
      case 'resize': {
        const { sessionId, cols, rows } = payload as PTYMessage;
        if (sessionId && cols && rows) {
          if (!this.canAccessSession(client, sessionId)) {
            this.sendError(client.ws, `Access denied: You don't have permission to resize session ${sessionId}`);
            return;
          }
          this.ptyManager.resize(sessionId, cols, rows);
        }
        break;
      }
      case 'close': {
        const { sessionId } = payload as { sessionId: string };
        if (!this.canAccessSession(client, sessionId)) {
          this.sendError(client.ws, `Access denied: You don't have permission to close session ${sessionId}`);
          return;
        }
        this.ptyManager.closeSession(sessionId);
        client.sessionSubscriptions.delete(sessionId);
        client.ownedSessions.delete(sessionId);
        sessionOwnership.delete(sessionId);
        break;
      }
      case 'subscribe': {
        const { sessionId } = payload as { sessionId: string };
        // Local clients can subscribe to any session; remote clients must own it
        if (!client.isLocal && sessionOwnership.get(sessionId) !== client.deviceId) {
          this.sendError(client.ws, `Access denied: You don't own session ${sessionId}`);
          return;
        }
        client.sessionSubscriptions.add(sessionId);
        if (sessionOwnership.get(sessionId) === client.deviceId) {
          client.ownedSessions.add(sessionId);  // Also restore to local set
        }
        break;
      }
      case 'unsubscribe': {
        const { sessionId } = payload as { sessionId: string };
        client.sessionSubscriptions.delete(sessionId);
        break;
      }
      case 'list': {
        // Local clients see all sessions; remote clients see only owned/subscribed
        const accessibleSessions = client.isLocal
          ? this.ptyManager.getAllSessions()
          : this.ptyManager.getAllSessions().filter(
              (session) => client.ownedSessions.has(session.id) || client.sessionSubscriptions.has(session.id)
            );
        this.send(client.ws, {
          type: 'pty',
          action: 'list',
          payload: accessibleSessions,
          requestId,
        });
        break;
      }
    }
  }

  private handleServiceMessage(client: AuthenticatedClient, message: RemoteMessage): void {
    const { action, payload, requestId } = message;

    switch (action) {
      case 'start': {
        const { serviceId } = payload as { serviceId: string };
        this.serviceManager.startService(serviceId).then(() => {
          this.send(client.ws, {
            type: 'service',
            action: 'started',
            payload: this.serviceManager.getStatus(serviceId),
            requestId,
          });
        });
        break;
      }
      case 'stop': {
        const { serviceId } = payload as { serviceId: string };
        this.serviceManager.stopService(serviceId).then(() => {
          this.send(client.ws, {
            type: 'service',
            action: 'stopped',
            payload: this.serviceManager.getStatus(serviceId),
            requestId,
          });
        });
        break;
      }
      case 'restart': {
        const { serviceId } = payload as { serviceId: string };
        this.serviceManager.restartService(serviceId).then(() => {
          this.send(client.ws, {
            type: 'service',
            action: 'restarted',
            payload: this.serviceManager.getStatus(serviceId),
            requestId,
          });
        });
        break;
      }
      case 'list': {
        this.send(client.ws, {
          type: 'service',
          action: 'list',
          payload: this.serviceManager.getAllStatuses(),
          requestId,
        });
        break;
      }
      case 'subscribe': {
        const { serviceId } = payload as { serviceId: string };
        // Verify service exists before allowing subscription
        if (!this.serviceManager.getStatus(serviceId)) {
          this.sendError(client.ws, `Service ${serviceId} not found`);
          return;
        }
        client.serviceSubscriptions.add(serviceId);
        break;
      }
      case 'unsubscribe': {
        const { serviceId } = payload as { serviceId: string };
        client.serviceSubscriptions.delete(serviceId);
        break;
      }
    }
  }

  private handleSystemMessage(client: AuthenticatedClient, message: RemoteMessage): void {
    const { action, requestId } = message;

    switch (action) {
      case 'ping': {
        this.send(client.ws, {
          type: 'system',
          action: 'pong',
          payload: { timestamp: Date.now() },
          requestId,
        });
        break;
      }
      case 'info': {
        this.send(client.ws, {
          type: 'system',
          action: 'info',
          payload: {
            platform: process.platform,
            arch: process.arch,
            nodeVersion: process.version,
            uptime: process.uptime(),
            memory: process.memoryUsage(),
          },
          requestId,
        });
        break;
      }
    }
  }

  private setupPTYForwarding(): void {
    this.ptyManager.on('data', ({ sessionId, data }) => {
      this.broadcastToSubscribers(sessionId, {
        type: 'pty',
        action: 'data',
        payload: { sessionId, data },
      });
    });

    this.ptyManager.on('exit', ({ sessionId, exitCode, signal }) => {
      // Clean up global ownership tracking
      sessionOwnership.delete(sessionId);

      // Only notify subscribers, not all clients
      this.broadcastToSubscribers(sessionId, {
        type: 'pty',
        action: 'exit',
        payload: { sessionId, exitCode, signal },
      });
    });
  }

  private setupServiceForwarding(): void {
    this.serviceManager.on('service:status', (status) => {
      // Broadcast status to all clients for backward compatibility
      this.broadcast({
        type: 'service',
        action: 'status',
        payload: status,
      });
    });

    this.serviceManager.on('service:output', (output) => {
      // Only send output to subscribed clients
      this.broadcastToServiceSubscribers((output as { id: string }).id, {
        type: 'service',
        action: 'output',
        payload: output,
      });
    });
  }

  private send(ws: WebSocket, message: RemoteMessage): void {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(message));
    }
  }

  private sendError(ws: WebSocket, error: string): void {
    this.send(ws, {
      type: 'system',
      action: 'error',
      payload: { error },
    });
  }

  private broadcast(message: RemoteMessage): void {
    for (const client of this.clients.values()) {
      this.send(client.ws, message);
    }
  }

  private broadcastToSubscribers(sessionId: string, message: RemoteMessage): void {
    for (const client of this.clients.values()) {
      if (client.sessionSubscriptions.has(sessionId)) {
        this.send(client.ws, message);
      }
    }
  }

  private broadcastToServiceSubscribers(serviceId: string, message: RemoteMessage): void {
    for (const client of this.clients.values()) {
      if (client.serviceSubscriptions.has(serviceId)) {
        this.send(client.ws, message);
      }
    }
  }

  getConnectedClients(): Array<{ id: string; deviceName: string; authenticatedAt: number }> {
    return Array.from(this.clients.values()).map((c) => ({
      id: c.id,
      deviceName: c.deviceName,
      authenticatedAt: c.authenticatedAt,
    }));
  }

  private normalizeIP(ip: string): string {
    // Handle IPv6-mapped IPv4 addresses (e.g., ::ffff:127.0.0.1 -> 127.0.0.1)
    if (ip.startsWith('::ffff:')) {
      return ip.substring(7);
    }
    return ip;
  }

  private isInTailscaleRange(ip: string): boolean {
    // Tailscale uses CGNAT range 100.64.0.0/10 (100.64.0.0 - 100.127.255.255)
    const normalized = this.normalizeIP(ip);
    const parts = normalized.split('.').map(Number);
    if (parts.length !== 4) return false;
    // Check if IP is in 100.64.0.0/10 range
    return parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
  }

  close(): void {
    for (const client of this.clients.values()) {
      client.ws.close();
    }
    this.wss.close();
    this.server.close();
  }
}
