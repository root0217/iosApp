import SwiftUI

/// Компактный плеер над нижним краем музыкального экрана. Нажатие открывает полноэкранный плеер.
struct MiniPlayerView: View {
    @EnvironmentObject var music: MusicManager
    @ObservedObject var clock: PlaybackClock
    let onOpen: () -> Void

    var body: some View {
        if let track = music.currentTrack {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: onOpen) {
                        HStack(spacing: 10) {
                            AlbumArtwork(fileName: track.artworkFile, size: 40, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                Text(track.displayArtist)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    Button { music.togglePlayPause() } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .frame(width: 42, height: 42)
                    }
                    Button { music.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16))
                            .frame(width: 42, height: 42)
                    }
                }
                progressBar
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = clock.duration > 0 ? min(max(clock.currentTime / clock.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.secondary.opacity(0.25))
                Capsule().fill(Color.primary.opacity(0.75))
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 2.5)
        .padding(.horizontal, 2)
    }
}
