import { URL } from 'node:url';
import { appendFileSync, readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { parseEnv } from 'node:util';

const file = new URL('../.env', import.meta.url);
if (!parseEnv(readFileSync(file, 'utf8')).AUTH_SECRET) {
  appendFileSync(file, `\nAUTH_SECRET=${randomBytes(32).toString('hex')}\n`);
}

// Add a private local S3 store to both fresh and existing developer checkouts.
const current = parseEnv(readFileSync(file, 'utf8'));
if (!current.EVIDENCE_S3_BUCKET || current.EVIDENCE_S3_ENDPOINT?.startsWith('http://127.0.0.1:')) {
  const defaults = {
    EVIDENCE_S3_BUCKET: 'ploggr-evidence', EVIDENCE_S3_ENDPOINT: 'http://127.0.0.1:8333',
    EVIDENCE_S3_ACCESS_KEY: randomBytes(16).toString('hex'), EVIDENCE_S3_SECRET_KEY: randomBytes(32).toString('hex'),
  };
  for (const [key, value] of Object.entries(defaults)) {
    if (!current[key]) appendFileSync(file, `\n${key}=${value}\n`);
  }
}
