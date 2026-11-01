import SwiftUI

/// Полноэкранный плеер: обложка, название, перемотка и кнопки управления.
struct MusicPlayerView: View {
    @EnvironmentObject var music: MusicManager
    @Environment(\.dismiss) private var dismiss
    @State private var dragY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                AlbumArtwork(fileName: music.currentTrack?.artworkFile,
                             size: artworkSize(in: geo.size), cornerRadius: 14)
                    .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
                    .scaleEffect(music.isPlaying ? 1 : 0.88)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: music.isPlaying)
                Spacer(minLength: 20)
                titleBlock
                ProgressSection(clock: music.clock)
                    .padding(.top, 14)
                PlaybackControls()
                    .padding(.top, 10)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
        }
        .background(Theme.background.ignoresSafeArea())
        .offset(y: dragY)
        .onChange(of: music.currentTrack?.id) { id in
            if id == nil { dismiss() }   // трек удалили, пока плеер был открыт
        }
    }

    private func artworkSize(in size: CGSize) -> CGFloat {
        max(160, min(size.width - 56, size.height * 0.42))
    }

    private var header: some View {
        ZStack {
            Capsule()
                .fill(Theme.secondary.opacity(0.45))
                .frame(width: 38, height: 5)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                Spacer()
            }
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in dragY = max(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragY = 0 }
                    }
                }
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(music.currentTrack?.title ?? "")
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(2)
            Text(music.currentTrack?.displayArtist ?? "")
                .font(.system(size: 16))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ползунок и время вынесены отдельно: обновляются дважды в секунду, остальной экран не перерисовывается.
private struct ProgressSection: View {
    @EnvironmentObject var music: MusicManager
    @ObservedObject var clock: PlaybackClock
    @State private var dragTime: Double?

    var body: some View {
        let duration = max(clock.duration, 0.1)
        let shown = dragTime ?? min(clock.currentTime, duration)
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { dragTime = $0 }),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        music.beginScrubbing()
                    } else {
                        music.endScrubbing(at: dragTime ?? clock.currentTime)
                        dragTime = nil
                    }
                }
            )
            .tint(.primary)
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(duration - shown, 0)))
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.secondary)
        }
    }
}
