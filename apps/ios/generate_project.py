#!/usr/bin/env python3
"""Generate the Xcode project; source folders synchronize in Xcode."""
from pathlib import Path

root = Path(__file__).resolve().parent
project = root / "Roast.xcodeproj"
project.mkdir(exist_ok=True)
objects = []

def item(identifier, body):
    objects.append(f"\t\t{identifier} = {{ {body} }};")

def ident(value):
    return f"{value:024X}"

project_id, main_group, products, project_configs = map(ident, [1, 2, 3, 4])
google_package, google_product, google_swift_product = map(ident, [500, 501, 502])
targets = [
    dict(name="Roast", folder="Roast", product="Roast.app", kind="application", base=100, bundle="$(ROAST_APP_BUNDLE_ID)"),
    dict(name="RoastTests", folder="RoastTests", product="RoastTests.xctest", kind="bundle.unit-test", base=300, bundle="$(ROAST_APP_BUNDLE_ID).tests"),
    dict(name="RoastUITests", folder="RoastUITests", product="RoastUITests.xctest", kind="bundle.ui-testing", base=400, bundle="$(ROAST_APP_BUNDLE_ID).uitests"),
]
item(project_id, f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700;
TargetAttributes = {{ {ident(100)} = {{ SystemCapabilities = {{ com.apple.SignInWithApple = {{ enabled = 1; }}; }}; }}; }}; }};
buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en;
hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group};
preferredProjectObjectVersion = 77; productRefGroup = {products}; projectDirPath = ""; projectRoot = "";
packageReferences = ({google_package});
targets = ({', '.join(ident(t['base']) for t in targets)});''')
item(main_group, f"isa = PBXGroup; children = ({', '.join(ident(t['base'] + 1) for t in targets)}, {products}); sourceTree = \"<group>\";")
item(products, f"isa = PBXGroup; children = ({', '.join(ident(t['base'] + 2) for t in targets)}); name = Products; sourceTree = \"<group>\";")
item(project_configs, f"isa = XCConfigurationList; buildConfigurations = ({ident(5)}, {ident(6)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
for number, name in [(5, "Debug"), (6, "Release")]:
    debug = name == "Debug"
    settings = f'''CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES;
IPHONEOS_DEPLOYMENT_TARGET = 26.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0;
SWIFT_STRICT_CONCURRENCY = minimal; ENABLE_USER_SCRIPT_SANDBOXING = YES;
DEVELOPMENT_TEAM = 37P86CG9SS;
ROAST_APP_BUNDLE_ID = com.furqanali.roast;
ROAST_MEDIA_SERVICE_URL = "https://api.recordpov.app";
ROAST_APPLE_SIGN_IN_ENABLED = YES; ROAST_GOOGLE_REVERSED_CLIENT_ID = "com.googleusercontent.apps.1001069179671-mvl07vu7kdrebl4atf9hjf2smqi4nrmm";
DEBUG_INFORMATION_FORMAT = {'dwarf' if debug else '"dwarf-with-dsym"'};
SWIFT_OPTIMIZATION_LEVEL = {'"-Onone"' if debug else '"-O"'};
SWIFT_ACTIVE_COMPILATION_CONDITIONS = {'"DEBUG $(inherited)"' if debug else '"APP_STORE $(inherited)"'};
GCC_PREPROCESSOR_DEFINITIONS = {'"DEBUG=1 $(inherited)"' if debug else '"$(inherited)"'};
ENABLE_TESTABILITY = {'YES' if debug else 'NO'};
ONLY_ACTIVE_ARCH = {'YES' if debug else 'NO'};'''
    item(ident(number), f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {name};')

for target in targets:
    base, name = target["base"], target["name"]
    phases = [ident(base + 3), ident(base + 4), ident(base + 5)]
    deps = []
    if name in ("RoastTests", "RoastUITests"):
        deps.append(ident(base + 12))
        item(ident(base + 11), f"isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {ident(100)}; remoteInfo = Roast;")
        item(ident(base + 12), f"isa = PBXTargetDependency; target = {ident(100)}; targetProxy = {ident(base + 11)};")
    item(ident(base), f'''isa = PBXNativeTarget; buildConfigurationList = {ident(base + 6)};
