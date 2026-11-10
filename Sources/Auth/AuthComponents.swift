import SwiftUI

enum AuthMode {
    case login, register, forgotPassword, forgotUsername
}

/// Общая обёртка для всех пред-авторизационных экранов: заголовок по центру, прокручиваемое
/// содержимое, снизу — адрес сервера (тот же, что и в настройках). Один и тот же каркас везде,
/// чтобы вход, регистрация и восстановление выглядели частью одного приложения, а не разных.
struct AuthScaffold<Content: View>: View {
    @EnvironmentObject var auth: AuthSession
    let title: String
    let onBack: (() -> Void)?
    let content: Content

    init(title: String, onBack: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let onBack = onBack {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        Spacer()
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 4)
                } else {
                    Color.clear.frame(height: 24)
                }

                Text("Chapa").font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.secondary)

                VStack(spacing: 16) { content }
                    .frame(maxWidth: 340)
                    .padding(.top, 6)

                Spacer(minLength: 20)

                Button { auth.showSettings = true } label: {
                    Text("Адрес сервера: \(APIConfig.baseURLText)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(PressableStyle())
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

struct AuthPrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading { ProgressView().tint(.white) }
                else { Text(title).font(.system(size: 16, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(disabled ? Theme.secondary.opacity(0.4) : Theme.accent, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled || isLoading)
    }
}

extension View {
    /// Единый стиль текстовых полей на всех пред-авторизационных экранах.
    func authFieldStyle() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
