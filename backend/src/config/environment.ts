export interface DatabaseEnvironment {
  DB_HOST: string;
  DB_PORT: number;
  DB_NAME: string;
  DB_USER: string;
  DB_PASSWORD: string;
}

interface StorageEnvironment {
  bucket: string;
  region: string;
  endpoint?: string;
  credentials?: { accessKeyId: string; secretAccessKey: string };
}

function storageEnvironment(config: Record<string, unknown>): StorageEnvironment | undefined {
  const { EVIDENCE_S3_BUCKET: bucket, EVIDENCE_S3_ENDPOINT: endpoint, EVIDENCE_S3_REGION: region,
    EVIDENCE_S3_ACCESS_KEY: accessKeyId, EVIDENCE_S3_SECRET_KEY: secretAccessKey } = config;
  if ([bucket, endpoint, region, accessKeyId, secretAccessKey].every(value => value === undefined)) return undefined;
  if (typeof bucket !== 'string' || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket)) {
    throw new Error('Set a valid EVIDENCE_S3_BUCKET');
  }
  if (region !== undefined && (typeof region !== 'string' || !region.trim())) throw new Error('Invalid EVIDENCE_S3_REGION');
  if (endpoint !== undefined) {
    if (typeof endpoint !== 'string' || !URL.canParse(endpoint)) throw new Error('Invalid EVIDENCE_S3_ENDPOINT');
    const url = new URL(endpoint);
    if (url.username || url.password || url.search || url.hash || !['http:', 'https:'].includes(url.protocol) ||
      (config.NODE_ENV === 'production' && url.protocol !== 'https:')) throw new Error('Invalid EVIDENCE_S3_ENDPOINT');
  }
  let credentials;
  if (accessKeyId !== undefined || secretAccessKey !== undefined) {
    if (typeof accessKeyId !== 'string' || !accessKeyId.trim() || typeof secretAccessKey !== 'string' || !secretAccessKey.trim()) {
      throw new Error('Configure both evidence storage credentials or use the workload role');
    }
    credentials = { accessKeyId, secretAccessKey };
  }
  return { bucket, region: region ?? 'us-east-1', endpoint, credentials };
}

export interface Environment extends DatabaseEnvironment {
  evidenceStorage?: StorageEnvironment;
  NODE_ENV: 'development' | 'test' | 'production';
  HOST: string;
  AUTH_SECRET: string;
  AUTH_ACCESS_TTL_SECONDS: number;
  PORT: number;
  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
  GEMINI_FALLBACK_MODELS?: string[];
  PHOTON_URL?: string;
}

export const defaultGeminiFallbackModels = ['gemini-3.5-flash-lite', 'gemini-3.8-flash'];

function parseGeminiFallbackModels(value: unknown): string[] | undefined {
  if (value === undefined) return;
  if (typeof value === 'string') {
    const models = [...new Set(value.split(',').map((name) => name.trim()).filter(Boolean))];
    if (models.length <= 2 && models.every((name) => /^[a-z0-9][a-z0-9.-]{0,127}$/i.test(name))) {
      return models;
    }
  }
  throw new Error('GEMINI_FALLBACK_MODELS must be a comma-separated list of up to two model IDs');
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

  const geminiApiKey =
    typeof config.GEMINI_API_KEY === 'string' && config.GEMINI_API_KEY.trim()
      ? config.GEMINI_API_KEY.trim()
      : undefined;
  const geminiModel =
    typeof config.GEMINI_MODEL === 'string' && config.GEMINI_MODEL.trim()
      ? config.GEMINI_MODEL.trim()
      : undefined;
  const photonUrl = config.PHOTON_URL || undefined;
  if (photonUrl !== undefined) {
    if (typeof photonUrl !== 'string' || !URL.canParse(photonUrl)) {
      throw new Error('Invalid PHOTON_URL');
    }
    const url = new URL(photonUrl);
    if (!['http:', 'https:'].includes(url.protocol) ||
        url.username || url.password || url.search || url.hash) {
      throw new Error('Invalid PHOTON_URL');
    }
  }

  return {
    evidenceStorage: storageEnvironment(config),
    AUTH_ACCESS_TTL_SECONDS: ttl,
    AUTH_SECRET: secret,
    NODE_ENV: nodeEnv,
    HOST: host.trim(),
    PORT: port,
    GEMINI_API_KEY: geminiApiKey,
    GEMINI_MODEL: geminiModel,
    PHOTON_URL: photonUrl,
    GEMINI_FALLBACK_MODELS: parseGeminiFallbackModels(config.GEMINI_FALLBACK_MODELS),
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
