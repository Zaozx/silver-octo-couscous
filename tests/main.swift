import Foundation

func require(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

let folder = try DriveFolderReference(" https://drive.google.com/drive/folders/shared_123?usp=sharing&resourcekey=key-456 ")
require(folder.id == "shared_123" && folder.resourceKey == "key-456", "Shared link/resource key parsing failed")
let accountPath = try DriveFolderReference("https://drive.google.com/drive/u/0/folders/folder_123")
require(accountPath.id == "folder_123", "Account-specific Drive link parsing failed")
let bare = try DriveFolderReference("folder-123")
require(bare.id == "folder-123" && bare.resourceKey == nil, "Bare ID parsing failed")
for invalid in ["", "folder' or trashed=true", "https://example.com/drive/folders/abc", "https://drive.google.com/file/d/abc/view", "http://drive.google.com/drive/folders/abc", "https://drive.google.com/drive/folders/"] {
    var rejected = false
    do { _ = try DriveFolderReference(invalid) } catch { rejected = true }
    require(rejected, "Accepted invalid folder input: \(invalid)")
}
let samples = #"[{"id":"one","name":"Song.MP3","mimeType":"application/octet-stream"},{"id":"two","name":"No extension","mimeType":"audio/mpeg","capabilities":{"canDownload":false}},{"id":"three","name":"Song.mp3","mimeType":"application/vnd.google-apps.shortcut"},{"id":"four","name":"Music","mimeType":"application/vnd.google-apps.folder"},{"id":"five","name":"Notes.txt","mimeType":"text/plain"}]"#
let items = try JSONDecoder().decode([DriveItem].self, from: Data(samples.utf8))
require(items[0].isAudio && items[1].isAudio, "Audio MIME/extension detection failed")
require(items[1].capabilities?.canDownload == false, "Download restriction was lost")
require(!items[2].isAudio, "Shortcut must not be treated as downloadable audio")
require(items[3].isFolder && !items[3].isAudio, "Folder detection failed")
require(!items[4].isAudio, "Non-audio file was accepted")
print("Drive link, resource key, file type and download restriction tests passed.")
