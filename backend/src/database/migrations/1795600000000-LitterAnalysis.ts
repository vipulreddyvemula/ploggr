import type { MigrationInterface, QueryRunner } from 'typeorm';

export class LitterAnalysis1795600000000 implements MigrationInterface {
  async up(db: QueryRunner) {
    await db.query(`
      ALTER TABLE plog_analysis ADD COLUMN review_note varchar(500);
      CREATE INDEX litter_report_photos_sha_idx ON litter_report_photos(sha256) WHERE sha256 IS NOT NULL;
      CREATE INDEX spot_observations_cleanup_plog_idx ON spot_observations(plog_id) WHERE outcome='cleaned';
    `);
  }

  async down(db: QueryRunner) {
    await db.query(`
      DROP INDEX spot_observations_cleanup_plog_idx;
      DROP INDEX litter_report_photos_sha_idx;
      ALTER TABLE plog_analysis DROP COLUMN review_note;
    `);
  }
}
