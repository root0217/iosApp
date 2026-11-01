import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Время воспроизведения вынесено отдельно: оно меняется дважды в секунду, и перерисовываться из-за него
/// должны только мини-плеер и экран плеера, а не весь список треков.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

/// Единая точка управления музыкой: библиотека, плейлисты, очередь, AVPlayer, экран блокировки.
/// Класс намеренно без @MainActor: все вызовы идут с главного потока (SwiftUI, таймеры и уведомления с queue: .main).
final class MusicManager: ObservableObject {

    // MARK: Состояние для интерфейса
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var recentIDs: [UUID] = []
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isImporting = false
    @Published var statusMessage: String?

    let clock = PlaybackClock()

    // MARK: Внутреннее состояние
    private enum Keys {
        static let lastTrack = "music.lastTrackID"
        static let lastPosition = "music.lastPosition"
        static let shuffle = "music.shuffle"
        static let repeatMode = "music.repeat"
    }

    private let player = AVPlayer()
    private var queue: [UUID] = []            // порядок воспроизведения (с учётом перемешивания)
    private var originalQueue: [UUID] = []    // порядок до перемешивания
    private var queueIndex = 0
    private var isScrubbing = false
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureStreak = 0
    private var tickCounter = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?

    // MARK: Запуск

    init() {
        if let snapshot = MusicStorage.loadSnapshot() {
            tracks = snapshot.tracks
            playlists = snapshot.playlists
            recentIDs = snapshot.recentIDs
        }
        let defaults = UserDefaults.standard
        isShuffled = defaults.bool(forKey: Keys.shuffle)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off

        configureAudioSession()
        configureRemoteCommands()
        addTimeObserver()
        restorePlaybackState()

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.persistPlaybackState()
        }
    }

    // MARK: - Воспроизведение

    /// Играет трек из списка, в котором его нажали (очередь = этот список).
    func play(_ track: Track, in context: [Track], forceRestart: Bool = false) {
        if !forceRestart, currentTrack?.id == track.id, player.currentItem != nil {
            togglePlayPause()
            return
        }
        let ids = context.map { $0.id }
        originalQueue = ids.contains(track.id) ? ids : [track.id]
        queue = isShuffled ? shuffledQueue(startingWith: track.id, from: originalQueue) : originalQueue
        queueIndex = queue.firstIndex(of: track.id) ?? 0
        failureStreak = 0
        load(trackID: track.id, autoplay: true)
    }

    /// «Вперемешку»: включает перемешивание и стартует со случайного трека.
    func playShuffled(_ context: [Track]) {
        guard let first = context.randomElement() else { return }
        isShuffled = true
        UserDefaults.standard.set(true, forKey: Keys.shuffle)
        play(first, in: context, forceRestart: true)
    }

    func play() {
        guard let track = currentTrack else { return }
        if player.currentItem == nil {
            load(trackID: track.id, autoplay: true, startAt: clock.currentTime)
            return
        }
        AudioSessionManager.shared.activate()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPlaybackState()
        updateNowPlaying()
    }

    func togglePlayPause() {
        if currentTrack == nil {
            if let first = tracks.first { play(first, in: tracks) }
            return
        }
        if isPlaying { pause() } else { play() }
    }

    func next() {
        advance()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if clock.currentTime > 3 {
            seek(to: 0)
        } else if queueIndex > 0 {
            queueIndex -= 1
            load(trackID: queue[queueIndex], autoplay: true)
        } else if repeatMode == .all {
            queueIndex = queue.count - 1
            load(trackID: queue[queueIndex], autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let limit = clock.duration
        let target = max(0, limit > 0 ? min(seconds, limit) : seconds)
        clock.currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
        persistPlaybackState()
    }

    func beginScrubbing() { isScrubbing = true }

    func endScrubbing(at seconds: Double) {
        seek(to: seconds)
        isScrubbing = false
    }

    func toggleShuffle() {
        isShuffled.toggle()
        UserDefaults.standard.set(isShuffled, forKey: Keys.shuffle)
        guard let current = currentTrack else { return }
        queue = isShuffled ? shuffledQueue(startingWith: current.id, from: originalQueue) : originalQueue
        queueIndex = queue.firstIndex(of: current.id) ?? 0
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        UserDefaults.standard.set(repeatMode.rawValue, forKey: Keys.repeatMode)
    }

    func stopPlayback() {
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        currentTrack = nil
        isPlaying = false
        clock.currentTime = 0
        clock.duration = 0
        nowPlayingArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistPlaybackState()
    }

    // MARK: - Загрузка трека в плеер

    private func load(trackID: UUID, autoplay: Bool, startAt: Double = 0) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        let url = MusicStorage.fileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Файл «\(track.title)» не найден на устройстве"
            skipBrokenTrack()
            return
        }

        removeItemObservers()
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.trackDidFinish()
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let message = observed.error?.localizedDescription
            DispatchQueue.main.async {
                self?.itemStatusChanged(status, message: message, trackID: trackID)
            }
        }
        player.replaceCurrentItem(with: item)

        currentTrack = track
        clock.duration = track.duration
        clock.currentTime = startAt
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }
        loadNowPlayingArtwork(for: track)

        if autoplay {
            AudioSessionManager.shared.activate()
            player.play()
            isPlaying = true
            markRecent(track.id)
        } else {
            isPlaying = false
        }
        updateNowPlaying()
        persistPlaybackState()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, trackID: UUID) {
        guard currentTrack?.id == trackID else { return }
        switch status {
        case .readyToPlay:
            failureStreak = 0
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                clock.duration = seconds
                updateNowPlaying()
            }
        case .failed:
            let title = currentTrack?.title ?? "трек"
            statusMessage = "Не удалось воспроизвести «\(title)»"
            NSLog("Music: ошибка воспроизведения: \(message ?? "неизвестная")")
            skipBrokenTrack()
        default:
            break
        }
    }

    /// Битый или пропавший файл: идём к следующему, но не зацикливаемся, если сломана вся очередь.
    private func skipBrokenTrack() {
        failureStreak += 1
        if failureStreak >= max(queue.count, 1) {
            failureStreak = 0
            player.pause()
            isPlaying = false
            return
        }
        advance()
    }

    private func trackDidFinish() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            isPlaying = true
            updateNowPlaying()
        } else {
            advance()
        }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            load(trackID: queue[queueIndex], autoplay: true)
        } else if repeatMode == .all {
            queueIndex = 0
            load(trackID: queue[0], autoplay: true)
        } else {
            // конец очереди: останавливаемся, трек остаётся в начале
            player.pause()
            isPlaying = false
            seek(to: 0)
            updateNowPlaying()
        }
    }

    private func removeItemObservers() {
        itemObservation?.invalidate()
        itemObservation = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    private func shuffledQueue(startingWith id: UUID, from ids: [UUID]) -> [UUID] {
        var rest = ids.filter { $0 != id }
        rest.shuffle()
        return [id] + rest
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time)
        }
    }

    private func tick(_ time: CMTime) {
        guard !isScrubbing else { return }
        let seconds = time.seconds
        if seconds.isFinite && seconds >= 0 { clock.currentTime = seconds }
        tickCounter += 1
        if tickCounter % 10 == 0 { persistPlaybackState() }   // раз в ~5 секунд
    }

    // MARK: - Экран блокировки и системные кнопки

    private func configureAudioSession() {
        let session = AudioSessionManager.shared
        session.onInterruptionBegan = { [weak self] in self?.pause() }
        session.onInterruptionEnded = { [weak self] shouldResume in
            if shouldResume { self?.play() }
        }
        session.onRouteLost = { [weak self] in self?.pause() }
        session.startObserving()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = positionEvent.positionTime
            DispatchQueue.main.async { self?.seek(to: position) }
            return .success
        }
    }

    private func loadNowPlayingArtwork(for track: Track) {
        nowPlayingArtwork = nil
        guard let name = track.artworkFile,
              let image = UIImage(contentsOfFile: MusicStorage.artworkURL(named: name).path) else { return }
        nowPlayingArtwork = MusicManager.makeArtwork(image)
    }

    private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let artwork = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Запоминание состояния

    private func persistPlaybackState() {
        let defaults = UserDefaults.standard
        if let track = currentTrack {
            defaults.set(track.id.uuidString, forKey: Keys.lastTrack)
            defaults.set(clock.currentTime, forKey: Keys.lastPosition)
        } else {
            defaults.removeObject(forKey: Keys.lastTrack)
            defaults.removeObject(forKey: Keys.lastPosition)
        }
    }

    private func restorePlaybackState() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: Keys.lastTrack),
              let id = UUID(uuidString: saved),
              let track = tracks.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: MusicStorage.fileURL(for: track).path) else { return }
        originalQueue = tracks.map { $0.id }
        queue = isShuffled ? shuffledQueue(startingWith: id, from: originalQueue) : originalQueue
        queueIndex = queue.firstIndex(of: id) ?? 0
        let position = defaults.double(forKey: Keys.lastPosition)
        let start = (track.duration > 0 && position < track.duration - 1) ? position : 0
        load(trackID: id, autoplay: false, startAt: start)   // восстанавливаем на паузе
    }

    // MARK: - Библиотека

    var recentTracks: [Track] {
        recentIDs.compactMap { id in tracks.first(where: { $0.id == id }) }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { id in tracks.first(where: { $0.id == id }) }
    }

    private func markRecent(_ id: UUID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 50 { recentIDs.removeLast(recentIDs.count - 50) }
        saveLibrary()
    }

    private func saveLibrary() {
        MusicStorage.save(LibrarySnapshot(tracks: tracks, playlists: playlists, recentIDs: recentIDs))
    }

    func deleteTrack(_ track: Track) {
        if currentTrack?.id == track.id { stopPlayback() }
        queue.removeAll { $0 == track.id }
        originalQueue.removeAll { $0 == track.id }
        queueIndex = currentTrack.flatMap { queue.firstIndex(of: $0.id) } ?? 0
        tracks.removeAll { $0.id == track.id }
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { $0 == track.id }
        }
        recentIDs.removeAll { $0 == track.id }
        try? FileManager.default.removeItem(at: MusicStorage.fileURL(for: track))
        if let artwork = track.artworkFile {
            try? FileManager.default.removeItem(at: MusicStorage.artworkURL(named: artwork))
            ArtworkCache.shared.remove(named: artwork)
        }
        saveLibrary()
    }

    @discardableResult
    func createPlaylist(name: String, trackIDs: [UUID] = []) -> Playlist {
        let playlist = Playlist(id: UUID(), name: name, trackIDs: trackIDs, createdAt: Date())
        playlists.append(playlist)
        saveLibrary()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        saveLibrary()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        saveLibrary()
    }

    func add(_ trackID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if playlists[index].trackIDs.contains(trackID) {
            statusMessage = "Этот трек уже в плейлисте"
            return
        }
        playlists[index].trackIDs.append(trackID)
        statusMessage = "Добавлено в «\(playlists[index].name)»"
        saveLibrary()
    }

    func remove(_ trackID: UUID, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        saveLibrary()
    }

    // MARK: - Импорт файлов с устройства

    private enum ImportResult {
        case added(Track)
        case duplicate
        case failed
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        let known = Set(tracks.map { "\($0.originalName)|\($0.fileSize)" })
        Task { [weak self] in
            var seen = known
            var added: [Track] = []
            var duplicates = 0
            var failures = 0
            for url in urls {
                let result = await MusicManager.importOne(url, known: seen)
                switch result {
                case .added(let track):
                    added.append(track)
                    seen.insert("\(track.originalName)|\(track.fileSize)")
                case .duplicate:
                    duplicates += 1
                case .failed:
                    failures += 1
                }
            }
            await MainActor.run {
                guard let self = self else { return }
                self.tracks.append(contentsOf: added)
                self.saveLibrary()
                self.isImporting = false
                var parts: [String] = []
                if !added.isEmpty { parts.append("Добавлено: \(added.count)") }
                if duplicates > 0 { parts.append("уже были: \(duplicates)") }
                if failures > 0 { parts.append("не удалось: \(failures)") }
                self.statusMessage = parts.joined(separator: ", ")
            }
        }
    }

    /// Мост из библиотеки файлов: файл уже скачан на устройство (во временный кэш), его нужно добавить
    /// в музыкальную коллекцию и сразу включить. Переиспользует ту же логику импорта, что и обычный выбор файлов.
    func importAndPlay(fileAt url: URL, suggestedName: String) {
        if let existing = tracks.first(where: { $0.originalName == url.lastPathComponent }) {
            play(existing, in: tracks)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let known = Set(self.tracks.map { "\($0.originalName)|\($0.fileSize)" })
            let result = await MusicManager.importOne(url, known: known)
            await MainActor.run {
                switch result {
                case .added(let track):
                    self.tracks.append(track)
                    self.saveLibrary()
                    self.play(track, in: self.tracks)
                case .duplicate:
                    if let existing = self.tracks.first(where: { $0.originalName == url.lastPathComponent }) {
                        self.play(existing, in: self.tracks)
                    } else {
                        self.statusMessage = "Трек уже есть в библиотеке"
                    }
                case .failed:
                    self.statusMessage = "Не удалось открыть «\(suggestedName)» как аудио"
                }
            }
        }
    }

    private static func importOne(_ url: URL, known: Set<String>) async -> ImportResult {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        let originalName = url.lastPathComponent
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if known.contains("\(originalName)|\(size)") { return .duplicate }

        let id = UUID()
        let ext = url.pathExtension.lowercased()
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destination = MusicStorage.filesDirectory.appendingPathComponent(fileName)

        // NSFileCoordinator нужен для файлов из iCloud Drive: он дожидается, пока файл скачается
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if coordinatorError != nil || copyError != nil {
            try? FileManager.default.removeItem(at: destination)
            return .failed
        }

        let info = await MusicMetadata.read(from: destination)
        guard info.playable else {
            try? FileManager.default.removeItem(at: destination)
            return .failed
        }

        var artworkFile: String?
        if let data = info.artworkData, let jpeg = MusicMetadata.jpegData(from: data) {
            let name = id.uuidString + ".jpg"
            if (try? jpeg.write(to: MusicStorage.artworkURL(named: name), options: .atomic)) != nil {
                artworkFile = name
            }
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let track = Track(id: id,
                          title: info.title ?? baseName,
                          artist: info.artist ?? "",
                          album: info.album ?? "",
                          duration: info.duration,
                          fileName: fileName,
                          artworkFile: artworkFile,
                          originalName: originalName,
                          fileSize: size,
                          addedAt: Date())
        return .added(track)
    }
}
