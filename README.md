# 在线客服 · iOS 管理员 APP（原生 SwiftUI）

基于现有 Go 客服系统（服务端版本 `0.5.43`）的原生 iOS 管理员客户端。
**纯 SwiftUI 实现，没有任何 WKWebView 加载网页后台**，所有数据都走服务端真实接口。

- Bundle ID：`com.ifeng.admin`
- URL Scheme：`ifengadmin`
- 最低系统：iOS 16.0
- 默认后台地址：`https://p12.cc.cd`（来自 `Info.plist` 的 `DefaultServerURL`）

接口逐条对照见 [`../docs/iOS-API对接清单.md`](../docs/iOS-API对接清单.md)。

---

## 一、目录结构

```
ios-app/
├── IfengAdmin/
│   ├── App/
│   │   ├── AppConfig.swift          集中配置（Scheme、超时、默认服务器、页大小）
│   │   ├── AppState.swift           全局状态机、登录/退出、实时通道生命周期、深链解析
│   │   ├── IfengAdminApp.swift      @main 入口
│   │   ├── KeychainStore.swift      凭据存取（按服务器 host 分账号）
│   │   └── ServerAddress.swift      服务器地址校验 + 三头凭据模型
│   ├── Core/
│   │   ├── APIClient.swift          全部 REST 调用、错误映射、multipart 上传
│   │   ├── RealtimeClient.swift     SSE（ticket → 事件流 → 解析 → 退避重连）
│   │   ├── Models.swift             与服务端 JSON 一一对应的模型
│   │   ├── ChatModel.swift          单会话：分页、发送、已读、屏蔽、状态、增量
│   │   ├── ConversationListModel.swift  列表：筛选、分页、事件合并
│   │   └── ImagePreparer.swift      HEIC → JPEG 真转码（白底、长边 1600、≤10MiB）
│   ├── Design/
│   │   ├── LucideIcon.swift         内联 Lucide SVG path + 自写路径解析器
│   │   └── Theme.swift              色板、Liquid Glass 兼容实现、头像、时间格式
│   ├── Features/
│   │   ├── Root/RootView.swift      根切换 + 底部三图标 Dock
│   │   ├── Login/LoginView.swift    登录页
│   │   ├── Conversations/ConversationListScreen.swift
│   │   ├── Chat/ChatView.swift      聊天页（消息、图片、发送、表情）
│   │   ├── Chat/ChatMessageRow.swift
│   │   ├── Chat/VisitorInfoView.swift  访客信息 / 状态 / 屏蔽
│   │   ├── Inbox/InboxScreen.swift  收件箱
│   │   └── Settings/SettingsScreen.swift  设置（严格四行）
│   ├── Assets.xcassets/             图标、强调色、启动背景
│   └── Info.plist
├── IfengAdmin.xcodeproj/            Xcode 工程（已生成，可直接打开）
├── project.yml                      XcodeGen 兜底配置
├── tools/make_xcodeproj.py          生成/重建 pbxproj
├── tools/make_icon.py               生成 1024×1024 图标 PNG
└── README.md
```

`.github/workflows/build-ios.yml` 在仓库根目录。

---

## 二、本地构建

```bash
cd ios-app
open IfengAdmin.xcodeproj
# 选择真机或模拟器 → Run
```

命令行编译（不需要签名）：