buildPhases = ({', '.join(phases)}); buildRules = (); dependencies = ({', '.join(deps)});
fileSystemSynchronizedGroups = ({ident(base + 1)}); name = {name}; productName = {name};
packageProductDependencies = ({f"{google_product}, {google_swift_product}" if name == "Roast" else ""});
productReference = {ident(base + 2)}; productType = "com.apple.product-type.{target['kind']}";''')
    item(ident(base + 1), f"isa = PBXFileSystemSynchronizedRootGroup; path = {target['folder']}; sourceTree = \"<group>\";")
    file_type = "wrapper.application" if target["kind"] == "application" else "wrapper.cfbundle"
    item(ident(base + 2), f'isa = PBXFileReference; explicitFileType = "{file_type}"; includeInIndex = 0; path = {target["product"]}; sourceTree = BUILT_PRODUCTS_DIR;')
    for offset, phase in [(3, "PBXSourcesBuildPhase"), (4, "PBXFrameworksBuildPhase"), (5, "PBXResourcesBuildPhase")]:
        files = f"{ident(503)}, {ident(504)}" if name == "Roast" and offset == 4 else ""
        item(ident(base + offset), f"isa = {phase}; buildActionMask = 2147483647; files = ({files}); runOnlyForDeploymentPostprocessing = 0;")
    item(ident(base + 6), f"isa = XCConfigurationList; buildConfigurations = ({ident(base + 7)}, {ident(base + 8)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    for offset, configuration in [(7, "Debug"), (8, "Release")]:
        settings = f'''PRODUCT_BUNDLE_IDENTIFIER = "{target['bundle']}"; PRODUCT_NAME = "$(TARGET_NAME)";
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "{'1' if name == "Roast" and configuration == "Release" else '1,2'}";
CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 1.0; CURRENT_PROJECT_VERSION = {2 if name == "Roast" else 1};
SWIFT_EMIT_LOC_STRINGS = YES;'''
        if name == "Roast":
            settings += '''INFOPLIST_FILE = Configuration/Info.plist; GENERATE_INFOPLIST_FILE = NO;
CODE_SIGN_ENTITLEMENTS = Configuration/Roast-Account.entitlements; ASSETCATALOG_COMPILER_APPICON_NAME = RecordPOV;
LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
        elif name == "RoastTests":
            settings += '''GENERATE_INFOPLIST_FILE = YES; BUNDLE_LOADER = "$(TEST_HOST)";
TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Roast.app/Roast";'''
        else:
            settings += 'GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = Roast;'
        item(ident(base + offset), f"isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {configuration};")

item(google_package, 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/google/GoogleSignIn-iOS"; requirement = { kind = exactVersion; version = 10.0.0; };')
item(google_product, f'isa = XCSwiftPackageProductDependency; package = {google_package}; productName = GoogleSignIn;')
item(google_swift_product, f'isa = XCSwiftPackageProductDependency; package = {google_package}; productName = GoogleSignInSwift;')
item(ident(503), f'isa = PBXBuildFile; productRef = {google_product};')
item(ident(504), f'isa = PBXBuildFile; productRef = {google_swift_product};')

(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {project_id};\n}}\n')
schemes = project / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)

def buildable(target):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(target["base"])}" BuildableName="{target["product"]}" BlueprintName="{target["name"]}" ReferencedContainer="container:Roast.xcodeproj"/>'

app = buildable(targets[0])
testables = ''.join(f'<TestableReference skipped="NO">{buildable(t)}</TestableReference>' for t in targets[1:])
(schemes / "Roast.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testables}</Testables><MacroExpansion>{app}</MacroExpansion></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
