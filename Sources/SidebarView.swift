import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var auth: AuthSession
    let close: () -> Void
    @State private var showAll = false

    // Все шесть пунктов в одном блоке, без разделителя и отступа перед «Музыкой».
    private let menu: [(icon: String, title: String, target: AppSection?)] = [
        ("paintbrush", "Изображения", nil),
        ("books.vertical", "Библиотека", .library),
        ("folder", "Проекты", nil),
        ("clock", "Запланированные", nil),
        ("square.grid.2x2", "Обзор", nil),
        ("music.note", "Музыка", .music)
    ]

    private var visibleChats: [Conversation] {
        showAll ? store.conversations : Array(store.conversations.prefix(7))
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

            // История чатов
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleChats) { chat in
                        Button {
                            router.section = .chat
                            store.open(chat)
                            close()
                        } label: {
                            Text(chat.title)
                                .font(Typo.history)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                        }
                    }
                    if !showAll && store.conversations.count > 7 {
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
                .padding(.horizontal, 32)
            }

            // Низ: «Чат» и настройки
            HStack {
                Button {
                    router.section = .chat
                    store.newChat()
                    close()
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
    }
}
