# SPDX-License-Identifier: AGPL-3.0-only
# -*- coding: utf-8 -*-
"""Run a real overlap experiment. The host only starts an on-target sequence.
Agent HID events and text are generated in the target process, independently
of the XCTest channel that represents the user's keyboard.
"""
from pathlib import Path
import argparse,json,os,signal,subprocess,time,uuid,shutil,re

root=Path(__file__).resolve().parent
args=argparse.ArgumentParser()
args.add_argument('--device',required=True)
args.add_argument('--name',default='native-overlap')
args.add_argument('--case',choices=['fixture','safari'],default='fixture')
opt=args.parse_args();device=opt.device
env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','LOGNAME','DEVELOPER_DIR']}
def call(argv,**kwargs):return subprocess.run(argv,check=True,env=env,**kwargs)
def container(bundle):return Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'data'],env=env,text=True).strip())
def read(path):return json.loads(path.read_text())
def atomic_json(path,value):
    tmp=path.with_suffix('.pending');tmp.write_text(json.dumps(value,ensure_ascii=False));tmp.replace(path)

target=container('com.apple.mobilesafari' if opt.case=='safari' else 'local.poki.DomainTarget')/'Documents'
bridge=target/'SceneBridge'
state=read(bridge/'state.json')
if state['window']=='none':raise SystemExit('Open the target on the CarPlay display before running the experiment.')
user=container('local.axlab.TypingPad')/'Documents'
driver=root/'driver';derived=Path((driver/'derived-path.txt').read_text().strip())
out=root/'evidence'/opt.name;out.mkdir(parents=True,exist_ok=False)
base=['xcodebuild','-project',str(driver/'AXIsolationDemo.xcodeproj'),'-scheme','AXIsolationDemo','-destination','platform=iOS Simulator,id='+device,'-derivedDataPath',str(derived),'CODE_SIGNING_ALLOWED=NO','ONLY_ACTIVE_ARCH=YES','ARCHS=arm64']
with (out/'build.log').open('w') as f:call(base+['build-for-testing'],stdout=f,stderr=subprocess.STDOUT)
call(['xcrun','simctl','install',device,str(derived/'Build/Products/Debug-iphonesimulator/AXProbeTests-Runner.app')],capture_output=True)
recorders=[];record_logs=[];anchors={};test=None;sent=False
steps=[{'op':'tap','x':140,'y':54,'after':.5+i*.7} for i in range(10)]
steps += [{'op':'text','x':200,'y':94,'text':'皮卡丘 / independent Agent','after':3.9},
          {'op':'swipe','x':200,'y':210,'endX':200,'endY':140,'after':8.0}]
if opt.case=='safari':
    steps=[] # Safari is driven below by fresh observations, not a fixed macro.
def is_images(url):
    from urllib.parse import urlparse,parse_qs
    u=urlparse(url);q=parse_qs(u.query)
    host=u.hostname or ''
    return (host=='baidu.com' or host.endswith('.baidu.com')) and (host=='image.baidu.com' or any(v.startswith('image') for v in q.get('pd',[])))
def query_matches(url):
    from urllib.parse import urlparse,parse_qs
    q=parse_qs(urlparse(url).query)
    return any(v.strip().casefold()=='pikachu' for k in ['word','wd','q'] for v in q.get(k,[]))
def center(row):
    n=[float(x) for x in re.findall(r'-?\d+(?:\.\d+)?',row['frame'])]
    return (n[0]+n[2]/2,n[1]+n[3]/2) if len(n)==4 else None
controller={'phase':'focus','lastAction':0,'attempts':0,'actions':[],'goal':False,'scrollVerified':False}
def send_action(action,observation):
    command={'id':str(uuid.uuid4()),**action};atomic_json(bridge/'command.json',command)
    controller['lastAction']=time.time();controller['actions'].append({'at':time.time(),'phase':controller['phase'],'command':command,'observation':observation})
    (out/'controller.json').write_text(json.dumps(controller,ensure_ascii=False,indent=2))
