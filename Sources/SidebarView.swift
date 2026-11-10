import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var messenger: MessengerStore
    let close: () -> Void

    @State private var showAll = false
    @State private var showNewMessage = false
    @State private var pendingHide: Conversation?

    // Все шесть пунктов в одном блоке, без разделителя и отступа перед «Музыкой».
    private let menu: [(icon: String, title: String, target: AppSection?)] = [
        ("paintbrush", "Изображения", nil),
        ("books.vertical", "Библиотека", .library),
        ("folder", "Проекты", nil),
        ("clock", "Запланированные", nil),
        ("square.grid.2x2", "Обзор", nil),
        ("music.note", "Музыка", .music)
    ]

    private var visibleConversations: [Conversation] {
        showAll ? messenger.conversations : Array(messenger.conversations.prefix(7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Заголовок + поиск
            HStack {
                Text(AppConfig.name)
                    .font(Typo.title)
                Spacer()
                Button { /* TODO: глобальный поиск */ } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 29)
            .frame(height: 44)

            // Разделы
            VStack(alignment: .leading, spacing: 0) {
                ForEach(menu, id: \.title) { item in
                    Button {
                        if let target = item.target {
                            router.section = target
                            close()
                        }
                    } label: {
                        HStack(spacing: 9.5) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .light))
                                .frame(width: 22)
                            Text(item.title)
                                .font(Typo.menuItem)
                            Spacer()
                        }
                        .frame(height: 45)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 4.5)

            Divider()
                .padding(.horizontal, 32)
                .padding(.top, 25)
                .padding(.bottom, 24)

            // Переписки
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !messenger.conversationsLoaded {
                        ProgressView().padding(.top, 20).frame(maxWidth: .infinity)
                    } else if messenger.conversations.isEmpty {
                        Text("Пока нет переписок").font(Typo.history).foregroundStyle(Theme.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(visibleConversations) { conversation in
                            conversationRow(conversation)
                        }
                        if !showAll && messenger.conversations.count > 7 {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) { showAll = true }
                            } label: {
                                Text("Показать все…")
                                    .font(Typo.history)
                                    .foregroundStyle(Theme.secondary)
                                    .frame(height: 42)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }

            // Низ: «Чат» и настройки
            HStack {
                Button {
                    showNewMessage = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                        Text("Чат")
                    }
                    .font(Typo.button)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 41)
                    .background(Theme.accent, in: Capsule())
                }

                Spacer()

                Button { auth.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 41, height: 41)
                        .background(Theme.card, in: Circle())
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                }
            }
            .padding(.leading, 34)
            .padding(.trailing, 25)
            .padding(.bottom, 1)
        }
        .foregroundStyle(.primary)
        .buttonStyle(PressableStyle())
        .sheet(isPresented: $showNewMessage) {
            NewMessageSheet(onOpen: openConversation)
        }
        .confirmationDialog("Удалить переписку у себя?", isPresented: Binding(get: { pendingHide != nil }, set: { if !$0 { pendingHide = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let conversation = pendingHide { Task { await messenger.hide(conversation) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        Button {
            openConversation(conversation)
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteAvatar(urlPath: conversation.participant.avatarUrl, fallbackText: conversation.participant.username, size: 36)
                    if conversation.participant.online {
                        Circle().fill(.green).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(conversation.participant.username)
                            .font(Typo.history).fontWeight(conversation.unreadCount > 0 ? .semibold : .regular)
                            .lineLimit(1)
                        if conversation.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text(previewText(for: conversation))
                        .font(.system(size: 12))
                        .foregroundStyle(messenger.isTyping(in: conversation.id) ? Theme.accent : Theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button { Task { await messenger.setPinned(conversation, pinned: !conversation.pinned) } } label: {
                Label(conversation.pinned ? "Открепить" : "Закрепить", systemImage: "pin")
            }
            Button(role: .destructive) { pendingHide = conversation } label: {
                Label("Удалить у себя", systemImage: "trash")
            }
        }
    }

    private func previewText(for conversation: Conversation) -> String {
        if messenger.isTyping(in: conversation.id) { return "печатает…" }
        guard let last = conversation.lastMessage else { return "" }
        if last.deletedForEveryone { return "Сообщение удалено" }
        if let attachment = last.attachment {
            return last.text?.isEmpty == false ? last.text! : attachment.mimeType.hasPrefix("image/") ? "Фото" : (attachment.durationSeconds != nil ? "Голосовое сообщение" : "Файл")
        }
        return last.text ?? ""
    }

    private func openConversation(_ conversation: Conversation) {
        router.section = .chat
        messenger.open(conversation)
        close()
    }
}
