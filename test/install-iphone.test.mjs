import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { mkdtemp, mkdir, open, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { root } from '../src/config.mjs';
import { redactText } from '../src/install/redact.mjs';

const exec = promisify(execFile);
const cli = join(root, 'bin/install-iphone.mjs');
const fakeBridge = join(root, 'src/install/fake-bridge.mjs');
// The terminal path, unless a test turns the Poki Setup windows on with a fake osascript.
const fastEnv = { POKI_INSTALL_WAIT_MS: '20000', POKI_INSTALL_POLL_MS: '20', POKI_INSTALL_RETRY_MS: '20', POKI_FAKE_DELAY_MS: '30', POKI_INSTALL_DIALOGS: '0' };

async function stateDir(t) {
  const dir = await mkdtemp(join(tmpdir(), 'poki-install-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

// Runs the installer the way an agent does: reads its JSON lines and answers each person stop
// with the same subcommands the guide tells the agent to use.
function runInstaller(state, { scenario = 'happy', env = {}, answer = {}, stateArgs = ['--state', state], args = [] } = {}) {
  const child = spawn(process.execPath, [cli, 'run', '--json', '--bridge', fakeBridge, ...stateArgs, ...args], {
    env: { ...process.env, ...fastEnv, POKI_FAKE_SCENARIO: scenario, POKI_APPLE_ID: 'tester@example.com', POKI_SETUP_PASSWORD: 'correct horse', ...env },
  });
  const events = [];
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  createInterface({ input: child.stdout }).on('line', async line => {
    const event = JSON.parse(line);
    events.push(event);
    if (event.event === 'wait' && answer[event.wait]) await answer[event.wait](event);
  });
  return new Promise(resolve => child.on('close', code => resolve({ code, events, stderr })));
}

const sub = (state, ...args) => exec(process.execPath, [cli, ...args, '--state', state]);

// The person types the Apple code into their own Terminal: it reaches the command on stdin.
function typeCode(state, input, ...args) {
  const child = spawn(process.execPath, [cli, 'code', ...args, '--state', state], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', c => { output += c; });
  child.stderr.on('data', c => { output += c; });
  child.stdin.end(input);
  return new Promise(resolve => child.on('close', code => resolve({ code, output })));
}
const personAnswers = state => ({
  apple_code: () => typeCode(state, '123456\n'),
  open_poki: () => sub(state, 'done', 'open_poki'),
  open_poki_tell: () => sub(state, 'done', 'open_poki'),
});

test('a custom IPA reaches the standard signing flow and a changed build is not skipped', async t => {
  const state = await stateDir(t);
  const ipa = join(state, 'Poki-custom.ipa');
  await writeFile(ipa, 'synthetic first build');
  const options = { args: ['--ipa', ipa], env: { POKI_FAKE_EXPECT_IPA: ipa }, answer: { apple_code: () => typeCode(state, '123456\n') } };
  const first = await runInstaller(state, options);
  assert.equal(first.code, 0, first.stderr);
  assert.ok(first.events.some(e => e.event === 'done' && e.step === 'install'));
  const before = JSON.parse(await readFile(join(state, 'run.json'), 'utf8')).local_ipa_sha256;
  assert.match(before, /^[a-f0-9]{64}$/);
  await writeFile(ipa, 'synthetic second build');
  const second = await runInstaller(state, options);
  assert.equal(second.code, 0, second.stderr + JSON.stringify(second.events.at(-1)));
  assert.ok(second.events.some(e => e.event === 'done' && e.step === 'install'));
  assert.notEqual(JSON.parse(await readFile(join(state, 'run.json'), 'utf8')).local_ipa_sha256, before);
});

test('a missing custom IPA is rejected before signing or downloading another app', async t => {
  const state = await stateDir(t);
  const result = await runInstaller(state, { args: ['--ipa', join(state, 'missing.ipa')] });
  assert.equal(result.code, 1);
  assert.equal(result.events.length, 0);
  assert.match(result.stderr, /existing .ipa file/);
});

test('polling does not consume a response before its writer has finished', async t => {
  const state = await stateDir(t);
  const result = await runInstaller(state, { answer: { apple_code: async () => {
    const file = await open(join(state, 'inbox/apple-code'), 'w', 0o600);
    await new Promise(resolve => setTimeout(resolve, 150));
    await file.writeFile('123456');
    await file.close();
  } } });
  assert.equal(result.code, 0, result.stderr + JSON.stringify(result.events.at(-1)));
});

test('runs every step in order, stops at each person step with one sentence, and continues once it is done', async t => {
  const state = await stateDir(t);
  const { code, events, stderr } = await runInstaller(state, { answer: personAnswers(state) });
  assert.equal(code, 0, stderr);
  const stepOrder = events.filter(e => e.event === 'step').map(e => e.step);
  assert.deepEqual(stepOrder, ['setup_app', 'bridge', 'channel', 'apple_account', 'phone', 'install', 'open_poki', 'model_key', 'loopback', 'relay', 'check']);
  const waits = events.filter(e => e.event === 'wait').map(e => [e.wait, e.who]);
  assert.deepEqual(waits, [['apple_code', 'input'], ['phone_plug', 'phone'], ['pair', 'phone'], ['devmode', 'phone'], ['open_poki', 'phone']]);
  for (const wait of events.filter(e => e.event === 'wait')) assert.match(wait.say, /^[A-Z].{10,}[.:]$/s, `wait ${wait.wait} has a sentence for the person`);
  assert.ok(events.findIndex(e => e.event === 'wait' && e.wait === 'pair') < events.findIndex(e => e.event === 'done' && e.step === 'install'), 'install finishes after the Trust tap');
  const result = events.at(-1);
  assert.equal(result.event, 'result');
  assert.equal(result.ok, true);
  assert.deepEqual(result.check, { poki: '0.2.8 (501)', developer_mode: true, paired: true, ddi_mounted: true, days_left: 7, relay: 'skipped' });
  const saved = JSON.parse(await readFile(join(state, 'run.json'), 'utf8'));
  assert.equal(saved.steps.check.status, 'ok');
  assert.doesNotMatch(JSON.stringify(events) + stderr + JSON.stringify(saved), /correct horse/, 'the Apple Account password never reaches output or state');
});

test('a step that fails gives a machine-readable code, its reason and what to do, and retries only what can heal', async t => {
  for (const [scenario, expectCode, expectExit] of [
    ['trust-timeout', null, 0],
    ['sign-fails', 'sign_failed', 2],
    ['usbmuxd', 'usbmuxd_unreachable', 2],
  ]) await t.test(scenario, async t => {
    const state = await stateDir(t);
    const { code, events, stderr } = await runInstaller(state, { scenario, answer: personAnswers(state) });
    assert.equal(code, expectExit, stderr);
    const errors = events.filter(e => e.event === 'error');
    if (expectCode === null) {
      assert.equal(errors.length, 1, 'the missed Trust tap is reported once');
      assert.equal(errors[0].code, 'trust_not_answered');
      assert.equal(errors[0].retrying, true);
      assert.equal(events.at(-1).ok, true);
      return;
    }
    const last = errors.at(-1);
    assert.equal(last.code, expectCode);
    assert.equal(last.retrying, false);
    assert.ok(last.reason.length > 10 && last.agent_fix.length > 10, 'reason and fix are filled in');
    assert.equal(events.at(-1).event, 'result');
    assert.equal(events.at(-1).ok, false);
    assert.equal(events.at(-1).code, expectCode);
    const saved = JSON.parse(await readFile(join(state, 'run.json'), 'utf8'));
    assert.equal(Object.values(saved.steps).find(s => s.status === 'failed').code, expectCode);
  });
});

test('a DDI signing refusal gives Xcode recovery steps in the JSON failure result', async t => {
  const state = await stateDir(t);
  const bin = join(state, 'bin');
  await mkdir(bin);
  await writeFile(join(bin, 'xcodebuild'), '#!/bin/sh\necho "Xcode 26.6"\n', { mode: 0o755 });
  const { code, events, stderr } = await runInstaller(state, {
    scenario: 'ddi-refused', answer: personAnswers(state),
    env: { PATH: `${bin}:${process.env.PATH}` },
  });
  assert.equal(code, 2, stderr);
  const result = events.at(-1);
  assert.equal(result.ok, false);
  for (const pattern of [/Xcode 26\.6/, /iOS 27\.1/, /Update Xcode/, /iOS 27 requires Xcode 27/, /Open Xcode once/, /components/, /rerun the same command/, /Poki does not need to be reinstalled/]) assert.match(result.reason, pattern);
});

test('a person stop that nobody answers ends with exit 3 and a rerun resumes from that step', async t => {
  const state = await stateDir(t);
  const first = await runInstaller(state, { env: { POKI_INSTALL_WAIT_MS: '150' } });
  assert.equal(first.code, 3, first.stderr);
  const { at, ...last } = first.events.at(-1);
  assert.deepEqual(last, { event: 'result', ok: false, waiting: 'apple_code', step: 'apple_account', rerun: 'node bin/install-iphone.mjs run' });
  const saved = JSON.parse(await readFile(join(state, 'run.json'), 'utf8'));
  assert.deepEqual(saved.steps.apple_account, { ...saved.steps.apple_account, status: 'waiting', wait: 'apple_code' });
  const second = await runInstaller(state, { answer: personAnswers(state) });
  assert.equal(second.code, 0, second.stderr);
  assert.equal(second.events.find(e => e.event === 'wait').wait, 'apple_code', 'the rerun picks up at the open sign-in');
});

const secrets = {
  udid: '00008999-000A11B22C33D44E',
  oldUdid: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
  serial: '000081500002349C2188401C',
  name: "Jamie's iPhone",
  anthropic: ['sk', 'ant', 'api03', 'FAKEFAKEFAKEFAKEFAKEFAKEFAKE0123456789'].join('-'),
  cloudflare: 'Zx9fakeCloudflareToken0123456789abcdefGHIJ',
  relay: 'https://poki-relay.jamie-fake.workers.dev',
  relayLink: 'poki://setup?relay=https%3A%2F%2Fpoki-relay.jamie-fake.workers.dev&secret=s3cr3tvalue',
  email: 'jamie.fake@example.com',
  wifi: '192.168.1.44',
  pairing: '<key>HostPrivateKey</key>\n<data>\nLS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFBS0NBUUVB\n</data>',
};

async function seedFailedRun(state) {
  await mkdir(join(state, 'setup-home/logs'), { recursive: true });
  await writeFile(join(state, 'run.json'), JSON.stringify({
    started_at: '2026-11-08T22:00:00Z', channel: 'alpha', poki_setup: '0.2.1-319',
    steps: {
      setup_app: { status: 'ok', detail: 'Poki Setup 0.2.1-319' },
      phone: { status: 'ok', detail: `${secrets.udid} ${secrets.name}` },
      install: { status: 'failed', code: 'trust_not_answered', reason: `Pairing ${secrets.udid} (${secrets.name}) timed out`, agent_fix: 'Ask the person to tap Trust and run again.' },
    },
    phones: [{ udid: secrets.udid, name: secrets.name, ios: '27.1', link: 'usb', wifi_address: secrets.wifi }],
  }));
  await writeFile(join(state, 'setup-home/logs/poki-setup.log'), [
    `INFO pairing ${secrets.udid} name="${secrets.name}" serial ${secrets.serial}`,
    `INFO old style udid ${secrets.oldUdid}`,
    `DEBUG anthropic key ${secrets.anthropic}`,
    `DEBUG Authorization: Bearer ${secrets.cloudflare}`,
    `INFO cloudflare token=${secrets.cloudflare}`,
    `INFO relay ${secrets.relay}/v1/frames link ${secrets.relayLink}`,
    `INFO signed in as ${secrets.email} from ${secrets.wifi}`,
    secrets.pairing,
    // Built from parts so secret scanners do not take the fixture for a real key.
    [`-----BEGIN ${'PRIVATE'} KEY-----`, 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7', `-----END ${'PRIVATE'} KEY-----`].join('\n'),
    'INFO install step failed: The iPhone did not answer the Trust dialog in time.',
  ].join('\n'));
}

test('the diagnostics bundle and the issue draft keep the failure but drop identifiers, tokens, keys, pairing records and relay addresses', async t => {
  const state = await stateDir(t);
  await seedFailedRun(state);
  const { stdout: bundle } = await sub(state, 'diagnose', '--no-device');
  const { stdout: issue } = await sub(state, 'issue');
  for (const [label, output] of [['diagnose', bundle], ['issue', issue]]) {
    for (const [kind, value] of Object.entries(secrets)) {
      for (const piece of value.split('\n').filter(p => p.length > 12 && !p.startsWith('<'))) assert.ok(!output.includes(piece), `${label} leaks the ${kind}`);
    }
    assert.doesNotMatch(output, /s3cr3tvalue|jamie/i, `${label} leaks a relay secret or the owner's name`);
    assert.match(output, /trust_not_answered/, `${label} keeps the failing code`);
    assert.match(output, /did not answer the Trust dialog in time/, `${label} keeps the last log lines`);
  }
  const parsed = JSON.parse(bundle);
  assert.equal(parsed.steps.install.code, 'trust_not_answered');
  assert.equal(parsed.phones[0].ios, '27.1');
  assert.ok(parsed.system.macos, 'the bundle names the macOS version');
});

test('the issue draft is only printed: it never runs gh, and it says the person must approve it first', async t => {
  const state = await stateDir(t);
  await seedFailedRun(state);
  const bin = join(state, 'fake-bin');
  await mkdir(bin);
  await writeFile(join(bin, 'gh'), `#!/bin/sh\necho "$@" >> ${JSON.stringify(join(state, 'gh-called'))}\n`);
  await chmod(join(bin, 'gh'), 0o755);
  const { stdout } = await exec(process.execPath, [cli, 'issue', '--state', state], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
  await assert.rejects(readFile(join(state, 'gh-called')), { code: 'ENOENT' }, 'gh was not run');
  assert.match(stdout, /Show this draft to the person and submit it only after they say yes/);
  assert.match(stdout, /gh issue create --repo JosssphZhou\/poki --template install-failure.yml|gh issue create --repo JosssphZhou\/poki --title/);
  const draft = await readFile(join(state, 'issue-draft.md'), 'utf8');
  const template = await readFile(join(root, '.github/ISSUE_TEMPLATE/install-failure.yml'), 'utf8');
  const labels = [...template.matchAll(/^\s+label: (.+)$/gm)].map(m => m[1]);
  assert.deepEqual([...draft.matchAll(/^### (.+)$/gm)].map(m => m[1]), labels, 'the draft follows the install-failure template field by field');
  assert.match(draft, /### Step it stopped at\n\nPair \(Trust This Computer\)\n/, 'the step is one of the template options');
});

test('the agent guide documents every error code the installer can print', async () => {
  const { errors } = JSON.parse(await readFile(join(root, 'src/install/steps.json'), 'utf8'));
  const guide = await readFile(join(root, 'skills/install-poki/SKILL.md'), 'utf8');
  for (const code of Object.keys(errors)) assert.ok(guide.includes(`\`${code}\``), `skills/install-poki/SKILL.md explains ${code}`);
});

// A Poki Setup.app laid out as the installer puts it, whose helper is the fake bridge.
async function fakeSetupApp(dir) {
  const helper = join(dir, 'Poki Setup.app/Contents/MacOS/poki-setup-bridge');
  await mkdir(join(dir, 'Poki Setup.app/Contents/MacOS'), { recursive: true });
  await writeFile(helper, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(fakeBridge)}\n`);
  await chmod(helper, 0o755);
  return helper;
}

async function fakeHome(t) {
  const home = await mkdtemp(join(tmpdir(), 'poki-install-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  await fakeSetupApp(join(home, 'Applications'));
  return home;
}

test('phones and diagnose find the Poki Setup that run installs into ~/Applications, and a missing one is an error code, not a stack', async t => {
  const state = await stateDir(t);
  const home = await fakeHome(t);
  const empty = await mkdtemp(join(tmpdir(), 'poki-install-nopath-'));
  t.after(() => rm(empty, { recursive: true, force: true }));
  const env = { ...process.env, HOME: home, PATH: empty, POKI_FAKE_UNPLUGGED_CALLS: '0' };
  const { stdout: phones } = await exec(process.execPath, [cli, 'phones', '--state', state], { env });
  assert.match(phones, /00008999-000A11B22C33D44E/, 'phones lists the phone through ~/Applications/Poki Setup.app');
  const { stdout: bundle } = await exec(process.execPath, [cli, 'diagnose', '--state', state], { env });
  const devices = JSON.parse(bundle).devices;
  assert.equal(devices.usbmuxd_error, undefined);
  assert.equal(devices.usbmuxd.length, 1, 'the bundle holds what usbmuxd sees');

  const missing = await exec(process.execPath, [cli, 'phones', '--bridge', join(home, 'nowhere/poki-setup-bridge'), '--state', state], { env }).catch(error => error);
  assert.equal(missing.code, 2);
  assert.match(missing.stderr, /setup_app_missing/);
  assert.doesNotMatch(missing.stderr, /\n\s+at /, 'no stack trace');
});

test('phones and diagnose use the helper the last run started, wherever it was', async t => {
  const state = await stateDir(t);
  const home = await mkdtemp(join(tmpdir(), 'poki-install-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const elsewhere = await mkdtemp(join(tmpdir(), 'poki-install-app-'));
  t.after(() => rm(elsewhere, { recursive: true, force: true }));
  const helper = await fakeSetupApp(elsewhere);
  await writeFile(join(state, 'run.json'), JSON.stringify({ steps: {}, setup_bridge: helper }));
  const { stdout } = await exec(process.execPath, [cli, 'phones', '--state', state], { env: { ...process.env, HOME: home, POKI_FAKE_UNPLUGGED_CALLS: '0' } });
  assert.match(stdout, /00008999-000A11B22C33D44E/);
});

test('findSetupBridge names setup_app_missing and lists where it looked', async () => {
  const { findSetupBridge } = await import('../src/install/setup-app.mjs');
  assert.throws(() => findSetupBridge({ roots: ['/nonexistent-a', '/nonexistent-b'] }), error => error.code === 'setup_app_missing' && /nonexistent-a/.test(error.message) && /--app-dir/.test(error.message));
});

test('the Apple code never goes on a command line: it is typed to stdin, and a code in the arguments is refused', async t => {
  const state = await stateDir(t);
  const refused = await typeCode(state, '', '123456');
  assert.equal(refused.code, 1);
  assert.doesNotMatch(refused.output, /123456/, 'the refusal does not echo the code');
  await assert.rejects(readFile(join(state, 'inbox/apple-code')), { code: 'ENOENT' }, 'nothing was handed over');
  const bad = await typeCode(state, '12ab\n');
  assert.equal(bad.code, 1);
  const ok = await typeCode(state, '654321\n');
  assert.equal(ok.code, 0);
  assert.equal((await readFile(join(state, 'inbox/apple-code'), 'utf8')).trim(), '654321');
  const manifest = await readFile(join(root, 'src/install/steps.json'), 'utf8');
  assert.doesNotMatch(manifest, /code 123456|Tell me the code/, 'the person stop does not ask for the code in chat or in arguments');
  const guide = await readFile(join(root, 'skills/install-poki/SKILL.md'), 'utf8');
  assert.doesNotMatch(guide, /code <digits>|pass through chat/);
});

// The person opens a fresh Terminal (it starts in their home folder, not in the checkout) and pastes
// the command exactly as the installer printed it.
function pasteIntoNewTerminal(say, { cwd, env = {} }) {
  const command = say.match(/run: (.+?) \(it asks/s)?.[1];
  assert.ok(command, `the prompt carries a command: ${say}`);
  const child = spawn('/bin/sh', ['-c', command], { cwd, env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdin.end('123456\n');
  return new Promise(resolve => child.on('close', code => resolve(code)));
}

test('the Apple code command in the prompt works pasted into a new Terminal outside the checkout, and reaches the install that is waiting, with or without --state', async t => {
  const home = await stateDir(t);
  const elsewhere = await stateDir(t);
  // A non-default --state, with a space in the path: the command has to carry it, quoted.
  const state = join(await stateDir(t), 'agent state');
  await mkdir(state);
  const withState = await runInstaller(state, { answer: { ...personAnswers(state), apple_code: async event => assert.equal(await pasteIntoNewTerminal(event.say, { cwd: elsewhere, env: { HOME: home } }), 0) } });
  assert.equal(withState.code, 0, withState.stderr);
  // The default state: no --state was given, so the command needs none, and finds the same folder from HOME.
  const defaultState = join(home, 'Library/Application Support/PokiInstall');
  const withDefault = await runInstaller(defaultState, { stateArgs: [], env: { HOME: home }, answer: { ...personAnswers(defaultState), apple_code: async event => {
    assert.doesNotMatch(event.say, /--state/);
    assert.equal(await pasteIntoNewTerminal(event.say, { cwd: elsewhere, env: { HOME: home } }), 0);
  } } });
  assert.equal(withDefault.code, 0, withDefault.stderr);
});

test('the installer shows its own version and build, and diagnose and the issue draft carry the versions of the installer, Poki Setup and the installed Poki', async t => {
  const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  const noGit = await mkdtemp(join(tmpdir(), 'poki-install-nogit-'));
  t.after(() => rm(noGit, { recursive: true, force: true }));
  const { stdout: version } = await exec(process.execPath, [cli, '--version'], { env: { ...process.env, PATH: noGit, POKI_BUILD_COMMIT: 'abc1234' } });
  assert.equal(version.trim(), `Poki installer ${pkg.version} (abc1234)`, 'without git the recorded build commit is shown');
  const { stdout: withGit } = await exec(process.execPath, [cli, '--version']);
  assert.match(withGit.trim(), new RegExp(`^Poki installer ${pkg.version.replaceAll('.', '\\.')} \\([0-9a-f]{7,}\\)$`));

  const state = await stateDir(t);
  const { code, events, stderr } = await runInstaller(state, { env: { POKI_BUILD_COMMIT: 'abc1234', PATH: `${noGit}:${dirname(process.execPath)}` }, answer: personAnswers(state) });
  assert.equal(code, 0, stderr);
  const { at, ...first } = events[0];
  assert.deepEqual(first, { event: 'installer', version: pkg.version, commit: 'abc1234' }, 'run starts by saying which installer it is');

  const env = { ...process.env, PATH: noGit, POKI_BUILD_COMMIT: 'abc1234' };
  const bundle = JSON.parse((await exec(process.execPath, [cli, 'diagnose', '--no-device', '--state', state], { env })).stdout);
  assert.deepEqual(bundle.installer, { version: pkg.version, commit: 'abc1234' });
  assert.equal(bundle.poki_setup, '0.2.1 (319)');
  assert.equal(bundle.poki, '0.2.8 (501)');
  const draft = (await exec(process.execPath, [cli, 'issue', '--state', state], { env })).stdout;
  assert.match(draft, new RegExp(`Poki Setup 0\\.2\\.1 \\(319\\)`));
  assert.match(draft, /Poki 0\.2\.8 \(501\)/);
  assert.match(draft, new RegExp(`installer ${pkg.version.replaceAll('.', '\\.')} \\(abc1234\\)`));
});

test('the bundle and the draft drop the Apple Account holder, the Mac name and phone names in other languages', async t => {
  const state = await stateDir(t);
  await seedFailedRun(state);
  const bin = await mkdtemp(join(tmpdir(), 'poki-install-fakebin-'));
  t.after(() => rm(bin, { recursive: true, force: true }));
  for (const [tool, answer] of [['scutil', "Quinn Fakeperson's MacBook Pro"], ['id', 'Quinn Fakeperson']]) {
    await writeFile(join(bin, tool), `#!/bin/sh\necho ${JSON.stringify(answer)}\n`);
    await chmod(join(bin, tool), 0o755);
  }
  const log = join(state, 'setup-home/logs/poki-setup.log');
  // Lines in the shape of Poki Setup's own log (desktop/core setup.rs, progress.rs, identity.rs).
  await writeFile(log, [
    ...(await readFile(log, 'utf8')).split('\n'),
    'INFO Signing Poki for Remy Testperson',
    'INFO Remy Testperson (free, 7-day signing)',
    'INFO signed for Remy Testperson',
    'INFO development certificates machine=Quinn Fakeperson\'s MacBook Pro',
    'INFO host Quinn Fakeperson MacBook Pro ready',
    'INFO done pair: iPhone von Anna Beispiel · iOS 27.1',
    'INFO done pair: 李雷的iPhone · iOS 27.1',
    'INFO done pair: Studio Phone · iOS 26.0',
    'INFO Poki 0.2.8 is on Hanako Nameless',
    'INFO install step failed: The iPhone did not answer the Trust dialog in time.',
  ].join('\n'));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}` };
  const bundle = (await exec(process.execPath, [cli, 'diagnose', '--no-device', '--state', state], { env })).stdout;
  const issue = (await exec(process.execPath, [cli, 'issue', '--state', state], { env })).stdout;
  for (const [label, output] of [['diagnose', bundle], ['issue', issue]]) {
    assert.doesNotMatch(output, /Remy|Testperson|Quinn|Fakeperson|Anna|Beispiel|李雷|Studio Phone|Hanako|Nameless/, `${label} leaks a team, Mac or phone name`);
    assert.match(output, /did not answer the Trust dialog in time/, `${label} keeps the failure`);
    assert.match(output, /free, 7-day signing/, `${label} keeps the kind of team`);
  }
});

// macOS's osascript and security, faked: osascript answers each Poki Setup window the way a person would
// and logs what it was shown; security plays a login keychain with or without the installer's item.
async function fakeMac(t, { cancel = false, keychain = null } = {}) {
  const bin = await mkdtemp(join(tmpdir(), 'poki-install-mac-'));
  t.after(() => rm(bin, { recursive: true, force: true }));
  const log = join(bin, 'osascript.log');
  await writeFile(join(bin, 'osascript'), `#!${process.execPath}
const { appendFileSync } = require('node:fs');
let script = '';
process.stdin.on('data', c => { script += c; }).on('end', () => {
  appendFileSync(${JSON.stringify(log)}, JSON.stringify({ argv: process.argv.slice(2), script }) + '\\n');
  if (${cancel}) { process.stderr.write('execution error: User canceled. (-128)\\n'); process.exit(1); }
  if (/verification code/.test(script)) process.stdout.write('123456\\n');
  else if (/hidden answer/.test(script)) process.stdout.write('correct horse\\n');
  else process.stdout.write('tester@example.com\\n');
});
`);
  const found = keychain ? `if [ "$1" = find-generic-password ]; then case "$*" in *-w*) echo ${JSON.stringify(keychain.password)};; *) echo '    "acct"<blob>="${keychain.account}"';; esac; exit 0; fi` : '';
  await writeFile(join(bin, 'security'), `#!/bin/sh\necho "$*" >> ${JSON.stringify(join(bin, 'security.log'))}\n${found}\n[ "$1" = delete-generic-password ] && exit 0\nexit 44\n`);
  for (const tool of ['osascript', 'security']) await chmod(join(bin, tool), 0o755);
  const shown = async () => (await readFile(log, 'utf8').catch(() => '')).split('\n').filter(Boolean).map(line => JSON.parse(line));
  return { env: { PATH: `${bin}:${process.env.PATH}`, POKI_INSTALL_DIALOGS: '1', POKI_APPLE_ID: '', POKI_SETUP_PASSWORD: '' }, shown };
}

test('with nothing to reuse, Poki Setup windows ask for the Apple Account and the code, so the person never opens Terminal', async t => {
  const state = await stateDir(t);
  const mac = await fakeMac(t);
  const { code, events, stderr } = await runInstaller(state, { env: mac.env, answer: { open_poki: () => sub(state, 'done', 'open_poki') } });
  assert.equal(code, 0, stderr);
  const waits = events.filter(e => e.event === 'wait');
  assert.deepEqual(waits.map(e => [e.wait, e.who]), [['apple_dialog', 'input'], ['apple_code_dialog', 'input'], ['phone_plug', 'phone'], ['pair', 'phone'], ['devmode', 'phone'], ['open_poki', 'phone']]);
  for (const wait of waits.slice(0, 2)) assert.doesNotMatch(wait.say, /Terminal|security |install-iphone/, `${wait.wait} sends the person to a window, not to Terminal`);
  const shown = await mac.shown();
  assert.equal(shown.length, 3, 'one window each for the email, the password and the code');
  for (const { argv, script } of shown) {
    assert.deepEqual(argv, [], 'the window text goes to osascript on stdin, not on its command line');
    assert.match(script, /with title "Poki Setup"/);
  }
  assert.doesNotMatch(shown[0].script, /hidden answer/, 'the email is shown as typed');
  assert.match(shown[1].script, /hidden answer/, 'the password is hidden');
  assert.match(shown[1].script, /Apple Account/);
  assert.match(shown[2].script, /hidden answer/, 'the code is hidden');
  assert.match(shown[2].script, /verification code/);
  const saved = await readFile(join(state, 'run.json'), 'utf8');
  assert.doesNotMatch(JSON.stringify(events) + stderr + saved, /correct horse|123456/, 'neither the password nor the code reaches output or state');
  assert.match(JSON.parse(saved).steps.apple_account.detail, /signed in with the password from the Poki Setup window/);
});

test('closing the Poki Setup window stops with apple_credentials_missing instead of signing in', async t => {
  const state = await stateDir(t);
  const mac = await fakeMac(t, { cancel: true });
  const { code, events, stderr } = await runInstaller(state, { env: mac.env });
  assert.equal(code, 2, stderr);
  assert.equal(events.at(-1).code, 'apple_credentials_missing');
  assert.equal((await mac.shown()).length, 1, 'the window is shown once, not again and again');
});

test('a sign-in Poki Setup already keeps, or a password already in the keychain, is reused without any window', async t => {
  for (const [label, scenario, keychain] of [
    ['Poki Setup is signed in', 'signed-in', null],
    ['the keychain item is there', 'happy', { account: 'tester@example.com', password: 'correct horse' }],
  ]) await t.test(label, async t => {
    const state = await stateDir(t);
    const mac = await fakeMac(t, { keychain });
    const { code, events, stderr } = await runInstaller(state, { scenario, env: mac.env, answer: { open_poki: () => sub(state, 'done', 'open_poki'), apple_code_dialog: () => {} } });
    assert.equal(code, 0, stderr);
    const shown = await mac.shown();
    assert.ok(!shown.some(s => /Apple Account password/.test(s.script)), 'no window asks for the password');
    assert.ok(!events.some(e => e.wait === 'apple_dialog' || e.wait === 'apple_password'), 'no person stop for the Apple Account');
    if (scenario === 'signed-in') assert.equal(shown.length, 0, 'a kept sign-in needs no window at all');
  });
});

test('a network error while signing in is retried with what the person already typed, without asking again', async t => {
  const state = await stateDir(t);
  const mac = await fakeMac(t);
  const { code, events, stderr } = await runInstaller(state, { scenario: 'gsa-network', env: mac.env, answer: { open_poki: () => sub(state, 'done', 'open_poki') } });
  assert.equal(code, 0, stderr);
  const errors = events.filter(e => e.event === 'error');
  assert.deepEqual(errors.map(e => [e.code, e.retrying]), [['network', true]]);
  assert.equal((await mac.shown()).length, 3, 'email, password and code are asked once each');
  assert.doesNotMatch(JSON.stringify(events) + stderr + await readFile(join(state, 'run.json'), 'utf8'), /correct horse/);
});

test('diagnose reads Poki Setup\'s own log where Poki Setup keeps it on macOS', async t => {
  const home = await fakeHome(t);
  const state = await stateDir(t);
  // directories::ProjectDirs::from("nz", "Poki", "Poki Setup") on macOS (desktop/core/src/paths.rs).
  const logs = join(home, 'Library/Application Support/nz.Poki.Poki-Setup/logs');
  await mkdir(logs, { recursive: true });
  await writeFile(join(logs, 'poki-setup.log'), 'INFO install step failed: iOS refused the install.\n');
  const env = { ...process.env, HOME: home, POKI_FAKE_UNPLUGGED_CALLS: '0' };
  const bundle = JSON.parse((await exec(process.execPath, [cli, 'diagnose', '--no-device', '--state', state], { env })).stdout);
  assert.ok(bundle.poki_setup_log?.some(line => line.includes('iOS refused the install')), 'the bundle carries Poki Setup\'s log');
});

test('diagnose drops the Apple team id and certificate ids from Poki Setup\'s log', async t => {
  const home = await fakeHome(t);
  const state = await stateDir(t);
  const setupHome = join(home, 'Library/Application Support/nz.Poki.Poki-Setup');
  await mkdir(join(setupHome, 'logs'), { recursive: true });
  await mkdir(join(setupHome, 'state'), { recursive: true });
  // The two lines as Poki Setup writes them while signing and installing, with made-up values.
  await writeFile(join(setupHome, 'logs/poki-setup.log'), [
    '2026-11-09T03:45:38.992476Z  INFO poki_setup_core::apple::portal: certificate request accepted certificate_id=QWERTY7788 cert_request_id=ZXCVB65432 serial=6F1A2B3C4D5E6F7A8B9C0D1E2F3A4B',
    `2026-11-09T03:45:46.325548Z  INFO poki_setup_core::device::install: uploading and installing the app upgrade=false bytes=22817612 ipa=${setupHome}/cache/Poki-ABCDE12345-00008140-001A2B3C4D5E6F70.ipa`,
    '',
  ].join('\n'));
  await writeFile(join(setupHome, 'state/phones.json'), JSON.stringify([{ udid: '00008140-001A2B3C4D5E6F70', team_id: 'ABCDE12345', team_is_free: true }]));
  const env = { ...process.env, HOME: home, POKI_FAKE_UNPLUGGED_CALLS: '0' };
  const { stdout } = await exec(process.execPath, [cli, 'diagnose', '--no-device', '--state', state], { env });
  assert.ok(JSON.parse(stdout).poki_setup_log?.some(line => line.includes('uploading and installing the app')), 'the install line is still there');
  assert.doesNotMatch(stdout, /ABCDE12345/, 'the team id from phones.json is removed');
  assert.doesNotMatch(stdout, /QWERTY7788|ZXCVB65432/, 'the certificate ids are removed');
  // A team that phones.json no longer names, such as an earlier Apple Account's, goes by the file name.
  const line = redactText('ipa=/tmp/cache/Poki-KLMNO67890-00008140-001A2B3C4D5E6F70.ipa');
  assert.doesNotMatch(line, /KLMNO67890/, 'the team id in the ipa file name is removed');
  assert.match(line, /Poki-.+\.ipa/, 'the file name keeps its shape');
});

test('a phone that is already paired is not a person stop: the Trust reminder becomes a note', async t => {
  const state = await stateDir(t);
  const { code, events, stderr } = await runInstaller(state, { scenario: 'paired', answer: personAnswers(state) });
  assert.equal(code, 0, stderr);
  assert.ok(!events.some(e => e.event === 'wait' && e.wait === 'pair'), 'no pair stop for a paired phone');
  assert.ok(events.some(e => e.event === 'note' && /tap Trust/.test(e.text)), 'the reminder is still there as a note');
});

// The phone's side of the hand-off: Poki's container as the simulated Poki in fake-bridge.mjs keeps
// it, a login keychain with one model key, and devicectl when a test gives the Mac Xcode.
const modelKey = ['sk', 'proj', 'FAKEmodelKEY0123456789abcdefFAKEmodelKEY'].join('-');
async function fakePhoneAndMac(t, { devicectl = false, keychainItem = 'openai-api-key' } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'poki-install-handoff-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const container = join(dir, 'container');
  const bin = join(dir, 'bin');
  await mkdir(bin, { recursive: true });
  const found = keychainItem ? `if [ "$1" = find-generic-password ] && [ "$3" = ${JSON.stringify(keychainItem)} ]; then echo ${JSON.stringify(modelKey)}; exit 0; fi` : '';
  await writeFile(join(bin, 'security'), `#!/bin/sh\necho "$*" >> ${JSON.stringify(join(dir, 'security.log'))}\n${found}\nexit 44\n`);
  // devicectl's copy from/to for appDataContainer, mapped onto the simulated container.
  await writeFile(join(bin, 'xcrun'), `#!${process.execPath}
const { appendFileSync, copyFileSync, existsSync, mkdirSync } = require('node:fs');
const { dirname, join } = require('node:path');
const a = process.argv.slice(2);
appendFileSync(${JSON.stringify(join(dir, 'xcrun.log'))}, JSON.stringify(a) + '\\n');
if (!${devicectl}) process.exit(72);
if (a[0] === '--find') { console.log('/Applications/Xcode.app/devicectl'); process.exit(0); }
const arg = n => a[a.indexOf(n) + 1];
const inside = p => join(${JSON.stringify(container)}, p);
if (a.slice(0, 4).join(' ') === 'devicectl device copy from') {
  if (!existsSync(inside(arg('--source')))) { console.error('ERROR: The file doesn’t exist.'); process.exit(1); }
  copyFileSync(inside(arg('--source')), arg('--destination'));
} else if (a.slice(0, 4).join(' ') === 'devicectl device copy to') {
  mkdirSync(dirname(inside(arg('--destination'))), { recursive: true });
  copyFileSync(arg('--source'), inside(arg('--destination')));
} else if (a.slice(0, 3).join(' ') === 'devicectl device info') {
  const app = 'file:///private/var/containers/Bundle/Application/0F1E2D3C/Poki.app';
  const running = existsSync(join(${JSON.stringify(container)}, '.running'));
  const result = a[3] === 'apps' ? { apps: [{ bundleIdentifier: arg('--bundle-id'), url: app + '/' }] } : { runningProcesses: running ? [{ executable: app + '/Poki' }] : [] };
  require('node:fs').writeFileSync(arg('--json-output'), JSON.stringify({ result }));
} else process.exit(64);
`);
  for (const tool of ['security', 'xcrun']) await chmod(join(bin, tool), 0o755);
  const read = name => readFile(join(dir, name), 'utf8').catch(() => '');
  return {
    container,
    env: { PATH: `${bin}:${process.env.PATH}`, POKI_FAKE_CONTAINER: container, POKI_FAKE_REQUEST_LOG: join(dir, 'requests.log') },
    phoneKeychain: provider => readFile(join(container, '.keychain', provider), 'utf8').catch(() => null),
    securityLog: () => read('security.log'),
    xcrunLog: () => read('xcrun.log'),
    requests: () => read('requests.log'),
  };
}

test('Poki says by itself that it is open, so the install goes on with nobody running done open_poki', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t);
  const { code, events, stderr } = await runInstaller(state, { env: mac.env, answer: { apple_code: () => typeCode(state, '123456\n') } });
  assert.equal(code, 0, stderr);
  const open = events.find(e => e.event === 'wait' && e.wait === 'open_poki');
  assert.ok(open, 'the person is still asked to trust the developer and open Poki');
  assert.doesNotMatch(open.say, /Tell me/, 'nobody has to say Poki is open');
  assert.match(events.find(e => e.event === 'done' && e.step === 'open_poki').detail, /Poki .* is open/);
  for (const event of events) assert.ok(!Number.isNaN(Date.parse(event.at)), `${event.event} carries the time it happened`);
});

test('with --model-key, the key goes from the Mac keychain into Poki sealed, Poki takes it, and it never appears in output, state, logs, diagnostics or a command line', async t => {
  for (const devicectl of [false, true]) await t.test(devicectl ? 'Poki Setup 0.2.1 and Xcode: through devicectl' : 'through Poki Setup', async t => {
    const state = await stateDir(t);
    const mac = await fakePhoneAndMac(t, { devicectl });
    const { code, events, stderr } = await runInstaller(state, { scenario: devicectl ? 'old-bridge' : 'happy', env: mac.env, args: ['--model-key', 'openai'], answer: { apple_code: () => typeCode(state, '123456\n') } });
    assert.equal(code, 0, stderr);
    assert.equal(await mac.phoneKeychain('openai'), modelKey, 'Poki on the phone has the key');
    assert.match(events.find(e => e.event === 'done' && e.step === 'model_key').detail, /openai/);
    assert.ok(!events.some(e => e.wait === 'open_poki_tell'), 'Poki said it was open by itself');
    if (devicectl) assert.match(await mac.xcrunLog(), /copy","to/, 'devicectl carried the sealed file');
    else assert.match(await mac.requests(), /container_write/, 'Poki Setup carried the sealed file');
    const { stdout: bundle } = await sub(state, 'diagnose', '--no-device');
    const { stdout: issue } = await sub(state, 'issue');
    const seen = [JSON.stringify(events), stderr, await readFile(join(state, 'run.json'), 'utf8'), await readFile(join(state, 'bridge.log'), 'utf8').catch(() => ''),
      await mac.requests(), await mac.securityLog(), await mac.xcrunLog(), bundle, issue].join('\n');
    assert.ok(!seen.includes(modelKey), 'the key is in no output, state file, log, bundle, draft or command line');
    assert.ok(!seen.includes(modelKey.slice(8, 30)), 'not even part of it');
  });
});

test('without --model-key the installer never reads a model key from the keychain', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t);
  const { code, events, stderr } = await runInstaller(state, { env: mac.env, answer: { apple_code: () => typeCode(state, '123456\n') } });
  assert.equal(code, 0, stderr);
  assert.doesNotMatch(await mac.securityLog(), /api-key/, 'the keychain is not asked for a model key');
  assert.equal(await mac.phoneKeychain('openai'), null);
  assert.match(events.find(e => e.event === 'skipped' && e.step === 'model_key').reason, /--model-key/);
});

test('a missing keychain item stops with model_key_missing and names the item, not a key', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t, { keychainItem: null });
  const { code, events, stderr } = await runInstaller(state, { env: mac.env, args: ['--model-key', 'openai'], answer: { apple_code: () => typeCode(state, '123456\n') } });
  assert.equal(code, 2, stderr);
  assert.equal(events.at(-1).code, 'model_key_missing');
  assert.match(events.at(-1).reason, /openai-api-key/);
});

test('with no way into Poki\'s files (Poki Setup 0.2.1, no Xcode), the install falls back to asking the person', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t, { devicectl: false });
  const { code, events, stderr } = await runInstaller(state, { scenario: 'old-bridge', env: mac.env, args: ['--model-key', 'openai'], answer: personAnswers(state) });
  assert.equal(code, 3, stderr);
  assert.equal(events.at(-1).ok, false);
  assert.deepEqual(events.at(-1).unverified.map(s => s.step), ['model_key', 'loopback']);
  assert.ok(events.some(e => e.event === 'note' && /Accounts and Models/.test(e.text)));
  assert.ok(events.some(e => e.event === 'wait' && e.wait === 'open_poki_tell' && /Tell me/.test(e.say)), 'the agent confirms Poki is open with done');
  assert.match(events.find(e => e.event === 'skipped' && e.step === 'model_key').reason, /Accounts and Models/);
  assert.match(events.find(e => e.event === 'skipped' && e.step === 'loopback').reason, /10\.7\.0\.1/);
  assert.doesNotMatch(await mac.securityLog(), /api-key/, 'with nowhere to put it, the key is not read');
});

