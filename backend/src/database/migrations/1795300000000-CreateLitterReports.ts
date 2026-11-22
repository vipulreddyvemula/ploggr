import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateLitterReports1795300000000 implements MigrationInterface {
  async up(runner: QueryRunner) {
    await runner.query(`
      CREATE TABLE litter_reports (
        id uuid PRIMARY KEY,
        author_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        collection_plog_id uuid REFERENCES plogs ON DELETE CASCADE,
        location geography(Point,4326) NOT NULL,
        category text NOT NULL,
        notes varchar(250) NOT NULL,
        fingerprint text NOT NULL,
        status text NOT NULL CHECK (status IN ('uploading','pending_finish','open','collected','withdrawn','hidden')),
        created_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX litter_reports_position ON litter_reports USING gist((location::geometry));
      CREATE INDEX litter_reports_author ON litter_reports(author_id, created_at DESC);
      CREATE INDEX litter_reports_collection ON litter_reports(collection_plog_id);
      CREATE TABLE litter_report_photos (
        report_id uuid NOT NULL REFERENCES litter_reports ON DELETE CASCADE,
        position smallint NOT NULL CHECK (position BETWEEN 0 AND 5),
        storage_key text NOT NULL UNIQUE,
        PRIMARY KEY(report_id,position)
      );
      CREATE TABLE plog_pickups (
        plog_id uuid NOT NULL REFERENCES plogs ON DELETE CASCADE,
        report_id uuid NOT NULL REFERENCES litter_reports ON DELETE CASCADE,
        PRIMARY KEY(plog_id,report_id)
      );
      CREATE TABLE litter_report_flags (
        report_id uuid NOT NULL REFERENCES litter_reports ON DELETE CASCADE,
        user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        created_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY(report_id,user_id)
      );
    `);
  }
  async down(runner: QueryRunner) {
    await runner.query('DROP TABLE litter_report_flags, plog_pickups, litter_report_photos, litter_reports');
  }
}
