import Foundation

enum RegisterStep {
    case form
    case confirmCode
}

/// Состояние регистрации в два шага: ввёл username+пароль → получил recovery-код → повторно
/// ввёл его для подтверждения. Пока код не подтверждён, аккаунта на сервере ещё не существует —
/// отдельный объект, не часть AuthSession, потому что это переходное состояние одного экрана.
@MainActor
final class RegisterFlow: ObservableObject {
    @Published var step: RegisterStep = .form
    @Published var username = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var usernameAvailability: AvailabilityOut?
    @Published var isCheckingUsername = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?

    @Published private(set) var recoveryCode: String?
    @Published var codeConfirmInput = ""

    private var pendingId: String?
    private var checkTask: Task<Void, Never>?

    var passwordsMatch: Bool { !password.isEmpty && password == confirmPassword }

    var canSubmitForm: Bool {
        (usernameAvailability?.available ?? false) && passwordsMatch && password.count >= 8
    }

    func usernameChanged(_ value: String) {
        username = value
        usernameAvailability = nil
        checkTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return }
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isCheckingUsername = true
            let result = try? await AuthAPI.usernameAvailable(trimmed)
            guard !Task.isCancelled else { return }
            usernameAvailability = result
            isCheckingUsername = false
        }
    }

    func submitForm() async {
        guard canSubmitForm else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await AuthAPI.registerStart(username: username, password: password)
            pendingId = result.pendingId
            recoveryCode = result.recoveryCode
            step = .confirmCode
        } catch {
            errorMessage = describeRegisterError(error)
        }
    }

    func confirmCode() async -> TokenPair? {
        guard let pendingId = pendingId else { return nil }
        let typed = codeConfirmInput.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            return try await AuthAPI.registerConfirm(pendingId: pendingId, recoveryCode: typed)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Код не подошёл, попробуйте ещё раз"
            return nil
        }
    }

    private func describeRegisterError(_ error: Error) -> String {
        if case APIError.server(_, "username_taken") = error { return "Такой username уже занят" }
        if case APIError.server(_, "invalid_username") = error { return "Недопустимый username" }
        if case APIError.server(_, "invalid_password") = error { return "Пароль не подходит по формату" }
        return (error as? LocalizedError)?.errorDescription ?? "Не удалось начать регистрацию"
    }
}
