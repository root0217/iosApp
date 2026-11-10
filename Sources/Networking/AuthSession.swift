import Foundation

/// Состояние входа: токены, текущий профиль, обновление по истечении, выход. Один экземпляр на
/// всё приложение — библиотека и мессенджер используют именно его, второй системы пользователей нет.
///
/// Класс на @MainActor, но его async-методы вызываются и из APIClient (отдельный actor): Swift сам
/// делает переход между акторами на каждом `await`, поэтому никаких ручных Task{}/nonisolated не нужно.
@MainActor
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var me: MeOut?
    @Published var lastError: String?
    @Published var showSettings = false

    private enum Keys {
        static let access = "auth.access"
        static let refresh = "auth.refresh"
        static let accessExpiry = "auth.accessExpiry"
    }

    private var accessToken: String?
    private var accessExpiry: Date = .distantPast
    private var refreshToken: String?
    private var refreshingTask: Task<Void, Error>?

    private init() {
        accessToken = Keychain.get(Keys.access)
        refreshToken = Keychain.get(Keys.refresh)
        if let raw = UserDefaults.standard.object(forKey: Keys.accessExpiry) as? Double {
            accessExpiry = Date(timeIntervalSince1970: raw)
        }
        isAuthenticated = refreshToken != nil
    }

    /// Вызывается один раз при старте приложения: если токен уже есть, подтягивает профиль
    /// и заодно проверяет, что refresh-токен ещё жив (иначе тихо разлогинивает).
    func bootstrap() async {
        guard isAuthenticated else { return }
        do {
            me = try await AuthAPI.me()
        } catch {
            forceLogout()
        }
    }

    func login(username: String, password: String) async {
        lastError = nil
        do {
            let pair = try await AuthAPI.login(username: username, password: password)
            store(pair)
            me = try? await AuthAPI.me()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Не удалось войти"
        }
    }

    /// Вызывается после успешного register/confirm — токены уже получены, просто сохраняем сессию.
    func completeRegistration(_ pair: TokenPair) async {
        lastError = nil
        store(pair)
        me = try? await AuthAPI.me()
    }

    func refreshProfile() async {
        me = try? await AuthAPI.me()
    }

    func logout() async {
        if let token = refreshToken { await AuthAPI.logout(refreshToken: token) }
        forceLogout()
    }

    /// Токены недействительны — чистим всё локально, пользователь увидит экран входа.
    func forceLogout() {
        Keychain.remove(Keys.access)
        Keychain.remove(Keys.refresh)
        UserDefaults.standard.removeObject(forKey: Keys.accessExpiry)
        accessToken = nil
        refreshToken = nil
        accessExpiry = .distantPast
        isAuthenticated = false
        me = nil
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
        store(pair)
    }

    private func store(_ pair: TokenPair) {
        accessToken = pair.accessToken
        refreshToken = pair.refreshToken
        accessExpiry = Date().addingTimeInterval(TimeInterval(pair.expiresIn))
        Keychain.set(pair.accessToken, for: Keys.access)
        Keychain.set(pair.refreshToken, for: Keys.refresh)
        UserDefaults.standard.set(accessExpiry.timeIntervalSince1970, forKey: Keys.accessExpiry)
        isAuthenticated = true
        lastError = nil
    }
}
