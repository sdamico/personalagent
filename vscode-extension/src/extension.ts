import * as vscode from 'vscode';
import { AgentClient } from './AgentClient';
import { TerminalManager } from './TerminalManager';

let client: AgentClient | null = null;
let terminalManager: TerminalManager | null = null;
let statusBarItem: vscode.StatusBarItem;

export function activate(context: vscode.ExtensionContext) {
  // Status bar indicator
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  statusBarItem.command = 'personalAgent.listTerminals';
  setDisconnectedStatus();
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  // Register commands
  context.subscriptions.push(
    vscode.commands.registerCommand('personalAgent.connect', connectToAgent),
    vscode.commands.registerCommand('personalAgent.disconnect', disconnectFromAgent),
    vscode.commands.registerCommand('personalAgent.listTerminals', listTerminals),
    vscode.commands.registerCommand('personalAgent.attachTerminal', attachTerminal),
    vscode.commands.registerCommand('personalAgent.createTerminal', createTerminal),
  );

  // Auto-connect if configured
  const config = vscode.workspace.getConfiguration('personalAgent');
  if (config.get<boolean>('autoConnect') && config.get<string>('authToken')) {
    connectToAgent();
  }
}

async function connectToAgent(): Promise<void> {
  if (client?.connected) {
    vscode.window.showInformationMessage('Already connected to Personal Agent.');
    return;
  }

  const config = vscode.workspace.getConfiguration('personalAgent');
  const host = config.get<string>('host') || '127.0.0.1';
  const port = config.get<number>('port') || 9876;
  const authToken = config.get<string>('authToken') || '';
  const useTLS = config.get<boolean>('useTLS') ?? true;
  const rejectUnauthorized = config.get<boolean>('rejectUnauthorized') ?? false;

  if (!authToken) {
    const token = await vscode.window.showInputBox({
      prompt: 'Enter your Personal Agent auth token',
      password: true,
      placeHolder: 'Paste the auth token from your Personal Agent tray menu',
    });
    if (!token) return;

    // Save the token to settings
    await config.update('authToken', token, vscode.ConfigurationTarget.Global);
    return connectWithToken(host, port, token, useTLS, rejectUnauthorized);
  }

  return connectWithToken(host, port, authToken, useTLS, rejectUnauthorized);
}

function connectWithToken(
  host: string,
  port: number,
  authToken: string,
  useTLS: boolean,
  rejectUnauthorized: boolean
): void {
  // Clean up previous connection
  if (client) {
    client.disconnect();
  }
  if (terminalManager) {
    terminalManager.dispose();
  }

  client = new AgentClient();
  terminalManager = new TerminalManager(client);

  statusBarItem.text = '$(sync~spin) Agent: Connecting...';

  client.on('connected', (sessions) => {
    setConnectedStatus(sessions.length);
    vscode.window.showInformationMessage(
      `Connected to Personal Agent (${sessions.length} active session${sessions.length === 1 ? '' : 's'})`
    );

    // Subscribe to existing sessions so we can see their output when attached
    terminalManager?.syncSessions(sessions);
  });

  client.on('disconnected', () => {
    setDisconnectedStatus();
    vscode.window.showWarningMessage('Disconnected from Personal Agent.');
  });

  client.on('error', (err: Error) => {
    // Only show connection errors if we're not yet connected
    if (!client?.connected) {
      setDisconnectedStatus();
      vscode.window.showErrorMessage(`Agent connection error: ${err.message}`);
    }
  });

  client.on('pty:created', () => {
    // Update status bar count
    client?.listSessions().then((sessions) => {
      setConnectedStatus(sessions.length);
    }).catch(() => {});
  });

  client.connect({
    host,
    port,
    authToken,
    useTLS,
    rejectUnauthorized,
    deviceName: `VS Code (${vscode.env.machineId.substring(0, 8)})`,
  });
}

function disconnectFromAgent(): void {
  if (client) {
    client.disconnect();
    client = null;
  }
  if (terminalManager) {
    terminalManager.dispose();
    terminalManager = null;
  }
  setDisconnectedStatus();
  vscode.window.showInformationMessage('Disconnected from Personal Agent.');
}

async function listTerminals(): Promise<void> {
  if (!client?.connected || !terminalManager) {
    const action = await vscode.window.showWarningMessage(
      'Not connected to Personal Agent.',
      'Connect'
    );
    if (action === 'Connect') {
      await connectToAgent();
    }
    return;
  }

  await terminalManager.showSessionPicker();
}

async function attachTerminal(): Promise<void> {
  if (!client?.connected || !terminalManager) {
    vscode.window.showWarningMessage('Not connected to Personal Agent.');
    return;
  }

  await terminalManager.showSessionPicker();
}

async function createTerminal(): Promise<void> {
  if (!client?.connected || !terminalManager) {
    const action = await vscode.window.showWarningMessage(
      'Not connected to Personal Agent.',
      'Connect'
    );
    if (action === 'Connect') {
      await connectToAgent();
    }
    return;
  }

  const name = await vscode.window.showInputBox({
    prompt: 'Terminal name',
    value: 'Shared Terminal',
  });

  if (name !== undefined) {
    await terminalManager.createSharedTerminal(name || undefined);
  }
}

function setConnectedStatus(sessionCount: number): void {
  statusBarItem.text = `$(terminal) Agent: ${sessionCount} terminal${sessionCount === 1 ? '' : 's'}`;
  statusBarItem.tooltip = 'Click to list shared terminals';
  statusBarItem.backgroundColor = undefined;
}

function setDisconnectedStatus(): void {
  statusBarItem.text = '$(debug-disconnect) Agent: Disconnected';
  statusBarItem.tooltip = 'Click to connect to Personal Agent';
  statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
}

export function deactivate() {
  if (client) {
    client.disconnect();
  }
  if (terminalManager) {
    terminalManager.dispose();
  }
}