def drive_safari():
    current=read(bridge/'state.json');now=time.time()
    if now-controller['lastAction']<.45 or current['at']<controller['lastAction']:return
    rows=current['views'];web=next((r for r in rows if 'webURL' in r),{})
    inputs=[r for r in rows if r.get('acceptsText') and r.get('firstResponder') and center(r) and center(r)[1]>400]
    phase=controller['phase']
    if phase=='focus':
        if inputs:controller['phase']='type';return
        bars=[r for r in rows if r['identifier'].startswith('CapsuleNavigationBar') or r['identifier'].startswith('SearchFieldItemView')]
        if not bars:return
        x,y=center(bars[0])
        if y>745:
            send_action({'op':'swipe','x':240,'y':200,'endX':240,'endY':600},web)
        elif controller['attempts']<4:
            send_action({'op':'tap','x':x,'y':y},bars[0]);controller['attempts']+=1
    elif phase=='type':
        if not inputs:controller['phase']='focus';return
        x,y=center(inputs[0]);send_action({'op':'text','x':x,'y':y,'text':'Pikachu','replace':True},inputs[0]);controller['phase']='submit'
    elif phase=='submit':
        if not any(r.get('text')=='Pikachu' for r in inputs):return
        suggestions=[r for r in rows if r['identifier'].startswith('SearchSuggestion') and r.get('text')=='Pikachu']
        if suggestions:
            x,y=center(suggestions[0]);send_action({'op':'tap','x':x,'y':y},suggestions[0]);controller['phase']='images';controller['attempts']=0
    elif phase=='images':
        if not query_matches(web.get('webURL','')) or web.get('webLoading'):return
        if is_images(web['webURL']):
            controller['goal']=True;controller['phase']='scroll';controller['beforeScroll']=web.get('webScrollOffset');return
        if now-controller['lastAction']>=1.0 and controller['attempts']<3:
            send_action({'op':'tap','x':375,'y':77},web);controller['attempts']+=1
    elif phase=='scroll':
        send_action({'op':'swipe','x':240,'y':600,'endX':240,'endY':350},web);controller['phase']='verify-scroll'
    elif phase=='verify-scroll':
        if web.get('webScrollOffset')!=controller.get('beforeScroll'):
            controller['scrollVerified']=True;controller['phase']='done';(out/'controller.json').write_text(json.dumps(controller,ensure_ascii=False,indent=2))
