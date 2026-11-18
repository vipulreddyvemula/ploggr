import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateUsers1795018043320 implements MigrationInterface {
  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE users (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        email text NOT NULL,
        password_hash text NOT NULL,
        CONSTRAINT users_pkey PRIMARY KEY (id),
        CONSTRAINT users_email_key UNIQUE (email),
        CONSTRAINT users_email_canonical CHECK (email <> '' AND email = lower(btrim(email)))
      )
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE users');
  }
}
