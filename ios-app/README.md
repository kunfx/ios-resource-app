# 客服工作台 iOS 外壳

SwiftUI + WKWebView，最低 iOS 16.4。复用现有 Go 系统的业务逻辑，APP 专属界面使用会话、收件箱、设置三栏导航，不包含新的聊天业务、APNs、角标或推送服务。

本目录是独立 iOS 子项目；根目录 `.github/workflows/build-ios.yml` 是唯一需要同时上传的构建配置。无需上传 Go 代码、服务器配置、数据库、research 目录、证书或管理员密码。

## 1.1.1：界面启动检查

检查用户提供的第 6 次构建：版本是 1.1.0（build 2），IPA 中包含 MobileUI.js、MobileUI.css 和 AdminBridge.js；不能将界面未生效归因于缺少资源。相同界面脚本通过了本地 WebKit 测试，但这不等于已定位 iPhone 上的失败原因。

1.1.1（build 3）将桥接与界面脚本合并到同一个明确的 page-world 注入脚本，顺序加载；资源读取失败不再静默忽略。DOM 就绪后挂载，页面完成加载后再次做幂等检查；界面脚本通过受限消息向原生层报告 ready 或固定的错误分类，不传认证信息或聊天内容。Workflow 同时检查界面 JS、CSS 和许可文件存在。

如果仍出现旧界面，请记录原生提示中的 `UI-CHECK`、`bootstrap`、`bridge-missing`、`styles`、`dom` 或 `unsupported-page`。这些提示是诊断证据，不能仅凭无报错就认定真机显示已通过。请上传本次完整 ios-app 和 Workflow，重新构建、重新签名并安装 1.1.1；旧的第 6 次 IPA 不会因服务器刷新而自动获得本次修复。无需清空服务器数据或修改网页。

本地验证已包括 WebKit 引擎下的单脚本启动、重复挂载、保留登录状态重新加载和三栏交互；尚未执行本次 iOS Xcode 编译或 iPhone 真机安装。

## 已核对的现有后台约定

开发时只读核对了 `E:/Codex/chat-server` 下的真实源码：

| 功能 | 实际实现 |
| --- | --- |
| 后台入口 | `web/embed.go`、`internal/api/server.go` 提供 `/`、`/app`、`/app/` |
| 登录 | 网页自行 POST `/auth/sign_in`，读取响应认证头 |
| 会话链接 | `/app/?account_id=1&conversation_id=11`；不是 `/app/accounts/1/conversations/11` |
| 登录持久化 | `web/app.js` 使用 `chat-server.session.v1` 的 LocalStorage，恢复时请求 `/api/v1/profile` |
| 通知导航 | `web/notifications.js` 已支持 `chat-server-admin-message` 消息和带账户/会话参数的后台链接 |
| 访客信息、屏蔽 | 继续使用现有网页详情栏和 `/visitor_block` 接口，不新增原生实现 |
| 实时消息 | 继续使用网页现有 SSE Ticket、EventSource 和恢复逻辑 |
| 上传 | 当前网页只支持 JPG、PNG、WebP 图片；没有视频和普通文件的聊天发送入口 |

默认地址来自项目现有示例配置 `public_url: https://p12.cc.cd`。APP 不读取服务器 config.json。现在可以在登录页底部填写并保存新的服务器地址，更换域名无需修改 APP 或重新构建。

## APP 专属界面与服务器切换

- 白色主题，顶部仅显示当前页面的“会话 / 收件箱 / 设置”。底部三个 Lucide 图标：`message-circle-more`、`inbox`、`settings`，带圆角毛玻璃、高光及选中背景。玻璃效果是兼容实现，并非要求 iOS 26 的原生 Liquid Glass API。
- 会话默认显示全部。右上角筛选按钮切换待处理、已完成、全部。进入聊天后隐藏 Dock，顶部显示小头像、昵称、实际访问来源，右侧 info 打开完整访客信息和原有屏蔽/解除屏蔽等操作。
- 设置页只有管理员头像、用户名、Bark 通知、退出登录四行。没有管理员头像时显示 Lucide 占位图标，不虚构头像或新增头像上传 API。
- Bark 开关通过现有 request 闭包调用既有账户 API，未更改服务器逻辑。已有 KEY 时直接保存开关，不重传 KEY；缺少 KEY 时打开原有 KEY 设置框。点击“Bark 通知”文字可修改 KEY。权限继续由现有服务器验证。
- 普通浏览器中的后台保持原样。所有改动只打包在 APP 的 `MobileUI.js` 和 `MobileUI.css`，复用已有按钮和 API，不把业务改成一套独立原生实现。
- 登录页底部“服务器地址”支持完整 HTTPS 根地址，也支持裸域名（自动补 `https://`）。点击连接后本地保存，下次启动继续使用。地址不得包含 `/app/`、用户名密码、查询参数或 fragment；HTTPS 证书验证继续有效。
- 已登录时先退出，再切换服务器。不同域名保有各自的 WebKit 存储，不复制 Token 或跨域登录；新域名需要重新登录。当前服务器连不上时仍可在底部修改地址。
- APP 专属样式使用构造式样式表，避免为界面注入而放宽服务器 CSP，因此最低支持 iOS 16.4。
- 新地址应指向同一套 Go 客服系统的兼容后台；此 APP 适配的是现有 `web/` 页面，不能据此承诺兼容任意第三方网页或未经适配的官方 Chatwoot 网页。

