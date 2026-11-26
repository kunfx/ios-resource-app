import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var app: AppState

    @State private var server: String = UserDefaults.standard.string(forKey: AppConfig.lastServerDefaultsKey)
        ?? AppConfig.defaultServer
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
        case server
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        BrandMark(size: 54)
                        Text("在线客服")
                            .font(.system(size: 26, weight: .semibold))
                            .padding(.top, 14)
                        Text("管理员登录")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 56)

                    VStack(spacing: 0) {
                        fieldRow(icon: "envelope") {
                            TextField("用户名（邮箱）", text: $email)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .submitLabel(.next)
                                .focused($focusedField, equals: .email)
                                .onSubmit { focusedField = .password }
                        }
                        Divider().padding(.leading, 46)
                        fieldRow(icon: "lock") {
                            SecureField("密码", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focusedField, equals: .password)
                                .onSubmit { submit() }
                        }
                    }
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 28)

                    if let errorText {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 12))
                            Text(errorText)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 12)
                    }

                    Button(action: submit) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.accent)
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Text("登录")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.85 : 1)
                    .padding(.top, 18)

                    Spacer(minLength: 40)

                    serverSection
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务器")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("https://example.com", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .server)
                    .font(.system(size: 14))
                    .submitLabel(.done)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("填写后台根域名（HTTPS）。更换服务器不需要重新编译，登录成功后会记住该地址。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content()
                .font(.system(size: 15))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func submit() {
        guard !isSubmitting else { return }
        focusedField = nil
        errorText = nil
        isSubmitting = true
        let currentServer = server
        let currentEmail = email
        let currentPassword = password
        Task {
            let message = await app.login(serverText: currentServer, email: currentEmail, password: currentPassword)
            isSubmitting = false
            errorText = message
            if message == nil {
                password = ""
            }
        }
    }
}
