import { randomUUID } from 'node:crypto';
import type { DataSource, Point } from 'typeorm';
import { Plog, PlogRoutePoint } from '../src/modules/plogs/plog.entity';
import { User } from '../src/modules/users/user.entity';

export function plogContract(source: () => DataSource) {
  describe('Plog activity persistence', () => {
    const createUser = () => source().getRepository(User).save({
      email: `${randomUUID()}@example.test`, passwordHash: 'test-hash',
    });

    it('round-trips an owned activity from its first GPS fix through completion', async () => {
      const user = await createUser();
      const plogs = source().getRepository(Plog);
      const points = source().getRepository(PlogRoutePoint);
      const startedAt = new Date('2026-11-20T07:00:00Z');
      const endedAt = new Date('2026-11-20T07:05:00Z');
      const { id } = await plogs.save({ user, startedAt });
      expect(await plogs.findOneByOrFail({ id })).toMatchObject({
        id, startedAt, endedAt: null, segmentStarts:[], durationSeconds: 0, distanceMeters: 0, status: 'active',
      });
      const readRoute = () => points.findBy({ plogId: id });
      expect(await readRoute()).toHaveLength(0);
      const route: Point[] = [
        { type: 'Point', coordinates: [78.4867, 17.385] },
        { type: 'Point', coordinates: [78.4871, 17.386] },
        { type: 'Point', coordinates: [78.4882, 17.3864] },
      ];
      await points.insert({ plogId: id, sequence: 0, location: route[0] });
      expect(await readRoute()).toMatchObject([{ plogId: id, sequence: 0, location: route[0] }]);
      await points.insert([
        { plogId: id, sequence: 2, location: route[2] },
        { plogId: id, sequence: 1, location: route[1] },
      ]);
      await plogs.update(id, { status: 'completed', endedAt, durationSeconds: 300, distanceMeters: 247.5 });
      const stored = await plogs.findOneOrFail({ where: { id }, relations: { user: true } });
      expect(stored).toMatchObject({
        id, user: { id: user.id, email: user.email }, startedAt, endedAt,
        status: 'completed',segmentStarts:[], durationSeconds: 300, distanceMeters: 247.5,
      });
      const [path] = await source().query(`
        SELECT ST_SRID(line) AS srid, ST_AsGeoJSON(line)::json AS route FROM (
          SELECT ST_MakeLine(location::geometry ORDER BY sequence) AS line
          FROM plog_route_points WHERE plog_id = $1
        ) AS track
      `, [id]);
      expect(path).toEqual({
        srid: 4326, route: { type: 'LineString', coordinates: route.map(point => point.coordinates) },
      });
      await plogs.save({ user });
      await source().getRepository(User).delete(user.id);
      expect(await plogs.countBy({ user: { id: user.id } })).toBe(0);
      expect(await readRoute()).toHaveLength(0);
    });

    it('requires an existing owner and allows one active Plog per user under concurrent starts', async () => {
      const plogs = source().getRepository(Plog);
      await expect(plogs.insert({ user: { id: randomUUID() } }))
        .rejects.toMatchObject({ code: '23503', constraint: 'plogs_user_fk' });
      await expect(source().query('INSERT INTO plogs DEFAULT VALUES'))
        .rejects.toMatchObject({ code: '23502', column: 'user_id' });
      const user = await createUser();
      const starts = await Promise.allSettled([plogs.insert({ user }), plogs.insert({ user })]);
      expect(starts).toEqual(expect.arrayContaining([
        expect.objectContaining({ status: 'fulfilled' }),
        expect.objectContaining({ status: 'rejected', reason: expect.objectContaining({
          code: '23505', constraint: 'plogs_one_active_per_user',
        }) }),
      ]));
      const other = await createUser();
      await plogs.insert({ user: other });
      expect(await plogs.countBy({ user: { id: user.id } })).toBe(1);
      expect(await plogs.countBy({ user: { id: other.id } })).toBe(1);
    });

    it('rejects inconsistent lifecycle states and invalid measurements', async () => {
      const user = await createUser();
      const plogs = source().getRepository(Plog);
      const startedAt = new Date('2026-11-20T12:00:00Z');
      const { id } = await plogs.save({ user, startedAt });
      await expect(plogs.update(id, { endedAt: startedAt })).rejects.toMatchObject({ constraint: 'plogs_lifecycle_check' });
      await expect(plogs.update(id, { status: 'completed' })).rejects.toMatchObject({ constraint: 'plogs_lifecycle_check' });
      await expect(plogs.update(id, { status: 'completed', endedAt: new Date(startedAt.getTime() - 1000) }))
        .rejects.toMatchObject({ constraint: 'plogs_lifecycle_check' });
      await expect(plogs.update(id, { durationSeconds: -1 })).rejects.toMatchObject({ constraint: 'plogs_duration_check' });
      for (const distanceMeters of [-1, Infinity, NaN]) {
        await expect(plogs.update(id, { distanceMeters })).rejects.toMatchObject({ constraint: 'plogs_distance_check' });
      }
    });

    it('enforces route point ownership, sequence and location shape', async () => {
      const user = await createUser();
      const { id } = await source().getRepository(Plog).save({ user });
      const points = source().getRepository(PlogRoutePoint);
      const location: Point = { type: 'Point', coordinates: [0, 0] };
      const point = { plogId: id, sequence: 0, location };
      await points.insert(point);
      await expect(points.insert(point)).rejects.toMatchObject({ constraint: 'plog_route_points_pkey' });
      await expect(points.insert({ ...point, sequence: -1 })).rejects.toMatchObject({ constraint: 'plog_route_points_sequence_check' });
      await expect(points.insert({ ...point, plogId: randomUUID() })).rejects.toMatchObject({ constraint: 'plog_route_points_plog_fk' });
      const insertLocation = (wkt: string) => source().query(
        'INSERT INTO plog_route_points (plog_id, sequence, location) VALUES ($1, 1, ST_GeogFromText($2))', [id, wkt],
      );
      await expect(insertLocation('POINT EMPTY')).rejects.toMatchObject({ constraint: 'plog_route_points_location_check' });
      await expect(insertLocation('LINESTRING(0 0,1 1)')).rejects.toThrow(/geometry type/i);
    });
  });
}