```bash
xcodebuild \
  -project IfengAdmin.xcodeproj \
  -scheme IfengAdmin \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

如果 `IfengAdmin.xcodeproj` 因为环境差异读不出来，用 XcodeGen 重建：

```bash
brew install xcodegen
cd ios-app && xcodegen generate
```

或直接用脚本重建（不依赖 XcodeGen）：

```bash
cd ios-app && python3 tools/make_xcodeproj.py
```

---

## 三、GitHub Actions 出包

`.github/workflows/build-ios.yml`：

- Runner：`macos-15`（系统自带 Xcode，无需额外安装）
- 触发：push 到 `main`/`master` 且改动 `ios-app/**`，或手动 `workflow_dispatch`
- 步骤：校验工程 → `Release` + `-sdk iphoneos` + `CODE_SIGNING_ALLOWED=NO` 编译 → 打包 `Payload/` 成 `IfengAdmin-unsigned.ipa` → 上传 Artifact
- 产物里会打印 Bundle ID、URL Scheme、`DefaultServerURL`、最低系统版本、签名状态
- 失败时把 `/tmp/build.log` 作为 `build-log` Artifact 上传，并把 `error:` 摘要写进 Job Summary

下载：Actions → 对应 run → Artifacts → `IfengAdmin-unsigned-ipa`。

---

## 四、未签名 IPA 怎么装

**未签名 IPA 不能直接双击安装。** 必须自行签名后装机，常见三种方式：

| 方式 | 说明 |
| --- | --- |
| 自签工具（ESign / Scarlet / AltStore 等） | 把 IPA 导入工具，用你自己的 Apple ID 证书重签。免费 Apple ID 签的 App 7 天过期、最多 3 个 |
| 开发者证书 + `codesign` | 有付费开发者账号时，解压 IPA → `codesign -f -s "Apple Development: xxx" --entitlements ... IfengAdmin.app` → 重新 zip |
| Xcode 直接跑 | 打开工程，填自己的 Team，连真机 Run（最省事，适合调试） |

免费 Apple ID 签名需要在 `Signing & Capabilities` 里把 Bundle ID 改成你自己的唯一 ID（如 `com.yourname.ifeng.admin`），否则会因 Bundle ID 被占用而失败。

---

## 五、必须知道的实现细节

### 1. 认证是三头，不是 Bearer

`access-token` / `uid` / `client` 三个请求头缺一不可。凭据存在 Keychain（`kSecClassGenericPassword`），按服务器 host 分账号保存，换服务器不会串号。

启动时用 `GET /api/v1/profile` 验证凭据：

- **只有 401 才清凭据**（避免离线/超时把用户误踢下线）
- 超时、不可达 → 显示「无法连接服务器 + 重试」，凭据保留

### 2. 会话列表必须显式传 `assignee_type=all`

服务端默认是 `me`，只传 `status` 会漏掉未分配的会话。APP 固定传 `all` + `sort_by=latest`。

### 3. 实时通道复用现有 SSE，不接 APNs

- `POST /api/v1/realtime/ticket` 申请一次性 ticket（30 秒、用一次）
- **申请 ticket 和连事件流都必须带 `Origin`**，且必须与服务端 `public_url` 完全一致，否则 403
- ticket 已被消费时服务端返回 **204**：原生 EventSource 会重试同一 URL，所以 APP 收到 204 就重新申请 ticket
- 事件 ID 是 `<序号>:<后缀>`，不能用 `message_id` 代替；只有整条事件处理成功才推进 `last_event_id`
- SSE 只给摘要，聊天页收到 `message.created` 后用 `after=<最新 id>` 循环补拉到完整消息
- 断线指数退避 1.5s → 30s；进后台主动断开，回前台重连 + 全量 resync

### 4. 发消息用 echo_id 做幂等

`echo_id` 形如 `ios-<UUID>`，**重试时保持不变**。服务端返回 `201` 表示新建、`200` 表示幂等命中。气泡在收到真实 message（`echo_id` 匹配）后自动消失。

### 5. 图片必须真转码

服务端只接受 JPEG/PNG/WebP ≤10MiB，且要求 MIME、文件头、扩展名一致。相册里的 HEIC 改后缀无效，APP 用 `UIGraphicsImageRenderer` 真正重绘为 JPEG（白底、长边 ≤1600、质量 0.86→0.40 自适应）。

multipart 字段名固定为 `attachments[]`（管理员侧），写错就 422；每次只能一张图。

### 6. 屏蔽是管理员专属

`PATCH .../visitor_block` 仅 `administrator` 角色可用。APP 侧是原生 `Toggle` + `alert` 二次确认，确认后才发请求，取消不发。

### 7. Liquid Glass 是兼容实现

iOS 26 之前没有系统级 Liquid Glass API。Dock 用 `.ultraThinMaterial` + 顶部高光渐变 + 渐变描边 + 柔和阴影拼出玻璃质感，**iOS 16 即可运行**，不会因为调用新 API 在旧系统崩溃。

底部只允许三个 26pt 的 Lucide 图标（`message-circle-more` / `inbox` / `settings`），图标是内联 SVG path 在运行期解析成 SwiftUI `Path` 绘制，不是位图、不是 SF Symbols。

---

## 六、页面结构

```
AppState.phase
├── .launching            → LaunchView（Logo + 菊花）
├── .login                → LoginView
├── .unreachable(message) → UnreachableView（重试）
└── .ready                → RootView
                             ├── 会话 Tab（NavigationStack）
                             │     ├── ConversationListScreen  标题「会话」+ 右上筛选 Menu
                             │     └── ChatView                返回 / 头像 / 昵称 / 来自来源 / Info
                             │           └── sheet: VisitorInfoView  资料 · 来源 · 位置 · IP · 设备 · 状态 · 屏蔽
                             ├── 收件箱 Tab（NavigationStack）
                             │     ├── InboxScreen             inbox 列表 + 每箱待处理数
                             │     ├── ConversationListScreen  该箱会话（带返回按钮）
                             │     └── ChatView
                             └── 设置 Tab
                                   └── SettingsScreen         头像 / 用户名 / Bark 开关 / 退出登录
```

底部 Dock 只在三个 Tab 的一级页面出现；进入二级页面自动隐藏。

各页交互要点：

| 页面 | 关键交互 |
| --- | --- |
| 登录 | 服务器地址可改可存；回车依次跳转输入框；失败原样展示服务端文案；成功后密码清空 |
| 会话 | 下拉刷新（合并去重）、触底翻页、筛选切换即重新请求、SSE 增量合并、404 自动移除 |
| 聊天 | 顶部日期分隔 + 30 秒/发送方变化分组；点图片全屏预览；长按气泡复制；发送中 65% 透明、失败可重试/删除 |
| 访客信息 | 来源可点开链接；位置带国旗；状态一键切换；屏蔽需二次确认 |
| 收件箱 | 下拉刷新；点击进入该箱会话列表 |
| 设置 | Bark 无 KEY 时拦截并提示；退出登录二次确认 |

---

## 七、配置项一览（改这里就够）

| 配置 | 位置 |
| --- | --- |
| 默认服务器地址 | `IfengAdmin/Info.plist` → `DefaultServerURL`（也可在登录页手改，登录后记住） |
| URL Scheme | `AppConfig.urlScheme` + `Info.plist` → `CFBundleURLSchemes`（两处必须一致） |
| Bundle ID / 版本号 / 最低系统 | `project.yml` 与 `project.pbxproj` |
| 请求/上传/流超时 | `AppConfig.requestTimeout` / `uploadTimeout` / `streamIdleTimeout` |
| 每页条数 | `AppConfig.pageSize`（服务端固定 20，不要改） |

---

## 八、已知限制（都来自服务端现状，未擅自改后端）

1. **Bark 通知点开不会跳到本 APP。** `internal/notification/bark.go` 里的跳转 URL 固定为 `chatwootapp://`。APP 只注册了 `ifengadmin`，所以 Bark 推送点开后是打开（或尝试打开）另一个 App。要让 Bark 直达本 APP，需要把服务端该常量改为 `ifengadmin://conversation/<id>`，属于另一项需要单独授权的改动。
2. **管理员头像为空。** 服务端 `avatar_url` 恒为空串，设置页使用占位图标。
3. **设置页严格四行。** 没有服务器地址编辑、没有通知配置入口；换服务器在退出登录后的登录页修改。
4. **收件箱没有「分类」。** 后端只有 inbox 实体，因此页面是「inbox 列表 + 每箱待处理数 + 点击进入该箱会话」。
5. **图片链接约 24 小时过期。** 过期后气泡显示占位图，重新进入会话会拿到新签名链接。
6. **无推送。** 后台不保证 SSE 存活，杀进程后不会有通知；实时能力仅在前台生效。

---

## 九、深链

```
ifengadmin://conversation/123
ifengadmin://conversation/123?account_id=2
```

- 只接受 `conversation/<正整数>`；query 只允许 `account_id`，其它参数一律判为非法并忽略
- 未登录：先记下目标，登录成功后自动跳转
- 已登录但 `account_id` 与当前账户不符：顶部提示并忽略，不跳转
- 会话不存在或无权限：聊天页展示服务端返回的提示
