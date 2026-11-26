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

### 选中态玻璃胶囊跟着滚动

整条 Dock 是一层玻璃，**选中的那个按钮自己也叠一层玻璃**，两层叠出「凸起」的层次感。
滑动不是手算位移，而是把选中态那层玻璃打上 `matchedGeometryEffect`，
切换时只改 `selection`，位置插值交给系统动画：

```swift
@Namespace private var glassNamespace

Button {
    guard selection != item else { return }
    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
        selection = item
    }
} label: {
    ZStack {
        if selected {
            GlassSurface(shape: Capsule(), strong: true)
                .matchedGeometryEffect(id: "dock.selection", in: glassNamespace)
                .frame(width: cellWidth, height: cellHeight)
        }
        LucideIcon(name: item.iconName, size: iconSize, ...)
    }
}
```

- 单元格 62×46、图标 24pt、`HStack` 间距 2、整条 Dock 内边距 6
- 同一个 `id` 只存在于一个分支里，系统会自动做「旧位置 → 新位置」的形变，
  得到和系统 TabBar 一致的 Liquid Glass 滑动效果
- 动画曲线用 `.spring(response: 0.34, dampingFraction: 0.78)`，比默认更跟手且不回弹过头

### 图标不再被裁切（真正的根因）

**根因不在内缩量，而在 SVG path 解析器。** `Scanner.number()` 原先只吃数字和小数点，
遇到负号就直接判定解析失败、返回已解析的部分——整条路径被从第一个负号处**截断**。
Lucide 的 path 里 `l-1.065 3.29` 这类写法极其常见，于是几乎所有图标都只剩上半截，
看起来就像「被外轮廓裁切」。

修复是在 `number()` 开头显式接受正负号：

```swift
if characters[index] == "-" || characters[index] == "+" {
    text.append(characters[index])
    index += 1
}
```

用 Python 复刻解析器逐条验证过：修复前 **72 条 path 里有 41 条被截断**，修复后 72 条全部完整。

内缩逻辑也顺手改稳了（次要因素，保证描边外沿不越界）：

```swift
let inset = min(lineWidth / 2 + 0.5, side / 4)
let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
```

用显式矩阵而不是 `scaledBy`+`translatedBy` 链式调用，避免乘法顺序带来的偏移歧义。

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

### 尺寸与线宽都收在一处

`size` 传的是「设计稿尺寸」，**实际绘制时统一 +1**；线宽系数从 Lucide 规范的
`2/24` 降到 `1.7/24`，下限也从 1.5 降到 1.2：

```swift
private var resolvedSize: CGFloat { size + 1 }
private var strokeWidth: CGFloat {
    lineWidth ?? max(1.2, resolvedSize * 1.7 / 24)
}
```

- 24pt 图标线宽 2.0 → 1.7，整体细一点点，和放大一号的字重更配
- 12~14pt 的小图标原来被 1.5 的下限卡住，看着比大字还粗；下限降到 1.2 之后比例才顺
- 想再整体调大/调小，只改 `resolvedSize` 这一行

字号同理，全部走 `Font.app(size:)`（见 `Theme.swift`，内部 `+1`），
调用点没有一处裸 `.system(size:)`：

```swift
Text("消息通知").font(.app(size: 15))   // 实际渲染 16pt
```

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

SSE 是主通道，但移动网络下长连接会抖，中间代理还可能把 `text/event-stream` 缓冲住。
聊天页可见时额外开一条 **2 秒轮询**，而且它必须**自己拉新消息**——这是「对话不实时」的根因修复点：

`ChatModel.pollOnce()` 的第 0 步：

```swift
if newestId != nil {
    await fetchNewer()          // 按 after_id 增量拉，比全量刷新便宜
} else if messages.isEmpty {
    await refreshLatestWindow()
}
```

之前这里只轮询回执和 typing，新消息完全依赖 SSE，一旦 SSE 被缓冲就表现为
「必须退回列表再点进来才看到新消息」——因为列表页会整体重新加载。

除此之外：

- `GET .../message_receipts?message_ids[]=...` —— 问服务端自己发出的消息有没有被读
- `GET .../typing_status` —— 问服务端访客在不在打字
- `update_last_seen` 加 **8 秒节流**，避免 2 秒轮询把接口打成刷屏
- 会话列表页也有 **6 秒轮询**兜底，未读数和最新一条不会停在旧状态

