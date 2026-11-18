import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes } from 'node:crypto';
import { DataSource, EntityManager } from 'typeorm';
import { isUUID } from 'class-validator';
import type { UserIdentity } from '../users/users.service';

interface SessionRow extends UserIdentity { sessionId: string }
interface TokenRecord { request_id: string | null; encrypted_successor: Buffer | null }

const issuer = 'ploggr-api';
const audience = 'ploggr-client';
const digestOf = (token: string) => createHash('sha256').update(token).digest('hex');

@Injectable()
export class SessionService {
  private readonly accessTtl: number;
  private readonly signingKey: Buffer;
  private readonly retryKey: Buffer;

  constructor(private readonly db: DataSource, private readonly jwt: JwtService, config: ConfigService) {
    this.accessTtl = config.getOrThrow<number>('AUTH_ACCESS_TTL_SECONDS');
    const secret = Buffer.from(config.getOrThrow<string>('AUTH_SECRET'), 'hex');
    this.signingKey = Buffer.from(hkdfSync('sha256', secret, '', 'ploggr/access/v1', 32));
    this.retryKey = Buffer.from(hkdfSync('sha256', secret, '', 'ploggr/refresh-retry/v1', 32));
  }

  async issue(manager: EntityManager, user: UserIdentity) {
    const [session]: { id: string }[] = await manager.query(
      'INSERT INTO auth_sessions(user_id) VALUES ($1) RETURNING id', [user.id],
    );
    const token = await this.newCredential(manager, session.id);
    return this.response(user, session.id, token);
  }

  async refresh(token: string, rawRequestId: string) {
    const requestId = rawRequestId.toLowerCase();
    const digest = digestOf(token);
    const result = await this.db.transaction(async manager => {
      // Serialize every mutation of this device, then read the credential at READ COMMITTED.
      const [row]: SessionRow[] = await manager.query(`
        SELECT s.id AS "sessionId", u.id, u.email FROM auth_sessions s
        JOIN users u ON u.id = s.user_id JOIN auth_refresh_tokens t ON t.session_id = s.id
        WHERE t.digest = $1 FOR UPDATE OF s`, [digest]);
      if (!row) return null;
      const [old]: TokenRecord[] = await manager.query(
        'SELECT request_id, encrypted_successor FROM auth_refresh_tokens WHERE digest = $1', [digest],
      );
      if (old.request_id !== null) {
        if (old.request_id !== requestId) {
          await manager.query('DELETE FROM auth_sessions WHERE id = $1', [row.sessionId]);
          return null; // Commit revocation before returning 401.
        }
        if (!old.encrypted_successor) return null;
        return this.response(row, row.sessionId, this.decrypt(old.encrypted_successor, digest));
      }
      const next = await this.newCredential(manager, row.sessionId);
      await manager.query(`UPDATE auth_refresh_tokens SET encrypted_successor = NULL
        WHERE session_id = $1 AND encrypted_successor IS NOT NULL`, [row.sessionId]);
      await manager.query(`UPDATE auth_refresh_tokens SET request_id = $2, encrypted_successor = $3
        WHERE digest = $1`, [digest, requestId, this.encrypt(next, digest)]);
      return this.response(row, row.sessionId, next);
    });
    if (!result) throw new UnauthorizedException();
    return result;
  }

  async revoke(token: string): Promise<void> {
    await this.db.query(`DELETE FROM auth_sessions WHERE id =
      (SELECT session_id FROM auth_refresh_tokens WHERE digest = $1)`, [digestOf(token)]);
  }

  async authenticate(token: string): Promise<UserIdentity> {
    let claims: { sid?: string; sub?: string; exp?: number };
    try {
      claims = await this.jwt.verifyAsync(token, { secret: this.signingKey, algorithms: ['HS256'], issuer, audience });
    } catch {
      throw new UnauthorizedException();
    }
    if (!Number.isSafeInteger(claims.exp) || !isUUID(claims.sub, '4') || !isUUID(claims.sid, '4')) {
      throw new UnauthorizedException();
    }
    const [user]: UserIdentity[] = await this.db.query(`
      SELECT u.id, u.email FROM auth_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.id = $1 AND u.id = $2`, [claims.sid, claims.sub]);
    if (!user) throw new UnauthorizedException();
    return user;
  }

  private async newCredential(manager: EntityManager, sessionId: string) {
    const token = randomBytes(32).toString('base64url');
    await manager.query('INSERT INTO auth_refresh_tokens(digest, session_id) VALUES ($1, $2)', [digestOf(token), sessionId]);
    return token;
  }

  private response({ id, email }: UserIdentity, sid: string, refreshToken: string) {
    const accessToken = this.jwt.sign({ sid }, {
      subject: id, algorithm: 'HS256', issuer, audience, expiresIn: this.accessTtl, secret: this.signingKey,
    });
    return { user: { id, email }, accessToken, refreshToken };
  }

  private encrypt(value: string, digest: string): Buffer {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.retryKey, iv);
    cipher.setAAD(Buffer.from(digest));
    const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]);
  }

  private decrypt(value: Buffer, digest: string): string {
    const cipher = createDecipheriv('aes-256-gcm', this.retryKey, value.subarray(0, 12));
    cipher.setAAD(Buffer.from(digest));
    cipher.setAuthTag(value.subarray(12, 28));
    return Buffer.concat([cipher.update(value.subarray(28)), cipher.final()]).toString('utf8');
  }
}
