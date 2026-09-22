import SwiftUI

@main
struct CadenceApp: App {
    @StateObject private var music = MusicStore()
    @StateObject private var drive = GoogleDriveSync()
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(music).environmentObject(drive)
                .preferredColorScheme(.dark).tint(Theme.mint)
        }
    }
}
