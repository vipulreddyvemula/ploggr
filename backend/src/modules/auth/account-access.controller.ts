import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Get,
  Header,
  HttpCode,
  Post,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Transform } from 'class-transformer';
import { IsEmail, IsString, Length, Matches, MaxLength } from 'class-validator';
import { createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { argon2id, hash } from 'argon2';
import { DataSource } from 'typeorm';
import { SessionService } from './session.service';
import { UsersService } from '../users/users.service';

class EmailInput {
  @Transform(({ value }) => (typeof value === 'string' ? value.trim().toLowerCase() : value))
  @IsEmail()
  @MaxLength(254)
  email!: string;
}
class ResetInput extends EmailInput {
  @IsString() @Matches(/^\d{8}$/) code!: string;
  @IsString() @Length(15, 128) password!: string;
}
class CodeInput {
  @IsString() @Length(1, 2048) code!: string;
  @IsString() @Matches(/^[A-Za-z0-9._~-]{43,128}$/) verifier!: string;
}
const redirectUri = 'com.example.ploggr.auth://callback';
const hashPassword = (v: string) =>
  hash(v, { type: argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 });
@Controller('auth')
export class AccountAccessController {
  constructor(
    private readonly db: DataSource,
    private readonly config: ConfigService,
    private readonly users: UsersService,
    private readonly sessions: SessionService,
  ) {}
  @Get('options')
  options() {
    const issuer = this.config.get<string>('AUTH_OIDC_ISSUER')?.replace(/\/$/, '');
    const clientId = this.config.get<string>('AUTH_OIDC_CLIENT_ID');
    const hasOidc = issuer && /^https:\/\/[\w.-]+$/.test(issuer) && clientId;
    const allowed = (this.config.get<string>('AUTH_OIDC_METHODS') ?? '').split(',').map((x) => x.trim());
    const methods = hasOidc ? ['google', 'apple', 'phone'].filter((x) => allowed.includes(x)) : [];
    return {
      issuer: hasOidc ? issuer : null,
      clientId: hasOidc ? clientId : null,
      methods,
      recovery: !!(this.config.get('RESEND_API_KEY') && this.config.get('MAIL_FROM')),
    };
  }
  @Post('external')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  async external(@Body() dto: CodeInput) {
    const { issuer, clientId, methods } = this.options();
    if (!issuer || !clientId || !methods.length) throw new ServiceUnavailableException();
    const res = await fetch(issuer + '/oauth/token', {
      method: 'POST',
      signal: AbortSignal.timeout(12000),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        grant_type: 'authorization_code',
        client_id: clientId,
        code: dto.code,
        redirect_uri: redirectUri,
        code_verifier: dto.verifier,
      }),
    });
    if (!res.ok) throw new UnauthorizedException();
    const token = (await res.json()) as { access_token?: string };
    if (!token.access_token) throw new UnauthorizedException();
    const identity = await fetch(issuer + '/userinfo', {
      headers: { Authorization: 'Bearer ' + token.access_token },
      signal: AbortSignal.timeout(12000),
    });
    if (!identity.ok) throw new UnauthorizedException();
    const info = (await identity.json()) as {
      sub?: string;
      email?: string;
      email_verified?: boolean;
      phone_number_verified?: boolean;
    };
    if (typeof info.sub !== 'string' || !info.sub || info.sub.length > 300) throw new UnauthorizedException();
    const strategy = info.sub.split('|')[0],
      method = (
        { google: 'google', 'google-oauth2': 'google', apple: 'apple', sms: 'phone' } as Record<
          string,
          string
        >
      )[strategy];
    if (!methods.includes(method)) throw new UnauthorizedException();
    return this.db.transaction(async (tx) => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [issuer + info.sub]);
      const [linked] = await tx.query(
        'SELECT u.id,u.email FROM external_identities e JOIN users u ON u.id=e.user_id WHERE issuer=$1 AND subject=$2',
        [issuer, info.sub],
      );
      if (linked) return this.sessions.issue(tx, linked);
      const email =
        info.email_verified === true && typeof info.email === 'string'
          ? info.email.trim().toLowerCase()
          : randomBytes(20).toString('hex') + '@identity.invalid';
      const [existing] = await tx.query('SELECT id FROM users WHERE email=$1', [email]);
      if (existing) throw new ConflictException('Use the original sign-in method for this account');
      const user = await this.users.create(
        { email, passwordHash: await hashPassword(randomBytes(48).toString('base64url')) },
        tx,
      );
      await tx.query('INSERT INTO external_identities VALUES($1,$2,$3)', [issuer, info.sub, user.id]);
      return this.sessions.issue(tx, user);
    });
  }
  private digest(email: string, code: string) {
    return createHmac('sha256', this.config.getOrThrow<string>('AUTH_SECRET'))
      .update('password-reset:' + email + ':' + code)
      .digest('hex');
  }
  @Post('password/request')
  @HttpCode(202)
  async request(@Body() dto: EmailInput) {
    if (!this.options().recovery) throw new ServiceUnavailableException('Email recovery is unavailable');
    const code = randomInt(0, 100000000).toString().padStart(8, '0');
    const digest = this.digest(dto.email, code);
    const rows = await this.db.query(
      `INSERT INTO password_resets(user_id,digest,expires_at)
      SELECT id,$2,now()+interval '15 minutes' FROM users WHERE email=$1 AND NOT EXISTS(SELECT 1 FROM external_identities WHERE user_id=users.id)
      ON CONFLICT(user_id) DO UPDATE SET digest=excluded.digest,expires_at=excluded.expires_at,attempts=0
      WHERE password_resets.expires_at<now()+interval '14 minutes' RETURNING user_id`,
      [dto.email, digest],
    );
    if (rows.length) {
      try {
        const result = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          signal: AbortSignal.timeout(8000),
          headers: {
            Authorization: 'Bearer ' + this.config.get('RESEND_API_KEY'),
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from: this.config.get('MAIL_FROM'),
            to: [dto.email],
            subject: 'Your Ploggr password reset code',
            text: 'Your code is ' + code + '. It expires in 15 minutes.',
          }),
        });
        if (!result.ok) throw new Error();
      } catch {
        await this.db.query('DELETE FROM password_resets WHERE user_id=$1 AND digest=$2', [
          rows[0].user_id,
          digest,
        ]);
      }
    }
    return { accepted: true };
  }
  @Post('password/reset')
  @HttpCode(204)
  async reset(@Body() dto: ResetInput) {
    const success = await this.db.transaction(async (tx) => {
      const [row] = await tx.query(
        `SELECT r.user_id,r.digest FROM password_resets r JOIN users u ON u.id=r.user_id
        WHERE u.email=$1 AND r.expires_at>now() AND r.attempts<5 FOR UPDATE OF r`,
        [dto.email],
      );
      if (!row) return false;
      if (
        !timingSafeEqual(Buffer.from(row.digest, 'hex'), Buffer.from(this.digest(dto.email, dto.code), 'hex'))
      ) {
        await tx.query('UPDATE password_resets SET attempts=attempts+1 WHERE user_id=$1', [row.user_id]);
        return false;
      }
      await tx.query('UPDATE users SET password_hash=$2 WHERE id=$1', [
        row.user_id,
        await hashPassword(dto.password),
      ]);
      await tx.query('DELETE FROM auth_sessions WHERE user_id=$1', [row.user_id]);
      await tx.query('DELETE FROM password_resets WHERE user_id=$1', [row.user_id]);
      return true;
    });
    if (!success) throw new BadRequestException('Invalid or expired code');
  }
}
