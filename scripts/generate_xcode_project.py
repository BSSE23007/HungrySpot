"""Deterministic native app project; local Swift package supplies the core library.

Run again after adding/removing app Swift files. No third-party Python packages.
"""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

objects = []
def obj(name, value):
    objects.append(f'\t\t{ident(name)} = {{ {value} }};')
    return ident(name)
swift = sorted((ROOT / 'Sources/HungrySpot').rglob('*.swift'))
refs, builds = [], []
for path in swift:
    rel = path.relative_to(ROOT).as_posix()
    refs.append(obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(rel)}; sourceTree = "<group>";'))
    builds.append(obj('build:' + rel, f'isa = PBXBuildFile; fileRef = {ident(rel)};'))
branding = 'Sources/HungrySpot/Resources/Branding.jpg'
refs.append(obj(branding, f'isa = PBXFileReference; lastKnownFileType = image.jpeg; path = {quote(branding)}; sourceTree = "<group>";'))
brand_build = obj('brandbuild', f'isa = PBXBuildFile; fileRef = {ident(branding)};')
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "The Hungry Spot.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
obj('group', f'isa = PBXGroup; children = ({",".join(refs + [products])},); sourceTree = "<group>";')
obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
core = obj('core', f'isa = XCSwiftPackageProductDependency; package = {ident("package")}; productName = HungrySpotCore;')
corebuild = obj('corebuild', f'isa = PBXBuildFile; productRef = {core};')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({brand_build},); runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({corebuild},); runOnlyForDeploymentPostprocessing = 0;')
for config in ['Debug', 'Release']:
    project_settings = 'CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 12.0; SDKROOT = macosx; SWIFT_VERSION = 5.0;'
    target_settings = 'CODE_SIGN_STYLE = Automatic; ENABLE_HARDENED_RUNTIME = YES; INFOPLIST_FILE = Configuration/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = com.thehungryspot.pos; PRODUCT_NAME = "The Hungry Spot"; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 12.0; GENERATE_INFOPLIST_FILE = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; OTHER_LDFLAGS = "$(inherited) -lsqlite3";'
    if config == 'Debug':
        target_settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
    else:
        target_settings += ' SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O";'
    obj('project' + config, f'isa = XCBuildConfiguration; buildSettings = {{ {project_settings} }}; name = {config};')
    obj('target' + config, f'isa = XCBuildConfiguration; buildSettings = {{ {target_settings} }}; name = {config};')
for level in ['project', 'target']:
    obj(level + 'configs', f'isa = XCConfigurationList; buildConfigurations = ({ident(level + "Debug")},{ident(level + "Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("targetconfigs")}; buildPhases = ({ident("sources")},{ident("frameworks")},{ident("resources")},); buildRules = (); dependencies = (); name = HungrySpot; packageProductDependencies = ({core},); productName = "The Hungry Spot"; productReference = {product}; productType = "com.apple.product-type.application";')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1420; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {ident("group")}; packageReferences = ({ident("package")},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({ident("target")},);')
project = ROOT / 'HungrySpot.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ident("project")};\n}}\n', encoding='utf-8')
scheme_dir = project / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="The Hungry Spot.app" BlueprintName="HungrySpot" ReferencedContainer="container:HungrySpot.xcodeproj"/>'
(scheme_dir / 'HungrySpot.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1420" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding='utf-8')
print(f'Generated native project with {len(swift)} app Swift files.')
