import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import { app } from 'electron';
import forge from 'node-forge';

interface CertificateInfo {
  cert: string;
  key: string;
  fingerprint: string;
}

export class CertManager {
  private certPath: string;
  private keyPath: string;
  private certInfo: CertificateInfo | null = null;

  constructor() {
    const userDataPath = app?.getPath('userData') || process.cwd();
    const certsDir = path.join(userDataPath, 'certs');

    // Ensure certs directory exists
    if (!fs.existsSync(certsDir)) {
      fs.mkdirSync(certsDir, { recursive: true });
    }

    this.certPath = path.join(certsDir, 'server.crt');
    this.keyPath = path.join(certsDir, 'server.key');
  }

  /**
   * Initialize certificate - load existing or generate new
   */
  async initialize(tailscaleIp?: string): Promise<CertificateInfo> {
    // Check if certs exist and are valid
    if (this.certsExist()) {
      try {
        this.certInfo = this.loadCerts();
        console.log('[CertManager] Loaded existing certificate');
        console.log(`[CertManager] Fingerprint: ${this.certInfo.fingerprint}`);
        return this.certInfo;
      } catch (error) {
        console.warn('[CertManager] Failed to load existing certs, generating new ones:', error);
      }
    }

    // Generate new certificate
    this.certInfo = await this.generateCertificate(tailscaleIp);
    this.saveCerts(this.certInfo);
    console.log('[CertManager] Generated new certificate');
    console.log(`[CertManager] Fingerprint: ${this.certInfo.fingerprint}`);
    return this.certInfo;
  }

  /**
   * Get the current certificate info
   */
  getCertInfo(): CertificateInfo | null {
    return this.certInfo;
  }

  /**
   * Get certificate and key for HTTPS server
   */
  getServerCredentials(): { cert: string; key: string } | null {
    if (!this.certInfo) return null;
    return {
      cert: this.certInfo.cert,
      key: this.certInfo.key,
    };
  }

  /**
   * Get SHA-256 fingerprint of the certificate
   */
  getFingerprint(): string | null {
    return this.certInfo?.fingerprint || null;
  }

  /**
   * Regenerate certificate (e.g., when Tailscale IP changes)
   */
  async regenerate(tailscaleIp?: string): Promise<CertificateInfo> {
    this.certInfo = await this.generateCertificate(tailscaleIp);
    this.saveCerts(this.certInfo);
    console.log('[CertManager] Regenerated certificate');
    console.log(`[CertManager] New fingerprint: ${this.certInfo.fingerprint}`);
    return this.certInfo;
  }

  private certsExist(): boolean {
    return fs.existsSync(this.certPath) && fs.existsSync(this.keyPath);
  }

  private loadCerts(): CertificateInfo {
    const cert = fs.readFileSync(this.certPath, 'utf-8');
    const key = fs.readFileSync(this.keyPath, 'utf-8');
    const fingerprint = this.calculateFingerprint(cert);
    return { cert, key, fingerprint };
  }

  private saveCerts(info: CertificateInfo): void {
    // Set restrictive permissions on private key
    fs.writeFileSync(this.keyPath, info.key, { mode: 0o600 });
    fs.writeFileSync(this.certPath, info.cert, { mode: 0o644 });
  }

  private async generateCertificate(tailscaleIp?: string): Promise<CertificateInfo> {
    // Generate RSA key pair
    const keys = forge.pki.rsa.generateKeyPair(2048);

    // Create certificate
    const cert = forge.pki.createCertificate();
    cert.publicKey = keys.publicKey;
    cert.serialNumber = '01' + crypto.randomBytes(8).toString('hex');

    // Valid for 10 years
    cert.validity.notBefore = new Date();
    cert.validity.notAfter = new Date();
    cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 10);

    // Set subject and issuer (self-signed)
    const attrs = [
      { name: 'commonName', value: 'Personal Agent' },
      { name: 'organizationName', value: 'Personal Agent' },
    ];
    cert.setSubject(attrs);
    cert.setIssuer(attrs);

    // Build subject alternative names
    const altNames: Array<{type: number; value?: string; ip?: string}> = [
      { type: 2, value: 'localhost' }, // DNS
      { type: 7, ip: '127.0.0.1' },    // IP
    ];

    // Add Tailscale IP if provided
    if (tailscaleIp) {
      altNames.push({ type: 7, ip: tailscaleIp });
    }

    cert.setExtensions([
      {
        name: 'basicConstraints',
        cA: false,
      },
      {
        name: 'keyUsage',
        keyCertSign: false,
        digitalSignature: true,
        keyEncipherment: true,
      },
      {
        name: 'extKeyUsage',
        serverAuth: true,
      },
      {
        name: 'subjectAltName',
        altNames,
      },
    ]);

    // Self-sign the certificate
    cert.sign(keys.privateKey, forge.md.sha256.create());

    // Convert to PEM format
    const certPem = forge.pki.certificateToPem(cert);
    const keyPem = forge.pki.privateKeyToPem(keys.privateKey);
    const fingerprint = this.calculateFingerprint(certPem);

    return {
      cert: certPem,
      key: keyPem,
      fingerprint,
    };
  }

  private calculateFingerprint(certPem: string): string {
    // Extract DER directly from PEM (don't re-encode through forge)
    // PEM is just base64-encoded DER with headers
    const pemBody = certPem
      .replace(/-----BEGIN CERTIFICATE-----/g, '')
      .replace(/-----END CERTIFICATE-----/g, '')
      .replace(/\s/g, '');
    const derBuffer = Buffer.from(pemBody, 'base64');

    // Calculate SHA-256 hash using Node's crypto (same as iOS CryptoKit)
    const fingerprint = crypto
      .createHash('sha256')
      .update(derBuffer)
      .digest('hex')
      .toUpperCase();

    // Format as colon-separated pairs for readability
    return fingerprint.match(/.{2}/g)?.join(':') || fingerprint;
  }
}
