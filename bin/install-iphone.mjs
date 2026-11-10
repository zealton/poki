#!/usr/bin/env node
// Installs Poki on an iPhone through Poki Setup without its window. Agents follow skills/install-poki/SKILL.md.
import { mkdir, readFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { Bridge } from '../src/install/bridge.mjs';
import { findSetupBridge, SetupError } from '../src/install/setup-app.mjs';
import { installerLabel, installerVersion } from '../src/install/version.mjs';
import { diagnose, issueDraft, readRun } from '../src/install/report.mjs';
import { codeCommand, defaultStateDir, manifest, run, writeInbox } from '../src/install/run.mjs';
import { PROVIDERS } from '../src/install/model-key.mjs';
import { readRecords } from '../src/install/records.mjs';

const usage = `Usage: node bin/install-iphone.mjs <command> [options]

Commands:
  run                 Install Poki on the iPhone, stopping only where a person has to act.
  code                Hand the running install the Apple two-factor code. The person runs this in their own
                      Terminal and types the code at the hidden prompt (or pipes it in). Never as an argument.
  done <step>         Tell the running install that the person finished a step it cannot see (open_poki).
  phones              List the iPhones Poki Setup can reach (to choose one with --udid).
  records             Copy Poki's chats, voice conversations and log off the iPhone over USB (read-only) and
                      write them in time order to a text file (default <state>/records/). Keys, pairing
                      records and relay addresses are left out. Prints only the file's path.
  diagnose            Print a diagnostics bundle with identifiers and secrets removed.
  issue               Draft an English issue from the last run. It prints the draft and the gh command;
                      it never submits. Show the draft to the person first.
  steps               Print the steps, who does each one, and the error codes.

Options:
  --channel <name>    stable, beta, alpha (default) or pre-alpha.
  --udid <udid>       The iPhone to use when several are plugged in.
  --dry-run           Download and check the real Poki Setup, start its real helper, then simulate the
                      iPhone and the Apple Account. Nothing touches a device or Apple.
  --json              One JSON event per line (for agents).
  --state <dir>       Where the run keeps its record (default ~/Library/Application Support/PokiInstall).
  --setup-home <dir>  Poki Setup's data directory (default: Poki Setup's own, shared with the app).
  --bridge <path>     Use this poki-setup-bridge instead of the one in Poki Setup.app.
  --app-dir <dir>     Where to put Poki Setup.app when it is not installed (default ~/Applications).
  --reinstall         Sign and install again even when the last run installed Poki.
  --ipa <path>        Install a locally built IPA through the same signing/setup flow.
                      Put its matching Poki-signing.zip beside it. No released IPA is substituted.
  --model-key <name>  Also give Poki on the iPhone this provider's model key from the Mac's login keychain
                      (${PROVIDERS.join(', ')}). Off unless given: ask the person first. The key is sealed
                      to a key Poki makes on the phone and never printed, logged or put on a command line.
  --model-key-item <item>  The keychain item to read it from (default <name>-api-key, e.g. openai-api-key).
  --version           Print the installer's version and build commit.
  --out <file>        records only: write the text here instead.
  --bundle <id>       records only: Poki's bundle id, when iOS does not list it as Poki.
  --no-device         diagnose only: do not ask usbmuxd, devicectl or Bonjour about devices.

Exit codes: 0 done, 1 bad usage, 2 a step failed (see the code), 3 a person step is still open (run again).`;

// Node 24 or later (package.json engines). An older Node fails later in a step that has nothing to
// do with it, so it is named here, with the way around it: Poki Setup's own command line tool.
if (Number(process.versions.node.split('.')[0]) < 24 && process.env.POKI_INSTALL_ANY_NODE !== '1') {
  const reason = `This installer needs Node.js 24 or later; this is ${process.version}.`;
  const agentFix = 'Install Node.js 24 or later and run again, or use the command line tool inside Poki Setup (320 or later), which needs no Node: "/Applications/Poki Setup.app/Contents/MacOS/poki-setup" next --json (see the skill).';
  if (process.argv.includes('--json')) console.log(JSON.stringify({ event: 'error', code: 'node_too_old', reason, agent_fix: agentFix, retrying: false, at: new Date().toISOString() }));
  else console.error(`${reason} ${agentFix}`);
  process.exit(2);
}

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    channel: { type: 'string', default: 'alpha' },
    udid: { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
    json: { type: 'boolean', default: false },
    state: { type: 'string' },
    'setup-home': { type: 'string' },
    bridge: { type: 'string' },
    'app-dir': { type: 'string' },
    reinstall: { type: 'boolean', default: false },
    ipa: { type: 'string' },
    'model-key': { type: 'string' },
    'model-key-item': { type: 'string' },
    'no-device': { type: 'boolean', default: false },
    out: { type: 'string' },
    bundle: { type: 'string' },
    version: { type: 'boolean', short: 'v', default: false },
    help: { type: 'boolean', short: 'h', default: false },
  },
});
if (opts.version) {
  console.log(`Poki installer ${installerLabel(await installerVersion())}`);
  process.exit(0);
}
const [command, arg] = positionals;
const dryRun = opts['dry-run'];
const state = resolve(opts.state ?? join(defaultStateDir(), dryRun ? 'dry-run' : ''));
const appDir = opts['app-dir'] ? resolve(opts['app-dir']) : dryRun ? join(state, 'app') : undefined;
const setupHome = opts['setup-home'] ? resolve(opts['setup-home']) : dryRun ? join(state, 'setup-home') : undefined;
await mkdir(join(state, 'inbox'), { recursive: true });

