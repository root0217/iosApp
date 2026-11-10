import Foundation

/// Состояние мессенджера на всё приложение: список диалогов, открытая переписка, подключение
/// по сокету. Сайдбар читает conversations, экран переписки — messages/typing для текущего id.
@MainActor
final class MessengerStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var conversationsLoaded = false
    @Published private(set) var messagesByConversation: [UUID: [Message]] = [:]
    @Published private(set) var hasMoreByConversation: [UUID: Bool] = [:]
    @Published var selectedConversationID: UUID?
    @Published private(set) var typingIn: Set<UUID> = []  // id диалогов, где собеседник сейчас печатает
    @Published var toast: String?

    let socket = WebSocketClient()
    private var myUserID: UUID?
    private var typingResetTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func start(myUserID: UUID) async {
        self.myUserID = myUserID
        socket.connect()
        await refreshConversations()
    }

    func stop() {
        socket.disconnect()
        conversations = []
        conversationsLoaded = false
        messagesByConversation = [:]
        selectedConversationID = nil
    }

    // MARK: Список диалогов

    func refreshConversations() async {
        if let list = try? await MessengerService.listConversations() {
            conversations = sortConversations(list)
        }
        conversationsLoaded = true
    }

    private func sortConversations(_ list: [Conversation]) -> [Conversation] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func startConversation(withUsername username: String) async -> Conversation? {
        guard let conv = try? await MessengerService.startConversation(username: username) else {
            toast = "Не удалось открыть переписку"
            return nil
        }
        if !conversations.contains(where: { $0.id == conv.id }) {
            conversations = sortConversations(conversations + [conv])
        }
        return conv
    }

    func setPinned(_ conversation: Conversation, pinned: Bool) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].pinned = pinned
        conversations = sortConversations(conversations)
        try? await MessengerService.setPinned(conversationId: conversation.id, pinned: pinned)
    }

    func hide(_ conversation: Conversation) async {
        conversations.removeAll { $0.id == conversation.id }
        if selectedConversationID == conversation.id { selectedConversationID = nil }
        try? await MessengerService.hideConversation(conversation.id)
    }

    // MARK: Открытая переписка

    func messages(for id: UUID) -> [Message] { messagesByConversation[id] ?? [] }
    func hasMore(for id: UUID) -> Bool { hasMoreByConversation[id] ?? false }
    func isTyping(in id: UUID) -> Bool { typingIn.contains(id) }

    func open(_ conversation: Conversation) {
        selectedConversationID = conversation.id
        if messagesByConversation[conversation.id] == nil {
            Task { await loadMessages(conversationId: conversation.id) }
        }
    }

    /// before == nil — первая загрузка (вызывается из open(_:), только пока в кэше для этого диалога
    /// ничего нет). before != nil — подгрузка более старых сообщений сверху (loadOlderMessages).
    /// В обоих случаях просто сливаем с уже известным и убираем дубликаты по id.
    func loadMessages(conversationId: UUID, before: Date? = nil) async {
        guard let page = try? await MessengerService.messages(conversationId: conversationId, before: before) else { return }
        let existing = messagesByConversation[conversationId] ?? []
        let knownIDs = Set(existing.map(\.id))
        let fresh = page.messages.filter { !knownIDs.contains($0.id) }
        messagesByConversation[conversationId] = (existing + fresh).sorted { $0.sentAt < $1.sentAt }
        hasMoreByConversation[conversationId] = page.hasMore
    }

    func loadOlderMessages(conversationId: UUID) async {
        guard let oldest = messagesByConversation[conversationId]?.first else { return }
        await loadMessages(conversationId: conversationId, before: oldest.sentAt)
    }

    // MARK: Отправка

    func send(conversationId: UUID, text: String?, attachmentFileId: UUID? = nil, durationSeconds: Double? = nil) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.isEmpty == false) || attachmentFileId != nil else { return }

        let sentOverSocket = socket.sendMessage(conversationId: conversationId, text: trimmed, attachmentFileId: attachmentFileId, durationSeconds: durationSeconds)
        guard !sentOverSocket else { return }  // сервер сам пришлёт готовое сообщение по сокету

        Task {
            guard let message = try? await MessengerService.sendMessage(conversationId: conversationId, text: trimmed, attachmentFileId: attachmentFileId, durationSeconds: durationSeconds) else {
                toast = "Не удалось отправить сообщение"
                return
            }
            appendIfNew(message)
            touchConversation(conversationId, with: message)
        }
    }

    func sendTyping(conversationId: UUID) {
        socket.sendTyping(conversationId: conversationId)
    }

    func markRead(conversationId: UUID) {
        guard let last = messagesByConversation[conversationId]?.last, let my = myUserID, last.senderId != my else { return }
        socket.sendRead(conversationId: conversationId, upToMessageId: last.id)
        Task { try? await MessengerService.markRead(conversationId: conversationId, upToMessageId: last.id) }
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].unreadCount = 0
        }
    }

    func edit(_ message: Message, newText: String) {
        Task {
            guard let updated = try? await MessengerService.editMessage(message.id, text: newText) else {
                toast = "Не удалось отредактировать сообщение"
                return
            }
            replace(updated)
        }
    }

    func delete(_ message: Message, forEveryone: Bool) {
        Task {
            guard (try? await MessengerService.deleteMessage(message.id, forEveryone: forEveryone)) != nil else {
                toast = "Не удалось удалить сообщение"
                return
            }
            if forEveryone {
                var updated = message
                updated.deletedForEveryone = true
                updated.text = nil
                updated.attachment = nil
                replace(updated)
            } else {
                messagesByConversation[message.conversationId]?.removeAll { $0.id == message.id }
            }
        }
    }

    // MARK: События сокета

    private func handle(_ event: WSEvent) {
        switch event {
        case .message(let message):
            appendIfNew(message)
            touchConversation(message.conversationId, with: message)
            if selectedConversationID == message.conversationId { markRead(conversationId: message.conversationId) }

        case .messageStatus(let id, let status):
            updateStatus(messageId: id, status: status)

        case .read(let conversationId, let upToMessageId):
            markLocalMessagesRead(conversationId: conversationId, upTo: upToMessageId)

        case .typing(let conversationId):
            typingIn.insert(conversationId)
            typingResetTasks[conversationId]?.cancel()
            typingResetTasks[conversationId] = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                typingIn.remove(conversationId)
            }

        case .presence(let username, let online, let lastActiveAt):
            updatePresence(username: username, online: online, lastActiveAt: lastActiveAt)

        case .error:
            break
        }
    }

    private func appendIfNew(_ message: Message) {
        var list = messagesByConversation[message.conversationId] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        messagesByConversation[message.conversationId] = list.sorted { $0.sentAt < $1.sentAt }
    }

    private func replace(_ message: Message) {
        guard var list = messagesByConversation[message.conversationId] else { return }
        guard let index = list.firstIndex(where: { $0.id == message.id }) else { return }
        list[index] = message
        messagesByConversation[message.conversationId] = list
    }

    private func updateStatus(messageId: UUID, status: String) {
        guard let state = DeliveryStatus(rawValue: status) else { return }
        for (convId, list) in messagesByConversation {
            guard let index = list.firstIndex(where: { $0.id == messageId }) else { continue }
            messagesByConversation[convId]?[index].status = state
        }
    }

    private func markLocalMessagesRead(conversationId: UUID, upTo: UUID) {
        guard var list = messagesByConversation[conversationId] else { return }
        guard let cutoffIndex = list.firstIndex(where: { $0.id == upTo }) else { return }
        for i in 0...cutoffIndex where list[i].status != .read {
            list[i].status = .read
        }
        messagesByConversation[conversationId] = list
    }

    private func touchConversation(_ conversationId: UUID, with message: Message) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            Task { await refreshConversations() }  // сообщение в диалоге, которого ещё нет в списке
            return
        }
        conversations[index].lastMessage = message
        conversations[index].updatedAt = message.sentAt
        if message.senderId != myUserID, selectedConversationID != conversationId {
            conversations[index].unreadCount += 1
        }
        conversations = sortConversations(conversations)
    }

    private func updatePresence(username: String, online: Bool, lastActiveAt: Date?) {
        guard let index = conversations.firstIndex(where: { $0.participant.username == username }) else { return }
        conversations[index].participant.online = online
        conversations[index].participant.lastActiveAt = lastActiveAt
    }
}