test('when Poki\'s local connection does not answer, the installer says Poki\'s own sentence for the VPN app and goes on once it answers', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t);
  const { code, events, stderr } = await runInstaller(state, { scenario: 'loopback-off', env: mac.env, answer: { apple_code: () => typeCode(state, '123456\n') } });
  assert.equal(code, 0, stderr);
  const wait = events.find(e => e.event === 'wait' && e.wait === 'loopback');
  assert.match(wait.say, /Karing/, 'the sentence names the VPN app Poki found on the phone');
  assert.ok(events.findIndex(e => e === wait) < events.findIndex(e => e.event === 'done' && e.step === 'loopback'));
});

test('the install-poki skill walks the same steps and person stops as the installer, in order', async () => {
  const manifest = JSON.parse(await readFile(join(root, 'src/install/steps.json'), 'utf8'));
  const skill = await readFile(join(root, 'skills/install-poki/SKILL.md'), 'utf8');
  assert.match(skill, /^---\nname: install-poki\ndescription: .+\n/, 'the skill has a name and a description');
  const listed = [...skill.matchAll(/^\d+\. \*\*`(\w+)`\*\*/gm)].map(m => m[1]);
  assert.deepEqual(listed, manifest.steps.map(s => s.id), 'one numbered line per installer step, in the installer\'s order');
  for (const wait of Object.keys(manifest.waits)) assert.ok(skill.includes(`\`${wait}\``), `the skill says what to do at ${wait}`);
  assert.match(skill, /node bin\/install-iphone\.mjs run/, 'the skill runs the installer instead of repeating it');
});

