import SwiftUI

/// Нижний ряд кнопок плеера: перемешать, назад, пауза/играть, вперёд, повтор.
struct PlaybackControls: View {
    @EnvironmentObject var music: MusicManager

    var body: some View {
        HStack(spacing: 0) {
            Button { music.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(music.isShuffled ? Theme.accent : Color.primary)
                    .frame(width: 48, height: 48)
            }
            Spacer()
            Button { music.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }
            Spacer()
            Button { music.togglePlayPause() } label: {
                Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .frame(width: 76, height: 76)
            }
            Spacer()
            Button { music.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }
            Spacer()
            Button { music.cycleRepeat() } label: {
                Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(music.repeatMode == .off ? Color.primary : Theme.accent)
                    .frame(width: 48, height: 48)
            }
        }
        .buttonStyle(PressableStyle())
    }
}
