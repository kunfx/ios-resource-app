# 在线客服 · iOS 管理员端（原生 SwiftUI）

真正原生的 iOS 管理员 APP，**不是 WKWebView 套壳**：全部界面用 SwiftUI 手写，
图标用 Lucide 的 SVG path 在运行期解析成 `Path` 绘制，没有一张位图图标。

- Bundle ID：`com.ifeng.admin`
- 最低系统：iOS 16.0
- URL Scheme：`ifengadmin://conversation/<id>[?account_id=<n>]`
- 产物：GitHub Actions 编译的**未签名 IPA**（需自行签名安装）

---

## 1. 目录结构

```
ios-app/
├── IfengAdmin/
│   ├── Info.plist                  # URL Scheme、ATS、默认服务器地址
│   ├── Assets.xcassets/            # AppIcon（脚本生成）+ AccentColor
│   ├── App/
│   │   ├── AppConfig.swift         # 集中配置 + Liquid Glass 编译开关
│   │   ├── AppState.swift          # 启动恢复 / 登录 / 登出 / 深链 / 实时生命周期
│   │   ├── ServerAddress.swift     # 服务器地址校验 + 三头认证凭据
│   │   ├── KeychainStore.swift     # 凭据只进 Keychain，按 host 隔离
│   │   └── IfengAdminApp.swift     # @main
│   ├── Core/
│   │   ├── APIClient.swift         # 全部 HTTP 接口（含 typing / message_receipts）
│   │   ├── Models.swift            # 模型 + 投递状态判定（灰色单勾 / 蓝色双勾）
│   │   ├── RealtimeClient.swift    # SSE：ticket → stream → 事件解析 → 退避重连
│   │   ├── ChatModel.swift         # 聊天数据源：分页 / 发送 / 已读 / 正在输入 / 轮询兜底
│   │   ├── ConversationListModel.swift
│   │   └── ImagePreparer.swift     # HEIC → JPEG（长边 1600、白底、逐步降质）
│   ├── Design/
│   │   ├── LucideIcon.swift        # 39 个 Lucide 图标 + SVG path 解析器
│   │   └── Theme.swift             # 配色 / Liquid Glass 表面 / 正在输入气泡 / 时间格式
│   └── Features/
│       ├── Root/RootView.swift     # 底部 Liquid Glass Dock + 三个 Tab
│       ├── Login/LoginView.swift
│       ├── Conversations/ConversationListScreen.swift
│       ├── Chat/ChatView.swift
│       ├── Chat/ChatMessageRow.swift
│       ├── Chat/VisitorInfoView.swift
│       ├── Inbox/InboxScreen.swift
│       └── Settings/SettingsScreen.swift
├── tools/
│   ├── make_xcodeproj.py           # 生成 IfengAdmin.xcodeproj（纯标准库）
│   ├── make_icon.py                # 生成 1024 图标（纯标准库写 PNG）
│   ├── check_sources.py            # 无 Xcode 环境下的静态自检
│   └── deeplink-test.html          # 浏览器里测深链能否唤醒 APP
├── project.yml                     # XcodeGen 兜底描述
└── README.md
```

---

## 2. 本地重建

```bash
cd ios-app

# 重新生成 Xcode 工程（新增 .swift 后必须重跑，否则不会进编译）
python3 tools/make_xcodeproj.py

# 重新生成 AppIcon
python3 tools/make_icon.py

# 没有 Xcode 的环境里先跑静态自检
python3 tools/check_sources.py
```

`make_xcodeproj.py` 会扫描 `IfengAdmin/**/*.swift` 自动建 PBXGroup、PBXBuildFile、
Sources/Resources 阶段与共享 Scheme，不需要 Xcode GUI，也不依赖 XcodeGen。

---

## 3. 底部 Dock 的 Liquid Glass

`Design/Theme.swift` 里的 `GlassSurface`：

```swift
#if compiler(>=6.2)
if #available(iOS 26.0, *), AppConfig.preferSystemLiquidGlass {
    Color.clear.glassEffect(.regular, in: shape)   // 苹果官方 API
} else {
    GlassBackground(shape: shape, strong: strong)  // 材质降级
}
#else
GlassBackground(shape: shape, strong: strong)
#endif
```

