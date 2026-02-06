import * as vscode from 'vscode';
import { AgentClient, PTYSession } from './AgentClient';

/**
 * Bridges Personal Agent PTY sessions to VS Code terminal instances.
 *
 * Each agent PTY session maps to a VS Code pseudoterminal that relays
 * I/O over the WebSocket connection.
 */
export class TerminalManager implements vscode.Disposable {
  // Maps agent session ID -> VS Code terminal
  private terminals: Map<string, vscode.Terminal> = new Map();
  // Maps agent session ID -> pseudoterminal write emitter
  private writeEmitters: Map<string, vscode.EventEmitter<string>> = new Map();
  private disposables: vscode.Disposable[] = [];

  constructor(private client: AgentClient) {
    // Listen for PTY data from the agent
    client.on('pty:data', (sessionId: string, data: string) => {
      const emitter = this.writeEmitters.get(sessionId);
      if (emitter) {
        emitter.fire(data);
      }
    });

    // Listen for PTY exit from the agent
    client.on('pty:exit', (sessionId: string) => {
      const emitter = this.writeEmitters.get(sessionId);
      if (emitter) {
        // Signal terminal close
        emitter.fire('\r\n[Session ended]\r\n');
      }
      this.cleanup(sessionId);
    });
  }

  /**
   * Attach to an existing agent PTY session and open it as a VS Code terminal.
   */
  attachToSession(session: PTYSession): vscode.Terminal {
    // If we already have a terminal for this session, show it
    const existing = this.terminals.get(session.id);
    if (existing) {
      existing.show();
      return existing;
    }

    // Subscribe to session data
    this.client.subscribe(session.id);

    // Create a pseudoterminal
    const writeEmitter = new vscode.EventEmitter<string>();
    const closeEmitter = new vscode.EventEmitter<number | void>();

    const pty: vscode.Pseudoterminal = {
      onDidWrite: writeEmitter.event,
      onDidClose: closeEmitter.event,

      open: (initialDimensions) => {
        if (initialDimensions) {
          this.client.resizeSession(
            session.id,
            initialDimensions.columns,
            initialDimensions.rows
          );
        }
      },

      close: () => {
        this.client.unsubscribe(session.id);
        this.cleanup(session.id);
      },

      handleInput: (data: string) => {
        this.client.writeToSession(session.id, data);
      },

      setDimensions: (dimensions) => {
        this.client.resizeSession(session.id, dimensions.columns, dimensions.rows);
      },
    };

    const terminal = vscode.window.createTerminal({
      name: `🔗 ${session.name}`,
      pty,
    });

    this.terminals.set(session.id, terminal);
    this.writeEmitters.set(session.id, writeEmitter);

    // Track disposal
    const disposable = vscode.window.onDidCloseTerminal((t) => {
      if (t === terminal) {
        this.client.unsubscribe(session.id);
        this.cleanup(session.id);
        disposable.dispose();
      }
    });
    this.disposables.push(disposable);

    terminal.show();
    return terminal;
  }

  /**
   * Create a new shared terminal (creates a PTY on the agent and opens it in VS Code).
   */
  async createSharedTerminal(name?: string): Promise<vscode.Terminal> {
    const session = await this.client.createSession({
      name: name || 'Shared Terminal',
      cols: 120,
      rows: 30,
    });

    return this.attachToSession(session);
  }

  /**
   * Show a quick-pick of available sessions and attach to the selected one.
   */
  async showSessionPicker(): Promise<void> {
    const sessions = await this.client.listSessions();

    if (sessions.length === 0) {
      const action = await vscode.window.showInformationMessage(
        'No active terminal sessions on the agent.',
        'Create New'
      );
      if (action === 'Create New') {
        await this.createSharedTerminal();
      }
      return;
    }

    const items = sessions.map((s) => ({
      label: s.name,
      description: `${s.shell} · ${s.cwd}`,
      detail: `Created ${new Date(s.createdAt).toLocaleTimeString()}`,
      session: s,
    }));

    const selected = await vscode.window.showQuickPick(items, {
      placeHolder: 'Select a terminal session to attach to',
    });

    if (selected) {
      this.attachToSession(selected.session);
    }
  }

  /**
   * Sync all sessions from the agent - attach to any new ones, clean up stale ones.
   */
  async syncSessions(sessions: PTYSession[]): Promise<void> {
    // Auto-subscribe to all sessions so we receive their output
    for (const session of sessions) {
      if (!this.terminals.has(session.id)) {
        this.client.subscribe(session.id);
      }
    }
  }

  getAttachedSessionIds(): string[] {
    return Array.from(this.terminals.keys());
  }

  private cleanup(sessionId: string): void {
    this.writeEmitters.delete(sessionId);
    this.terminals.delete(sessionId);
  }

  dispose(): void {
    for (const emitter of this.writeEmitters.values()) {
      emitter.dispose();
    }
    for (const d of this.disposables) {
      d.dispose();
    }
    this.writeEmitters.clear();
    this.terminals.clear();
    this.disposables = [];
  }
}
