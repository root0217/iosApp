import Foundation
import UIKit

struct TokenPair: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct MeOut: Codable {
    let id: UUID
    let username: String
    let avatarUrl: String?
    let isAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case id, username
        case avatarUrl = "avatar_url"
        case isAdmin = "is_admin"
    }
}

struct PublicUserOut: Codable, Identifiable, Hashable {
    let username: String
    let avatarUrl: String?
    var online: Bool          // var: обновляется на лету presence-событиями из WebSocket
    var lastActiveAt: Date?

    var id: String { username }

    enum CodingKeys: String, CodingKey {
        case username
        case avatarUrl = "avatar_url"
        case online
        case lastActiveAt = "last_active_at"
    }
}

struct AvailabilityOut: Codable {
    let available: Bool
    let reason: String?
}

struct RegisterStartOut: Codable {
    let pendingId: String
    let recoveryCode: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case pendingId = "pending_id"
        case recoveryCode = "recovery_code"
        case expiresIn = "expires_in"
    }
}

struct RecoverUsernameOut: Codable {
    let username: String
}

private struct RegisterStartBody: Encodable { let username: String; let password: String }
private struct RegisterConfirmBody: Encodable { let pending_id: String; let recovery_code: String; let device_name: String? }
private struct LoginBody: Encodable { let username: String; let password: String; let device_name: String? }
private struct RefreshBody: Encodable { let refresh_token: String }
private struct ChangePasswordBody: Encodable { let old_password: String; let new_password: String }
private struct ChangeUsernameBody: Encodable { let username: String; let current_password: String }
private struct RecoverPasswordBody: Encodable { let username: String; let recovery_code: String; let new_password: String }
private struct RecoverUsernameBody: Encodable { let recovery_code: String }
private struct DeleteAccountBody: Encodable { let password: String; let recovery_code: String }

/// Тонкая обёртка над /auth: сам HTTP идёт через APIClient. Логики хранения токенов здесь нет — это AuthSession.
enum AuthAPI {
    static func usernameAvailable(_ username: String) async throws -> AvailabilityOut {
        try await APIClient.shared.send("GET", "/auth/username-available",
                                        query: [URLQueryItem(name: "username", value: username)], auth: false)
    }

    static func registerStart(username: String, password: String) async throws -> RegisterStartOut {
        try await APIClient.shared.send("POST", "/auth/register/start",
                                        body: RegisterStartBody(username: username, password: password), auth: false)
    }

    static func registerConfirm(pendingId: String, recoveryCode: String) async throws -> TokenPair {
        try await APIClient.shared.send("POST", "/auth/register/confirm",
                                        body: RegisterConfirmBody(pending_id: pendingId, recovery_code: recoveryCode,
                                                                  device_name: UIDeviceName.current), auth: false)
    }

    static func login(username: String, password: String) async throws -> TokenPair {
        try await APIClient.shared.send("POST", "/auth/login",
                                        body: LoginBody(username: username, password: password, device_name: UIDeviceName.current),
                                        auth: false)
    }

    static func refresh(refreshToken: String) async throws -> TokenPair {
        try await APIClient.shared.send("POST", "/auth/refresh", body: RefreshBody(refresh_token: refreshToken), auth: false)
    }

    static func logout(refreshToken: String) async {
        try? await APIClient.shared.send("POST", "/auth/logout", body: RefreshBody(refresh_token: refreshToken), auth: false)
    }

    static func me() async throws -> MeOut {
        try await APIClient.shared.send("GET", "/auth/me")
    }

    static func changePassword(old: String, new: String) async throws {
        try await APIClient.shared.send("POST", "/auth/me/password", body: ChangePasswordBody(old_password: old, new_password: new))
    }

    static func changeUsername(_ username: String, currentPassword: String) async throws -> MeOut {
        try await APIClient.shared.send("PATCH", "/auth/me/username",
                                        body: ChangeUsernameBody(username: username, current_password: currentPassword))
    }

    static func recoverPassword(username: String, recoveryCode: String, newPassword: String) async throws {
        try await APIClient.shared.send("POST", "/auth/recover/password",
                                        body: RecoverPasswordBody(username: username, recovery_code: recoveryCode, new_password: newPassword),
                                        auth: false)
    }

    static func recoverUsername(recoveryCode: String) async throws -> RecoverUsernameOut {
        try await APIClient.shared.send("POST", "/auth/recover/username",
                                        body: RecoverUsernameBody(recovery_code: recoveryCode), auth: false)
    }

    static func deleteAccount(password: String, recoveryCode: String) async throws {
        try await APIClient.shared.send("POST", "/auth/me/delete", body: DeleteAccountBody(password: password, recovery_code: recoveryCode))
    }

    static func search(_ query: String) async throws -> [PublicUserOut] {
        try await APIClient.shared.send("GET", "/auth/search", query: [URLQueryItem(name: "q", value: query)])
    }

    static func publicProfile(username: String) async throws -> PublicUserOut {
        try await APIClient.shared.send("GET", "/auth/users/\(username)")
    }

    static func uploadAvatar(_ data: Data) async throws -> MeOut {
        let raw = try await APIClient.shared.upload("PUT", "/auth/me/avatar", chunk: data)
        return try await APIClient.shared.decode(MeOut.self, from: raw)
    }

    static func deleteAvatar() async throws {
        try await APIClient.shared.send("DELETE", "/auth/me/avatar")
    }

    static func sessions() async throws -> [SessionOut] {
        try await APIClient.shared.send("GET", "/auth/sessions")
    }

    static func revokeSession(_ id: String) async throws {
        try await APIClient.shared.send("DELETE", "/auth/sessions/\(id)")
    }
}

struct SessionOut: Codable, Identifiable {
    let id: String
    let deviceName: String?
    let createdAt: Date
    let lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

enum UIDeviceName {
    static let current: String = {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }()
}
