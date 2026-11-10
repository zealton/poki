// The install as an ordered list of steps (steps.json) that an agent, or Poki Setup's own agent,
// runs end to end. Agent steps run by themselves; at a person step the installer says one sentence
// and polls until it sees the step done. Every failure carries a code from steps.json.
import { execFile, spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Bridge, BridgeError } from './bridge.mjs';
import { ensureSetupApp, downloadIpa, SetupError } from './setup-app.mjs';
import { containerAccess, readHello, SEALED_KEY } from './container.mjs';
import { phoneKey, readKeychainKey, seal } from './model-key.mjs';
import { installerLabel, installerVersion } from './version.mjs';
import { signingRefused, ddiRecovery } from '../ddi-failure.mjs';

const exec = promisify(execFile);
export const manifest = JSON.parse(readFileSync(new URL('./steps.json', import.meta.url), 'utf8'));
const fakeBridgePath = fileURLToPath(new URL('./fake-bridge.mjs', import.meta.url));
export const defaultStateDir = () => join(homedir(), 'Library/Application Support/PokiInstall');
const cliPath = fileURLToPath(new URL('../../bin/install-iphone.mjs', import.meta.url));
const shellQuote = text => (/^[\w@%+=:,./-]+$/.test(text) ? text : `'${text.replaceAll("'", "'\\''")}'`);
// What the person pastes into a new Terminal (which starts in their home folder, not in the checkout):
// the installer's absolute path, and --state when this run does not use the default folder.
export function codeCommand(state) {
  const stateArg = resolve(state) === defaultStateDir() ? '' : ` --state ${shellQuote(resolve(state))}`;
  return `${shellQuote(process.execPath)} ${shellQuote(cliPath)} code${stateArg}`;
}

