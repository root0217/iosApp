import SwiftUI

@main
struct ChatApp: App {
    @StateObject private var store = ChatStore()
    @StateObject private var router = AppRouter()
    @StateObject private var music = MusicManager()
    @StateObject private var auth = AuthSession.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(music)
                .environmentObject(auth)
                .sheet(isPresented: $auth.showSettings) {
                    SettingsView()
                }
        }
    }
}
