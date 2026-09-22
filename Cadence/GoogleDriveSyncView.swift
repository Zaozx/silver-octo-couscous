import SwiftUI
import GoogleSignInSwift

struct GoogleDriveSyncView: View {
    @EnvironmentObject private var drive: GoogleDriveSync
    @EnvironmentObject private var music: MusicStore
    @State private var editing = false
    @State private var folderInput = ""
    @State private var signingOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .font(.system(size: 40)).foregroundStyle(Theme.mint)
                Text("Your music, together.").font(.title2.bold())
                Text("Connect Google Drive to download songs from the folder you use on Windows. Your songs stay available offline after downloading.")
                    .foregroundStyle(Theme.muted)
                connection
                folder
                Text(drive.status).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                if drive.syncing || drive.connecting { ProgressView() }
                if let date = drive.lastSync {
                    Text("Last successful sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if !drive.details.isEmpty {
                    Text(drive.details).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                }
                if drive.connected {
                    Toggle("Check automatically while open", isOn: $drive.automatic)
                    Text("Checks every minute and when you return to Cadence. Downloads use phone storage and your current internet connection, including mobile data.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    if drive.syncing {
                        Button("Stop sync", role: .destructive) { drive.cancel() }
                    } else {
                        Button { drive.sync(music: music) } label: {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                            .disabled(drive.connecting || music.importing)
                    }
                }
                Text("Add songs to this folder using the Google Drive app or Drive for desktop. Cadence downloads new audio; it does not upload songs, sync playlists or delete files from Drive. Folder shortcuts are skipped—use the original folder link.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Google Drive")
            .alert("Music folder", isPresented: $editing) {
                TextField("Google Drive folder link", text: $folderInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") { drive.changeFolder(folderInput) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Paste the original folder link from Google Drive. Downloaded songs will remain in your library.") }
            .confirmationDialog("Sign out of Google Drive? Downloaded songs will remain.",
                isPresented: $signingOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { drive.disconnect() }
                Button("Cancel", role: .cancel) {}
            }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if drive.connected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                Text(drive.account).font(.subheadline).textSelection(.enabled)
                Button("Sign out") { signingOut = true }.disabled(drive.syncing || drive.connecting)
            } else {
                Text("Google asks for permission to view and download your Drive files. Cadence reads only the music folder you select and its subfolders.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                GoogleSignInButton(scheme: .light) {
                    Task { await drive.signIn() }
                }.frame(height: 48).disabled(drive.connecting || drive.syncing)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(drive.folderName, systemImage: "folder.fill").font(.headline)
            Text(drive.folderLink).font(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
            Button("Change folder link") { folderInput = drive.folderLink; editing = true }
                .disabled(drive.syncing || drive.connecting)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}
