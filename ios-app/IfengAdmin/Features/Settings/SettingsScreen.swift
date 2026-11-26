import SwiftUI
import UIKit

/// 设置页。严格四行：账号 / 服务器地址 / 消息通知 / 退出登录。
/// 版本号与实时连接状态放在页脚，不占用行数。
struct SettingsScreen: View {
    @EnvironmentObject private var app: AppState

    let session: AppSession

    /// 开关状态。**用缓存做初值**，这样每次进设置页都是「上次的样子」，
    /// 不会先渲染成关闭、再被服务器值顶成开启（那个从左往右的滑动动画）。
    @State private var barkEnabled: Bool
    /// 是否已经有可信值（缓存或服务器）。没有之前 Toggle 置灰，避免误触。
    @State private var barkKnown: Bool
    @State private var didLoadBark = false
    @State private var isUpdatingBark = false
    @State private var barkMessage: String?
    @State private var confirmingLogout = false
    @State private var copiedHint: String?

    init(session: AppSession) {
        self.session = session
        let cached = Self.cachedBarkEnabled(for: session)
        _barkEnabled = State(initialValue: cached ?? false)
        _barkKnown = State(initialValue: cached != nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                accountCard
                actionCard
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .background(Theme.screenBackground)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didLoadBark else { return }
            didLoadBark = true
            await loadBark()
        }
        .overlay(alignment: .top) {
            if let copiedHint {
                Text(copiedHint)
                    .font(.app(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            "退出后需要重新输入账号密码。",
            isPresented: $confirmingLogout,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await app.logout() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 账号（第 1 行）

    private var accountCard: some View {
        HStack(spacing: 12) {
            AdminAvatar(size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.app(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let email = session.profile.email, !email.isEmpty {
                    Text(email)
                        .font(.app(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if session.isAdministrator {
                Text("管理员")
                    .font(.app(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: 第 2~4 行

    private var actionCard: some View {
        VStack(spacing: 0) {
            // 第 2 行：服务器地址（点击复制）
            Button {
                UIPasteboard.general.string = session.server.origin
                showHint("已复制服务器地址")
            } label: {
                rowShell {
                    HStack(spacing: 10) {
                        LucideIcon(name: "globe", size: 17, color: .secondary)
                        Text("服务器地址")
                            .font(.app(size: 15))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(session.server.displayHost)
                            .font(.app(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        LucideIcon(name: "copy", size: 12, color: Color.secondary.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            divider

            // 第 3 行：消息通知
            rowShell {
                HStack(spacing: 10) {
                    LucideIcon(name: "bell", size: 17, color: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("消息通知")
                            .font(.app(size: 15))
                            .foregroundStyle(.primary)
                        if let barkMessage {
                            Text(barkMessage)
                                .font(.app(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if isUpdatingBark {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Toggle("", isOn: barkBinding)
                            .labelsHidden()
                            .tint(Theme.accent)
                            .disabled(!barkKnown)
                            // 程序化回写（缓存 / 服务器）不参与动画，只有用户自己点才动。
                            .animation(nil, value: barkEnabled)
                    }
                }
            }

            divider

            // 第 4 行：退出登录
            Button {
                confirmingLogout = true
            } label: {
                rowShell {
                    HStack(spacing: 10) {
                        LucideIcon(name: "log-out", size: 17, color: Theme.danger)
                        Text("退出登录")
                            .font(.app(size: 15))
                            .foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .background(cardBackground)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 40)
    }

    private func rowShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
    }

    // MARK: 页脚

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(app.realtimeHealthy ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(app.realtimeHealthy ? "实时连接正常" : "实时连接恢复中（轮询兜底）")
                    .font(.app(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("\(AppConfig.appDisplayName) \(shortVersion)（\(buildNumber)）")
                .font(.app(size: 11))
                .foregroundStyle(.secondary)

            Text("账号 #\(session.accountId) · \(session.server.displayHost)")
                .font(.app(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.8))
        }
        .padding(.top, 4)
    }

    private var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    // MARK: 数据

    /// 不能用 `$barkEnabled` 直接绑 Toggle：请求成功/回滚时程序化赋值也会触发 onChange，
    /// 会形成「赋值 → 请求 → 再赋值」的死循环。这里用自定义 Binding 把「用户操作」和
    /// 「服务器回写」彻底分开。
    private var barkBinding: Binding<Bool> {
        Binding(
            get: { barkEnabled },
            set: { newValue in
                barkEnabled = newValue
                Task { await updateBark(enabled: newValue) }
            }
        )
    }

    // MARK: 通知开关的本地缓存

    /// 键里带上服务器与账户，换账号不会串。
    private static func cacheKey(for session: AppSession) -> String {
        "bark.enabled|\(session.server.origin)|\(session.accountId)"
    }

    private static func cachedBarkEnabled(for session: AppSession) -> Bool? {
        UserDefaults.standard.object(forKey: cacheKey(for: session)) as? Bool
    }

    /// 程序化写入：更新状态 + 落盘，并且**禁用动画**。
    /// 这样「进页面时用服务器值校正」不会又变成一次从左往右的滑动。
    private func applyBark(_ enabled: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            barkEnabled = enabled
            barkKnown = true
        }
        UserDefaults.standard.set(enabled, forKey: Self.cacheKey(for: session))
    }

    private func loadBark() async {
        do {
            let settings = try await session.api.barkSettings()
            applyBark(settings.enabled)
            barkMessage = settings.hasKey ? nil : "未配置 Bark KEY，需先在网页后台填写。"
        } catch {
            // 服务端未实现 Bark 时静默降级，不打扰用户。
            barkMessage = "当前服务器未提供通知配置。"
            // 拉不到就保留缓存值，只是把开关放开，别一直置灰。
            barkKnown = true
        }
    }

    private func updateBark(enabled: Bool) async {
        isUpdatingBark = true
        defer { isUpdatingBark = false }
        // 先落盘：即使请求失败或用户中途杀掉 APP，下次进来也还是他刚才选的状态。
        UserDefaults.standard.set(enabled, forKey: Self.cacheKey(for: session))
        do {
            let settings = try await session.api.updateBark(enabled: enabled)
            applyBark(settings.enabled)
            barkMessage = settings.hasKey ? nil : "未配置 Bark KEY，需先在网页后台填写。"
        } catch let error as APIError {
            barkMessage = error.message
            // 回滚开关，避免界面状态和服务器不一致。
            applyBark(!enabled)
        } catch {
            barkMessage = "设置失败，请重试。"
            applyBark(!enabled)
        }
    }

    private func showHint(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { copiedHint = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copiedHint = nil }
        }
    }
}
