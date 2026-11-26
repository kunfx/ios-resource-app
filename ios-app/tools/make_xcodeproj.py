#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 IfengAdmin.xcodeproj（纯标准库，不依赖 XcodeGen / Xcode GUI）。

为什么要自己生成：
    XcodeGen 在 GitHub Actions 上要 brew install（联网、耗时、可能失败），
    而 .xcodeproj 又必须入库才能让 xcodebuild 直接用。这里用脚本扫描源码目录
    生成 pbxproj，任何新增 .swift 文件只要重跑一次脚本就会被纳入编译。

用法（在 ios-app/ 目录下）：
    python3 tools/make_xcodeproj.py

产物：
    ios-app/IfengAdmin.xcodeproj/project.pbxproj
    ios-app/IfengAdmin.xcodeproj/xcshareddata/xcschemes/IfengAdmin.xcscheme
"""

from __future__ import annotations

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "IfengAdmin")
PROJECT_DIR = os.path.join(ROOT, "IfengAdmin.xcodeproj")

PROJECT_NAME = "IfengAdmin"
TARGET_NAME = "IfengAdmin"
BUNDLE_ID = "com.ifeng.admin"
DISPLAY_NAME = "在线客服"
DEPLOYMENT_TARGET = "16.0"
SWIFT_VERSION = "5.0"
MARKETING_VERSION = "1.4.1"
BUILD_VERSION = "7"

# 图标与 Info.plist 在 Assets / plist 里的相对路径。
INFO_PLIST_REL = "IfengAdmin/Info.plist"
ASSETS_REL = "IfengAdmin/Assets.xcassets"

_uuid_cache: dict[str, str] = {}
_uuid_used: set[str] = set()


def uid(*parts: str) -> str:
    """稳定的 24 位十六进制对象 ID（同一 key 每次生成结果一致，diff 干净）。"""
    key = "|".join(parts)
    if key in _uuid_cache:
        return _uuid_cache[key]
    digest = hashlib.md5(key.encode("utf-8")).hexdigest().upper()[:24]
    candidate = digest
    salt = 0
    while candidate in _uuid_used:
        salt += 1
        candidate = hashlib.md5(f"{key}#{salt}".encode("utf-8")).hexdigest().upper()[:24]
    _uuid_used.add(candidate)
    _uuid_cache[key] = candidate
    return candidate


def _rel(path: str) -> str:
    """相对 ios-app/ 的路径，统一用正斜杠（pbxproj 只认 /，Windows 上 os.sep 是 \\）。"""
    return os.path.relpath(path, ROOT).replace(os.sep, "/").replace("\\", "/")


def quote(text: str) -> str:
    """pbxproj 里出现特殊字符时需要加引号。"""
    if text == "":
        return '""'
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$./")
    if all(char in safe for char in text):
        return text
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


# ---------------------------------------------------------------- 扫描源码


def scan_sources() -> tuple[list[str], list[str]]:
    """返回 (swift 相对路径列表, 资源相对路径列表)，路径相对 ios-app/。"""
    swift_files: list[str] = []
    resources: list[str] = []

    for dirpath, dirnames, filenames in os.walk(SRC_DIR):
        dirnames.sort()
        # .xcassets / .bundle 是"目录型资源"，整体当文件处理，不递归进去。
        kept: list[str] = []
        for name in dirnames:
            if name.endswith((".xcassets", ".bundle", ".storyboardc")):
                resources.append(_rel(os.path.join(dirpath, name)))
            else:
                kept.append(name)
        dirnames[:] = kept

        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            rel = _rel(full)
            if name.endswith(".swift"):
                swift_files.append(rel)
            elif name.endswith((".storyboard", ".xib", ".plist")):
                # Info.plist 通过 INFOPLIST_FILE 引用，不进 Resources 阶段。
                if name != "Info.plist":
                    resources.append(rel)

    if not swift_files:
        raise SystemExit("没有找到任何 .swift 文件，请检查 IfengAdmin/ 目录。")
    return swift_files, resources


def group_tree(paths: list[str]) -> dict:
    """把文件路径折叠成目录树，用于生成 PBXGroup 层级。"""
    tree: dict = {"files": [], "children": {}}
    for rel in paths:
        # rel 形如 IfengAdmin/App/AppConfig.swift
        parts = rel.split("/")[1:]  # 去掉顶层的 IfengAdmin
        node = tree
        for part in parts[:-1]:
            node = node["children"].setdefault(part, {"files": [], "children": {}})
        node["files"].append((parts[-1], rel))
    return tree


# ---------------------------------------------------------------- pbxproj 生成


def build_pbxproj(swift_files: list[str], resources: list[str]) -> str:
    project_id = uid("project", PROJECT_NAME)
    target_id = uid("target", TARGET_NAME)
    product_ref_id = uid("product", TARGET_NAME)
    main_group_id = uid("group", "main")
    src_group_id = uid("group", "IfengAdmin")
    products_group_id = uid("group", "Products")

    sources_phase_id = uid("phase", "sources")
    frameworks_phase_id = uid("phase", "frameworks")
    resources_phase_id = uid("phase", "resources")

    project_config_list_id = uid("configlist", "project")
    target_config_list_id = uid("configlist", "target")
    project_debug_id = uid("config", "project", "Debug")
    project_release_id = uid("config", "project", "Release")
    target_debug_id = uid("config", "target", "Debug")
    target_release_id = uid("config", "target", "Release")

    # ---- 文件引用与构建文件
    # 注意：PBXFileReference.path 是相对「所属 PBXGroup 的 path」的，
    # 分组层级已经表达了目录结构，所以这里只能写文件名，不能写完整相对路径。
    file_refs: list[tuple[str, str, str]] = []   # (id, 显示名, path)
    build_files: list[tuple[str, str, str]] = []  # (buildfile id, fileref id, 显示名)

    for rel in swift_files:
        name = os.path.basename(rel)
        ref = uid("fileref", rel)
        file_refs.append((ref, name, name))
        build_files.append((uid("buildfile", rel), ref, name))

    for rel in resources:
        name = os.path.basename(rel)
        ref = uid("fileref", rel)
        file_refs.append((ref, name, name))
        build_files.append((uid("buildfile", rel), ref, name))

    info_ref = uid("fileref", INFO_PLIST_REL)
    file_refs.append((info_ref, "Info.plist", "Info.plist"))

    # ---- 分组
    tree = group_tree(swift_files + resources)
    group_lines: list[str] = []

    def emit_group(node: dict, name: str, own_path: str, gid: str, key_prefix: str) -> None:
        children: list[str] = []
        for _filename, rel in node["files"]:
            children.append(uid("fileref", rel))
        for child_name in sorted(node["children"]):
            child_id = uid("group", key_prefix, child_name)
            children.append(child_id)
            # PBXGroup 的 path 是相对父组的，只写自己这一段，不能写累积路径。
            emit_group(
                node["children"][child_name],
                child_name,
                child_name,
                child_id,
                f"{key_prefix}/{child_name}",
            )
        # Info.plist 挂在顶层 IfengAdmin 组下，方便在 Xcode 里直接看到。
        if name == "IfengAdmin":
            children.append(info_ref)
        lines = [f"\t\t{gid} /* {name} */ = {{", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
        for child in children:
            lines.append(f"\t\t\t\t{child},")
        lines.append("\t\t\t);")
        lines.append(f"\t\t\tpath = {quote(own_path)};")
        lines.append(f"\t\t\tsourceTree = {quote('<group>')};")
        lines.append("\t\t};")
        group_lines.extend(lines)

    emit_group(tree, "IfengAdmin", "IfengAdmin", src_group_id, "IfengAdmin")

    out: list[str] = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")
    out.append("")

    # PBXBuildFile
    out.append("/* Begin PBXBuildFile section */")
    for bid, ref, name in build_files:
        out.append(
            f"\t\t{bid} /* {name} in Build */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};"
        )
    out.append("/* End PBXBuildFile section */")
    out.append("")

    # PBXFileReference
    out.append("/* Begin PBXFileReference section */")
    for ref, name, path in file_refs:
        ext = os.path.splitext(name)[1].lower()
        if ext == ".swift":
            ftype = "sourcecode.swift"
        elif ext == ".plist":
            ftype = "text.plist.xml"
        elif ext == ".xcassets":
            ftype = "folder.assetcatalog"
        elif ext == ".storyboard":
            ftype = "file.storyboard"
        else:
            ftype = "folder"
        out.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {ftype}; path = {quote(path)}; sourceTree = {quote('<group>')}; }};"
        )
    out.append(
        f"\t\t{product_ref_id} /* {TARGET_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {quote(TARGET_NAME + '.app')}; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    out.append("/* End PBXFileReference section */")
    out.append("")

    # PBXFrameworksBuildPhase
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append(f"\t\t{frameworks_phase_id} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")
    out.append("")

    # PBXGroup
    out.append("/* Begin PBXGroup section */")
    out.append(f"\t\t{main_group_id} = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{src_group_id} /* IfengAdmin */,")
    out.append(f"\t\t\t\t{products_group_id} /* Products */,")
    out.append("\t\t\t);")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.append(f"\t\t{products_group_id} /* Products */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{product_ref_id} /* {TARGET_NAME}.app */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.extend(group_lines)
    out.append("/* End PBXGroup section */")
    out.append("")

    # PBXNativeTarget
    out.append("/* Begin PBXNativeTarget section */")
    out.append(f"\t\t{target_id} /* {TARGET_NAME} */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {target_config_list_id};")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{sources_phase_id} /* Sources */,")
    out.append(f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,")
    out.append(f"\t\t\t\t{resources_phase_id} /* Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append(f"\t\t\tname = {TARGET_NAME};")
    out.append(f"\t\t\tproductName = {TARGET_NAME};")
    out.append(f"\t\t\tproductReference = {product_ref_id} /* {TARGET_NAME}.app */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")
    out.append("")

    # PBXProject
    out.append("/* Begin PBXProject section */")
    out.append(f"\t\t{project_id} /* Project object */ = {{")
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    out.append("\t\t\t\tLastUpgradeCheck = 1600;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append(f"\t\t\t\t\t{target_id} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append(f"\t\t\tbuildConfigurationList = {project_config_list_id};")
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\t\"zh-Hans\",")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tmainGroup = {main_group_id};")
    out.append(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
    out.append("\t\t\tprojectDirPath = \"\";")
    out.append("\t\t\tprojectRoot = \"\";")
    out.append("\t\t\ttargets = (")
    out.append(f"\t\t\t\t{target_id} /* {TARGET_NAME} */,")
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")
    out.append("")

    # PBXResourcesBuildPhase
    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append(f"\t\t{resources_phase_id} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for rel in resources:
        name = os.path.basename(rel)
        out.append(f"\t\t\t\t{uid('buildfile', rel)} /* {name} in Build */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")
    out.append("")

    # PBXSourcesBuildPhase
    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append(f"\t\t{sources_phase_id} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for rel in swift_files:
        name = os.path.basename(rel)
        out.append(f"\t\t\t\t{uid('buildfile', rel)} /* {name} in Build */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")
    out.append("")

    # XCBuildConfiguration
    shared_settings = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CLANG_WARN_BOOL_CONVERSION", "YES"),
        ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
        ("CLANG_WARN_EMPTY_BODY", "YES"),
        ("CLANG_WARN_ENUM_CONVERSION", "YES"),
        ("CLANG_WARN_INFINITE_RECURSION", "YES"),
        ("CLANG_WARN_INT_CONVERSION", "YES"),
        ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("GCC_C_LANGUAGE_STANDARD", "gnu17"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
        ("GCC_WARN_UNINITIALIZED_AUTOS", "YES"),
        ("GCC_WARN_UNUSED_FUNCTION", "YES"),
        ("GCC_WARN_UNUSED_VARIABLE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
        ("LOCALIZATION_PREFERS_STRING_CATALOGS", "YES"),
        ("MTL_FAST_MATH", "YES"),
        ("SDKROOT", "iphoneos"),
    ]

    debug_extra = [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_DYNAMIC_NO_PIC", "NO"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("GCC_PREPROCESSOR_DEFINITIONS", "(\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t)"),
        ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "\"DEBUG $(inherited)\""),
        ("SWIFT_OPTIMIZATION_LEVEL", "\"-Onone\""),
    ]

    release_extra = [
        ("DEBUG_INFORMATION_FORMAT", "\"dwarf-with-dsym\""),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("SWIFT_OPTIMIZATION_LEVEL", "\"-O\""),
        ("VALIDATE_PRODUCT", "YES"),
    ]

    target_common = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", BUILD_VERSION),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", INFO_PLIST_REL),
        ("LD_RUNPATH_SEARCH_PATHS", "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t)"),
        ("MARKETING_VERSION", MARKETING_VERSION),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("SWIFT_VERSION", SWIFT_VERSION),
        ("TARGETED_DEVICE_FAMILY", "\"1,2\""),
    ]

    def emit_config(cid: str, name: str, settings: list[tuple[str, str]]) -> None:
        out.append(f"\t\t{cid} /* {name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        for key, value in settings:
            out.append(f"\t\t\t\t{key} = {value};")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")

    out.append("/* Begin XCBuildConfiguration section */")
    emit_config(project_debug_id, "Debug", shared_settings + debug_extra)
    emit_config(project_release_id, "Release", shared_settings + release_extra)
    emit_config(target_debug_id, "Debug", target_common)
    emit_config(target_release_id, "Release", target_common)
    out.append("/* End XCBuildConfiguration section */")
    out.append("")

    # XCConfigurationList
    out.append("/* Begin XCConfigurationList section */")
    for clid, label, debug_id, release_id in (
        (project_config_list_id, "PBXProject", project_debug_id, project_release_id),
        (target_config_list_id, "PBXNativeTarget", target_debug_id, target_release_id),
    ):
        out.append(f"\t\t{clid} /* Build configuration list for {label} */ = {{")
        out.append("\t\t\tisa = XCConfigurationList;")
        out.append("\t\t\tbuildConfigurations = (")
        out.append(f"\t\t\t\t{debug_id} /* Debug */,")
        out.append(f"\t\t\t\t{release_id} /* Release */,")
        out.append("\t\t\t);")
        out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        out.append("\t\t\tdefaultConfigurationName = Release;")
        out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")
    out.append("")

    out.append("\t};")
    out.append(f"\trootObject = {project_id} /* Project object */;")
    out.append("}")
    out.append("")
    return "\n".join(out)


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES"
            buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{target}.app"
               BlueprintName = "{target}"
               ReferencedContainer = "container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0"
      useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{target}.app"
            BlueprintName = "{target}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{target}.app"
            BlueprintName = "{target}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main() -> None:
    swift_files, resources = scan_sources()
    pbxproj = build_pbxproj(swift_files, resources)

    os.makedirs(PROJECT_DIR, exist_ok=True)
    with open(os.path.join(PROJECT_DIR, "project.pbxproj"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(pbxproj)

    scheme_dir = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(scheme_dir, f"{TARGET_NAME}.xcscheme"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            SCHEME_TEMPLATE.format(
                target_id=uid("target", TARGET_NAME),
                target=TARGET_NAME,
                project=PROJECT_NAME,
            )
        )

    print(f"已生成 {PROJECT_DIR}")
    print(f"  Swift 文件：{len(swift_files)} 个")
    for rel in swift_files:
        print(f"    - {rel}")
    print(f"  资源：{len(resources)} 个")
    for rel in resources:
        print(f"    - {rel}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001
        print(f"生成工程失败：{error}", file=sys.stderr)
        raise
