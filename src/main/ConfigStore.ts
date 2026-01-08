import * as fs from 'fs';
import * as path from 'path';
import { app } from 'electron';
import { AgentConfig, DEFAULT_CONFIG } from '../shared/types';
import * as crypto from 'crypto';
import * as keytar from 'keytar';

const KEYCHAIN_SERVICE = 'com.personal-agent';
const KEYCHAIN_ACCOUNT = 'authToken';

export class ConfigStore {
  private _configPath: string;
  private config: AgentConfig;
  private initPromise: Promise<void>;

  get configPath(): string {
    return this._configPath;
  }

  constructor() {
    const userDataPath = app?.getPath('userData') || process.cwd();
    this._configPath = path.join(userDataPath, 'config.json');
    this.config = this.loadSync();
    this.initPromise = this.initialize();
  }

  private loadSync(): AgentConfig {
    try {
      if (fs.existsSync(this.configPath)) {
        const data = fs.readFileSync(this.configPath, 'utf-8');
        return { ...DEFAULT_CONFIG, ...JSON.parse(data) };
      }
    } catch (error) {
      console.error('Failed to load config:', error);
    }

    return { ...DEFAULT_CONFIG };
  }

  private async initialize(): Promise<void> {
    // Check if we need to migrate token from JSON to Keychain
    if (this.config.connection.authToken) {
      console.log('Migrating auth token from JSON to Keychain...');
      await keytar.setPassword(
        KEYCHAIN_SERVICE,
        KEYCHAIN_ACCOUNT,
        this.config.connection.authToken
      );

      // Remove token from JSON config
      delete this.config.connection.authToken;
      this.save(this.config);
      console.log('Auth token migrated successfully');
    } else {
      // Check if token exists in Keychain
      const token = await keytar.getPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
      if (!token) {
        // Generate a new token if none exists
        console.log('Generating new auth token...');
        const newToken = this.generateToken();
        await keytar.setPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, newToken);
      }
    }
  }

  private generateToken(): string {
    return crypto.randomBytes(32).toString('hex');
  }

  get(): AgentConfig {
    return { ...this.config };
  }

  set(config: Partial<AgentConfig>): void {
    this.config = { ...this.config, ...config };
    this.save(this.config);
  }

  private save(config: AgentConfig): void {
    try {
      const dir = path.dirname(this.configPath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      // Ensure authToken is not saved to JSON
      const configToSave = { ...config };
      delete configToSave.connection.authToken;
      fs.writeFileSync(this.configPath, JSON.stringify(configToSave, null, 2));
    } catch (error) {
      console.error('Failed to save config:', error);
    }
  }

  async getAuthToken(): Promise<string> {
    await this.initPromise;
    const token = await keytar.getPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT);
    if (!token) {
      throw new Error('Auth token not found in Keychain');
    }
    return token;
  }

  async regenerateAuthToken(): Promise<string> {
    await this.initPromise;
    const token = this.generateToken();
    await keytar.setPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, token);
    return token;
  }
}
