import SwiftUI

struct ForgotPasswordView: View {
    @Binding var mode: AuthMode

    @State private var username = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var done = false

    var body: some View {
        AuthScaffold(title: "Восстановление пароля", onBack: { mode = .login }) {
            if done {
                successView
            } else {
                formView
            }
        }
    }

    private var formView: some View {
        VStack(spacing: 14) {
            TextField("Username", text: $username)
                .autocorrectionDisabled().textInputAutocapitalization(.never).authFieldStyle()
            TextField("Recovery-код", text: $code)
                .autocorrectionDisabled().textInputAutocapitalization(.characters).authFieldStyle()
            SecureField("Новый пароль", text: $newPassword).textContentType(.newPassword).authFieldStyle()
            SecureField("Повторите новый пароль", text: $confirmPassword).textContentType(.newPassword).authFieldStyle()

            if let errorMessage = errorMessage {
                Text(errorMessage).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            AuthPrimaryButton(title: "Сбросить пароль", isLoading: isLoading, disabled: !canSubmit) {
                Task { await submit() }
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.green)
            Text("Пароль изменён. Остальные сессии завершены — войдите заново с новым паролем.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            AuthPrimaryButton(title: "К входу") { mode = .login }
        }
    }

    private var canSubmit: Bool {
        !username.isEmpty && !code.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        do {
            try await AuthAPI.recoverPassword(username: username, recoveryCode: code, newPassword: newPassword)
            done = true
        } catch {
            errorMessage = describeError(error)
        }
        isLoading = false
    }

    private func describeError(_ error: Error) -> String {
        if case APIError.server(_, "invalid_recovery_code") = error { return "Username или recovery-код неверны" }
        if case APIError.server(429, _) = error { return "Слишком много попыток, попробуйте позже" }
        if case APIError.server(_, "invalid_password") = error { return "Пароль не подходит по формату" }
        return (error as? LocalizedError)?.errorDescription ?? "Не удалось сбросить пароль"
    }
}
