# PGS2SRT

PGS2SRT turns Blu-ray picture subtitles into text subtitles. A `.sup` file is a series of pictures (PGS). An `.srt` file is the words, with times, that a video player can show.

The decoder, the SRT writer, and Apple Vision text recognition are in place. On a Mac, open the app and drop a `.sup` file on the window. The same conversion is still available from Terminal.

The app is for Mac, and it is built as a universal binary so it runs on both Apple silicon and Intel. The decoder itself is plain Swift, with no Apple-only code, so a Windows version can share it later.

Minimum system: macOS 13 Ventura. Open the project in Xcode 27.

## Use the window

1. Open **PGS2SRT** (from Xcode with the Run button, or from the copy GitHub built — both are described below).
2. Drop one or more `.sup` or `.mkv` files onto the window. You can also drop a folder; the app looks through it, including folders inside it, and queues every `.sup` and `.mkv` it finds.
3. Or click **Open…**, or choose **File → Open…**.
4. Each file shows in the list as Waiting, then Converting with a count such as `120/777`, then Done or Failed.
5. When a file is Done, the list shows how many cues were written and, if any line could not be read, how many say `[OCR failed]`. **Reveal in Finder** selects the new `.srt`. If that file is missing, Reveal says so. It can show the folder, or convert the original again when that file is still there.
6. **Cancel** stops that file. **Cancel All** stops the whole queue. A file that was cancelled is not saved as a half-written `.srt`.

By default the `.srt` is written next to the source file, with the same name: `Movie.sup` becomes `Movie.srt`, and `Movie.mkv` becomes `Movie.srt`.

The first time you add files, macOS may ask whether PGS2SRT can send notifications. If you allow it, a notification appears when the batch finishes and says how many files are done and how many failed. If you say no, conversion still works; you just will not get that notification. The app asks once.

