#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 源码静态自检。

用途：在没有 Xcode 的环境（Windows）里，先排掉一批"一定会编译失败"的低级问题：
    1. Lucide 图标名是否都在注册表里；
    2. 用了 UIColor / UIImage / UIPasteboard / Color(uiColor:) 却没有 import UIKit；
    3. 括号是否平衡（先剔字符串与注释，避免误报）；
    4. 引用了不存在的 Swift 类型名（简单白名单核对）；
    5. 已知的「API 签名记错」写法（如 addResource(fileData:)、
       @FocusState 当 Binding<Bool> 传出）。

注意：这只是**结构级**自检，不做类型检查。真正的编译在 GitHub Actions
的 macOS runner 上跑（见 .github/workflows/build-ios.yml）。

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
        # Photos 框架：存图用 PHAssetCreationRequest + PHAuthorizationStatus
        "PHAssetCreationRequest", "PHAuthorizationStatus",
        "UnicodeScalarView", "AnyView", "EmptyView", "TupleView", "Content", "CoordinateSpace",
        "Font", "EdgeInsets", "Alignment", "HorizontalAlignment", "VerticalAlignment",
        "Animation", "Transaction", "Binding", "Environment", "EnvironmentObject", "ObservedObject",
        "StateObject", "Namespace", "SceneStorage", "AppStorage", "Gesture", "DragGesture",
        "TapGesture", "LongPressGesture", "Predicate", "AutoreleasingUnsafeMutablePointer",
        "UserDefaults", "Self", "UInt64", "UInt", "Int64", "TimeInterval", "Divider",
        "IndexSet", "Range", "ClosedRange", "DispatchTime", "AsyncImage", "URLRequest",
        "HTTPURLResponse", "URLError", "JSONValue", "AnyCancellable", "ObservableObject",
        "NotificationCenter", "FileManager", "OutputStream", "InputStream", "Timer",
        # 链接识别：正则 + 富文本
        "CharacterSet", "NSRegularExpression", "NSRange", "AttributedString",
        # UIKit 文本编辑：原生菜单扩展
        "UIEdgeInsets", "UIFont", "UIMenu", "UIAction", "UIMenuElement",
        "UITextView", "UITextRange", "UITextPosition", "UIViewRepresentable",
        "TextEditor", "StrokeBorderStyle", "ScrollContentBackground", "ConfirmationDialog",
        "NSLock", "OperationQueue", "URLSessionDataDelegate", "URLSessionDataTask",
        "URLResponse", "ResponseDisposition", "URLSessionTask", "Data",
        "UNUserNotificationCenter", "UNAuthorizationOptions", "UNError",
        "MagnificationGesture", "RotationGesture", "GeometryProxy", "GeometryReader",
        # 欢迎语快捷按钮：SwiftUI 的 Link、自定义 Layout 的尺寸提议类型
        "Link", "ProposedViewSize",
        # 输入框原生菜单兜底：标准编辑动作（剪切/复制/粘贴/全选）的协议
        "UIResponderStandardEditActions",
        # 正文改用 UITextView 承载：富文本属性串 + 手势识别器
        "NSAttributedString", "NSMutableAttributedString", "NSParagraphStyle",
        "NSMutableParagraphStyle", "NSUnderlineStyle",
        "UITapGestureRecognizer", "UIGestureRecognizer", "UIGestureRecognizerDelegate",
        "UIView", "UIViewRepresentable", "NSObject",
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


def check_known_api_misuse(files: list[str]) -> list[str]:
    """拦一类「API 签名记错」的编译错误。

    本地没有 Xcode，`xcodebuild` 只在 GitHub Actions 上跑，所以这类错误
    要等推上去才发现。这里把**已经踩过的坑**固化成模式匹配，防止再犯。

    规则只收录「确定错」的写法，宁可漏报也不误报——误报会让人不信任自检。
    """
    problems: list[str] = []
    for path in files:
        code = strip_code(read(path))
        name = os.path.basename(path)

        # 1) PHAssetCreationRequest 的资源接口签名是
        #    `addResource(with:data:options:)` / `addResource(with:fileURL:options:)`，
        #    没有 `fileData:` 这个标签（那是 PHAssetResourceCreationOptions 的字段名）。
        for match in re.finditer(r"addResource\(", code):
            tail = code[match.end() : match.end() + 160]
            if "fileData:" in tail:
                problems.append(
                    f"addResource 参数标签错误（应为 data:，没有 fileData:）：{name}"
                )

        # 2) `@FocusState` 的投影类型是 `FocusState<T>.Binding`，和 `Binding<Bool>`
        #    不是同一个类型。它唯一的合法用途是传给 `.focused(...)`。
        #    如果出现在别处（比如传给某个 `Binding<Bool>` 形参），一定编译失败。
        for var in re.findall(r"@FocusState\s+(?:private\s+)?var\s+(\w+)", code):
            for match in re.finditer(r"\$" + re.escape(var) + r"\b", code):
                prefix = code[max(0, match.start() - 16) : match.start()]
                # `.focused( $x` 这种带空格也要放过，只认「紧邻的调用括号」。
                if not prefix.rstrip().endswith(".focused("):
                    problems.append(
                        f"@FocusState 变量 ${var} 被当 Binding<Bool> 传出"
                        f"（只能用于 .focused(...)）：{name}"
                    )

        # 3) `canPerformAction` 的第二个参数标签在新版 SDK 里是 `withSender:`。
        #    ObjC 原名是 `canPerformAction:withSender:`，Swift 老版本导入成
        #    `with:`，Xcode 26 / iOS 26 SDK 改成了 `withSender:`。
        #    写成 `with:` 会报 `incorrect argument label in call
        #    (have '_:with:', expected '_:withSender:')`。
        for match in re.finditer(r"canPerformAction\([^()]*,\s*with\s*:", code):
            problems.append(
                f"canPerformAction 参数标签错误（应为 withSender:，不是 with:）：{name}"
            )

    print("[API] 检查完成")
    return problems


def main() -> None:
    files = swift_files()
    print(f"共 {len(files)} 个 Swift 文件\n")

    problems: list[str] = []
    problems += check_icons(files)
    problems += check_uikit(files)
    problems += check_brackets(files)
    problems += check_types(files)
    problems += check_known_api_misuse(files)

    print()
    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for item in problems:
            print("  -", item)
        sys.exit(1)
    print("静态自检通过。")


if __name__ == "__main__":
    main()
