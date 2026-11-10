#!/usr/bin/env node
// A stand-in for Poki Setup's poki-setup-bridge that speaks the same JSON-lines protocol and plays
// one simulated iPhone. The installer's --dry-run and the tests use it; nothing here touches a device
// or Apple. POKI_FAKE_SCENARIO picks the story, POKI_FAKE_DELAY_MS how long a simulated person takes.
import { createInterface } from 'node:readline';
import { createECDH } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { KEM, keyId, open } from './model-key.mjs';

const scenario = process.env.POKI_FAKE_SCENARIO || 'happy';
// old-bridge (Poki Setup 0.2.1, no container commands) and old-poki (Poki 0.2.8, which writes no
// hello) combine with the others: POKI_FAKE_SCENARIO=old-bridge,old-poki.
const has = name => scenario.split(',').includes(name);
const delay = Number(process.env.POKI_FAKE_DELAY_MS ?? 300);
const udid = '00008999-000A11B22C33D44E';
const phoneName = 'Test iPhone';
let signedIn = scenario === 'signed-in';
let pending = null;
let phoneCalls = 0;
let signInCalls = 0;
let installCalls = 0;
let record = null;
// Poki's container on the simulated phone. POKI_FAKE_CONTAINER lets a test look inside it, and a fake
// devicectl reach the same files. old-bridge is Poki Setup 0.2.1, which has no container commands.
const container = process.env.POKI_FAKE_CONTAINER || mkdtempSync(join(tmpdir(), 'poki-fake-container-'));
if (!process.env.POKI_FAKE_CONTAINER) process.on('exit', () => rmSync(container, { recursive: true, force: true }));
const handoff = name => join(container, 'Documents/PokiSetup', name);
const writeFile = (path, text) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, text); };

const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const progress = data => send({ event: 'progress', data: { job: 'install', ...data } });
const fail = (kind, message) => { throw Object.assign(new Error(message), { kind }); };

const facts = () => ({ name: phoneName, ios: '27.1', product_type: 'iPhone17,1', developer_mode: record !== null, paired_with_this_computer: scenario === 'paired' || installCalls > 0, wifi_address: '192.168.1.44' });

async function install({ ipa } = {}) {
  if (process.env.POKI_FAKE_EXPECT_IPA && ipa !== process.env.POKI_FAKE_EXPECT_IPA) fail('bad_request', 'The requested local IPA was not passed to the signing flow.');
  installCalls += 1;
  if (!signedIn) fail('needs_person', 'Sign in with your Apple ID first.');
  progress({ kind: 'step', id: 'phone', title: 'Finding the iPhone' });
  progress({ kind: 'done', id: 'phone', detail: udid });
  progress({ kind: 'step', id: 'pair', title: 'Pairing with the iPhone' });
  progress({ kind: 'waiting', id: 'pair', text: 'On the iPhone: stay on the Home Screen, unlocked. If it asks, tap Trust and enter the passcode.' });
  if (scenario === 'trust-timeout' && installCalls === 1) {
    await sleep(delay);
    fail('needs_person', 'The iPhone did not answer the Trust dialog in time. Unlock it, plug it in again and tap Trust.');
  }
  await sleep(delay);
  progress({ kind: 'done', id: 'pair', detail: `${phoneName} · iOS 27.1` });
  progress({ kind: 'step', id: 'devmode', title: 'Developer Mode' });
  progress({ kind: 'waiting', id: 'devmode', text: 'Developer Mode is now available on your iPhone or iPad. Open Settings > Privacy & Security > Developer Mode, turn it on and tap Restart. After the restart, tap Turn On and enter your passcode. Poki Setup carries on by itself once it is on.' });
  await sleep(delay);
  progress({ kind: 'done', id: 'devmode', detail: 'on' });
  progress({ kind: 'step', id: 'account', title: 'Apple account' });
  progress({ kind: 'done', id: 'account', detail: 'Test Team (free, 7-day signing)' });
  progress({ kind: 'step', id: 'release', title: 'Getting Poki' });
  progress({ kind: 'done', id: 'release', detail: 'ios-alpha-latest' });
  progress({ kind: 'step', id: 'sign', title: 'Signing Poki for Test Team' });
  if (scenario === 'sign-fails') fail('sign', 'signing failed: the provisioning profile does not match the certificate');
  progress({ kind: 'done', id: 'sign', detail: 'Poki 0.2.8 (501) signed for Test Team' });
  progress({ kind: 'step', id: 'install', title: 'Installing' });
  progress({ kind: 'step', id: 'pairing_file', title: "Giving Poki its pairing file" });
  progress({ kind: 'done', id: 'pairing_file', detail: "placed in Poki's container" });
  record = { udid, phone_name: phoneName, ios: '27.1', apple_id: 'tester@example.com', team_id: 'TEAMID1234', team_name: 'Test Team', team_is_free: true, bundle_id: 'nz.zheha.poki.TEAMID1234', version: '0.2.8', build: '501', release_tag: 'ios-alpha-latest', signed_at: 0, profile_expires_at: Math.floor(Date.now() / 1000) + 7 * 86400, pairing_handed_off: true, wifi_address: '192.168.1.44' };
  progress({ kind: 'done', id: 'all', detail: `Poki 0.2.8 is on ${phoneName}` });
  setTimeout(simulatePoki, delay);
  return { record, notes: [], handoff: null };
}

