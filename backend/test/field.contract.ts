import { randomBytes, randomUUID } from 'node:crypto';
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
    const discover = (filters: Record<string, string | number>) =>
      http().get('/api/litter-reports').set(b.auth).query({ ...bbox, ...filters });
    const hasSpot = (response: { body: { items: { id: string }[] } }) =>
      response.body.items.some(item => item.id === spot);
    await discover({ status: 'open', category: 'Glass', lat: 19.09, lon: 72.88,
      radius: 1000, sort: 'nearest', ageDays: 7, limit: 1 }).expect(200)
      .expect(r => expect(r.body.items).toEqual([expect.objectContaining({ id: spot, distance: 0 })]));
    await discover({ category: 'Paper' }).expect(200).expect(r => expect(hasSpot(r)).toBe(false));
    await discover({ lat: 19.09, lon: 72.99, radius: 1000 }).expect(200)
      .expect(r => expect(hasSpot(r)).toBe(false));
    await discover({ radius: 1000 }).expect(400);
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
    await discover({ status: 'verification' }).expect(200).expect(r => expect(hasSpot(r)).toBe(true));
    await discover({ status: 'open' }).expect(200).expect(r => expect(hasSpot(r)).toBe(false));
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
    expect(details.find(r => r.body.cleanupClaims.verified === 1)?.body.cleanupLocations).toEqual([
      { id: spot, category: 'Glass', place: 'Park gate', latitude: 19.09, longitude: 72.88 },
    ]);
    expect(details.find(r => r.body.cleanupClaims.alreadyCollected === 1)?.body.cleanupLocations).toBeUndefined();
    await http().get('/api/plogs/' + aWalk.claim.plogId).set(b.auth).expect(404);
    const totals = await Promise.all([a.auth, b.auth].map(auth => http().get('/api/plogs/summary').set(auth).expect(200)));
    expect(totals.map(response => response.body.verifiedCleanups ?? 0).sort()).toEqual([0, 1]);
    await http().get('/api/litter-reports').set(b.auth).query(bbox).expect(200)
      .expect(r => expect(r.body.items.map((s: { id: string }) => s.id)).not.toContain(spot));
    await discover({ status: 'collected', category: 'Glass' }).expect(200)
      .expect(r => expect(hasSpot(r)).toBe(true));
  });

  it('analyzes a private pickup across multiple photos and keeps it outside rankings after review', async () => {
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
    const second = randomUUID();
    const otherView = await sharp(randomBytes(16 * 16 * 3), {
      raw: { width: 16, height: 16, channels: 3 },
    }).png().toBuffer();
    await http().put(path + '/evidence/' + second).set(a.auth)
      .attach('photo', otherView, 'other-view.png').expect(200);
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
    const clock = jest.spyOn(Date, 'now');
    cfg.set('GEMINI_API_KEY', 'test-only');
    try {
      await prioritize();
      provider.mockResolvedValueOnce(new Response('', { status: 503 }))
        .mockResolvedValueOnce(new Response('', { status: 503 }));
      await app().get(AnalysisWorker).processNext();
      await http().get(path + '/analysis').set(a.auth).expect(200)
        .expect(r => expect(r.body).toMatchObject({ state: 'queued', retryAt: expect.any(String) }));
      clock.mockReturnValue(Date.now() + 120_000);
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
                          material: 'PET plastic',
                          type: 'Bottle',
                          count: 2,
                          weight: { estimateKg: 0.04, minKg: 0.03, maxKg: 0.06 },
                          photos: [0, 1],
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
      const parts = JSON.parse(provider.mock.calls[2][1]!.body as string).contents[0].parts;
      expect(parts.filter((p: Record<string, unknown>) => p.inlineData)).toHaveLength(2);
    } finally {
      clock.mockRestore();
      provider.mockRestore();
      cfg.set('GEMINI_API_KEY', '');
    }
    await http()
      .get(path + '/analysis')
      .set(a.auth)
      .expect(200)
      .expect((r) =>
        expect(r.body).toMatchObject({
          state: 'ready', model: 'test-vision', retryAt: null, result: { items: [{
            label: 'bottle', count: 2, type: 'Bottle', weight: { estimateKg: 0.04 },
            photoIds: expect.arrayContaining([photo, second]),
            potentialImpact: { baseline: 'Landfill', alternative: 'Recycling', avoidedKg: expect.any(Number) },
          }] },
          reward: { status: 'ineligible', earnedPoints: 0 },
        }),
      );
    await http()
      .get('/api/leaderboard')
      .set(a.auth)
      .expect(200)
      .expect((r) => expect(r.body).toMatchObject({ rules: { version: 'm5-v1' }, mine: null }));
    await http()
      .post(path + '/analysis/review')
      .set(a.auth)
      .send({ note: 'Please check the bottle count.' })
      .expect(201);
    await http().get('/api/moderation/analysis').set(b.auth).expect(200)
      .expect(r => expect(r.body).toContainEqual(expect.objectContaining({
        id, reviewNote: 'Please check the bottle count.',
      })));
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
      .send({ items: [{ label: 'bottle', material: 'PET plastic', type: 'Bottle', count: 2, photoIds: [second, photo] }] })
      .expect(200);
    await http().get(path + '/analysis').set(a.auth).expect(200).expect(r => {
      expect(r.body).toMatchObject({
        reviewed: true, reported: false,
        result: { items: [{ weight: { estimateKg: 0.04 }, potentialImpact: { version: 'EPA WARM v16' } }] },
        reward: { status: 'ineligible', earnedPoints: 0 },
      });
    });
    await db().query(
      "INSERT INTO disposal_factors(region,material,pathway,version,factor,source) VALUES('test','PET plastic','landfill','v1',2,'Test fixture'),('test','PET plastic','recycle','v1',1,'Test fixture')",
    );
    await http()
      .put(path + '/disposal')
      .set(a.auth)
      .send({
        material: 'PET plastic',
        region: 'test',
        massKg: 0.5,
        baseline: 'landfill',
        actual: 'recycle',
        version: 'v1',
      })
      .expect(200)
      .expect((r) => expect(r.body.impacts[0].avoidedKg).toBe(0.5));
    await http().get('/api/leaderboard').set(a.auth).expect(200)
      .expect(r => expect(r.body.mine).toBeNull());
  });

  it('ranks one verified cleanup, holds it for review and excludes reused evidence', async () => {
    const a = await account(), b = await account();
    app().get(ConfigService).set('MODERATOR_IDS', b.id);
    const image = () => sharp(randomBytes(16 * 16 * 3), { raw: { width: 16, height: 16, channels: 3 } }).png().toBuffer();
    const pickup = await image();
    const makeReport = async () => {
      const id = randomUUID();
      const path = '/api/litter-reports/' + id;
      await http().put(path).set(b.auth).field('latitude', '19.09').field('longitude', '72.88')
        .field('category', 'Glass').field('notes', 'Cleanup evidence').attach('photos', await image(), 'report.png').expect(200);
      return path;
    };
    const finishCleanup = async (auth: typeof a.auth, report: string, bytes: Buffer) => {
      const id = (await http().post('/api/plogs').set(auth).expect(201)).body.id;
      const photoId = randomUUID(), path = '/api/plogs/' + id;
      const capturedAt = new Date().toISOString();
      await http().put(path + '/evidence/' + photoId).set(auth)
        .field('capture', JSON.stringify({ source: 'camera', capturedAt,
          gps: { latitude: 19.09, longitude: 72.88, accuracyMeters: 5, recordedAt: capturedAt },
        })).attach('photo', bytes, 'pickup.png').expect(200);
      const receipt = report + '/observations/' + randomUUID();
      const claim = { plogId: id, photoId, outcome: 'cleaned' };
      await http().put(receipt).set(auth).send(claim).expect(200);
      await http().post(path + '/finish').set(auth).send({
        endedAt: new Date().toISOString(), durationSeconds: 0, distanceMeters: 0, route: [],
      }).expect(200);
      const verification = (await http().put(receipt).set(auth).send(claim).expect(200)).body.verification;
      return { id, path, photoId, verification };
    };
    const verified = await finishCleanup(a.auth, await makeReport(), pickup);
    expect(verified.verification).toBe('verified');
    await http().get(verified.path + '/analysis').set(a.auth).expect(200)
      .expect(r => expect(r.body.reward).toMatchObject({ status: 'pending', earnedPoints: 0 }));
    const progress = (period = 'week') => http().get('/api/progress').set(a.auth).query({ period }).expect(200);
    const challenges = () => http().get('/api/challenges').set(a.auth).expect(200);
    const badges = () => http().get('/api/badges').set(a.auth).expect(200);
    await http().get('/api/progress').expect(401);
    await http().put('/api/profile/goal').set(a.auth).send({ cadence: 'week', target: 101 }).expect(400);
    await http().put('/api/profile/goal').set(a.auth).send({ cadence: 'week', target: 2 }).expect(200)
      .expect(r => expect(r.body.goal).toMatchObject({ target: 2, cadence: 'week', progress: 0 }));
    await progress().expect(r => expect(r.body).toMatchObject({
      pending: 1, goal: { streak: 0 }, totals: { completedPlogs: 1, verifiedCleanups: 0, points: 0 },
    }));
    const provider = jest.spyOn(global, 'fetch');
    const cfg = app().get(ConfigService);
    cfg.set('GEMINI_API_KEY', 'test-only');
    try {
      await db().query("UPDATE plog_analysis SET next_run='2000-01-01' WHERE plog_id=$1", [verified.id]);
      provider.mockResolvedValueOnce(Response.json({
        candidates: [{ content: { parts: [{ text: JSON.stringify({ quality: 'clear', items: [{
          label: 'glass jar', material: 'Glass', type: 'Jar', count: 3,
          weight: { estimateKg: 0.9, minKg: 0.6, maxKg: 1.1 },
          photos: [0], box: [0, 0, 500, 500], certain: true,
        }] }) }] } }],
      }));
      await app().get(AnalysisWorker).processNext();
    } finally {
      provider.mockRestore();
      cfg.set('GEMINI_API_KEY', '');
    }
    const result = (await http().get(verified.path + '/analysis').set(a.auth).expect(200)).body;
    expect(result.reward).toMatchObject({
      status: 'earned', earnedPoints: 3.6, breakdown: { items: 3, movement: 0, spots: 1 },
    });
    const savedReceipt = async () => (await db().query(
      'SELECT state,points::float8,evidence_and_components,policy FROM plog_reward_receipts WHERE plog_id=$1',
      [verified.id],
    ))[0];
    expect(await savedReceipt()).toMatchObject({
      state: 'earned',points: 3.6,policy: { version: 'm5-v1' },
      evidence_and_components: { photoIds: [verified.photoId],acceptedItems: 3 },
    });
    await http().get('/api/plogs/summary?include=progress').set(a.auth).expect(200)
      .expect(r => expect(r.body.progress).toMatchObject({ points: 6.6,verifiedCleanups: 1 }));
    expect(result.challengeAwards).toEqual([{ title: 'Daily cleanup', points: 3 }]);
    expect(result.impact.estimatedKg).toBe(0.9);
    expect(result.impact.measuredKg).toBeNull();
    const active = (await challenges()).body.filter((c: { endsAt: string }) => Date.parse(c.endsAt) > Date.now());
    expect(active).toEqual(expect.arrayContaining([
      expect.objectContaining({ title: 'Daily cleanup', progress: 1, earnedPoints: 3, completedAt: expect.any(String) }),
      expect.objectContaining({ title: 'Daily collection', progress: 3, earnedPoints: 0 }),
      expect.objectContaining({ title: 'Weekly consistency', progress: 1, earnedPoints: 0 }),
    ]));
    expect((await badges()).body).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: 'First Plog', status: 'earned', earned: expect.any(String) }),
      expect.objectContaining({ name: '100 points', status: 'in_progress', progress: 6.6 }),
      expect.objectContaining({ name: 'Challenge starter', status: 'earned' }),
    ]));
    const assertScore = async (score: number | null) => {
      for (const period of ['week', 'month', 'all']) {
        const { body } = await http().get('/api/leaderboard').set(a.auth).query({ period }).expect(200);
        const stats = (await progress(period)).body;
        expect(stats.totals.points).toBe(score ?? 0);
        if (score === null) expect(body.mine).toBeNull();
        else {
          expect(body.mine).toMatchObject({ rank: 1, score, mine: true, impact: stats.totals });
          const bucketPoints = stats.series.reduce((total: number, row: { totals: { points: number } }) =>
            total + row.totals.points,0);
          expect(bucketPoints).toBeCloseTo(score);
        }
      }
    };
    await assertScore(6.6);
    await progress().expect(r => expect(r.body.goal).toMatchObject({ progress: 1, streak: 1, longestStreak: 1 }));
    await db().query(`INSERT INTO disposal_factors(region,material,pathway,version,factor,source) VALUES
      ('Fixture','Glass','Landfill','m5-test',1,'https://example.test/landfill'),
      ('Fixture','Glass','Recycling','m5-test',0.5,'https://example.test/recycling')`);
    await http().put(verified.path+'/disposal').set(a.auth).send({
      material: 'Glass',massKg: 2,region: 'Fixture',baseline: 'Landfill',actual: 'Recycling',version: 'm5-test',
    }).expect(200).expect(r => expect(r.body.impact).toMatchObject({
      estimatedKg: null,measuredKg: 2,potentialCo2eKg: 1,
    }));
    await assertScore(6.6);
    await db().query(`INSERT INTO impact_rules VALUES ('new-policy','{"Glass":10}',0,true)`);
    try {
      await assertScore(6.6);
    } finally {
      await db().query("DELETE FROM impact_rules WHERE version='new-policy'");
    }
    await http().post(verified.path + '/analysis/review').set(a.auth).expect(201);
    await assertScore(null);
    await http().get(verified.path + '/analysis').set(a.auth).expect(200)
      .expect(r => expect(r.body.reward).toMatchObject({ status: 'pending', pendingPoints: 3.6 }));
    await http().put('/api/moderation/analysis/' + verified.id).set(b.auth)
      .send({ items: [{ label: 'glass jar', material: 'Glass', type: 'Jar', count: 3, photoIds: [verified.photoId] }] })
      .expect(200);
    await assertScore(6.6);
    const reencoded = await sharp(pickup).withMetadata({ orientation: 1 }).png().toBuffer();
    for (const [bytes, expectedVerification] of [[pickup, 'unverified'], [reencoded, 'unverified']] as const) {
      const repeated = await finishCleanup(b.auth, await makeReport(), bytes);
      expect(repeated.verification).toBe(expectedVerification);
      const repeatedResult = {
        ...result.result,
        items: result.result.items.map((item: Record<string, unknown>) => ({ ...item, photoIds: [repeated.photoId] })),
      };
      await db().query("UPDATE plog_analysis SET state='ready',reviewed=true,result=$2 WHERE plog_id=$1",
        [repeated.id, JSON.stringify(repeatedResult)]);
      await http().get(repeated.path + '/analysis').set(b.auth).expect(200)
        .expect(r => expect(r.body.reward).toMatchObject({ status: 'ineligible', earnedPoints: 0 }));
    }
    await assertScore(6.6);
    await db().query("UPDATE plog_analysis SET state='review' WHERE plog_id=$1", [verified.id]);
    const decide = () => http().put('/api/moderation/analysis/' + verified.id).set(b.auth).send({
      items: [{ label: 'glass jar', material: 'Glass', type: 'Jar', count: 5,
        weightKg: 0.9, photoIds: [verified.photoId] }],
    });
    const decisions = await Promise.all([decide(),decide()]);
    expect(decisions.map(r => r.status).sort()).toEqual([200,409]);
    await assertScore(10.6);
    expect(await savedReceipt()).toMatchObject({ state: 'earned',points: 5.6 });
    expect((await challenges()).body).toEqual(expect.arrayContaining([
      expect.objectContaining({ title: 'Daily collection', progress: 5, earnedPoints: 2 }),
    ]));
    await http().post(verified.path + '/analysis/review').set(a.auth).expect(201);
    await http().put('/api/moderation/analysis/' + verified.id).set(b.auth).send({ items: [] }).expect(200);
    await assertScore(null);
    expect(await savedReceipt()).toMatchObject({ state: 'rejected',points: 0,evidence_and_components: null });
    await progress().expect(r => expect(r.body).toMatchObject({
      pending: 0, goal: { progress: 0, streak: 0, longestStreak: 0 },
      totals: { verifiedCleanups: 0, items: 0, measuredKg: null, potentialCo2eKg: null },
    }));
    expect((await badges()).body).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: 'First Plog', status: 'locked', earned: null }),
      expect.objectContaining({ name: 'Challenge starter', status: 'locked' }),
    ]));

    // Place the already verified evidence at UTC period boundaries. Approval still happens now.
    const [calendar] = await db().query(`
      SELECT date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS week,
        date_trunc('month',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month,
        starts_at FROM gamification_season
    `);
    const weekStart = new Date(calendar.week).getTime();
    const monthStart = new Date(calendar.month).getTime();
    const dayMs = 86400000;
    const monday = weekStart - 7*dayMs;
    const historical = [monday,monday+1,monday+dayMs,monday+2*dayMs];
    const approved = (photoId: string) => JSON.stringify({
      quality: 'clear', items: [{ label: 'glass jar', material: 'Glass', type: 'Jar', certain: true,
        count: 1, photoIds: [photoId], box: [1,1,100,100] }],
    });
    const place = async (plog: { id: string; photoId: string }, endedAt: number) => {
      await db().query(`UPDATE plogs SET ended_at=$2,started_at=$2::timestamptz-interval '25 minutes',duration_seconds=1500
        WHERE id=$1`, [plog.id,new Date(endedAt)]);
      await db().query(`UPDATE plog_analysis SET result=$2,state='ready',reviewed=false WHERE plog_id=$1`,
        [plog.id,approved(plog.photoId)]);
    };
    await db().query("UPDATE gamification_season SET starts_at=$1", [new Date(Math.min(monday,monthStart)-dayMs)]);
    try {
      for (const time of historical) {
        const late = await finishCleanup(a.auth,await makeReport(),await image());
        expect(late.verification).toBe('verified');
        await place(late,time);
      }
      const weekly = (await challenges()).body.filter((r: { title: string; startsAt: string }) =>
        r.title==='Weekly consistency' && Date.parse(r.startsAt)===monday);
      expect(weekly).toEqual([expect.objectContaining({ progress: 3, earnedPoints: 10 })]);
      await progress().expect(r => expect(r.body).toMatchObject({
        totals: { points: 0 }, goal: { progress: 0, streak: 1, longestStreak: 1 },
      }));
      await progress('all').expect(r => expect(r.body.totals).toMatchObject({
        verifiedCleanups: 4,cleanupPoints: 4,challengePoints: 19,points: 23,
      }));
      await http().put('/api/profile/goal').set(a.auth).send({ cadence: 'day',target: 1 }).expect(200)
        .expect(r => expect(r.body.goal).toMatchObject({ streak: 0, longestStreak: 3 }));

      const before = await finishCleanup(b.auth,await makeReport(),await image());
      const at = await finishCleanup(b.auth,await makeReport(),await image());
      await place(before,monthStart-1);
      await place(at,monthStart);
      // Timestamped fixes contribute only within continuous valid route segments.
      await db().query(`INSERT INTO plog_route_points(plog_id,sequence,location,recorded_at,accuracy_meters)
        SELECT $1,n,ST_SetSRID(ST_MakePoint(72.88+n*0.00025,19.09),4326)::geography,
          $2::timestamptz-interval '22 minutes'+n*interval '25 seconds',5
        FROM generate_series(0,50) n`, [at.id,new Date(monthStart)]);
      await http().get(at.path+'/analysis').set(b.auth).expect(200)
        .expect(r => expect(r.body.reward).toMatchObject({
          earnedPoints: 2,breakdown: { movement: 1, movingSeconds: 1250 },
        }));
      await http().get('/api/progress?period=month').set(b.auth).expect(200)
        .expect(r => expect(r.body.totals).toMatchObject({ verifiedCleanups: 1,points: 5 }));
      await http().get('/api/progress?period=all').set(b.auth).expect(200)
        .expect(r => expect(r.body.totals).toMatchObject({ verifiedCleanups: 2,points: 9 }));

      const peer = await account();
      const tie = await finishCleanup(peer.auth,await makeReport(),await image());
      await place(tie,monthStart);
      const peerResult = JSON.parse(approved(tie.photoId));
      peerResult.items[0].count = 2;
      await db().query('UPDATE plog_analysis SET result=$2 WHERE plog_id=$1', [tie.id,JSON.stringify(peerResult)]);
      const standings = (await http().get('/api/leaderboard?period=month').set(b.auth).expect(200)).body;
      const tied = standings.items.filter((row: { score: number }) => row.score === 5);
      expect(tied).toHaveLength(2);
      expect(tied.every((row: { rank: number }) => row.rank === standings.mine.rank)).toBe(true);

      const outlier = { quality: 'clear',items: [{
        material: 'Glass',type: 'Jar', count: 40, certain: true,photoIds: [at.photoId],
      }] };
      await db().query("UPDATE plog_analysis SET state='ready',result=$2 WHERE plog_id=$1",
        [at.id,JSON.stringify(outlier)]);
      await http().get(at.path+'/analysis').set(b.auth).expect(200)
        .expect(r => expect(r.body).toMatchObject({ state: 'review',reward: { status: 'pending',earnedPoints: 0 } }));
      await http().get('/api/leaderboard?period=month').set(b.auth).expect(200)
        .expect(r => expect(r.body.mine).toBeNull());
    } finally {
      await db().query('UPDATE gamification_season SET starts_at=$1',[calendar.starts_at]);
    }
  });

  it('awards and revokes XP for three bottles photographed without a map report', async () => {
    const plogger = await account(), reviewer = await account();
    const config = app().get(ConfigService);
    config.set('MODERATOR_IDS', reviewer.id);
    const image = () => sharp(randomBytes(16 * 16 * 3), {
      raw: { width: 16, height: 16, channels: 3 },
    }).png().toBuffer();
    const bottles = await image();
    const finish = async (auth: typeof plogger.auth, bytes: Buffer, source = 'camera', offset = 0, extraGallery = false) => {
      const { body: { id } } = await http().post('/api/plogs').set(auth).expect(201);
      const photoId = randomUUID(), path = '/api/plogs/' + id;
      await http().put(path + '/evidence/' + photoId).set(auth)
        .field('capture',JSON.stringify({ source,capturedAt: new Date(Date.now()+offset).toISOString() }))
        .attach('photo',bytes,'pickup.png').expect(200);
      const photoIds = [photoId];
      if (extraGallery) {
        const extra = randomUUID();
        await http().put(path+'/evidence/'+extra).set(auth)
          .field('capture',JSON.stringify({ source: 'gallery',capturedAt: new Date().toISOString() }))
          .attach('photo',await image(),'gallery.png').expect(200);
        photoIds.push(extra);
      }
      const result = { endedAt: new Date().toISOString(),durationSeconds: 0,distanceMeters: 0,route: [] };
      await http().post(path+'/finish').set(auth).send(result).expect(200);
      await http().post(path+'/finish').set(auth).send(result).expect(200);
      return { id,path,photoId,photoIds };
    };
    const fresh = await finish(plogger.auth,bottles);
    const prediction = { label: 'plastic bottles', material: 'Plastic', type: 'Bottle', count: 3,
      weight: null,box: [0,0,500,500],certain: true };
    await http().get(fresh.path+'/analysis').set(plogger.auth).expect(200)
      .expect(r => expect(r.body.reward).toMatchObject({ status: 'pending',earnedPoints: 0 }));
    const provider = jest.spyOn(global,'fetch');
    config.set('GEMINI_API_KEY','test-only');
    try {
      await db().query("UPDATE plog_analysis SET next_run='2000-01-01' WHERE plog_id=$1",[fresh.id]);
      provider.mockResolvedValueOnce(Response.json({ candidates: [{ content: { parts: [{
        text: JSON.stringify({ quality: 'clear',items: [{ ...prediction,photos: [0] }] }),
      }] } }] }));
      await app().get(AnalysisWorker).processNext();
    } finally {
      provider.mockRestore();
      config.set('GEMINI_API_KEY','');
    }
    await http().get(fresh.path+'/analysis').set(plogger.auth).expect(200).expect(r => {
      expect(r.body.reward).toMatchObject({ status: 'earned',earnedPoints: 3,
        breakdown: { acceptedItems: 3,spots: 0,verifiedCleanups: 1,reportIds: [],photoIds: [fresh.photoId] },
      });
      expect(r.body.challengeAwards).toEqual([{ title: 'Daily cleanup',points: 3 }]);
    });
    await http().get('/api/progress').set(plogger.auth).expect(200).expect(r =>
      expect(r.body).toMatchObject({ totals: { verifiedCleanups: 1,items: 3,points: 6 },
        goal: { progress: 1,streak: 1 },
      }));
    await http().get('/api/leaderboard').set(plogger.auth).expect(200).expect(r =>
      expect(r.body.mine).toMatchObject({ score: 6 }));
    await http().get('/api/badges').set(plogger.auth).expect(200).expect(r =>
      expect(r.body).toEqual(expect.arrayContaining([
        expect.objectContaining({ name: 'First Plog',status: 'earned' }),
        expect.objectContaining({ name: 'Spot cleaner',status: 'locked' }),
      ])));
    expect((await db().query('SELECT points::int FROM plog_reward_receipts WHERE plog_id=$1',[fresh.id]))[0].points)
      .toBe(3);

    const excluded = [
      [await finish(reviewer.auth,bottles),'ineligible'],
      [await finish(reviewer.auth,await sharp(bottles).withMetadata({ orientation: 1 }).png().toBuffer()),'ineligible'],
      [await finish(reviewer.auth,await image(),'gallery'),'ineligible'],
      [await finish(reviewer.auth,await image(),'camera',-86400000),'ineligible'],
      [await finish(reviewer.auth,await image(),'camera',0,true),'rejected'],
    ] as const;
    for (const [other,status] of excluded) {
      await db().query("UPDATE plog_analysis SET state='ready',reviewed=true,result=$2 WHERE plog_id=$1",
        [other.id,JSON.stringify({ quality: 'clear',items: [{ ...prediction,photoIds: other.photoIds }] })]);
      await http().get(other.path+'/analysis').set(reviewer.auth).expect(200)
        .expect(r => expect(r.body.reward).toMatchObject({ status,earnedPoints: 0 }));
    }
    await http().post(fresh.path+'/analysis/review').set(plogger.auth).expect(201);
    await http().put('/api/moderation/analysis/'+fresh.id).set(reviewer.auth).send({ items: [] }).expect(200);
    await http().get('/api/progress').set(plogger.auth).expect(200)
      .expect(r => expect(r.body.totals).toMatchObject({ verifiedCleanups: 0,items: 0,points: 0 }));
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
