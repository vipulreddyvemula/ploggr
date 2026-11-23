import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CorePlogIntegrity1795500000000 implements MigrationInterface {
  async up(db: QueryRunner) {
    await db.query(`
      ALTER TABLE plogs DROP CONSTRAINT plogs_lifecycle_check,
        ADD CONSTRAINT plogs_lifecycle_check CHECK (
          (status = 'active' AND ended_at IS NULL) OR
          (status IN ('completed','cancelled','abandoned') AND ended_at >= started_at AND ended_at IS NOT NULL)
        ),
        ADD COLUMN finish_fingerprint text, ADD COLUMN recording_device uuid, ADD COLUMN completed_at timestamptz;
      UPDATE plogs SET completed_at=ended_at WHERE status='completed';
      ALTER TABLE plog_route_points ADD COLUMN recorded_at timestamptz, ADD COLUMN accuracy_meters float8;
      ALTER TABLE garbage_evidence ADD COLUMN capture jsonb, ADD COLUMN perceptual_hash text;
      CREATE INDEX garbage_evidence_sha_idx ON garbage_evidence(sha256);
      CREATE INDEX garbage_evidence_phash_bucket ON garbage_evidence(left(perceptual_hash,4))
        WHERE perceptual_hash IS NOT NULL;
      ALTER TABLE litter_report_photos ADD COLUMN capture jsonb, ADD COLUMN sha256 text;
      ALTER TABLE litter_reports ADD COLUMN collection_verification text,
        ADD COLUMN previous_report_id uuid REFERENCES litter_reports(id) ON DELETE SET NULL,
        ADD COLUMN upload_token uuid NOT NULL DEFAULT gen_random_uuid(),
        ADD COLUMN location_source text NOT NULL DEFAULT 'manual' CHECK(location_source IN ('gps','manual'));
      ALTER TABLE spot_observations ADD COLUMN plog_id uuid REFERENCES plogs(id) ON DELETE CASCADE,
        ADD COLUMN verification text NOT NULL DEFAULT 'unverified'
          CHECK(verification IN ('pending','verified','unverified','already_collected','legacy')),
        ADD COLUMN observed_at timestamptz, ADD COLUMN reward_sha256 text;
      ALTER TABLE spot_observations DROP CONSTRAINT spot_observations_outcome_check,
        ADD CONSTRAINT spot_observations_outcome_check CHECK(outcome IN ('cleaned','remains','missing','present'));
      ALTER TABLE plog_analysis ADD COLUMN suspicious_evidence boolean NOT NULL DEFAULT false;
      CREATE TABLE litter_report_status_history (
        event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        report_id uuid NOT NULL REFERENCES litter_reports(id) ON DELETE CASCADE,
        status text NOT NULL,
        changed_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX litter_report_status_history_report ON litter_report_status_history(report_id,event_id);
      INSERT INTO litter_report_status_history(report_id,status,changed_at)
        SELECT id,status,created_at FROM litter_reports;
      CREATE FUNCTION record_litter_report_status() RETURNS trigger LANGUAGE plpgsql AS $sql$
      BEGIN
        IF TG_OP='INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
          INSERT INTO litter_report_status_history(report_id,status) VALUES (NEW.id,NEW.status);
        END IF;
        RETURN NEW;
      END;
      $sql$;
      CREATE TRIGGER litter_report_status_changed AFTER INSERT OR UPDATE OF status ON litter_reports
        FOR EACH ROW EXECUTE FUNCTION record_litter_report_status();
      UPDATE spot_observations SET verification='legacy',
        plog_id=(SELECT plog_id FROM garbage_evidence WHERE id=photo_id);
      CREATE INDEX spot_observations_plog_idx ON spot_observations(plog_id) WHERE verification='pending';
      CREATE INDEX spot_observations_photo_idx ON spot_observations(photo_id) WHERE photo_id IS NOT NULL;
      CREATE UNIQUE INDEX spot_observations_reward_sha ON spot_observations(reward_sha256)
        WHERE reward_sha256 IS NOT NULL;
      CREATE TABLE litter_report_draft_cancellations (
        author_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        report_id uuid NOT NULL,
        PRIMARY KEY(author_id, report_id)
      );
      CREATE TABLE evidence_deletion_queue (storage_key text PRIMARY KEY,
        next_attempt timestamptz NOT NULL DEFAULT now());
      CREATE INDEX evidence_deletion_ready ON evidence_deletion_queue(next_attempt,storage_key);
      CREATE FUNCTION queue_report_photo_deletion(report uuid) RETURNS void LANGUAGE sql AS $sql$
        INSERT INTO evidence_deletion_queue(storage_key)
        SELECT storage_key FROM litter_report_photos WHERE report_id=report
        UNION ALL
        SELECT 'evidence/reports/' || r.id || '/' || r.upload_token || '/' || n || '.jpg'
          FROM litter_reports r CROSS JOIN generate_series(0,5) n WHERE r.id=report AND r.status='uploading'
        UNION ALL
        SELECT 'evidence/reports/' || r.id || '/' || n || '.jpg'
          FROM litter_reports r CROSS JOIN generate_series(0,5) n WHERE r.id=report AND r.status='uploading'
        ON CONFLICT DO NOTHING
      $sql$;
    `);
  }

  async down(db: QueryRunner) {
    await db.query(`
      DROP INDEX garbage_evidence_sha_idx;
      DELETE FROM plogs WHERE status IN ('cancelled','abandoned');
      ALTER TABLE plogs DROP CONSTRAINT plogs_lifecycle_check,
        ADD CONSTRAINT plogs_lifecycle_check CHECK (
          (status = 'active' AND ended_at IS NULL) OR
          (status = 'completed' AND ended_at IS NOT NULL AND ended_at >= started_at)
        ), DROP COLUMN finish_fingerprint, DROP COLUMN recording_device, DROP COLUMN completed_at;
      ALTER TABLE plog_route_points DROP COLUMN recorded_at, DROP COLUMN accuracy_meters;
      ALTER TABLE garbage_evidence DROP COLUMN capture, DROP COLUMN perceptual_hash;
      ALTER TABLE litter_report_photos DROP COLUMN capture, DROP COLUMN sha256;
      ALTER TABLE litter_reports DROP COLUMN collection_verification, DROP COLUMN location_source, DROP COLUMN upload_token, DROP COLUMN previous_report_id;
      DROP TRIGGER litter_report_status_changed ON litter_reports;
      DROP FUNCTION record_litter_report_status();
      DROP TABLE litter_report_status_history;
      ALTER TABLE plog_analysis DROP COLUMN suspicious_evidence;
      DELETE FROM spot_observations WHERE outcome='present';
      ALTER TABLE spot_observations DROP CONSTRAINT spot_observations_outcome_check,
        ADD CONSTRAINT spot_observations_outcome_check CHECK(outcome IN ('cleaned','remains','missing'));
      ALTER TABLE spot_observations DROP COLUMN plog_id, DROP COLUMN verification,
        DROP COLUMN observed_at, DROP COLUMN reward_sha256;
      DROP TABLE litter_report_draft_cancellations;
      DROP FUNCTION queue_report_photo_deletion(uuid);
      DROP TABLE evidence_deletion_queue;
    `);
  }
}