SSE 正常时轮询只是冗余校验；SSE 断了它就是唯一来源。这样「永远单勾」「气泡不出现」
「新消息要退出重进」都不会因为长连接抖动而复现。

---

## 6. 消息气泡与聊天区

### 6.1 气泡对齐网页 CSS（四周各 +2pt）

配色和圆角照抄 `web/messages.css`，内边距在网页基础上**四周各放大 2pt**（真机实测网页间距偏挤）：

| 项 | 收到（左） | 发出（右） |
| --- | --- | --- |
| 圆角 | `3px 14px 14px 14px` | `14px 3px 14px 14px` |
| 网页内边距 | `8px 15px 8px 14px` | `8px 14px 8px 15px` |
| iOS 内边距 | 上 10 / 右 17 / 下 10 / 左 16 | 上 10 / 右 16 / 下 10 / 左 17 |
| 文字色 | `#1f2937` | `#fff` |
| 背景 | `#ebebeb` | `#1677ff` |
| 描边 | 无 | 无 |

`UnevenRoundedRectangle` 要 iOS 17，工程最低支持 iOS 16，所以自绘了一个
`BubbleShape: Shape, InsettableShape`：

```swift
isOutgoing
    ? BubbleShape(topLeading: 14, topTrailing: 3, bottomLeading: 14, bottomTrailing: 14)
    : BubbleShape(topLeading: 3, topTrailing: 14, bottomLeading: 14, bottomTrailing: 14)
```

注意左右内边距是**镜像互换**的（`17/16` ↔ `16/17`），网页就是靠这一点让文字
在「尖角侧」多留 1px，视觉上才不贴边。`InsettableShape` 是为了 `strokeBorder` 可用。

同一套边距同时套给了「该消息已撤回」占位、图片气泡（`padding(6)`，对应网页 `.message-card`）、
系统提示胶囊和「正在输入」三点气泡——四处不一致会显得忽宽忽窄。

### 6.2 「正在输入」气泡不被输入框挡住

三个点显示不全，是**滚动时机早于布局**——气泡刚插进列表就去 `scrollTo`，
系统按旧的内容高度算位置，于是停在了输入框底下。修法是延迟一帧再滚：

```swift
.onChange(of: model.peerTyping) { typing in
    guard typing else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
    }
}
```

再加两层留白兜底：消息列表底部 `padding(.bottom, 16)`，`TypingBubble` 自己额外
`padding(.bottom, 10)`。气泡本体也改成了真正的气泡（`BubbleShape` + 描边 + 轻阴影），
不再是一串裸圆点。

### 6.3 工具栏按钮的点击热区

左上角返回键点不动，不是图标问题，是**热区只有图标本身那 20pt**。
统一换成 `ToolbarIconButton`：

```swift
LucideIcon(name: name, size: size, color: color)
    .frame(width: 44, height: 44)   // 44×44 是苹果最小可点尺寸
    .contentShape(Rectangle())      // 让透明区域也接收点击
```

`ChatView` 还额外传了 `onBack` 闭包直接操作 `NavigationPath`，双保险：

```swift
ChatView(session: session, conversationId: route.id) {
    if !conversationPath.isEmpty { conversationPath.removeLast() }
}
```

### 6.4 会话筛选收进右上角

列表顶部原来那条「待处理 / 已完成 / 全部」占了一整行，现在改成右上角
`list-filter` 图标的 `Menu`，筛选非「全部」时图标右下角点一个小圆点提示：

```swift
Menu { ForEach(ConversationListModel.Filter.allCases) { ... } } label: {
    ZStack(alignment: .topTrailing) {
        LucideIcon(name: "list-filter", size: 18, color: Theme.accent)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        if model.filter != .all {
            Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -6, y: 10)
        }
    }
}
```

### 6.5 全屏看图：大图不能顶出屏幕

原来的实现只有 `AsyncImage { image.resizable().scaledToFit() }.ignoresSafeArea()`。
`AsyncImage` 在某些情况下拿到的建议尺寸是 nil，大图就按原始像素铺开，
直接顶到屏幕外，右上角的关闭按钮也被挤得看不见背景。

