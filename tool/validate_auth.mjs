import { fileURLToPath } from 'node:url';
import { run, runCli } from '../backend/test/commands.mjs';
import { backend, runDatabaseIntegration, unusedPort } from '../backend/test/run-database-integration.mjs';
import { startApi } from './validation_api.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));

await runCli(async signal => {
  const device = process.argv[2];
  if (!/^emulator-\d+$/.test(device ?? '')) {
    throw new Error('Pass an empty running Android emulator, e.g. make validate-auth DEVICE=emulator-5554');
  }
  await run('adb', ['-s', device, 'wait-for-device'], { signal, timeout: 15_000 });
  await run('flutter', ['pub', 'get', '--enforce-lockfile'], { cwd: root, signal });
  await run('npm', ['ci', '--include=dev'], { cwd: backend, signal });
  await run('make', ['check'], { cwd: root, signal, timeout: 600_000 });

  await runDatabaseIntegration(signal, async ({ env }) => {
    // Check logout with a long-lived JWT, then use actual short-lived JWTs for expiry.
    for (const [suite, ttl] of [['forms', '900'], ['persistence', '12']]) {
      const port = await unusedPort();
      const api = startApi({ ...env, PORT: port, AUTH_ACCESS_TTL_SECONDS: ttl });
      try {
        await api.ready(signal);
        await run('tool/test_android_session.sh', [device, port, suite], { cwd: root, signal, timeout: 900_000 });
      } finally {
        await api.stop();
      }
    }
  });
  console.log('M2 authentication validation passed.');
});
