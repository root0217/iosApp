import SwiftUI

/// Экран «Написать сообщение»: поиск по всем юзернеймам сверху, уже начатые переписки снизу —
/// тот же паттерн, что в Telegram, без групп и каналов (мессенджер только 1:1).
struct NewMessageSheet: View {
    @EnvironmentObject var messenger: MessengerStore
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Conversation) -> Void

    @State private var query = ""
    @State private var results: [PublicUserOut] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var startingUsername: String?
    @FocusState private var focused: Bool

    private var existingContacts: [PublicUserOut] {
        messenger.conversations.map(\.participant).sorted { $0.username < $1.username }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                List {
                    if !query.isEmpty {
                        if isSearching {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if results.isEmpty {
                            Text("Никого не нашлось").foregroundStyle(Theme.secondary)
                        } else {
                            ForEach(results) { user in row(user) }
                        }
                    } else if existingContacts.isEmpty {
                        Text("Пока нет ни одной переписки").foregroundStyle(Theme.secondary)
                    } else {
                        Section("Переписки") {
                            ForEach(existingContacts) { user in row(user) }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .background(Theme.background)
            .navigationTitle("Написать сообщение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            TextField("Найти по username", text: $query)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused)
                .onChange(of: query) { search($0) }
            if !query.isEmpty {
                Button { query = ""; results = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ user: PublicUserOut) -> some View {
        Button {
            Task { await open(user) }
        } label: {
            HStack(spacing: 12) {
                RemoteAvatar(urlPath: user.avatarUrl, fallbackText: user.username, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.username).font(.system(size: 15, weight: .medium))
                    Text(user.online ? "В сети" : "Был(а) недавно")
                        .font(.system(size: 12)).foregroundStyle(user.online ? Theme.accent : Theme.secondary)
                }
                Spacer()
                if startingUsername == user.username { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(startingUsername != nil)
        .listRowBackground(Theme.background)
    }

    private func search(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; isSearching = false; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = (try? await AuthAPI.search(trimmed)) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func open(_ user: PublicUserOut) async {
        startingUsername = user.username
        defer { startingUsername = nil }
        guard let conversation = await messenger.startConversation(withUsername: user.username) else { return }
        onOpen(conversation)
        dismiss()
    }
}