现在用 `GeometryReader` 拿真实尺寸，**显式**把图片框死，再整体 `clipped()`：

```swift
GeometryReader { proxy in
    let size = proxy.size
    AsyncImage(url: url) { phase in
        case .success(let image):
            image.resizable().scaledToFit()
                .frame(width: size.width, height: size.height)  // 关键
                .scaleEffect(scale).offset(offset)
                .gesture(magnification(size: size))
                .simultaneousGesture(pan(size: size))
                .onTapGesture(count: 2) { toggleZoom() }
    }
    .frame(width: size.width, height: size.height)
}
.clipped()   // 缩放后也不越界
```

- 捏合 1~5 倍；双击在 1× / 2.5× 之间切换；放大后可拖动，位移用
  `(size * scale - size) / 2` 夹住，拖不出黑边
- 关闭按钮是 `ZStack` 的**最后一个兄弟节点**（画在最上层），背景改成
  `ultraThinMaterial + 黑 35% + 白 28% 描边`，原来只有 16% 白，压在白底图上等于没有

### 6.6 设置页的「消息通知」不再每次闪一下

`SettingsScreen` 在切换 Tab 时会被销毁重建，`@State private var barkEnabled = false`
每次都从「关」开始渲染，等 `barkSettings()` 回来再翻成「开」——就是那个从左往右的滑动动画。

修法分三步：

1. **用缓存做初值**：`init(session:)` 里读 `UserDefaults`（键 `bark.enabled|<origin>|<accountId>`），
   首帧就是上次的样子
2. **程序化写入禁用动画**：`applyBark()` 用 `withTransaction` + `disablesAnimations`，
   服务器值只做「校正」，不会再来一次滑动
3. **Toggle 上加 `.animation(nil, value: barkEnabled)`**，只有用户自己点才动

`barkKnown` 和「是否已请求过」拆成两个状态：前者控制 Toggle 是否可点，
后者保证 `.task` 只请求一次；请求失败时保留缓存值并放开开关，不会一直置灰。

---

## 7. 长按消息：复制 / 编辑 / 撤销

长按任意一条消息会弹出系统菜单（`.contextMenu`），三项按权限动态出现：

| 菜单项 | 出现条件 | 行为 |
| --- | --- | --- |
| 复制 | 有正文（有图无文时改为「复制图片链接」） | 写 `UIPasteboard`，顶部提示「已复制」 |
| 编辑 | 自己发的 + 纯文本 + 未撤回 + 无图片 | 弹出编辑弹窗，保存走 `PATCH .../messages/{id}` |
| 撤销 | 自己发的 + 未撤回 | 二次确认后走 `DELETE .../messages/{id}` |

几个必须注意的点：

1. **气泡里不能开 `.textSelection(.enabled)`**。iOS 上长按选字的手势会抢走
   长按手势，菜单根本弹不出来。复制统一走菜单里的「复制」。
2. 判定规则与后端 `store.mutateMessage` 一致，见 `Message.canEdit(viewerId:)` /
   `Message.canRecall(viewerId:)`。已撤回的消息两个条件都不成立，因此不挂菜单。
3. 撤回后服务端返回 `content = ""`、`attachments = []`、`recalled_at > 0`，
   `ChatMessageRow` 用虚线占位「该消息已撤回」替换气泡，勾选状态一起隐藏。
4. 编辑过的消息在时间旁显示「已编辑」（`edited_at > 0 && recalled_at == 0`）。
5. 编辑 / 撤回成功后本地那条消息**直接用接口返回的对象替换**，同时 SSE 的
   `message.updated` 还会再刷一次，两者幂等。

网页后台与访客组件用的是同一套交互（右键 / 长按），实现见 `web/message-menu.js`。

---

## 8. 构建

推送到 `main` / `master` 会自动跑 `.github/workflows/build-ios.yml`：

1. 挑选 Runner 上**最新的一版 Xcode**（尽量拿到 iOS 26 SDK，走官方 Liquid Glass）
2. `python3 tools/make_xcodeproj.py` 重建工程，保证新文件一定进编译
3. `xcodebuild -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`
4. 打包成 `IfengAdmin-unsigned.ipa` 并上传 Artifact

未签名 IPA 不能直接安装，需要用 ESign / TrollStore / 自签工具或自己的开发者证书重签。
