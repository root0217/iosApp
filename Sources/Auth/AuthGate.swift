import SwiftUI

/// Вход в приложение целиком завязан на один аккаунт Chapa — без него нет ни мессенджера
/// (это и есть личность собеседника), ни библиотеки. Поэтому шлюз один, на самом верху,
/// а не отдельно для каждого раздела.
struct AuthGate: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var messenger: MessengerStore
    @State private var didBootstrap = false

    var body: some View {
        Group {
            if auth.isAuthenticated {
                RootView()
            } else {
                AuthFlowView()
            }
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await auth.bootstrap()
        }
        .onChange(of: auth.me?.id) { id in
            if let id = id {
                Task { await messenger.start(myUserID: id) }
            } else {
                messenger.stop()
            }
        }
    }
}
