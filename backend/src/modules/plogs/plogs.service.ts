import { deviceId, requireRecorder } from './recording-device';
import { BadRequestException, ConflictException, Injectable, NotFoundException, UnprocessableEntityException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { DataSource, EntityManager, QueryFailedError } from 'typeorm';
import { FinishPlogDto } from './plog.dto';
import { finalizeObservations, lockPlogEvidence } from './cleanup-verification';
import { validateRoute } from './route-validation';
import { Plog } from './plog.entity';

function summary(plog: Plog, userId: string) {
  const { id, status, startedAt, endedAt, durationSeconds, distanceMeters } = plog;
  return { id, userId, status, startedAt, endedAt, durationSeconds, distanceMeters,
    ...(status === 'active' && plog.recordingDevice ? { recordingDevice: plog.recordingDevice } : {}) };
}

@Injectable()
export class PlogsService {
  constructor(private readonly source: DataSource) {}

  async start(userId: string, recorder?: string) {
    const repo = this.source.getRepository(Plog);
    try {
      const created = await repo.save(repo.create({ user: { id: userId }, startedAt: new Date(), recordingDevice: deviceId(recorder) }));
      return summary(created, userId);
    } catch (error) {
      if (error instanceof QueryFailedError && error.driverError.constraint === 'plogs_one_active_per_user') {
        throw new ConflictException('An active Plog already exists');
      }
      throw error;
    }
  }

  async active(userId: string) {
    const plog = await this.source.getRepository(Plog).findOneBy({ user: { id: userId }, status: 'active' });
    return { plog: plog && summary(plog, userId) };
  }

  async totals(owner: string) {
    const [{ verifiedCleanups, ...totals }] = await this.source.query(`
      SELECT (SELECT count(*)::int FROM litter_reports WHERE author_id=$1 AND collection_plog_id IS NULL
        AND status IN ('open','collected')) AS reports,
      (SELECT count(*)::int FROM spot_observations o JOIN plogs p ON p.id=o.plog_id
        WHERE o.user_id=$1 AND p.user_id=$1 AND p.status='completed' AND o.resolved) AS "verifiedCleanups",
      count(*)::int AS sessions,
      count(*) FILTER (WHERE distance_meters>0 OR EXISTS(SELECT 1 FROM plog_route_points f WHERE f.plog_id=plogs.id))::int AS "trackedSessions",
      coalesce(sum(distance_meters),0)::float8 AS "distanceMeters"
      FROM plogs WHERE user_id=$1 AND status='completed'`, [owner]);
    return { ...totals, ...(verifiedCleanups > 0 && { verifiedCleanups }) };
  }

  async completed(userId: string, before?: string) {
    const query = this.source.getRepository(Plog).createQueryBuilder('p')
      .where('p.user_id = :userId AND p.status = :status', { userId, status: 'completed' });
    if (before) {
      query.andWhere(`(p.ended_at, p.id) < (
        SELECT ended_at, id FROM plogs WHERE id = :before AND user_id = :userId AND status = :status
      )`, { before });
    }
    const records = await query.orderBy('p.ended_at', 'DESC').addOrderBy('p.id', 'DESC').take(26).getMany();
    const page = records.slice(0, 25);
    const stats = await this.source.query<{
      id: string; hasRoute: boolean; pickupCount: number; photoCount: number; analysisState: string | null;
    }[]>(`
      SELECT p.id, EXISTS(SELECT 1 FROM plog_route_points f WHERE f.plog_id=p.id) AS "hasRoute",
        (SELECT count(*)::int FROM plog_pickups x WHERE x.plog_id=p.id) AS "pickupCount",
        (SELECT count(*)::int FROM garbage_evidence e WHERE e.plog_id=p.id AND e.uploaded_at IS NOT NULL) AS "photoCount",
        (SELECT state FROM plog_analysis a WHERE a.plog_id=p.id) AS "analysisState"
      FROM plogs p WHERE p.user_id=$1 AND p.id=ANY($2::uuid[])
    `, [userId, page.map(p => p.id)]);
    const byId = new Map(stats.map(({ id, ...values }) => [id, values]));
    const items = page.map(p => ({ ...summary(p, userId), ...byId.get(p.id) }));
    return { items, nextCursor: records.length > items.length ? items[items.length - 1].id : null };
  }

  async detail(userId: string, id: string) {
    const record = await this.source.getRepository(Plog).findOneBy({ user: { id: userId }, id, status: 'completed' });
    if (!record) throw new NotFoundException();
    const [route, [claims]] = await Promise.all([
      this.readRoute(this.source.manager, id),
      this.source.query(`
        SELECT count(*) FILTER(WHERE resolved)::int AS verified,
          count(*) FILTER(WHERE verification='unverified')::int AS unverified,
          count(*) FILTER(WHERE verification='already_collected')::int AS "alreadyCollected"
        FROM spot_observations WHERE plog_id=$1 AND outcome='cleaned'
      `, [id]),
    ]);
    const { alreadyCollected, ...verifiedClaims } = claims;
    return { ...summary(record, userId), segmentStarts: record.segmentStarts, route,
      ...(claims.verified || claims.unverified || alreadyCollected
        ? { cleanupClaims: { ...verifiedClaims, ...(alreadyCollected > 0 && { alreadyCollected }) } }
        : {}) };
  }

  private readRoute(manager: EntityManager, id: string): Promise<FinishPlogDto['route']> {
    return manager.query<{ latitude: number; longitude: number; recordedAt: Date | null; accuracyMeters: number | null }[]>(`
      SELECT ST_Y(location::geometry) AS latitude, ST_X(location::geometry) AS longitude,
        recorded_at AS "recordedAt", accuracy_meters AS "accuracyMeters"
      FROM plog_route_points WHERE plog_id = $1 ORDER BY sequence
    `, [id]).then(points => points.map(({ latitude, longitude, recordedAt, accuracyMeters }) =>
      ({ latitude, longitude, ...(recordedAt && accuracyMeters != null && { recordedAt: recordedAt.toISOString(), accuracyMeters }) })));
  }

  async transfer(userId: string, id: string, recorder?: string) {
    const recordingDevice = deviceId(recorder);
    if (!recordingDevice) throw new BadRequestException('A recording device is required');
    return this.source.transaction(async manager => {
      const plog = await this.lockOwned(manager, userId, id);
      if (plog.status !== 'active') throw new ConflictException('This Plog is closed');
      if (plog.recordingDevice && plog.recordingDevice !== recordingDevice) {
        await manager.query(`
          WITH removed AS (
            DELETE FROM garbage_evidence WHERE plog_id=$1 AND uploaded_at IS NULL RETURNING storage_key
          )
          INSERT INTO evidence_deletion_queue(storage_key) SELECT storage_key FROM removed ON CONFLICT DO NOTHING
        `, [id]);
      }
      plog.recordingDevice = recordingDevice;
      await manager.getRepository(Plog).save(plog);
      return summary(plog, userId);
    });
  }

  async cancel(userId: string, id: string, recorder?: string) {
    return this.source.transaction(async manager => {
      const plog = await this.lockOwned(manager, userId, id);
      if (plog.status === 'completed') throw new ConflictException('The Plog was already completed');
      if (plog.status === 'active') {
        requireRecorder(plog.recordingDevice, recorder);
        await endIncompletePlog(manager, id, 'cancelled');
      }
    });
  }

  private async lockOwned(manager: EntityManager, userId: string, id: string) {
    const plog = await manager.getRepository(Plog).createQueryBuilder('p')
      .where('p.id = :id AND p.user_id = :userId', { id, userId }).setLock('pessimistic_write').getOne();
    if (!plog) throw new NotFoundException();
    return plog;
  }

  async finish(userId: string, id: string, dto: FinishPlogDto, recorder?: string) {
    return this.source.transaction(async manager => {
      const repo = manager.getRepository(Plog);
      const plog = await this.lockOwned(manager, userId, id);
      const endedAt = new Date(dto.endedAt);
      const pickups = [...(dto.pickupIds ?? [])].sort();
      const declaredBreaks = dto.segmentStarts ?? [];
      const fingerprint = createHash('sha256').update(JSON.stringify([
        endedAt.getTime(), dto.durationSeconds, dto.distanceMeters, dto.pausedMilliseconds ?? null,
        declaredBreaks, pickups, dto.route.map(p => [p.latitude, p.longitude, p.recordedAt ?? null, p.accuracyMeters ?? null]),
      ])).digest('hex');
      if (plog.status === 'completed') {
        if (plog.finishFingerprint === fingerprint) return summary(plog, userId);
        if (plog.finishFingerprint === null) {
          const saved = await manager.query('SELECT report_id FROM plog_pickups WHERE plog_id=$1 ORDER BY report_id', [id]);
          const points = await this.readRoute(manager, id);
          if (plog.endedAt?.getTime() === endedAt.getTime() && plog.distanceMeters === dto.distanceMeters
            && JSON.stringify(saved.map((r: {report_id: string}) => r.report_id)) === JSON.stringify(pickups)
            && JSON.stringify(plog.segmentStarts) === JSON.stringify(declaredBreaks)
            && plog.durationSeconds === dto.durationSeconds && points.length === dto.route.length
            && points.every((point, i) => point.latitude === dto.route[i].latitude && point.longitude === dto.route[i].longitude)) {
            return summary(plog, userId);
          }
        }
        throw new ConflictException('The Plog was already completed');
      }
      if (plog.status !== 'active') throw new ConflictException('This Plog is closed');
      requireRecorder(plog.recordingDevice, recorder);
      const validated = validateRoute(dto, plog.startedAt, endedAt);
      const [photos] = await manager.query(`
        SELECT count(*)::int AS total, count(uploaded_at)::int AS ready FROM garbage_evidence WHERE plog_id = $1
      `, [id]);
      if (photos.ready < 1 || photos.ready > 6 || photos.ready !== photos.total) {
        throw new UnprocessableEntityException('Upload one to six garbage photos before finishing');
      }
      await lockPlogEvidence(manager, id);
      await manager.query(`
        INSERT INTO plog_route_points (plog_id, sequence, location, recorded_at, accuracy_meters)
        SELECT $1, ordinal - 1, ST_SetSRID(ST_MakePoint(
          (fix->>'longitude')::float8, (fix->>'latitude')::float8
        ), 4326)::geography, (fix->>'recordedAt')::timestamptz, (fix->>'accuracyMeters')::float8
        FROM jsonb_array_elements($2::jsonb) WITH ORDINALITY AS route(fix, ordinal)
      `, [id, JSON.stringify(validated.route)]);
      const [{ meters }] = await manager.query(`
        SELECT coalesce(sum(ST_Distance(location, prior, false)),0)::float8 AS meters
        FROM (SELECT sequence,location,lag(location) OVER (ORDER BY sequence) AS prior
          FROM plog_route_points WHERE plog_id=$1) points
        WHERE NOT (sequence=ANY($2::int[]))
      `, [id, validated.breaks]);
      await finalizeObservations(manager, id, plog.startedAt, endedAt);
      if (pickups.length) {
        await manager.query(`
          INSERT INTO plog_pickups(plog_id,report_id)
          SELECT $1,id FROM litter_reports WHERE id=ANY($2::uuid[]) AND collection_plog_id IS NULL
        `, [id, pickups]);
      }
      await manager.query(`
        UPDATE litter_reports SET collection_verification='unverified'
        WHERE collection_plog_id=$1 AND status='pending_finish'
      `, [id]);
      Object.assign(plog, { segmentStarts: validated.breaks, status: 'completed', endedAt, completedAt: new Date(), finishFingerprint: fingerprint,
        durationSeconds: validated.duration, distanceMeters: meters });
      await repo.save(plog);
      await manager.query(`
        INSERT INTO plog_analysis(plog_id,suspicious_evidence)
        SELECT $1::uuid, EXISTS(
          SELECT 1 FROM garbage_evidence photo
          JOIN garbage_evidence candidate ON candidate.id<>photo.id
            AND left(candidate.perceptual_hash,4)=left(photo.perceptual_hash,4)
            AND bit_count(('x'||candidate.perceptual_hash)::bit(64) # ('x'||photo.perceptual_hash)::bit(64)) <= 4
          JOIN plogs other ON other.id=candidate.plog_id
          WHERE photo.plog_id=$1 AND candidate.uploaded_at IS NOT NULL
            AND (candidate.plog_id=$1 OR other.status='completed')
            AND candidate.sha256<>photo.sha256
        ) ON CONFLICT DO NOTHING
      `, [id]);
      return summary(plog, userId);
    });
  }
}

export async function endIncompletePlog(manager: EntityManager, id: string, status: 'cancelled' | 'abandoned') {
  await manager.query(`
    INSERT INTO evidence_deletion_queue(storage_key)
    SELECT storage_key FROM garbage_evidence WHERE plog_id=$1
    ON CONFLICT DO NOTHING
  `, [id]);
  await manager.query(`
    SELECT queue_report_photo_deletion(id) FROM litter_reports
    WHERE collection_plog_id=$1 AND status IN ('uploading','pending_finish')
  `, [id]);
  await manager.query('DELETE FROM garbage_evidence WHERE plog_id=$1', [id]);
  await manager.query("DELETE FROM litter_reports WHERE collection_plog_id=$1 AND status IN ('uploading','pending_finish')", [id]);
  await manager.query("UPDATE plogs SET status=$2,ended_at=greatest(started_at,now()) WHERE id=$1 AND status='active'", [id, status]);
}