An `.mkv` is converted from the PGS subtitle track inside it. That uses [MKVToolNix](https://mkvtoolnix.download) (`mkvmerge` and `mkvextract`). If those tools are not installed, the row says so and links to the download. The picture subtitles are extracted to a temporary file, converted the same way as a `.sup`, and the temporary file is removed when the row finishes, fails, or is cancelled.

### Dock icon and Open With

The app declares itself as a reader of `.sup` files, `.mkv` files, and folders.

- Drag a `.sup`, an `.mkv`, or a folder of them, onto the PGS2SRT icon in the Dock. It is added to the queue. If the window is already open, the files join that window and a second window does not open. A window opens only when none is open. A folder is searched the same way as a folder dropped on the window, including folders inside it. An empty folder shows a note that no `.sup` or `.mkv` files were found.
- In Finder, right-click a `.sup`, choose **Open With → PGS2SRT**. If PGS2SRT is not listed yet, launch the app once, or move it to the Applications folder, and try again. Opening a file this way also uses the window that is already open.

### Settings

Choose **PGS2SRT → Settings…** (or the Settings… button). The choices are remembered on this Mac.

- **Save the .srt file.** Next to the source file, or in one folder you choose.
- **If the .srt file already exists.** Overwrite it, add a number (`Movie 2.srt`, `Movie 3.srt`, …), or skip that file. Overwrite is the default, and it asks before replacing a file that is already there. Replace erases that file. Skip leaves it alone. Apply to all uses that answer for the rest of the files you just dropped, so a folder does not ask once per file. Add a number and Skip do not ask. Two files in one batch that would both be named `Movie.srt` get separate names, so one does not erase the other.
- **Language.** English is the default. This is the language Apple Vision looks for.
- **Pictures to read at once.** Files are converted one at a time, so the progress count stays easy to read. This number is how many pictures inside the current file are read together. The default is 4.
- **Experimental italics.** Off by default. Turn it on only if you want the app to guess which lines lean and wrap those words in `<i>` tags. On a real Blu-ray that guess often marks ordinary upright dialogue, so leave it off unless you want to try it. It is the same switch as `--italics` on the command line.
- **Choose the subtitle track for each MKV.** Off by default. Off uses the English PGS track, or the first PGS track when the file has no English one. On shows a sheet for each MKV listing the PGS tracks (number, language, name, and the forced and default flags), with that usual choice already selected. Convert uses the selected track. Skip leaves that file alone.

## Convert a .sup file from Terminal

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

1. Open **`App/PGS2SRT.xcodeproj`** (see the next section if Xcode asks you to trust the project).
2. At the top of the window, open the scheme menu and choose **pgs2srt** instead of PGS2SRT.
3. Choose **Product → Scheme → Edit Scheme…**.
4. Select **Run** on the left, then the **Arguments** tab.
5. Under **Arguments Passed On Launch**, click **+** and paste the full path to the `.sup` file. Add a second argument only if you want the `.srt` written somewhere else.
6. Press Run (the triangle) or Command-R.

Xcode’s debug console shows progress as `12/340`, then a short summary: where the `.srt` was written, how many cues there were, and which ones could not be read. The working folder is not the folder that holds the `.sup`, so the path you pass has to be a full path.

The **PGS2SRT** scheme is the window. Use that for drag-and-drop. The **pgs2srt** scheme is only the command-line tool.

## Open it in Xcode and press Run

You do not need Python or Homebrew to convert a `.sup` file. An `.mkv` needs [MKVToolNix](https://mkvtoolnix.download) installed (`mkvmerge` and `mkvextract`).

1. Install Xcode 27 from the App Store if it is not already installed.
2. Download this repository (the green Code button, or the pull request’s checkout).
3. Quit Xcode if it is open. In the repository folder, delete the `.build` folder if you see one. In Terminal, run `rm -rf ~/Library/Developer/Xcode/DerivedData/PGS2SRT-*`.
4. Double-click **`App/PGS2SRT.xcodeproj`**. Do not open `Package.swift`, and do not open a project file that sits in the repository root. `Package.swift` is the decoder library. Opening it runs a command-line tool instead of the window.
5. If Xcode asks whether to trust the project, choose Trust. The first open loads the local Swift package. Wait until the progress spinner in the title bar finishes. That can take a minute.
6. At the top of the window, the scheme should say **PGS2SRT** and the destination should be **My Mac**.
7. Press the Run button (the triangle) or Command-R.

A window named PGS2SRT opens. Drop a `.sup` file on it, or click Open…. The `.srt` appears next to the source file when the row says Done.

The project is set to **Sign to Run Locally**, so Xcode should not ask for an Apple Developer team. If it does: click the blue PGS2SRT project in the sidebar, select the PGS2SRT target, open Signing & Capabilities, and set the signing certificate to **Sign to Run Locally**.

Run uses the Debug build, which includes only the chip in the Mac you are using (Apple silicon or Intel). The copy GitHub builds for download is Release, and that one includes both. The app you run from Xcode is still unsigned in the notarization sense, but Xcode’s local signature is enough to launch it on your Mac.

### Why the project is set up this way

The decoder lives in a Swift package named **PGS2SRTKit** (`Package.swift` at the repository root). The Xcode project is named PGS2SRT and lives in `App/`, one folder down, so it is not sitting in the same folder as that package. Xcode’s window gets confused when the package and the project share a name and a folder: the command line can still resolve the package, but the window says the products are missing, and a Debug build then tries to read a module built for a different Mac target. The window is a normal macOS app (not an iPad app, not Mac Catalyst). Debug builds only the chip in the Mac you are using. Release still builds for both Apple silicon and Intel. The `.xcodeproj` is already generated and checked in, so you can open it and press Run.

`App/project.yml` is a recipe for [XcodeGen](https://github.com/yonaskolb/XcodeGen). You can ignore it. It is only there so a developer can regenerate the Xcode project later (`brew install xcodegen`, then `cd App` and `xcodegen generate`).

`AGENTS.md` has the rules for coding agents (and a short project map). Read it before the first change.

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

The downloaded app converts `.sup` files. Drop one on the window, or use Open…. The first launch still needs the Open / Open Anyway steps above, because the app is not notarized.

## What this version can do

- Read a Blu-ray PGS `.sup` file. It understands presentation composition (PCS, `0x16`), windows (WDS, `0x17`), palettes (PDS, `0x14`), images (ODS, `0x15`, including an image split across several packets), and the end marker (END, `0x80`).
- Turn each palette color from limited-range YCbCr into RGBA. Frames taller than 576 pixels use BT.709. Shorter frames use BT.601. A caller can force either one.
- Compose each display set into an image and a time range. Times are the 90 kHz timestamps stored in the file. A subtitle stays up until the next display set that clears the screen. A different picture, or a new epoch, closes it early so the first picture is not thrown away. Palette fades keep one cue and the most solid frame.
- Write an `.srt` file: cue numbers, `HH:MM:SS,mmm` times, and CRLF line endings (LF is available too).
- Recognize the words with Apple Vision (`VNRecognizeTextRequest`, accurate mode, language correction, English by default). The pictures are prepared first. Light letters are drawn on black and dark letters on white. A light fill with a dark outline, the usual Blu-ray letter, counts as light ink, so the outline is ignored and the fill is kept on black. Lines are padded and enlarged when the line is tiny, then ordered top to bottom. Italic tags are off unless you turn on Experimental italics in Settings, or pass `--italics` to the command. That lean check is experimental. Common OCR junk is cleaned up (a lone `l` that should be `I`, a bar read as a letter, extra spaces, stray marks). A space before an apostrophe that starts a word, as in "it 'cause", is kept. Spaces inside a contraction, as in "don ' t", are still joined.
- Keep a cue when recognition fails. The `.srt` line says `[OCR failed: …]` instead of skipping it. Several pictures are read at once, with progress, and the work can be cancelled.
- A Mac window with a queue: drop files or folders, Open…, Dock drops, and Finder’s Open With. `.sup` and `.mkv` files are accepted. Each row shows waiting, extracting (for an MKV), progress, done (with the cue count and any `[OCR failed]` count), or the decoder’s own error text. Settings remember the output folder, the language, what to do when the `.srt` already exists, how many pictures to read at once, Experimental italics, and whether to choose the PGS track in each MKV. A notification reports how many files finished and how many failed.
- MKV conversion by calling MKVToolNix. `mkvmerge -J` lists the tracks. The English PGS track is used, or the first PGS track when there is no English one, unless Settings asks you to pick. `mkvextract` writes that track to a temporary `.sup`, the usual pipeline converts it, and the temporary file is deleted. Cancel stops a running `mkvmerge` or `mkvextract`. An MKV with no PGS track is skipped. If MKVToolNix is not installed, the row says so and links to https://mkvtoolnix.download.
- `pgs2srt`, the Mac command that runs that whole path from a `.sup` file to an `.srt` file. The window calls the same pipeline. It does not run the command in the background.
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

`swift test` does not need a Mac for the decoder, the image-preparation math, the text cleanup, the SRT assembly, or the queue (naming collisions, status changes, and cancellation). The Vision checks are compiled only on macOS and run in the Mac CI job, using small pictures drawn in the test rather than a ripped disc. `pgsdump` writes `0001.pam`, `0002.pam`, and so on, plus `cues.txt` with the times. On a Mac, Preview opens PAM files. `ffplay` and ImageMagick open them too. `pgs2srt` on Linux builds, then stops with a message that text recognition needs a Mac.

The app is not sandboxed. A sandboxed app is allowed to read a file you drop, and is not allowed to create a new `.srt` beside it. Writing next to the source is what this app does, including for a file dropped on the Dock icon. The project stays on **Sign to Run Locally**, so no Apple Developer team is required. Turning the sandbox on later needs a real signature and a way to save next to the dropped file (for example a folder the person has chosen).

### Adding a real .sup file later

There are no sample discs in the repository. To try a real file:

1. Put the `.sup` in `Tests/PGSCoreTests/Fixtures/`.
2. Run `swift test`.

If the folder contains any `.sup` file, the fixture test decodes it and fails if the file is unreadable. The pictures are not compared to a golden image, because we do not have official samples yet. Use `pgsdump` when you want to look at the pixels.

`.sup` files in that folder are listed in `.gitignore`, so a ripped subtitle is not committed by accident. To commit a small sample on purpose, delete the two `Fixtures/*.sup` lines from `.gitignore`.

## Roadmap

1. **Done.** Repository, Linux tests, Mac CI, the PGS decoder, and the SRT writer.
2. **Done.** Apple Vision text recognition, image preparation, cleanup, a cancellable batch pipeline, and the `pgs2srt` command.
3. **Done.** The window: drop files or folders, a queue with progress, Settings, and a notification when a batch finishes.
4. **Done.** MKV files, by calling MKVToolNix (`mkvmerge` and `mkvextract`) when it is installed, including a setting to choose the PGS track.
5. **Next.** Preview and edit the lines before saving.
6. **Later.** Read MKV files in Swift, without mkvextract. Then sign and notarize the app.
7. **After that.** Windows. The decoder stays free of Apple-only imports so that can share it.

## Not in this version

No subtitle editor, and the app is not notarized. MKV conversion needs MKVToolNix; the app does not read an MKV by itself.
