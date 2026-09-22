import Foundation

struct DriveItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    var resourceKey: String?
    let capabilities: Capabilities?
    struct Capabilities: Decodable { let canDownload: Bool? }
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var isAudio: Bool {
        guard !mimeType.hasPrefix("application/vnd.google-apps.") else { return false }
        return mimeType.hasPrefix("audio/") ||
        ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"].contains((name as NSString).pathExtension.lowercased())
    }
}

struct DriveFolderReference: Equatable {
    let id: String
    let resourceKey: String?
    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme != nil {
            guard url.scheme == "https", url.host == "drive.google.com",
                  let index = url.pathComponents.firstIndex(of: "folders"),
                  url.pathComponents.indices.contains(index + 1) else {
                throw DriveSyncError.message("Paste a Google Drive folder link, not a song link.")
            }
            id = url.pathComponents[index + 1]
            resourceKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "resourcekey" })?.value
        } else { id = text; resourceKey = nil }
        guard Self.validID(id), resourceKey.map(Self.validID) ?? true else {
            throw DriveSyncError.message("That folder link is not valid.")
        }
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

enum DriveSyncError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

