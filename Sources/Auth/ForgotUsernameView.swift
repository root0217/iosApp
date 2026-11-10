import SwiftUI

struct ForgotUsernameView: View {
    @Binding var mode: AuthMode

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var foundUsername: String?

    var body: some View {
        AuthScaffold(title: "Восстановление username", onBack: { mode = .login }) {
            if let username = foundUsername {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.accent)
                    Text("Ваш username:").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Text(username).font(.system(size: 20, weight: .bold))
                    AuthPrimaryButton(title: "К входу") { mode = .login }
                }
            } else {
                VStack(spacing: 14) {
                    Text("Введите recovery-код — он тот же, что вы сохранили при регистрации.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                        .autocorrectionDisabled().textInputAutocapitalization(.characters).authFieldStyle()

                    if let errorMessage = errorMessage {
                        Text(errorMessage).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    AuthPrimaryButton(title: "Найти username", isLoading: isLoading, disabled: code.isEmpty) {
                        Task { await submit() }
                    }
                }
            }
        }
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        do {
            foundUsername = try await AuthAPI.recoverUsername(recoveryCode: code).username
        } catch {
            if case APIError.server(_, "invalid_recovery_code") = error {
                errorMessage = "Такой recovery-код не найден"
            } else if case APIError.server(429, _) = error {
                errorMessage = "Слишком много попыток, попробуйте позже"
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось найти username"
            }
        }
        isLoading = false
    }
}