- **iOS 26 + Xcode 26**：走官方 `View.glassEffect(_:in:)`，系统级玻璃，会跟随壁纸与滚动内容折射
- **更早的系统 / 更早的 Xcode**：自动回退到 `.ultraThinMaterial` + 高光 + 描边 + 阴影的等价实现
- 双保险的原因：`glassEffect` 是 iOS 26 SDK 才有的符号，用 Xcode 16 编译时
  必须让整段代码在**编译期**就消失，光靠 `#available` 不够

如果某个 Xcode 版本的 SDK 签名有出入，把 `AppConfig.preferSystemLiquidGlass` 改成 `false`
即可一键回退，不需要改其它任何代码。

### 图标不再被裁切

`LucideShape` 会把 24×24 的图形**内缩半个线宽**再铺进 frame：

```swift
let inset = min(lineWidth / 2, side / 4)
let available = max(1, side - inset * 2)
let scale = available / 24
```

这样描边最外沿正好落在 frame 边界内，不会被父容器的 `clipShape` / 圆角切掉一半。
Dock 单元格也放大到 66×48、图标 24pt，四周留足余量。

---

## 4. Lucide 图标

`Design/LucideIcon.swift` 内置一个极简 SVG path 解析器（支持
`M/L/H/V/C/S/Q/T/A/Z` 及相对命令），运行期把 path 数据转成 `SwiftUI.Path` 再描边。

用法：

```swift
LucideIcon(name: "info", size: 19, color: Theme.accent)
```

新增一个图标：在 `LucideRegistry.icons` 里加一条，path 数据直接从
`web/icons.js` 复制（保证与网页后台同款），然后跑一次 `check_sources.py` 确认名称没拼错。

当前已注册 39 个，覆盖底部导航、会话操作、输入区、访客信息、设置、状态六类。

---

## 5. 两个实时状态

### 5.1 「正在输入」三点气泡

| 方向 | 触发 | 接口 |
| --- | --- | --- |
| 自己 → 访客 | 输入框内容变化 | `POST .../toggle_typing_status`，`typing_mode: heartbeat` |
| 访客 → 自己 | SSE `typing_on` / `typing_off` | 显示 `TypingBubble` |

- 上报节流 300ms，停止输入 2 秒发 `off`，发送消息 / 离开页面立即 `off`
- 服务端租约 3 秒（`heartbeat`），客户端按 `lease_ms` 本地过期，上限 8 秒
- 对方直接关掉浏览器也能在租约到期后自动隐藏气泡
- 只接受 `actor_type == "visitor"`，自己发的 typing 服务端不会回推

### 5.2 已读回执：灰色单勾 → 蓝色双勾

判定严格照抄 `web/messages.js` 的 `deliveryStatus()`：

| 条件 | 图标 | 颜色 |
| --- | --- | --- |
| `status == "failed"` | `circle-alert` | 红 |
| `sending` | `clock` | 灰 |
| 公开消息且 `status == "read" && read_at > 0` | `check-check` | **#3B82F6 蓝** |
| 其余 `sent / delivered / read` | `check` | **#9CA3AF 灰** |

两个容易踩的坑：

1. 消息创建时服务端就写 `status = 'sent'`，所以**不能**用 `read_at != nil` 判断已读，
   必须 `status == "read"` **且** `read_at > 0`
2. `message.updated` 可能带较旧快照，合并时 `read_at` 只允许前进不允许后退，
   否则蓝色双勾会被打回灰色单勾

### 5.3 为什么还要轮询

SSE 是主通道，但移动网络下长连接会抖。聊天页可见时额外开一条 **2 秒轮询**：

- `GET .../message_receipts?message_ids[]=...` —— 问服务端自己发出的消息有没有被读
- `GET .../typing_status` —— 问服务端访客在不在打字

SSE 正常时它只是冗余校验；SSE 断了它就是唯一来源。这样「永远单勾」「气泡不出现」
不会因为长连接抖动而复现。

---

## 6. 构建

推送到 `main` / `master` 会自动跑 `.github/workflows/build-ios.yml`：

1. 挑选 Runner 上**最新的一版 Xcode**（尽量拿到 iOS 26 SDK，走官方 Liquid Glass）
2. `python3 tools/make_xcodeproj.py` 重建工程，保证新文件一定进编译
3. `xcodebuild -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`
4. 打包成 `IfengAdmin-unsigned.ipa` 并上传 Artifact

未签名 IPA 不能直接安装，需要用 ESign / TrollStore / 自签工具或自己的开发者证书重签。
