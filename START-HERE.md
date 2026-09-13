# Cadence for iPhone — IPA build kit

This ZIP contains a native SwiftUI iPhone app and the tools to build an unsigned IPA. **It is not itself an IPA and cannot be imported directly into KSign.** The iOS app has not been compiled or tested on an iPhone in this Windows environment.

Requires iOS 17 or newer. No Spotify account, subscription, server, or API key is used. Bring your own unprotected audio files.

## Get an IPA without owning a Mac

1. Create an empty **private** GitHub repository for Cadence.
2. Extract this kit and upload its contents to the repository root. The root must contain `Cadence.xcodeproj`, `Cadence`, `scripts`, and `.github`. Do not upload only the ZIP or place everything inside an extra `Cadence-iOS` folder.
3. Make sure `.github/workflows/build-ipa.yml` is present. Windows may hide the `.github` folder. If GitHub's upload page skips it, create a new file at that exact path and paste the supplied workflow into it.
4. Open the repository's **Actions** tab, select **Build Cadence IPA**, and choose **Run workflow**. Enable Actions if GitHub asks. The workflow runs only when you manually start it.
5. When the run succeeds, download **Cadence-unsigned-IPA** from its Artifacts section. Unzip that download to get **Cadence-unsigned.ipa**.
6. Transfer that `.ipa` to your iPhone's Files app. Import it into KSign and sign/install it using your existing valid signing setup. Keep the bundle ID `com.cadence.localplayer` when updating the app if you want to retain its library.

The build requires no signing certificates or Apple credentials. GitHub's account-specific Actions limits and billing apply; review your available minutes before running it. Installation still depends on your signing certificate, provisioning profile, and device being compatible. This kit does not include or obtain certificates.

## Build on a Mac instead

Install Xcode 15 or newer, launch it once to finish its setup, and select it as the active developer directory if necessary. In Terminal, open the extracted kit folder and run:

```sh
bash scripts/build-ipa.sh
```

The script builds for a real arm64 iPhone, verifies the app and IPA archive, and writes `artifacts/Cadence-unsigned.ipa`. Sign that file with your existing setup. You can also open `Cadence.xcodeproj` and run the app directly with Xcode after selecting your Apple signing team.

## Using Cadence

- Tap **+** to import audio from Files, including files downloaded from iCloud Drive. Cadence copies them into its own storage for local playback.
- Use a song's **…** menu to like it, add it to a playlist, or remove it.
- Open **Playlists** and tap **+** to create a playlist. Swipe a playlist to delete it.
- Tap the mini-player to open the full player, with seeking, shuffle, repeat, and AirPlay output selection.
- Background audio and lock-screen controls are implemented. Playback pauses if headphones disconnect or another audio interruption occurs; press Play to resume.
- Use your iPhone's volume buttons. Imports, favorites, and playlists stay on that device.

MP3, unprotected M4A, and WAV are recommended. Unsupported or corrupt files are rejected during import. Titles/artists come from filenames such as `Artist - Song.mp3`; embedded tags and album artwork are not read. Importing a file again creates another copy. Removing a song deletes Cadence's imported copy, not the original in Files. Uninstalling Cadence removes its local library.

## What was verified here

The kit was authored on Windows. Source syntax and project/asset/package structure were checked locally where tools allowed. Apple frameworks, device behavior, background playback, AirPlay, signing, and installation still need a successful Xcode build and iPhone test. The build workflow is included but has not been run from this environment.

If the GitHub build fails, download or copy the failed step's log and return it to this task for repair.

References: [Apple device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices), [Apple audio session](https://developer.apple.com/documentation/avfaudio/avaudiosession), [GitHub workflow runs and artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs).
