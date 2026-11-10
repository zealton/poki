# SPDX-License-Identifier: AGPL-3.0-only
# No model calls on the host: this drives only the independent user's keyboard.
from pathlib import Path
import json,subprocess,time,signal,uuid,os,shutil,argparse
root=Path(__file__).resolve().parent;lab=root
a=argparse.ArgumentParser();a.add_argument('--device',required=True);a.add_argument('--name',required=True);a.add_argument('--task',default='');a.add_argument('--launch-only',action='store_true');a.add_argument('--followup');o=a.parse_args();sim=o.device
if not o.name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in o.name):raise SystemExit('Use letters, digits, - or _ for --name')
if not o.launch_only and not o.task:raise SystemExit('--task is required for a model run')
out=root/'evidence'/o.name;out.mkdir(parents=True,exist_ok=False)
env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','LOGNAME','DEVELOPER_DIR']}
def call(args,**kwargs):return subprocess.run(args,env=env,check=True,**kwargs)
def container(b):return Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,b,'data'],env=env,text=True).strip())
def atomic(p,v):
 q=p.with_suffix('.pending');q.write_text(json.dumps(v));q.replace(p)
c=json.loads((lab/'client-config.json').read_text());launch=lab/'coordinator/launch.json'
if launch.exists():launch.rename(launch.with_name('old-'+str(uuid.uuid4())+'.json'))
# The target apps are stopped before user typing. Their first new PID must appear during typing.
for b in c['targets']:
 subprocess.run(['xcrun','simctl','terminate',sim,b],env=env,capture_output=True)
 bridge=Path(c['targets'][b]);cmd=bridge/'command.json'
 if cmd.exists():cmd.rename(cmd.with_name('old-'+str(uuid.uuid4())+'.json'))
