# -*- coding: utf-8 -*-
"""生成 IfengAdmin.xcodeproj/project.pbxproj 与共享 scheme。

工程结构固定，用脚本生成可避免手写 pbxproj 的 UUID / 引用错误。
用法：python tools/make_xcodeproj.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = "IfengAdmin"
PROJECT = "IfengAdmin"

SOURCES = [
    ("App", "AppConfig.swift"),
    ("App", "ServerAddress.swift"),
    ("App", "KeychainStore.swift"),
    ("App", "AppState.swift"),
    ("App", "IfengAdminApp.swift"),
    ("Core", "Models.swift"),
    ("Core", "APIClient.swift"),
    ("Core", "RealtimeClient.swift"),
    ("Core", "ConversationListModel.swift"),
    ("Core", "ChatModel.swift"),
    ("Core", "ImagePreparer.swift"),
    ("Design", "LucideIcon.swift"),
    ("Design", "Theme.swift"),
    ("Features/Root", "RootView.swift"),
    ("Features/Login", "LoginView.swift"),
    ("Features/Conversations", "ConversationListScreen.swift"),
    ("Features/Chat", "ChatView.swift"),
    ("Features/Chat", "ChatMessageRow.swift"),
    ("Features/Chat", "VisitorInfoView.swift"),
    ("Features/Inbox", "InboxScreen.swift"),
    ("Features/Settings", "SettingsScreen.swift"),
]

_counter = {"build": 0, "file": 0, "group": 0}


def oid(kind):
    _counter[kind] += 1
    prefix = {"build": "A1", "file": "A2", "group": "A3"}[kind]
    return "%s%022X" % (prefix, _counter[kind])


BUILD_IDS = {}
FILE_IDS = {}
GROUP_IDS = {}

for folder, name in SOURCES:
    FILE_IDS[(folder, name)] = oid("file")
    BUILD_IDS[(folder, name)] = oid("build")

ASSET_ID = oid("file")
PLIST_ID = oid("file")
PRODUCT_ID = oid("file")
MAIN_GROUP = oid("group")
APP_GROUP = oid("group")
PRODUCTS_GROUP = oid("group")

TARGET_ID = "A40000000000000000000001"
PROJECT_ID = "A40000000000000000000002"
SOURCES_PHASE = "A40000000000000000000003"
FRAMEWORKS_PHASE = "A40000000000000000000004"
RESOURCES_PHASE = "A40000000000000000000005"
PROJECT_CONFIG_LIST = "A40000000000000000000006"
TARGET_CONFIG_LIST = "A40000000000000000000007"
PROJECT_DEBUG = "A40000000000000000000008"
PROJECT_RELEASE = "A40000000000000000000009"
TARGET_DEBUG = "A4000000000000000000000A"
TARGET_RELEASE = "A4000000000000000000000B"


def build_file_line(folder, name):
    return "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
        BUILD_IDS[(folder, name)], name, FILE_IDS[(folder, name)], name)


def file_ref_line(folder, name):
    return "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n" % (
        FILE_IDS[(folder, name)], name, name)


out = []
out.append("// !$*UTF8*$!\n{\n")
out.append("\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

# PBXBuildFile
out.append("\n/* Begin PBXBuildFile section */\n")
for folder, name in SOURCES:
    out.append(build_file_line(folder, name))
out.append("\t\t%s /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = %s /* Assets.xcassets */; };\n" % (
    "A50000000000000000000001", ASSET_ID))
out.append("/* End PBXBuildFile section */\n")

# PBXFileReference
out.append("\n/* Begin PBXFileReference section */\n")
for folder, name in SOURCES:
    out.append(file_ref_line(folder, name))
out.append("\t\t%s /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; };\n" % ASSET_ID)
out.append("\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };\n" % PLIST_ID)
out.append("\t\t%s /* IfengAdmin.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = IfengAdmin.app; sourceTree = BUILT_PRODUCTS_DIR; };\n" % PRODUCT_ID)
out.append("/* End PBXFileReference section */\n")

# PBXFrameworksBuildPhase
out.append("\n/* Begin PBXFrameworksBuildPhase section */\n")
out.append("\t\t%s /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n" % FRAMEWORKS_PHASE)
out.append("/* End PBXFrameworksBuildPhase section */\n")

# PBXGroup
folder_groups = {}
for folder, name in SOURCES:
    parts = folder.split("/")
    for i in range(1, len(parts) + 1):
        key = "/".join(parts[:i])
        if key not in folder_groups:
            folder_groups[key] = oid("group")

out.append("\n/* Begin PBXGroup section */\n")
out.append("\t\t%s = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" % MAIN_GROUP)
out.append("\t\t\t\t%s /* IfengAdmin */,\n" % APP_GROUP)
out.append("\t\t\t\t%s /* Products */,\n" % PRODUCTS_GROUP)
out.append("\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")

out.append("\t\t%s /* Products */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" % PRODUCTS_GROUP)
out.append("\t\t\t\t%s /* IfengAdmin.app */,\n" % PRODUCT_ID)
out.append("\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")

# app group children: top-level folders + assets + plist
top_level = []
for key in sorted(folder_groups.keys()):
    if "/" not in key:
        top_level.append(key)
out.append("\t\t%s /* IfengAdmin */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" % APP_GROUP)
for key in top_level:
    out.append("\t\t\t\t%s /* %s */,\n" % (folder_groups[key], key))
out.append("\t\t\t\t%s /* Assets.xcassets */,\n" % ASSET_ID)
out.append("\t\t\t\t%s /* Info.plist */,\n" % PLIST_ID)
out.append("\t\t\t);\n\t\t\tpath = IfengAdmin;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")

for key in sorted(folder_groups.keys()):
    children = []
    for folder, name in SOURCES:
        if folder == key:
            children.append((FILE_IDS[(folder, name)], name))
    for sub in sorted(folder_groups.keys()):
        if "/" in sub and sub.rsplit("/", 1)[0] == key:
            children.append((folder_groups[sub], sub.rsplit("/", 1)[1]))
    out.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" % (folder_groups[key], key))
    for cid, cname in children:
        out.append("\t\t\t\t%s /* %s */,\n" % (cid, cname))
    leaf = key.rsplit("/", 1)[-1]
    if "/" in key:
        out.append("\t\t\t);\n\t\t\tname = \"%s\";\n\t\t\tpath = \"%s\";\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n" % (leaf, leaf))
    else:
        out.append("\t\t\t);\n\t\t\tpath = \"%s\";\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n" % key)
out.append("/* End PBXGroup section */\n")

# PBXNativeTarget
out.append("\n/* Begin PBXNativeTarget section */\n")
out.append("\t\t%s /* IfengAdmin */ = {\n\t\t\tisa = PBXNativeTarget;\n" % TARGET_ID)
out.append("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"IfengAdmin\" */;\n" % TARGET_CONFIG_LIST)
out.append("\t\t\tbuildPhases = (\n")
out.append("\t\t\t\t%s /* Sources */,\n" % SOURCES_PHASE)
out.append("\t\t\t\t%s /* Frameworks */,\n" % FRAMEWORKS_PHASE)
out.append("\t\t\t\t%s /* Resources */,\n" % RESOURCES_PHASE)
out.append("\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n")
out.append("\t\t\tname = IfengAdmin;\n\t\t\tproductName = IfengAdmin;\n")
out.append("\t\t\tproductReference = %s /* IfengAdmin.app */;\n" % PRODUCT_ID)
out.append("\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};\n")
out.append("/* End PBXNativeTarget section */\n")

# PBXProject
out.append("\n/* Begin PBXProject section */\n")
out.append("\t\t%s /* Project object */ = {\n\t\t\tisa = PBXProject;\n" % PROJECT_ID)
out.append("\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n")
out.append("\t\t\t\tTargetAttributes = {\n\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t};\n\t\t\t\t};\n" % TARGET_ID)
out.append("\t\t\t};\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"IfengAdmin\" */;\n" % PROJECT_CONFIG_LIST)
out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n")
out.append("\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\t\"zh-Hans\",\n\t\t\t);\n")
out.append("\t\t\tmainGroup = %s;\n\t\t\tproductRefGroup = %s /* Products */;\n" % (MAIN_GROUP, PRODUCTS_GROUP))
out.append("\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t%s /* IfengAdmin */,\n\t\t\t);\n\t\t};\n" % TARGET_ID)
out.append("/* End PBXProject section */\n")

# PBXResourcesBuildPhase
out.append("\n/* Begin PBXResourcesBuildPhase section */\n")
out.append("\t\t%s /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" % RESOURCES_PHASE)
out.append("\t\t\t\tA50000000000000000000001 /* Assets.xcassets in Resources */,\n")
out.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
out.append("/* End PBXResourcesBuildPhase section */\n")

# PBXSourcesBuildPhase
out.append("\n/* Begin PBXSourcesBuildPhase section */\n")
out.append("\t\t%s /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" % SOURCES_PHASE)
for folder, name in SOURCES:
    out.append("\t\t\t\t%s /* %s in Sources */,\n" % (BUILD_IDS[(folder, name)], name))
out.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
out.append("/* End PBXSourcesBuildPhase section */\n")

PROJECT_COMMON = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
"""

