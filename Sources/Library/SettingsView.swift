import SwiftUI

/// Настройки, общие для всего приложения: адрес сервера и выход из аккаунта.
/// Открывается шестерёнкой из сайдбара и с экрана входа в библиотеку.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var serverText = APIConfig.baseURLText
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Сервер") {
                    TextField("http://адрес:порт", text: $serverText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Сохранить") {
                        guard let url = URL(string: serverText), APIConfig.isValid(serverText) else { return }
                        APIConfig.baseURL = url
                        saved = true
                    }
                    .disabled(!APIConfig.isValid(serverText))
                    if saved {
                        Text("Сохранено. Если вы были в библиотеке, откройте её заново.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                if auth.isAuthenticated {
                    Section("Аккаунт") {
                        if let email = auth.email {
                            Text(email).foregroundStyle(Theme.secondary)
                        }
                        Button("Выйти", role: .destructive) {
                            Task { await auth.logout() }
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