// Publish a complete person response at once; polling must never consume an empty/truncated code.
export async function writeInbox(directory, name, value) {
  const pending = join(directory, `${name}.${randomUUID()}.pending`);
  try {
    await writeFile(pending, value, { mode: 0o600 });
    await rename(pending, join(directory, name));
  } finally { await rm(pending, { force: true }); }
}
const KEYCHAIN_SERVICE = 'poki-setup-install';
const pollMs = () => Number(process.env.POKI_INSTALL_POLL_MS ?? 2000);
const retryMs = () => Number(process.env.POKI_INSTALL_RETRY_MS ?? 3000);
const waitMs = () => Number(process.env.POKI_INSTALL_WAIT_MS ?? 15 * 60 * 1000);
// Poki reads a sealed key while it is in front, every 2 s.
const keyWaitMs = () => Number(process.env.POKI_INSTALL_KEY_WAIT_MS ?? 2 * 60 * 1000);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// Poki Setup windows (osascript dialogs) ask for the Apple Account and the code, so the person never
// opens Terminal. POKI_INSTALL_DIALOGS=0, or a Mac with no screen to show them on, falls back to Terminal.
const dialogsOn = () => process.platform === 'darwin' && process.env.POKI_INSTALL_DIALOGS !== '0';
const appleText = text => `"${text.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
const GAVE_UP = '\u0000gave up';

class DialogUnavailable extends Error {}

// One native window titled Poki Setup. Its text goes to osascript on stdin, never on a command line.
// Returns what the person typed, null for Cancel; throws WaitTimedOut when nobody answers.
function dialog({ message, answer = '', hidden = false, wait }) {
  const seconds = Math.max(1, Math.round(waitMs() / 1000));
  const script = [
    `set r to display dialog ${appleText(message)} with title "Poki Setup" default answer ${appleText(answer)}${hidden ? ' with hidden answer' : ''} buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with icon note giving up after ${seconds}`,
    `if gave up of r then return ${appleText(GAVE_UP)}`,
    'return text returned of r',
  ].join('\n');
  return new Promise((resolve, reject) => {
    const child = spawn('osascript', [], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    child.stdout.on('data', chunk => { out += chunk; });
    child.stderr.on('data', chunk => { err += chunk; });
    child.on('error', error => reject(new DialogUnavailable(error.message)));
    child.on('close', code => {
      const text = out.replace(/\n$/, '');
      if (code === 0) return text === GAVE_UP ? reject(new WaitTimedOut(wait)) : resolve(text);
      if (/-128/.test(err)) return resolve(null);
      reject(new DialogUnavailable(err.trim() || `osascript exited ${code}`));
    });
    child.stdin.end(script);
  });
}

class StepFailure extends Error {
  constructor(code, reason) {
    super(reason);
    this.code = code in manifest.errors ? code : 'unknown';
    this.reason = reason;
  }
}
class WaitTimedOut extends Error {
  constructor(wait) {
    super(`Nobody finished ${wait}`);
    this.wait = wait;
  }
}

// Bridge and setup errors to the codes in steps.json.
function classify(step, error) {
  if (error instanceof StepFailure) return error;
  if (error instanceof SetupError) return new StepFailure(error.code, error.message);
  const kind = error.kind ?? '';
  const text = error.message ?? String(error);
  const code = (() => {
    if (signingRefused(text)) return 'ddi_refused';
    if (kind === 'bridge_start_failed') return 'bridge_start_failed';
    if (kind === 'usbmuxd' || /usbmuxd/i.test(text)) return 'usbmuxd_unreachable';
    if (/more than one iPhone/i.test(text)) return 'several_phones';
    if (/Trust|remote pairing in time/i.test(text) && kind !== 'apple') return 'trust_not_answered';
    if (/Developer Mode/i.test(text)) return 'developer_mode_off';
    if (/unlock/i.test(text) && kind !== 'apple') return 'phone_locked';
    if (kind === 'apple' || step === 'apple_account') {
      if (/App ID|maximum|too many|certificate/i.test(text)) return 'apple_account_limit';
      if (/-8004[56]|\b5\d\d\b|unavailable|busy/i.test(text)) return 'apple_server_busy';
      if (/verification code|-21669|code/i.test(text)) return 'apple_code_wrong';
      if (/password|-22406|incorrect/i.test(text)) return 'apple_sign_in_rejected';
    }
    if (kind === 'sign') return 'sign_failed';
    if (step === 'relay') return 'relay_failed';
    if (kind === 'http' || /network|timed out|connection/i.test(text)) return 'network';
    if (step === 'install' && kind === 'device') return 'install_failed';
    return 'unknown';
  })();
  return new StepFailure(code, text);
}

function format(event) {
  switch (event.event) {
    case 'installer': return `Poki installer ${installerLabel(event)}`;
    case 'step': return `\n[${event.n}/${event.of}] ${event.title}  (${event.who})`;
    case 'progress': return `      · ${event.title}${event.detail ? `: ${event.detail}` : ''}`;
    case 'note': return `      ${event.text}`;
    case 'wait': return `  ⏸ PERSON (${event.who}) ${event.wait}: ${event.say}`;
    case 'done': return `  ✓ ${event.detail ?? 'done'}`;
    case 'skipped': return `  – skipped: ${event.reason}`;
    case 'error': return `  ✗ ${event.code}: ${event.reason}\n    fix: ${event.agent_fix}${event.retrying ? '\n    retrying' : ''}`;
    case 'result': return `\nRESULT ${JSON.stringify(event)}`;
    default: return JSON.stringify(event);
  }
}

class Run {
  constructor(opts) {
    this.opts = opts;
    this.state = opts.state;
    this.inbox = join(opts.state, 'inbox');
    this.unverified = [];
    this.record = { started_at: new Date().toISOString(), channel: opts.channel, dry_run: !!opts.dryRun, setup_home: opts.setupHome ?? null, steps: {} };
  }

  emit(event) {
    const stamped = { ...event, at: new Date().toISOString() };
    process.stdout.write(`${this.opts.json ? JSON.stringify(stamped) : format(stamped)}\n`);
  }

  async save() { await writeFile(join(this.state, 'run.json'), `${JSON.stringify(this.record, null, 2)}\n`); }

  async load() {
    try {
      const previous = JSON.parse(await readFile(join(this.state, 'run.json'), 'utf8'));
      if (previous.channel === this.opts.channel && previous.dry_run === !!this.opts.dryRun) this.previous = previous;
    } catch {}
  }

  doneBefore(step) { return this.previous?.steps?.[step]?.status === 'ok'; }

  async mark(step, status, extra = {}) {
    this.record.steps[step] = { status, at: new Date().toISOString(), ...extra };
    await this.save();
  }

  // One person stop: say it once, then poll `check` until it returns a value.
  async waitFor(wait, check, vars = {}, say) {
    const spec = manifest.waits[wait];
    const sentence = (say ?? spec.say).replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? k);
    this.emit({ event: 'wait', wait, who: spec.who, say: sentence });
    this.record.waiting = wait;
    await this.save();
    if (this.opts.dryRun) this.simulatePerson(wait);
    const deadline = Date.now() + waitMs();
    for (;;) {
      const value = await check();
      if (value) {
        delete this.record.waiting;
        return value;
      }
      if (Date.now() > deadline) throw new WaitTimedOut(wait);
      await sleep(pollMs());
    }
  }

  // Dry run: the simulated person answers the installer's own stops after a moment.
  simulatePerson(wait) {
    const files = { apple_code: ['apple-code', '123456'], open_poki: ['open_poki', 'done'], open_poki_tell: ['open_poki', 'done'] };
    if (!files[wait]) return;
    setTimeout(() => {
      this.emit({ event: 'note', text: `[dry run] the simulated person finished ${wait}` });
      writeInbox(this.inbox, files[wait][0], files[wait][1]).catch(() => {});
    }, Number(process.env.POKI_FAKE_DELAY_MS ?? 1500));
  }

  async takeInbox(name) {
    const file = join(this.inbox, name);
    if (!existsSync(file)) return null;
    const value = (await readFile(file, 'utf8')).trim();
    if (!value) return null;
    await rm(file, { force: true });
    return value || null;
  }

  async startBridge(path, label, { remember = true } = {}) {
    const env = this.opts.setupHome ? { POKI_SETUP_HOME: this.opts.setupHome } : {};
    const { bridge, version } = await Bridge.start(path, { env, logFile: join(this.state, 'bridge.log') });
    this.bridge?.close();
    this.bridge = bridge;
    this.record.poki_setup = version;
    // phones and diagnose read this, so they start the same helper this run did.
    if (remember) this.record.setup_bridge = path;
    return `${label} ${version}`;
  }

  async credentials() {
    if (this.opts.dryRun) return { appleId: 'tester@example.com', password: 'simulated', from: 'dry run' };
    const appleId = process.env.POKI_APPLE_ID;
    const password = process.env.POKI_SETUP_PASSWORD;
    if (appleId && password) return { appleId, password, from: 'environment' };
    try {
      const { stdout: attributes } = await exec('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE]);
      const account = /"acct"<blob>="([^"]*)"/.exec(attributes)?.[1];
      const { stdout: secret } = await exec('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-w']);
      if (account && secret.trim()) return { appleId: account, password: secret.replace(/\n$/, ''), from: 'keychain' };
    } catch {}
    return null;
  }

  async setup_app() {
    if (this.opts.bridge) return { skipped: `using the bridge at ${this.opts.bridge}` };
    const app = await ensureSetupApp({
      channel: this.opts.channel,
      into: this.opts.appDir ?? (this.opts.dryRun ? join(this.state, 'app') : undefined),
      downloads: join(this.state, 'downloads'),
      onNote: text => this.emit({ event: 'note', text }),
    });
    this.app = app;
    return `Poki Setup ${app.version} (${app.build}) at ${app.app}`;
  }

  async bridge_step() {
    if (this.opts.bridge) return this.startBridge(this.opts.bridge, 'Poki Setup bridge');
    const detail = await this.startBridge(this.app.bridge, 'Poki Setup bridge');
    if (!this.opts.dryRun) return detail;
    const channels = await this.bridge.request('channels');
    const offered = channels.map(c => `${c.id}: ${c.latest ? `Poki ${c.latest.version} (${c.latest.build})` : 'nothing'}`).join(', ');
    this.emit({ event: 'note', text: `The real bridge answers: ${offered}` });
    await this.startBridge(fakeBridgePath, '[dry run] simulated iPhone and Apple Account behind bridge', { remember: false });
    return `${detail}; from here on the iPhone and Apple Account are simulated`;
  }

  async channel() {
    const rows = await this.bridge.request('set_channel', { channel: this.opts.channel });
    const chosen = rows.find(r => r.selected) ?? rows[0];
    this.releaseTag = chosen?.latest?.tag;
    this.releaseIpaName = chosen?.latest?.ipa_name;
    return `${this.opts.channel}: Poki ${chosen?.latest?.version ?? '?'} (${chosen?.latest?.build ?? '?'})`;
  }

  async apple_account() {
    const account = await this.bridge.request('account');
    if (account.signed_in) {
      await this.rememberTeams();
      return `already signed in (team ${account.team_id ? 'chosen' : 'to choose'})`;
    }
    const attempts = { code: 0, password: 0, busy: 0, network: 0 };
    // Kept across retries that are not about the password, so the person types it once.
    let creds = null;
    for (;;) {
      creds ??= await this.credentials() ?? await this.askCredentials(account.apple_id, attempts.password > 0) ?? await this.waitFor('apple_password', () => this.credentials());
      try {
        const started = await this.bridge.request('sign_in', { apple_id: creds.appleId, password: creds.password, keep_password: true });
        if (started.needs_code) {
          const via = started.via === 'sms' ? 'a text message' : 'your Apple devices';
          for (;;) {
            const code = await this.askCode(via, attempts.code > 0) ?? await this.waitFor('apple_code', () => this.takeInbox('apple-code'), { via, codeCommand: codeCommand(this.state) });
            try {
              await this.bridge.request('finish_sign_in', { code });
              break;
            } catch (error) {
              const failure = classify('apple_account', error);
              if (failure.code !== 'apple_code_wrong' || ++attempts.code > manifest.errors.apple_code_wrong.retry) throw failure;
              this.reportError(failure, true);
            }
          }
        }
        if (creds.from === 'keychain') await exec('security', ['delete-generic-password', '-s', KEYCHAIN_SERVICE]).catch(() => {});
        const teams = await this.rememberTeams();
        const team = teams.find(t => !t.is_free) ?? teams[0];
        return `signed in with the password from the ${creds.from}; team ${team ? (team.is_free ? 'free (7-day signing)' : 'paid') : 'none'}`;
      } catch (error) {
        if (error instanceof WaitTimedOut) throw error;
        const failure = classify('apple_account', error);
        if (failure.code === 'apple_sign_in_rejected' && creds.from !== 'environment' && ++attempts.password <= manifest.errors.apple_sign_in_rejected.retry) {
          this.reportError(failure, true);
          if (creds.from === 'keychain') await exec('security', ['delete-generic-password', '-s', KEYCHAIN_SERVICE]).catch(() => {});
          creds = null;
          continue;
        }
        if (failure.code === 'network' && ++attempts.network <= manifest.errors.network.retry) {
          this.reportError(failure, true);
          await sleep(retryMs() * attempts.network);
          continue;
        }
        if (failure.code === 'apple_server_busy' && ++attempts.busy <= manifest.errors.apple_server_busy.retry) {
          this.reportError(failure, true);
          const info = await this.bridge.request('app_info');
          const next = info.anisette_servers?.[attempts.busy % (info.anisette_servers?.length || 1)];
          if (next) await this.bridge.request('set_anisette', { source: { kind: 'remote', url: next } });
          await sleep(retryMs());
          continue;
        }
        throw failure;
      }
    }
  }

  // Nothing to reuse: Poki Setup windows ask for the email and the password. Poki Setup keeps the
  // password in its own keychain item after sign-in, for renewals. Null when the windows cannot show.
  async askCredentials(lastAppleId, again) {
    if (this.opts.dryRun || !dialogsOn() || this.noDialogs) return null;
    this.emit({ event: 'wait', wait: 'apple_dialog', who: 'input', say: manifest.waits.apple_dialog.say });
    this.record.waiting = 'apple_dialog';
    await this.save();
    try {
      const why = 'Poki Setup signs Poki with your Apple Account so it can run on your iPhone.';
      const email = await dialog({ wait: 'apple_dialog', message: `${again ? 'Apple did not accept that email or password. ' : ''}${why}\n\nApple Account email:`, answer: lastAppleId ?? process.env.POKI_APPLE_ID ?? '' });
      if (email === null || !email.trim()) throw new StepFailure('apple_credentials_missing', 'The person closed the Poki Setup window without an Apple Account.');
      const password = await dialog({ wait: 'apple_dialog', message: `${why} Poki Setup keeps the password in this Mac's keychain to renew the signing; it is not shown or sent anywhere else.\n\nApple Account password for ${email.trim()}:`, hidden: true });
      if (password === null || !password) throw new StepFailure('apple_credentials_missing', 'The person closed the Poki Setup window without the password.');
      delete this.record.waiting;
      return { appleId: email.trim(), password, from: 'Poki Setup window' };
    } catch (error) {
      if (!(error instanceof DialogUnavailable)) throw error;
      this.noDialogs = true;
      this.emit({ event: 'note', text: `Poki Setup windows cannot show here (${error.message}); asking in Terminal instead.` });
      return null;
    }
  }

  async askCode(via, again) {
    if (this.opts.dryRun || !dialogsOn() || this.noDialogs) return null;
    this.emit({ event: 'wait', wait: 'apple_code_dialog', who: 'input', say: manifest.waits.apple_code_dialog.say.replace('{via}', via) });
    this.record.waiting = 'apple_code_dialog';
    await this.save();
    try {
      for (;;) {
        const code = await dialog({ wait: 'apple_code_dialog', message: `${again ? 'Apple did not accept that code. ' : ''}Apple sent a 6-digit verification code to ${via}.\n\nVerification code:`, hidden: true });
        if (code === null) throw new StepFailure('apple_credentials_missing', 'The person closed the Poki Setup window without the verification code.');
        if (/^\d{6}$/.test(code.trim())) {
          delete this.record.waiting;
          return code.trim();
        }
        again = true;
      }
    } catch (error) {
      if (!(error instanceof DialogUnavailable)) throw error;
      this.noDialogs = true;
      this.emit({ event: 'note', text: `Poki Setup windows cannot show here (${error.message}); asking in Terminal instead.` });
      return null;
    }
  }

  // A free Apple Account's team is named after its holder. run.json keeps the names only so diagnose
  // can take them out of Poki Setup's log; the diagnostics bundle never prints them.
  async rememberTeams() {
    const teams = await this.bridge.request('teams').catch(() => []);
    this.record.teams = teams.map(t => ({ team_id: t.team_id, name: t.name }));
    await this.save();
    return teams;
  }

  async listPhones() {
    const rows = await this.bridge.request('phones');
    return this.opts.udid ? rows.filter(r => r.phone.udid === this.opts.udid) : rows;
  }

  async phone() {
    let rows = await this.listPhones();
    if (!rows.length) rows = await this.waitFor('phone_plug', async () => { const r = await this.listPhones(); return r.length ? r : null; });
    const usb = rows.filter(r => r.phone.link?.kind === 'usb');
    if (!this.opts.udid && usb.length > 1) throw new StepFailure('several_phones', `${usb.length} iPhones are plugged in`);
    const row = usb[0] ?? rows[0];
    this.udid = row.phone.udid;
    this.paired = row.facts?.paired_with_this_computer === true;
    this.record.phones = rows.map(r => ({ udid: r.phone.udid, name: r.facts?.name, product_type: r.facts?.product_type, ios: r.facts?.ios, build: r.facts?.build, link: r.phone.link?.kind, developer_mode: r.facts?.developer_mode, paired: r.facts?.paired_with_this_computer, error: r.error }));
    return `${row.facts?.product_type ?? 'iPhone'} on iOS ${row.facts?.ios ?? '?'} over ${row.phone.link?.kind ?? '?'}`;
  }

  async install() {
    const sameSource = this.opts.ipa
      ? this.previous?.local_ipa_sha256 === this.record.local_ipa_sha256
      : !this.previous?.local_ipa_sha256;
    if (this.doneBefore('install') && !this.opts.reinstall && sameSource) {
      const records = await this.bridge.request('records');
      const installed = records.find(r => r.udid === this.udid);
      if (installed && installed.profile_expires_at > Date.now() / 1000) {
        this.bundleId = installed.bundle_id;
        return { skipped: 'Poki is already installed from this computer (pass --reinstall to sign and install again)' };
      }
    }
    const retries = {};
    let localIpa = this.opts.ipa;
    for (;;) {
      try {
        const onProgress = data => {
          if (data.job !== 'install') return;
          if (data.kind === 'waiting') {
            // Poki Setup reminds about Trust on every install; a phone paired with this Mac needs no one.
            if (data.id === 'pair' && this.paired) return this.emit({ event: 'note', text: data.text || manifest.waits.pair.say });
            const wait = manifest.waits[data.id] ? data.id : 'pair';
            this.emit({ event: 'wait', wait, who: manifest.waits[wait].who, say: data.text || manifest.waits[wait].say });
          } else if (data.kind === 'step') this.emit({ event: 'progress', id: data.id, title: data.title });
          else if (data.kind === 'note') this.emit({ event: 'note', text: data.text });
          else if (data.kind === 'done' && !['all', 'phone'].includes(data.id)) this.emit({ event: 'progress', id: data.id, title: `${data.id} done`, detail: data.detail });
        };
        const done = await this.bridge.request('install', { udid: this.udid, seed_ddi: true, ...(localIpa ? { ipa: localIpa } : {}) }, { onProgress });
        for (const note of done.notes ?? []) this.emit({ event: 'note', text: note });
        if (done.handoff?.link) this.emit({ event: 'wait', wait: 'pairing_file', who: 'phone', say: `${manifest.waits.pairing_file.say} Or open ${done.handoff.link} on the iPhone.` });
        this.installed = done.record;
        this.bundleId = done.record.bundle_id;
        this.record.poki = `${done.record.version} (${done.record.build})`;
        return `Poki ${done.record.version} (${done.record.build}) installed, signed for ${Math.round((done.record.profile_expires_at - Date.now() / 1000) / 86400)} days`;
      } catch (error) {
        const failure = classify('install', error);
        if (!localIpa && error.kind === 'http' && this.releaseTag) {
          this.emit({ event: 'note', text: 'Poki Setup could not download the release. Downloading and verifying a local IPA with its matching signing archive.' });
          localIpa = await downloadIpa(this.releaseTag, join(this.state, 'downloads'), this.releaseIpaName);
          continue;
        }
        const limit = manifest.errors[failure.code].retry;
        retries[failure.code] = (retries[failure.code] ?? 0) + 1;
        if (!['trust_not_answered', 'developer_mode_off', 'phone_locked', 'install_failed', 'network'].includes(failure.code) || retries[failure.code] > limit) throw failure;
        this.reportError(failure, true);
        await sleep(retryMs());
      }
    }
  }

  // Poki's hand-off files, through Poki Setup's helper or devicectl; null when neither can reach them.
  async access() {
    if (this.containerTried) return this.container;
    this.containerTried = true;
    try {
      this.container = await containerAccess({ bridge: this.bridge, udid: this.udid, bundleId: this.bundleId });
    } catch (error) {
      this.emit({ event: 'note', text: `Poki's files are not reachable from this Mac: ${error.message}` });
      this.container = null;
    }
    if (this.container) this.record.handoff = this.container.kind;
    return this.container;
  }

  // Poki writes Documents/PokiSetup/poki-hello.json each time it starts, so a new one is Poki open.
  async open_poki() {
    if (this.doneBefore('open_poki') && !this.opts.reinstall && !this.installed) return { skipped: 'Poki was opened on an earlier run' };
    const access = await this.access();
    if (!access) {
      await this.waitFor('open_poki_tell', () => this.takeInbox('open_poki'));
      return 'the person said Poki is open';
    }
    const before = (await readHello(access))?.at;
    const seen = await this.waitFor('open_poki', async () => {
      const hello = await readHello(access);
      if (hello && hello.at !== before) return hello;
      if (await access.running?.()) return { running: true };
      return (await this.takeInbox('open_poki')) ? { told: true } : null;
    });
    if (seen.told) return 'the person said Poki is open';
    if (seen.running) return 'Poki is running on the iPhone (a version that does not write its hello yet)';
    this.hello = seen;
    return `Poki ${seen.version} (${seen.build}) is open on the iPhone`;
  }

  // Only with --model-key: the key leaves the keychain into this process, is sealed to the key Poki
  // made on the phone, and only the sealed file goes to the phone. Poki's hello says when it took it.
  async model_key() {
    const provider = this.opts.modelKey;
    if (!provider) return { skipped: 'not asked to give Poki a model key (pass --model-key openai to carry the Mac keychain item openai-api-key)' };
    const typeIt = `ask the person to type the key in Poki: Agents > Accounts and Models`;
    const access = await this.access();
    if (!access) return { manual: true, skipped: `this Mac cannot reach Poki's files (this Poki Setup has no container commands and Xcode's devicectl is not installed); ${typeIt}` };
    const phone = phoneKey((await readHello(access)) ?? this.hello);
    if (!phone) return { manual: true, skipped: `this Poki takes no key from the Mac yet; ${typeIt}` };
    const item = this.opts.modelKeyItem ?? `${provider}-api-key`;
    let secret = await readKeychainKey(item);
    if (!secret) throw new StepFailure('model_key_missing', `the login keychain has no key in the item ${item}`);
    const sealed = seal({ secret, provider, bundleId: this.bundleId, phone });
    secret = null;
    await access.write(SEALED_KEY, sealed);
    const deadline = Date.now() + keyWaitMs();
    for (;;) {
      const hello = await readHello(access);
      if (hello?.imported?.key_id === phone.keyId) break;
      if (Date.now() > deadline) throw new StepFailure('model_key_not_taken', `Poki did not take the sealed ${provider} key in ${Math.round(keyWaitMs() / 1000)} s`);
      await sleep(pollMs());
    }
    return `the ${provider} key from the keychain item ${item} is in Poki on the iPhone, sealed to a key only that phone holds`;
  }

  async loopback() {
    const tell = manifest.waits.loopback.say.replace(/ I see by myself when it works\.$/, '');
    const access = await this.access();
    if (!access) return { manual: true, skipped: `this Mac cannot read Poki's state; tell the person: ${tell}` };
    const hello = (await readHello(access)) ?? this.hello;
    if (!hello?.loopback) return { manual: true, skipped: `this Poki does not say whether its connection answers; tell the person: ${tell}` };
    if (hello.loopback.working) return 'Poki\'s local connection (10.7.0.1) answers';
    // Poki's own sentence for the VPN app it found; device text is kept to one plain line.
    const fromPoki = String(hello.loopback.say ?? '').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 400);
    const say = fromPoki ? `${fromPoki} I see by myself when it works.` : undefined;
    await this.waitFor('loopback', async () => ((await readHello(access))?.loopback?.working ? true : null), {}, say);
    return 'Poki\'s local connection (10.7.0.1) answers';
  }

  async relay() {
    const token = process.env.CLOUDFLARE_API_TOKEN;
    const saved = await this.bridge.request('relay_token_saved').catch(() => false);
    if (!token && !saved) return { skipped: 'no Cloudflare token (set CLOUDFLARE_API_TOKEN to deploy a relay); Poki and its own chat work on the phone without one, but agents on other computers cannot reach it' };
    try {
      const accounts = await this.bridge.request('relay_accounts', token ? { token } : {});
      if (accounts.length !== 1) throw new StepFailure('relay_failed', `the token sees ${accounts.length} Cloudflare accounts; deploy from Poki Setup's Relay page`);
      const deployed = await this.bridge.request('relay_deploy', { ...(token ? { token } : {}), account_id: accounts[0].id });
      this.relayAddress = deployed.address;
      if (deployed.phone_link) this.emit({ event: 'note', text: 'In Poki on the iPhone, open the relay settings and scan the QR on Poki Setup\'s Relay page, or open the relay link there.' });
      return 'relay deployed';
    } catch (error) {
      throw classify('relay', error);
    }
  }

  async check() {
    const records = await this.bridge.request('records');
    const record = records.find(r => r.udid === this.udid);
    const phone = (await this.listPhones()).find(r => r.phone.udid === this.udid);
    const ddi = await this.bridge.request('mount_ddi', { udid: this.udid }).then(() => true, error => {
      if (signingRefused(error.message)) throw error;
      this.emit({ event: 'note', text: `developer disk image: ${error.message}` });
      return false;
    });
    let relay = 'skipped';
    if (this.relayAddress) relay = (await this.bridge.request('relay_check', { address: this.relayAddress }).catch(() => false)) ? 'answering' : 'not answering';
    const check = {
      poki: record ? `${record.version} (${record.build})` : null,
      developer_mode: phone?.facts?.developer_mode === true,
      paired: phone?.facts?.paired_with_this_computer === true,
      ddi_mounted: ddi,
      days_left: record ? Math.round((record.profile_expires_at - Date.now() / 1000) / 86400) : null,
      relay,
    };
    this.checkResult = check;
    if (check.poki) this.record.poki = check.poki;
    const bad = Object.entries(check).filter(([key, value]) => value === null || value === false || (key === 'relay' && value === 'not answering')).map(([key]) => key);
    if (!(record?.profile_expires_at > Date.now() / 1000)) bad.push('signing_expired');
    if (bad.length) throw new StepFailure('check_failed', `not ready: ${bad.join(', ')}`);
    return `Poki ${check.poki}, Developer Mode on, paired, developer disk image mounted, ${check.days_left} days of signing left`;
  }

  reportError(failure, retrying) {
    const spec = manifest.errors[failure.code];
    (this.record.errors ??= []).push({ code: failure.code, reason: failure.reason, retrying, at: new Date().toISOString() });
    this.emit({ event: 'error', code: failure.code, reason: failure.reason, agent_fix: spec.agent_fix, ...(spec.person ? { person: spec.person } : {}), retrying });
  }

  async go() {
    await mkdir(this.inbox, { recursive: true });
    await this.load();
    if (this.opts.ipa) {
      this.record.local_ipa_sha256 = createHash('sha256').update(await readFile(this.opts.ipa)).digest('hex');
      this.record.local_ipa_name = basename(this.opts.ipa);
      this.emit({ event: 'note', text: `Using local build ${this.record.local_ipa_name} (SHA-256 ${this.record.local_ipa_sha256}); no released IPA fallback.` });
    }
    const installer = await installerVersion();
    this.record.installer = installer;
    this.emit({ event: 'installer', ...installer });
    const steps = manifest.steps;
    try {
      for (const [index, step] of steps.entries()) {
        this.emit({ event: 'step', step: step.id, n: index + 1, of: steps.length, who: step.who, title: step.title });
        try {
          const out = await (step.id === 'bridge' ? this.bridge_step() : this[step.id]());
          if (out && typeof out === 'object' && out.skipped) {
            this.emit({ event: 'skipped', step: step.id, reason: out.skipped });
            if (out.manual) {
              this.unverified.push({ step: step.id, say: out.skipped });
              this.emit({ event: 'note', text: `Action required: ${out.skipped}` });
            }
            await this.mark(step.id, out.manual ? 'manual' : this.previous?.steps?.[step.id]?.status === 'ok' ? 'ok' : 'skipped', { detail: out.skipped });
          } else {
            this.emit({ event: 'done', step: step.id, detail: out });
            await this.mark(step.id, 'ok', { detail: out });
          }
        } catch (error) {
          if (error instanceof WaitTimedOut) {
            await this.mark(step.id, 'waiting', { wait: error.wait });
            this.emit({ event: 'result', ok: false, waiting: error.wait, step: step.id, rerun: 'node bin/install-iphone.mjs run' });
            return 3;
          }
          const failure = classify(step.id, error);
          if (failure.code === 'ddi_refused') {
            const phone = this.record.phones?.find(phone => phone.udid === this.udid);
            failure.reason = await ddiRecovery(phone?.ios);
          }
          this.reportError(failure, false);
          await this.mark(step.id, 'failed', { code: failure.code, reason: failure.reason, agent_fix: manifest.errors[failure.code].agent_fix });
          this.emit({ event: 'result', ok: false, step: step.id, code: failure.code, reason: failure.reason, next: 'node bin/install-iphone.mjs diagnose, then node bin/install-iphone.mjs issue' });
          return 2;
        }
      }
      this.record.finished_at = new Date().toISOString();
      await this.save();
      this.emit({ event: 'result', ok: this.unverified.length === 0, check: this.checkResult, dry_run: !!this.opts.dryRun, ...(this.unverified.length ? { unverified: this.unverified } : {}) });
      return this.unverified.length ? 3 : 0;
    } finally {
      this.bridge?.close();
    }
  }
}

export const run = opts => new Run(opts).go();
