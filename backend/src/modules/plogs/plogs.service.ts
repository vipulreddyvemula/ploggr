import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
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
      if (plog.status === 'completed') {
        const points = await this.readRoute(manager, id);
        if (plog.endedAt?.getTime() === endedAt.getTime() && plog.distanceMeters === dto.distanceMeters
          && plog.durationSeconds === dto.durationSeconds && points.length === dto.route.length
          && points.every((point, i) => point.latitude === dto.route[i].latitude && point.longitude === dto.route[i].longitude)) {
          return summary(plog, userId);
        }
        throw new ConflictException('The Plog was already completed');
      }
      await manager.query(`
        INSERT INTO plog_route_points (plog_id, sequence, location)
        SELECT $1, ordinal - 1, ST_SetSRID(ST_MakePoint(
          (fix->>'longitude')::double precision, (fix->>'latitude')::double precision
        ), 4326)::geography
        FROM jsonb_array_elements($2::jsonb) WITH ORDINALITY AS route(fix, ordinal)
      `, [id, JSON.stringify(dto.route)]);
      Object.assign(plog, { status: 'completed', endedAt, durationSeconds: dto.durationSeconds, distanceMeters: dto.distanceMeters });
      await repo.save(plog);
      return summary(plog, userId);
    });
  }
}
