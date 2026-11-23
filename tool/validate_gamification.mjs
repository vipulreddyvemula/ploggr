import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run, runCli } from '../backend/test/commands.mjs';
import { runDatabaseIntegration, unusedPort } from '../backend/test/run-database-integration.mjs';
import { startApi } from './validation_api.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const require = createRequire(new URL('../backend/package.json', import.meta.url));
const { Client } = require('pg');
const { hash } = require('argon2');
const sharp = require('sharp');

await runCli(signal => runDatabaseIntegration(signal, async ({ env }) => {
  const port = await unusedPort();
  const base = `http://127.0.0.1:${port}/api/`;
  const moderator = { id: randomUUID(), email: 'moderator@example.test', password: randomUUID() };
  const member = { email: 'plogger@example.test', password: randomUUID() };
  async function query(sql, params) {
    const database = new Client({
      host: env.DB_HOST, port: Number(env.DB_PORT), database: env.DB_NAME,
      user: env.DB_USER, password: env.DB_PASSWORD,
    });
    await database.connect();
    try { return await database.query(sql, params); }
    finally { await database.end(); }
  }
  await query('INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)',
    [moderator.id, moderator.email, await hash(moderator.password)]);

  const fixturePath = await mkdtemp(join(tmpdir(), 'ploggr-m5-'));
  const api = startApi({ ...env, PORT: port, GEMINI_API_KEY: '', MODERATOR_IDS: moderator.id });
  try {
    await api.ready(signal);
    async function request(path, method, status, body, token) {
      const json = body && !(body instanceof FormData);
      const response = await fetch(base + path, {
        method,
        headers: { ...(token && { Authorization: 'Bearer ' + token }), ...(json && { 'Content-Type': 'application/json' }) },
        ...(body && { body: json ? JSON.stringify(body) : body }),
        signal: AbortSignal.any([signal, AbortSignal.timeout(10000)]),
      });
      assert.equal(response.status, status, `${method} ${path}`);
      return response.json();
    }
    const admin = await request('auth/login', 'POST', 200, { email: moderator.email, password: moderator.password });
    const owner = await request('auth/signup', 'POST', 201, member);
    const photo = async color => new Blob([await sharp({ create: {
      width: 12, height: 12, channels: 3, background: color,
    } }).png().toBuffer()], { type: 'image/png' });
    const plog = await request('plogs', 'POST', 201, undefined, owner.accessToken);
    const pickup = new FormData();
    const photoId = randomUUID();
    const capturedAt = new Date().toISOString();
    pickup.set('capture', JSON.stringify({ source: 'camera', capturedAt }));
    pickup.set('photo', await photo('#344456'), 'pickup.png');
    await request(`plogs/${plog.id}/evidence/${photoId}`, 'PUT', 200, pickup, owner.accessToken);
    await request(`plogs/${plog.id}/finish`, 'POST', 200, {
      endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route: [],
    }, owner.accessToken);
    const stored = await request(`plogs/${plog.id}/analysis`, 'GET', 200, undefined, owner.accessToken);
    assert.equal(stored.reward.status, 'pending');
    // Reproduce the worker's handoff of uncertain evidence to moderation without an external AI service.
    await query("UPDATE plog_analysis SET state='review' WHERE plog_id=$1", [plog.id]);

    const fixture = join(fixturePath, 'fixture.json');
    await writeFile(fixture, JSON.stringify({ ...member, moderatorToken: admin.accessToken, plogId: plog.id, photoId }), { mode: 0o600 });
    await run('flutter', ['test', '--no-pub', '-d', 'linux', 'integration_test/gamification_test.dart',
      `--dart-define=API_BASE_URL=${base}`, `--dart-define=M5_FIXTURE_PATH=${fixture}`],
    { cwd: root, signal, timeout: 240000 });
  } finally {
    try { await api.stop(); }
    finally { await rm(fixturePath, { recursive: true, force: true }); }
  }
  console.log('Live gamification flow passed.');
}));
