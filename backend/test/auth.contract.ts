import { type INestApplication, Logger } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import { randomUUID, hkdfSync } from 'node:crypto';
import request from 'supertest';
import { DataSource } from 'typeorm';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/app.setup';
import { UsersService } from '../src/modules/users/users.service';

export function authContract(source: () => DataSource) {
  describe('authentication HTTP contract', () => {
    let app: INestApplication;
    const credentials = { email: '  Auth@Example.test ', password: '  long pass phrase  ' };
    const post = (route: string, body: object) => request(app.getHttpServer()).post('/api/auth/' + route).send(body);
    const me = (token: string) => request(app.getHttpServer()).get('/api/auth/me').auth(token, { type: 'bearer' });

    beforeAll(async () => {
      const module = await Test.createTestingModule({ imports: [AppModule] }).compile();
      app = module.createNestApplication();
      configureApp(app);
      await app.init();
    });
    afterAll(async () => { await app?.close(); });

    it('creates one account under concurrency, hashes verbatim passwords, and identifies both devices', async () => {
      const results = await Promise.all([post('signup', credentials), post('signup', credentials)]);
      expect(results.map(r => r.status).sort()).toEqual([201, 409]);
      const signup = results.find(r => r.status === 201)!.body;
      expect(Object.keys(signup).sort()).toEqual(['accessToken', 'refreshToken', 'user']);
      expect(signup.user).toEqual({ email: 'auth@example.test', id: expect.any(String) });
      const [{ password_hash }] = await source().query('SELECT password_hash FROM users WHERE id=$1', [signup.user.id]);
      expect(password_hash).toMatch(/^\$argon2id\$/);
      const login = await post('login', credentials).expect(200);
      await me(login.body.accessToken).expect(200, signup.user);
      const invalid = await post('login', { ...credentials, password: credentials.password.trim() }).expect(401);
      const unknown = await post('login', { ...credentials, email: 'unknown@example.test' }).expect(401);
      expect(unknown.body.message).toEqual(invalid.body.message);
      await post('signup', { email: credentials.email, password: 'short' }).expect(400);
      await post('login', { ...credentials, extra: true }).expect(400);
      await post('logout', { refreshToken: signup.refreshToken }).expect(204);
      await post('logout', { refreshToken: signup.refreshToken }).expect(204);
      await me(signup.accessToken).expect(401);
      await post('refresh', { refreshToken: signup.refreshToken, requestId: randomUUID() }).expect(401);
      await me(login.body.accessToken).expect(200, signup.user);
    });

    it('recovers a lost rotation response and revokes only the replayed session', async () => {
      const { body: login } = await post('login', credentials).expect(200);
      const other = await post('login', credentials).expect(200);
      const first = { refreshToken: login.refreshToken, requestId: randomUUID() };
      const [a, b] = await Promise.all([post('refresh', first).expect(200), post('refresh', first).expect(200)]);
      expect(a.body.refreshToken).not.toBe(login.refreshToken);
      expect(a.body.refreshToken).toBe(b.body.refreshToken);
      const next = await post('refresh', { refreshToken: b.body.refreshToken, requestId: randomUUID() }).expect(200);
      await post('refresh', first).expect(401);
      await me(next.body.accessToken).expect(200);
      await post('refresh', { ...first, requestId: randomUUID() }).expect(401);
      await me(next.body.accessToken).expect(401);
      await me(other.body.accessToken).expect(200);
    });

    it('rejects invalid access tokens and requires all expected JWT claims', async () => {
      const { body } = await post('login', credentials).expect(200);
      const jwt = app.get(JwtService);
      const { sub, sid, iss, aud } = jwt.decode(body.accessToken);
      const key = Buffer.from(hkdfSync('sha256', Buffer.from(process.env.AUTH_SECRET!, 'hex'), '', 'ploggr/access/v1', 32));
      const sign = (payload: object) => jwt.sign(payload, { secret: key });
      const valid = { sub, sid, iss, aud, exp: Math.floor(Date.now()/1000) + 100 };
      for (const token of [
        'invalid', sign({ ...valid, exp: 1 }), sign({ sub, sid, iss, aud }),
        sign({ ...valid, aud: 'another-app' }), sign({ ...valid, iss: 'another-issuer' }),
        jwt.sign(valid, { secret: key, algorithm: 'HS512' }), jwt.sign(valid, { secret: 'other-key' }),
      ]) await me(token).expect(401);
      await request(app.getHttpServer()).get('/api/auth/me').expect(401);
    });

    it('sanitizes credential-bearing errors in HTTP responses and logs', async () => {
      const log = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
      const lookup = jest.spyOn(app.get(UsersService), 'findForAuthentication')
        .mockRejectedValueOnce(new Error(credentials.password));
      try {
        const response = await post('login', credentials).expect(500);
        expect(JSON.stringify([response.body, log.mock.calls])).not.toContain(credentials.password);
      } finally { lookup.mockRestore(); log.mockRestore(); }
    });
  });
}
