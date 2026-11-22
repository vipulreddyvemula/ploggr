import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AuthSession, RefreshCredential } from '../modules/auth/session.entity';
import { GarbageEvidence } from '../modules/evidence/garbage-evidence.entity';
import { Plog, PlogRoutePoint } from '../modules/plogs/plog.entity';
import { User } from '../modules/users/user.entity';
import { createDatabaseOptions, loadDatabaseEnvironment } from './database.config';
import { VerifyPostgis1794873600000 } from './migrations/1794873600000-VerifyPostgis';
import { CreateUsers1795018043320 } from './migrations/1795018043320-CreateUsers';
import { CreateAuthSessions1795020000000 } from './migrations/1795020000000-CreateAuthSessions';
import { CreatePlogs1795171000000 } from './migrations/1795171000000-CreatePlogs';
import { CreateGarbageEvidence1795172900000 } from './migrations/1795172900000-CreateGarbageEvidence';
import { FieldExperience1795400000000 } from './migrations/1795400000000-FieldExperience';
import { CreateLitterReports1795300000000 } from './migrations/1795300000000-CreateLitterReports';

describe('shared database configuration', () => {
  it('disables implicit schema changes and uses explicit credentials', () => {
    expect(createDatabaseOptions({
      DB_HOST: '127.0.0.1', DB_PORT: 5433, DB_NAME: 'test',
      DB_USER: 'app', DB_PASSWORD: 'test_password',
    })).toMatchObject({
      type: 'postgres', host: '127.0.0.1', port: 5433, database: 'test',
      username: 'app', password: 'test_password', connectTimeoutMS: 5000,
      synchronize: false, migrationsRun: false, uuidExtension: 'pgcrypto', installExtensions: false,
      entities: [User, AuthSession, RefreshCredential, Plog, PlogRoutePoint, GarbageEvidence],
      migrations: [
        VerifyPostgis1794873600000, CreateUsers1795018043320, CreateAuthSessions1795020000000, CreatePlogs1795171000000,
        CreateGarbageEvidence1795172900000, CreateLitterReports1795300000000, FieldExperience1795400000000,
      ],
    });
  });

  it('loads .env for standalone tools while process variables take precedence', () => {
    const directory = mkdtempSync(join(tmpdir(), 'ploggr-config-'));
    const originalEnv = { ...process.env };
    try {
      process.env.NODE_ENV = 'development';
      writeFileSync(join(directory, '.env'), 'DB_USER=file_user\nDB_PASSWORD=file_password\nDB_PORT=5544\n');
      delete process.env.DB_PORT;
      delete process.env.DB_PASSWORD;
      process.env.DB_USER = 'process_user';
      const env = loadDatabaseEnvironment(join(directory, '.env'));
      expect(env.DB_USER).toBe('process_user');
      expect(env.DB_PORT).toBe(5544);
      expect(env.DB_PASSWORD).toBe('file_password');
    } finally {
      process.env = originalEnv;
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it('does not load file credentials in test mode', () => {
    const directory = mkdtempSync(join(tmpdir(), 'ploggr-test-config-'));
    const originalEnv = { ...process.env };
    try {
      writeFileSync(join(directory, '.env'), 'DB_USER=local_user\nDB_PASSWORD=private_value\n');
      process.env.NODE_ENV = 'test';
      delete process.env.DB_PASSWORD;
      expect(() => loadDatabaseEnvironment(join(directory, '.env')))
        .toThrow('DB_PASSWORD must be a non-empty string');
      expect(process.env.DB_PASSWORD).toBeUndefined();
    } finally {
      process.env = originalEnv;
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
