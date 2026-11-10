#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Launch original Poki with the prepared Simulator display backend.

Optional API-key provisioning uses a private one-shot FIFO, never argv, an
environment value, a regular file or target-app IPC. The unsigned Simulator
may retain the key only in Poki's memory, as indicated in its Accounts UI.
"""
import argparse
import getpass
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--app', type=Path, help='optional original Poki.app build product to stage/install')
parser.add_argument('--provision', action='store_true', help='read an OpenRouter key from a secure terminal prompt')
opt = parser.parse_args()
env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'TMPDIR', 'USER', 'LOGNAME', 'DEVELOPER_DIR')}


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, env=env, **kwargs)


devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], env=env))
if not any(d['udid'] == opt.device and d['state'] == 'Booted' for group in devices['devices'].values() for d in group):
    parser.error('--device must be a booted Simulator')
if not (root / 'client-config.json').exists():
    parser.error('run lab.py prepare first')
if opt.app:
    stage = Path(tempfile.mkdtemp(prefix='poki-carplay-app-')) / 'Poki.app'
    shutil.copytree(opt.app.resolve(), stage)
    run(['xattr', '-cr', str(stage)])
    for dylib in stage.rglob('*.dylib'):
        run(['codesign', '--force', '--sign', '-', str(dylib)])
    bundles = [p for p in stage.rglob('*') if p.is_dir() and p.suffix in ('.framework', '.appex', '.xctest')]
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        run(['codesign', '--force', '--sign', '-', str(bundle)])
    run(['codesign', '--force', '--sign', '-', str(stage)])
    run(['xcrun', 'simctl', 'install', opt.device, str(stage)])
bundle = 'app.zealton.poki'
subprocess.run(['xcrun', 'simctl', 'terminate', opt.device, bundle], env=env, capture_output=True)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', opt.device, bundle, 'data'], text=True, env=env).strip())
pending = container / 'Documents/carplay-acceptance/request.json'
if pending.exists():
    pending.rename(pending.with_name('previous-' + str(time.time_ns()) + '.json'))
launch_env = {**env, 'SIMCTL_CHILD_POKI_CARPLAY_CONFIG': str(root / 'client-config.json')}
with tempfile.TemporaryDirectory(prefix='poki-carplay-secret-') as private:
    fifo = Path(private) / 'credential.fifo'
    if opt.provision:
        os.mkfifo(fifo, 0o600)
        launch_env['SIMCTL_CHILD_POKI_TEST_CREDENTIAL_FIFO'] = str(fifo)
    subprocess.run(['xcrun', 'simctl', 'launch', opt.device, bundle, '-pokiScreen', 'chat',
                    '-pokiCarPlay', 'YES', '-pokiContainedSafari', 'NO', '-pokiCarPlayEvidence', 'YES',
                    '-pokiInProcess', 'carplay', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                   check=True, env=launch_env)
    if opt.provision:
        secret = getpass.getpass('OpenRouter API key (not saved by this script): ').strip()
        deadline = time.monotonic() + 20
        while True:
            try:
                fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise SystemExit('Poki did not open its credential FIFO; nothing was written.')
                time.sleep(.1)
        with os.fdopen(fd, 'w') as writer:
            json.dump({'provider': 'openrouter', 'secret': secret,
                       'model': 'deepseek/deepseek-v4.1-flash-1017'}, writer)
        secret = None
        print('Credential delivered to original Poki only.')
print('Poki is ready. Its CarPlay mode uses the original ChatModel / PiLoop / ModelKeys.')
