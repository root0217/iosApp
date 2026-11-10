import Foundation

enum WSEvent {
    case message(Message)
    case messageStatus(messageId: UUID, status: String)
    case typing(conversationId: UUID)
    case read(conversationId: UUID, upToMessageId: UUID)
    /// По username, не по id: сервер намеренно не раскрывает id обычным пользователям, а клиенту
    /// и нечем было бы сверить голый id — у него на руках только username собеседника.
    case presence(username: String, online: Bool, lastActiveAt: Date?)
    case error(code: String)
}

/// Тонкий слой поверх URLSessionWebSocketTask: соединение, разбор событий, переподключение
/// с нарастающей паузой. Сам ничего не решает про UI или данные — только шлёт события наружу
/// через onEvent, подписывается MessengerStore.
@MainActor
final class WebSocketClient: ObservableObject {
    @Published private(set) var isConnected = false
    var onEvent: ((WSEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var shouldStayConnected = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    func connect() {
        shouldStayConnected = true
        reconnectTask?.cancel()
        Task { await openSocket() }
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func openSocket() async {
        guard shouldStayConnected else { return }
        guard let token = await AuthSession.shared.validAccessToken() else { return }
        guard var components = URLComponents(url: APIConfig.baseURL.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }

        let newTask = URLSession.shared.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        isConnected = true
        reconnectAttempt = 0
        listen(on: newTask)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        Task {
            while shouldStayConnected, self.task === task {
                do {
                    let message = try await task.receive()
                    handle(message)
                } catch {
                    if self.task === task {
                        isConnected = false
                        self.task = nil
                        scheduleReconnect()
                    }
                    return
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldStayConnected else { return }
        reconnectAttempt += 1
        let delay = min(pow(1.6, Double(reconnectAttempt)), 30)
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await openSocket()
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message, let data = text.data(using: .utf8) else { return }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else { return }

        switch type {
        case "message":
            guard let payload = envelope["message"] as? [String: Any],
                  let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                  let decoded = try? decoder.decode(Message.self, from: payloadData) else { return }
            onEvent?(.message(decoded))

        case "message_status":
            guard let idString = envelope["message_id"] as? String, let id = UUID(uuidString: idString),
                  let status = envelope["status"] as? String else { return }
            onEvent?(.messageStatus(messageId: id, status: status))

        case "typing":
            guard let convString = envelope["conversation_id"] as? String, let convId = UUID(uuidString: convString) else { return }
            onEvent?(.typing(conversationId: convId))

        case "read":
            guard let convString = envelope["conversation_id"] as? String, let convId = UUID(uuidString: convString),
                  let msgString = envelope["up_to_message_id"] as? String, let msgId = UUID(uuidString: msgString) else { return }
            onEvent?(.read(conversationId: convId, upToMessageId: msgId))

        case "presence":
            guard let username = envelope["username"] as? String, let online = envelope["online"] as? Bool else { return }
            let lastActive = (envelope["last_active_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            onEvent?(.presence(username: username, online: online, lastActiveAt: lastActive))

        case "error":
            onEvent?(.error(code: (envelope["code"] as? String) ?? "unknown"))

        default:
            break  // pong и будущие типы событий — молча игнорируем
        }
    }

    // MARK: Отправка

    func sendTyping(conversationId: UUID) {
        send(["type": "typing", "conversation_id": conversationId.uuidString])
    }

    func sendRead(conversationId: UUID, upToMessageId: UUID) {
        send(["type": "read", "conversation_id": conversationId.uuidString, "up_to_message_id": upToMessageId.uuidString])
    }

    /// true, если реально отправлено по сокету (онлайн) — иначе вызывающий код сам решает,
    /// откатываться ли на REST.
    @discardableResult
    func sendMessage(conversationId: UUID, text: String?, attachmentFileId: UUID?, durationSeconds: Double?) -> Bool {
        guard isConnected else { return false }
        var payload: [String: Any] = ["type": "message", "conversation_id": conversationId.uuidString]
        if let text = text { payload["text"] = text }
        if let attachmentFileId = attachmentFileId { payload["attachment_file_id"] = attachmentFileId.uuidString }
        if let durationSeconds = durationSeconds { payload["attachment_duration_seconds"] = durationSeconds }
        send(payload)
        return true
    }

    private func send(_ payload: [String: Any]) {
        guard let task = task, let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}
