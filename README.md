# PGS2SRT

PGS2SRT turns Blu-ray picture subtitles into text subtitles. A `.sup` file is a series of pictures (PGS). An `.srt` file is the words, with times, that a video player can show.

This is the first slice of the app. The decoder, the SRT writer, the tests, and a placeholder Mac window are here. Drag-and-drop, text recognition, and MKV files come in later updates.

The app is for Mac, and it is built as a universal binary so it runs on both Apple silicon and Intel. The decoder itself is plain Swift, with no Apple-only code, so a Windows version can share it later.

Minimum system: macOS 13 Ventura. Open the project in Xcode 27.

## Open it in Xcode and press Run

You do not need Python, Homebrew, or any extra tools.

1. Install Xcode 27 from the App Store if it is not already installed.
2. Download this repository (the green Code button, or the pull request’s checkout).
3. Double-click **`PGS2SRT.xcodeproj`**. Do not open `Package.swift`. That file is the decoder library, and Xcode would run it as a command-line tool instead of a window.
4. If Xcode asks whether to trust the project, choose Trust. The first open loads the local Swift package. Wait until the progress spinner in the title bar finishes. That can take a minute.
5. At the top of the window, the scheme should say **PGS2SRT** and the destination should be **My Mac**.
6. Press the Run button (the triangle) or Command-R.

A window named PGS2SRT opens. It says “Coming soon” and shows decoder version 0.1.0. That means the app linked the decoder and launched. Dropping a subtitle file does nothing yet.

The project is set to **Sign to Run Locally**, so Xcode should not ask for an Apple Developer team. If it does: click the blue PGS2SRT project in the sidebar, select the PGS2SRT target, open Signing & Capabilities, and set the signing certificate to **Sign to Run Locally**.

Both the Debug and Release builds include Apple silicon (`arm64`) and Intel (`x86_64`). The first build is a little slower because of that. The app you run from Xcode is still unsigned in the notarization sense, but Xcode’s local signature is enough to launch it on your Mac.

### Why the project is set up this way

The decoder lives in a Swift package (`Package.swift`). That is what `swift test` runs on Linux, and it is the same code the Mac app uses. The window is a normal Xcode app target that links that package. The `.xcodeproj` is already generated and checked in, so you can open it and press Run.

`project.yml` is a recipe for [XcodeGen](https://github.com/yonaskolb/XcodeGen). You can ignore it. It is only there so a developer can regenerate the Xcode project later if the app target grows (`brew install xcodegen`, then `xcodegen generate`).

## Download the app that GitHub built

GitHub builds the universal app on a Mac runner for every pull request and every push to `main`.

1. Open this repository on GitHub.
2. Click **Actions**.
3. Open the latest **CI** run that has a green check (on `main` after this is merged, or on the pull request).
4. Scroll to **Artifacts** and download **PGS2SRT-universal.zip**.
5. Unzip it once. Inside is `PGS2SRT.app`.
6. Move that app to the Desktop or to Applications.

This copy is not signed with an Apple Developer account and it is not notarized. macOS will refuse the first open until you allow it.

### If macOS says the app cannot be opened

1. Right-click `PGS2SRT.app` and choose **Open**.
2. Click **Open** in the dialog.
3. If macOS still blocks it: open **System Settings → Privacy & Security**, scroll to the Security section, and click **Open Anyway**. Then try Open again.

The downloaded app is the same placeholder window. It is there so you can confirm the universal build launches. It does not convert files yet.

## What this version can do

- Read a Blu-ray PGS `.sup` file. It understands presentation composition (PCS, `0x16`), windows (WDS, `0x17`), palettes (PDS, `0x14`), images (ODS, `0x15`, including an image split across several packets), and the end marker (END, `0x80`).
- Turn each palette color from limited-range YCbCr into RGBA. Frames taller than 576 pixels use BT.709. Shorter frames use BT.601. A caller can force either one.
- Compose each display set into an image and a time range. Times are the 90 kHz timestamps stored in the file. A subtitle stays up until the next display set that clears the screen. A different picture, or a new epoch, closes it early so the first picture is not thrown away. Palette fades keep one cue and the most solid frame.
- Write an `.srt` file: cue numbers, `HH:MM:SS,mmm` times, and CRLF line endings (LF is available too).
- Leave a slot for text recognition. Nothing in this library recognizes text. The next update will plug Apple Vision into `SubtitleRecognizing`.
- `pgsdump`, a small command-line tool that writes each decoded picture as a PAM image so a person can look at it.

A broken file stops with a message that says what was wrong and where, instead of crashing.

## For developers

From the repository root, with Swift 5.9 or newer:

```bash
swift test
swift run pgsdump file.sup /tmp/pgs-out
```

`swift test` does not need a Mac. `pgsdump` writes `0001.pam`, `0002.pam`, and so on, plus `cues.txt` with the times. On a Mac, Preview opens PAM files. `ffplay` and ImageMagick open them too.

### Adding a real .sup file later

There are no sample discs in the repository. To try a real file:

1. Put the `.sup` in `Tests/PGSCoreTests/Fixtures/`.
2. Run `swift test`.

If the folder contains any `.sup` file, the fixture test decodes it and fails if the file is unreadable. The pictures are not compared to a golden image, because we do not have official samples yet. Use `pgsdump` when you want to look at the pixels.

`.sup` files in that folder are listed in `.gitignore`, so a ripped subtitle is not committed by accident. To commit a small sample on purpose, delete the two `Fixtures/*.sup` lines from `.gitignore`.

## Roadmap

1. **This slice.** Repository, Linux tests, Mac CI, the PGS decoder, the SRT writer, the OCR hook, and a placeholder window.
2. **Rest of the first version.** Apple Vision text recognition, a window you can drop `.sup` files on, a queue with progress and errors, MKV files by calling `mkvextract` when it is installed, and a notification when a batch finishes.
3. **Next.** Preview and edit the lines before saving, and choose which subtitle track to take from an MKV.
4. **Later.** Read MKV files in Swift, without mkvextract. Then sign and notarize the app.
5. **After that.** Windows. The decoder stays free of Apple-only imports so that can share it.

## Not in this version

No drag-and-drop, no Vision text recognition, no notifications, and no MKV support.
