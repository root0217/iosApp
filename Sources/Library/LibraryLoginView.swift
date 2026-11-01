import SwiftUI

/// Экран входа: показывается вместо библиотеки, пока нет токена. Авторизация одна на всё приложение.
struct LibraryLoginView: View {
    @EnvironmentObject var auth: AuthSession
    let openDrawer: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: openDrawer) { MenuGlyph() }
                Text("Библиотека").font(Typo.title)
                Spacer()
                Button { auth.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 6)
            .frame(height: 44)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "externaldrive.badge.person.crop")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.secondary)
                Text("Вход в библиотеку")
                    .font(.system(size: 19, weight: .semibold))

                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    SecureField("Пароль", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: 320)

                if let error = auth.lastError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    focused = false
                    isLoading = true
                    Task {
                        await auth.login(email: email, password: password)
                        isLoading = false
                    }
                } label: {
                    ZStack {
                        if isLoading { ProgressView().tint(.white) }
                        else { Text("Войти").font(.system(size: 16, weight: .semibold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320)
                    .frame(height: 46)
                    .background(canSubmit ? Theme.accent : Theme.secondary.opacity(0.4), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSubmit || isLoading)

                Button { auth.showSettings = true } label: {
                    Text("Адрес сервера: \(APIConfig.baseURLText)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 1
    }
}
