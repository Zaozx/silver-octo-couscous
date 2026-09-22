import SwiftUI
import UniformTypeIdentifiers
import MediaPlayer
import AVKit
import SafariServices

enum Theme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.05)
    static let surface = Color(red: 0.10, green: 0.15, blue: 0.12)
    static let mint = Color(red: 0.53, green: 0.93, blue: 0.67)
    static let muted = Color(red: 0.61, green: 0.69, blue: 0.63)
}

struct LibraryView: View {
    @EnvironmentObject private var music: MusicStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var importPresented = false
    @State private var nowPresented = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CollectionView(title: "Your library", likedOnly: false, importMusic: { importPresented = true })
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("Library", systemImage: "square.stack.fill") }.tag(0)
            NavigationStack {
                SpotifySearchView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(3)
            NavigationStack {
                CollectionView(title: "Liked songs", likedOnly: true, importMusic: { importPresented = true })
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("Liked", systemImage: "heart.fill") }.tag(1)
            NavigationStack {
                PlaylistsView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("Playlists", systemImage: "music.note.list") }.tag(2)
            NavigationStack {
                FolderSyncView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(4)
        }
        .onAppear { music.syncFolder() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { music.syncFolder() }
        }
        .toolbarBackground(Theme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onOpenURL { url in
            guard url.isFileURL else {
                music.error = "Share an audio file from Files, not a website link."
                return
            }
            selectedTab = 0
            importPresented = false
            nowPresented = false
            music.importFiles([url])
        }
        .sheet(isPresented: $importPresented) {
            AudioImportPicker { urls in
                selectedTab = 0
                music.importFiles(urls)
                importPresented = false
            } onCancel: {
                importPresented = false
            }
        }
        .sheet(isPresented: $nowPresented) { NowPlayingView().presentationDragIndicator(.visible) }
        .alert("Cadence", isPresented: Binding(get: { music.error != nil }, set: { if !$0 { music.error = nil } })) {
            Button("OK", role: .cancel) { music.error = nil }
        } message: { Text(music.error ?? "") }
    }

    @ViewBuilder private var miniPlayer: some View {
        if let current = music.current {
            HStack(spacing: 12) {
                Button { nowPresented = true } label: {
                    HStack(spacing: 12) {
                        CoverArt(seed: current.id).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(current.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Now playing: \(current.title)")
                Button { music.togglePlay() } label: {
                    Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(music.playing ? "Pause" : "Play")
                Button { music.next() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 36, height: 44)
                }.accessibilityLabel("Next song")
            }
            .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.background)
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject private var music: MusicStore
    let title: String
    var likedOnly = false
    var playlistID: UUID? = nil
    var importMusic: (() -> Void)? = nil
    @State private var search = ""
    private var playlist: Playlist? { music.playlists.first { $0.id == playlistID } }
    private var visible: [Song] {
        music.songs.filter { song in
            (!likedOnly || song.liked) && (playlistID == nil || playlist?.songs.contains(song.id) == true) &&
            (search.isEmpty || (song.title + " " + song.artist).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !likedOnly && playlistID == nil && search.isEmpty { welcome }
                HStack {
                    Text("\(visible.count) \(visible.count == 1 ? "song" : "songs")").foregroundStyle(Theme.muted)
                    Spacer()
                    if !visible.isEmpty {
                        Button {
                            music.shuffle = true
                            if let first = visible.randomElement() { music.play(first, in: visible) }
                        } label: { Label("Shuffle", systemImage: "shuffle").font(.subheadline.weight(.semibold)) }
                    }
                }
                if music.importing {
                    ProgressView(music.importStatus).padding(.vertical)
                } else if !music.importStatus.isEmpty && !likedOnly && playlistID == nil {
                    Text(music.importStatus).font(.subheadline).foregroundStyle(Theme.mint)
                }
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "Make room for your music" : "No matching songs", systemImage: likedOnly ? "heart" : "music.note")
                    } description: {
                        Text(search.isEmpty ? (likedOnly ? "Like a song from your library to find it here." : playlistID != nil ? "Use a song’s menu in your library to add it here." : "Add MP3, M4A, or WAV files from the Files app.") : "Try a different title or artist.")
                    } actions: {
                        if !likedOnly && playlistID == nil, let importMusic {
                            Button("Add music", action: importMusic).buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(music.importing)
                        }
                    }
                } else {
                    ForEach(visible) { song in SongRow(song: song, queue: visible, playlist: playlist) }
                }
            }.padding(20)
        }
        .background(Theme.background).navigationTitle(title)
        .searchable(text: $search, prompt: "Songs or artists")
        .onChange(of: music.songs.count) { old, new in if new > old { search = "" } }
        .toolbar {
            if let importMusic {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: importMusic) { Image(systemName: "plus").frame(width: 32, height: 32) }
                        .accessibilityLabel("Add music from Files").disabled(music.importing)
                }
            }
        }
    }
    private var welcome: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("CADENCE").font(.caption.weight(.bold)).tracking(2).foregroundStyle(Theme.mint)
                Text("Version 1.2.0").font(.caption).foregroundStyle(Theme.muted)
                Text("Stay for\nthe music.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let first = music.songs.first {
                    Button { music.play(first, in: music.songs) } label: { Label("Press play", systemImage: "play.fill").font(.subheadline.bold()) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                } else { Text("Your collection, wherever you go.").font(.subheadline).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 0)
            Image("BrandMark").resizable().scaledToFit().frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 22))
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 0.15, green: 0.31, blue: 0.22), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct SongRow: View {
    @EnvironmentObject private var music: MusicStore
    let song: Song
    let queue: [Song]
    var playlist: Playlist? = nil
    @State private var deletePresented = false
    var body: some View {
        HStack(spacing: 12) {
            Button { music.play(song, in: queue) } label: {
                HStack(spacing: 12) {
                    CoverArt(seed: song.id).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(music.current?.id == song.id ? Theme.mint : .white).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if song.liked { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.mint).accessibilityLabel("Liked") }
            Menu {
                Button { music.toggleLike(song) } label: { Label(song.liked ? "Unlike" : "Like song", systemImage: song.liked ? "heart.slash" : "heart") }
                Menu("Add to playlist") {
                    if music.playlists.isEmpty { Text("Create a playlist in the Playlists tab") }
                    ForEach(music.playlists) { list in Button(list.name) { music.add(song, to: list) } }
                }
                if let playlist { Button("Remove from playlist", role: .destructive) { music.remove(song, from: playlist) } }
                Button("Remove from library", role: .destructive) { deletePresented = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 40, height: 44) }
            .accessibilityLabel("Options for \(song.title)")
        }
        .alert("Remove this song?", isPresented: $deletePresented) {
            Button("Remove", role: .destructive) { music.deleteSong(song) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The imported copy and its playlist entries will be removed. The original file in Files stays where it is.") }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var music: MusicStore
    @State private var creating = false
    @State private var name = ""
    @State private var deleting: Playlist?
    var body: some View {
        List {
            if music.playlists.isEmpty {
                ContentUnavailableView("A mix for every mood", systemImage: "music.note.list", description: Text("Create a playlist, then add songs from your library."))
                    .listRowBackground(Color.clear)
            }
            ForEach(music.playlists) { playlist in
                NavigationLink {
                    CollectionView(title: playlist.name, playlistID: playlist.id)
                } label: {
                    HStack(spacing: 14) {
                        CoverArt(seed: playlist.id).frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.songs.count) songs").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 7)
                    }
                }.listRowBackground(Theme.surface)
                .swipeActions { Button("Delete", role: .destructive) { deleting = playlist } }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Your playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { name = ""; creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create playlist") }
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Playlist name", text: $name)
            Button("Create") { music.createPlaylist(name) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete playlist?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { music.deletePlaylist(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Your music will stay in your library.") }
    }
}

struct CoverArt: View {
    let seed: UUID
    private var color: Color {
        let colors: [Color] = [.teal, .purple, .orange, .green, .pink, .blue]
        return colors[Int(seed.uuid.0) % colors.count]
    }
    var body: some View {
        GeometryReader { size in
            ZStack {
                LinearGradient(colors: [color.opacity(0.8), color.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(.white.opacity(0.16), lineWidth: 1).padding(size.size.width * 0.15)
                Circle().stroke(.white.opacity(0.10), lineWidth: 1).padding(size.size.width * 0.25)
                Image(systemName: "waveform").font(.system(size: size.size.width * 0.36, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }.clipShape(RoundedRectangle(cornerRadius: size.size.width * 0.18))
        }.accessibilityHidden(true)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var music: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var position = 0.0
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Close player")
                    Spacer()
                    Text("NOW PLAYING").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.muted)
                    Spacer()
                    AirPlayPicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay output")
                }
                if let song = music.current {
                    CoverArt(seed: song.id).aspectRatio(1, contentMode: .fit).frame(maxWidth: 380)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(song.title).font(.title2.bold())
                            Text(song.artist).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button { music.toggleLike(song) } label: { Image(systemName: song.liked ? "heart.fill" : "heart").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel(song.liked ? "Unlike song" : "Like song")
                    }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { scrubbing ? position : min(music.elapsed, max(music.duration, 1)) }, set: { position = $0 }), in: 0...max(music.duration, 1), onEditingChanged: { editing in
                            if editing { position = music.elapsed }
                            scrubbing = editing
                            if !editing { music.seek(position) }
                        }).accessibilityLabel("Playback position")
                        HStack {
                            Text(time(scrubbing ? position : music.elapsed)); Spacer(); Text(time(music.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Button { music.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(music.shuffle ? Theme.mint : Theme.muted).frame(width: 44, height: 44) }.accessibilityLabel(music.shuffle ? "Shuffle on" : "Shuffle off")
                        Spacer()
                        Button { music.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("Previous song")
                        Spacer()
                        Button { music.togglePlay() } label: { Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.title).foregroundStyle(Theme.background).frame(width: 72, height: 72).background(Theme.mint, in: Circle()) }.accessibilityLabel(music.playing ? "Pause" : "Play")
                        Spacer()
                        Button { music.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("Next song")
                        Spacer()
                        Button { music.repeatMode = (music.repeatMode + 1) % 3 } label: { Image(systemName: music.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(music.repeatMode == 0 ? Theme.muted : Theme.mint).frame(width: 44, height: 44) }.accessibilityLabel(["Repeat off", "Repeat queue", "Repeat song"][music.repeatMode])
                    }.foregroundStyle(.white)
                    Text("Use your iPhone’s volume buttons to adjust the sound.").font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                } else { ContentUnavailableView("Nothing playing", systemImage: "music.note") }
            }.padding(24).frame(maxWidth: 500).frame(maxWidth: .infinity)
        }.background(Theme.background)
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(value.isFinite ? value : 0, 0))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(Theme.muted)
        picker.activeTintColor = UIColor(Theme.mint)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// Import a copy rather than opening a document-provider URL in place.
// iOS completes the provider handoff before delivering the selected URLs.
struct FolderSyncView: View {
    @EnvironmentObject private var music: MusicStore
    @State private var choosing = false
    @State private var unlinking = false
    private var busy: Bool { music.syncing || music.importing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "folder.badge.arrow.down")
                    .font(.system(size: 40)).foregroundStyle(Theme.mint)
                Text("Your folder. Your music.").font(.title2.bold())
                Text("Link a folder in Files. Cadence downloads new songs into your library so you can listen offline.")
                    .foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 14) {
                    Label(music.syncFolderName ?? "No folder linked", systemImage: "folder.fill")
                        .font(.headline)
                    if music.syncing { ProgressView(music.syncStatus) }
                    else { Text(music.syncStatus).font(.subheadline) }
                    if let date = music.lastSync {
                        Text("Last successful check: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Button { choosing = true } label: {
                        Label(music.syncFolderName == nil ? "Choose music folder" : "Change folder",
                              systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(busy)
                    if music.syncFolderName != nil {
                        Button { music.syncFolder() } label: {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(busy)
                        Button("Unlink folder", role: .destructive) { unlinking = true }.disabled(busy)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                if !music.syncDetails.isEmpty {
                    Text(music.syncDetails).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Using Google Drive").font(.headline)
                    Text("Sign into the Drive app, enable it in Files → Browse → … → Edit, then try choosing your music folder above.")
                    Text("If Drive is greyed out or will not let you select a folder, its Files integration does not support this feature. Direct Google account sync is not configured in this build. You can use a selectable iCloud Drive folder, or import individual Drive files with + in Library.")
                    Link("Open your Google Drive folder", destination: URL(string: "https://drive.google.com/drive/folders/1OLRkulk0ASY2j0S0Id9PL2VgeJMnsfPa")!)
                }.font(.subheadline).foregroundStyle(Theme.muted)
                Text("Checks when Cadence opens and every minute while it is in the foreground. Cloud downloads use data and phone storage. Upload songs through your cloud provider’s app; Cadence only imports new files. Likes and playlists stay on this device.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Folder sync")
            .sheet(isPresented: $choosing) {
                MusicFolderPicker { url in
                    choosing = false
                    music.linkSyncFolder(url)
                } onCancel: { choosing = false }
            }
            .confirmationDialog("Unlink this folder? Downloaded songs will stay in Cadence.",
                isPresented: $unlinking, titleVisibility: .visible) {
                Button("Unlink folder", role: .destructive) { music.unlinkSyncFolder() }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct MusicFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

struct AudioImportPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

// Spotify's public website supplies the actual results. Cadence does not
// scrape the catalog, embed API secrets, or claim to download Spotify audio.
private struct SpotifySearchPage: Identifiable {
    let id = UUID()
    let url: URL
}

struct SpotifySearchView: View {
    @State private var query = ""
    @State private var page: SpotifySearchPage?
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL
    @State private var launchError = false

    private var searchURL: URL? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: "https://open.spotify.com/search/" + encoded)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Find your next song.").font(.title2.bold())
                    Text("Search songs, artists, or albums on Spotify.")
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Song, artist, or album", text: $query)
                        .focused($focused).submitLabel(.search)
                        .autocorrectionDisabled().onSubmit(search)
                        .accessibilityLabel("Spotify search")
                    if !query.isEmpty {
                        Button { query = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 36, height: 44)
                        }.accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                Button(action: search) {
                    Label("Search Spotify", systemImage: "magnifyingglass")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                    .disabled(searchURL == nil)
                Text("Results open on Spotify’s website in a browser inside Cadence. Spotify may ask you to sign in. Audio is not downloaded into your library.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Button {
                    guard let url = searchURL else { return }
                    focused = false
                    openURL(url) { accepted in if !accepted { launchError = true } }
                } label: { Label("Open search outside Cadence", systemImage: "arrow.up.right.square") }
                    .disabled(searchURL == nil)
                Text("Your imported songs are still available in the Library tab.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Search")
            .sheet(item: $page) { target in SpotifyBrowser(url: target.url).ignoresSafeArea() }
            .alert("Could not open Spotify", isPresented: $launchError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Check your connection and try Search Spotify again.") }
    }

    private func search() {
        guard let url = searchURL else { return }
        focused = false
        page = SpotifySearchPage(url: url)
    }
}

struct SpotifyBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.preferredControlTintColor = UIColor(Theme.mint)
        browser.preferredBarTintColor = UIColor(Theme.background)
        browser.dismissButtonStyle = .done
        return browser
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
