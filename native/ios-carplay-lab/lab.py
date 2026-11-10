#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Prepare a disposable Simulator for the display-domain experiment.

This does not install or pair a physical iPhone. Use a dedicated Simulator:
prepare restarts its SpringBoard and CarPlay services.
"""
import argparse
import json
import plistlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
ENV = {k: v for k, v in os.environ.items()
       if k in ('PATH', 'HOME', 'TMPDIR', 'USER', 'LOGNAME', 'DEVELOPER_DIR')}


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, env=ENV, **kwargs)


def output(argv):
    return subprocess.check_output(argv, text=True, env=ENV).strip()


def atomic(path, value):
    pending = path.with_suffix('.pending')
    pending.write_text(json.dumps(value, indent=2))
    pending.replace(path)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=('prepare', 'launch'))
parser.add_argument('--device', required=True, help='dedicated, booted Simulator UUID')
parser.add_argument('--case', choices=('fixture', 'safari'), default='safari')
parser.add_argument('--bundle', help='override target; compatibility is unverified')
parser.add_argument('--allow', nargs='+', help='explicit installed bundle allowlist for cold launch/switch tests')
parser.add_argument('--restart', action='store_true', help='terminate only the selected target before dashboard launch')
args = parser.parse_args()
device = args.device
bundle = args.bundle or ('com.apple.mobilesafari' if args.case == 'safari'
                         else 'local.poki.DomainTarget')
devices = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
matches = [d for group in devices['devices'].values() for d in group
           if d['udid'] == device and d['state'] == 'Booted']
if not matches:
    parser.error('--device must identify a booted Simulator, never a physical device')

if args.action == 'prepare':
    run(['python3', str(ROOT / 'build.py')])
    build = Path((ROOT / 'build-path.txt').read_text().strip())
    run(['xcrun', 'simctl', 'install', device, str(build / 'DomainTarget.app')])
    # Verify the explicit target is installed before admitting it to CarPlay.
    output(['xcrun', 'simctl', 'get_app_container', device, bundle, 'app'])
    driver = ROOT / 'driver'
    run(['python3', str(driver / 'generate_project.py')])
    derived = Path(tempfile.mkdtemp(prefix='poki-carplay-driver-'))
    (driver / 'derived-path.txt').write_text(str(derived))
    with (ROOT / 'prepare-build.log').open('w') as log:
        run(['xcodebuild', '-project', str(driver / 'AXIsolationDemo.xcodeproj'),
             '-scheme', 'AXIsolationDemo', '-destination',
             'platform=iOS Simulator,id=' + device, '-derivedDataPath', str(derived),
             'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES', 'ARCHS=arm64',
             'build-for-testing'], stdout=log, stderr=subprocess.STDOUT)
    products = derived / 'Build/Products/Debug-iphonesimulator'
    for app in ('TypingPad.app', 'AXProbeTests-Runner.app'):
        run(['xcrun', 'simctl', 'install', device, str(products / app)])
    coordinator = ROOT / 'coordinator'
    coordinator.mkdir(exist_ok=True)
    allowed = args.allow or [bundle]
    targets = {}; apps = []
    for bid in allowed:
        app = Path(output(['xcrun', 'simctl', 'get_app_container', device, bid, 'app']))
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        apps.append({'bundle': bid, 'name': info.get('CFBundleDisplayName', info.get('CFBundleName', bid))})
        data = Path(output(['xcrun', 'simctl', 'get_app_container', device, bid, 'data']))
        # Some Apple system apps are uncontained: simctl returns literal '(null)'.
        # Give those processes an explicit, private lab IPC directory instead.
        directory = data / 'Documents/SceneBridge' if data.is_absolute() else coordinator / 'targets' / bid
        directory.mkdir(parents=True, exist_ok=True)
        targets[bid] = str(directory)
    atomic(coordinator / 'allowlist.json', allowed)
    atomic(coordinator / 'runtime.json', {'bridge': str(build / 'SceneBridge.dylib'), 'targets': targets})
    atomic(ROOT / 'client-config.json', {'coordinator': str(coordinator), 'targets': targets, 'apps': apps})
    # A stale launch request must not run during a service restart.
    if (coordinator / 'launch.json').exists():
        (coordinator / 'launch.json').rename(coordinator / ('previous-' + str(uuid.uuid4()) + '.json'))
    dylib = Path(tempfile.mkdtemp(prefix='poki-carplay-coordinator-')) / 'CarPlayCoordinator.dylib'
    sdk = output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    run(['xcrun', 'clang', '-isysroot', sdk, '-target', 'arm64-apple-ios18.0-simulator',
         '-fobjc-arc', '-fmodules', '-framework', 'UIKit', '-framework', 'Foundation',
         '-DCOORDINATOR_DIR=' + json.dumps(str(coordinator)), '-dynamiclib',
         str(ROOT / 'CarPlayCoordinator.m'), '-o', str(dylib)])
    run(['codesign', '--force', '--sign', '-', str(dylib)])
    for service in ('com.apple.SpringBoard', 'com.apple.CarPlayApp'):
        run(['xcrun', 'simctl', 'spawn', device, 'launchctl', 'debug',
             'user/foreground/' + service, '--environment',
             'DYLD_INSERT_LIBRARIES=' + str(dylib)])
        run(['xcrun', 'simctl', 'spawn', device, 'launchctl', 'kickstart', '-k',
             'user/foreground/' + service])
        time.sleep(3)
    atomic(ROOT / '.lab-state.json', {'device': device, 'bundle': bundle,
           'bridge': str(build / 'SceneBridge.dylib'), 'coordinator': str(dylib)})
    print('Prepared. In Simulator: I/O > External Displays > CarPlay. '
          'Safari test: 960 x 1600 pixels, scale 2, Touch Screen enabled. '
          'Fixture test: 800 x 480 pixels, scale 2. Then run lab.py launch.')
else:
    config = json.loads((ROOT / '.lab-state.json').read_text())
    if config['device'] != device:
        parser.error('prepare the same device first')
    client = json.loads((ROOT / 'client-config.json').read_text())
    if bundle not in client['targets']:
        parser.error('target is not in the prepared allowlist')
    bridge_dir = Path(client['targets'][bundle])
    command = bridge_dir / 'command.json'
    if command.exists():
        command.rename(command.with_name('previous-' + str(uuid.uuid4()) + '.json'))
    if args.restart:
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle],
                       env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    started = time.time()
    atomic(ROOT / 'coordinator/launch.json', {'id': str(uuid.uuid4()), 'bundle': bundle})
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            state = json.loads((bridge_dir / 'state.json').read_text())
            if state.get('window') != 'none' and state.get('sceneState') == 0 and state.get('at', 0) > started:
                print('Target has a live external window. Run run_parallel.py for the overlap test.')
                break
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(.2)
    else:
        raise SystemExit('No fresh external target window. Check CarPlay display and coordinator/*.json; no success claimed.')
