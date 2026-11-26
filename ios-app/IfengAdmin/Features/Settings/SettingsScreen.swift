import SwiftUI
import UIKit

/// 设置页。严格四行：账号 / 服务器地址 / 消息通知 / 退出登录。
/// 版本号与实时连接状态放在页脚，不占用行数。
struct SettingsScreen: View {
    @EnvironmentObject private var app: AppState

    let session: AppSession

    @State private var barkEnabled = false
    @State private var barkLoaded = false
    @State private var isUpdatingBark = false
    @State private var barkMessage: String?
    @State private var confirmingLogout = false
    @State private var copiedHint: String?

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
            guard !barkLoaded else { return }
            barkLoaded = true
            await loadBark()
        }
        .overlay(alignment: .top) {
            if let copiedHint {
                Text(copiedHint)
                    .font(.system(size: 12))
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
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let email = session.profile.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if session.isAdministrator {
                Text("管理员")
                    .font(.system(size: 10, weight: .medium))
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
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(session.server.displayHost)
                            .font(.system(size: 13))
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
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                        if let barkMessage {
                            Text(barkMessage)
                                .font(.system(size: 11))
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
                            .disabled(!barkLoaded)
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
                            .font(.system(size: 15))
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
                    .fill(app.realtimeConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(app.realtimeConnected ? "实时连接正常" : "实时连接重连中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("\(AppConfig.appDisplayName) \(shortVersion)（\(buildNumber)）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("账号 #\(session.accountId) · \(session.server.displayHost)")
                .font(.system(size: 11))
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

    private func loadBark() async {
        do {
            let settings = try await session.api.barkSettings()
            barkEnabled = settings.enabled
            barkMessage = settings.hasKey ? nil : "未配置 Bark KEY，需先在网页后台填写。"
        } catch {
            // 服务端未实现 Bark 时静默降级，不打扰用户。
            barkMessage = "当前服务器未提供通知配置。"
        }
    }

    private func updateBark(enabled: Bool) async {
        isUpdatingBark = true
        defer { isUpdatingBark = false }
        do {
            let settings = try await session.api.updateBark(enabled: enabled)
            barkEnabled = settings.enabled
            barkMessage = settings.hasKey ? nil : "未配置 Bark KEY，需先在网页后台填写。"
        } catch let error as APIError {
            barkMessage = error.message
            // 回滚开关，避免界面状态和服务器不一致。
            barkEnabled = !enabled
        } catch {
            barkMessage = "设置失败，请重试。"
            barkEnabled = !enabled
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
