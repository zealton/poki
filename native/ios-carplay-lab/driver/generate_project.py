#!/usr/bin/env python3
"""Generate the dependency-free Xcode project. No XcodeGen / Ruby gems required."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
objects = {}
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def obj(key, **fields):
    k = uid(key); objects[k] = fields; return k
def quote(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
def serialize(v, indent=0):
    if isinstance(v, dict):
        return '{\n' + ''.join('\t'*(indent+1)+quote(k)+' = '+serialize(x,indent+1)+';\n' for k,x in v.items())+'\t'*indent+'}'
    if isinstance(v,list): return '(' + ', '.join(serialize(x,indent) for x in v) + ')'
    return quote(v)

products=[]; children=[]; targets=[]
base={"SDKROOT":"iphoneos", "IPHONEOS_DEPLOYMENT_TARGET":"18.0", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "CLANG_ENABLE_MODULES":"YES", "CLANG_ENABLE_OBJC_ARC":"YES", "CODE_SIGN_STYLE":"Automatic", "TARGETED_DEVICE_FAMILY":"1,2", "ENABLE_USER_SCRIPT_SANDBOXING":"YES", "DEBUG_INFORMATION_FORMAT":"dwarf", "GCC_PREPROCESSOR_DEFINITIONS":["$(inherited)","DEBUG=1"], "GCC_OPTIMIZATION_LEVEL":"0"}
def configs(name,settings):
    refs=[]
    for mode in ["Debug","Release"]:
        refs.append(obj(name+mode,isa="XCBuildConfiguration",name=mode,buildSettings=settings))
    return obj(name+"configs",isa="XCConfigurationList",buildConfigurations=refs,defaultConfigurationIsVisible="0",defaultConfigurationName="Debug")

for name in ["TypingPad","AXProbeTests"]:
    test=name=="AXProbeTests"
    source_builds=[]
    for path in sorted((ROOT/'Sources'/name).glob('*.m')):
        rel=str(path.relative_to(ROOT))
        file=obj(rel+"src",isa="PBXFileReference",lastKnownFileType="sourcecode.c.objc",path=rel,sourceTree="<group>")
        children.append(file)
        source_builds.append(obj(rel+"build",isa="PBXBuildFile",fileRef=file))
    for path in sorted((ROOT/'Sources'/name).glob('*.h')):
        rel=str(path.relative_to(ROOT))
        children.append(obj(rel+"header",isa="PBXFileReference",lastKnownFileType="sourcecode.c.h",path=rel,sourceTree="<group>"))
    src=obj(name+"sources",isa="PBXSourcesBuildPhase",buildActionMask="2147483647",files=source_builds,runOnlyForDeploymentPostprocessing="0")
    frameworks=obj(name+"frameworks",isa="PBXFrameworksBuildPhase",buildActionMask="2147483647",files=[],runOnlyForDeploymentPostprocessing="0")
    resources=obj(name+"resources",isa="PBXResourcesBuildPhase",buildActionMask="2147483647",files=[],runOnlyForDeploymentPostprocessing="0")
    product=obj(name+"product",isa="PBXFileReference",explicitFileType="wrapper.cfbundle" if test else "wrapper.application",includeInIndex="0",path=name+(".xctest" if test else ".app"),sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    settings={**base,"PRODUCT_NAME":"$(TARGET_NAME)","PRODUCT_BUNDLE_IDENTIFIER":"local.axlab."+name,"GENERATE_INFOPLIST_FILE":"YES", "INFOPLIST_KEY_CFBundleDisplayName":name,"INFOPLIST_KEY_UILaunchScreen_Generation":"YES"}
    if test:
        settings.update({"TEST_TARGET_NAME":"TypingPad", "FRAMEWORK_SEARCH_PATHS":["$(inherited)","$(PLATFORM_DIR)/Developer/Library/Frameworks"],"OTHER_LDFLAGS":["$(inherited)","-framework","XCTest","-framework","XCUIAutomation"],"LD_RUNPATH_SEARCH_PATHS":["$(inherited)","@executable_path/Frameworks","@loader_path/Frameworks","$(PLATFORM_DIR)/Developer/Library/Frameworks"]})
    else: settings["OTHER_LDFLAGS"]=["$(inherited)","-framework","UIKit"]
    deps=[]
    if test:
        for dep in ["TypingPad"]:
            proxy=obj(dep+"proxy",isa="PBXContainerItemProxy",containerPortal=uid("project"),proxyType="1",remoteGlobalIDString=uid(dep+"target"),remoteInfo=dep)
            deps.append(obj(dep+"dep",isa="PBXTargetDependency",target=uid(dep+"target"),targetProxy=proxy))
    targets.append(obj(name+"target",isa="PBXNativeTarget",buildConfigurationList=configs(name,settings),buildPhases=[src,frameworks,resources],buildRules=[],dependencies=deps,name=name,productName=name,productReference=product,productType="com.apple.product-type.bundle.ui-testing" if test else "com.apple.product-type.application"))

pg=obj("products",isa="PBXGroup",children=products,name="Products",sourceTree="<group>")
group=obj("group",isa="PBXGroup",children=children+[pg],sourceTree="<group>")
project=obj("project",isa="PBXProject",attributes={"BuildIndependentTargetsInParallel":"YES","LastUpgradeCheck":"2620","TargetAttributes":{uid("AXProbeTeststarget"):{"TestTargetID":uid("TypingPadtarget")}}},buildConfigurationList=configs("project",base),compatibilityVersion="Xcode 14.0",developmentRegion="en",hasScannedForEncodings="0",knownRegions=["en","Base"],mainGroup=group,productRefGroup=pg,projectDirPath="",projectRoot="",targets=targets)
out=ROOT/"AXIsolationDemo.xcodeproj"; (out/"xcshareddata/xcschemes").mkdir(parents=True,exist_ok=True)
(out/"project.pbxproj").write_text('// !$*UTF8*$!\n'+serialize({"archiveVersion":"1","classes":{},"objectVersion":"56","objects":objects,"rootObject":project})+'\n')
entries=''.join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(n+"target")}" BuildableName="{n+(".xctest" if n=="AXProbeTests" else ".app")}" BlueprintName="{n}" ReferencedContainer="container:AXIsolationDemo.xcodeproj"/></BuildActionEntry>' for n in ["TypingPad","AXProbeTests"])
testref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("AXProbeTeststarget")}" BuildableName="AXProbeTests.xctest" BlueprintName="AXProbeTests" ReferencedContainer="container:AXIsolationDemo.xcodeproj"/>'
(out/"xcshareddata/xcschemes/AXIsolationDemo.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.7"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{testref}</TestableReference></Testables></TestAction></Scheme>''')
print(out)
