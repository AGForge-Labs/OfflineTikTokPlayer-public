"""Generate the checked-in Xcode project without requiring third-party project tools."""
from pathlib import Path
import argparse
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / "ios"
APP = "OfflineTikTokPlayer"


def identity(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def encode(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + encode(str(k)) + " = " + encode(v, depth + 1) + ";\n" for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (depth + 1) + encode(v, depth + 1) + ",\n" for v in value) + indent + ")"
    if isinstance(value, int): return str(value)
    return json.dumps(value, ensure_ascii=True)


def generate():
    objects = {}
    def add(object_name, isa, **fields):
        key = identity(object_name)
        objects[key] = dict(isa=isa, **fields)
        return key

    build_sources = {APP: [], APP + "Tests": [], APP + "UITests": []}
    resources = {name: [] for name in build_sources}
    def group(path, target):
        children = []
        for file in sorted(path.iterdir()):
            if file.is_dir() and file.suffix != ".xcassets": children.append(group(file, target)); continue
            if file.name.startswith("."): continue
            filetype = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
                        ".xcprivacy": "text.xml", ".xcassets": "folder.assetcatalog", ".mp4": "file", ".mp3": "audio.mp3", ".svg": "image.svg"}.get(file.suffix, "text")
            ref = add("file:" + file.relative_to(ROOT).as_posix(), "PBXFileReference", lastKnownFileType=filetype, path=file.name, sourceTree="<group>")
            children.append(ref)
            if file.suffix == ".swift": build_sources[target].append(add("source:" + file.relative_to(ROOT).as_posix(), "PBXBuildFile", fileRef=ref))
            if file.suffix in (".xcassets", ".xcprivacy", ".mp4", ".mp3"):
                resources[target].append(add("resource:" + file.relative_to(ROOT).as_posix(), "PBXBuildFile", fileRef=ref))
        return add("group:" + path.relative_to(ROOT).as_posix(), "PBXGroup", children=children, path=path.name, sourceTree="<group>")

    source_groups = [group(ROOT / target, target) for target in build_sources]
    products = []
    for name in build_sources:
        products.append(add("product:" + name, "PBXFileReference", explicitFileType="wrapper.application" if name == APP else "wrapper.cfbundle",
                            includeInIndex=0, path=name + (".app" if name == APP else ".xctest"), sourceTree="BUILT_PRODUCTS_DIR"))
    products_group = add("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
    main_group = add("main", "PBXGroup", children=source_groups + [products_group], sourceTree="<group>")
    local = add("package:core", "XCLocalSwiftPackageReference", relativePath="PlayerCore")
    msal = add("package:msal", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/AzureAD/microsoft-authentication-library-for-objc",
               requirement=dict(kind="exactVersion", version="2.16.0"))
    core_product = add("product:core", "XCSwiftPackageProductDependency", package=local, productName="PlayerCore")
    msal_product = add("product:msal", "XCSwiftPackageProductDependency", package=msal, productName="MSAL")
    framework_files = [add("link:core", "PBXBuildFile", productRef=core_product), add("link:msal", "PBXBuildFile", productRef=msal_product)]

    def configurations(name, common):
        refs = []
        for configuration in ("Debug", "Release"):
            settings = dict(common)
            settings.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if configuration == "Debug" else "-O",
                            ONLY_ACTIVE_ARCH="YES" if configuration == "Debug" else "NO")
            if configuration == "Debug": settings.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)")
            refs.append(add("config:" + name + configuration, "XCBuildConfiguration", buildSettings=settings, name=configuration))
        return add("configs:" + name, "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    base = dict(IPHONEOS_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="5.0", SDKROOT="iphoneos", CLANG_ENABLE_MODULES="YES",
                SWIFT_STRICT_CONCURRENCY="complete", ENABLE_USER_SCRIPT_SANDBOXING="YES", DEVELOPMENT_TEAM="")
    project_configs = configurations("project", base)
    targets = []
    for index, name in enumerate(build_sources):
        settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="dev.galaxybigbird." + name,
                        TARGETED_DEVICE_FAMILY="1", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", CODE_SIGN_STYLE="Automatic",
                        MARKETING_VERSION="1.0", CURRENT_PROJECT_VERSION="1", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"],
                        GENERATE_INFOPLIST_FILE="YES")
        deps = []
        if name == APP:
            settings.update(INFOPLIST_FILE=APP + "/Support/Info.plist", GENERATE_INFOPLIST_FILE="NO",
                            CODE_SIGN_ENTITLEMENTS=APP + "/Support/OfflineTikTokPlayer.entitlements",
                            ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME="AccentColor")
        else:
            proxy = add("proxy:" + name, "PBXContainerItemProxy", containerPortal=identity("project"), proxyType=1,
                        remoteGlobalIDString=identity("target:" + APP), remoteInfo=APP)
            deps = [add("dependency:" + name, "PBXTargetDependency", target=identity("target:" + APP), targetProxy=proxy)]
            if name.endswith("UITests"): settings.update(TEST_TARGET_NAME=APP)
            else: settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/" + APP + ".app/" + APP, BUNDLE_LOADER="$(TEST_HOST)")
        phases = [add("sources:" + name, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_sources[name], runOnlyForDeploymentPostprocessing=0),
                  add("frameworks:" + name, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=framework_files if name == APP else [], runOnlyForDeploymentPostprocessing=0),
                  add("resources:" + name, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources[name], runOnlyForDeploymentPostprocessing=0)]
        targets.append(add("target:" + name, "PBXNativeTarget", buildConfigurationList=configurations(name, settings), buildPhases=phases,
            buildRules=[], dependencies=deps, name=name, productName=name, productReference=products[index],
            packageProductDependencies=[core_product, msal_product] if name == APP else [],
            productType="com.apple.product-type.application" if name == APP else ("com.apple.product-type.bundle.ui-testing" if name.endswith("UITests") else "com.apple.product-type.bundle.unit-test")))
    project = add("project", "PBXProject", attributes=dict(LastUpgradeCheck="2600", BuildIndependentTargetsInParallel="YES",
                  TargetAttributes={targets[0]: dict(SystemCapabilities={"com.apple.BackgroundModes": dict(enabled=1), "com.apple.Keychain": dict(enabled=1)}),
                                    targets[1]: dict(TestTargetID=targets[0]), targets[2]: dict(TestTargetID=targets[0])}),
                  buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
                  knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=products_group,
                  projectDirPath="", projectRoot="", targets=targets, packageReferences=[local, msal])
    raw = "// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n"
    scheme = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    def reference(parent, target):
        return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=identity("target:" + target),
            BuildableName=target + (".app" if target == APP else ".xctest"), BlueprintName=target, ReferencedContainer="container:" + APP + ".xcodeproj")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    reference(entry, APP)
    tests = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                          selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testables = ET.SubElement(tests, "Testables")
    for name in [APP + "Tests", APP + "UITests"]: reference(ET.SubElement(testables, "TestableReference", skipped="NO"), name)
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), APP)
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), APP)
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(scheme, space="  ")
    return raw, '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(scheme, encoding="unicode") + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    raw, scheme = generate()
    outputs = {ROOT / (APP + ".xcodeproj") / "project.pbxproj": raw,
               ROOT / (APP + ".xcodeproj") / "xcshareddata" / "xcschemes" / (APP + ".xcscheme"): scheme}
    for path, value in outputs.items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != value: raise SystemExit(f"Regenerate Xcode project: {path.name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(value, encoding="utf-8", newline="\n")
    print("Xcode project references are current" if args.check else "Generated Xcode project and shared scheme")


if __name__ == "__main__": main()
