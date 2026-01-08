import {
  app,
  BrowserWindow,
  Tray,
  Menu,
  nativeImage,
  ipcMain,
  dialog,
  shell,
} from 'electron';
import * as path from 'path';
import * as QRCode from 'qrcode';
import { PTYManager } from '../services/PTYManager';
import { ServiceManager } from '../services/ServiceManager';
import { RemoteServer } from '../services/RemoteServer';
import { TailscaleService } from '../services/TailscaleService';
import { ConfigStore } from './ConfigStore';
import { CertManager } from './CertManager';
import { ServiceConfig, PairingInfo } from '../shared/types';

class PersonalAgent {
  private mainWindow: BrowserWindow | null = null;
  private tray: Tray | null = null;
  private ptyManager: PTYManager;
  private serviceManager: ServiceManager;
  private remoteServer: RemoteServer | null = null;
  private configStore: ConfigStore;
  private tailscaleService: TailscaleService;
  private certManager: CertManager;
  private isQuitting = false;

  constructor() {
    this.ptyManager = new PTYManager();
    this.serviceManager = new ServiceManager();
    this.configStore = new ConfigStore();
    this.tailscaleService = new TailscaleService();
    this.certManager = new CertManager();

    this.setupApp();
    this.setupIPC();
  }

  private setupApp(): void {
    // Prevent multiple instances
    const gotTheLock = app.requestSingleInstanceLock();
    if (!gotTheLock) {
      app.quit();
      return;
    }

    app.on('second-instance', () => {
      if (this.mainWindow) {
        if (this.mainWindow.isMinimized()) this.mainWindow.restore();
        this.mainWindow.focus();
      }
    });

    app.on('ready', () => this.onReady());

    app.on('window-all-closed', () => {
      // Don't quit on window close - stay in tray
      if (process.platform !== 'darwin') {
        // On non-Mac, we keep running in tray
      }
    });

    app.on('activate', () => {
      if (this.mainWindow === null) {
        this.createWindow();
      } else {
        this.mainWindow.show();
      }
    });

    app.on('before-quit', () => {
      this.isQuitting = true;
    });
  }

  private async onReady(): Promise<void> {
    const config = this.configStore.get();

    // Create tray icon
    this.createTray();

    // Initialize TLS certificate
    const tailscaleStatus = await this.tailscaleService.getStatus();
    await this.certManager.initialize(tailscaleStatus.ip || undefined);

    // Start remote server with TLS
    await this.startRemoteServer();

    // Register default services
    this.registerDefaultServices(config.services);

    // Auto-start services
    for (const service of config.services) {
      if (service.autoStart) {
        this.serviceManager.startService(service.id).catch(console.error);
      }
    }

    // Create window unless configured to start minimized
    if (!config.startMinimized) {
      this.createWindow();
    }

    // Enable launch at login if configured
    if (config.autoLaunch) {
      app.setLoginItemSettings({
        openAtLogin: true,
        openAsHidden: true,
      });
    }

    console.log('Personal Agent started');
    console.log(`Remote server port: ${config.connection.directPort || 9876}`);
    const token = await this.configStore.getAuthToken();
    console.log(`Auth token: ${token.substring(0, 8)}...`);
  }

  private createTray(): void {
    // Create a simple tray icon (you'd want to replace with an actual icon)
    const iconPath = path.join(__dirname, '../../assets/tray-icon.png');
    let icon: Electron.NativeImage;

    try {
      icon = nativeImage.createFromPath(iconPath);
    } catch {
      // Create a simple colored icon as fallback
      icon = nativeImage.createEmpty();
    }

    // Resize for tray
    if (!icon.isEmpty()) {
      icon = icon.resize({ width: 16, height: 16 });
    }

    this.tray = new Tray(icon.isEmpty() ? this.createDefaultIcon() : icon);
    this.tray.setToolTip('Personal Agent');
    this.updateTrayMenu();

    this.tray.on('click', () => {
      if (this.mainWindow) {
        if (this.mainWindow.isVisible()) {
          this.mainWindow.hide();
        } else {
          this.mainWindow.show();
        }
      } else {
        this.createWindow();
      }
    });
  }

  private createDefaultIcon(): Electron.NativeImage {
    // Create a simple 16x16 icon
    const size = 16;
    const canvas = Buffer.alloc(size * size * 4);

    // Fill with a solid color (green for "running")
    for (let i = 0; i < size * size; i++) {
      canvas[i * 4] = 100;     // R
      canvas[i * 4 + 1] = 200; // G
      canvas[i * 4 + 2] = 100; // B
      canvas[i * 4 + 3] = 255; // A
    }

    return nativeImage.createFromBuffer(canvas, {
      width: size,
      height: size,
    });
  }

