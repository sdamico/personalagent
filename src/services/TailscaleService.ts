import { execSync, exec } from 'child_process';
import * as fs from 'fs';

export interface TailscaleStatus {
  installed: boolean;
  running: boolean;
  loggedIn: boolean;
  ip: string | null;
  hostname: string | null;
  error?: string;
}

export class TailscaleService {
  private static CLI_PATHS = [
    '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
    '/usr/local/bin/tailscale',
    '/opt/homebrew/bin/tailscale',
    'tailscale', // In PATH
  ];

  private cliPath: string | null = null;

  constructor() {
    this.cliPath = this.findCli();
  }

  private findCli(): string | null {
    for (const path of TailscaleService.CLI_PATHS) {
      try {
        if (path.startsWith('/')) {
          if (fs.existsSync(path)) {
            return path;
          }
        } else {
          // Check if in PATH
          execSync(`which ${path}`, { stdio: 'pipe' });
          return path;
        }
      } catch {
        // Continue to next path
      }
    }
    return null;
  }

  async getStatus(): Promise<TailscaleStatus> {
    if (!this.cliPath) {
      return {
        installed: false,
        running: false,
        loggedIn: false,
        ip: null,
        hostname: null,
        error: 'Tailscale not installed',
      };
    }

    try {
      // Get status as JSON
      const statusJson = execSync(`"${this.cliPath}" status --json`, {
        encoding: 'utf-8',
        timeout: 5000,
      });

      const status = JSON.parse(statusJson);

      // Check BackendState for login status
      const backendState = status.BackendState;
      const selfStatus = status.Self;

      if (backendState === 'NeedsLogin' || backendState === 'NoState') {
        return {
          installed: true,
          running: true,
          loggedIn: false,
          ip: null,
          hostname: selfStatus?.HostName || null,
          error: 'Please log in to Tailscale',
        };
      }

      if (backendState !== 'Running') {
        return {
          installed: true,
          running: true,
          loggedIn: false,
          ip: null,
          hostname: selfStatus?.HostName || null,
          error: `Tailscale state: ${backendState}`,
        };
      }

      // Get IPv4 address
      const ip = await this.getIPv4();

      return {
        installed: true,
        running: true,
        loggedIn: true,
        ip,
        hostname: selfStatus?.HostName || null,
      };
    } catch (error: any) {
      // Check if it's a "not running" error
      if (error.message?.includes('not running') || error.stderr?.includes('not running')) {
        return {
          installed: true,
          running: false,
          loggedIn: false,
          ip: null,
          hostname: null,
          error: 'Tailscale is not running',
        };
      }

      return {
        installed: true,
        running: false,
        loggedIn: false,
        ip: null,
        hostname: null,
        error: error.message || 'Failed to get Tailscale status',
      };
    }
  }

  private async getIPv4(): Promise<string | null> {
    if (!this.cliPath) return null;

    try {
      const ip = execSync(`"${this.cliPath}" ip -4`, {
        encoding: 'utf-8',
        timeout: 5000,
      }).trim();
      return ip || null;
    } catch {
      return null;
    }
  }

  static getInstallUrl(): string {
    return 'https://tailscale.com/download/mac';
  }

  static getAppStoreUrl(): string {
    return 'https://apps.apple.com/app/tailscale/id1475387142';
  }
}
