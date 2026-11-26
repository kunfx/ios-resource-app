import SwiftUI
import UIKit

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var bark: BarkSettings?
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    private let api: APIClient

    init(session: AppSession) {
        self.api = session.api
    }

    var barkEnabled: Bool { bark?.enabled ?? false }
    var hasBarkKey: Bool { bark?.hasKey ?? false }

    func load() async {
        isLoading = true
        do {
            bark = try await api.barkSettings()
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.message
        } catch {
            errorMessage = "读取 Bark 通知设置失败。"
        }
        isLoading = false
    }

    /// 返回 nil 表示成功，否则返回错误文案。
    func setBark(_ enabled: Bool) async -> String? {
        guard !isSaving else { return nil }
        if enabled && !hasBarkKey {
            return "尚未配置 Bark KEY。请先在网页后台的 Bark 设置中填写 KEY，再回来开启。"
        }
        isSaving = true
        defer { isSaving = false }
        do {
            bark = try await api.updateBark(enabled: enabled)
            errorMessage = nil
            return nil
        } catch let error as APIError {
            errorMessage = error.message
            return error.message
        } catch {
            errorMessage = "保存失败，请重试。"
            return "保存失败，请重试。"
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: SettingsModel

    private let session: AppSession

    @State private var showLogoutConfirm = false
    @State private var alertMessage: String?

    init(session: AppSession) {
        self.session = session
        _model = StateObject(wrappedValue: SettingsModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("设置")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    avatarRow
                    Divider().padding(.leading, 16)
                    usernameRow
                    Divider().padding(.leading, 16)
                    barkRow
                    Divider().padding(.leading, 16)
                    logoutRow
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 76)
        }
        .task {
            await model.load()
        }
        .confirmationDialog("确认退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task { await app.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后将清除本机保存的登录凭据，并断开实时连接。")
        }
        .alert("Bark 通知", isPresented: Binding(
            get: { alertMessage != nil },
            set: { newValue in if !newValue { alertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // 第一行：管理员头像（服务端当前不提供头像地址，使用占位图标）
    private var avatarRow: some View {
        HStack {
            AdminAvatar(size: 52)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // 第二行：用户名
    private var usernameRow: some View {
        HStack(spacing: 12) {
            Text("用户名")
                .font(.system(size: 15))
            Spacer()
            Text(session.displayName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    // 第三行：Bark 通知开关
    private var barkRow: some View {
        HStack(spacing: 12) {
            Text("Bark 通知")
                .font(.system(size: 15))
            if model.isSaving {
                ProgressView().scaleEffect(0.7)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.barkEnabled },
                set: { newValue in
                    Task {
                        if let message = await model.setBark(newValue) {
                            alertMessage = message
                        }
                    }
                }
            ))
            .labelsHidden()
            .disabled(model.isLoading || model.isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // 第四行：退出登录
    private var logoutRow: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            HStack {
                Text("退出登录")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.danger)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
