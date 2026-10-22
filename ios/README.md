# AppKu for iOS（SwiftUI 客户端）

独立客户端，通过 Laravel 的 `/api/*` 读写网站数据。
**App 不连接 MySQL**，所有权限、积分、VIP、下载地址都由服务端校验后下发。

- 最低系统：iOS 16.0
- 界面：SwiftUI + MVVM（无第三方依赖）
- 工程生成：XcodeGen（`project.yml`），仓库里不提交 `.xcodeproj`
- 打包：GitHub Actions 在 macOS runner 上无签名构建，产出未签名 `.ipa`

---

## 一、界面结构

底部 5 个 Tab，没有首页：

| Tab | 内容 |
|---|---|
| 应用 | 网站「应用」大分类，顶部搜索框（放大镜在最左）+ 子分类筛选 + 两列网格 |
| 游戏 | 网站「游戏」大分类，同上 |
| 巨魔 | 网站「巨魔」大分类，同上 |
| 下载 | 内置下载管理，列表 + 实时进度条，**不跳浏览器** |
| 我的 | 未登录时是登录表单；登录后显示与网站 `/user` 一致的 9 个菜单 |

「我的」菜单（顺序与网站侧边栏一致）：
站内消息 · 个人中心 · 修改资料 · 下载记录 · 签名证书 · 升级会员 · 我的积分 · 赚取积分 · 我的订单 · 问题反馈
（另外单独一组：教程文章 / 服务器地址 / 退出登录）

## 二、目录结构

```
ios/
├── project.yml                     # XcodeGen 工程定义
├── Support/Info.plist              # Info.plist（含文件共享，下载的 ipa 能在「文件」App 里取）
├── Sources/
│   ├── App/
│   │   ├── AppKuApp.swift          # @main + RootView + 5 个 Tab
│   │   ├── AppConfig.swift         # 服务器地址（可在 App 内修改）
│   │   ├── SessionStore.swift      # 登录态 / 用户资料 / 积分
│   │   └── Theme.swift             # 配色与卡片样式
│   ├── Core/
│   │   ├── APIClient.swift         # 统一 HTTP 层（Bearer Token）
│   │   ├── APIError.swift
│   │   ├── KeychainStore.swift     # token 存钥匙串
│   │   ├── Models.swift            # 与后端 JSON 一一对应的 Codable
│   │   └── Formatters.swift
│   ├── Components/                 # 卡片、状态视图、缓存图片
│   ├── Features/
│   │   ├── Catalog/                # CategoryTabView：三个分类页共用
│   │   ├── Downloads/              # DownloadManager（URLSession）+ 下载列表
│   │   ├── Detail/                 # 详情 + 两步下载（request/confirm）
│   │   ├── Articles/               # 教程文章（WKWebView 渲染 HTML）
│   │   ├── Messages/               # 站内消息 + 积分明细
│   │   ├── Profile/                # 我的：登录表单 / 菜单 / 个人中心 / 修改资料 / 商城 / 订单 / 反馈
│   │   └── Auth/                   # 登录（支持内嵌与弹窗两种形态）
│   └── Resources/Assets.xcassets   # AppIcon / AccentColor
└── make_icon.py                    # 纯 Python 生成 1024 图标（可忽略）
```

## 三、内置下载管理

- 下载走 `URLSessionDownloadTask`，**不会打开 Safari**
- 列表实时显示进度条、百分比、已下载/总大小
- 支持暂停 / 继续（resumeData 断点续传）/ 重试 / 删除 / 清空已完成
- 文件保存到 `Documents/Downloads`，开启 `UIFileSharingEnabled`，
  可以在「文件」App → 我的 iPhone → AppKu → Downloads 里直接取走 ipa
- 完成后点「分享 / 安装」可 AirDrop 或直接分享给轻松签等签名工具
- 下载任务列表持久化，重启 App 后保留（进行中的任务会变成「已暂停」）

---

## 四、本地构建（需要 macOS + Xcode）

```bash
brew install xcodegen
cd ios
xcodegen generate
open AppKu.xcodeproj
```

在 Xcode 里选一台真机或模拟器直接 Run 即可。
真机调试需要你自己配置 Team；CI 里是无签名构建，不需要证书。

---

## 五、云端出未签名 ipa（Windows 也能做）

工作流文件：`.github/workflows/ios-unsigned-ipa.yml`

触发方式：

1. 把仓库推到 GitHub（`main` 分支，且包含 `ios/` 目录）
2. `Actions` → **Build Unsigned IPA** → `Run workflow`
   - 可填 `version`（如 `1.2.0`）和 `build`（如 `12`）
