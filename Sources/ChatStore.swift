import SwiftUI

struct Message: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    var text: String
}

struct Conversation: Identifiable {
    let id = UUID()
    var title: String
    var messages: [Message]
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?          // nil = новый пустой чат
    @Published var isStreaming = false
    private var streamTask: Task<Void, Never>?

    var messages: [Message] {
        conversations.first(where: { $0.id == currentID })?.messages ?? []
    }

    func newChat() {
        stop()
        currentID = nil
    }

    func open(_ conversation: Conversation) {
        stop()
        currentID = conversation.id
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        if currentID == nil {
            let c = Conversation(title: String(text.prefix(40)), messages: [])
            conversations.insert(c, at: 0)
            currentID = c.id
        }
        guard let convID = currentID,
              let ci = conversations.firstIndex(where: { $0.id == convID }) else { return }

        let reply = Message(isUser: false, text: "")
        conversations[ci].messages.append(Message(isUser: true, text: text))
        conversations[ci].messages.append(reply)
        isStreaming = true

        streamTask = Task { [weak self] in
            await self?.fakeStream(for: text, replyID: reply.id, convID: convID)
        }
    }

    // MARK: - Заглушка модели (потом заменим на настоящий API)

    private func fakeStream(for prompt: String, replyID: UUID, convID: UUID) async {
        let answer = "Это заглушка ответа. Здесь позже будет настоящая модель.\n\nТы написал: \(prompt)"
        try? await Task.sleep(nanoseconds: 600_000_000)
        for ch in answer {
            if Task.isCancelled { return }
            append(String(ch), replyID: replyID, convID: convID)
            try? await Task.sleep(nanoseconds: 22_000_000)
        }
        isStreaming = false
        streamTask = nil
    }

    private func append(_ piece: String, replyID: UUID, convID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == convID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].text += piece
    }
}