poki=container('app.zealton.poki')/'Documents';request=poki/'carplay-acceptance/request.json';request.parent.mkdir(parents=True,exist_ok=True)
if request.exists():request.rename(request.with_name('old-'+str(uuid.uuid4())+'.json'))
runid=str(uuid.uuid4());jobs=[{'id':runid,'task':o.task}];followed=False;derived=Path((lab/'driver/derived-path.txt').read_text().strip());logs=[];recorders=[];anchors={};test=None
try:
 for display in ['internal','external']:
  f=(out/(display+'-record.log')).open('w');logs.append(f)
  recorders.append(subprocess.Popen(['xcrun','simctl','io',sim,'recordVideo','--codec=h264','--display='+display,'--force',str(out/(display+'.mp4'))],env=env,stdout=f,stderr=f))
 deadline=time.monotonic()+8
 while len(anchors)<2 and time.monotonic()<deadline:
  for d in ['internal','external']:
   if d not in anchors and 'Recording started' in (out/(d+'-record.log')).read_text():anchors[d]=time.time()
  time.sleep(.1)
 (out/'recording-anchors.json').write_text(json.dumps(anchors))
 selector='testUserTypingForIndependentAgent' if o.launch_only else 'testUserTypingForLiveCarPlay'
 with (out/'test.log').open('w') as log:
  test=subprocess.Popen(['xcodebuild','test-without-building','-project',str(lab/'driver/AXIsolationDemo.xcodeproj'),'-scheme','AXIsolationDemo','-destination','platform=iOS Simulator,id='+sim,'-derivedDataPath',str(derived),'CODE_SIGNING_ALLOWED=NO','ARCHS=arm64','-parallel-testing-enabled','NO','-only-testing:AXProbeTests/DisplayDomainTests/'+selector,'-resultBundlePath',str(out/'Run.xcresult')],env=env,stdout=log,stderr=subprocess.STDOUT)
  sent=None;launches=[];deadline=time.monotonic()+300
  bundles=['com.apple.mobilesafari','com.apple.mobileslideshow','com.apple.Preferences','com.apple.mobilesafari']
  while test.poll() is None:
   text=(out/'test.log').read_text()
   if sent is None and any('AXLAB ' in l and 'display.typingInterval' in l and '"start"' in l for l in text.splitlines()):
    sent=time.time();atomic(request,{'id':runid,'task':o.task}) if not o.launch_only else None
    print('User typing started; '+('dashboard launch tests' if o.launch_only else 'original Poki model task triggered'),flush=True)
   if sent is not None and o.followup and not followed and (poki/'carplay-acceptance'/(runid+'.json')).exists() and '"end"' not in text:
    followed=True;job={'id':str(uuid.uuid4()),'task':o.followup};jobs.append(job);atomic(request,job);print('Original Poki follow-up model task triggered',flush=True)
   if sent is not None and o.launch_only and len(launches)<len(bundles) and time.time()-sent>=.5+len(launches)*4.8:
    b=bundles[len(launches)];cmd={'id':str(uuid.uuid4()),'bundle':b};atomic(launch,cmd);launches.append({'at':time.time(),'command':cmd})
   for entry in launches:
    if entry.get('snapshot'):continue
    p=Path(c['targets'][entry['command']['bundle']])/'state.json'
    if p.exists():
     state=json.loads(p.read_text())
     if state.get('at',0)>entry['at'] and state.get('pid') and state.get('sceneState')==0 and state.get('window')!='none':
      entry['snapshot']={k:state.get(k) for k in ['at','bundle','pid','window','sceneState']}
      call(['xcrun','simctl','io',sim,'screenshot','--display=external',str(out/(str(launches.index(entry))+'-external.png'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if time.monotonic()>deadline:test.terminate();raise RuntimeError('Test deadline exceeded')
   time.sleep(.1)
  (out/'launches.json').write_text(json.dumps(launches,indent=2));(out/'request.json').write_text(json.dumps({'id':runid,'task':o.task,'triggeredAt':sent,'jobs':jobs},indent=2))
finally:
 for p in recorders:
  if p.poll() is None:p.send_signal(signal.SIGINT)
 for p in recorders:
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.terminate()
 for f in logs:f.close()
user=container('local.axlab.TypingPad')/'Documents/evidence.json';shutil.copy(user,out/'user-editor.json')
for b,path in c['targets'].items():
 d=out/b;d.mkdir()
 for name in ['state.json','events.json','frame.png']:
  p=Path(path)/name
  if p.exists():shutil.copy(p,d/name)
for name in ['SpringBoard.json','CarPlay.json']:shutil.copy(lab/'coordinator'/name,out/name)
response=poki/'carplay-acceptance'/(runid+'.json')
if response.exists():shutil.copy(response,out/'model-response.json')
for job in jobs:
 receipt=poki/'carplay-acceptance'/(job['id']+'.json')
 if receipt.exists():shutil.copy(receipt,out/(job['id']+'.json'))
if (poki/'carplay-evidence').exists():shutil.copytree(poki/'carplay-evidence',out/'model-evidence')
telemetry=[]
for l in (out/'test.log').read_text().splitlines():
 if 'AXLAB ' in l:
  try:telemetry.append(json.loads(l.split('AXLAB ',1)[1]))
  except json.JSONDecodeError:pass
(out/'test-events.json').write_text(json.dumps(telemetry,indent=2))
interval={e['stage']:e['at'] for e in telemetry if e.get('event')=='display.typingInterval'}
u=json.loads((out/'user-editor.json').read_text());te=[e for e in u['events'] if e['event']=='text.change' and interval.get('start',float('inf'))<=e['at']<=interval.get('end',0)]
lo=te[0]['at'] if te else 0;hi=te[-1]['at'] if te else 0
bad=[e for e in u['events'] if lo<=e['at']<=hi and (not e['firstResponder'] or e['state']!=0)]
count=24 if o.launch_only else 160;expected=''.join('Parallel typing %02d: abcdefghijklmnopqrstuvwxyz 0123456789.\n'%i for i in range(count))
v={'actualTestStarted':bool(interval.get('start') and interval.get('end')),'testExit':test.returncode,'typingStart':lo,'typingEnd':hi,'duration':hi-lo,'userTextLength':len(u['text']),'userTextExact':u['text']==expected,'userFocus':u['firstResponder'],'userActive':u['active'],'interruptions':len(bad),'modelResponsePresent':response.exists(),'runId':runid,'launches':launches}
v['actualTestStarted']=bool(interval.get('start') and interval.get('end'));v['typingPassed']=bool(v['actualTestStarted'] and test.returncode==0 and te and u['text']==expected and u['firstResponder'] and u['active'] and not bad)
v['jobs']=jobs
(out/'summary.json').write_text(json.dumps(v,indent=2));print(json.dumps(v,indent=2),flush=True)

if o.launch_only:
 passed=v['typingPassed'] and len(launches)==4 and all(x.get('snapshot') and lo<=x['snapshot']['at']<=hi for x in launches)
else:
 responses=[]
 for job in jobs:
  path=out/(job['id']+'.json')
  if path.exists():responses.append(json.loads(path.read_text()))
 passed=v['typingPassed'] and len(responses)==len(jobs) and all(r.get('success') is True and lo<=r['started']<=r['ended']<=hi for r in responses)
print('Automated input/model checks:', 'PASS' if passed else 'FAIL', '; visually verify actual task results as well.',flush=True)
raise SystemExit(0 if passed else 1)
