import Foundation
import Combine
import UIKit
import GoogleSignIn

@MainActor
final class GoogleDriveSync: ObservableObject {
    static let scope = "https://www.googleapis.com/auth/drive.readonly"
    static let defaultFolder = "https://drive.google.com/drive/folders/1OLRkulk0ASY2j0S0Id9PL2VgeJMnsfPa"
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var syncing = false
    @Published private(set) var account = ""
    @Published private(set) var status = "Sign in to connect your music folder."
    @Published private(set) var details = ""
    @Published private(set) var folderLink: String
    @Published private(set) var folderName = "Your music folder"
    @Published private(set) var lastSync: Date?
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "driveAutomatic") }
    }
    private var restored = false
    private var work: Task<Void, Never>?
    private let session: URLSession

    init() {
        folderLink = UserDefaults.standard.string(forKey: "driveFolderLink") ?? Self.defaultFolder
        automatic = UserDefaults.standard.bool(forKey: "driveAutomatic")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        connecting = true
        defer { connecting = false }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            accept(user)
        } catch { status = "Sign in again to reconnect Google Drive." }
    }

    func signIn() async {
        guard !connecting && !syncing else { return }
        guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else {
            status = "Could not open sign-in. Try again."; return
        }
        while let next = presenter.presentedViewController { presenter = next }
        connecting = true; details = ""
        defer { connecting = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter,
                hint: nil, additionalScopes: [Self.scope])
            accept(result.user)
        } catch {
            status = "Google sign-in did not finish."
            details = "\(error.localizedDescription)\n\nIf access is blocked, add your email under Google Auth Platform → Audience → Test users."
        }
    }

    private func accept(_ user: GIDGoogleUser) {
        connected = user.grantedScopes?.contains(Self.scope) == true
        account = user.profile?.email ?? "Google account"
        status = connected ? "Connected. Tap Sync now to download your music." : "Drive read access was not granted. Sign in again and allow it."
    }

    func disconnect() {
        guard !syncing && !connecting else { return }
        GIDSignIn.sharedInstance.signOut()
        connected = false; account = ""; automatic = false; lastSync = nil
        status = "Signed out. Downloaded songs remain in Library."; details = ""
    }

    func changeFolder(_ input: String) {
        guard !syncing else { return }
        do {
            _ = try DriveFolderReference(input)
            folderLink = input.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(folderLink, forKey: "driveFolderLink")
            folderName = "Your music folder"; lastSync = nil
            status = "Folder saved. Tap Sync now to check access."; details = ""
        } catch { status = error.localizedDescription }
    }

    func checkAutomatically(music: MusicStore) {
        guard automatic, UIApplication.shared.applicationState == .active else { return }
        sync(music: music)
    }

    func cancel() { work?.cancel(); status = "Stopping download…" }

    func sync(music: MusicStore) {
        guard connected && !connecting && !syncing else { return }
        guard music.beginDriveImport() else {
            status = "Wait for the current music import, then try again."; return
        }
        syncing = true; details = ""; status = "Checking Google Drive…"
        work = Task {
            var added = 0
            var issues: [String] = []
            defer {
                music.endDriveImport(added: added)
                syncing = false; work = nil
            }
            do {
                let reference = try DriveFolderReference(folderLink)
                var root: DriveItem = try await metadata(id: reference.id, key: reference.resourceKey)
                root.resourceKey = root.resourceKey ?? reference.resourceKey
                guard root.isFolder else { throw DriveSyncError.message("The link must point to an actual Drive folder, not a file or shortcut.") }
                folderName = root.name
                var pending = [root]
                var visited = Set<String>()
                while !pending.isEmpty {
                    try Task.checkCancellation()
                    let directory = pending.removeLast()
                    guard visited.insert(directory.id).inserted else { continue }
                    var page: String?
                    repeat {
                        try Task.checkCancellation()
                        let result = try await children(of: directory, page: page)
                        if result.incompleteSearch == true {
                            throw DriveSyncError.message("Google returned an incomplete folder listing. Try Sync now again.")
                        }
                        for item in result.files {
                            try Task.checkCancellation()
                            if item.isFolder { pending.append(item); continue }
                            guard item.isAudio, !music.hasDriveFile(item.id) else { continue }
                            if item.capabilities?.canDownload == false {
                                issues.append("\(item.name): the owner has disabled downloading."); continue
                            }
                            status = "Downloading \(item.name)…"
                            do {
                                let local = try await download(item)
                                defer { try? FileManager.default.removeItem(at: local) }
                                try Task.checkCancellation()
                                try await music.addDriveFile(local, name: item.name, id: item.id)
                                added += 1
                            } catch {
                                try Task.checkCancellation()
                                // Stop on authentication, quota and network failures; corrupt audio
                                // can be skipped without preventing the other tracks from importing.
                                if error is DriveSyncError || error is URLError { throw error }
                                issues.append("\(item.name): \(error.localizedDescription)")
                            }
                        }
                        page = result.nextPageToken
                    } while page != nil
                }
                if issues.isEmpty { lastSync = Date() }
                status = issues.isEmpty ? "Up to date. Added \(added) new song(s)." : "Added \(added) song(s); \(issues.count) could not be downloaded."
                details = issues.prefix(8).joined(separator: "\n\n")
            } catch {
                if Task.isCancelled { status = "Stopped. \(added) downloaded song(s) kept." }
                else {
                    status = "Sync stopped. \(added) downloaded song(s) kept."
                    details = error.localizedDescription
                }
            }
        }
    }

    private struct Page: Decodable {
        let files: [DriveItem]
        let nextPageToken: String?
        let incompleteSearch: Bool?
    }
    private static let fields = "id,name,mimeType,resourceKey,capabilities(canDownload)"

    private func metadata(id: String, key: String?) async throws -> DriveItem {
        let request = try await self.request(path: "/files/\(id)", query: [URLQueryItem(name: "fields", value: Self.fields)], id: id, key: key)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    private func children(of folder: DriveItem, page: String?) async throws -> Page {
        var query = [URLQueryItem(name: "q", value: "'\(folder.id)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fields))"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let request = try await self.request(path: "/files", query: query, id: folder.id, key: folder.resourceKey)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(Page.self, from: data)
    }

    private func download(_ item: DriveItem) async throws -> URL {
        let request = try await self.request(path: "/files/\(item.id)",
            query: [URLQueryItem(name: "alt", value: "media")], id: item.id, key: item.resourceKey)
        let (url, response) = try await session.download(for: request)
        do {
            try validate(response, data: nil)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    private func request(path: String, query: [URLQueryItem], id: String, key: String?) async throws -> URLRequest {
        try Task.checkCancellation()
        guard let current = GIDSignIn.sharedInstance.currentUser else {
            connected = false
            throw DriveSyncError.message("Sign in again to reconnect Google Drive.")
        }
        let user: GIDGoogleUser
        do { user = try await current.refreshTokensIfNeeded() }
        catch {
            throw DriveSyncError.message("Google could not renew your connection. Check your internet, or sign out and sign in again. Test-mode access may expire after seven days.")
        }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3" + path)!
        components.queryItems = query + [URLQueryItem(name: "supportsAllDrives", value: "true")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + user.accessToken.tokenString, forHTTPHeaderField: "Authorization")
        if let key { request.setValue(id + "/" + key, forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") }
        return request
    }

    private func validate(_ response: URLResponse, data: Data?) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { connected = false; throw DriveSyncError.message("Google access expired. Sign in again.") }
            if code == 404 { throw DriveSyncError.message("Folder or song not found. Use the Google account that can open your shared folder, and check the folder link.") }
            if code == 403 {
                throw DriveSyncError.message("Google denied access. Check that Drive API is enabled, Drive read permission was granted, and the folder owner allows downloads. A download quota may also have been reached.")
            }
            if code == 429 { throw DriveSyncError.message("Google's request limit was reached. Wait a few minutes before trying again.") }
            throw DriveSyncError.message("Google Drive returned HTTP \(code). Try again later.")
        }
    }
}
