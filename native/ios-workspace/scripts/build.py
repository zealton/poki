#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build Poki Workspace: Simulator ZIP or unsigned device IPA.
Keys are entered in the app; this script never accepts or reads an API key.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIN = '9d6ea09b05afa2c8fc537c372795a294db631311'
OPENSSL = '623c84da314e85363236507ca38a4bde65df21c3'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work', type=Path, default=ROOT / '.build')
parser.add_argument('--runtime', type=Path)
parser.add_argument('--platform', choices=['simulator', 'device'], default='simulator')
parser.add_argument('--device', help='Install on this booted Simulator UUID')
args = parser.parse_args()
if args.device and args.platform != 'simulator':
    parser.error('--device installs only to Simulator; device IPA requires your own signing.')
args.work = args.work.resolve()
args.work.mkdir(parents=True, exist_ok=True)
runtime = (args.runtime or args.work / 'LiveContainer').resolve()
simulator = args.platform == 'simulator'
sdk = 'iphonesimulator' if simulator else 'iphoneos'
variant = 'ios-arm64_x86_64-simulator' if simulator else 'ios-arm64'
products = 'Debug-' + sdk


def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, **kwargs)


def output(command):
    return subprocess.check_output([str(x) for x in command], text=True).strip()


def build(command, log):
    print('Building ' + log, flush=True)
    with (args.work / log).open('w') as stream:
        try:
            run(command, stdout=stream, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print((args.work / log).read_text()[-10000:])
            raise


if not runtime.exists():
    run(['git', 'clone', '--filter=blob:none', '--depth', '1', '--no-tags', '--no-checkout',
         'https://github.com/LiveContainer/LiveContainer.git', runtime])
    run(['git', '-C', runtime, 'fetch', '--depth', '1', 'origin', PIN])
    run(['git', '-C', runtime, 'checkout', '--detach', PIN])
if output(['git', '-C', runtime, 'rev-parse', 'HEAD']) != PIN:
    raise SystemExit('Use the pinned LiveContainer revision; refusing to modify this checkout.')
patch = ROOT / 'scripts/runtime.patch'
reverse = subprocess.run(['git', '-C', str(runtime), 'apply', '--unidiff-zero', '--reverse', '--check', str(patch)],
                         capture_output=True)
if reverse.returncode:
    run(['git', '-C', runtime, 'apply', '--unidiff-zero', '--check', patch])
    run(['git', '-C', runtime, 'apply', '--unidiff-zero', patch])
# Refuse accidental source duplicates, e.g. files created by cloud sync conflicts.
untracked = output(['git', '-C', runtime, 'ls-files', '--others', '--exclude-standard']).splitlines()
for name in untracked:
    if name.endswith(('.m', '.mm', '.c', '.swift')) and not name.startswith('LiveContainerSwiftUI/Workspace/'):
        raise SystemExit('Unexpected runtime source; preserve it outside the build checkout: ' + name)
if not (runtime / 'litehook/src').exists():
    run(['git', '-C', runtime, 'submodule', 'update', '--init', '--depth', '1', 'litehook'])
ssl = runtime / 'OpenSSL/Frameworks/OpenSSL.xcframework'
if not (ssl / variant).exists():
    cache = args.work / 'dependencies/OpenSSL'
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        run(['git', 'clone', '--filter=blob:none', '--depth', '1', '--no-tags', '--no-checkout',
             'https://github.com/krzyzanowskim/OpenSSL.git', cache])
        run(['git', '-C', cache, 'sparse-checkout', 'init', '--no-cone'])
    run(['git', '-C', cache, 'sparse-checkout', 'set',
         '/Frameworks/OpenSSL.xcframework/Info.plist',
         '/Frameworks/OpenSSL.xcframework/ios-arm64_x86_64-simulator/',
         '/Frameworks/OpenSSL.xcframework/ios-arm64/'])
    run(['git', '-C', cache, 'fetch', '--depth', '1', 'origin', OPENSSL])
    run(['git', '-C', cache, 'checkout', OPENSSL])
    ssl.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cache / 'Frameworks/OpenSSL.xcframework/Info.plist', ssl / 'Info.plist')
    shutil.copytree(cache / 'Frameworks/OpenSSL.xcframework' / variant, ssl / variant)
if Path(output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])).name != 'MacOSX26.2.sdk':
    raise SystemExit('This pinned runtime patch currently targets Xcode 26.2.')
overlay = runtime / 'LiveContainerSwiftUI/Workspace'
overlay.mkdir(exist_ok=True)
for folder in ['Shared', 'Host']:
    for source in (ROOT / folder).glob('*.[hm]'):
        shutil.copyfile(source, overlay / source.name)
run(['python3', ROOT / 'scripts/generate-project.py'])
common = ['-sdk', sdk, '-configuration', 'Debug', 'CODE_SIGNING_ALLOWED=NO',
          'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES']
build(['xcodebuild', '-project', ROOT / 'PokiWorkspaceHelpers.xcodeproj',
       '-scheme', 'PokiWorkspaceHelpers', '-derivedDataPath', args.work / 'helpers',
       *common, 'build'], 'helpers-build.log')