// The Apple code is single-use but still a credential: it is read from a hidden prompt or stdin,
// never from argv, where ps and shell history would show it.
async function readSecret(prompt) {
  if (!process.stdin.isTTY) {
    let text = '';
    for await (const chunk of process.stdin) text += chunk;
    return text.trim();
  }
  process.stderr.write(prompt);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  let text = '';
  for await (const chunk of process.stdin) {
    const input = chunk.toString();
    if (input.includes('\u0003')) { process.stderr.write('\n'); process.exit(130); }
    const end = input.search(/[\r\n]/);
    text += end < 0 ? input : input.slice(0, end);
    if (end >= 0) break;
  }
  process.stdin.setRawMode(false);
  process.stderr.write('\n');
  return text.trim();
}

async function inbox(name, value) {
  await writeInbox(join(state, 'inbox'), name, value);
}

// phones and diagnose start the helper the last run used, else the Poki Setup run would use.
async function bridgePath() {
  if (opts.bridge) {
    if (!existsSync(resolve(opts.bridge))) throw new SetupError('setup_app_missing', `${resolve(opts.bridge)} does not exist`);
    return resolve(opts.bridge);
  }
  return findSetupBridge({ recorded: (await readRun(state))?.setup_bridge, into: appDir });
}

switch (opts.help ? 'help' : command) {
  case 'run':
    if (opts.ipa && (!opts.ipa.endsWith('.ipa') || !existsSync(resolve(opts.ipa)) || !statSync(resolve(opts.ipa)).isFile())) {
      console.error('--ipa must name an existing .ipa file.'); process.exitCode = 1; break;
    }
    if (opts['model-key'] !== undefined && !PROVIDERS.includes(opts['model-key'])) { console.error(`--model-key is one of ${PROVIDERS.join(', ')}.`); process.exitCode = 1; break; }
    process.exitCode = await run({ modelKey: opts['model-key'], modelKeyItem: opts['model-key-item'], state, setupHome, channel: opts.channel, udid: opts.udid, dryRun, json: opts.json, bridge: opts.bridge && resolve(opts.bridge), appDir, reinstall: opts.reinstall, ipa: opts.ipa && resolve(opts.ipa) });
    break;
  case 'code':
    if (arg !== undefined) { console.error(`Do not put the Apple code on the command line. Run: ${codeCommand(state)} (and type it at the hidden prompt).`); process.exitCode = 1; break; }
    {
      const digits = await readSecret('Apple code (6 digits, not shown): ');
      if (!/^\d{6}$/.test(digits)) { console.error('The Apple code has 6 digits.'); process.exitCode = 1; break; }
      await inbox('apple-code', digits);
    }
    console.log('Handed the code to the running install.');
    break;
  case 'done':
    if (arg !== 'open_poki') { console.error('Only open_poki is confirmed by hand: node bin/install-iphone.mjs done open_poki'); process.exitCode = 1; break; }
    await inbox(arg, 'done');
    console.log(`Told the running install that ${arg} is done.`);
    break;
  case 'phones': {
    try {
      const path = await bridgePath();
      const { bridge } = await Bridge.start(path, { env: setupHome ? { POKI_SETUP_HOME: setupHome } : {} });
      try {
        for (const r of await bridge.request('phones')) console.log(`${r.phone.udid}  ${r.facts?.product_type ?? '?'}  iOS ${r.facts?.ios ?? '?'}  ${r.phone.link?.kind ?? ''}`);
      } finally { bridge.close(); }
    } catch (error) {
      console.error(`${error.code ?? error.kind ?? 'error'}: ${error.message}`);
      process.exitCode = 2;
    }
    break;
  }
  case 'records':
    try {
      const done = await readRecords({ udid: opts.udid, bundle: opts.bundle, out: opts.out && resolve(opts.out), state });
      console.log(`Wrote ${done.sessions} conversation${done.sessions === 1 ? '' : 's'} and ${done.logLines} log lines from Poki ${done.poki.version} to ${done.file}`);
    } catch (error) {
      console.error(`${error.code ?? 'error'}: ${error.message}`);
      process.exitCode = 2;
    }
    break;
  case 'diagnose':
    process.stdout.write((await diagnose({ state, noDevice: opts['no-device'], bridge: opts.bridge && resolve(opts.bridge), appDir, setupHome })).text);
    break;
  case 'issue': {
    const draft = await issueDraft({ state });
    console.log(`Title: ${draft.title}\n\n${draft.body}`);
    console.log(`Saved to ${draft.draftFile}.\n\nShow this draft to the person and submit it only after they say yes. Then run:\n  ${draft.command}`);
    break;
  }
  case 'steps':
    console.log(JSON.stringify(manifest, null, 2));
    break;
  default:
    console.log(usage);
    process.exitCode = command && !opts.help ? 1 : 0;
}