## 集中配置

编辑 `Configuration/App.xcconfig`：

```text
ADMIN_BASE_URL = https:/$()/p12.cc.cd
APP_URL_SCHEME = ifengadmin
PRODUCT_BUNDLE_IDENTIFIER = com.ifeng.admin
IPHONEOS_DEPLOYMENT_TARGET = 16.4
```

`https:/$()/` 是 xcconfig 中表示 `https://` 的写法，避免 `//` 被当成注释。只填写 HTTPS 根域名，可带端口，不要添加 `/app/`、查询参数或登录凭据。APP 会自行拼接后台真实路径。

Actions 手动运行时也可临时覆盖前三项；留空则采用文件配置。`ADMIN_BASE_URL` 现在是首次启动默认地址，本地已保存的服务器地址优先。不要为了方便添加 ATS 例外、接受自签名错误或关闭 HTTPS 校验。

Bundle Identifier 和 URL Scheme 建议长期保持不变，并选择自己独有的名称。安装新的签名版本时还需要签名工具保留 Info.plist 中的 Scheme 注册。

## Windows 上上传及构建

1. 将 `ios-app/` 和 `.github/workflows/build-ios.yml` 按原路径上传至同一个 GitHub 仓库。不要只上传 `ios-app` 导致 Workflow 丢失。
2. 确认仓库允许 GitHub Actions。手动运行入口通常需要 Workflow 已位于默认分支。
3. 打开仓库 **Actions → Build iOS unsigned IPA → Run workflow**。
4. 根据需要填写 HTTPS 根域名、Bundle Identifier、Scheme，或全部留空使用配置。
5. 任务完成后，在本次运行页面底部 **Artifacts** 下载 `IfengAdmin-unsigned-运行编号`。
6. 解压 GitHub 下载的 Artifact ZIP，得到 `IfengAdmin-unsigned.ipa` 和校验文件。Artifact ZIP 不是 IPA 本身，不要直接改扩展名安装。

修改 iOS 源码或该 Workflow 的 push/PR 也会触发构建。Runner 为 `macos-15`，使用预装、已由 `xcode-select` 选中的系统 Xcode，不要求 Windows 安装 Xcode，也不需要把付费证书放进 GitHub Secrets。

工作流先运行 Node 桥接测试、工程结构检查、原生 Foundation 路由断言和 plist 检查，再通过 `xcodebuild` 编译 Release 真机 `.app`。使用 `CODE_SIGNING_ALLOWED=NO`，最后打包 `Payload/IfengAdmin.app` 为未签名 IPA。

编译日志保留为 `IfengAdmin-build-log-运行编号`。构建输出未经消音，Swift 或 Xcode 编译错误可在步骤日志定位。仓库未推送、Actions 未实际运行前，不能宣称已通过 Xcode 编译或生成了 IPA。

## 未签名与签名

本次交付的是源码和未签名构建流程，**没有生成或签名 IPA**。

- 未签名 IPA：验证工程可以构建和打包；不能直接正常安装到 iPhone。
- 已签名 IPA：还需要有效的签名证书、与设备和 App ID 匹配的 Provisioning Profile、正确的签名及 iOS 信任条件。构建成功不等于安装或签名成功。
- 本 APP 不需要 APNs entitlement、`.p8` 或推送证书；通知仍由手机上的 Bark 接收。

后续可以在有合法签名条件时，对构建产物重新签名，例如使用支持 Windows 的个人侧载工具。是否支持特定证书及安装方式由实际签名工具和 profile 决定，不能只看证书文件是否存在。

免费 Apple 个人开发者签名通常有效期较短（常见为 7 天），需要定期刷新，且有设备、应用数量及能力限制；不等同于一年有效的付费分发。免费个人签名不是本 Workflow 已实现的功能，也不能在没有有效身份和 profile 时凭空签名。

如以后接入 CI 签名，应另设签名流程，从 Secrets 临时导入证书及 profile，并用实际 Team ID、App ID 配置签名后导出；不要把 Apple ID 密码、证书、profile 提交到 Git。当前未签名 Workflow 不会访问这些信息。

