import { type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import request from 'supertest';
import { DataSource } from 'typeorm';
import { EvidenceStorage } from '../src/modules/evidence/evidence-storage';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/app.setup';

export function plogHttpContract() {
  describe('Plog lifecycle HTTP contract', () => {
    let app: INestApplication;
    beforeAll(async () => {
      app = (await Test.createTestingModule({ imports: [AppModule] }).compile()).createNestApplication();
      configureApp(app);
      await app.init();
    });
    afterAll(async () => { await app?.close(); });

    it('stores and reads an image privately in the isolated S3 bucket', async () => {
      const storage = app.get(EvidenceStorage);
      const key = 'evidence/' + randomUUID();
      const bytes = Buffer.from('private storage contract');
      await storage.put(key, bytes, 'application/octet-stream');
      expect(await storage.read(key)).toEqual(bytes);
      const anonymous = await fetch(process.env.EVIDENCE_S3_ENDPOINT + '/' + process.env.EVIDENCE_S3_BUCKET + '/' + key);
      expect([401, 403]).toContain(anonymous.status);
      await expect(storage.read('evidence/' + randomUUID())).rejects.toMatchObject({ status: 404 });
    });

    it('authenticates starts and finishes, scopes ownership, and safely retries a lost finish response', async () => {
      const http = request(app.getHttpServer());
      const signup = async () => (await http.post('/api/auth/signup')
        .send({ email: randomUUID() + '@example.test', password: randomUUID() }).expect(201)).body;
      const owner = await signup();
      const other = await signup();
      await http.get('/api/plogs').expect(401);
      await http.post('/api/plogs').expect(401);
      await http.get('/api/plogs/active').expect(401);
      const { body: active } = await http.post('/api/plogs').set('Authorization', 'Bearer ' + owner.accessToken).expect(201);
      expect(active).toMatchObject({ userId: owner.user.id, status: 'active', endedAt: null });
      const auth = { Authorization: 'Bearer ' + owner.accessToken };
      const foreign = { Authorization: 'Bearer ' + other.accessToken };
      await http.get('/api/plogs/active').set(auth).expect(200, { plog: active });
      await http.get('/api/plogs/active').set(foreign).expect(200, { plog: null });
      await http.post('/api/plogs').set(auth).expect(409);
      const detail = '/api/plogs/' + active.id;
      await http.get(detail).set(auth).expect(404);
      const url = detail + '/finish';
      const data = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0,
        route: [{ latitude: 17.01, longitude: 78.12 }] };
      await http.post(url).send(data).expect(401);
      await http.post(url).set(foreign).send(data).expect(404);
      await http.post(url).set(auth).send({ ...data, route: [{ latitude: 121, longitude: 0 }] }).expect(400);
      await http.post(url).set(auth).send({ ...data, endedAt: '2000-01-01T00:00:00Z' }).expect(400);
      const completed = await http.post(url).set(auth).send(data).expect(200);
      expect(completed.body).toMatchObject({ id: active.id, status: 'completed', endedAt: data.endedAt });
      await http.get(detail).expect(401);
      await http.get(detail).set(foreign).expect(404);
      await http.get(detail).set(auth).expect(200, { ...completed.body, route: data.route });
      await http.get('/api/plogs').set(auth).expect(200, { items: [completed.body], nextCursor: null });
      await http.get('/api/plogs').set(foreign).expect(200, { items: [], nextCursor: null });
      await http.get('/api/plogs?before=' + active.id).set(auth).expect(200, { items: [], nextCursor: null });
      await http.get('/api/plogs?before=invalid').set(auth).expect(400);
      await http.post(url).set(auth).send(data).expect(200, completed.body);
      await http.post(url).set(auth).send({ ...data, route: [] }).expect(409);
      await http.get('/api/plogs/active').set(auth).expect(200, { plog: null });
    });

    it('pages completed activities with tied end times and accepts routes above the default JSON limit', async () => {
      const http = request(app.getHttpServer());
      const { body: owner } = await http.post('/api/auth/signup')
        .send({ email: randomUUID() + '@example.test', password: randomUUID() }).expect(201);
      const auth = { Authorization: 'Bearer ' + owner.accessToken };
      await app.get(DataSource).query(`
        INSERT INTO plogs(user_id, started_at, ended_at, status)
        SELECT $1, now(), now(), 'completed' FROM generate_series(1, 26)
      `, [owner.user.id]);
      const first = await http.get('/api/plogs').set(auth).expect(200);
      expect(first.body.items).toHaveLength(25);
      expect(first.body.nextCursor).toBe(first.body.items[24].id);
      const last = await http.get('/api/plogs').set(auth).query({ before: first.body.nextCursor }).expect(200);
      expect(last.body.nextCursor).toBeNull();
      expect(new Set([...first.body.items, ...last.body.items].map(p => p.id)).size).toBe(26);
      const { body: active } = await http.post('/api/plogs').set(auth).expect(201);
      const route = Array.from({ length: 3500 }, (_, i) => ({ latitude: 37.422, longitude: -122 + i / 100000 }));
      const finish = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route };
      expect(JSON.stringify(finish).length).toBeGreaterThan(102400);
      await http.post('/api/plogs/' + active.id + '/finish').set(auth).send(finish).expect(200);
      const { body: saved } = await http.get('/api/plogs/' + active.id).set(auth).expect(200);
      expect(saved.route).toEqual(route);
    });
  });
}
