import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { run, runCli } from '../backend/test/commands.mjs';
import { runDatabaseIntegration, unusedPort } from '../backend/test/run-database-integration.mjs';
import { startApi } from './validation_api.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
await runCli(async signal => {
  const device = process.argv[2];
  assert.match(device ?? '', /^emulator-\d+$/, 'Pass a disposable Android emulator serial');
  const command = (cmd, args, options) => run(cmd, args, { cwd: root, signal, timeout: 600_000, ...options });
  const adb = (args, options) => command('adb', ['-s', device, ...args], options);
  const pkg = 'com.example.ploggr';
  const packages = await adb(['shell', 'pm', 'list', 'packages', pkg], { capture: true });
  assert.ok(!packages.split(/\s+/).includes('package:' + pkg), 'Use an emulator without Ploggr installed');
  await command('flutter', ['pub', 'get', '--enforce-lockfile']);
  await command('make', ['check']);
  await runDatabaseIntegration(signal, async ({ env, compose }) => {
    const port = await unusedPort();
    const apiEnv = { ...env, PORT: port };
    const phase = name => command('python3', ['tool/test_android_plog.py', device, name], { timeout: 360_000 });
    await command('flutter', ['build', 'apk', '--debug', '-t', 'test_driver/plog_probe.dart',
      '--dart-define=API_BASE_URL=http://127.0.0.1:' + port + '/api/']);
    await adb(['reverse', '--no-rebind', 'tcp:' + port, 'tcp:' + port]);
    let api;
    let installed = false;
    try {
      await adb(['install', 'build/app/outputs/flutter-apk/app-debug.apk']);
      installed = true;
      api = startApi(apiEnv);
      await api.ready(signal);
      await phase('track');
      await api.stop();
      api = undefined;
      await phase('offline');
      api = startApi(apiEnv);
      await api.ready(signal);
      await phase('restore');
      await compose(['up', '-d', '--force-recreate', '--wait', '--wait-timeout', '90', 'storage']);
      await phase('retrieve');
    } finally {
      try { await api?.stop(); } finally {
        try { if (installed) await adb(['uninstall', pkg], { signal: undefined }); }
        finally { await adb(['reverse', '--remove', 'tcp:' + port], { signal: undefined }); }
      }
    }
  });
  console.log('Android Plog tracking, evidence and completion validation passed.');
});