## Bark 唤醒与会话定位

默认注册 `ifengadmin`，与官方 Chatwoot 的 `chatwootapp` 相互独立：

```text
ifengadmin://
ifengadmin://conversation/123
ifengadmin://conversation/123?account_id=2
```

第一种只唤醒，保持当前页面。第二种采用当前网页登录的账户。多账户建议明确携带 `account_id`，第三种会打开账户 2 的会话 123。

APP 只接受正整数和 JavaScript 安全整数范围；不接受额外路径、重复参数、用户名密码、任意网站地址、Token 或其他查询字段。ID 仅用于路由，实际访问继续由网站认证、账户及收件箱权限验证。

首次尚未登录时，APP 保留待打开目标；网页登录完成后才导航。若目标属于其他账户，不自动切换身份或越权访问，而是提示退出网页并登录相应账户。不存在或无权限的会话继续由网页返回错误，并显示通用提示。

优先借用现有网页的通知导航监听器，在当前页面打开会话。iOS 的 WKWebView 如果没有可用的 ServiceWorker 容器，则加载 `/app/?account_id=...&conversation_id=...`。这种后备路径会重新加载；检测到当前输入文字或待发送图片时，先请用户确认，避免悄悄丢失草稿。网页原有登录和权限验证保持不变。

**当前服务器的 Bark URL 仍保持原样。** 本次没有修改 Bark 后端。如果它现在发送 `chatwootapp://`，仍会唤醒官方 Chatwoot APP；要唤醒本 APP，未来需要把服务器最终发送的 URL 改为上面的 `ifengadmin://...`。具体会话链接必须使用真实账户、会话 ID，不能写死示例编号。

测试链接可放入 iPhone Safari 的测试 HTML，通过明确点击触发：

```html
<a href="ifengadmin://">打开客服工作台</a>
<a href="ifengadmin://conversation/123?account_id=2">打开测试会话</a>
```

也可创建 iOS 快捷指令：URL → 打开 URL。用真实可访问的会话编号测试。未安装或未签名安装成功前不能唤醒。无需服务器 AASA、Universal Links 配置或 APNs。

## 原生适配说明

- 使用 `WKWebsiteDataStore.default()`，保留 Cookie、LocalStorage 等网站数据。不在原生层保存管理员密码或复制登录 Token。登录有效期由服务器决定；卸载、清理数据、改域名、会话过期会要求重新登录。
- WebKit 原生 `<input type="file">` 负责相册、相机、文件选择；Info.plist 声明相机和相册用途。当前网页 accept 与后端仍只接受 JPG/PNG/WebP。没有通过注入方式放开视频或普通文件发送。
- 当前网页支持的图片压缩、预览、聊天编辑器、屏蔽、收件箱设置、Bark 设置全部继续加载。APP 仅简化导航及布局，原网页顶部状态文字和导航替换为 APP 专属界面。
- 若网页提供视频、PDF、图片或下载链接，WebKit 可显示受支持格式；不支持内嵌显示的文件及 attachment 响应由 `WKDownload` 下载，交给 Quick Look、保存到文件或系统分享。独立附件预览页面提供返回和下载入口。实际文件类型、编解码及服务端 Content-Disposition 影响预览能力。
- 下载沿用 WebKit 请求链路，不另行拼装认证头；默认仅允许配置服务器的 HTTPS 下载和重定向。当前项目本地媒体不需要外部 CDN。未来使用 CDN 时需要明确增加受信任来源，不能默认向任意域名转发认证。
- 同源链接在 APP 内打开，用户点击的外站链接交给系统浏览器；电话、邮件、短信链接交给系统。拦截任意 Scheme、自动外站重定向及主站 HTTP 降级。`target="_blank"` 不创建第二个登录容器。
- 支持网页 alert、confirm 和 prompt，访客屏蔽确认框不会因缺少 WKUIDelegate 而静默失效。
- WebView 遵循安全区及键盘避让，滚动交互可收键盘。支持横竖屏，APP 专属样式只作用于当前 WebView 的后台主文档，不作用于外站或普通浏览器。
- 下拉刷新是软同步：通过网页既有 online/pageshow/visibilitychange 恢复流程刷新，而不是整页重载清空草稿。APP 回到前台或网络恢复时也复用该流程，并关闭先前可能冻结的 SSE，由网页重新申请短期 Ticket。
- iOS 会挂起后台 WebView；不承诺后台一直运行 SSE，也不以本 APP 接收系统推送。后台通知由 Bark 提供，回前台后恢复连接。网页进程被系统回收时提供重新加载入口；内存草稿无法保证恢复。
- 主文档加载、HTTP 错误和网络异常提供重试；已加载页面内的业务错误仍由网页原有提示处理。不会用原生错误层覆盖每个失败的业务 API。

