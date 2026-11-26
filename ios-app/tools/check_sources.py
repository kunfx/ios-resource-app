#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 源码静态自检。

用途：在没有 Xcode 的环境（Windows）里，先排掉一批"一定会编译失败"的低级问题：
    1. Lucide 图标名是否都在注册表里；
    2. 用了 UIColor / UIImage / UIPasteboard / Color(uiColor:) 却没有 import UIKit；
    3. 括号是否平衡（先剔字符串与注释，避免误报）；
    4. 引用了不存在的 Swift 类型名（简单白名单核对）。

用法：
    python3 tools/check_sources.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "IfengAdmin")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def swift_files() -> list[str]:
    output: list[str] = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(".swift"):
                output.append(os.path.join(dirpath, name))
    return output


def strip_code(text: str) -> str:
    """去掉字符串字面量与注释，只留结构性字符。"""
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def check_icons(files: list[str]) -> list[str]:
    registry = read(os.path.join(SRC, "Design", "LucideIcon.swift"))
    block = registry[registry.index("static let icons") : registry.index("static func path(named")]
    names = set(re.findall(r'"([a-z0-9-]+)":\s*\[', block))

    used: dict[str, set[str]] = {}
    for path in files:
        text = read(path)
        for match in re.finditer(r"LucideIcon\(|LucideCircleButton\(", text):
            tail = text[match.end() : match.end() + 90]
            hit = re.search(r'name:\s*"([a-z0-9-]+)"', tail)
            if hit:
                used.setdefault(hit.group(1), set()).add(os.path.basename(path))
        for match in re.finditer(r'name:\s*[^,\n]*\?\s*"([a-z0-9-]+)"\s*:\s*"([a-z0-9-]+)"', text):
            used.setdefault(match.group(1), set()).add(os.path.basename(path))
            used.setdefault(match.group(2), set()).add(os.path.basename(path))

    problems: list[str] = []
    for name, where in sorted(used.items()):
        if name not in names:
            problems.append(f"图标未注册：{name}（{', '.join(sorted(where))}）")
    print(f"[图标] 注册 {len(names)} 个，实际引用 {len(used)} 个")
    return problems


def check_uikit(files: list[str]) -> list[str]:
    problems: list[str] = []
    markers = ("Color(uiColor:", "UIColor", "UIImage", "UIPasteboard", "UIApplication", "UIGraphics")
    for path in files:
        text = read(path)
        if any(marker in text for marker in markers) and "import UIKit" not in text:
            problems.append(f"缺少 import UIKit：{os.path.basename(path)}")
    print("[UIKit] 检查完成")
    return problems


def check_brackets(files: list[str]) -> list[str]:
    problems: list[str] = []
    for path in files:
        code = strip_code(read(path))
        for opening, closing in (("{", "}"), ("(", ")"), ("[", "]")):
            left, right = code.count(opening), code.count(closing)
            if left != right:
                problems.append(
                    f"括号不平衡：{os.path.basename(path)} {opening}={left} {closing}={right}"
                )
    print("[括号] 检查完成")
    return problems


