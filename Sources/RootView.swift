import SwiftUI
import UIKit

/// Корневой экран: чат или музыка + выезжающий сайдбар (карточка сдвигается вправо, углы скругляются).
struct RootView: View {
    @EnvironmentObject var router: AppRouter
    @State private var drawerOpen = false
    @GestureState private var dragX: CGFloat = 0

    // Без отскока: плавно «садится» на место.
    private let spring = Animation.spring(response: 0.34, dampingFraction: 1.0)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 0.79
            let base: CGFloat = drawerOpen ? width : 0
            let offset = min(max(base + dragX, 0), width)
            let progress = width > 0 ? offset / width : 0

            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()

                SidebarView(close: { setDrawer(false) })
                    .frame(width: width, alignment: .leading)
                    .offset(x: -24 * (1 - progress))

                // Оба экрана всегда «живые», показывается один: так чат не теряет введённый текст и историю.
                ZStack {
                    ChatScreen(openDrawer: { setDrawer(true) })
                        .opacity(router.section == .chat ? 1 : 0)
                        .allowsHitTesting(router.section == .chat)
                        .accessibilityHidden(router.section != .chat)
                    MusicView(openDrawer: { setDrawer(true) })
                        .opacity(router.section == .music ? 1 : 0)
                        .allowsHitTesting(router.section == .music)
                        .accessibilityHidden(router.section != .music)
                    LibraryView(openDrawer: { setDrawer(true) })
                        .opacity(router.section == .library ? 1 : 0)
                        .allowsHitTesting(router.section == .library)
                        .accessibilityHidden(router.section != .library)
                }
                .animation(.easeInOut(duration: 0.18), value: router.section)
                .frame(width: geo.size.width)
                .background(
                    RoundedRectangle(cornerRadius: 48 * progress, style: .continuous)
                        .fill(Theme.background)
                        .shadow(color: .black.opacity(0.12 * progress), radius: 16)
                        .ignoresSafeArea()
                )
                .offset(x: offset)

                if drawerOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width)
                        .offset(x: offset)
                        .ignoresSafeArea()
                        .onTapGesture { setDrawer(false) }
                }
            }
            .gesture(drag(width: width))
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragX) { value, state, _ in
                if abs(value.translation.width) > abs(value.translation.height) {
                    state = value.translation.width
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start: CGFloat = drawerOpen ? width : 0
                setDrawer(start + value.predictedEndTranslation.width > width / 2)
            }
    }

    private func setDrawer(_ open: Bool) {
        if open {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
        if open != drawerOpen {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        withAnimation(spring) { drawerOpen = open }
    }
}
