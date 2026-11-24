import { UnreportedPickupRewards1795800000000 } from './migrations/1795800000000-UnreportedPickupRewards';
import { Gamification1795700000000 } from './migrations/1795700000000-Gamification';
import { LitterAnalysis1795600000000 } from './migrations/1795600000000-LitterAnalysis';
import type { DataSourceOptions } from 'typeorm';
import { validateDatabaseEnvironment, type DatabaseEnvironment } from '../config/environment';
import { loadEnvironmentFile } from '../config/environment-file';
import { AuthSession, RefreshCredential } from '../modules/auth/session.entity';
import { GarbageEvidence } from '../modules/evidence/garbage-evidence.entity';
import { Plog, PlogRoutePoint } from '../modules/plogs/plog.entity';
import { User } from '../modules/users/user.entity';
import { VerifyPostgis1794873600000 } from './migrations/1794873600000-VerifyPostgis';
import { CreateUsers1795018043320 } from './migrations/1795018043320-CreateUsers';
import { CreateAuthSessions1795020000000 } from './migrations/1795020000000-CreateAuthSessions';
import { CreatePlogs1795171000000 } from './migrations/1795171000000-CreatePlogs';
import { CreateGarbageEvidence1795172900000 } from './migrations/1795172900000-CreateGarbageEvidence';
import { FieldExperience1795400000000 } from './migrations/1795400000000-FieldExperience';
import { CorePlogIntegrity1795500000000 } from './migrations/1795500000000-CorePlogIntegrity';
import { CreateLitterReports1795300000000 } from './migrations/1795300000000-CreateLitterReports';

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
    ssl: env.DB_TLS ? { rejectUnauthorized: true } : false,
    synchronize: false,
    migrationsRun: false,
    uuidExtension: 'pgcrypto', // Selects PostgreSQL's built-in gen_random_uuid().
    installExtensions: false,
    entities: [User, AuthSession, RefreshCredential, Plog, PlogRoutePoint, GarbageEvidence],
    migrations: [
      VerifyPostgis1794873600000, CreateUsers1795018043320, CreateAuthSessions1795020000000, CreatePlogs1795171000000,
      CreateGarbageEvidence1795172900000, CreateLitterReports1795300000000, FieldExperience1795400000000, CorePlogIntegrity1795500000000,
        LitterAnalysis1795600000000, Gamification1795700000000, UnreportedPickupRewards1795800000000,
    ],
    migrationsTableName: 'migrations',
    logging: false,
  };
}