3. 跑完在 **Artifacts** 下载 `AppKu-unsigned-ipa`，解压得到 `AppKu-unsigned.ipa`

工作流做的事情：

```
checkout → brew install xcodegen → xcodegen generate
→ xcodebuild build -sdk iphoneos -configuration Release
   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
→ mkdir Payload; cp AppKu.app Payload/
→ zip -qry AppKu-unsigned.ipa Payload
→ upload-artifact
```

> 注意：`Payload/AppKu.app` 里没有 `_CodeSignature`，这是正常的，签名工具会重新签名。

---

## 六、用签名工具安装到手机

1. 下载 `AppKu-unsigned.ipa`
2. 用 **轻松签 / Esign / Sideloadly / AltStore** 打开
3. 导入你的 `.p12` 证书 + `.mobileprovision` 描述文件（或 Apple ID 自签）
4. 确认 Bundle ID 与描述文件一致：`top.appku.app`
   - 如果描述文件的 App ID 不同，在签名工具里直接改 Bundle ID 即可
5. 安装，首次打开需在「设置 → 通用 → VPN 与设备管理」里信任证书

---

## 七、服务器地址

已确认默认值为 **`https://ifeng.app`**（`AppConfig.defaultBaseURL`），与项目里的 API 已打通。

如需切换（测试环境、换域名）：

1. **登录页 → 服务器地址**（展开后填写，保存即生效）
2. **我的 → 服务器地址**（改完自动退出登录）
3. 直接改 `Sources/App/AppConfig.swift` 里的 `defaultBaseURL` 重新打包

填写规则：只填站点根地址，App 会自动拼 `/api/...`。
例如 `https://ifeng.app` → 实际请求 `https://ifeng.app/api/apps`。

> 后端 API 已启用：`routes/api.php` 已注册，`api_tokens` 表由迁移创建。
> 服务器上需要执行 `composer dump-autoload -o && php artisan migrate --force && php artisan optimize:clear`，
> 详见 `../ios-backend/README.md` 第二节。

---

## 八、安全设计（重要）

| 关注点 | 做法 |
|---|---|
| 不直连数据库 | 客户端只访问 Laravel `/api/*`，MySQL 只在服务端 |
| 登录 | `POST /api/login` 换 64 位随机 token，库里只存 `sha256`，30 天过期 |
| Token 存储 | iOS Keychain（`kSecAttrAccessibleAfterFirstUnlock`），不进 UserDefaults |
| 权限判断 | 积分、VIP、每日免费次数全部在服务端 `DownloadPolicy` 里算，客户端只展示 |
| 下载地址 | 未解锁时 `url` 字段为 `null`；解锁后拿到 2 小时有效的签名地址 |
| 扣积分 | `download/confirm` 在数据库事务 + 行锁内二次校验，防连点/多设备刷分 |
| 401 处理 | `APIClient` 收到 401 立即清空本地 token 并回到未登录态 |

---

## 九、接口清单

详见 `../ios-backend/README.md`。App 实际使用：

```
POST /api/login
POST /api/logout
GET  /api/user/profile
POST /api/user/profile/update
GET  /api/categories
GET  /api/apps?q=&category_id=&parent_slug=&sort=&page=
GET  /api/apps/{id}
GET  /api/apps/{id}/comments
POST /api/apps/{id}/comments
POST /api/apps/{id}/download/request
POST /api/apps/{id}/download/confirm
GET  /api/download/{app}/{index}      # 签名跳转（下载器直接请求）
GET  /api/downloads                   # 下载记录
GET  /api/sign-in/status              # 签到状态 + 邀请信息
POST /api/sign-in                     # 每日签到
GET  /api/shop/goods                  # 签名证书商品
GET  /api/vip/packages                # 会员套餐
GET  /api/orders?type=shop|vip|recharge
GET  /api/tickets                     # 问题反馈列表
GET  /api/tickets/{id}                # 反馈详情（含对话）
POST /api/tickets                     # 新建反馈
GET  /api/articles
GET  /api/articles/{id}
GET  /api/messages
POST /api/messages/{id}/read
POST /api/messages/read-all
GET  /api/points/logs
```

---

## 十、常见问题

**首页一直转圈 / 提示网络失败**
先确认 `https://你的域名/api/apps` 在浏览器能返回 JSON。
返回 404 说明 `routes/api.php` 没注册（见 `ios-backend/README.md` 第二步）。

**登录提示 422**
网站账号是邮箱登录，`email` 必须是 `users.email` 里存在的那个。

**详情页没有下载按钮**
`download_links` 为空，说明该资源后台没配置下载地址。

**文章空白**
后台文章的 `content` 为空，或文章未发布（`is_published = 0`）。
