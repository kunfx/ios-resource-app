import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var serverAddress = AppConfig.baseURLString
    @State private var showAdvanced = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    brandHeader
                    form
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    submitButton
                    advancedSection
                    Spacer(minLength: 10)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: session.isLoggedIn) { loggedIn in
                if loggedIn { dismiss() }
            }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 72, height: 72)

                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("登录 \(AppConfig.appName)")
                .font(.system(size: 20, weight: .bold))

            Text("使用网站账号登录，积分与会员状态与网页端同步")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var form: some View {
        VStack(spacing: 14) {
            field(title: "邮箱", icon: "envelope.fill") {
                TextField("you@example.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
            }

            field(title: "密码", icon: "lock.fill") {
                SecureField("请输入密码", text: $password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            }
        }
        .cardStyle()
    }

    private func field<Content: View>(title: String, icon: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }

            content()
                .font(.system(size: 15))
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 6) {
                if isSubmitting {
                    ProgressView().tint(.white)
                }
                Text(isSubmitting ? "登录中…" : "登录")
            }
        }
        .buttonStyle(PrimaryButtonStyle(enabled: canSubmit && !isSubmitting))
        .disabled(!canSubmit || isSubmitting)
    }

    private var advancedSection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("服务器地址")
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://your-domain.com", text: $serverAddress)
                        .font(.system(size: 13))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Text("填写站点根地址即可，App 会自动拼接 /api 路径。修改后需要重新登录。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .cardStyle(padding: 12, radius: 14)
            }
        }
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }

        focusedField = nil
        isSubmitting = true
        errorMessage = nil

        let newServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        if !newServer.isEmpty && newServer != AppConfig.normalizedBaseURLString {
            AppConfig.baseURLString = newServer
            session.resetForNewServer()
        }

        Task {
            do {
                try await session.login(email: email.trimmingCharacters(in: .whitespaces),
                                        password: password)
            } catch {
                errorMessage = error.readableMessage
            }
            isSubmitting = false
        }
    }
}
