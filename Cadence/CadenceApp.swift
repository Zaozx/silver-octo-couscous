import SwiftUI

@main
struct CadenceApp: App {
    @StateObject private var music = MusicStore()
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(music)
                .preferredColorScheme(.dark).tint(Theme.mint)
        }
    }
}
