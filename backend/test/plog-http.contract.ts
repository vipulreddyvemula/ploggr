import { fieldContract } from './field.contract';
import { type INestApplication, ServiceUnavailableException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import request from 'supertest';
import sharp from 'sharp';
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

    fieldContract(()=>app);

    async function attachPhoto(id: string, auth: { Authorization: string }) {
      const photo = await sharp({ create: { width: 2, height: 2, channels: 3, background: 'green' } }).png().toBuffer();
      return request(app.getHttpServer()).put('/api/plogs/' + id + '/evidence/' + randomUUID())
        .set(auth).attach('photo', photo, 'evidence.png').expect(200);
    }

    it('validates image content and limits concurrent reservations to six per owned Plog', async () => {
      const http = request(app.getHttpServer());
      const account = async () => (await http.post('/api/auth/signup').send({
        email: randomUUID() + '@example.test', password: randomUUID(),
      }).expect(201)).body.accessToken;
      const auth = { Authorization: 'Bearer ' + await account() };
      const other = { Authorization: 'Bearer ' + await account() };
      const { body: plog } = await http.post('/api/plogs').set(auth).expect(201);
      const jpeg = await sharp({ create: { width: 3, height: 3, channels: 3, background: 'red' } }).jpeg().toBuffer();
      const path = '/api/plogs/' + plog.id + '/evidence/';
      const upload = (id: string, bytes = jpeg) => http.put(path + id).set(auth).attach('photo', bytes, 'photo.jpg');
      const id = randomUUID();
      await http.put(path + id).expect(401);
      await http.put(path + id).set(other).attach('photo', jpeg, 'photo.jpg').expect(404);
      await upload(id, Buffer.from('wrong bytes')).expect(415);
      await upload(id, jpeg.subarray(0, 12)).expect(400);
      await upload(id, Buffer.alloc(8 * 1024 * 1024 + 1)).expect(413);
      const saved = await upload(id).expect(200);
      expect(saved.body).toMatchObject({ id, mediaType: 'image/jpeg', byteSize: jpeg.length });
      await upload(id).expect(200, saved.body);
      await http.get(path).expect(401);
      await http.get(path + id).expect(401);
      await http.get(path).set(other).expect(404);
      await http.get(path + id).set(other).expect(404);
      await http.get(path).set(auth).expect(200, { items: [saved.body] });
      const retrieved = await http.get(path + id).set(auth).expect('Content-Type', 'image/jpeg')
        .expect('Cache-Control', 'private, no-store').expect(200);
      expect(retrieved.body).toEqual(jpeg);
      const boundary = Buffer.alloc(8 * 1024 * 1024);
      jpeg.copy(boundary);
      await upload(randomUUID(), boundary).expect(200);
      const attempts = await Promise.all(Array.from({ length: 5 }, () => upload(randomUUID())));
      expect(attempts.map(r => r.status).sort()).toEqual([200, 200, 200, 200, 409]);
    });

    it('hides interrupted uploads, retries them once, and preserves activity details if a stored image disappears', async () => {
      const http = request(app.getHttpServer());
      const { body: account } = await http.post('/api/auth/signup')
        .send({ email: randomUUID() + '@example.test', password: randomUUID() }).expect(201);
      const auth = { Authorization: 'Bearer ' + account.accessToken };
      const { body: plog } = await http.post('/api/plogs').set(auth).expect(201);
      const first = await attachPhoto(plog.id, auth);
      const activity = '/api/plogs/' + plog.id;
      const path = activity + '/evidence/';
      const id = randomUUID();
      const image = (background: string) => sharp({ create: { width: 2, height: 2, channels: 3, background } }).png().toBuffer();
      const bytes = await image('blue');
      const put = (photoId: string, data: Buffer) => http.put(path + photoId).set(auth).attach('photo', data, 'photo.png');
      const finish = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route: [] };
      const unavailable = jest.spyOn(app.get(EvidenceStorage), 'put');
      try {
        unavailable.mockRejectedValueOnce(new ServiceUnavailableException());
        await put(id, bytes).expect(503);
      } finally {
        unavailable.mockRestore();
      }
      await http.get(path).set(auth).expect(200, { items: [first.body] });
      await http.get(path + id).set(auth).expect(404);
      await http.post(activity + '/finish').set(auth).send(finish).expect(422);
      await put(id, await image('red')).expect(409);
      const confirmed = await put(id, bytes).expect(200);
      await http.post(activity + '/finish').set(auth).send(finish).expect(200);
      await put(id, bytes).expect(200, confirmed.body);
      await put(randomUUID(), bytes).expect(409);
      await http.get(path).set(auth).expect(200, { items: [first.body, confirmed.body] });
      const retrieved = await http.get(path + id).set(auth).expect(200);
      expect(retrieved.body).toEqual(bytes);
      await app.get(DataSource).query('UPDATE garbage_evidence SET storage_key = $1 WHERE id = $2',
        ['evidence/' + randomUUID(), id]);
      await http.get(path + id).set(auth).expect(404);
      await http.get(path + first.body.id).set(auth).expect(200);
      await http.get(activity).set(auth).expect(200).expect(res => expect(res.body.status).toBe('completed'));
    });

    it('publishes geotagged photos and lets two other accounts collect one spot exactly once', async () => {
      const http = request(app.getHttpServer());
      const account = async () => ({
        Authorization:
          'Bearer ' +
          (
            await http
              .post('/api/auth/signup')
              .send({ email: randomUUID() + '@example.test', password: randomUUID() })
              .expect(201)
          ).body.accessToken,
      });
      const [author, walker, other] = await Promise.all([account(), account(), account()]);
      const id = randomUUID(),
        url = '/api/litter-reports/' + id;
      const photo = await sharp({ create: { width: 4, height: 5, channels: 3, background: 'green' } })
        .withMetadata()
        .jpeg()
        .toBuffer();
      const publish = (notes = 'Beside the bench') =>
        http
          .put(url)
          .set(author)
          .field({ latitude: '37.42', longitude: '-122.08', category: 'Plastic', notes })
          .attach('photos', photo, 'bottle.jpg');
      const outage = jest
        .spyOn(app.get(EvidenceStorage), 'put')
        .mockRejectedValueOnce(new ServiceUnavailableException());
      try {
        await publish().expect(503);
      } finally {
        outage.mockRestore();
      }
      await http.get(url).set(walker).expect(404);
      await publish().expect(200);
      await publish().expect(200);
      await publish('changed').expect(409);
      await http.get(url).expect(401);
      const found = await http
        .get('/api/litter-reports')
        .query({ west: -123, east: -122, south: 37, north: 38 })
        .set(walker)
        .expect(200);
      expect(found.body.items).toContainEqual(
        expect.objectContaining({
          id,
          notes: 'Beside the bench',
          latitude: 37.42,
          mine: false,
          photoCount: 1,
        }),
      );
      const image = await http
        .get(url + '/photos/0')
        .set(walker)
        .expect(200);
      expect((await sharp(image.body).metadata()).exif).toBeUndefined();
      await http.delete(url).set(walker).expect(404);
      await http
        .post(url + '/flags')
        .set(walker)
        .expect(204);
      const walks = await Promise.all(
        [walker, other].map(async (auth) => {
          const { body: p } = await http.post('/api/plogs').set(auth).expect(201);
          const pic = await attachPhoto(p.id, auth);
          const collection = randomUUID();
          await http
            .put('/api/litter-reports/' + collection + '/collection')
            .set(auth)
            .send({
              latitude: '37.42',
              longitude: '-122.08',
              category: 'Glass',
              notes: 'Collected',
              plogId: p.id,
              photoIds: [pic.body.id],
            })
            .expect(200);
          await http
            .get('/api/litter-reports/' + collection)
            .set(author)
            .expect(404);
          return { auth, p, collection };
        }),
      );
      await Promise.all(
        walks.map(async ({ p, auth, collection }) => {
          const data = {
            endedAt: new Date().toISOString(),
            durationSeconds: 0,
            distanceMeters: 0,
            route: [],
            pickupIds: [id],
          };
          await http
            .post('/api/plogs/' + p.id + '/finish')
            .set(auth)
            .send(data)
            .expect(200);
          await http
            .post('/api/plogs/' + p.id + '/finish')
            .set(auth)
            .send(data)
            .expect(200);
          await http
            .get('/api/plogs/' + p.id)
            .set(author)
            .expect(404);
          await http
            .get('/api/litter-reports/' + collection)
            .set(author)
            .expect(200)
            .expect((r) => expect(r.body.status).toBe('collected'));
        }),
      );
      await http
        .get(url)
        .set(walker)
        .expect(200)
        .expect((r) => expect(r.body.status).toBe('collected'));
      const empty = await http
        .get('/api/litter-reports')
        .query({ west: -123, east: -122, south: 37, north: 38 })
        .set(walker)
        .expect(200);
      expect(empty.body.items.map((item: { id: string }) => item.id)).not.toContain(id);
      await http.delete(url).set(author).expect(204);
      await http
        .get(url + '/photos/0')
        .set(walker)
        .expect(404);
    });

    it('finds reports across the dateline and preserves a walk when its target is withdrawn', async () => {
      const http = request(app.getHttpServer());
      const signup = async () => {
        const { body } = await http
          .post('/api/auth/signup')
          .send({
            email: randomUUID() + '@example.test',
            password: randomUUID(),
          })
          .expect(201);
        return { Authorization: 'Bearer ' + body.accessToken };
      };
      const [author, walker] = await Promise.all([signup(), signup()]);
      const photo = await sharp({ create: { width: 4, height: 4, channels: 3, background: 'green' } })
        .png()
        .toBuffer();
      const path = '/api/litter-reports';
      const ids = await Promise.all(
        ['179.9', '-179.9', '0'].map(async (longitude) => {
          const id = randomUUID();
          await http
            .put(path + '/' + id)
            .set(author)
            .field({ latitude: '0', longitude, category: 'Other', notes: '' })
            .attach('photos', photo, 'litter.png')
            .expect(200);
          return id;
        }),
      );
      const view = { west: 179, east: -179, south: -1, north: 1 };
      const { body } = await http.get(path).set(walker).query(view).expect(200);
      expect(body.items.map((r: { id: string }) => r.id).sort()).toEqual(ids.slice(0, 2).sort());
      await http
        .get(path)
        .set(walker)
        .query({ ...view, south: 3 })
        .expect(400);
      const { body: plog } = await http.post('/api/plogs').set(walker).expect(201);
      const evidence = await attachPhoto(plog.id, walker);
      await http
        .put(path + '/' + randomUUID() + '/collection')
        .set(author)
        .send({
          latitude: '0',
          longitude: '179.9',
          category: 'Other',
          notes: '',
          plogId: plog.id,
          photoIds: [evidence.body.id],
        })
        .expect(404);
      await http
        .delete(path + '/' + ids[0])
        .set(author)
        .expect(204);
      const finish = {
        endedAt: new Date().toISOString(),
        durationSeconds: 0,
        distanceMeters: 0,
        route: [],
        pickupIds: [ids[0]],
      };
      const endpoint = '/api/plogs/' + plog.id + '/finish';
      await http.post(endpoint).set(walker).send(finish).expect(200);
      await http.post(endpoint).set(walker).send(finish).expect(200);
      await http
        .get(path + '/' + ids[0])
        .set(walker)
        .expect(404);
      await http
        .get(path + '/' + ids[0] + '/photos/0')
        .set(walker)
        .expect(404);
    });

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
      await http.get('/api/plogs/summary').expect(401);
      await http.post('/api/plogs').expect(401);
      await http.get('/api/plogs/active').expect(401);
      const { body: active } = await http.post('/api/plogs').set('Authorization', 'Bearer ' + owner.accessToken).expect(201);
      expect(active).toMatchObject({ userId: owner.user.id, status: 'active', endedAt: null });
      const auth = { Authorization: 'Bearer ' + owner.accessToken };
      const foreign = { Authorization: 'Bearer ' + other.accessToken };
      await http.get('/api/plogs/active').set(auth).expect(200, { plog: active });
      await http.get('/api/plogs/active').set(foreign).expect(200, { plog: null });
      await http.get('/api/plogs/summary').set(auth).expect(200, { sessions: 0, distanceMeters: 0, reports:0,trackedSessions:0 });
      await http.post('/api/plogs').set(auth).expect(409);
      const detail = '/api/plogs/' + active.id;
      await http.get(detail).set(auth).expect(404);
      const url = detail + '/finish';
      const data = { endedAt: new Date().toISOString(), durationSeconds: 15, distanceMeters: 12.5,
        route: [{ latitude: 17.01, longitude: 78.12 }, { latitude: 17.0101, longitude: 78.12 }] };
      await http.post(url).send(data).expect(401);
      await http.post(url).set(foreign).send(data).expect(404);
      await http.post(url).set(auth).send({ ...data, route: [{ latitude: 121, longitude: 0 }] }).expect(400);
      await http.post(url).set(auth).send({ ...data, endedAt: '2000-01-01T00:00:00Z' }).expect(400);
      await http.post(url).set(auth).send(data).expect(422);
      await attachPhoto(active.id, auth);
      const completed = await http.post(url).set(auth).send(data).expect(200);
      expect(completed.body).toMatchObject({ id: active.id, status: 'completed', endedAt: data.endedAt });
      await http.get(detail).expect(401);
      await http.get(detail).set(foreign).expect(404);
      await http.get(detail).set(auth).expect(200, { ...completed.body, segmentStarts:[],route: data.route });
      await http.get('/api/plogs').set(auth).expect(200, { items: [completed.body], nextCursor: null });
      await http.get('/api/plogs').set(foreign).expect(200, { items: [], nextCursor: null });
      await http.get('/api/plogs?before=' + active.id).set(auth).expect(200, { items: [], nextCursor: null });
      await http.get('/api/plogs?before=invalid').set(auth).expect(400);
      await http.post(url).set(auth).send(data).expect(200, completed.body);
      await http.get('/api/plogs/summary').set(auth).expect(200, { sessions: 1, distanceMeters: 12.5,reports:0,trackedSessions:1 });
      await http.get('/api/plogs/summary').set(foreign).expect(200, { sessions: 0, distanceMeters: 0, reports:0,trackedSessions:0 });
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
      await attachPhoto(active.id, auth);
      const route = Array.from({ length: 3500 }, (_, i) => ({ latitude: 37.422, longitude: -122 + i / 100000 }));
      const finish = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route };
      expect(JSON.stringify(finish).length).toBeGreaterThan(102400);
      await http.post('/api/plogs/' + active.id + '/finish').set(auth).send(finish).expect(200);
      const { body: saved } = await http.get('/api/plogs/' + active.id).set(auth).expect(200);
      expect(saved.route).toEqual(route);
    });
  });
}