  private updateTrayMenu(): void {
    if (!this.tray) return;

    const services = this.serviceManager.getAllStatuses();
    const clients = this.remoteServer?.getConnectedClients() || [];

    const contextMenu = Menu.buildFromTemplate([
      {
        label: 'Personal Agent',
        enabled: false,
      },
      { type: 'separator' },
      {
        label: `Connected Clients: ${clients.length}`,
        enabled: false,
      },
      { type: 'separator' },
      {
        label: 'Services',
        submenu: services.length > 0 ? services.map((s) => ({
          label: `${s.name} (${s.status})`,
          submenu: [
            {
              label: 'Start',
              enabled: s.status === 'stopped',
              click: () => this.serviceManager.startService(s.id),
            },
            {
              label: 'Stop',
              enabled: s.status === 'running',
              click: () => this.serviceManager.stopService(s.id),
            },
            {
              label: 'Restart',
              enabled: s.status === 'running',
              click: () => this.serviceManager.restartService(s.id),
            },
          ],
        })) : [{ label: 'No services configured', enabled: false }],
      },
      { type: 'separator' },
      {
        label: 'Show Window',
        click: () => {
          if (this.mainWindow) {
            this.mainWindow.show();
          } else {
            this.createWindow();
          }
        },
      },
      {
        label: 'Copy Auth Token',
        click: async () => {
          const { clipboard } = require('electron');
          const token = await this.configStore.getAuthToken();
          clipboard.writeText(token);
        },
      },
      {
        label: 'Show Connection Info',
        click: () => this.showConnectionInfo(),
      },
      { type: 'separator' },
      {
        label: 'Quit',
        click: () => {
          this.isQuitting = true;
          this.shutdown();
        },
      },
    ]);

    this.tray.setContextMenu(contextMenu);
  }

  private createWindow(): void {
    const iconPath = path.join(__dirname, '../../assets/icon.png');

    // Set dock icon on macOS
    if (process.platform === 'darwin' && app.dock) {
      app.dock.setIcon(iconPath);
    }

    this.mainWindow = new BrowserWindow({
      width: 900,
      height: 600,
      show: false,
      icon: iconPath,
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        preload: path.join(__dirname, 'preload.js'),
      },
    });

    // Load the renderer
    this.mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

    this.mainWindow.once('ready-to-show', () => {
      this.mainWindow?.show();
    });

    this.mainWindow.on('close', (event) => {
      if (!this.isQuitting) {
        event.preventDefault();
        this.mainWindow?.hide();
      }
    });

