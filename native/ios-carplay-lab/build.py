# SPDX-License-Identifier: AGPL-3.0-only
# -*- coding: utf-8 -*-
from pathlib import Path
import os,plistlib,subprocess,tempfile,json
root=Path(__file__).resolve().parent
build=Path(tempfile.mkdtemp(prefix='poki-carplay-build-'))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
base=['xcrun','clang','-isysroot',sdk,'-target','arm64-apple-ios18.0-simulator','-fobjc-arc','-fmodules','-framework','UIKit','-framework','Foundation']
bridge=build/'SceneBridge.dylib'
subprocess.run(base+['-dynamiclib',str(root/'SceneBridge.m'),'-o',str(bridge)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(bridge)],check=True)
app=build/'DomainTarget.app';app.mkdir()
config={'UISceneClassName':'UIWindowScene','UISceneDelegateClassName':'DomainScene','UISceneConfigurationName':'Default'}
info={'CFBundleIdentifier':'local.poki.DomainTarget','CFBundleExecutable':'DomainTarget','CFBundleName':'DomainTarget','CFBundleDisplayName':'Domain Target','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'MinimumOSVersion':'18.0','UIDeviceFamily':[1,2],'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':True,'UISceneConfigurations':{role:[config] for role in ['UIWindowSceneSessionRoleApplication','UIWindowSceneSessionRoleCarPlay','UIWindowSceneSessionRoleExternalDisplayNonInteractive']}}}
info['SBStarkLaunchModes']=['Default']
info['CFBundleSupportedPlatforms']=['iPhoneSimulator']
(app/'Info.plist').write_bytes(plistlib.dumps(info))
ent={'get-task-allow':True,'SBStarkCapable':True,'CARCapableApp':True}
ep=build/'simulator.entitlements';ep.write_bytes(plistlib.dumps(ent))
# Simulator entitlements are a Mach-O section, not restricted host entitlements.
subprocess.run(base+[str(root/'DomainTarget.m'),'-Wl,-sectcreate,__TEXT,__entitlements,'+str(ep),'-o',str(app/'DomainTarget')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
(root/'build-path.txt').write_text(str(build))
print(json.dumps({'build':str(build),'app':str(app),'bridge':str(bridge)}))