plan={'id':str(uuid.uuid4()),'op':'sequence','steps':steps}
(out/'agent-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
(out/'initial-state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2))
try:
    for display in ['internal','external']:
        f=(out/(display+'-record.log')).open('w');record_logs.append(f)
        recorders.append(subprocess.Popen(['xcrun','simctl','io',device,'recordVideo','--codec=h264','--display='+display,'--force',str(out/(display+'.mp4'))],stdout=f,stderr=f,env=env))
    until=time.monotonic()+10
    while len(anchors)<2 and time.monotonic()<until:
        for display in ['internal','external']:
            if display not in anchors and 'Recording started' in (out/(display+'-record.log')).read_text():anchors[display]=time.time()
        time.sleep(.1)
    (out/'recording-anchors.json').write_text(json.dumps(anchors,indent=2))
    with (out/'test.log').open('w') as log:
        test=subprocess.Popen(base+['test-without-building','-parallel-testing-enabled','NO','-only-testing:AXProbeTests/DisplayDomainTests/testUserTypingForIndependentAgent','-resultBundlePath',str(out/'Run.xcresult')],stdout=log,stderr=subprocess.STDOUT,env=env)
        deadline=time.monotonic()+180
        while test.poll() is None:
            if not sent and any('AXLAB ' in l and 'display.typingInterval' in l and '"start"' in l for l in (out/'test.log').read_text().splitlines()):
                atomic_json(bridge/'command.json',plan);sent=True;print('Independent target sequence started.',flush=True)
            if sent and opt.case=='safari':drive_safari()
            if time.monotonic()>deadline:
                test.terminate();raise RuntimeError('Experiment deadline exceeded; no success claimed.')
            time.sleep(.1)
finally:
    for p in recorders:
        if p.poll() is None:p.send_signal(signal.SIGINT)
    for p in recorders:
        try:p.wait(timeout=20)
        except subprocess.TimeoutExpired:p.terminate()
    for f in record_logs:f.close()

# Xcode may reinstall dependent fixture apps and assign new data containers.
user=container('local.axlab.TypingPad')/'Documents'
for src,name in [(target/'events.json','target-events.json'),(bridge/'events.json','bridge-events.json'),(bridge/'state.json','bridge-state.json'),(user/'evidence.json','user-editor.json')]:
    if src.exists():shutil.copy(src,out/name)
log=(out/'test.log').read_text();telemetry=[]
for line in log.splitlines():
    if 'AXLAB ' in line:
        try:telemetry.append(json.loads(line.split('AXLAB ',1)[1]))
        except json.JSONDecodeError:pass
(out/'test-events.json').write_text(json.dumps(telemetry,indent=2))
intervals={e['stage']:e['at'] for e in telemetry if e.get('event')=='display.typingInterval'}
user_state=read(out/'user-editor.json');events=read(out/'target-events.json') if (out/'target-events.json').exists() else [];be=read(out/'bridge-events.json')
text_events=[e for e in user_state['events'] if e['event']=='text.change' and intervals.get('start',float('inf'))<=e['at']<=intervals.get('end',0)]
lo=text_events[0]['at'] if text_events else float('inf');hi=text_events[-1]['at'] if text_events else 0
overlap=[e for e in events if e['event']=='button.pressed' and lo<=e['at']<=hi]
scroll=[e for e in events if e['event']=='table.scrolled' and lo<=e['at']<=hi]
agent_text=[e for e in be if e['event']=='text.inserted' and lo<=e['at']<=hi and e.get('text')=='皮卡丘 / independent Agent']
interruptions=[e for e in user_state['events'] if lo<=e['at']<=hi and (not e['firstResponder'] or e['state']!=0)]
expected=''.join('Parallel typing %02d: abcdefghijklmnopqrstuvwxyz 0123456789.\n'%i for i in range(24))
verdict={'runtime':'Xcode 26.2 / iOS 26.2 Simulator','device':device,'testHarnessExit':test.returncode,'actualTestStarted':"Test Case '-[DisplayDomainTests testUserTypingForIndependentAgent]' started" in log,'agentSequenceSent':sent,'nativeHIDInput':True,'userTypingFirstChange':lo if text_events else None,'userTypingLastChange':hi if text_events else None,'overlappingButtonActions':len(overlap),'overlappingScrollEvents':len(scroll),'overlappingAgentTextInsertions':len(agent_text),'userTextLength':len(user_state['text']),'userTextExact':user_state['text']==expected,'userFocusAtEnd':user_state['firstResponder'],'userActiveAtEnd':user_state['active'],'userInterruptionEvents':len(interruptions),'realDeviceVerified':False,'arbitraryInstalledAppsVerified':False,'chineseUserIMEVerified':False}
verdict['approachSucceeded']=bool(test.returncode==0 and verdict['actualTestStarted'] and sent and len(overlap)==10 and scroll and agent_text and verdict['userTextExact'] and verdict['userFocusAtEnd'] and verdict['userActiveAtEnd'] and not interruptions)
if opt.case=='safari':
    web=[e for e in be if e['event']=='web.observed' and lo<=e['at']<=hi]
    images=[e for e in web if is_images(e.get('webURL','')) and query_matches(e.get('webURL','')) and not e.get('webLoading')]
    typed=[e for e in be if e['event']=='text.inserted' and lo<=e['at']<=hi and e.get('text')=='Pikachu']
    touches=[e for e in be if e['event']=='nativeTouch.began' and lo<=e['at']<=hi]
    verdict.update({'target':'original Simulator MobileSafari','searchQueryTypedDuringUserTyping':bool(typed),'imagesPageLoadedDuringUserTyping':bool(images),'overlappingNativeGestures':len(touches),'webObservationsDuringUserTyping':web,'imagePageObservations':images,'controller':controller})
    verdict['approachSucceeded']=bool(test.returncode==0 and verdict['actualTestStarted'] and sent and typed and images and len(touches)>=3 and controller['scrollVerified'] and verdict['userTextExact'] and verdict['userFocusAtEnd'] and verdict['userActiveAtEnd'] and not interruptions)
(out/'summary.json').write_text(json.dumps(verdict,indent=2))
for display in ['internal','external']:call(['xcrun','simctl','io',device,'screenshot','--display='+display,str(out/(display+'.png'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print(json.dumps({k:v for k,v in verdict.items() if not isinstance(v,(list,dict))},indent=2),flush=True)
raise SystemExit(0 if verdict['approachSucceeded'] else 1)
