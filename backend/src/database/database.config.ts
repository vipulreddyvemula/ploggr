import type { DataSourceOptions } from 'typeorm';
import { validateDatabaseEnvironment, type DatabaseEnvironment } from '../config/environment';
import { loadEnvironmentFile } from '../config/environment-file';
import { AuthSession, RefreshCredential } from '../modules/auth/session.entity';
import { Plog, PlogRoutePoint } from '../modules/plogs/plog.entity';
import { User } from '../modules/users/user.entity';
import { VerifyPostgis1794873600000 } from './migrations/1794873600000-VerifyPostgis';
import { CreateUsers1795018043320 } from './migrations/1795018043320-CreateUsers';
import { CreateAuthSessions1795020000000 } from './migrations/1795020000000-CreateAuthSessions';
import { CreatePlogs1795171000000 } from './migrations/1795171000000-CreatePlogs';

export function loadDatabaseEnvironment(envFile?: string): DatabaseEnvironment {
  loadEnvironmentFile(envFile);
  return validateDatabaseEnvironment(process.env);
}

export function createDatabaseOptions(env: DatabaseEnvironment): DataSourceOptions {
  return {
    type: 'postgres',
    host: env.DB_HOST,
    port: env.DB_PORT,
    database: env.DB_NAME,
    username: env.DB_USER,
    password: env.DB_PASSWORD,
    connectTimeoutMS: 5000,
    extra: { query_timeout: 5000, statement_timeout: 5000 },
    ssl: false,
    synchronize: false,
    migrationsRun: false,
    uuidExtension: 'pgcrypto', // Selects PostgreSQL's built-in gen_random_uuid().
    installExtensions: false,
    entities: [User, AuthSession, RefreshCredential, Plog, PlogRoutePoint],
    migrations: [
      VerifyPostgis1794873600000, CreateUsers1795018043320, CreateAuthSessions1795020000000, CreatePlogs1795171000000,
    ],
    migrationsTableName: 'migrations',
    logging: false,
  };
}
