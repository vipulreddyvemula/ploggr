import type { MigrationInterface, QueryRunner } from 'typeorm';
import { savePlogRewardReceiptSql } from './plog-reward-receipt';

export class Gamification1795700000000 implements MigrationInterface {
  async up(db: QueryRunner) {
    await db.query(`
      CREATE TABLE gamification_season (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        starts_at timestamptz NOT NULL DEFAULT now()
      );
      INSERT INTO gamification_season DEFAULT VALUES;

      CREATE TABLE cleanup_goals (
        user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        cadence text NOT NULL CHECK (cadence IN ('day','week')),
        target integer NOT NULL CHECK (target BETWEEN 1 AND 100)
      );

      ALTER TABLE plog_analysis ADD COLUMN approved_at timestamptz, ADD COLUMN reward_policy jsonb;
      CREATE FUNCTION current_cleanup_policy() RETURNS jsonb LANGUAGE sql STABLE AS $$
        SELECT coalesce(
          (SELECT jsonb_build_object('version', version, 'material_points', material_points,
             'carbon_points_per_kg', carbon_points_per_kg) FROM impact_rules WHERE active),
          '{"version":"m5-v1","material_points":{"Plastic":1,"PET plastic":1,"HDPE plastic":1,"PP plastic":1,"Plastic film":1,"Foam plastic":1,"Paper":1,"Cardboard":1,"Glass":1,"Metal":1,"Aluminum":1,"Steel":1,"E-waste":1,"Battery":1,"Textile":1,"Rubber":1,"Wood":1,"Ceramic":1,"Construction debris":1,"Organic":1,"Mixed":1,"Other":1},"carbon_points_per_kg":2}'::jsonb)
      $$;
      UPDATE plog_analysis a SET reward_policy=current_cleanup_policy(),
        approved_at=CASE WHEN a.state='ready' THEN coalesce(p.completed_at,p.ended_at) END
        FROM plogs p WHERE p.id=a.plog_id;
      CREATE FUNCTION analysis_needs_review(result jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
        WITH groups AS (
          SELECT item, n, (item->>'count')::int AS amount
          FROM jsonb_array_elements(result->'items') WITH ORDINALITY AS g(item,n)
        )
        SELECT EXISTS (SELECT 1 FROM groups WHERE amount>25
          OR (item->'weight'->>'estimateKg')::numeric>5*amount) OR
          coalesce((SELECT sum(amount)>50 FROM groups),false) OR
          EXISTS (SELECT 1 FROM groups a JOIN groups b ON a.n<b.n
            WHERE (a.item->'photoIds') ?| ARRAY(SELECT jsonb_array_elements_text(b.item->'photoIds'))
              AND (
                (a.item->>'material'=b.item->>'material' AND a.item->>'type'=b.item->>'type')
                OR (a.item->'photoIds'->>0=b.item->'photoIds'->>0 AND a.item->'box'=b.item->'box')
              ))
      $$;
      UPDATE plog_analysis SET state='review',approved_at=NULL
        WHERE state='ready' AND NOT reviewed AND analysis_needs_review(result);

      CREATE FUNCTION record_cleanup_reward_inputs() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP='INSERT' THEN
          NEW.reward_policy := current_cleanup_policy();
        ELSE
          NEW.reward_policy := OLD.reward_policy;
        END IF;
        IF NEW.state='ready' AND NOT NEW.reviewed AND analysis_needs_review(NEW.result) THEN
          NEW.state := 'review';
        END IF;
        IF NEW.state='ready' AND (TG_OP='INSERT' OR OLD.state IS DISTINCT FROM NEW.state
           OR OLD.result IS DISTINCT FROM NEW.result) THEN
          NEW.approved_at := clock_timestamp();
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER plog_analysis_reward_inputs BEFORE INSERT OR UPDATE ON plog_analysis
        FOR EACH ROW EXECUTE FUNCTION record_cleanup_reward_inputs();
      ALTER TABLE plog_analysis ALTER COLUMN reward_policy SET NOT NULL;

      ALTER TABLE litter_report_photos ADD COLUMN perceptual_hash text, ADD COLUMN published_at timestamptz;
      UPDATE litter_report_photos f SET published_at=r.created_at FROM litter_reports r WHERE f.report_id=r.id;
      ALTER TABLE litter_report_photos ALTER COLUMN published_at SET DEFAULT clock_timestamp();
      CREATE FUNCTION photo_hash_bands(hash text) RETURNS text[] LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
        SELECT ARRAY['0:'||substr(hash,1,4),'1:'||substr(hash,5,3),'2:'||substr(hash,8,3),
          '3:'||substr(hash,11,3),'4:'||substr(hash,14,3)]
      $$;
      CREATE FUNCTION images_match(sha_a text, hash_a text, sha_b text, hash_b text)
        RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
        SELECT sha_a=sha_b OR (photo_hash_bands(hash_a) && photo_hash_bands(hash_b)
          AND bit_count(('x'||hash_a)::bit(64) # ('x'||hash_b)::bit(64)) <= 4)
      $$;
      CREATE INDEX cleanup_evidence_bands ON garbage_evidence USING gin (photo_hash_bands(perceptual_hash));
      CREATE INDEX sighting_photo_bands ON litter_report_photos USING gin (photo_hash_bands(perceptual_hash));
      CREATE INDEX plogs_completed_period ON plogs(ended_at,user_id) WHERE status='completed';
      CREATE TABLE plog_reward_receipts (
        plog_id uuid PRIMARY KEY REFERENCES plog_analysis(plog_id) ON DELETE CASCADE,
        policy jsonb NOT NULL,
        state text NOT NULL,
        points numeric NOT NULL,
        evidence_and_components jsonb,
        updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
      );

      ${savePlogRewardReceiptSql(false)}
      CREATE FUNCTION update_plog_reward_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM save_plog_reward_receipt(NEW.plog_id);
        RETURN NEW;
      END $$;
      CREATE TRIGGER plog_reward_receipt_changed AFTER INSERT OR UPDATE OF state,result,reviewed
        ON plog_analysis FOR EACH ROW EXECUTE FUNCTION update_plog_reward_receipt();

      CREATE FUNCTION update_spot_reward_receipts() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE affected uuid;
      BEGIN
        FOR affected IN SELECT a.plog_id FROM plog_analysis a
          JOIN spot_observations o ON o.plog_id=a.plog_id
          WHERE o.report_id=NEW.id AND o.outcome='cleaned' AND o.verification='verified' AND o.resolved
          ORDER BY a.plog_id FOR NO KEY UPDATE OF a
        LOOP
          PERFORM save_plog_reward_receipt(affected);
        END LOOP;
        RETURN NEW;
      END $$;
      CREATE TRIGGER spot_reward_receipt_changed AFTER UPDATE OF status
        ON litter_reports FOR EACH ROW
        WHEN (OLD.status IS DISTINCT FROM NEW.status)
        EXECUTE FUNCTION update_spot_reward_receipts();

      SELECT save_plog_reward_receipt(o.plog_id) FROM (
        SELECT DISTINCT plog_id FROM spot_observations
        WHERE outcome='cleaned' AND verification='verified' AND resolved
      ) o;
    `);
  }

  async down(db: QueryRunner) {
    await db.query(`
      DROP TRIGGER spot_reward_receipt_changed ON litter_reports;
      DROP TRIGGER plog_reward_receipt_changed ON plog_analysis;
      DROP FUNCTION update_spot_reward_receipts();
      DROP FUNCTION update_plog_reward_receipt();
      DROP FUNCTION save_plog_reward_receipt(uuid);
      DROP TABLE plog_reward_receipts;
      DROP INDEX plogs_completed_period, sighting_photo_bands, cleanup_evidence_bands;
      DROP FUNCTION images_match(text,text,text,text);
      DROP FUNCTION photo_hash_bands(text);
      ALTER TABLE litter_report_photos DROP COLUMN perceptual_hash, DROP COLUMN published_at;
      DROP TRIGGER plog_analysis_reward_inputs ON plog_analysis;
      DROP FUNCTION record_cleanup_reward_inputs();
      DROP FUNCTION current_cleanup_policy();
      DROP FUNCTION analysis_needs_review(jsonb);
      ALTER TABLE plog_analysis DROP COLUMN approved_at, DROP COLUMN reward_policy;
      DROP TABLE cleanup_goals, gamification_season;
    `);
  }
}
