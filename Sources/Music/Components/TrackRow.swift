import SwiftUI

/// Строка трека: обложка, название, исполнитель, длительность и меню «…».
struct TrackRow: View {
    @EnvironmentObject var music: MusicManager

    let track: Track
    let context: [Track]                 // список, из которого играем (станет очередью)
    var playlist: Playlist? = nil        // если строка показана внутри плейлиста
    let onDelete: (Track) -> Void
    let onNewPlaylist: (Track) -> Void

    private var isCurrent: Bool { music.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 4) {
            Button { music.play(track, in: context) } label: {
                HStack(spacing: 12) {
                    AlbumArtwork(fileName: track.artworkFile, size: 48, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                            .lineLimit(1)
                        Text(track.displayArtist)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isCurrent {
                        Image(systemName: music.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(formatTime(track.duration))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }

            Menu {
                Menu("Добавить в плейлист") {
                    ForEach(music.playlists) { item in
                        Button(item.name) { music.add(track.id, to: item.id) }
                    }
                    Button("Новый плейлист…") { onNewPlaylist(track) }
                }
                if let playlist = playlist {
                    Button {
                        music.remove(track.id, from: playlist.id)
                    } label: {
                        Label("Убрать из плейлиста", systemImage: "minus.circle")
                    }
                }
                Button(role: .destructive) {
                    onDelete(track)
                } label: {
                    Label("Удалить из библиотеки", systemImage: "trash")
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
}