test('expired signing is renewed on rerun and an expired final record is rejected', async t => {
  for (const staysExpired of [false, true]) await t.test(String(staysExpired), async t => {
    const state = await stateDir(t);
    const bridge = join(state, 'expired.mjs');
    const expired = { udid: '00008999-000A11B22C33D44E', bundle_id: 'nz.zheha.poki.TEAMID1234', version: '0.2.8', build: '501', profile_expires_at: 1 };
    await writeFile(bridge, `
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
const child = spawn(process.execPath, [${JSON.stringify(fakeBridge)}], { stdio: ['pipe', 'pipe', 'inherit'] });
const commands = new Map();
let installed = false;
createInterface({ input: process.stdin }).on('line', line => {
  const req = JSON.parse(line); commands.set(req.id, req.cmd);
  if (req.cmd === 'install') installed = true;
  child.stdin.write(line + '\\n');
}).on('close', () => child.stdin.end());
createInterface({ input: child.stdout }).on('line', line => {
  const res = JSON.parse(line);
  if (commands.get(res.id) === 'records' && (!installed || ${staysExpired})) res.ok = [${JSON.stringify(expired)}];
  process.stdout.write(JSON.stringify(res) + '\\n');
});
`);
    await writeFile(join(state, 'run.json'), JSON.stringify({ channel: 'alpha', dry_run: false, steps: { install: { status: 'ok' }, open_poki: { status: 'ok' } } }));
    const result = await runInstaller(state, { args: ['--bridge', bridge], answer: personAnswers(state) });
    assert.ok(result.events.some(e => e.event === 'done' && e.step === 'install'), 'expired signing is installed again');
    assert.equal(result.code, staysExpired ? 2 : 0, result.stderr);
    assert.equal(result.events.at(-1).ok, !staysExpired);
    if (staysExpired) assert.equal(result.events.at(-1).code, 'check_failed');
  });
});

test('a Poki too old to write its hello still counts as open once devicectl sees it running', async t => {
  const state = await stateDir(t);
  const mac = await fakePhoneAndMac(t, { devicectl: true });
  const { code, events, stderr } = await runInstaller(state, { scenario: 'old-bridge,old-poki', env: mac.env, args: ['--model-key', 'openai'], answer: { apple_code: () => typeCode(state, '123456\n') } });
  assert.equal(code, 3, stderr);
  assert.equal(events.at(-1).ok, false);
  assert.deepEqual(events.at(-1).unverified.map(s => s.step), ['model_key', 'loopback']);
  assert.match(events.find(e => e.event === 'done' && e.step === 'open_poki').detail, /running/);
  assert.match(events.find(e => e.event === 'skipped' && e.step === 'model_key').reason, /Accounts and Models/);
  assert.match(events.find(e => e.event === 'skipped' && e.step === 'loopback').reason, /10\.7\.0\.1/);
  assert.doesNotMatch(await mac.securityLog(), /api-key/, 'a Poki that cannot take the key does not make the installer read it');
});
