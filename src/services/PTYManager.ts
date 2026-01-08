import * as pty from 'node-pty';
import { EventEmitter } from 'events';
import { v4 as uuidv4 } from 'uuid';
import { PTYSession, PTYMessage } from '../shared/types';
import * as os from 'os';

// Only absolute paths allowed - short names could be exploited via PATH manipulation
const ALLOWED_SHELLS = [
  '/bin/zsh',
  '/bin/bash',
  '/bin/sh',
  '/usr/bin/zsh',
  '/usr/bin/bash',
  '/usr/local/bin/zsh',
  '/usr/local/bin/bash',
];

interface ManagedPTY {
  session: PTYSession;
  pty: pty.IPty;
}

export class PTYManager extends EventEmitter {
  private sessions: Map<string, ManagedPTY> = new Map();
  private defaultShell: string;

  constructor() {
    super();
    this.defaultShell = process.env.SHELL || (os.platform() === 'win32' ? 'powershell.exe' : '/bin/zsh');
  }

  createSession(options: {
    name?: string;
    cols?: number;
    rows?: number;
    cwd?: string;
    shell?: string;
    env?: Record<string, string>;
  } = {}): PTYSession {
    const id = uuidv4();

    // Validate shell option
    let shell = options.shell || this.defaultShell;
    if (options.shell && !this.isValidShell(options.shell)) {
      console.warn(`[PTYManager] Invalid shell "${options.shell}" rejected. Using default shell instead.`);
      shell = this.defaultShell;
    }

    // Validate cwd option
    let cwd = options.cwd || process.env.HOME || '/';
    if (options.cwd && !this.isValidCwd(options.cwd)) {
      console.warn(`[PTYManager] Invalid cwd "${options.cwd}" rejected. Using home directory instead.`);
      cwd = process.env.HOME || '/';
    }

    const session: PTYSession = {
      id,
      name: options.name || `Terminal ${this.sessions.size + 1}`,
      cols: options.cols || 80,
      rows: options.rows || 24,
      cwd,
      shell,
      createdAt: Date.now(),
    };

    const ptyProcess = pty.spawn(session.shell, [], {
      name: 'xterm-256color',
      cols: session.cols,
      rows: session.rows,
      cwd: session.cwd,
      env: {
        ...process.env,
        ...options.env,
        TERM: 'xterm-256color',
        COLORTERM: 'truecolor',
      } as Record<string, string>,
    });

    ptyProcess.onData((data) => {
      this.emit('data', { sessionId: id, data });
    });

    ptyProcess.onExit(({ exitCode, signal }) => {
      this.emit('exit', { sessionId: id, exitCode, signal });
      this.sessions.delete(id);
    });

    this.sessions.set(id, { session, pty: ptyProcess });
    this.emit('session:created', session);

    return session;
  }

  write(sessionId: string, data: string): void {
    const managed = this.sessions.get(sessionId);
    if (managed) {
      managed.pty.write(data);
    }
  }

  resize(sessionId: string, cols: number, rows: number): void {
    const managed = this.sessions.get(sessionId);
    if (managed) {
      managed.pty.resize(cols, rows);
      managed.session.cols = cols;
      managed.session.rows = rows;
    }
  }

  closeSession(sessionId: string): void {
    const managed = this.sessions.get(sessionId);
    if (managed) {
      managed.pty.kill();
      this.sessions.delete(sessionId);
      this.emit('session:closed', sessionId);
    }
  }

  getSession(sessionId: string): PTYSession | undefined {
    return this.sessions.get(sessionId)?.session;
  }

  getAllSessions(): PTYSession[] {
    return Array.from(this.sessions.values()).map((m) => m.session);
  }

  handleMessage(message: PTYMessage): void {
    switch (message.type) {
      case 'data':
        if (message.data) {
          this.write(message.sessionId, message.data);
        }
        break;
      case 'resize':
        if (message.cols && message.rows) {
          this.resize(message.sessionId, message.cols, message.rows);
        }
        break;
      case 'close':
        this.closeSession(message.sessionId);
        break;
    }
  }

  closeAll(): void {
    for (const [id] of this.sessions) {
      this.closeSession(id);
    }
  }

  private isValidShell(shell: string): boolean {
    return ALLOWED_SHELLS.includes(shell);
  }

  private isValidCwd(cwd: string): boolean {
    // Reject path traversal attempts
    if (cwd.includes('..')) return false;
    // Must be absolute path
    return cwd.startsWith('/');
  }
}
