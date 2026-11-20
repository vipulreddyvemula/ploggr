import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateGarbageEvidence1795172900000 implements MigrationInterface {
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`
      CREATE TABLE garbage_evidence (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        plog_id uuid NOT NULL CONSTRAINT garbage_evidence_plog_fk REFERENCES plogs(id) ON DELETE CASCADE,
        storage_key text NOT NULL CONSTRAINT garbage_evidence_storage_key_key UNIQUE,
        media_type text NOT NULL,
        byte_size integer NOT NULL,
        sha256 text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        uploaded_at timestamptz,
        CONSTRAINT garbage_evidence_reference_check CHECK (storage_key <> '' AND storage_key = btrim(storage_key)),
        CONSTRAINT garbage_evidence_metadata_check CHECK (byte_size > 0 AND media_type <> '' AND sha256 ~ '^[0-9a-f]{64}$')
      );
      CREATE INDEX garbage_evidence_plog_idx ON garbage_evidence(plog_id)
    `);
  }
  async down(runner: QueryRunner): Promise<void> {
    await runner.query('DROP TABLE garbage_evidence');
  }
}