    this.mainWindow.on('closed', () => {
      this.mainWindow = null;
    });
  }

  private async startRemoteServer(): Promise<void> {
    const config = this.configStore.get();
    const port = config.connection.directPort || 9876;
    const authToken = await this.configStore.getAuthToken();

    // Get TLS credentials
    const tlsCredentials = this.certManager.getServerCredentials();

    // Check if we should restrict to Tailscale connections
    const restrictToTailscale = config.connection.restrictToTailscale !== false; // Default true

    this.remoteServer = new RemoteServer({
      port,
      authToken,
      ptyManager: this.ptyManager,
      serviceManager: this.serviceManager,
      tlsCredentials: tlsCredentials || undefined,
      restrictToTailscale,
    });

    this.remoteServer.on('client:authenticated', () => {
      this.updateTrayMenu();
    });

    this.remoteServer.on('client:disconnected', () => {
      this.updateTrayMenu();
    });
  }

  private registerDefaultServices(services: ServiceConfig[]): void {
    for (const service of services) {
      this.serviceManager.registerService(service);
    }

    // Update tray when service status changes
    this.serviceManager.on('service:status', () => {
      this.updateTrayMenu();
    });
  }

  private async showConnectionInfo(): Promise<void> {
    const config = this.configStore.get();
    const token = await this.configStore.getAuthToken();

    dialog.showMessageBox({
      type: 'info',
      title: 'Connection Info',
      message: 'Personal Agent Connection Details',
      detail: `Port: ${config.connection.directPort || 9876}\n\nAuth Token (first 16 chars):\n${token.substring(0, 16)}...\n\nUse Tailscale to connect from your iOS app.`,
      buttons: ['OK', 'Copy Full Token'],
    }).then((result) => {
      if (result.response === 1) {
        const { clipboard } = require('electron');
        clipboard.writeText(token);
      }
    });
  }

  private setupIPC(): void {
    ipcMain.handle('get-config', () => this.configStore.get());
    ipcMain.handle('set-config', (_, config) => this.configStore.set(config));

    ipcMain.handle('get-services', () => this.serviceManager.getAllStatuses());
    ipcMain.handle('start-service', (_, id) => this.serviceManager.startService(id));
    ipcMain.handle('stop-service', (_, id) => this.serviceManager.stopService(id));
    ipcMain.handle('restart-service', (_, id) => this.serviceManager.restartService(id));

    ipcMain.handle('get-sessions', () => this.ptyManager.getAllSessions());
    ipcMain.handle('create-session', (_, options) => this.ptyManager.createSession(options));
    ipcMain.handle('close-session', (_, id) => this.ptyManager.closeSession(id));

    ipcMain.handle('get-connected-clients', () =>
      this.remoteServer?.getConnectedClients() || []
    );

    ipcMain.handle('get-auth-token', () => this.configStore.getAuthToken());
    ipcMain.handle('regenerate-auth-token', async () => {
      const newToken = await this.configStore.regenerateAuthToken();
      // Restart server with new token
      this.remoteServer?.close();
      await this.startRemoteServer();
      return newToken;
    });

    ipcMain.handle('open-external', (_, url) => shell.openExternal(url));

    // Tailscale and pairing
    ipcMain.handle('get-tailscale-status', () => this.tailscaleService.getStatus());

    ipcMain.handle('get-pairing-info', async () => {
      const status = await this.tailscaleService.getStatus();
      const config = this.configStore.get();
      const port = config.connection.directPort || 9876;
      const token = await this.configStore.getAuthToken();
      const certFingerprint = this.certManager.getFingerprint();

      const pairingInfo: PairingInfo = {
        host: status.ip || 'Not available',
        port,
        token,
        certFingerprint: certFingerprint || undefined,
      };

      return {
        tailscaleStatus: status,
        pairingInfo,
        usingTLS: this.remoteServer?.isUsingTLS() || false,
      };
    });

    ipcMain.handle('generate-pairing-qr', async () => {
      const status = await this.tailscaleService.getStatus();
      const config = this.configStore.get();
      const port = config.connection.directPort || 9876;
      const token = await this.configStore.getAuthToken();
      const certFingerprint = this.certManager.getFingerprint();

      if (!status.ip) {
        return { error: 'Tailscale IP not available', qrDataUrl: null, host: null, port: null };
      }

      const pairingInfo: PairingInfo = {
        host: status.ip,
        port,
        token,
        certFingerprint: certFingerprint || undefined,
      };

      try {
        const qrDataUrl = await QRCode.toDataURL(JSON.stringify(pairingInfo), {
          width: 256,
          margin: 2,
          color: {
            dark: '#000000',
            light: '#ffffff',
          },
        });
        return { error: null, qrDataUrl, host: status.ip, port };
      } catch (err: any) {
        return { error: err.message, qrDataUrl: null, host: null, port: null };
      }
    });

    ipcMain.handle('get-tailscale-install-url', () => TailscaleService.getInstallUrl());

    // Paths and data folder
    ipcMain.handle('get-paths', () => ({
      config: this.configStore.configPath,
      certs: path.join(app.getPath('userData'), 'certs'),
      data: app.getPath('userData'),
      electronVersion: process.versions.electron,
      nodeVersion: process.versions.node,
    }));

    ipcMain.handle('open-data-folder', () => {
      shell.openPath(app.getPath('userData'));
    });

    // Certificate management
    ipcMain.handle('regenerate-cert', async () => {
      const tailscaleStatus = await this.tailscaleService.getStatus();
      await this.certManager.regenerate(tailscaleStatus.ip || undefined);
      // Restart server with new certificate
      this.remoteServer?.close();
      await this.startRemoteServer();
      return { fingerprint: this.certManager.getFingerprint() };
    });

    ipcMain.handle('get-cert-fingerprint', () => this.certManager.getFingerprint());
  }

  private async shutdown(): Promise<void> {
    console.log('Shutting down Personal Agent...');

    // Stop all services
    await this.serviceManager.stopAll();

    // Close all PTY sessions
    this.ptyManager.closeAll();

    // Close remote server
    this.remoteServer?.close();

    app.quit();
  }
}

// Start the application
new PersonalAgent();
