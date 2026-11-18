import 'reflect-metadata';
import { randomUUID } from 'node:crypto';
import { Test, type TestingModule } from '@nestjs/testing';
import { DataSource } from 'typeorm';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/app.setup';
import { createDatabaseOptions, loadDatabaseEnvironment } from '../src/database/database.config';
import { checkDatabase } from '../src/database/database-check';
import { VerifyPostgis1794873600000 } from '../src/database/migrations/1794873600000-VerifyPostgis';
import { CreateUsers1795018043320 } from '../src/database/migrations/1795018043320-CreateUsers';
import { User } from '../src/modules/users/user.entity';
import { UsersService } from '../src/modules/users/users.service';
import request from 'supertest';

describe('PostgreSQL / PostGIS (isolated Compose database)', () => {
  let source: DataSource;

  beforeAll(async () => {
    source = new DataSource(createDatabaseOptions(loadDatabaseEnvironment()));
    await source.initialize();
  });

  afterAll(async () => {
    if (source?.isInitialized) await source.destroy();
  });

  it('uses an application role without superuser privileges', async () => {
    const [role] = await source.query(
      'SELECT rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = current_user',
    );
    expect(role).toEqual({ rolsuper: false, rolcreatedb: false, rolcreaterole: false });
  });

  it('checks connectivity, PostGIS, and spatial operations', async () => {
    expect(await checkDatabase(source)).toMatchObject({
      connectivity: true, postgresql: expect.stringContaining('PostgreSQL'),
      postgis: expect.stringContaining('POSTGIS='),
      spatial: { type: 'Point', coordinates: [78.4867, 17.385] },
    });
  });

  it('applies both migrations on a fresh database and upgrades from M1 after rollback', async () => {
    expect(await source.showMigrations()).toBe(true);
    expect((await source.runMigrations()).map(({ name }) => name)).toEqual([
      VerifyPostgis1794873600000.name,
      CreateUsers1795018043320.name,
    ]);
    expect(await source.showMigrations()).toBe(false);
    expect(await source.runMigrations()).toHaveLength(0);

    await source.undoLastMigration();
    expect(await source.query('SELECT name FROM migrations')).toEqual([
      { name: VerifyPostgis1794873600000.name },
    ]);
    expect(await source.query("SELECT to_regclass('public.users') AS users")).toEqual([{ users: null }]);
    expect((await checkDatabase(source)).postgis).toContain('POSTGIS=');
    expect(await source.showMigrations()).toBe(true);
    expect((await source.runMigrations()).map(({ name }) => name)).toEqual([CreateUsers1795018043320.name]);
    expect(await source.showMigrations()).toBe(false);
  });

  it('has only the migration history and users tables outside PostGIS', async () => {
    // Extension-owned tables (e.g. spatial_ref_sys) are infrastructure, not domain tables.
    const tables = await source.query(`
      SELECT c.relname AS name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
            AND d.objid = c.oid AND d.deptype = 'e'
        ) ORDER BY c.relname
    `);
    expect(tables).toEqual([{ name: 'migrations' }, { name: 'users' }]);
    expect((await source.driver.createSchemaBuilder().log()).upQueries).toEqual([]);
  });

  describe('user identity persistence', () => {
    let module: TestingModule;
    let users: UsersService;

    beforeAll(async () => {
      module = await Test.createTestingModule({ imports: [AppModule] }).compile();
      users = module.get(UsersService);
    });

    afterAll(async () => {
      await module?.close();
    });

    it('persists identities with stable UUIDs and returns only identity fields', async () => {
      const passwordHash = 'test-only-password-hash';
      const first = await users.create({ email: '  First@Example.test ', passwordHash });
      const second = await users.create({ email: 'second@example.test', passwordHash });

      expect(first).toStrictEqual({
        id: expect.stringMatching(/^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$/),
        email: 'first@example.test',
      });
      expect(second.id).not.toBe(first.id);
      expect(await users.findById(first.id)).toStrictEqual(first);
      expect(await users.findByEmail(' FIRST@example.test  ')).toStrictEqual(first);
      expect(await users.findById(randomUUID())).toBeNull();
      expect(await users.findByEmail('missing@example.test')).toBeNull();

      // Read through a separate pool to verify what was persisted and what TypeORM selects by default.
      const repository = source.getRepository(User);
      expect(await repository.findOneBy({ id: first.id })).toEqual(first);
      expect(await repository.createQueryBuilder('user')
        .addSelect('user.passwordHash').where({ id: first.id }).getOne())
        .toEqual({ ...first, passwordHash });
    });

    it('rejects concurrent inserts for equivalent emails at the database constraint', async () => {
      const results = await Promise.allSettled([
        users.create({ email: '  Duplicate@example.test ', passwordHash: 'test-hash-a' }),
        users.create({ email: 'duplicate@EXAMPLE.test', passwordHash: 'test-hash-b' }),
      ]);
      expect(results).toEqual(expect.arrayContaining([
        expect.objectContaining({ status: 'fulfilled' }),
        expect.objectContaining({
          status: 'rejected',
          reason: expect.objectContaining({ code: '23505', constraint: 'users_email_key' }),
        }),
      ]));
      expect(await source.getRepository(User).countBy({ email: 'duplicate@example.test' })).toBe(1);
    });

    it('requires canonical emails and a non-null hash even outside the service', async () => {
      for (const email of ['', 'untrimmed@example.test ', 'Uppercase@example.test']) {
        await expect(source.query('INSERT INTO users (email, password_hash) VALUES ($1, $2)', [email, 'test-hash']))
          .rejects.toMatchObject({ code: '23514', constraint: 'users_email_canonical' });
      }
      await expect(source.query('INSERT INTO users (email) VALUES ($1)', ['missing-hash@example.test']))
        .rejects.toMatchObject({ code: '23502', column: 'password_hash' });
    });

    it('supports foreign keys for future ownership', async () => {
      const { id } = await users.create({ email: 'owner@example.test', passwordHash: 'test-hash' });
      await expect(source.transaction(async manager => {
        // The missing-owner insert aborts the transaction and rolls back the test table.
        await manager.query('CREATE TABLE test_ownership (user_id uuid NOT NULL REFERENCES users (id))');
        await expect(manager.query('INSERT INTO test_ownership VALUES ($1) RETURNING user_id', [id]))
          .resolves.toEqual([{ user_id: id }]);
        await manager.query('INSERT INTO test_ownership VALUES ($1)', [randomUUID()]);
      })).rejects.toMatchObject({ code: '23503', table: 'test_ownership' });
    });
  });

  it('starts NestJS against the real database and releases its pool on shutdown', async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] }).compile();
    const app = module.createNestApplication();
    const applicationSource = app.get(DataSource);
    try {
      configureApp(app);
      await app.init();
      expect(applicationSource.isInitialized).toBe(true);
      await request(app.getHttpServer()).get('/api/health').expect(200, { status: 'ok' });
      await request(app.getHttpServer()).get('/api/health/ready')
        .expect('Cache-Control', 'no-store')
        .expect(200, { status: 'ok', database: 'up', postgis: 'up' });
    } finally {
      await app.close();
    }
    expect(applicationSource.isInitialized).toBe(false);
  });

  it('rejects incorrect credentials', async () => {
    const invalid = new DataSource(createDatabaseOptions({
      ...loadDatabaseEnvironment(), DB_PASSWORD: 'incorrect_password',
    }));
    try {
      await expect(invalid.initialize()).rejects.toThrow();
    } finally {
      if (invalid.isInitialized) await invalid.destroy();
    }
  });
});
