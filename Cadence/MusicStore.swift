import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

struct Song: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var title: String
    var artist: String
    var liked = false
    // Optional so libraries from earlier versions still decode.
    var folderSource: String? = nil
}

struct Playlist: Identifiable, Codable {
    var id = UUID()
    var name: String
    var songs: [UUID] = []
}

private struct SavedLibrary: Codable {
    var songs: [Song]
    var playlists: [Playlist]
}

private struct LinkedMusicFolder: Codable {
    var id: UUID
    var name: String
    var bookmark: Data
}

final class MusicStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var songs: [Song] = []
    @Published var playlists: [Playlist] = []
    @Published var current: Song?
    @Published var playing = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode = 0
    @Published var importing = false
    @Published var importStatus = ""
    @Published var error: String?
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncing = false
    @Published private(set) var syncStatus = "Choose a folder to start."
    @Published private(set) var syncDetails = ""
    @Published private(set) var lastSync: Date?
    private var linkedFolder: LinkedMusicFolder?
    private var syncTimer: Timer?
    private var player: AVAudioPlayer?
    private var queue: [UUID] = []
    private var timer: Timer?
    private let folder: URL
    private let database: URL
    private let syncSettings: URL

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cadence", isDirectory: true)
        folder = support.appendingPathComponent("Music", isDirectory: true)
        database = support.appendingPathComponent("library.json")
        syncSettings = support.appendingPathComponent("linked-folder.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: database.path) {
                let saved = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: database))
                songs = saved.songs; playlists = saved.playlists
            }
        } catch { self.error = "Your library could not be loaded: \(error.localizedDescription)" }
        if FileManager.default.fileExists(atPath: syncSettings.path) {
            do {
                linkedFolder = try JSONDecoder().decode(LinkedMusicFolder.self, from: Data(contentsOf: syncSettings))
                syncFolderName = linkedFolder?.name
                syncStatus = "Ready to check for new songs."
            } catch { syncStatus = "Folder access could not be restored. Choose the folder again." }
        }
        // Direct Google Drive sync now owns foreground scheduling. Legacy
        // folder bookmarks stay saved but no longer start provider scans.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = self.player?.currentTime ?? 0
        }
        configureRemoteControls()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit { timer?.invalidate(); syncTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    @discardableResult private func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(SavedLibrary(songs: songs, playlists: playlists))
            try data.write(to: database, options: .atomic)
            return true
        } catch { self.error = "Your changes could not be saved: \(error.localizedDescription)"; return false }
    }

    @MainActor func beginDriveImport() -> Bool {
        guard !importing && !syncing else { return false }
        importing = true; importStatus = "Syncing Google Drive…"
        return true
    }

    @MainActor func endDriveImport(added: Int) {
        importing = false
        importStatus = "Google Drive: added \(added) song(s)."
    }

    @MainActor func hasDriveFile(_ id: String) -> Bool {
        songs.contains { $0.folderSource == "gdrive:" + id }
    }

    @MainActor func addDriveFile(_ local: URL, name: String, id: String) async throws {
        let destinationFolder = folder
        let song = try await Task.detached(priority: .utility) {
            let songID = UUID()
            let filename = songID.uuidString + "." + (name as NSString).pathExtension
            let destination = destinationFolder.appendingPathComponent(filename)
            do {
                try FileManager.default.copyItem(at: local, to: destination)
                _ = try AVAudioPlayer(contentsOf: destination)
                let stem = (name as NSString).deletingPathExtension
                let parts = stem.components(separatedBy: " - ")
                return Song(id: songID, filename: filename,
                    title: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : stem,
                    artist: parts.count > 1 ? parts[0] : "Google Drive", folderSource: "gdrive:" + id)
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
        }.value
        do {
            try Task.checkCancellation()
            songs.append(song)
            guard save() else {
                songs.removeAll { $0.id == song.id }
                throw DriveSyncError.message("The downloaded song could not be saved to your library. Check free storage and retry.")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(song.filename))
            throw error
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !importing && !syncing else {
            error = "A song is still being imported. Wait for it to finish, then share the next file."
            return
        }
        guard !urls.isEmpty else {
            error = "No file was received from Files. Download the song in Files, then select it again."
            return
        }
        importing = true
        importStatus = "Preparing \(urls.count) selected file(s)…"
        let destinationFolder = folder
        // Hold document-provider access while copying on a background queue.
        let access = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var imported: [Song] = []
            var failures: [String] = []
            for (index, item) in access.enumerated() {
                let (url, scoped) = item
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                DispatchQueue.main.async { [weak self] in
                    self?.importStatus = "Adding \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                }
                let id = UUID()
                let name = id.uuidString + "." + url.pathExtension
                let destination = destinationFolder.appendingPathComponent(name)
                do {
                    // The document picker supplies a local copy. Do not start a
                    // second provider coordination operation after it dismisses.
                    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    if (attributes[.size] as? NSNumber)?.int64Value == 0 {
                        throw NSError(domain: "CadenceImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected file is empty. Download it fully in Files and try again."])
                    }
                    // Reject unsupported or corrupt audio before adding it to the library.
                    _ = try AVAudioPlayer(contentsOf: destination)
                    let stem = url.deletingPathExtension().lastPathComponent
                    let parts = stem.components(separatedBy: " - ")
                    imported.append(Song(id: id, filename: name,
                        title: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : stem,
                        artist: parts.count > 1 ? parts[0] : "Local music"))
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    let details = error as NSError
                    failures.append("\(url.lastPathComponent): \(details.localizedDescription) [\(details.domain) \(details.code)]")
                }
            }
            let results = imported
            let failed = failures
            DispatchQueue.main.async {
                guard let self else { return }
                self.songs.append(contentsOf: results)
                self.save(); self.importing = false
                self.importStatus = results.isEmpty ? "No songs were added." : "Added \(results.count) \(results.count == 1 ? "song" : "songs"). Tap a song below to play."
                if !failed.isEmpty {
                    self.error = "Could not import:\n\n" + failed.joined(separator: "\n\n") + "\n\nTry opening the file in the Files app first. Use a fully downloaded MP3, M4A, or WAV file."
                }
            }
        }
    }

    func linkSyncFolder(_ url: URL) {
        guard !syncing && !importing else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Retain the source identity when reconnecting the same folder.
            var id = UUID()
            if let previous = linkedFolder {
                var stale = false
                if let oldURL = try? URL(resolvingBookmarkData: previous.bookmark,
                    options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
                   oldURL.standardizedFileURL == url.standardizedFileURL { id = previous.id }
            }
            let link = LinkedMusicFolder(id: id, name: url.lastPathComponent,
                bookmark: try url.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: nil, relativeTo: nil))
            try JSONEncoder().encode(link).write(to: syncSettings, options: .atomic)
            linkedFolder = link; syncFolderName = link.name; lastSync = nil
            syncFolder()
        } catch {
            self.error = "This provider could not grant folder access: \(error.localizedDescription)"
        }
    }

    func unlinkSyncFolder() {
        guard !syncing else { return }
        do {
            if FileManager.default.fileExists(atPath: syncSettings.path) {
                try FileManager.default.removeItem(at: syncSettings)
            }
            linkedFolder = nil; syncFolderName = nil; lastSync = nil
            syncStatus = "Folder unlinked. Your downloaded songs are still in Library."
            syncDetails = ""
        } catch { self.error = "Could not unlink the folder: \(error.localizedDescription)" }
    }

    func syncFolder() {
        guard let link = linkedFolder, !syncing, !importing else { return }
        syncing = true; syncStatus = "Checking \(link.name)…"; syncDetails = ""
        let destinationFolder = folder
        let known = Set(songs.compactMap(\.folderSource))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var imported: [Song] = []
            var failures: [String] = []
            var refreshedLink = link
            var scanCompleted = false
            do {
                var stale = false
                let root = try URL(resolvingBookmarkData: link.bookmark, options: .withoutUI,
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                if stale {
                    refreshedLink.bookmark = try root.bookmarkData(options: .minimalBookmark,
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                // File providers must finish materializing data before it is copied.
                let files = try Self.audioFiles(in: root)
                for file in files {
                    let url = file.url
                    let source = link.id.uuidString + ":" + file.relative
                    if known.contains(source) { continue }
                    DispatchQueue.main.async { [weak self] in
                        self?.syncStatus = "Downloading \(url.lastPathComponent)…"
                    }
                    let id = UUID()
                    let name = id.uuidString + "." + url.pathExtension
                    let destination = destinationFolder.appendingPathComponent(name)
                    do {
                        try Self.coordinatedCopy(from: url, to: destination)
                        _ = try AVAudioPlayer(contentsOf: destination)
                        let stem = url.deletingPathExtension().lastPathComponent
                        let parts = stem.components(separatedBy: " - ")
                        imported.append(Song(id: id, filename: name,
                            title: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : stem,
                            artist: parts.count > 1 ? parts[0] : "Local music", folderSource: source))
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                scanCompleted = true
            } catch {
                failures.append("Folder unavailable: \(error.localizedDescription). Check Files, your connection, or choose the folder again.")
            }
            let results = imported
            let issues = failures
            let renewed = refreshedLink
            let completed = scanCompleted
            DispatchQueue.main.async {
                guard let self else { return }
                self.songs.append(contentsOf: results)
                if !results.isEmpty { self.save() }
                if renewed.bookmark != link.bookmark {
                    do {
                        try JSONEncoder().encode(renewed).write(to: self.syncSettings, options: .atomic)
                        self.linkedFolder = renewed
                    } catch { self.error = "Folder access could not be saved. Choose it again next time." }
                }
                self.syncing = false
                if completed && issues.isEmpty { self.lastSync = Date() }
                self.syncStatus = issues.isEmpty
                    ? (results.isEmpty ? "Up to date. No new songs." : "Added \(results.count) song(s). Ready in Library.")
                    : "Added \(results.count) song(s). \(issues.count) item(s) need attention."
                self.syncDetails = issues.prefix(8).joined(separator: "\n\n")
            }
        }
    }

    private static func audioFiles(in root: URL) throws -> [(url: URL, relative: String)] {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var readError: Error?
        var files: [(url: URL, relative: String)] = []
        coordinator.coordinate(readingItemAt: root, options: [], error: &coordinationError) { directory in
            do {
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw NSError(domain: "CadenceSync", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Choose a music folder, not a file."])
                }
                let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"]
                guard let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in readError = error; return false }) else {
                    throw NSError(domain: "CadenceSync", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The provider could not list this folder."])
                }
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true && extensions.contains(url.pathExtension.lowercased()) {
                        let prefix = directory.standardizedFileURL.path + "/"
                        guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
                        files.append((url, String(url.standardizedFileURL.path.dropFirst(prefix.count))))
                    }
                }
            } catch { readError = error }
        }
        if let error = coordinationError { throw error }
        if let error = readError { throw error }
        return files.sorted { $0.relative < $1.relative }
    }

    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) }
            catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
    }

    func play(_ song: Song, in list: [Song]? = nil) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let nextPlayer = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(song.filename))
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            player?.stop(); player = nextPlayer
            if let list { queue = list.map(\.id) }
            if queue.isEmpty { queue = [song.id] }
            current = song; duration = nextPlayer.duration; elapsed = 0
            playing = nextPlayer.play()
            updateNowPlaying()
        } catch { self.error = "This song could not be played: \(error.localizedDescription)" }
    }

    func togglePlay() { playing ? pause() : resume() }
    func pause() { player?.pause(); playing = false; updateNowPlaying() }
    func resume() {
        guard let player else { if let first = songs.first { play(first, in: songs) }; return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            playing = player.play(); updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ value: Double) {
        player?.currentTime = min(max(value, 0), duration)
        elapsed = player?.currentTime ?? 0; updateNowPlaying()
    }
    func next(automatically: Bool = false) {
        let available = queue.compactMap { id in songs.first { $0.id == id } }
        guard !available.isEmpty else { return }
        if automatically && repeatMode == 2 { seek(0); resume(); return }
        if shuffle, let random = available.filter({ $0.id != current?.id }).randomElement() {
            play(random); return
        }
        let index = (available.firstIndex { $0.id == current?.id } ?? -1) + 1
        if index >= available.count && automatically && repeatMode == 0 { pause(); seek(0); return }
        play(available[index % available.count])
    }
    func previous() {
        if elapsed > 3 { seek(0); return }
        let available = queue.compactMap { id in songs.first { $0.id == id } }
        guard !available.isEmpty else { return }
        let index = available.firstIndex { $0.id == current?.id } ?? 0
        play(available[(index - 1 + available.count) % available.count])
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { next(automatically: true) } else { pause(); error = "Playback stopped unexpectedly." }
    }
    func toggleLike(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        songs[index].liked.toggle()
        if current?.id == song.id { current = songs[index] }
        save()
    }
    func createPlaylist(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        playlists.append(Playlist(name: cleaned)); save()
    }
    func add(_ song: Song, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
            !playlists[index].songs.contains(song.id) else { return }
        playlists[index].songs.append(song.id); save()
    }
    func remove(_ song: Song, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].songs.removeAll { $0 == song.id }; save()
    }
    func deletePlaylist(_ playlist: Playlist) { playlists.removeAll { $0.id == playlist.id }; save() }
    func deleteSong(_ song: Song) {
        if current?.id == song.id { pause(); player = nil; current = nil; duration = 0; elapsed = 0 }
        songs.removeAll { $0.id == song.id }; queue.removeAll { $0 == song.id }
        for index in playlists.indices { playlists[index].songs.removeAll { $0 == song.id } }
        save()
        do { try FileManager.default.removeItem(at: folder.appendingPathComponent(song.filename)) }
        catch { self.error = "Removed from your library, but its imported copy could not be deleted." }
        updateNowPlaying()
    }
    private func updateNowPlaying() {
        guard let current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        if let image = UIImage(named: "BrandMark") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func configureRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.togglePlay() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            DispatchQueue.main.async { self?.seek(position) }; return .success
        }
    }
    @objc private func interrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        if type == .began { pause() }
        // Resume explicitly after interruptions so music does not restart unexpectedly.
    }
    @objc private func routeChanged(_ notification: Notification) {
        if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
    }
}