build(['xcodebuild', '-project', runtime / 'LiveContainer.xcodeproj', '-scheme', 'LiveContainer',
       '-derivedDataPath', args.work / 'runtime', *common, 'DEVELOPMENT_ASSET_PATHS=', 'build'],
      'runtime-build.log')
# Stage outside cloud-synced folders before signing: FinderInfo can be re-added in Documents.
staging = Path(tempfile.mkdtemp(prefix='poki-workspace-'))
app = staging / 'Payload/LiveContainer.app' if not simulator else staging / 'LiveContainer.app'
shutil.copytree(args.work / 'runtime/Build/Products' / products / 'LiveContainer.app', app)
resources = app / 'WorkspaceResources'
shutil.rmtree(resources, ignore_errors=True)
resources.mkdir()
licenses = resources / 'Licenses'
licenses.mkdir()
for source, name in [(ROOT.parents[1] / 'LICENSE', 'Poki-AGPL.txt'),
                     (runtime / 'LICENSE', 'LiveContainer-AGPL.txt'),
                     (runtime / 'litehook/LICENSE', 'litehook-LICENSE.txt'),
                     (ROOT / 'Licenses/OpenSSL-LICENSE.txt', 'OpenSSL-LICENSE.txt')]:
    if source.exists():
        shutil.copyfile(source, licenses / name)
(resources / 'NOTICE.txt').write_text(
    'Poki Workspace: AGPL-3.0-only. Corresponding source and build instructions:\n'
    'https://github.com/zealton/poki/tree/dev/isolated-ios-agent/native/ios-workspace\n'
    'LiveContainer runtime: https://github.com/LiveContainer/LiveContainer/tree/' + PIN + '\n'
    'OpenSSL build dependency: https://github.com/krzyzanowskim/OpenSSL/tree/' + OPENSSL + '\n'
)
for name in ['PokiWorker', 'PokiFixture']:
    destination = resources / (name + '.app')
    shutil.copytree(args.work / 'helpers/Build/Products' / products / (name + '.app'), destination)
    if simulator:
        run(['python3', ROOT / 'scripts/patch-helper.py', destination / name])
    worker = name == 'PokiWorker'
    metadata = {
        'LCOrignalBundleIdentifier': 'app.zealton.poki.' + name,
        'PKWBuildHash': hashlib.sha256((destination / name).read_bytes()).hexdigest(),
        'LCDataUUID': 'PKW-' + name,
        'dontSign': simulator,
        'LCPatchRevision': 7 if simulator else 0,
        'LCContainers': [{'name': 'Workspace', 'folderName': 'PKW-' + name}],
        'LabNoSubstrate': True,
        'dontInjectTweakLoader': worker,
        'dontLoadTweakLoader': worker,
    }
    (destination / 'LCAppInfo.plist').write_bytes(plistlib.dumps(metadata))
    run(['xattr', '-cr', destination])
    run(['codesign', '--force', '--sign', '-', destination])
target = 'arm64-apple-ios18.0-simulator' if simulator else 'arm64-apple-ios18.0'
build(['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot',
       output(['xcrun', '--sdk', sdk, '--show-sdk-path']), '-fobjc-arc', '-dynamiclib',
       '-I', ROOT / 'Shared', ROOT / 'GuestBridge/GuestBridge.m', ROOT / 'Shared/WorkspaceIPC.m',
       ROOT / 'Shared/WorkspacePolicy.m', '-framework', 'UIKit', '-framework', 'Foundation',
       '-framework', 'QuartzCore', '-framework', 'CoreGraphics', '-framework', 'WebKit',
       '-o', resources / 'WorkspaceBridge.dylib'], 'bridge-build.log')
run(['codesign', '--force', '--sign', '-', resources / 'WorkspaceBridge.dylib'])
run(['xattr', '-cr', app])
if simulator:
    # Do not invent restricted application-identifier / Keychain entitlements for Simulator.
    run(['codesign', '--force', '--sign', '-', app])
    archive = args.work / 'PokiWorkspace-Simulator.zip'
    run(['ditto', '-c', '-k', '--norsrc', '--keepParent', app, archive])
else:
    archive = args.work / 'PokiWorkspace-unsigned.ipa'
    run(['ditto', '-c', '-k', '--norsrc', '--keepParent', staging / 'Payload', archive])
(args.work / 'build-info.json').write_text(json.dumps({
    'product': str(app), 'archive': str(archive), 'runtime': PIN,
    'platform': 'arm64 iOS Simulator' if simulator else 'arm64 iPhone (unsigned, untested)',
    'model': 'deepseek/deepseek-v4.1-flash-1017',
}, indent=2) + '\n')
if args.device:
    run(['xcrun', 'simctl', 'install', args.device, app])
    run(['xcrun', 'simctl', 'install', args.device,
         args.work / 'helpers/Build/Products' / products / 'TypingPad.app'])
print(archive)
