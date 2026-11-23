import { randomUUID } from 'node:crypto';
import { type INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DataSource } from 'typeorm';
import request from 'supertest';
import sharp from 'sharp';
import { AnalysisWorker } from '../src/modules/field/analysis.service';

export function fieldContract(instance: () => INestApplication) {
  const app = () => instance();
  const http = () => request(app().getHttpServer());
  const db = () => app().get(DataSource);
  const account = async () => {
    const credentials = { email: randomUUID() + '@example.test', password: randomUUID() };
    const { body } = await http().post('/api/auth/signup').send(credentials).expect(201);
    return { auth: { Authorization: 'Bearer ' + body.accessToken }, id: body.user.id, credentials };
  };

  it('keeps partial and missing sightings open and accepts one independently confirmed cleanup', async () => {
    const a = await account(),
      b = await account();
    const cfg = app().get(ConfigService);
    cfg.set('MODERATOR_IDS', a.id);
    const image = await sharp({ create: { width: 5, height: 6, channels: 3, background: '#42a353' } })
      .png()
      .toBuffer();
    const spot = randomUUID(),
      path = '/api/litter-reports/' + spot;
    await http()
      .put(path)
      .set(a.auth)
      .field('latitude', '19.09')
      .field('longitude', '72.88')
      .field('category', 'Glass')
      .field('notes', 'At the gate')
      .field('place', 'Park gate')
      .attach('photos', image, 'spot.png')
      .expect(200);
    const bbox = { south: 19, west: 72, north: 20, east: 73 };
    const clusters = await http().get('/api/litter-reports/clusters').set(b.auth).query(bbox).expect(200);
    expect(clusters.body).toContainEqual(expect.objectContaining({ id: spot, count: 1 }));
    expect(
      (
        await http()
          .get('/api/litter-reports/nearby')
          .set(b.auth)
          .query({ lat: 19.09, lon: 72.88 })
          .expect(200)
      ).body[0].place,
    ).toBe('Park gate');
    const observation = () => path + '/observations/' + randomUUID();
    const gps = (longitude = 72.88) => ({
      latitude: 19.09, longitude, accuracyMeters: 5, recordedAt: new Date().toISOString(),
    });
    await http().put(observation()).set(b.auth).send({ outcome: 'missing', gps: gps(73.88) })
      .expect(200).expect(r => expect(r.body.verification).toBe('unverified'));
    await http().get(path).set(b.auth).expect(200).expect(r => expect(r.body.needsChecking).toBe(false));
    await http().put(observation()).set(b.auth).send({ outcome: 'missing', gps: gps() })
      .expect(200).expect(r => expect(r.body.verification).toBe('verified'));
    await http().get(path).set(b.auth).expect(200).expect(r => expect(r.body.needsChecking).toBe(true));
    await http().put(observation()).set(b.auth).send({ outcome: 'missing', gps: gps() }).expect(200);
    const moderation = async () =>
      (await http().get('/api/moderation').set(a.auth)).body.reports.map((s: { id: string }) => s.id);
    expect(await moderation()).not.toContain(spot);
    await http().put(observation()).set(a.auth).send({ outcome: 'missing', gps: gps() }).expect(200);
    expect(await moderation()).toContain(spot);

    const prepare = async (auth: typeof a.auth, color: string, longitude = 72.88) => {
      const plogId = (await http().post('/api/plogs').set(auth).expect(201)).body.id;
      const upload = async (background: string, position = longitude) => {
        const photoId = randomUUID();
        const capture = { source: 'camera', capturedAt: new Date().toISOString(), gps: gps(position) };
        const bytes = await sharp({ create: { width: 5, height: 6, channels: 3, background } }).png().toBuffer();
        await http().put('/api/plogs/' + plogId + '/evidence/' + photoId).set(auth)
          .field('capture', JSON.stringify(capture)).attach('photo', bytes, 'pickup.png').expect(200);
        return photoId;
      };
      const photoId = await upload(color);
      const finish = () => http().post('/api/plogs/' + plogId + '/finish').set(auth)
        .send({ endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route: [] }).expect(200);
      return { claim: { outcome: 'cleaned', photoId, plogId }, finish, upload };
    };
    const far = await prepare(a.auth, 'orange', 73.88);
    const farReceipt = observation();
    await http().put(farReceipt).set(a.auth).send(far.claim).expect(200);
    await far.finish();
    await http().put(farReceipt).set(a.auth).send(far.claim)
      .expect(200).expect(r => expect(r.body.verification).toBe('unverified'));
    await http().get(path).set(b.auth).expect(200).expect(r => expect(r.body.status).toBe('open'));

    const aWalk = await prepare(a.auth, 'blue');
    const bWalk = await prepare(b.auth, 'purple');
    await http().put(observation()).set(b.auth).send(aWalk.claim).expect(404);
    await http().put(observation()).set(a.auth)
      .send({ ...aWalk.claim, plogId: bWalk.claim.plogId }).expect(404);
    const receipt = observation();
    await Promise.all([
      http().put(receipt).set(a.auth).send(aWalk.claim).expect(200),
      http().put(observation()).set(b.auth).send(bWalk.claim).expect(200),
    ]);
    const duplicate = await aWalk.upload('blue');
    await http().put(observation()).set(a.auth).send({ ...aWalk.claim, photoId: duplicate }).expect(422);
    await http().get(path).set(b.auth).expect(200).expect(r => expect(r.body.status).toBe('open'));
    await Promise.all([aWalk.finish(), bWalk.finish()]);
    await http().put(receipt).set(a.auth).send(aWalk.claim).expect(200);
    await http().put(observation()).set(a.auth).send(aWalk.claim).expect(422);
    expect(await db().query('SELECT id FROM spot_observations WHERE report_id=$1 AND resolved', [spot])).toHaveLength(1);
    const details = await Promise.all([aWalk.claim, bWalk.claim].map((claim, index) =>
      http().get('/api/plogs/' + claim.plogId).set(index === 0 ? a.auth : b.auth).expect(200)));
    expect(details.map(response => response.body.cleanupClaims)).toEqual(expect.arrayContaining([
      { verified: 1, unverified: 0 }, { verified: 0, unverified: 0, alreadyCollected: 1 },
    ]));
    const totals = await Promise.all([a.auth, b.auth].map(auth => http().get('/api/plogs/summary').set(auth).expect(200)));
    expect(totals.map(response => response.body.verifiedCleanups ?? 0).sort()).toEqual([0, 1]);
    await http().get('/api/litter-reports').set(b.auth).query(bbox).expect(200)
      .expect(r => expect(r.body.items.map((s: { id: string }) => s.id)).not.toContain(spot));
  });

  it('saves a private, unpinned pickup then analyzes, reviews and scores it under an explicit policy', async () => {
    const a = await account(),
      b = await account();
    const cfg = app().get(ConfigService);
    cfg.set('MODERATOR_IDS', b.id);
    const id = (await http().post('/api/plogs').set(a.auth)).body.id,
      photo = randomUUID(),
      path = '/api/plogs/' + id;
    const image = await sharp({ create: { width: 12, height: 11, channels: 3, background: '#777811' } })
      .jpeg()
      .toBuffer();
    for (const key of [photo, randomUUID()])
      await http()
        .put(path + '/evidence/' + key)
        .set(a.auth)
        .attach('photo', image, 'pickup.jpg')
        .expect(200);
    const finish = { endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route: [] };
    await http()
      .post(path + '/finish')
      .set(a.auth)
      .send(finish)
      .expect(200);
    await http()
      .post(path + '/finish')
      .set(a.auth)
      .send(finish)
      .expect(200);
    await http()
      .get(path + '/analysis')
      .set(b.auth)
      .expect(404);
    await http()
      .get(path + '/analysis')
      .set(a.auth)
      .expect(200)
      .expect((r) => expect(r.body.state).toBe('queued'));
    const provider = jest.spyOn(global, 'fetch');
    const prioritize = () =>
      db().query("UPDATE plog_analysis SET next_run='2000-01-01' WHERE plog_id=$1", [id]);
    cfg.set('GEMINI_API_KEY', 'test-only');
    try {
      await prioritize();
      provider.mockResolvedValueOnce(new Response('', { status: 503 }));
      await app().get(AnalysisWorker).processNext();
      await prioritize();
      provider.mockResolvedValueOnce(
        Response.json({
          modelVersion: 'test-vision',
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      quality: 'clear',
                      items: [
                        {
                          label: 'bottle',
                          material: 'Plastic',
                          count: 2,
                          photos: [0],
                          box: [0, 0, 100, 100],
                          certain: true,
                        },
                      ],
                    }),
                  },
                ],
              },
            },
          ],
        }),
      );
      await app().get(AnalysisWorker).processNext();
      const parts = JSON.parse(provider.mock.calls[1][1]!.body as string).contents[0].parts;
      expect(parts.filter((p: Record<string, unknown>) => p.inlineData)).toHaveLength(1);
    } finally {
      provider.mockRestore();
      cfg.set('GEMINI_API_KEY', '');
    }
    await http()
      .get(path + '/analysis')
      .set(a.auth)
      .expect(200)
      .expect((r) =>
        expect(r.body).toMatchObject({ state: 'ready', result: { items: [{ label: 'bottle', count: 2 }] } }),
      );
    await http()
      .get('/api/leaderboard')
      .set(a.auth)
      .expect(200)
      .expect((r) => expect(r.body.rules).toBeNull());
    await http()
      .post(path + '/analysis/review')
      .set(a.auth)
      .expect(201);
    await http()
      .get('/api/moderation/analysis/' + id + '/photos/' + photo)
      .set(a.auth)
      .expect(403);
    await http()
      .get('/api/moderation/analysis/' + id + '/photos/' + photo)
      .set(b.auth)
      .expect(200);
    await http()
      .put('/api/moderation/analysis/' + id)
      .set(b.auth)
      .send({ items: [{ label: 'bottle', material: 'Plastic', count: 2, photoIds: [photo] }] })
      .expect(200);
    await db().query(
      "INSERT INTO disposal_factors VALUES('test','Plastic','landfill',2,'Test fixture','v1'),('test','Plastic','recycle',1,'Test fixture','v1')",
    );
    await http()
      .put(path + '/disposal')
      .set(a.auth)
      .send({
        material: 'Plastic',
        region: 'test',
        massKg: 0.5,
        baseline: 'landfill',
        actual: 'recycle',
        version: 'v1',
      })
      .expect(200)
      .expect((r) => expect(r.body.impacts[0].avoidedKg).toBe(0.5));
    await db().query(`INSERT INTO impact_rules VALUES('fixture','{"Plastic":2}',2,true)`);
    try {
      for (const period of ['week', 'month', 'all'])
        await http()
          .get('/api/leaderboard')
          .set(a.auth)
          .query({ period })
          .expect(200)
          .expect((r) => expect(r.body.mine).toMatchObject({ rank: 1, score: 5, mine: true }));
    } finally {
      await db().query("DELETE FROM impact_rules WHERE version='fixture'");
    }
  });

  it('exchanges a PKCE authorization code and recovers a password with a single-use mailed code', async () => {
    const cfg = app().get(ConfigService),
      provider = jest.spyOn(global, 'fetch');
    const a = await account();
    cfg.set('RESEND_API_KEY', 'fixture');
    cfg.set('MAIL_FROM', 'team@example.test');
    cfg.set('AUTH_OIDC_ISSUER', 'https://issuer.example.test');
    cfg.set('AUTH_OIDC_CLIENT_ID', 'native-fixture');
    cfg.set('AUTH_OIDC_METHODS', 'google,apple,phone');
    try {
      await http()
        .get('/api/auth/options')
        .expect(200)
        .expect((r) =>
          expect(r.body).toMatchObject({ methods: ['google', 'apple', 'phone'], recovery: true }),
        );
      await http().post('/api/auth/password/request').send({ email: 'unknown@example.test' }).expect(202);
      expect(provider).not.toHaveBeenCalled();
      provider.mockResolvedValueOnce(Response.json({ id: 'mail' }));
      await http().post('/api/auth/password/request').send({ email: a.credentials.email }).expect(202);
      const email = JSON.parse(provider.mock.calls[0][1]!.body as string);
      const code = (email.text as string).match(/\b\d{8}\b/)![0];
      const password = randomUUID();
      await http()
        .post('/api/auth/password/reset')
        .send({ email: a.credentials.email, password, code: '999999999' })
        .expect(400);
      await http()
        .post('/api/auth/password/reset')
        .send({ email: a.credentials.email, password, code })
        .expect(204);
      await http()
        .post('/api/auth/password/reset')
        .send({ email: a.credentials.email, password, code })
        .expect(400);
      await http().post('/api/auth/login').send(a.credentials).expect(401);
      await http().post('/api/auth/login').send({ email: a.credentials.email, password }).expect(200);
      await http().get('/api/auth/me').set(a.auth).expect(401);
      const external = { code: 'auth-code', verifier: 'v'.repeat(43) };
      provider.mockResolvedValueOnce(new Response('', { status: 401 }));
      await http().post('/api/auth/external').send(external).expect(401);
      const externalEmail = randomUUID() + '@example.test';
      for (let i = 0; i < 2; i++) {
        provider
          .mockResolvedValueOnce(Response.json({ access_token: 'provider-access' }))
          .mockResolvedValueOnce(
            Response.json({ sub: 'google-oauth2|field', email: externalEmail, email_verified: true }),
          );
        await http()
          .post('/api/auth/external')
          .send(external)
          .expect(200)
          .expect((r) => expect(r.body.user.email).toBe(externalEmail));
      }
    } finally {
      provider.mockRestore();
      for (const k of [
        'RESEND_API_KEY',
        'MAIL_FROM',
        'AUTH_OIDC_ISSUER',
        'AUTH_OIDC_CLIENT_ID',
        'AUTH_OIDC_METHODS',
      ])
        cfg.set(k, '');
    }
  });

  it('persists community, organizer and participant actions across accounts', async () => {
    const a = await account(),
      b = await account();
    await http().put('/api/profile').set(a.auth).send({ name: 'Park organizer' }).expect(200);
    const post = '/api/community/posts/' + randomUUID();
    await http().put(post).set(a.auth).send({ body: 'Saturday cleanup' }).expect(200);
    await http()
      .put(post + '/reaction')
      .set(b.auth)
      .send({ selected: true })
      .expect(200);
    await http()
      .put(post + '/reaction')
      .set(b.auth)
      .send({ selected: true })
      .expect(200);
    await http()
      .put(post + '/comments/' + randomUUID())
      .set(b.auth)
      .send({ body: 'See you there' })
      .expect(200);
    expect((await http().get('/api/community/posts').set(a.auth)).body.items[0]).toMatchObject({
      author: 'Park organizer',
      likes: 1,
      comments: 1,
    });
    await http().delete(post).set(b.auth).expect(403);
    const id = randomUUID(),
      event = '/api/events/' + id,
      start = new Date(Date.now() + 86400000).toISOString();
    const eventData = {
      title: 'Riverside',
      place: 'Bridge',
      latitude: 18.5,
      longitude: 73.8,
      startsAt: start,
    };
    await http().put(event).set(a.auth).send(eventData).expect(200);
    await http().put(event).set(b.auth).send(eventData).expect(409);
    await http()
      .put(event + '/rsvp')
      .set(b.auth)
      .send({ selected: true })
      .expect(200);
    expect((await http().get('/api/events').set(b.auth)).body[0]).toMatchObject({
      id,
      joined: true,
      going: 1,
    });
    await http()
      .put(event + '/rsvp')
      .set(b.auth)
      .send({ selected: false })
      .expect(200);
    await http().delete(event).set(a.auth).expect(200);
    await http()
      .put('/api/challenges/' + randomUUID())
      .set(a.auth)
      .send({
        title: 'Two walks',
        goal: 2,
        startsAt: start,
        endsAt: new Date(Date.now() + 3 * 86400000).toISOString(),
      })
      .expect(200);
    expect((await http().get('/api/challenges').set(b.auth)).body[0]).toMatchObject({
      goal: 2,
      progress: 0,
      mine: false,
    });
    expect(
      (await http().get('/api/badges').set(a.auth)).body.find(
        (r: { name: string }) => r.name === 'Community voice',
      ).earned,
    ).toBeTruthy();
  });
}
