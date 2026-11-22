import { BadRequestException, ConflictException, Injectable, NotFoundException, UnprocessableEntityException } from '@nestjs/common';
import { DataSource, EntityManager, QueryFailedError } from 'typeorm';
import { FinishPlogDto } from './plog.dto';
import { Plog } from './plog.entity';

function summary(plog: Plog, userId: string) {
  const { id, status, startedAt, endedAt, durationSeconds, distanceMeters } = plog;
  return { id, userId, status, startedAt, endedAt, durationSeconds, distanceMeters };
}

@Injectable()
export class PlogsService {
  constructor(private readonly source: DataSource) {}

  async start(userId: string) {
    const repo = this.source.getRepository(Plog);
    try {
      const created = await repo.save(repo.create({ user: { id: userId }, startedAt: new Date() }));
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
    const [row] = await this.source.query(`SELECT (SELECT count(*)::int FROM litter_reports WHERE author_id=$1 AND status IN ('open','collected')) AS reports, count(*)::int AS sessions,
      count(*) FILTER (WHERE distance_meters>0 OR EXISTS(SELECT 1 FROM plog_route_points f WHERE f.plog_id=plogs.id))::int AS "trackedSessions",
      coalesce(sum(distance_meters),0)::float8 AS "distanceMeters"
      FROM plogs WHERE user_id=$1 AND status='completed'`, [owner]);
    return row;
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
    const items = records.slice(0, 25).map(p => summary(p, userId));
    return { items, nextCursor: records.length > items.length ? items[items.length - 1].id : null };
  }

  async detail(userId: string, id: string) {
    const record = await this.source.getRepository(Plog).findOneBy({ user: { id: userId }, id, status: 'completed' });
    if (!record) throw new NotFoundException();
    return { ...summary(record, userId), segmentStarts:record.segmentStarts, route: await this.readRoute(this.source.manager, id) };
  }

  private readRoute(manager: EntityManager, id: string): Promise<FinishPlogDto['route']> {
    return manager.query(`
      SELECT ST_Y(location::geometry) AS latitude, ST_X(location::geometry) AS longitude
      FROM plog_route_points WHERE plog_id = $1 ORDER BY sequence
    `, [id]);
  }

  async finish(userId: string, id: string, dto: FinishPlogDto) {
    return this.source.transaction(async manager => {
      const repo = manager.getRepository(Plog);
      const plog = await repo.createQueryBuilder('p').where('p.id = :id AND p.user_id = :userId', { id, userId })
        .setLock('pessimistic_write').getOne();
      if (!plog) throw new NotFoundException();
      const endedAt = new Date(dto.endedAt);
      if (endedAt < plog.startedAt) throw new BadRequestException('End precedes start');
      const breaks=dto.segmentStarts??[];
      if(breaks.some((n,i)=>n>=dto.route.length || (i>0 && breaks[i-1]>=n))) throw new BadRequestException('Invalid route segments');
      const pickups = [...(dto.pickupIds ?? [])].sort();
      if (plog.status === 'completed') {
        const saved = await manager.query('SELECT report_id FROM plog_pickups WHERE plog_id=$1 ORDER BY report_id', [id]);
        if (JSON.stringify(saved.map((r: {report_id: string}) => r.report_id)) !== JSON.stringify(pickups)) {
          throw new ConflictException('The saved pickups differ');
        }
        const points = await this.readRoute(manager, id);
        if (plog.endedAt?.getTime() === endedAt.getTime() && plog.distanceMeters === dto.distanceMeters
          && JSON.stringify(plog.segmentStarts)===JSON.stringify(breaks) && plog.durationSeconds === dto.durationSeconds && points.length === dto.route.length
          && points.every((point, i) => point.latitude === dto.route[i].latitude && point.longitude === dto.route[i].longitude)) {
          return summary(plog, userId);
        }
        throw new ConflictException('The Plog was already completed');
      }
      const [photos] = await manager.query(`
        SELECT count(*)::int AS total, count(uploaded_at)::int AS ready FROM garbage_evidence WHERE plog_id = $1
      `, [id]);
      if (photos.ready < 1 || photos.ready > 6 || photos.ready !== photos.total) {
        throw new UnprocessableEntityException('Upload one to six garbage photos before finishing');
      }
      await manager.query(`
        INSERT INTO plog_route_points (plog_id, sequence, location)
        SELECT $1, ordinal - 1, ST_SetSRID(ST_MakePoint(
          (fix->>'longitude')::double precision, (fix->>'latitude')::double precision
        ), 4326)::geography
        FROM jsonb_array_elements($2::jsonb) WITH ORDINALITY AS route(fix, ordinal)
      `, [id, JSON.stringify(dto.route)]);
      // Lock shared reports in a stable order so concurrent pickups can both save their activity.
      if (pickups.length) {
        const spots = await manager.query(`SELECT id,status FROM litter_reports WHERE id=ANY($1::uuid[]) ORDER BY id FOR UPDATE`, [pickups]);
        if (spots.length !== pickups.length || spots.some((r: {status: string}) => !['open', 'collected', 'withdrawn', 'hidden'].includes(r.status))) {
          throw new UnprocessableEntityException('A selected spot is unavailable');
        }
        await manager.query('INSERT INTO plog_pickups SELECT $1, unnest($2::uuid[])', [id,pickups]);
        await manager.query("UPDATE litter_reports SET status='collected' WHERE id=ANY($1::uuid[]) AND status='open'", [pickups]);
      }
      const pending = await manager.query("SELECT id FROM litter_reports WHERE collection_plog_id=$1 AND status='uploading'", [id]);
      if (pending.length) throw new UnprocessableEntityException('Wait for collection photos');
      await manager.query("UPDATE litter_reports SET status='collected' WHERE collection_plog_id=$1 AND status='pending_finish'", [id]);
      Object.assign(plog, { segmentStarts:breaks, status: 'completed', endedAt, durationSeconds: dto.durationSeconds, distanceMeters: dto.distanceMeters });
      await repo.save(plog);
      await manager.query('INSERT INTO plog_analysis(plog_id) VALUES($1) ON CONFLICT DO NOTHING',[id]);
      return summary(plog, userId);
    });
  }
}
