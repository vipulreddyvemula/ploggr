export interface DatabaseEnvironment {
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
}

export interface Environment extends DatabaseEnvironment {
  NODE_ENV: 'development' | 'test' | 'production';
  HOST: string;
  AUTH_SECRET: string;
  AUTH_ACCESS_TTL_SECONDS: number;
  PORT: number;
}

function parsePort(value: unknown, name: 'PORT' | 'DB_PORT', fallback: number): number {
  const raw = value ?? fallback;
  const port = Number(raw);
  if (!/^\d+$/.test(String(raw)) || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`${name} must be an integer between 1 and 65535`);
  }
  return port;
}

export function validateEnvironment(config: Record<string, unknown>): Environment {
  const nodeEnv = config.NODE_ENV ?? 'development';
  if (nodeEnv !== 'development' && nodeEnv !== 'test' && nodeEnv !== 'production') {
    throw new Error('NODE_ENV must be development, test, or production');
  }

  const host = config.HOST ?? '127.0.0.1';
  if (typeof host !== 'string' || host.trim().length === 0) {
    throw new Error('HOST must be a non-empty hostname or IP address');
  }

  const port = parsePort(config.PORT, 'PORT', 3000);

  const database = validateDatabaseEnvironment(config);
  const secret = config.AUTH_SECRET;
  if (typeof secret !== 'string' || !/^[0-9a-f]{64}$/i.test(secret)) {
    throw new Error('AUTH_SECRET must be 32 random bytes encoded as 64 hex characters');
  }

  const ttl = Number(config.AUTH_ACCESS_TTL_SECONDS ?? 900);
  if (!Number.isInteger(ttl) || ttl < 1 || ttl > 900) {
    throw new Error('AUTH_ACCESS_TTL_SECONDS must be an integer from 1 through 900');
  }

  return {
    AUTH_ACCESS_TTL_SECONDS: ttl,
    AUTH_SECRET: secret,
    NODE_ENV: nodeEnv,
    HOST: host.trim(),
    PORT: port,
    ...database,
  };
}

export function validateDatabaseEnvironment(config: Record<string, unknown>): DatabaseEnvironment {
  const port = parsePort(config.DB_PORT, 'DB_PORT', 5432);

  function text(name: string, fallback?: string): string {
    const value = config[name] ?? fallback;
    if (typeof value !== 'string' || value.trim().length === 0) {
      throw new Error(`${name} must be a non-empty string`);
    }
    // Passwords are used verbatim, including intentional surrounding whitespace.
    return name === 'DB_PASSWORD' ? value : value.trim();
  }

  return {
    DB_HOST: text('DB_HOST', '127.0.0.1'),
    DB_PORT: port,
    DB_NAME: text('DB_NAME', 'ploggr'),
    DB_USER: text('DB_USER'),
    DB_PASSWORD: text('DB_PASSWORD'),
  };
}