## 目录

```text
ios-app/
  Configuration/App.xcconfig
  IfengAdmin.xcodeproj/
  IfengAdmin/
    App/             SwiftUI 入口与集中配置
    WebView/         WebView、导航、原生对话框、生命周期
    URLHandler/      严格链接解析与来源策略
    FileHandler/     WebKit 下载、预览、保存和分享
    Resources/       APP 侧桥接、专属三栏界面、样式、图标及 Lucide 许可
    Info.plist
  Tests/             Node 行为测试、工程检查、macOS 原生路由断言
  README.md
.github/workflows/build-ios.yml
```

没有引入第三方 iOS SDK、UI 框架或网络依赖。

## 验收清单和真实限制

Windows 可运行：

```powershell
node ios-app/Tests/validate-project.mjs
node --test ios-app/Tests/AdminBridge.test.mjs
```

当前 Windows 检查结果：工程引用/资源及 XML 解析通过，13 项 Node 行为测试通过。其中一项直接加载 `Tests/fixtures/notifications-0.5.43.js`（从现有网页只读复制的导航契约快照），验证实际监听器收到正确账户和会话；这个快照不打包进 APP。

另已运行 `Tests/MobileUI.browser.mjs`：以真实 `web/` HTML/脚本为界面，所有 API 使用 Mock，验证三栏导航、默认全部会话、筛选、昵称/来源、屏蔽和解除屏蔽、原发送消息处理器、Bark 开关及缺少 KEY 时配置流程、收件箱编辑、退出、横屏和小屏尺寸。Chrome 浏览器检查未发现 JS 页面异常、水平溢出或严格 CSP 违规；不会访问真实服务器或发送真实 Bark 通知。

可选重跑方式：设置 `IFENG_WEB_SOURCE` 为 Go 项目的 `web` 目录、`IFENG_PLAYWRIGHT` 为本机 Playwright 模块路径、`IFENG_BROWSER_CHANNEL=chrome`，然后运行 `node ios-app/Tests/MobileUI.browser.mjs`。此集成测试需要本机实际网页源码及浏览器，未放入 CI 的默认运行步骤。

这些检查覆盖脚本语法、认证等待、账户隔离、现有网页导航事件、草稿确认信号、隐私边界、SSE 恢复钩子。它们不替代 Swift 编译或 iPhone 真机验证。原生 URL/导航断言位于 `Tests/main.swift`，由 macOS Runner 实际编译执行。

必须在 GitHub Actions 验证：Release Xcode 编译、原生 URL 断言、资源嵌入、未签名 IPA 结构及 Artifact 上传。本地 Windows 未运行这些步骤。

本次新增的服务器域名校验断言同样由 GitHub Actions 的原生 URL 测试执行。服务器地址保存/重启恢复、WKWebView 实际键盘安全区、iPhone 玻璃效果及系统版本兼容仍需安装新的签名 IPA 后真机确认。

必须由用户合法签名安装后在真实 iPhone 验证：

1. 冷启动、登录、结束进程再打开后的登录保留，以及退出账号。
2. 会话列表、历史与实时收发、已读、输入状态、前后台及断网恢复。
3. 文字编辑、键盘避让、下拉软同步、滚动、横竖屏和刘海安全区。
4. 访客 IP/地区/浏览器/系统、屏蔽与解除屏蔽、收件箱设置和其他网页管理入口。
5. 相册与拍照 JPG/PNG/WebP、图片本地处理及发送、取消选择、权限拒绝。iPhone 相册 HEIC 是否由选择器转换为网页接受的格式也需实测；不承诺后端本来不支持的格式可发送。
6. 当前网站实际提供的附件预览、下载、保存到文件、分享；未来视频/PDF/其他文件须先有网站支持的入口。
7. APP 前台、后台、冷启动三种状态点击 Scheme；未登录→登录后定位；多会话先后点击；无权限/不存在会话；跨账户拒绝；草稿后备导航确认。
8. 外站链接与新窗口进入系统浏览器，主站保持 WebView；无效 HTTPS 证书不被接受。
9. 服务器未来配置新 Scheme 后，实际 Bark 横幅点击是否唤醒本 APP。当前 Bark 发送逻辑未改变，不能声称已完成这一步。

参考原生能力：[WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)、[WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate)、[Apple URL Scheme](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app)、[Apple Membership](https://developer.apple.com/support/compare-memberships/)。Actions 使用 [checkout](https://github.com/actions/checkout/tree/v4) 与 [upload-artifact](https://github.com/actions/upload-artifact/tree/v4) 官方 Action。
