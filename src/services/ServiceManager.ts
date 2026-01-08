import { spawn, ChildProcess } from 'child_process';
import { EventEmitter } from 'events';
import { ServiceConfig, ServiceStatus } from '../shared/types';

interface ManagedService {
  config: ServiceConfig;
  process: ChildProcess | null;
  status: ServiceStatus;
  startTime: number | null;
}

export class ServiceManager extends EventEmitter {
  private services: Map<string, ManagedService> = new Map();

  constructor() {
    super();
  }

  registerService(config: ServiceConfig): void {
    if (this.services.has(config.id)) {
      throw new Error(`Service ${config.id} already registered`);
    }

    this.services.set(config.id, {
      config,
      process: null,
      status: {
        id: config.id,
        name: config.name,
        status: 'stopped',
      },
      startTime: null,
    });

    this.emit('service:registered', config);
  }

  async startService(id: string): Promise<void> {
    const service = this.services.get(id);
    if (!service) {
      throw new Error(`Service ${id} not found`);
    }

    if (service.status.status === 'running') {
      return;
    }

    service.status.status = 'starting';
    this.emit('service:status', service.status);

    try {
      const proc = spawn(service.config.command, service.config.args, {
        cwd: service.config.cwd,
        env: { ...process.env, ...service.config.env },
        stdio: ['pipe', 'pipe', 'pipe'],
      });

      service.process = proc;
      service.startTime = Date.now();
      service.status.status = 'running';
      service.status.pid = proc.pid;

      proc.stdout?.on('data', (data) => {
        this.emit('service:output', { id, stream: 'stdout', data: data.toString() });
      });

      proc.stderr?.on('data', (data) => {
        this.emit('service:output', { id, stream: 'stderr', data: data.toString() });
      });

      proc.on('error', (error) => {
        service.status.status = 'error';
        service.status.lastError = error.message;
        this.emit('service:status', service.status);
        this.emit('service:error', { id, error });
      });

      proc.on('exit', (code, signal) => {
        service.status.status = 'stopped';
        service.process = null;
        service.startTime = null;
        this.emit('service:status', service.status);
        this.emit('service:exit', { id, code, signal });

        if (service.config.restartOnFailure && code !== 0) {
          setTimeout(() => this.startService(id), 5000);
        }
      });

      this.emit('service:status', service.status);
    } catch (error) {
      service.status.status = 'error';
      service.status.lastError = (error as Error).message;
      this.emit('service:status', service.status);
      throw error;
    }
  }

  async stopService(id: string): Promise<void> {
    const service = this.services.get(id);
    if (!service || !service.process) {
      return;
    }

    return new Promise((resolve) => {
      const proc = service.process!;

      proc.once('exit', () => {
        service.process = null;
        service.status.status = 'stopped';
        this.emit('service:status', service.status);
        resolve();
      });

      // Graceful shutdown
      proc.kill('SIGTERM');

      // Force kill after 10 seconds
      setTimeout(() => {
        if (service.process) {
          proc.kill('SIGKILL');
        }
      }, 10000);
    });
  }

  async restartService(id: string): Promise<void> {
    await this.stopService(id);
    await this.startService(id);
  }

  getStatus(id: string): ServiceStatus | undefined {
    const service = this.services.get(id);
    if (!service) return undefined;

    if (service.startTime) {
      service.status.uptime = Date.now() - service.startTime;
    }

    return { ...service.status };
  }

  getAllStatuses(): ServiceStatus[] {
    return Array.from(this.services.values()).map((s) => this.getStatus(s.config.id)!);
  }

  async stopAll(): Promise<void> {
    const stopPromises = Array.from(this.services.keys()).map((id) => this.stopService(id));
    await Promise.all(stopPromises);
  }
}
