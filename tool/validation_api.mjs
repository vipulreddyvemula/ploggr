import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { backend } from '../backend/test/run-database-integration.mjs';

export async function waitUntil(check, description, signal, timeout) {
  const deadline = Date.now() + timeout;
  do {
    signal.throwIfAborted();
    if (await check()) return;
    await delay(100, undefined, { signal });
  } while (Date.now() < deadline);
  throw new Error(`Timed out waiting for ${description}`);
}

export function startApi(env) {
  const child = spawn(process.execPath, ['dist/main.js'], {
    cwd: backend, env, stdio: ['ignore', 'pipe', 'inherit'],
  });
  const closed = once(child, 'close');
  let listening = false;
  child.stdout.setEncoding('utf8').on('data', chunk => {
    process.stdout.write(chunk);
    if (chunk.includes('API listening at')) listening = true;
  });
  return {
    async ready(signal) {
      await waitUntil(() => {
        if (child.exitCode !== null || child.signalCode) throw new Error('Nest exited during startup');
        return listening;
      }, 'Nest startup', signal, 30_000);
    },
    async stop() {
      child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      try { await closed; } finally { clearTimeout(timer); }
    },
  };
}
