import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthSession
    @Binding var mode: AuthMode

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @FocusState private var focusedField: Field?
    private enum Field { case username, password }

    var body: some View {
        AuthScaffold(title: "Вход в Chapa") {
            VStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .authFieldStyle()

                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                    .authFieldStyle()
            }

            if let error = auth.lastError {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            AuthPrimaryButton(title: "Войти", isLoading: isLoading, disabled: username.isEmpty || password.isEmpty) {
                Task { await submit() }
            }

            VStack(spacing: 10) {
                Button("Забыли пароль?") { mode = .forgotPassword }
                Button("Забыли username?") { mode = .forgotUsername }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondary)

            Divider().padding(.vertical, 4)

            Button { mode = .register } label: {
                Text("Создать аккаунт").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func submit() async {
        focusedField = nil
        isLoading = true
        await auth.login(username: username, password: password)
        isLoading = false
    }
}
