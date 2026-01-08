import { contextBridge, ipcRenderer } from 'electron';

// Expose protected methods that allow the renderer process to use
// ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld('api', {
  // Config
  getConfig: () => ipcRenderer.invoke('get-config'),
  setConfig: (config: unknown) => ipcRenderer.invoke('set-config', config),

  // Services
  getServices: () => ipcRenderer.invoke('get-services'),
  startService: (id: string) => ipcRenderer.invoke('start-service', id),
  stopService: (id: string) => ipcRenderer.invoke('stop-service', id),
  restartService: (id: string) => ipcRenderer.invoke('restart-service', id),

  // PTY Sessions
  getSessions: () => ipcRenderer.invoke('get-sessions'),
  createSession: (options?: unknown) => ipcRenderer.invoke('create-session', options),
  closeSession: (id: string) => ipcRenderer.invoke('close-session', id),

  // Remote
  getConnectedClients: () => ipcRenderer.invoke('get-connected-clients'),
  getAuthToken: () => ipcRenderer.invoke('get-auth-token'),
  regenerateAuthToken: () => ipcRenderer.invoke('regenerate-auth-token'),

  // Utilities
  openExternal: (url: string) => ipcRenderer.invoke('open-external', url),

  // Tailscale and Pairing
  getTailscaleStatus: () => ipcRenderer.invoke('get-tailscale-status'),
  getPairingInfo: () => ipcRenderer.invoke('get-pairing-info'),
  generatePairingQR: () => ipcRenderer.invoke('generate-pairing-qr'),
  getTailscaleInstallUrl: () => ipcRenderer.invoke('get-tailscale-install-url'),

  // Paths and data folder
  getPaths: () => ipcRenderer.invoke('get-paths'),
  openDataFolder: () => ipcRenderer.invoke('open-data-folder'),

  // Certificate management
  regenerateCert: () => ipcRenderer.invoke('regenerate-cert'),
  getCertFingerprint: () => ipcRenderer.invoke('get-cert-fingerprint'),

  // Event listeners
  on: (channel: string, callback: (...args: unknown[]) => void) => {
    const validChannels = [
      'service:status',
      'service:output',
      'pty:data',
      'pty:exit',
      'client:connected',
      'client:disconnected',
    ];
    if (validChannels.includes(channel)) {
      ipcRenderer.on(channel, (_, ...args) => callback(...args));
    }
  },
  removeAllListeners: (channel: string) => {
    ipcRenderer.removeAllListeners(channel);
  },
});
