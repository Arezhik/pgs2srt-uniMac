# PGS2SRT

PGS2SRT turns Blu-ray picture subtitles into text subtitles. A `.sup` file is a series of pictures (PGS). An `.srt` file is the words, with times, that a video player can show.

The decoder, the SRT writer, and Apple Vision text recognition are in place. On a Mac you can already turn a `.sup` file into an `.srt` file from Terminal or from Xcode. The window is still a placeholder: drag-and-drop and MKV files come later.

The app is for Mac, and it is built as a universal binary so it runs on both Apple silicon and Intel. The decoder itself is plain Swift, with no Apple-only code, so a Windows version can share it later.

Minimum system: macOS 13 Ventura. Open the project in Xcode 27.

## Convert a .sup file to .srt on a Mac

Text recognition uses Apple’s Vision framework. It only runs on a Mac. You do not need Tesseract, pgsrip, or Python.

The command reads the pictures in the `.sup` file, recognizes the words, and writes an `.srt` file next to it. A line it cannot read is kept in the `.srt` file as `[OCR failed: …]` and is also printed in the log, so a missed subtitle does not vanish.

### From Terminal

1. Install Xcode 27 if it is not already installed.
2. Open Terminal.
3. Go into this project’s folder. For example: `cd ~/Desktop/pgs2srt-uniMac`
4. Run:

```bash
xcrun swift run pgs2srt "/path/to/Movie.sup"
```

Use the real path to your `.sup` file, including the quote marks if the path has spaces. The first run compiles the tool, which takes a minute. When it finishes, `Movie.srt` is next to `Movie.sup`.

To choose the output file, the language, or how many pictures to read at once:

```bash
xcrun swift run pgs2srt "/path/to/Movie.sup" "/path/to/Movie.srt" --lang en-US --jobs 4
```

`--lang` is a language tag such as `en-US` or `fr-FR`. Repeat it to add another language. English is the default. `--jobs` is how many subtitles to recognize at the same time (default 4).

Italics are off. Add `--italics` only if you want the tool to guess which lines lean and wrap those in `<i>`. That guess is experimental. On a real Blu-ray it marked ordinary upright dialogue, so it is not used unless you ask.

To check a file you already converted, write the new subtitles to a different name and compare:

```bash
xcrun swift run pgs2srt "/path/to/Movie.sup" "/path/to/Movie-fixed.srt"
```

`xcrun swift run pgs2srt --help` prints the same instructions.

### From Xcode

1. Open **`PGS2SRT.xcodeproj`** (see the next section if Xcode asks you to trust the project).
2. At the top of the window, open the scheme menu and choose **pgs2srt** instead of PGS2SRT.
3. Choose **Product → Scheme → Edit Scheme…**.
4. Select **Run** on the left, then the **Arguments** tab.
5. Under **Arguments Passed On Launch**, click **+** and paste the full path to the `.sup` file. Add a second argument only if you want the `.srt` written somewhere else.
6. Press Run (the triangle) or Command-R.

Xcode’s debug console shows progress as `12/340`, then a short summary: where the `.srt` was written, how many cues there were, and which ones could not be read. The working folder is not the folder that holds the `.sup`, so the path you pass has to be a full path.

The **PGS2SRT** scheme is still the placeholder window. It does not convert a file. Use the **pgs2srt** scheme for that.

## Open it in Xcode and press Run

You do not need Python, Homebrew, or any extra tools.

1. Install Xcode 27 from the App Store if it is not already installed.
2. Download this repository (the green Code button, or the pull request’s checkout).
3. Double-click **`PGS2SRT.xcodeproj`**. Do not open `Package.swift`. That file is the decoder library, and Xcode would run it as a command-line tool instead of a window.
4. If Xcode asks whether to trust the project, choose Trust. The first open loads the local Swift package. Wait until the progress spinner in the title bar finishes. That can take a minute.
5. At the top of the window, the scheme should say **PGS2SRT** and the destination should be **My Mac**.
6. Press the Run button (the triangle) or Command-R.

A window named PGS2SRT opens. It says “Coming soon” and shows decoder version 0.1.0. That means the app linked the decoder and launched. Dropping a subtitle file does nothing yet. To convert a file from Xcode, switch the scheme to **pgs2srt**, as described above.

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
- Recognize the words with Apple Vision (`VNRecognizeTextRequest`, accurate mode, language correction, English by default). The pictures are prepared first. Light letters are drawn on black and dark letters on white. A light fill with a dark outline, the usual Blu-ray letter, counts as light ink, so the outline is ignored and the fill is kept on black. Lines are padded and enlarged when the line is tiny, then ordered top to bottom. Italic tags are off unless you pass `--italics`. That lean check is experimental. Common OCR junk is cleaned up (a lone `l` that should be `I`, a bar read as a letter, extra spaces, stray marks). A space before an apostrophe that starts a word, as in "it 'cause", is kept. Spaces inside a contraction, as in "don ' t", are still joined.
- Keep a cue when recognition fails. The `.srt` line says `[OCR failed: …]` instead of skipping it. Several pictures are read at once, with progress, and the work can be cancelled.
- `pgs2srt`, the Mac command that runs that whole path from a `.sup` file to an `.srt` file.
- `pgsdump`, a small command-line tool that writes each decoded picture as a PAM image so a person can look at it. It does not recognize text, and it runs on Linux too.

A broken file stops with a message that says what was wrong and where, instead of crashing.

## For developers

From the repository root, with Swift 5.9 or newer:

```bash
swift test
swift run pgsdump file.sup /tmp/pgs-out
```

On a Mac, this also recognizes text:

```bash
swift run pgs2srt file.sup
```

`swift test` does not need a Mac for the decoder, the image-preparation math, the text cleanup, or the SRT assembly. The Vision checks are compiled only on macOS and run in the Mac CI job, using small pictures drawn in the test rather than a ripped disc. `pgsdump` writes `0001.pam`, `0002.pam`, and so on, plus `cues.txt` with the times. On a Mac, Preview opens PAM files. `ffplay` and ImageMagick open them too. `pgs2srt` on Linux builds, then stops with a message that text recognition needs a Mac.

### Adding a real .sup file later

There are no sample discs in the repository. To try a real file:

1. Put the `.sup` in `Tests/PGSCoreTests/Fixtures/`.
2. Run `swift test`.

If the folder contains any `.sup` file, the fixture test decodes it and fails if the file is unreadable. The pictures are not compared to a golden image, because we do not have official samples yet. Use `pgsdump` when you want to look at the pixels.

`.sup` files in that folder are listed in `.gitignore`, so a ripped subtitle is not committed by accident. To commit a small sample on purpose, delete the two `Fixtures/*.sup` lines from `.gitignore`.

## Roadmap

1. **Done.** Repository, Linux tests, Mac CI, the PGS decoder, the SRT writer, and a placeholder window.
2. **This slice.** Apple Vision text recognition, image preparation, cleanup, a cancellable batch pipeline, and the `pgs2srt` command. The window you can drop files on, the queue, MKV files by calling `mkvextract` when it is installed, and a notification when a batch finishes are still to come.
3. **Next.** Preview and edit the lines before saving, and choose which subtitle track to take from an MKV.
4. **Later.** Read MKV files in Swift, without mkvextract. Then sign and notarize the app.
5. **After that.** Windows. The decoder stays free of Apple-only imports so that can share it.

## Not in this version

No drag-and-drop window, no notifications, and no MKV support. Text recognition is the `pgs2srt` command, not the window yet.
