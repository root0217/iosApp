import Foundation

struct APIErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String?
    }
    let detail: Detail?
}

enum APIError: Error, LocalizedError {
    case notAuthenticated
    case server(status: Int, code: String?)
    case network(Error)
    case decoding(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Нужно войти заново"
        case .server(let status, let code): return "Сервер ответил ошибкой (\(status)\(code.map { ": \($0)" } ?? ""))"
        case .network: return "Нет соединения с сервером"
        case .decoding: return "Сервер прислал неожиданный ответ"
        case .cancelled: return "Отменено"
        }
    }
}

/// Один HTTP-клиент на всё приложение: подставляет Bearer-токен, по 401 обновляет его один раз и повторяет запрос.
/// Все остальные сервисы (Auth, Library) идут только через него — второго сетевого слоя не заводим.
actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private var refreshTask: Task<Void, Error>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: APIConfig.baseURL.appendingPathComponent("v1" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// Сервер иногда сам присылает относительный путь, уже включающий "/v1/…" и свой query (например,
    /// ссылка на скачивание из POST .../link: "/v1/library/files/{id}/content?t=..."). Его нельзя
    /// пропускать через url(_:) — это задвоило бы префикс и испортило бы query через appendingPathComponent.
    func absoluteURL(forServerPath path: String) -> URL? {
        guard var components = URLComponents(string: path) else { return nil }
        let base = APIConfig.baseURL
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        return components.url
    }

    // MARK: - Запросы без тела / с JSON-телом

    func send<Response: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [],
        body: Encodable? = nil, auth: Bool = true, ifMatch: Int? = nil
    ) async throws -> Response {
        let data = try await raw(method, path, query: query, body: body, auth: auth, ifMatch: ifMatch)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Encodable? = nil, auth: Bool = true, ifMatch: Int? = nil) async throws {
        _ = try await raw(method, path, query: query, body: body, auth: auth, ifMatch: ifMatch)
    }

    /// Декодирует Data, полученные отдельно (например, из upload(_:_:chunk:)), тем же декодером,
    /// что и обычные JSON-ответы — чтобы формат дат и прочее было единообразным.
    func decode<Response: Decodable>(_ type: Response.Type, from data: Data) async throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    @discardableResult
    func raw(
        _ method: String, _ path: String, query: [URLQueryItem] = [],
        body: Encodable? = nil, auth: Bool = true, ifMatch: Int? = nil, retrying: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let body = body {
            request.httpBody = try? encoder.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch = ifMatch {
            request.setValue("\"\(ifMatch)\"", forHTTPHeaderField: "If-Match")
        }
        if auth {
            guard let token = await AuthSession.shared.validAccessToken() else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await execute(request, allowRefresh: auth && !retrying)
    }

    /// Для потоковых запросов (кусок загрузки): тело передаётся как Data напрямую, без JSON-обёртки.
    func upload(_ method: String, _ path: String, query: [URLQueryItem] = [], chunk: Data, auth: Bool = true) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.httpBody = chunk
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if auth {
            guard let token = await AuthSession.shared.validAccessToken() else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await execute(request, allowRefresh: auth)
    }

    private func execute(_ request: URLRequest, allowRefresh: Bool) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }

        if http.statusCode == 401, allowRefresh {
            do {
                try await AuthSession.shared.refreshTokens()
            } catch {
                await AuthSession.shared.forceLogout()
                throw APIError.notAuthenticated
            }
            var retried = request
            if let token = await AuthSession.shared.validAccessToken() {
                retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data2, response2) = try await session.data(for: retried)
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
            guard (200..<300).contains(http2.statusCode) else { throw APIError.server(status: http2.statusCode, code: errorCode(in: data2)) }
            return data2
        }

        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, code: errorCode(in: data))
        }
        return data
    }

    private func errorCode(in data: Data) -> String? {
        (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.detail?.code
    }
}

/// Обёртка, чтобы кодировать `Encodable`-значение неизвестного конкретного типа через протокольную ссылку.
private struct AnyEncodable: Encodable {
    private let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension JSONDecoder.DateDecodingStrategy {
    /// FastAPI отдаёт ISO-8601 иногда с дробными секундами, иногда без — пробуем оба варианта.
    static let iso8601WithFractional = custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Неверный формат даты: \(text)")
    }
}
