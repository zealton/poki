#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Collect only bundled fixture / TypingPad evidence, never arbitrary guest contents."""
import argparse
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('device')
parser.add_argument('output', type=Path)
parser.add_argument('--expected-count', type=int, default=10)
parser.add_argument('--native-input', action='store_true', help='Account for iOS sentence autocapitalization on the normal Mac keyboard channel')
args = parser.parse_args()

def container(bundle):
    return Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
        args.device, bundle, 'data'], text=True).strip())

host = container('app.zealton.poki.workspace')
args.output.mkdir(parents=True, exist_ok=True)
# NSHomeDirectory may be cached at LiveProcess startup; inspect only our extension's own container.
roots = [host / 'Documents/Data/Application/PKW-PokiWorker',
         host / 'Documents/Data/Application/PKW-PokiFixture']
for candidate in (host.parent.parent / 'PluginKitPlugin').glob('*'):
    metadata = candidate / '.com.apple.mobile_container_manager.metadata.plist'
    if metadata.exists():
        identity = plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier', '')
        if identity == 'app.zealton.poki.workspace.LiveProcess':
            roots.append(candidate)
for name in ['fixture.json', 'fixture-run.json', 'fixture-guest.jpg']:
    candidates = [r / 'Documents' / name for r in roots if (r / 'Documents' / name).exists()]
    if candidates:
        shutil.copyfile(max(candidates, key=lambda p: p.stat().st_mtime), args.output / name)
pad = container('app.zealton.poki.TypingPad') / 'Documents/evidence.json'
if pad.exists():
    shutil.copyfile(pad, args.output / 'typing.json')
fixture = json.loads((args.output / 'fixture.json').read_text())
worker = json.loads((args.output / 'fixture-run.json').read_text())
typing = json.loads((args.output / 'typing.json').read_text())
changes = [x for x in typing['events'] if x['event'] == 'text.change']
first, last = (min(x['at'] for x in changes), max(x['at'] for x in changes)) if changes else (0, 0)
overlap = [x for x in fixture.get('events', []) if first <= x['at'] <= last]
focus = [x for x in fixture.get('events', []) if x.get('focusAttempted')]
prefix='Owner' if args.native_input else 'owner'
expected = ''.join((prefix+'-%02d keeps typing.\n') % i for i in range(30))
checks = {
    'model_completed': worker['phase'] == 'completed',
    'actual_callbacks': fixture['count'] == args.expected_count and fixture['name'] == 'Poki',
    'separate_processes': len({fixture['pid'], worker['workerPID'], typing['pid']}) == 3,
    'exact_typing': typing['text'] == expected,
    'actual_actions_during_typing': len(overlap) > 0,
    'no_focus_loss_during_typing': all(x['firstResponder'] and x['state'] == 0 for x in typing['events'] if first <= x['at'] <= last),
    'focus_requests_rejected': bool(focus) and not any(x.get('focusGranted') for x in focus),
    'guest_pixel_capture': worker.get('observation', {}).get('capture') == 'guest-calayer',
}
summary = {'checks': checks, 'allPassed': all(checks.values()), 'count': fixture['count'],
    'characters': len(typing['text']), 'actionsDuringTyping': len(overlap),
    'focusAttempts': len({x['count'] for x in focus}), 'requests': worker['requests'],
    'model': worker['servedModel'], 'typingStart': first, 'typingEnd': last,
    'pids': {'guest': fixture['pid'], 'worker': worker['workerPID'], 'typingPad': typing['pid']}}
(args.output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(summary, ensure_ascii=False, indent=2))
