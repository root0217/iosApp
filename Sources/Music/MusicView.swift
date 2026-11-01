import SwiftUI
import UniformTypeIdentifiers

enum MusicTab: String, CaseIterable, Identifiable {
    case library = "Моя музыка"
    case playlists = "Плейлисты"
    case recent = "Недавно"

    var id: String { rawValue }
}

private enum PlaylistPrompt {
    case create(trackToAdd: Track?)
    case rename(Playlist)
}

private enum PendingDelete {
    case track(Track)
    case playlist(Playlist)
}

/// Значок «меню» в верхней панели (тот же, что на экране чата).
struct MenuGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4.5) {
            Capsule().frame(width: 15, height: 2)
            Capsule().frame(width: 10, height: 2)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

/// Музыкальный экран: библиотека, плейлисты, недавно прослушанное, поиск, импорт файлов.
struct MusicView: View {
    @EnvironmentObject var music: MusicManager
    let openDrawer: () -> Void

    @State private var tab: MusicTab = .library
    @State private var query = ""
    @State private var showImporter = false
    @State private var showPlayer = false
    @State private var openPlaylistID: UUID?
    @State private var prompt: PlaylistPrompt?
    @State private var promptText = ""
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if openPlaylistID == nil { tabBar }
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if music.currentTrack != nil {
                MiniPlayerView(clock: music.clock, onOpen: { showPlayer = true })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: music.currentTrack?.id)
        .overlay(alignment: .top) { toast }
        .onChange(of: tab) { _ in query = "" }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                music.importFiles(urls)
            case .failure(let error):
                music.statusMessage = "Не удалось открыть файлы: \(error.localizedDescription)"
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            MusicPlayerView().environmentObject(music)
        }
        .alert(promptTitle, isPresented: promptBinding) {
            let current = prompt
            TextField("Название", text: $promptText)
            Button("Отмена", role: .cancel) {}
            Button("Готово") { commit(current) }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            let current = pendingDelete
            Button("Удалить", role: .destructive) { performDelete(current) }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: Верхняя панель

    private var openPlaylist: Playlist? {
        guard let id = openPlaylistID else { return nil }
        return music.playlists.first(where: { $0.id == id })
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if openPlaylistID != nil {
                Button { openPlaylistID = nil; query = "" } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Button(action: openDrawer) { MenuGlyph() }
            }

            Text(openPlaylist?.name ?? "Музыка")
                .font(Typo.title)
                .lineLimit(1)

            Spacer()

            if let playlist = openPlaylist {
                Menu {
                    Button {
                        promptText = playlist.name
                        prompt = .rename(playlist)
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = .playlist(playlist)
                    } label: {
                        Label("Удалить плейлист", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else if music.isImporting {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button { showImporter = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 6)
        .frame(height: 44)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(MusicTab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tab == item ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(tab == item ? Theme.accent : Theme.field, in: Capsule())
                }
            }
            Spacer()
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Содержимое

    @ViewBuilder
    private var content: some View {
        if let playlist = openPlaylist {
            trackScroll(music.tracks(in: playlist), playlist: playlist,
                        emptyIcon: "music.note.list", emptyTitle: "Плейлист пуст",
                        emptyText: "Добавьте треки через меню «…» у трека", showImport: false)
        } else {
            switch tab {
            case .library:
                trackScroll(music.tracks, playlist: nil,
                            emptyIcon: "music.note", emptyTitle: "Пока нет музыки",
                            emptyText: "Добавьте аудиофайлы с устройства", showImport: true)
            case .playlists:
                playlistsContent
            case .recent:
                trackScroll(music.recentTracks, playlist: nil,
                            emptyIcon: "clock", emptyTitle: "Пока ничего",
                            emptyText: "Здесь появятся треки, которые вы слушали", showImport: false)
            }
        }
    }

    private func trackScroll(_ source: [Track], playlist: Playlist?, emptyIcon: String,
                             emptyTitle: String, emptyText: String, showImport: Bool) -> some View {
        let filtered = filter(source)
        return VStack(spacing: 0) {
            if source.isEmpty {
                emptyState(icon: emptyIcon, title: emptyTitle, text: emptyText, showImport: showImport)
            } else {
                searchField
                ScrollView {
                    LazyVStack(spacing: 0) {
                        playHeader(filtered)
                        ForEach(filtered) { track in
                            TrackRow(track: track,
                                     context: filtered,
                                     playlist: playlist,
                                     onDelete: { pendingDelete = .track($0) },
                                     onNewPlaylist: { prompt = .create(trackToAdd: $0); promptText = "" })
                        }
                        if filtered.isEmpty {
                            Text("Ничего не найдено")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondary)
                                .padding(.top, 40)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var playlistsContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button {
                    promptText = ""
                    prompt = .create(trackToAdd: nil)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .light))
                            .frame(width: 48, height: 48)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Новый плейлист")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())

                ForEach(music.playlists) { playlist in
                    playlistRow(playlist)
                }

                if music.playlists.isEmpty {
                    Text("Плейлистов пока нет")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 30)
                }
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let items = music.tracks(in: playlist)
        let cover = items.first(where: { $0.artworkFile != nil })?.artworkFile
        return HStack(spacing: 4) {
            Button {
                query = ""
                openPlaylistID = playlist.id
            } label: {
                HStack(spacing: 12) {
                    AlbumArtwork(fileName: cover, size: 48, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Text(trackCountText(items.count))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            Menu {
                Button {
                    promptText = playlist.name
                    prompt = .rename(playlist)
                } label: {
                    Label("Переименовать", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = .playlist(playlist)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 62)
    }

    // MARK: Мелкие элементы

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            TextField("Поиск", text: $query)
                .font(Typo.input)
                .disableAutocorrection(true)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func playHeader(_ tracks: [Track]) -> some View {
        if !tracks.isEmpty {
            HStack(spacing: 10) {
                Button {
                    if let first = tracks.first { music.play(first, in: tracks) }
                } label: {
                    chip(icon: "play.fill", title: "Слушать", filled: true)
                }
                Button { music.playShuffled(tracks) } label: {
                    chip(icon: "shuffle", title: "Вперемешку", filled: false)
                }
                Spacer()
                Text(trackCountText(tracks.count))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(icon: String, title: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(filled ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(filled ? Theme.accent : Theme.field, in: Capsule())
    }

    private func emptyState(icon: String, title: String, text: String, showImport: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            if showImport {
                Button { showImporter = true } label: {
                    chip(icon: "plus", title: "Добавить файлы", filled: true)
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = music.statusMessage, !message.isEmpty {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 54)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if music.statusMessage == message { music.statusMessage = nil }
                }
        }
    }

    // MARK: Поиск, диалоги, действия

    private func filter(_ tracks: [Track]) -> [Track] {
        let words = query.split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return tracks }
        return tracks.filter { track in
            words.allSatisfy { word in
                track.title.localizedCaseInsensitiveContains(word)
                    || track.artist.localizedCaseInsensitiveContains(word)
                    || track.album.localizedCaseInsensitiveContains(word)
            }
        }
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var promptTitle: String {
        switch prompt {
        case .some(.rename(_)): return "Переименовать плейлист"
        default: return "Новый плейлист"
        }
    }

    private func commit(_ value: PlaylistPrompt?) {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = value, !name.isEmpty else { return }
        switch value {
        case .create(let track):
            music.createPlaylist(name: name, trackIDs: track.map { [$0.id] } ?? [])
        case .rename(let playlist):
            music.renamePlaylist(playlist.id, to: name)
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        switch pendingDelete {
        case .some(.track(let track)): return "Удалить «\(track.title)» с устройства?"
        case .some(.playlist(let playlist)): return "Удалить плейлист «\(playlist.name)»? Треки останутся в библиотеке."
        case .none: return ""
        }
    }

    private func performDelete(_ value: PendingDelete?) {
        guard let value = value else { return }
        switch value {
        case .track(let track):
            music.deleteTrack(track)
        case .playlist(let playlist):
            if openPlaylistID == playlist.id { openPlaylistID = nil }
            music.deletePlaylist(playlist.id)
        }
    }
}
