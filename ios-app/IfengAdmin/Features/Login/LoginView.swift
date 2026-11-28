import SwiftUI
import UIKit

/// 登录页：服务器地址可编辑、账号密码、错误内联提示。
/// 所有输入控件都不做自动大写/自动纠错，避免邮箱和域名被系统改写。
struct LoginView: View {
    @EnvironmentObject private var app: AppState

    @State private var serverText: String =
        UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey) ?? AppConfig.defaultServer
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var errorText: String?
    @State private var isSubmitting = false
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case server
        case email
        case password
    }

    var body: some View {
        ZStack {
            Theme.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    card
                    footnote
                }
                .padding(.horizontal, 22)
                .padding(.top, 52)
                .padding(.bottom, 44)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 12) {
            BrandMark(size: 76)
                .shadow(color: Theme.accent.opacity(0.28), radius: 16, x: 0, y: 8)
            VStack(spacing: 5) {
                Text(AppConfig.appDisplayName)
                    .font(.app(size: 23, weight: .semibold))
                Text("管理员登录")
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: 表单

    private var card: some View {
        VStack(spacing: 16) {
            field(icon: "globe", title: "服务器地址") {
                TextField("https://example.com", text: $serverText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.URL)
                    .focused($focused, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focused = .email }
            }

            field(icon: "envelope", title: "用户名") {
                TextField("邮箱地址", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.username)
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }

            field(icon: "lock", title: "密码") {
                HStack(spacing: 8) {
                    Group {
                        if showsPassword {
                            TextField("密码", text: $password)
                        } else {
                            SecureField("密码", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }

                    Button {
                        showsPassword.toggle()
                    } label: {
                        LucideIcon(
                            name: showsPassword ? "eye-off" : "eye",
                            size: 16,
                            color: .secondary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                }
            }

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    LucideIcon(name: "circle-alert", size: 14, color: Theme.danger)
                        .padding(.top, 1)
                    Text(errorText)
                        .font(.app(size: 13))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    }
                    Text(isSubmitting ? "登录中…" : "登录")
                        .font(.app(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.accent)
                )
                .opacity(canSubmit ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(.top, 2)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: errorText)
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            Text("服务器地址填写后台根域名，不要带路径或参数。")
            Text("生产环境必须使用 HTTPS。")
        }
        .font(.app(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: 组件

    @ViewBuilder
    private func field<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                LucideIcon(name: icon, size: 11, color: .secondary)
                Text(title)
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            content()
                .font(.app(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
    }

    // MARK: 提交

    private var canSubmit: Bool {
        !isSubmitting
            && !serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        errorText = nil
        isSubmitting = true
        Task {
            let message = await app.login(serverText: serverText, email: email, password: password)
            isSubmitting = false
            errorText = message
        }
    }
}