def check_types(files: list[str]) -> list[str]:
    """收集所有自定义类型名，核对被引用的"大写开头标识符"里是否有拼错的。"""
    defined: set[str] = set()
    for path in files:
        code = strip_code(read(path))
        defined |= set(
            re.findall(
                r"(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)",
                code,
            )
        )

    known_apple = {
        "Any", "Array", "Bool", "Bundle", "CGPoint", "CGRect", "CGSize", "CGFloat",
        "CGAffineTransform", "Calendar", "CaseIterable", "Character", "Codable",
        "CodingKey", "Color", "Comparable", "Data", "Date", "DateFormatter", "Decoder",
        "DecodingError", "Dictionary", "Double", "Encoder", "Equatable", "Error",
        "Float", "ForEach", "Group", "Hashable", "Identifiable", "IndexPath", "Int",
        "JSONDecoder", "JSONEncoder", "JSONSerialization", "LazyVGrid", "LazyVStack",
        "LocalizedError", "MainActor", "NavigationPath", "NavigationStack",
        "NavigationLink", "Never", "ObservableObject", "Optional", "Path", "PhotosPicker",
        "PhotosPickerItem", "ProgressView", "Published", "RoundedRectangle", "Scene",
        "ScenePhase", "ScrollView", "ScrollViewReader", "SecItemAdd", "SecItemCopyMatching",
        "SecItemDelete", "SecureField", "Set", "Shape", "Spacer", "State", "StateObject",
        "String", "StrokeStyle", "Substring", "Task", "Text", "TextField", "TimeZone",
        "Toggle", "URL", "URLComponents", "URLQueryItem", "URLRequest", "URLSession",
        "URLSessionConfiguration", "UIImage", "UIPasteboard", "UIGraphicsImageRenderer",
        "UIGraphicsImageRendererFormat", "UIApplication", "UIColor", "UIKit", "UIScreen",
        "View", "ViewBuilder", "ViewModifier", "VStack", "HStack", "ZStack", "WindowGroup",
        "AsyncImage", "Button", "Capsule", "Circle", "ColorScheme", "Combine", "Coder",
        "Foundation", "GeometryReader", "GridItem", "Image", "Label", "LinearGradient",
        "List", "Locale", "NSNumber", "NSNull", "PassthroughSubject", "Path", "Rectangle",
        "ShareLink", "SwiftUI", "ToolbarItem", "AnyShapeStyle", "Animation", "AnyObject",
        "CGRect", "CFDictionary", "DispatchQueue", "NSCoder", "NSError", "NSUUID",
        "PHPhotoLibrary", "PHPickerFilter", "PhotosUI", "Security", "UUID", "UnicodeScalar",
        "UnicodeScalarView", "AnyView", "EmptyView", "TupleView", "Content", "CoordinateSpace",
        "Font", "EdgeInsets", "Alignment", "HorizontalAlignment", "VerticalAlignment",
        "Animation", "Transaction", "Binding", "Environment", "EnvironmentObject", "ObservedObject",
        "StateObject", "Namespace", "SceneStorage", "AppStorage", "Gesture", "DragGesture",
        "TapGesture", "LongPressGesture", "Predicate", "AutoreleasingUnsafeMutablePointer",
        "UserDefaults", "Self", "UInt64", "UInt", "Int64", "TimeInterval", "Divider",
        "IndexSet", "Range", "ClosedRange", "DispatchTime", "AsyncImage", "URLRequest",
        "HTTPURLResponse", "URLError", "JSONValue", "AnyCancellable", "ObservableObject",
        "NotificationCenter", "FileManager", "OutputStream", "InputStream", "Timer",
        "TextEditor", "StrokeBorderStyle", "ScrollContentBackground", "ConfirmationDialog",
        "MagnificationGesture", "RotationGesture", "GeometryProxy", "GeometryReader",
    }

    problems: list[str] = []
    for path in files:
        code = strip_code(read(path))
        # 只看 "Xxx(" 或 "Xxx." 形式的类型引用
        for match in re.finditer(r"(?<![A-Za-z0-9_.])([A-Z][A-Za-z0-9_]{2,})[.(]", code):
            name = match.group(1)
            if name in defined or name in known_apple:
                continue
            # 过滤掉类似 HTTPURLResponse 之类确实存在的系统类型白名单外项
            problems.append(f"未知类型引用：{name}（{os.path.basename(path)}）")

    if problems:
        print(f"[类型] 发现 {len(problems)} 处可疑引用（需人工确认）")
    else:
        print("[类型] 检查完成")
    return problems


def main() -> None:
    files = swift_files()
    print(f"共 {len(files)} 个 Swift 文件\n")

    problems: list[str] = []
    problems += check_icons(files)
    problems += check_uikit(files)
    problems += check_brackets(files)
    problems += check_types(files)

    print()
    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for item in problems:
            print("  -", item)
        sys.exit(1)
    print("静态自检通过。")


if __name__ == "__main__":
    main()
