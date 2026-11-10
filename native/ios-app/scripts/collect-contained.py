#!/usr/bin/env python3
"""Collect an explicitly enabled Debug Simulator acceptance run; never reads model credentials.
The UI test must have finished before collection. Pixel content needs separate visual review.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('device')
p.add_argument('test_log', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--lines', type=int, default=40)
a = p.parse_args()
env = {k:os.environ[k] for k in ['PATH','HOME','TMPDIR','USER','LOGNAME','DEVELOPER_DIR'] if k in os.environ}
def container(bundle):
    return Path(subprocess.check_output(['xcrun','simctl','get_app_container',a.device,bundle,'data'], env=env,text=True).strip())
host, pad = container('app.zealton.poki'), container('app.zealton.poki.TypingPad')
evidence = host/'Documents/contained-evidence'
if not evidence.is_dir() or not any(evidence.glob('*.json')):
    raise SystemExit('No contained Agent observations/actions: typing-only success is not end-to-end acceptance.')
log = a.test_log.read_text()
start = float(re.search(r'CONTAINED_TYPING_BEGIN at=([0-9.]+)',log)[1])
end = float(re.search(r'CONTAINED_TYPING_END at=([0-9.]+)',log)[1])
typing = json.loads((pad/'Documents/evidence.json').read_text())
events = [e for e in typing['events'] if start <= e['at'] <= end]
expected = ''.join(f'owner-{i:02d} keeps typing.\n' for i in range(a.lines))
a.output.mkdir(parents=True,exist_ok=True)
shutil.copyfile(pad/'Documents/evidence.json',a.output/'typing.json')
shutil.copyfile(a.test_log,a.output/'ui-test.log')
shutil.copytree(host/'Documents/contained-evidence',a.output/'guest',dirs_exist_ok=True)
sessions = list((host/'Library/Application Support/Poki/Sessions').glob('*.json'))
session = max(sessions,key=lambda f:json.loads(f.read_text()).get('updated',0))
shutil.copyfile(session,a.output/'session.json')
looks, actions = [], []
for f in sorted((a.output/'guest').glob('*.json')):
    record = json.loads(f.read_text())
    value = record['result']
    if not start <= record['at'] <= end:
        continue
    if record['kind'] == 'look':
        web = value.get('web',{})
        image = f.with_suffix('.jpg')
        looks.append({'file':f.name,'hostBackground':not record['hostActive'],
            'guestPID':value.get('pid'),'bundle':value.get('bundle'),'capture':value.get('capture'),
            'error':value.get('error'),'url':web.get('url'),'title':web.get('title'),
            'loadedImages':len(web.get('images',[])),
            'jpegSHA256':hashlib.sha256(image.read_bytes()).hexdigest() if image.exists() else None})
    else:
        actions.append({'file':f.name,'hostBackground':not record['hostActive'],'result':value})
processes = subprocess.check_output(['ps','-axo','pid=,comm='],env=env,text=True).splitlines()
host_running = any('/Devices/'+a.device+'/' in line and line.rstrip().endswith('/Poki.app/Poki') for line in processes)
result = {'hostRunningAfterTest':host_running,'device':a.device,'typingWindow':[start,end],'durationSeconds':end-start,
    'expectedCharacters':len(expected),'actualCharacters':len(typing['text']),
    'exactText':typing['text']==expected,
    'focusLosses':sum(e['event']=='text.blur' for e in events),
    'foregroundLosses':sum('WillResignActive' in e['event'] or 'DidEnterBackground' in e['event'] for e in events),
    'looksDuringTyping':looks,'actionsDuringTyping':actions,
    'pixelContentRequiresVisualReview':True,'physicalIPhoneTested':False,'appleNotesTested':False}
result['typingIsolationPassed'] = result['exactText'] and not result['focusLosses'] and not result['foregroundLosses']
result['backgroundRenderingPassed'] = any(x['hostBackground'] and x['bundle']=='com.apple.mobilesafari'
    and x['capture']=='guest-calayer+real-WKWebView-snapshot' and not x['error'] for x in looks)
(a.output/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['actualCharacters','exactText','focusLosses','foregroundLosses','typingIsolationPassed','backgroundRenderingPassed']},indent=2))
if not result['typingIsolationPassed'] or not result['backgroundRenderingPassed'] or not result['hostRunningAfterTest']:
    raise SystemExit(1)
