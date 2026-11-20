import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreatePlogs1795171000000 implements MigrationInterface {
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`
      CREATE TABLE plogs (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL CONSTRAINT plogs_user_fk REFERENCES users(id) ON DELETE CASCADE,
        status text NOT NULL DEFAULT 'active',
        started_at timestamptz NOT NULL DEFAULT now(),
        ended_at timestamptz,
        duration_seconds integer NOT NULL DEFAULT 0,
        distance_meters double precision NOT NULL DEFAULT 0,
        CONSTRAINT plogs_lifecycle_check CHECK (
          (status = 'active' AND ended_at IS NULL) OR
          (status = 'completed' AND ended_at IS NOT NULL AND ended_at >= started_at)
        ),
        CONSTRAINT plogs_duration_check CHECK (duration_seconds >= 0),
        CONSTRAINT plogs_distance_check CHECK (distance_meters >= 0 AND distance_meters < 'Infinity'::double precision)
      );
      CREATE INDEX plogs_user_idx ON plogs(user_id);
      CREATE UNIQUE INDEX plogs_one_active_per_user ON plogs(user_id) WHERE status = 'active';
      CREATE TABLE plog_route_points (
        plog_id uuid NOT NULL CONSTRAINT plog_route_points_plog_fk REFERENCES plogs(id) ON DELETE CASCADE,
        sequence integer NOT NULL,
        location geography(Point, 4326) NOT NULL,
        PRIMARY KEY (plog_id, sequence),
        CONSTRAINT plog_route_points_sequence_check CHECK (sequence >= 0),
        CONSTRAINT plog_route_points_location_check CHECK (NOT ST_IsEmpty(location::geometry))
      )
    `);
  }

  async down(runner: QueryRunner): Promise<void> {
    await runner.query('DROP TABLE plog_route_points, plogs');
  }
}
