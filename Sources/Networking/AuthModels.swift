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
    let id: String
    let email: String
}

private struct LoginBody: Encodable {
    let email: String
    let password: String
    let device_name: String?
}

private struct RefreshBody: Encodable {
    let refresh_token: String
}

/// Тонкая обёртка над /auth: сам HTTP идёт через APIClient. Логики хранения токенов здесь нет — это AuthSession.
enum AuthAPI {
    static func login(email: String, password: String) async throws -> TokenPair {
        try await APIClient.shared.send("POST", "/auth/login",
                                        body: LoginBody(email: email, password: password, device_name: UIDeviceName.current),
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
