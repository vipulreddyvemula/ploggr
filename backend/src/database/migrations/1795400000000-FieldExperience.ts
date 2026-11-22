import type { MigrationInterface, QueryRunner } from 'typeorm';

export class FieldExperience1795400000000 implements MigrationInterface {
  async up(db: QueryRunner) {
    await db.query(`
      ALTER TABLE plogs ADD COLUMN segment_starts integer[] NOT NULL DEFAULT '{}';
      ALTER TABLE users ADD COLUMN display_name varchar(50);
      ALTER TABLE litter_reports ADD COLUMN place varchar(160) NOT NULL DEFAULT '',
        ADD COLUMN last_seen_at timestamptz;
      CREATE INDEX litter_reports_open_geo ON litter_reports USING gist(location) WHERE status='open';
      CREATE TABLE spot_observations (
        id uuid PRIMARY KEY, report_id uuid NOT NULL REFERENCES litter_reports ON DELETE CASCADE,
        user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        outcome text NOT NULL CHECK(outcome IN ('cleaned','remains','missing')),
        photo_id uuid REFERENCES garbage_evidence ON DELETE CASCADE,
        resolved boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX spot_observations_report ON spot_observations(report_id,created_at);
      CREATE UNIQUE INDEX spot_observations_resolution ON spot_observations(report_id) WHERE resolved;
      CREATE TABLE plog_analysis (
        plog_id uuid PRIMARY KEY REFERENCES plogs ON DELETE CASCADE, state text NOT NULL DEFAULT 'queued'
          CHECK(state IN ('queued','processing','ready','review','failed')),
        result jsonb, model text, lease uuid, attempts int NOT NULL DEFAULT 0,
        next_run timestamptz NOT NULL DEFAULT now(), reviewed boolean NOT NULL DEFAULT false
      );
      INSERT INTO plog_analysis(plog_id) SELECT id FROM plogs WHERE status='completed';
      CREATE INDEX analysis_queue ON plog_analysis(next_run) WHERE state IN ('queued','processing');
      CREATE TABLE impact_rules (
        version text PRIMARY KEY, material_points jsonb NOT NULL, carbon_points_per_kg float8 NOT NULL DEFAULT 0,
        active boolean NOT NULL DEFAULT false
      );
      CREATE UNIQUE INDEX one_active_impact_rule ON impact_rules(active) WHERE active;
      CREATE TABLE disposal_factors (
        region text NOT NULL, material text NOT NULL, pathway text NOT NULL, factor float8 NOT NULL,
        source text NOT NULL, version text NOT NULL, PRIMARY KEY(region,material,pathway,version)
      );
      CREATE TABLE plog_disposal (
        plog_id uuid NOT NULL REFERENCES plogs ON DELETE CASCADE, material text NOT NULL,
        region text NOT NULL, mass_kg float8 NOT NULL CHECK(mass_kg>0),
        baseline text NOT NULL, actual text NOT NULL, factor_version text NOT NULL,
        PRIMARY KEY(plog_id,material)
      );
      CREATE TABLE community_posts (
        id uuid PRIMARY KEY, author_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        body varchar(1000) NOT NULL, plog_id uuid REFERENCES plogs ON DELETE SET NULL,
        hidden boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX community_feed ON community_posts(created_at DESC,id DESC) WHERE NOT hidden;
      CREATE TABLE post_reactions(post_id uuid REFERENCES community_posts ON DELETE CASCADE,
        user_id uuid REFERENCES users ON DELETE CASCADE, PRIMARY KEY(post_id,user_id));
      CREATE TABLE post_comments(id uuid PRIMARY KEY, post_id uuid NOT NULL REFERENCES community_posts ON DELETE CASCADE,
        user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, body varchar(500) NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now());
      CREATE TABLE post_flags(post_id uuid REFERENCES community_posts ON DELETE CASCADE,
        user_id uuid REFERENCES users ON DELETE CASCADE, PRIMARY KEY(post_id,user_id));
      CREATE TABLE cleanup_events(id uuid PRIMARY KEY, organizer uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        title varchar(80) NOT NULL, place varchar(160) NOT NULL, starts_at timestamptz NOT NULL,
        latitude float8 NOT NULL, longitude float8 NOT NULL, cancelled boolean NOT NULL DEFAULT false);
      CREATE TABLE event_rsvps(event_id uuid REFERENCES cleanup_events ON DELETE CASCADE,
        user_id uuid REFERENCES users ON DELETE CASCADE, PRIMARY KEY(event_id,user_id));
      CREATE TABLE cleanup_challenges(id uuid PRIMARY KEY, organizer uuid NOT NULL REFERENCES users ON DELETE CASCADE,
        title varchar(80) NOT NULL, goal int NOT NULL CHECK(goal>0), starts_at timestamptz NOT NULL,
        ends_at timestamptz NOT NULL CHECK(ends_at>starts_at));
      CREATE TABLE password_resets(user_id uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
        digest text NOT NULL, expires_at timestamptz NOT NULL, attempts int NOT NULL DEFAULT 0);
      CREATE TABLE external_identities(issuer text NOT NULL, subject text NOT NULL,
        user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, PRIMARY KEY(issuer,subject));
    `);
  }

  async down(db: QueryRunner) {
    await db.query(`
      DROP TABLE external_identities,password_resets,cleanup_challenges,event_rsvps,cleanup_events,post_flags,
        post_comments,post_reactions,community_posts,plog_disposal,disposal_factors,impact_rules,plog_analysis,spot_observations;
      DROP INDEX litter_reports_open_geo;
      ALTER TABLE litter_reports DROP COLUMN place, DROP COLUMN last_seen_at;
      ALTER TABLE plogs DROP COLUMN segment_starts;
      ALTER TABLE users DROP COLUMN display_name;
    `);
  }
}