TARGET_COMMON = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = IfengAdmin/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ifeng.admin;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSUPPORTS_MACCATALYST = NO;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""

out.append("\n/* Begin XCBuildConfiguration section */\n")
out.append("\t\t%s /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n" % PROJECT_DEBUG)
out.append(PROJECT_COMMON)
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tENABLE_TESTABILITY = YES;\n\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n")
out.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t);\n")
out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n")
out.append("\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n")

out.append("\t\t%s /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n" % PROJECT_RELEASE)
out.append(PROJECT_COMMON)
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n")
out.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";\n\t\t\t\tVALIDATE_PRODUCT = YES;\n")
out.append("\t\t\t};\n\t\t\tname = Release;\n\t\t};\n")

out.append("\t\t%s /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n" % TARGET_DEBUG)
out.append(TARGET_COMMON)
out.append("\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n")

out.append("\t\t%s /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n" % TARGET_RELEASE)
out.append(TARGET_COMMON)
out.append("\t\t\t};\n\t\t\tname = Release;\n\t\t};\n")
out.append("/* End XCBuildConfiguration section */\n")

out.append("\n/* Begin XCConfigurationList section */\n")
out.append("\t\t%s /* Build configuration list for PBXProject \"IfengAdmin\" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n" % PROJECT_CONFIG_LIST)
out.append("\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n" % (PROJECT_DEBUG, PROJECT_RELEASE))
out.append("\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")
out.append("\t\t%s /* Build configuration list for PBXNativeTarget \"IfengAdmin\" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n" % TARGET_CONFIG_LIST)
out.append("\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n" % (TARGET_DEBUG, TARGET_RELEASE))
out.append("\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")
out.append("/* End XCConfigurationList section */\n")

out.append("\t};\n\trootObject = %s /* Project object */;\n}\n" % PROJECT_ID)

pbxproj_path = os.path.join(ROOT, PROJECT + ".xcodeproj", "project.pbxproj")
os.makedirs(os.path.dirname(pbxproj_path), exist_ok=True)
with open(pbxproj_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("".join(out))

scheme_dir = os.path.join(ROOT, PROJECT + ".xcodeproj", "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "IfengAdmin.app"
               BlueprintName = "IfengAdmin"
               ReferencedContainer = "container:IfengAdmin.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "IfengAdmin.app"
            BlueprintName = "IfengAdmin"
            ReferencedContainer = "container:IfengAdmin.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "IfengAdmin.app"
            BlueprintName = "IfengAdmin"
            ReferencedContainer = "container:IfengAdmin.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""".replace("{target}", TARGET_ID)
with open(os.path.join(scheme_dir, "IfengAdmin.xcscheme"), "w", encoding="utf-8", newline="\n") as f:
    f.write(scheme)

print("generated:", pbxproj_path)
print("sources:", len(SOURCES))
