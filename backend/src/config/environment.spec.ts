import { validateEnvironment } from './environment';

describe('environment configuration', () => {
  const secret = 'af'.repeat(32);
  const credentials = { DB_USER: 'ploggr', DB_PASSWORD: 'test_password' };
  const database = {
    ...credentials,
    DB_HOST: '127.0.0.1',
    DB_PORT: 5432,
    DB_NAME: 'ploggr',
  };

  it('provides local development defaults', () => {
    expect(validateEnvironment({ ...credentials, AUTH_SECRET: secret })).toEqual({
      NODE_ENV: 'development',
      HOST: '127.0.0.1',
      PORT: 3000,
      ...database, AUTH_SECRET: secret, AUTH_ACCESS_TTL_SECONDS: 900,
    });
  });

  it('accepts environment overrides and converts PORT to a number', () => {
    expect(validateEnvironment({ ...credentials, AUTH_SECRET: secret, NODE_ENV: 'production', HOST: '0.0.0.0', PORT: '8080' }))
      .toEqual({ NODE_ENV: 'production', HOST: '0.0.0.0', PORT: 8080, AUTH_SECRET: secret, AUTH_ACCESS_TTL_SECONDS: 900, ...database });
  });

  it('parses ordered Gemini fallbacks and accepts an empty override', () => {
    const env = { ...credentials, AUTH_SECRET: secret };
    expect(validateEnvironment({
      ...env, GEMINI_FALLBACK_MODELS: ' gemini-a, gemini-b,gemini-a ',
    }).GEMINI_FALLBACK_MODELS).toEqual(['gemini-a', 'gemini-b']);
    expect(validateEnvironment({ ...env, GEMINI_FALLBACK_MODELS: '' }).GEMINI_FALLBACK_MODELS).toEqual([]);
    expect(() => validateEnvironment({
      ...env, GEMINI_FALLBACK_MODELS: 'gemini-a,gemini-b,gemini-c',
    })).toThrow('GEMINI_FALLBACK_MODELS');
  });

  it.each(['', 'abc', '3000.5', '0', '-1', '65536', '3e3'])('rejects invalid PORT=%j', (PORT) => {
    expect(() => validateEnvironment({ PORT })).toThrow('PORT must be an integer');
  });

  it.each([undefined, '', 'short', 'z'.repeat(64)])('rejects invalid auth secrets', AUTH_SECRET => {
    expect(() => validateEnvironment({ ...credentials, AUTH_SECRET })).toThrow('AUTH_SECRET must be');
  });

  it.each([0, 901, 1.1, 'bad'])('rejects invalid access token lifetime', AUTH_ACCESS_TTL_SECONDS => {
    expect(() => validateEnvironment({ ...credentials, AUTH_SECRET: secret, AUTH_ACCESS_TTL_SECONDS }))
      .toThrow('AUTH_ACCESS_TTL_SECONDS');
  });

  it('rejects an unsupported environment', () => {
    expect(() => validateEnvironment({ NODE_ENV: 'unknown' })).toThrow('NODE_ENV must be');
  });

  it('rejects an empty host', () => {
    expect(() => validateEnvironment({ HOST: ' ' })).toThrow('HOST must be');
  });

  it('accepts database overrides without trimming passwords', () => {
    expect(validateEnvironment({
      AUTH_SECRET: secret, DB_HOST: ' db.example ', DB_PORT: '5433', DB_NAME: 'other',
      DB_USER: ' app ', DB_PASSWORD: ' password ',
    })).toMatchObject({
      DB_HOST: 'db.example', DB_PORT: 5433, DB_NAME: 'other',
      DB_USER: 'app', DB_PASSWORD: ' password ',
    });
  });

  it.each(['', 'abc', '5432.5', '0', '-1', '65536', '5e3'])('rejects invalid DB_PORT=%j', (DB_PORT) => {
    expect(() => validateEnvironment({ ...credentials, DB_PORT })).toThrow('DB_PORT must be');
  });

  it.each(['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'])('rejects empty %s', (name) => {
    expect(() => validateEnvironment({ ...credentials, [name]: ' ' })).toThrow(`${name} must be`);
  });

  it.each(['DB_USER', 'DB_PASSWORD'])('requires %s without exposing credentials', (name) => {
    expect(() => validateEnvironment({ ...credentials, [name]: undefined })).toThrow(`${name} must be`);
  });
});
