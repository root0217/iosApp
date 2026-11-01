import Foundation

/// Состояние входа: токены, обновление по истечении, выход. Один экземпляр на всё приложение —
/// библиотека и (в будущем) мессенджер используют именно его, второй системы пользователей не заводим.
///
/// Класс на @MainActor, но его async-методы вызываются и из APIClient (отдельный actor): Swift сам
/// делает переход между акторами на каждом `await`, поэтому никаких ручных Task{}/nonisolated не нужно.
@MainActor
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var email: String?
    @Published var lastError: String?
    @Published var showSettings = false

    private enum Keys {
        static let access = "auth.access"
        static let refresh = "auth.refresh"
        static let accessExpiry = "auth.accessExpiry"
        static let email = "auth.email"
    }

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast
    private var refreshToken: String?
    private var refreshingTask: Task<Void, Error>?

    private init() {
        accessToken = Keychain.get(Keys.access)
        refreshToken = Keychain.get(Keys.refresh)
        email = UserDefaults.standard.string(forKey: Keys.email)
        if let raw = UserDefaults.standard.object(forKey: Keys.accessExpiry) as? Double {
            accessExpiry = Date(timeIntervalSince1970: raw)
        }
        isAuthenticated = refreshToken != nil
    }

    func login(email: String, password: String) async {
        lastError = nil
        do {
            let pair = try await AuthAPI.login(email: email, password: password)
            store(pair, email: email)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Не удалось войти"
        }
    }

    func logout() async {
        if let token = refreshToken { await AuthAPI.logout(refreshToken: token) }
        forceLogout()
    }

    /// Токены недействительны (сервер отклонил refresh) — чистим всё локально, пользователь увидит экран входа.
    func forceLogout() {
        Keychain.remove(Keys.access)
        Keychain.remove(Keys.refresh)
        UserDefaults.standard.removeObject(forKey: Keys.accessExpiry)
        accessToken = nil
        refreshToken = nil
        accessExpiry = .distantPast
        isAuthenticated = false
    }

    /// Токен для APIClient: если истёк или истекает в ближайшие 10 секунд, сперва обновляется.
    func validAccessToken() async -> String? {
        if let token = accessToken, Date() < accessExpiry.addingTimeInterval(-10) {
            return token
        }
        do {
            try await refreshTokens()
            return accessToken
        } catch {
            return nil
        }
    }

    /// Несколько параллельных 401 не должны вызвать несколько одновременных запросов обновления —
    /// все ждут один и тот же Task.
    func refreshTokens() async throws {
        if let existing = refreshingTask {
            try await existing.value
            return
        }
        let task = Task { try await performRefresh() }
        refreshingTask = task
        defer { refreshingTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refresh = refreshToken else { throw APIError.notAuthenticated }
        let pair = try await AuthAPI.refresh(refreshToken: refresh)
        store(pair, email: email)
    }

    private func store(_ pair: TokenPair, email: String?) {
        accessToken = pair.accessToken
        refreshToken = pair.refreshToken
        accessExpiry = Date().addingTimeInterval(TimeInterval(pair.expiresIn))
        Keychain.set(pair.accessToken, for: Keys.access)
        Keychain.set(pair.refreshToken, for: Keys.refresh)
        UserDefaults.standard.set(accessExpiry.timeIntervalSince1970, forKey: Keys.accessExpiry)
        if let email = email {
            self.email = email
            UserDefaults.standard.set(email, forKey: Keys.email)
        }
        isAuthenticated = true
        lastError = nil
    }
}
