# SPDX-License-Identifier: AGPL-3.0-only
"""Real native fixture regression checks; never runs a model or global input."""
import json
import re
import subprocess
import time
import uuid
from pathlib import Path


class TransportChecks:
    def __init__(self, config, device, out, atomic, env):
        self.bundle = 'local.poki.DomainTarget'
        self.directory = Path(config['targets'][self.bundle])
        self.launch = Path(config['coordinator']) / 'launch.json'
        self.device, self.out, self.atomic, self.env = device, out, atomic, env
        self.phase = 'start'; self.results = []; self.pending = None
        self.started = None; self.done = False

    def read(self, name):
        try:
            return json.loads((self.directory / name).read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def point(self, state, identifier):
        row = next(v for v in state['views'] if v.get('identifier') == identifier)
        x, y, w, h = map(float, re.findall(r'-?\d+(?:\.\d+)?', row['frame']))
        return {'x': x + w / 2, 'y': y + h / 2}

    def send(self, state, op, **values):
        command = {'id': str(uuid.uuid4()), 'op': op, 'instance': state['instance'],
                   'expiresAt': time.time() + 8, **values}
        self.atomic(self.directory / 'command.json', command)
        self.pending = command['id']

    def record(self, name, ok, **detail):
        self.results.append({'check': name, 'ok': bool(ok), 'at': time.time(), **detail})
        (self.out / 'transport-checks.json').write_text(json.dumps(self.results, indent=2))

    def tick(self):
        if self.done:
            return
        if self.started is None:
            self.started = time.time()
        if time.time() - self.started > 18:
            self.record('deadline', False, phase=self.phase); self.done = True; return
        state = self.read('state.json')
        if state.get('sceneState') != 0 or not state.get('instance'):
            return
        result = self.read('result.json')
        answered = self.pending and result.get('id') == self.pending
        if self.phase == 'start':
            self.original = state['instance']
            self.send(state, 'tap', **self.point(state, 'domain.button'), instance='old-process')
            self.phase = 'stale'
        elif self.phase == 'stale' and answered:
            self.record('stale_instance_rejected', result.get('event') == 'command.instanceMismatch' and result.get('ok') is False)
            self.send(state, 'tap', **self.point(state, 'domain.button'), expiresAt=time.time() - 1)
            self.phase = 'expired'
        elif self.phase == 'expired' and answered:
            self.record('expired_command_rejected', result.get('event') == 'command.expired' and result.get('ok') is False)
            self.send(state, 'text', x=2, y=2, text='MUST NOT INSERT')
            self.phase = 'invalid_text'
        elif self.phase == 'invalid_text' and answered:
            self.record('non_input_target_rejected', result.get('event') == 'text.noInput' and result.get('ok') is False)
            self.send(state, 'tap', **self.point(state, 'domain.button'))
            self.phase = 'button'
        elif self.phase == 'button' and answered:
            if not any(v.get('text') == 'REAL COUNT: 1' for v in state['views']):
                return
            self.record('one_real_button_action', result.get('event') == 'nativeTouch.ended')
            self.send(state, 'tap', **self.point(state, 'domain.permission'))
            self.phase = 'permission'
        elif self.phase == 'permission' and answered:
            events = self.read('../events.json') or []
            after = next((e for e in events if e['event'] == 'permission.after'), None)
            before = next((e for e in events if e['event'] == 'permission.before'), None)
            if after is None or before is None:
                return
            self.record('permission_deferred_without_grant', before['status'] == 0 and after['status'] == 0 and not after['granted'] and after['deferred'], before=before['status'], after=after['status'])
            subprocess.run(['xcrun', 'simctl', 'terminate', self.device, self.bundle], check=True, env=self.env, capture_output=True)
            self.atomic(self.launch, {'id': str(uuid.uuid4()), 'bundle': self.bundle})
            self.phase = 'restarted'
        elif self.phase == 'restarted' and state['instance'] != self.original:
            if result.get('instance') != state['instance'] or result.get('event') != 'command.instanceMismatch':
                return
            events = self.read('../events.json') or []
            clean = not any(e['event'] in ('button.pressed', 'permission.before') for e in events)
            self.record('restart_does_not_replay_old_action', clean)
            self.done = True
