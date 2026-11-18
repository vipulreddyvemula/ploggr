import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateAuthSessions1795020000000 implements MigrationInterface {
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`
      CREATE TABLE auth_sessions (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL CONSTRAINT auth_sessions_user_fk REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX auth_sessions_user_idx ON auth_sessions(user_id);
      CREATE TABLE auth_refresh_tokens (
        digest text PRIMARY KEY,
        session_id uuid NOT NULL CONSTRAINT auth_refresh_session_fk REFERENCES auth_sessions(id) ON DELETE CASCADE,
        request_id uuid,
        encrypted_successor bytea
      );
      CREATE INDEX auth_refresh_session_idx ON auth_refresh_tokens(session_id)
    `);
  }

  async down(runner: QueryRunner): Promise<void> {
    await runner.query('DROP TABLE auth_refresh_tokens, auth_sessions');
  }
}
