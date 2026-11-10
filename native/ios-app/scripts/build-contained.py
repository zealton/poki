#!/usr/bin/env python3
"""Compose original Poki + pinned LiveContainer + locally installed Simulator MobileSafari.
No API keys accepted. Never downloads or publishes Apple's application binary.
First build ios-workspace/scripts/build.py with the pinned runtime checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--workspace-build', type=Path, required=True)
p.add_argument('--safari', type=Path, required=True, help='MobileSafari.app from installed iOS Simulator RuntimeRoot/Applications')
p.add_argument('--work', type=Path, required=True)
p.add_argument('--device', required=True, help='Dedicated booted Simulator UUID; no personal Safari data')
a = p.parse_args()
for name in ['workspace_build', 'safari', 'work']:
    setattr(a, name, getattr(a, name).resolve())
if '/RuntimeRoot/Applications/MobileSafari.app' not in str(a.safari):
    p.error('Use the installed Simulator runtime Apple application, not a device IPA.')
env = {k:os.environ[k] for k in ['PATH','HOME','TMPDIR','USER','LOGNAME','DEVELOPER_DIR'] if k in os.environ}
def run(command, **kw):
    return subprocess.run([str(x) for x in command], env=env, check=True, **kw)
def copy(source, dest):
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(source, dest)

a.work.mkdir(parents=True, exist_ok=True)
cache = ROOT / '.contained-runtime'
cache.mkdir(exist_ok=True)
products = a.workspace_build / 'runtime/Build/Products/Debug-iphonesimulator'
for name in ['LiveContainerSwiftUI.framework', 'LiveContainerShared.framework', 'OpenSSL.framework']:
    copy(products / name, cache / name)
resources = cache / 'ContainedResources'
resources.mkdir(exist_ok=True)
guest = resources / 'MobileSafari.app'
copy(a.safari, guest)
binary = guest / 'MobileSafari'
data = bytearray(binary.read_bytes())
header = list(struct.unpack_from('<8I', data))
if header[0] != 0xfeedfacf or header[1] != 0x100000c or header[3] != 2:
    raise SystemExit('Expected unmodified arm64 Simulator executable')
original_hash = hashlib.sha256(data).hexdigest()
commands, offset, entry = [], 32, None
for _ in range(header[4]):
    command, size = struct.unpack_from('<II', data, offset)
    block = bytearray(data[offset:offset+size])
    if command == 0x2c and struct.unpack_from('<I',block,16)[0]:
        raise SystemExit('Encrypted application cannot be used')
    if command == 0x80000028:
        entry = struct.unpack_from('<Q',block,8)[0]
    if command == 0x19 and bytes(block[8:24]).rstrip(b'\0') == b'__PAGEZERO':
        struct.pack_into('<QQ', block,24,0xffffc000,0x4000)
    if command not in [0xe,0x2a]:
        commands.append(block)
    offset += size
def dylib(command, name):
    text = name.encode() + b'\0'
    size = (24+len(text)+7)//8*8
    return struct.pack('<6I',command,size,24,0,0x10000,0x10000)+text+b'\0'*(size-24-len(text))
commands += [dylib(0xd,'MobileSafari'),dylib(0xc,'@loader_path/P')]
table = b''.join(commands)
if entry is None or 32+len(table)>entry:
    raise SystemExit('Insufficient Mach-O command padding; refusing to overwrite code')
header[3],header[4],header[5],header[6] = 6,len(commands),len(table),(header[6]|0x100000)&~0x200000
struct.pack_into('<8I',data,0,*header)
data[32:entry] = table+b'\0'*(entry-32-len(table))
binary.write_bytes(data)
shutil.copyfile(products/'TweakLoader.dylib',guest/'P')
metadata = {'LCOrignalBundleIdentifier':'com.apple.mobilesafari','LCDataUUID':'Poki-Safari-Isolation',
            'dontSign':True,'LCPatchRevision':7,'LabNoSubstrate':True,
            'dontInjectTweakLoader':False,'dontLoadTweakLoader':False,
            'PKWBuildHash':hashlib.sha256(data).hexdigest(),
            'LCContainers':[{'name':'Dedicated Simulator Safari','folderName':'Poki-Safari-Isolation'}]}
(guest/'LCAppInfo.plist').write_bytes(plistlib.dumps(metadata))
workspace_app = Path(json.loads((a.workspace_build/'build-info.json').read_text())['product'])
shutil.copyfile(workspace_app/'WorkspaceResources/WorkspaceBridge.dylib',resources/'WorkspaceBridge.dylib')
copy(workspace_app/'WorkspaceResources/Licenses',resources/'Licenses')
(resources/'NOTICE.txt').write_text('Experimental original Poki + LiveContainer. Source: https://github.com/zealton/poki/tree/dev/isolated-ios-agent\nApple MobileSafari is imported locally from the installed Simulator runtime; do not redistribute it.\n')
run(['xattr','-cr',cache])
run(['codesign','--force','--sign','-',guest/'P'])
run(['codesign','--force','--sign','-',guest])
run(['xcodegen','generate','--spec','project-contained.yml'],cwd=ROOT)
with (a.work/'build.log').open('w') as log:
    result = subprocess.run(['xcodebuild','build-for-testing','-project',str(ROOT/'PokiContained.xcodeproj'),
        '-scheme','Poki','-configuration','Debug','-destination','id='+a.device,
        '-derivedDataPath',str(a.work/'derived'),'-disableAutomaticPackageResolution','CODE_SIGNING_ALLOWED=NO',
        'POKI_BUNDLE_ID=app.zealton.poki','POKI_APP_GROUP=group.app.zealton.poki','ARCHS=arm64'],
        env=env,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit('Build failed; inspect '+str(a.work/'build.log'))
app = Path(tempfile.mkdtemp(prefix='poki-contained-'))/'Poki.app'
copy(a.work/'derived/Build/Products/Debug-iphonesimulator/Poki.app',app)
copy(products/'LiveProcess.appex',app/'PlugIns/LiveProcess.appex')
info = app/'PlugIns/LiveProcess.appex/Info.plist'
value = plistlib.loads(info.read_bytes());value['CFBundleIdentifier']='app.zealton.poki.LiveProcess'
info.write_bytes(plistlib.dumps(value))
run(['xattr','-cr',app])
for binary in app.rglob('*.dylib'):
    run(['codesign','--force','--sign','-',binary])
bundles = [x for x in app.rglob('*') if x.is_dir() and x.suffix in ['.framework','.appex','.app','.xctest']]
for bundle in sorted(bundles,key=lambda x:len(x.parts),reverse=True):
    run(['codesign','--force','--sign','-',bundle])
run(['codesign','--force','--sign','-',app])
run(['xcrun','simctl','install',a.device,app])
(a.work/'build-info.json').write_text(json.dumps({'app':str(app),'device':a.device,
    'sourceSafariSHA256':original_hash,'transformedBeforeSigningSHA256':metadata['PKWBuildHash'],
    'packagedSafariSHA256':hashlib.sha256((app/'ContainedResources/MobileSafari.app/MobileSafari').read_bytes()).hexdigest(),
    'originalPoki':True,'modelProvider':'original Poki ModelKeys / OpenRouter','physicalDeviceTested':False},indent=2)+'\n')
print('Installed original Poki with experimental contained Safari:',app)
