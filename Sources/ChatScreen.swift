import SwiftUI
import UIKit

// MARK: - Главный экран мессенджера

struct ChatScreen: View {
    @EnvironmentObject var messenger: MessengerStore
    @EnvironmentObject var auth: AuthSession
    @State var text = ""
    @FocusState var focused: Bool
    @State private var showNewMessage = false
    @State private var typingSentAt: Date = .distantPast
    @State private var pendingDelete: Message?
    @State private var editingMessage: Message?
    @State private var editText = ""
    let openDrawer: () -> Void

    private var conversation: Conversation? {
        guard let id = messenger.selectedConversationID else { return nil }
        return messenger.conversations.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(conversation: conversation, openDrawer: openDrawer, newMessage: { showNewMessage = true })

            Group {
                if let conversation = conversation {
                    conversationBody(conversation)
                } else {
                    emptyNoSelection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { focused = false }

            if conversation != nil {
                InputBar(text: $text, focused: $focused, onTyping: sendTyping, onSend: send)
            }
        }
        .sheet(isPresented: $showNewMessage) {
            NewMessageSheet(onOpen: { messenger.open($0) })
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let message = pendingDelete, isMine(message) {
                Button("Удалить у всех", role: .destructive) { messenger.delete(message, forEveryone: true) }
            }
            Button("Удалить у себя", role: .destructive) {
                if let message = pendingDelete { messenger.delete(message, forEveryone: false) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Редактировать сообщение", isPresented: Binding(get: { editingMessage != nil }, set: { if !$0 { editingMessage = nil } })) {
            TextField("Текст", text: $editText)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") {
                if let message = editingMessage, !editText.trimmingCharacters(in: .whitespaces).isEmpty {
                    messenger.edit(message, newText: editText)
                }
            }
        }
        .onChange(of: messenger.selectedConversationID) { id in
            if let id = id { messenger.markRead(conversationId: id) }
        }
    }

    private var deleteTitle: String { "Удалить сообщение?" }

    private func isMine(_ message: Message) -> Bool { message.senderId == auth.me?.id }

    @ViewBuilder
    private func conversationBody(_ conversation: Conversation) -> some View {
        let messages = messenger.messages(for: conversation.id)
        if messages.isEmpty {
            emptyConversation(conversation)
        } else {
            MessageList(messages: messages, conversation: conversation, isMine: isMine,
                       isTyping: messenger.isTyping(in: conversation.id),
                       onEdit: { editingMessage = $0; editText = $0.text ?? "" },
                       onDelete: { pendingDelete = $0 },
                       onLoadMore: { Task { await messenger.loadOlderMessages(conversationId: conversation.id) } })
        }
    }

    /// Пустая переписка: крупный приглушённый аватар и юзернейм по центру, как в Telegram —
    /// пропадает после первого сообщения.
    private func emptyConversation(_ conversation: Conversation) -> some View {
        VStack(spacing: 14) {
            Spacer()
            RemoteAvatar(urlPath: conversation.participant.avatarUrl, fallbackText: conversation.participant.username, size: 84)
                .opacity(0.55)
            Text(conversation.participant.username)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Spacer()
        }
    }

    private var emptyNoSelection: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.secondary)
            Text("Выберите переписку слева").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            Button { showNewMessage = true } label: {
                Text("Написать сообщение").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 4)
            Spacer()
            Spacer()
        }
    }

    private func sendTyping() {
        guard let id = messenger.selectedConversationID else { return }
        guard Date().timeIntervalSince(typingSentAt) > 2 else { return }
        typingSentAt = Date()
        messenger.sendTyping(conversationId: id)
    }

    private func send() {
        guard let id = messenger.selectedConversationID else { return }
        let value = text
        text = ""
        messenger.send(conversationId: id, text: value)
    }
}

// MARK: - Верхняя панель

