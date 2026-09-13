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
    private var player: AVAudioPlayer?
    private var queue: [UUID] = []
    private var timer: Timer?
    private let folder: URL
    private let database: URL

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cadence", isDirectory: true)
        folder = support.appendingPathComponent("Music", isDirectory: true)
        database = support.appendingPathComponent("library.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: database.path) {
                let saved = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: database))
                songs = saved.songs; playlists = saved.playlists
            }
        } catch { self.error = "Your library could not be loaded: \(error.localizedDescription)" }
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

    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private func save() {
        do {
            let data = try JSONEncoder().encode(SavedLibrary(songs: songs, playlists: playlists))
            try data.write(to: database, options: .atomic)
        } catch { self.error = "Your changes could not be saved: \(error.localizedDescription)" }
    }

    func importFiles(_ urls: [URL]) {
        guard !importing else {
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