// The person trusts the developer and opens Poki: Poki writes its hello with a key it made, takes a
// sealed model key it finds (into .keychain/, the test's view of its Keychain), and says so.
function simulatePoki() {
  writeFile(join(container, '.running'), record.bundle_id);
  if (has('old-poki')) return;
  const me = createECDH('prime256v1');
  me.generateKeys();
  const loopbackAt = Date.now() + (has('loopback-off') ? delay * 3 : 0);
  let imported = null;
  const hello = () => writeFile(handoff('poki-hello.json'), JSON.stringify({
    schema: 'poki.hello/1', version: '0.2.9', build: '510', at: new Date().toISOString(),
    model_key: { kem: KEM, public_key: me.getPublicKey().toString('base64url'), key_id: keyId(me.getPublicKey()) },
    ...(imported ? { imported } : {}),
    loopback: Date.now() >= loopbackAt ? { working: true } : { working: false, say: 'In Karing, open Settings > TUN, set Loopback address to 10.7.0.1, then reconnect Karing.' },
  }));
  hello();
  const timer = setInterval(() => {
    const sealed = handoff('model-key.json');
    if (existsSync(sealed)) {
      const { provider, secret } = open(readFileSync(sealed, 'utf8'), { privateKey: me.getPrivateKey(), bundleId: record.bundle_id });
      writeFile(join(container, '.keychain', provider), secret);
      rmSync(sealed);
      imported = { key_id: keyId(me.getPublicKey()), provider, at: new Date().toISOString() };
    }
    hello();
  }, 20);
  timer.unref();
}

const allowed = name => {
  if (!['poki-hello.json', 'model-key.json'].includes(name)) fail('bad_request', `not a Poki hand-off file: ${name}`);
  return handoff(name);
};
const containerCommands = has('old-bridge') ? {} : {
  container_read: ({ name }) => {
    const path = allowed(name);
    if (!existsSync(path)) fail('device', `${name}: kAFCObjectNotFound`);
    return readFileSync(path).toString('base64');
  },
  container_write: ({ name, data }) => { writeFile(allowed(name), Buffer.from(data, 'base64')); return true; },
};

const commands = {
  app_info: () => ({ version: '0.2.1-319', os: 'macos', arch: 'aarch64', data_dir: process.env.POKI_SETUP_HOME || '', simulated: true }),
  account: () => ({ signed_in: signedIn, apple_id: signedIn ? 'tester@example.com' : null, team_id: signedIn ? 'TEAMID1234' : null, password_kept: signedIn, pending_factor: pending }),
  sign_in: ({ apple_id, password }) => {
    if (!apple_id || !password) fail('bad_request', 'apple_id and password are required');
    if (password === 'wrong') fail('apple', 'Your Apple ID or password was incorrect. (-22406)');
    if (scenario === 'gsa-network' && ++signInCalls === 1) fail('http', 'network: error sending request for url (https://gsa.apple.com/grandslam/GsService2)');
    pending = 'trusted_device';
    return { needs_code: true, via: 'trusted_device' };
  },
  finish_sign_in: ({ code }) => {
    if (!pending) fail('message', 'Start the sign-in again.');
    if (code !== '123456') fail('apple', 'Incorrect verification code. (-21669)');
    pending = null;
    signedIn = true;
    return true;
  },
  teams: () => [{ team_id: 'TEAMID1234', name: 'Test Team', kind: 'Individual', is_free: true }],
  set_channel: ({ channel }) => [{ id: channel, title: channel, selected: true, latest: { tag: `ios-${channel}-latest`, version: '0.2.8', build: '501' } }],
  channels: () => [{ id: 'alpha', title: 'Alpha', selected: true, latest: { tag: 'ios-alpha-latest', version: '0.2.8', build: '501' } }],
  phones: () => {
    phoneCalls += 1;
    if (scenario === 'usbmuxd') fail('usbmuxd', 'Poki Setup cannot reach usbmuxd, which macOS starts when an iPhone is plugged in. Plug the iPhone in with a data cable and unlock it.');
    if (phoneCalls <= Number(process.env.POKI_FAKE_UNPLUGGED_CALLS ?? 2)) return [];
    return [{ phone: { udid, link: { kind: 'usb' } }, facts: facts(), error: null, record }];
  },
  install,
  records: () => (record ? [record] : []),
  mount_ddi: () => {
    if (scenario === 'ddi-refused') fail('device', "TSS server responded with non-success status (STATUS=94&MESSAGE=This device isn't eligible for the requested build.)");
    return true;
  },
  relay_token_saved: () => false,
  relay_state: () => null,
  ...containerCommands,
};

createInterface({ input: process.stdin }).on('line', async line => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  if (process.env.POKI_FAKE_REQUEST_LOG) appendFileSync(process.env.POKI_FAKE_REQUEST_LOG, `${line}\n`);
  const handler = commands[request.cmd];
  try {
    if (!handler) fail('bad_request', `unknown command ${request.cmd}`);
    send({ id: request.id, ok: await handler(request.args ?? {}) });
  } catch (error) {
    send({ id: request.id, err: { kind: error.kind || 'message', message: error.message } });
  }
});
process.stderr.write(`fake bridge for ${udid} (${phoneName}) started\n`);
send({ event: 'ready', data: { version: '0.2.1-319' } });
