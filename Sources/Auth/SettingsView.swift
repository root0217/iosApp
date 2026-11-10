import SwiftUI
import PhotosUI

/// Настройки, общие для всего приложения: профиль, безопасность, сервер, удаление аккаунта.
/// Открывается шестерёнкой из сайдбара.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var serverText = APIConfig.baseURLText
    @State private var serverSaved = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var avatarError: String?

    @State private var showChangeUsername = false
    @State private var showChangePassword = false
    @State private var showDeleteAccount = false

    @State private var sessions: [SessionOut] = []
    @State private var sessionsLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let me = auth.me {
                    Section("Профиль") {
                        HStack(spacing: 14) {
                            ZStack(alignment: .bottomTrailing) {
                                RemoteAvatar(urlPath: me.avatarUrl, fallbackText: me.username, size: 56)
                                if isUploadingAvatar {
                                    ProgressView().frame(width: 56, height: 56)
                                        .background(.black.opacity(0.3), in: Circle())
                                }
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.accent, .white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.username).font(.system(size: 16, weight: .semibold))
                                if me.isAdmin {
                                    Text("Администратор").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .overlay(
                            PhotosPicker(selection: $photoItem, matching: .images) { Color.clear }
                        )
                        if let avatarError = avatarError {
                            Text(avatarError).font(.system(size: 12)).foregroundStyle(.red)
                        }
                        if me.avatarUrl != nil {
                            Button("Удалить аватар", role: .destructive) { Task { await deleteAvatar() } }
                        }

                        Button { showChangeUsername = true } label: {
                            HStack { Text("Изменить username"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                        }
                        Button { showChangePassword = true } label: {
                            HStack { Text("Изменить пароль"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                        }
                    }

                    Section("Активные сессии") {
                        if !sessionsLoaded {
                            ProgressView()
                        } else if sessions.isEmpty {
                            Text("Нет активных сессий").foregroundStyle(Theme.secondary)
                        } else {
                            ForEach(sessions) { s in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.deviceName ?? "Неизвестное устройство").font(.system(size: 14))
                                    Text(s.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                                .swipeActions {
                                    Button("Завершить", role: .destructive) { Task { await revoke(s) } }
                                }
                            }
                        }
                    }
                }

                Section("Сервер") {
                    TextField("http://адрес:порт", text: $serverText)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Сохранить") {
                        guard let url = URL(string: serverText), APIConfig.isValid(serverText) else { return }
                        APIConfig.baseURL = url
                        serverSaved = true
                    }
                    .disabled(!APIConfig.isValid(serverText))
                    if serverSaved {
                        Text("Сохранено.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }

                if auth.isAuthenticated {
                    Section("Аккаунт") {
                        Button("Выйти", role: .destructive) { Task { await auth.logout() } }
                        Button("Удалить аккаунт", role: .destructive) { showDeleteAccount = true }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .task { await loadSessions() }
            .onChange(of: photoItem) { handlePhotoPick($0) }
            .sheet(isPresented: $showChangeUsername) { ChangeUsernameSheet() }
            .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
            .sheet(isPresented: $showDeleteAccount) { DeleteAccountSheet() }
        }
    }

    private func loadSessions() async {
        sessions = (try? await AuthAPI.sessions()) ?? []
        sessionsLoaded = true
    }

    private func revoke(_ session: SessionOut) async {
        try? await AuthAPI.revokeSession(session.id)
        await loadSessions()
    }

    private func handlePhotoPick(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            isUploadingAvatar = true
            avatarError = nil
            defer { isUploadingAvatar = false; photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                avatarError = "Не удалось прочитать фото"
                return
            }
            do {
                _ = try await AuthAPI.uploadAvatar(data)
                await auth.refreshProfile()
            } catch {
                avatarError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить аватар"
            }
        }
    }

    private func deleteAvatar() async {
        try? await AuthAPI.deleteAvatar()
        await auth.refreshProfile()
    }
}

// MARK: - Смена username

private struct ChangeUsernameSheet: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Новый username", text: $username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Текущий пароль", text: $password)
                } footer: {
                    Text("Менять username можно не чаще раза в 7 дней.")
                }
                if let errorMessage = errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.system(size: 13))
                }
            }
            .navigationTitle("Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await submit() } }
                        .disabled(username.isEmpty || password.isEmpty || isLoading)
                }
            }
        }
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        do {
            _ = try await AuthAPI.changeUsername(username, currentPassword: password)
            await auth.refreshProfile()
            dismiss()
        } catch {
            if case APIError.server(_, "username_change_too_soon") = error {
                errorMessage = "Username уже меняли недавно — раз в 7 дней"
            } else if case APIError.server(_, "username_taken") = error {
                errorMessage = "Такой username уже занят"
            } else if case APIError.server(_, "invalid_password") = error {
                errorMessage = "Неверный пароль"
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось изменить username"
            }
        }
        isLoading = false
    }
}

// MARK: - Смена пароля

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Text("Пароль изменён. Остальные сессии завершены.").foregroundStyle(Theme.secondary)
                } else {
                    Section {
                        SecureField("Текущий пароль", text: $oldPassword)
                        SecureField("Новый пароль", text: $newPassword)
                        SecureField("Повторите новый пароль", text: $confirmPassword)
                    }
                    if let errorMessage = errorMessage {
                        Text(errorMessage).foregroundStyle(.red).font(.system(size: 13))
                    }
                }
            }
            .navigationTitle("Пароль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Готово" : "Отмена") { dismiss() } }
                if !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { Task { await submit() } }
                            .disabled(!canSubmit || isLoading)
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        !oldPassword.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        do {
            try await AuthAPI.changePassword(old: oldPassword, new: newPassword)
            done = true
        } catch {
            if case APIError.server(_, "invalid_password") = error {
                errorMessage = "Текущий пароль неверен или новый не подходит по формату"
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось изменить пароль"
            }
        }
        isLoading = false
    }
}

// MARK: - Удаление аккаунта

private struct DeleteAccountSheet: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showFinalConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Пароль", text: $password)
                    TextField("Recovery-код", text: $code).autocorrectionDisabled().textInputAutocapitalization(.characters)
                } footer: {
                    Text("Удаление необратимо: пропадут профиль, аватар, файлы, сообщения и музыкальные данные.")
                }
                if let errorMessage = errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.system(size: 13))
                }
            }
            .navigationTitle("Удалить аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Удалить", role: .destructive) { showFinalConfirm = true }
                        .disabled(password.isEmpty || code.isEmpty || isLoading)
                }
            }
            .confirmationDialog("Это действие необратимо", isPresented: $showFinalConfirm, titleVisibility: .visible) {
                Button("Удалить аккаунт навсегда", role: .destructive) { Task { await submit() } }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        do {
            try await AuthAPI.deleteAccount(password: password, recoveryCode: code)
            dismiss()
            auth.forceLogout()
        } catch {
            if case APIError.server(_, "invalid_password") = error {
                errorMessage = "Неверный пароль"
            } else if case APIError.server(_, "invalid_recovery_code") = error {
                errorMessage = "Неверный recovery-код"
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось удалить аккаунт"
            }
            isLoading = false
        }
    }
}
