import SwiftUI

@main
struct ChatApp: App {
    @StateObject private var messenger = MessengerStore()
    @StateObject private var router = AppRouter()
    @StateObject private var music = MusicManager()
    @StateObject private var auth = AuthSession.shared

    var body: some Scene {
        WindowGroup {
            AuthGate()
                .environmentObject(messenger)
                .environmentObject(router)
                .environmentObject(music)
                .environmentObject(auth)
                .sheet(isPresented: $auth.showSettings) {
                    SettingsView()
                }
        }
    }
}
