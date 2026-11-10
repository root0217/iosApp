import SwiftUI

/// Переключатель между входом, регистрацией и двумя экранами восстановления — один контейнер,
/// чтобы переходы между ними были частью одного плавного потока, а не отдельными модалками.
struct AuthFlowView: View {
    @State private var mode: AuthMode = .login

    var body: some View {
        Group {
            switch mode {
            case .login: LoginView(mode: $mode)
            case .register: RegisterView(mode: $mode)
            case .forgotPassword: ForgotPasswordView(mode: $mode)
            case .forgotUsername: ForgotUsernameView(mode: $mode)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: mode)
    }
}