struct TopBar: View {
    let conversation: Conversation?
    let openDrawer: () -> Void
    let newMessage: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openDrawer) { MenuGlyph() }

            if let conversation = conversation {
                HStack(spacing: 8) {
                    RemoteAvatar(urlPath: conversation.participant.avatarUrl, fallbackText: conversation.participant.username, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(conversation.participant.username).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(conversation.participant.online ? "в сети" : "была(а) недавно")
                            .font(.system(size: 11)).foregroundStyle(conversation.participant.online ? Theme.accent : Theme.secondary)
                    }
                }
            } else {
                Text("Мессенджер").font(Typo.title)
            }

            Spacer()

            Button(action: newMessage) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 6)
        .frame(height: 44)
    }
}

// MARK: - Список сообщений

struct MessageList: View {
    let messages: [Message]
    let conversation: Conversation
    let isMine: (Message) -> Bool
    let isTyping: Bool
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    Button("Показать раньше") { onLoadMore() }
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .padding(.top, 6)

                    ForEach(messages) { message in
                        MessageBubble(message: message, mine: isMine(message), onEdit: { onEdit(message) }, onDelete: { onDelete(message) })
                            .id(message.id)
                    }
                    if isTyping {
                        HStack { TypingBubble(); Spacer() }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let mine: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: .trailing, spacing: 3) {
                if message.deletedForEveryone {
                    Text("Сообщение удалено")
                        .font(.system(size: 15)).italic().foregroundStyle(Theme.secondary)
                } else {
                    if let text = message.text, !text.isEmpty {
                        Text(text).font(.system(size: 16)).foregroundStyle(mine ? .white : .primary)
                    }
                    if let attachment = message.attachment {
                        AttachmentPreview(attachment: attachment, tinted: mine)
                    }
                }
                HStack(spacing: 3) {
                    if message.editedAt != nil && !message.deletedForEveryone {
                        Text("изменено").font(.system(size: 10))
                    }
                    Text(message.sentAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 10))
                    if mine { statusIcon }
                }
                .foregroundStyle(mine ? .white.opacity(0.75) : Theme.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(mine ? Theme.accent : Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contextMenu {
                if let text = message.text { Button { UIPasteboard.general.string = text } label: { Label("Копировать", systemImage: "doc.on.doc") } }
                if mine && !message.deletedForEveryone && message.attachment == nil {
                    Button(action: onEdit) { Label("Редактировать", systemImage: "pencil") }
                }
                if !message.deletedForEveryone {
                    Button(role: .destructive, action: onDelete) { Label("Удалить", systemImage: "trash") }
                }
            }
            if !mine { Spacer(minLength: 56) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sent: Image(systemName: "checkmark").font(.system(size: 9))
        case .delivered: Image(systemName: "checkmark").font(.system(size: 9))
        case .read: Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.white)
        }
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    let tinted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(Format.size(attachment.sizeBytes)).font(.system(size: 11)).opacity(0.75)
            }
        }
        .foregroundStyle(tinted ? .white : .primary)
        .padding(8)
        .background(.black.opacity(tinted ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        if attachment.durationSeconds != nil { return "waveform" }
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        return "doc"
    }
}

struct TypingBubble: View {
    @State private var phase = 0
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.secondary).frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            loopTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
                }
            }
        }
        .onDisappear {
            loopTask?.cancel()
            loopTask = nil
        }
    }
}

// MARK: - Поле ввода

struct InputBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onTyping: () -> Void
    let onSend: () -> Void

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button { /* TODO: вложения — следующий этап */ } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .frame(width: 32, height: 32)
            }

            TextField("Сообщение", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .font(Typo.input)
                .frame(minHeight: 32)
                .onChange(of: text) { _ in if hasText { onTyping() } }

            if !hasText {
                Button { /* TODO: голосовые — следующий этап */ } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 32, height: 32)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            Button(action: onSend) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
            }
            .disabled(!hasText)
            .opacity(hasText ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle())
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .padding(.horizontal, 34)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasText)
    }
}
