import { URL } from 'node:url';
import { appendFileSync, readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { parseEnv } from 'node:util';

const file = new URL('../.env', import.meta.url);
if (!parseEnv(readFileSync(file, 'utf8')).AUTH_SECRET) {
  appendFileSync(file, `\nAUTH_SECRET=${randomBytes(32).toString('hex')}\n`);
}
