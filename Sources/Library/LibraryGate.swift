import SwiftUI

/// Переключатель: показать экран входа или саму библиотеку, в зависимости от того, есть ли токен.
/// Отдельный тип, чтобы RootView не знал деталей авторизации библиотеки.
struct LibraryGate: View {
    @EnvironmentObject var auth: AuthSession
    let openDrawer: () -> Void

    var body: some View {
        if auth.isAuthenticated {
            LibraryView(openDrawer: openDrawer)
        } else {
            LibraryLoginView(openDrawer: openDrawer)
        }
    }
}
