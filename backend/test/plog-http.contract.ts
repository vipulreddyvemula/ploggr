import { type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import request from 'supertest';
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

    it('authenticates starts and finishes, scopes ownership, and safely retries a lost finish response', async () => {
      const http = request(app.getHttpServer());
      const signup = async () => (await http.post('/api/auth/signup')
        .send({ email: randomUUID() + '@example.test', password: randomUUID() }).expect(201)).body;
      const owner = await signup();
      const other = await signup();
      await http.post('/api/plogs').expect(401);
      await http.get('/api/plogs/active').expect(401);
      const { body: active } = await http.post('/api/plogs').set('Authorization', 'Bearer ' + owner.accessToken).expect(201);
      expect(active).toMatchObject({ userId: owner.user.id, status: 'active', endedAt: null });
      const auth = { Authorization: 'Bearer ' + owner.accessToken };
      const foreign = { Authorization: 'Bearer ' + other.accessToken };
      await http.get('/api/plogs/active').set(auth).expect(200, { plog: active });
      await http.get('/api/plogs/active').set(foreign).expect(200, { plog: null });
      await http.post('/api/plogs').set(auth).expect(409);
      const url = '/api/plogs/' + active.id + '/finish';
      const data = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0,
        route: [{ latitude: 17.01, longitude: 78.12 }] };
      await http.post(url).send(data).expect(401);
      await http.post(url).set(foreign).send(data).expect(404);
      await http.post(url).set(auth).send({ ...data, route: [{ latitude: 121, longitude: 0 }] }).expect(400);
      await http.post(url).set(auth).send({ ...data, endedAt: '2000-01-01T00:00:00Z' }).expect(400);
      const completed = await http.post(url).set(auth).send(data).expect(200);
      expect(completed.body).toMatchObject({ id: active.id, status: 'completed', endedAt: data.endedAt });
      await http.post(url).set(auth).send(data).expect(200, completed.body);
      await http.post(url).set(auth).send({ ...data, route: [] }).expect(409);
      await http.get('/api/plogs/active').set(auth).expect(200, { plog: null });
    });
  });
}
