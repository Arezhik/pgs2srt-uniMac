import Foundation

/// One `.sup` or `.mkv` file in the window's queue.
public struct ConversionItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sourcePath: String
    public var name: String
    public var status: ConversionStatus

    public init(id: UUID, sourcePath: String, name: String, status: ConversionStatus) {
        self.id = id
        self.sourcePath = sourcePath
        self.name = name
        self.status = status
    }

    /// Folder that holds the source file. Empty when the path has no directory.
    public var folder: String {
        let directory = (sourcePath as NSString).deletingLastPathComponent
        if directory.isEmpty || directory == "." { return "" }
        return directory
    }
}

/// Waiting, extracting, converting, finished, or stopped.
public enum ConversionStatus: Equatable, Sendable {
    case waiting
    /// `mkvextract` is pulling the PGS track out of an MKV.
    case extracting
    case converting(completed: Int, total: Int)
    case done(cueCount: Int, unrecognizedCount: Int, outputPath: String)
    /// Converted, and held until the person saves from the review window.
    case awaitingReview(cueCount: Int, unrecognizedCount: Int, plannedPath: String)
    case failed(String)
    case cancelled
    case skipped(String)

    public var isActive: Bool {
        switch self {
        case .waiting, .extracting, .converting:
            return true
        case .done, .awaitingReview, .failed, .cancelled, .skipped:
            return false
        }
    }

    /// Done, held for review, failed, cancelled, or skipped. Clear Finished and
    /// the row's remove button can take these off the list. Waiting, extracting,
    /// and converting stay until Cancel.
    public var isRemovable: Bool {
        switch self {
        case .done, .awaitingReview, .failed, .cancelled, .skipped:
            return true
        case .waiting, .extracting, .converting:
            return false
        }
    }
}

/// Counts posted when a batch has nothing left running.
public struct BatchOutcome: Equatable, Sendable {
    public var done: Int
    public var failed: Int
    public var cancelled: Int
    public var skipped: Int

    public init(done: Int, failed: Int, cancelled: Int, skipped: Int) {
        self.done = done
        self.failed = failed
        self.cancelled = cancelled
        self.skipped = skipped
    }

    public static let zero = BatchOutcome(done: 0, failed: 0, cancelled: 0, skipped: 0)

    /// "Finished. 3 done, 1 failed." Cancelled and skipped are added when they happened.
    public var notificationBody: String {
        var text = "Finished. \(done) done, \(failed) failed"
        if cancelled > 0 { text += ", \(cancelled) cancelled" }
        if skipped > 0 { text += ", \(skipped) skipped" }
        return text + "."
    }
}

/// One file's bytes, the recognition settings, and a progress callback.
public struct ConversionWork: Sendable {
    public var data: Data
    public var languages: [String]
    public var maxConcurrent: Int
    public var italics: Bool
    /// When true, the pipeline keeps each cue picture for the review window.
    public var keepPictures: Bool
    public var progress: @Sendable (TranscriptionProgress) -> Void

    public init(
        data: Data,
        languages: [String],
        maxConcurrent: Int,
        italics: Bool,
        keepPictures: Bool = false,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) {
        self.data = data
        self.languages = languages
        self.maxConcurrent = maxConcurrent
        self.italics = italics
        self.keepPictures = keepPictures
        self.progress = progress
    }
}

/// File access and the conversion call. Tests substitute their own.
public struct ConversionServices: Sendable {
    public var read: @Sendable (String) async throws -> Data
    public var write: @Sendable (String, String) async throws -> Void
    public var fileExists: @Sendable (String) -> Bool
    public var directoryExists: @Sendable (String) -> Bool
    public var listing: DirectoryListing
    public var convert: @Sendable (ConversionWork) async throws -> TranscriptionResult
    public var mkv: MKVClient

    public init(
        read: @escaping @Sendable (String) async throws -> Data,
        write: @escaping @Sendable (String, String) async throws -> Void,
        fileExists: @escaping @Sendable (String) -> Bool,
        directoryExists: @escaping @Sendable (String) -> Bool,
        listing: DirectoryListing,
        convert: @escaping @Sendable (ConversionWork) async throws -> TranscriptionResult,
        mkv: MKVClient = .live
    ) {
        self.read = read
        self.write = write
        self.fileExists = fileExists
        self.directoryExists = directoryExists
        self.listing = listing
        self.convert = convert
        self.mkv = mkv
    }

    /// Disk reads and writes. `convert` is the shared transcription pipeline.
    public static func live(
        convert: @escaping @Sendable (ConversionWork) async throws -> TranscriptionResult
    ) -> ConversionServices {
        return ConversionServices(
            read: { path in
                try SourceFileBytes.read(path)
            },
            write: { path, text in
                try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            listing: .live,
            convert: convert,
            mkv: .live
        )
    }
}

public extension TranscriptionPipeline {
    /// Decode, recognize, and assemble SRT text. The window and tests both come through here.
    static func run(
        _ work: ConversionWork,
        recognizer: any SubtitleRecognizing
    ) async throws -> TranscriptionResult {
        let languages = work.languages.isEmpty ? [ConversionPreferences.defaultLanguage] : work.languages
        let pipeline = TranscriptionPipeline(
            languages: languages,
            maxConcurrent: max(1, work.maxConcurrent),
            italics: work.italics,
            keepPictures: work.keepPictures
        )
        return try await pipeline.transcribeFile(
            data: work.data,
            recognizer: recognizer,
            progress: work.progress
        )
    }
}

/// The queue behind the window. Files run one at a time. Pictures inside a file
/// run together, up to the concurrency setting. UI updates stay on the main actor.
/// Reading, recognition, and writing hop off it.
@MainActor
public final class ConversionQueue {
    public private(set) var items: [ConversionItem] = []
    public private(set) var banners: [String] = []
    public var onChange: (@MainActor () -> Void)?
    public var onBatchFinished: (@MainActor (BatchOutcome) -> Void)?

    private var storedPreferences: ConversionPreferences
    public var preferences: ConversionPreferences {
        get { storedPreferences }
        set { storedPreferences = newValue.normalized }
    }

    private let services: ConversionServices
    private let progressSink = ProgressSink()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var startedAt: [UUID: Date] = [:]
    private var pumpTask: Task<Void, Never>?
    private var reserved: Set<String> = []
    private var batch = BatchOutcome.zero
    private var batchOpen = false
    private var outputFolderOverrides: [String: String] = [:]
    /// Replace or Skip for later files in this batch. Cleared when the batch ends.
    private var rememberedOverwrite: RememberedOverwrite?
    /// Asks before Overwrite replaces a file. Nil replaces without asking, for tests and tools.
    public var confirmReplace: (@MainActor (String) async -> OverwriteAnswer)?
    /// Asks which PGS track to take when the MKV setting is on. Nil uses the usual track.
    public var chooseTrack: (@MainActor (String, [PGSSubtitleTrack], Int) async -> MKVTrackChoice)?

    private struct HeldReview {
        var document: CueDocument
        var plannedPath: String
        var savedPath: String?
    }

    private var heldReviews: [UUID: HeldReview] = [:]
    private let pictureSession = CuePictureSession()

    public init(preferences: ConversionPreferences = .default, services: ConversionServices) {
        self.storedPreferences = preferences.normalized
        self.services = services
        progressSink.setApply { [weak self] id, completed, total in
            Task { @MainActor in
                self?.applyProgress(id: id, completed: completed, total: total)
            }
        }
    }

    /// Add dropped or opened paths. Folders are searched for `.sup` and `.mkv` files.
    /// `outputFolder`, when set, is where this batch of files is written instead of the saved place.
    @discardableResult
    public func add(paths: [String], outputFolder: String? = nil) -> [IntakeNotice] {
        let intake = FileIntake.collect(paths: paths, listing: services.listing)
        let fresh = intake.sourcePaths.filter { !isActive($0) }
        if !fresh.isEmpty {
            ensureBatch()
        }
        if let outputFolder {
            let folder = outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !folder.isEmpty {
                for path in fresh {
                    outputFolderOverrides[path] = folder
                }
            }
        }
        for path in fresh {
            let id = UUID()
            startedAt[id] = Date()
            let name = FileIntake.lastComponent(path)
            items.append(ConversionItem(
                id: id,
                sourcePath: path,
                name: name,
                status: .waiting
            ))
            DebugLog.shared.record(.queue, "Added \(name) (\(Self.byteCount(path)), \(Self.fileKind(path))) \(path)")
        }
        for notice in intake.notices where notice.isFile {
            guard let path = notice.path else { continue }
            items.append(ConversionItem(
                id: UUID(),
                sourcePath: path,
                name: FileIntake.lastComponent(path),
                status: .skipped(notice.message)
            ))
            DebugLog.shared.record(.queue, "Skipped \(notice.message)")
            if batchOpen {
                batch.skipped += 1
            }
        }
        for notice in intake.notices where !notice.isFile {
            banners.append(notice.message)
            DebugLog.shared.record(.queue, notice.message)
        }
        publish()
        if !fresh.isEmpty {
            startPump()
        }
        return intake.notices
    }

    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .waiting:
            outputFolderOverrides.removeValue(forKey: items[index].sourcePath)
            tasks[id]?.cancel()
            setStatus(id, .cancelled)
            finishBatchIfIdle()
        case .extracting, .converting:
            tasks[id]?.cancel()
        case .done, .awaitingReview, .failed, .cancelled, .skipped:
            break
        }
    }

    public func cancelAll() {
        let ids = items.filter { $0.status.isActive }.map(\.id)
        if !ids.isEmpty {
            DebugLog.shared.record(.queue, "Cancel all")
        }
        for id in ids {
            cancel(id: id)
        }
    }

    /// Takes one finished row off the list. Waiting and converting rows are left
    /// alone. This does not delete the `.sup` or the `.srt`.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].status.isRemovable else { return false }
        items.remove(at: index)
        tasks[id] = nil
        discardReview(id)
        publish()
        return true
    }

    /// Takes every done, failed, skipped, and cancelled row off the list.
    /// Waiting and converting rows stay. Nothing on disk is deleted.
    /// An empty list is the window's drop screen.
    public func clearFinished() {
        let removed = items.filter(\.status.isRemovable).map(\.id)
        guard !removed.isEmpty else { return }
        items.removeAll { $0.status.isRemovable }
        for id in removed {
            tasks[id] = nil
            discardReview(id)
        }
        publish()
    }

    /// True when Clear Finished has at least one row it can take off the list.
    public var canClearFinished: Bool {
        items.contains(where: \.status.isRemovable)
    }

    public func dismissBanner(at index: Int) {
        guard banners.indices.contains(index) else { return }
        banners.remove(at: index)
        publish()
    }

    public var hasCancellableWork: Bool {
        items.contains(where: \.status.isActive)
    }

    private func isActive(_ path: String) -> Bool {
        items.contains { $0.sourcePath == path && $0.status.isActive }
    }

    private func ensureBatch() {
        if !batchOpen {
            batch = .zero
            batchOpen = true
            reserved.removeAll()
            rememberedOverwrite = nil
        }
    }

    private func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pump()
            self.endPump()
        }
    }

    private func pump() async {
        while !Task.isCancelled {
            guard let id = nextWaitingID() else { return }
            await runJob(id)
        }
    }

    private func endPump() {
        pumpTask = nil
        if nextWaitingID() != nil {
            startPump()
        } else {
            finishBatchIfIdle()
        }
    }

    private func nextWaitingID() -> UUID? {
        items.first { if case .waiting = $0.status { return true }; return false }?.id
    }

    private func runJob(_ id: UUID) async {
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(id)
        }
        tasks[id] = job
        await job.value
        tasks[id] = nil
    }

    private func perform(_ id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .waiting = items[index].status else { return }
        let source = items[index].sourcePath
        let fileName = items[index].name
        if Task.isCancelled {
            outputFolderOverrides.removeValue(forKey: source)
            setStatus(id, .cancelled)
            return
        }
        let outputFolder = outputFolderOverrides.removeValue(forKey: source)
        let kind = FileIntake.isMkv(source) ? "mkv" : "sup"
        DebugLog.shared.record(.queue, "Start \(fileName) (\(kind)) \(preferences.logDescription)")
        if let outputFolder, !outputFolder.isEmpty {
            DebugLog.shared.record(.queue, "Output folder override \(outputFolder) for \(fileName)")
        }
        if FileIntake.isMkv(source) {
            await performMKV(id: id, source: source, outputFolder: outputFolder)
        } else {
            await performSup(id: id, source: source, outputFolder: outputFolder)
        }
    }

    private func performSup(id: UUID, source: String, outputFolder: String?) async {
        guard let prepared = await resolveDestination(id: id, source: source, outputFolder: outputFolder) else {
            return
        }
        await beginConversion(id: id, readPath: source, prepared: prepared)
    }

    /// Lists PGS tracks, extracts the chosen one, then runs the `.sup` pipeline.
    /// The temporary `.sup` and its folder are removed on every way out.
    private func performMKV(id: UUID, source: String, outputFolder: String?) async {
        guard isStillRunning(id) else { return }
        let fileName = FileIntake.lastComponent(source)
        guard let tools = services.mkv.locate() else {
            DebugLog.shared.record(.mkv, "MKVToolNix not found for \(fileName)")
            setStatus(id, .skipped(MKVCopy.needsToolNix))
            return
        }
        DebugLog.shared.record(
            .mkv,
            "MKVToolNix mkvmerge \(tools.mkvmerge), mkvextract \(tools.mkvextract)"
        )
        guard markExtracting(id) else { return }

        let parsed: [PGSSubtitleTrack]
        let identifyStarted = Date()
        DebugLog.shared.record(.mkv, "Identify started \(fileName)")
        do {
            try Task.checkCancellation()
            let json = try await services.mkv.identify(tools.mkvmerge, source)
            try Task.checkCancellation()
            parsed = try MKVIdentify.tracks(in: json)
        } catch is CancellationError {
            DebugLog.shared.record(
                .mkv,
                "Identify cancelled \(fileName), \(DebugLogFormatting.duration(since: identifyStarted))"
            )
            setStatus(id, .cancelled)
            return
        } catch {
            DebugLog.shared.record(
                .error,
                "Identify failed \(fileName), \(DebugLogFormatting.duration(since: identifyStarted)): \(error)",
                isError: true
            )
            setStatus(id, .failed(ConversionFailureText.message(for: error)))
            return
        }
        DebugLog.shared.record(
            .mkv,
            "Identify finished \(fileName), \(DebugLogFormatting.duration(since: identifyStarted)), tracks \(Self.trackSummary(parsed))"
        )

        guard let suggested = MKVIdentify.preferredTrack(in: parsed) else {
            setStatus(id, .skipped(MKVCopy.noPGS))
            return
        }

        let track: PGSSubtitleTrack
        if preferences.chooseMKVTrack, let chooseTrack {
            DebugLog.shared.record(.mkv, "Asking which track in \(fileName)")
            let choice = await chooseTrack(fileName, parsed, suggested.id)
            if Task.isCancelled || !isStillRunning(id) {
                setStatus(id, .cancelled)
                return
            }
            switch choice {
            case let .convert(trackID):
                track = parsed.first { $0.id == trackID } ?? suggested
                DebugLog.shared.record(.mkv, "Track chosen \(track.id) \(track.language) for \(fileName)")
            case .skip:
                DebugLog.shared.record(.mkv, "Track choice skipped \(fileName)")
                setStatus(id, .skipped(MKVCopy.skippedTrack))
                return
            case .cancel:
                DebugLog.shared.record(.mkv, "Track choice cancelled \(fileName)")
                setStatus(id, .cancelled)
                return
            }
        } else {
            track = suggested
            DebugLog.shared.record(.mkv, "Track chosen \(track.id) \(track.language) for \(fileName)")
        }

        guard let prepared = await resolveDestination(id: id, source: source, outputFolder: outputFolder) else {
            return
        }

        let folder: URL
        do {
            folder = try TemporaryExtract.create()
        } catch {
            setStatus(id, .failed(ConversionFailureText.message(for: error)))
            return
        }
        defer { TemporaryExtract.remove(folder) }

        let supPath = folder.appendingPathComponent("subtitles.sup").path
        let extractStarted = Date()
        DebugLog.shared.record(.mkv, "Extract started \(fileName) track \(track.id)")
        do {
            try Task.checkCancellation()
            try await services.mkv.extract(tools.mkvextract, source, track.id, supPath)
            try Task.checkCancellation()
        } catch is CancellationError {
            DebugLog.shared.record(
                .mkv,
                "Extract cancelled \(fileName), \(DebugLogFormatting.duration(since: extractStarted))"
            )
            setStatus(id, .cancelled)
            return
        } catch {
            DebugLog.shared.record(
                .error,
                "Extract failed \(fileName), \(DebugLogFormatting.duration(since: extractStarted)): \(error)",
                isError: true
            )
            setStatus(id, .failed(ConversionFailureText.message(for: error)))
            return
        }
        DebugLog.shared.record(
            .mkv,
            "Extract finished \(fileName) track \(track.id), \(DebugLogFormatting.duration(since: extractStarted))"
        )

        if Task.isCancelled || !isStillRunning(id) {
            setStatus(id, .cancelled)
            return
        }
        await beginConversion(id: id, readPath: supPath, prepared: prepared)
    }

    private func markExtracting(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].status.isActive else { return false }
        items[index].status = .extracting
        publish()
        return true
    }

    /// Where this file will be written, after the overwrite question. Nil means the row is already finished.
    private func resolveDestination(
        id: UUID,
        source: String,
        outputFolder: String?
    ) async -> (path: String, preferences: ConversionPreferences)? {
        guard isStillRunning(id) else { return nil }
        var prefs = preferences
        if let outputFolder {
            prefs.placement = .folder(outputFolder)
        }
        let planned = SRTOutputPath.plan(
            sourcePath: source,
            preferences: prefs,
            fileExists: services.fileExists,
            directoryExists: services.directoryExists,
            reserved: reserved
        )
        let destination: OutputDestination
        switch OverwriteConfirmation.resolve(
            planned: planned,
            setting: prefs.existingFile,
            fileExists: services.fileExists,
            remembered: rememberedOverwrite
        ) {
        case let .ask(path):
            let answer = await askToReplace(path)
            if !isStillRunning(id) {
                return nil
            }
            if Task.isCancelled {
                setStatus(id, .cancelled)
                return nil
            }
            if let remembered = OverwriteConfirmation.remember(answer) {
                rememberedOverwrite = remembered
            }
            switch answer {
            case let .replace(applyToAll):
                DebugLog.shared.record(.queue, "Overwrite replace \(path) applyToAll=\(applyToAll)")
                destination = .write(path)
            case let .skip(applyToAll):
                DebugLog.shared.record(.queue, "Overwrite skip \(path) applyToAll=\(applyToAll)")
                destination = .skipBecauseExists(path)
            case .cancel:
                DebugLog.shared.record(.queue, "Overwrite cancel \(path)")
                setStatus(id, .cancelled)
                return nil
            }
        case let .ready(output):
            destination = output
        }
        switch destination {
        case let .write(path):
            return (path, prefs)
        case .skipBecauseExists, .skipBecauseReserved:
            setStatus(id, .skipped(Self.skipMessage(destination)))
            return nil
        case let .reject(message):
            setStatus(id, .failed(message))
            return nil
        }
    }

    private func beginConversion(
        id: UUID,
        readPath: String,
        prepared: (path: String, preferences: ConversionPreferences)
    ) async {
        guard let current = items.firstIndex(where: { $0.id == id }), items[current].status.isActive else { return }
        reserved.insert(prepared.path)
        items[current].status = .converting(completed: 0, total: 0)
        DebugLog.shared.record(.queue, "Convert started \(items[current].name)")
        publish()
        await convert(id: id, readPath: readPath, path: prepared.path, preferences: prepared.preferences)
    }

    private func isStillRunning(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return items[index].status.isActive
    }

    /// Asks only when a callback is installed. Otherwise Overwrite replaces the file.
    private func askToReplace(_ path: String) async -> OverwriteAnswer {
        guard let confirmReplace else { return .replace(applyToAll: false) }
        return await confirmReplace(path)
    }

    /// Reading, decoding, recognition, and disk access run in a child task so the
    /// main actor stays free and cancelling the row cancels that work.
    private func convert(
        id: UUID,
        readPath: String,
        path: String,
        preferences: ConversionPreferences
    ) async {
        let services = self.services
        let sink = progressSink
        var spilledDirectory: String?
        let fileName = items.first(where: { $0.id == id })?.name ?? FileIntake.lastComponent(readPath)
        do {
            try Task.checkCancellation()
            let readStarted = Date()
            DebugLog.shared.record(.queue, "Read started \(fileName)")
            let data = try await offMain {
                try await services.read(readPath)
            }
            DebugLog.shared.record(
                .queue,
                "Read finished \(fileName), \(data.count) bytes, \(DebugLogFormatting.duration(since: readStarted))"
            )
            try Task.checkCancellation()
            let work = ConversionWork(
                data: data,
                languages: [preferences.language],
                maxConcurrent: preferences.concurrency,
                italics: preferences.experimentalItalics,
                keepPictures: true,
                progress: { progress in
                    sink.send(id: id, completed: progress.completed, total: progress.total)
                }
            )
            let result = try await offMain {
                try await services.convert(work)
            }
            try Task.checkCancellation()
            let packed = try await offMain {
                ReviewArchive.pack(result)
            }
            spilledDirectory = packed.pictureDirectory
            let timing = preferences.saveTiming
            if timing == .immediately {
                let srt = packed.srt
                let writeStarted = Date()
                DebugLog.shared.record(.queue, "Write started \(fileName) \(path)")
                try await offMain {
                    try await services.write(path, srt)
                }
                DebugLog.shared.record(
                    .queue,
                    "Write finished \(fileName), \(srt.utf8.count) bytes, \(DebugLogFormatting.duration(since: writeStarted))"
                )
            }
            try Task.checkCancellation()
            var document = packed.document
            let savedPath: String?
            if timing == .immediately {
                document.noteSaved()
                savedPath = path
            } else {
                savedPath = nil
            }
            storeReview(
                id: id,
                document: document,
                directory: packed.pictureDirectory,
                plannedPath: path,
                savedPath: savedPath
            )
            spilledDirectory = nil
            if timing == .immediately {
                setStatus(
                    id,
                    .done(
                        cueCount: packed.cueCount,
                        unrecognizedCount: packed.unrecognizedCount,
                        outputPath: path
                    )
                )
            } else {
                setStatus(
                    id,
                    .awaitingReview(
                        cueCount: packed.cueCount,
                        unrecognizedCount: packed.unrecognizedCount,
                        plannedPath: path
                    )
                )
            }
        } catch is CancellationError {
            CuePictureFiles.remove(spilledDirectory)
            reserved.remove(path)
            setStatus(id, .cancelled)
        } catch {
            CuePictureFiles.remove(spilledDirectory)
            reserved.remove(path)
            setStatus(id, .failed(ConversionFailureText.message(for: error)))
        }
    }

    /// The editable cues for a finished file, when this queue kept them.
    public func reviewDocument(for id: UUID) -> CueDocument? {
        heldReviews[id]?.document
    }

    public func setReviewDocument(_ document: CueDocument, for id: UUID) {
        guard heldReviews[id] != nil else { return }
        heldReviews[id]?.document = document
        publish()
    }

    public func reviewPlannedPath(for id: UUID) -> String? {
        heldReviews[id]?.plannedPath
    }

    public func reviewSavedPath(for id: UUID) -> String? {
        heldReviews[id]?.savedPath
    }

    public func reviewPictureDirectory(for id: UUID) -> String? {
        pictureSession.directory(for: id)
    }

    public func hasReview(for id: UUID) -> Bool {
        heldReviews[id] != nil
    }

    /// Writes the current review document. The caller decides whether to ask
    /// about replacing an existing file before this runs.
    public func saveReview(id: UUID, to path: String) async throws {
        guard let current = heldReviews[id]?.document else { return }
        let text = try current.srtText()
        let services = self.services
        let fileName = items.first(where: { $0.id == id })?.name ?? FileIntake.lastComponent(path)
        let writeStarted = Date()
        DebugLog.shared.record(.queue, "Write started \(fileName) \(path)")
        try await offMain {
            try await services.write(path, text)
        }
        DebugLog.shared.record(
            .queue,
            "Write finished \(fileName), \(text.utf8.count) bytes, \(DebugLogFormatting.duration(since: writeStarted))"
        )
        guard var held = heldReviews[id] else { return }
        held.document.noteSaved(current.cues)
        held.savedPath = path
        heldReviews[id] = held
        markSaved(id: id, path: path, document: held.document)
    }

    public func rememberOverwriteAnswer(_ answer: OverwriteAnswer) {
        if let remembered = OverwriteConfirmation.remember(answer) {
            rememberedOverwrite = remembered
        }
    }

    private func storeReview(
        id: UUID,
        document: CueDocument,
        directory: String?,
        plannedPath: String,
        savedPath: String?
    ) {
        heldReviews[id] = HeldReview(document: document, plannedPath: plannedPath, savedPath: savedPath)
        pictureSession.store(directory, for: id)
    }

    private func discardReview(_ id: UUID) {
        heldReviews[id] = nil
        pictureSession.discard(id)
    }

    private func markSaved(id: UUID, path: String, document: CueDocument) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .done, .awaitingReview:
            items[index].status = .done(
                cueCount: document.cues.count,
                unrecognizedCount: document.ocrFailedCount,
                outputPath: path
            )
            publish()
        default:
            break
        }
    }

    private func offMain<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .userInitiated) {
                try await body()
            }
            do {
                guard let value = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func applyProgress(id: UUID, completed: Int, total: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .converting = items[index].status else { return }
        items[index].status = .converting(completed: completed, total: total)
        publish()
    }

    private func setStatus(_ id: UUID, _ status: ConversionStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status.isActive else { return }
        let name = items[index].name
        items[index].status = status
        logOutcome(name: name, id: id, status: status)
        if batchOpen {
            switch status {
            case .done, .awaitingReview: batch.done += 1
            case .failed: batch.failed += 1
            case .cancelled: batch.cancelled += 1
            case .skipped: batch.skipped += 1
            case .waiting, .extracting, .converting: break
            }
        }
        publish()
    }

    private func finishBatchIfIdle() {
        guard batchOpen, pumpTask == nil else { return }
        guard !items.contains(where: \.status.isActive) else { return }
        batchOpen = false
        let outcome = batch
        DebugLog.shared.record(.queue, "Batch finished. \(outcome.notificationBody)")
        onBatchFinished?(outcome)
    }

    private func logOutcome(name: String, id: UUID, status: ConversionStatus) {
        let duration = elapsed(id)
        switch status {
        case let .done(cues, unrecognized, path):
            DebugLog.shared.record(
                .queue,
                "Finished \(name): \(cues) cues, \(unrecognized) OCR failed, \(path), \(duration)"
            )
        case let .awaitingReview(cues, unrecognized, path):
            DebugLog.shared.record(
                .queue,
                "Held for review \(name): \(cues) cues, \(unrecognized) OCR failed, planned \(path), \(duration)"
            )
        case let .failed(message):
            DebugLog.shared.record(.error, "Failed \(name): \(message) (\(duration))", isError: true)
        case .cancelled:
            DebugLog.shared.record(.queue, "Cancelled \(name) (\(duration))")
        case let .skipped(message):
            DebugLog.shared.record(.queue, "Skipped \(name): \(message) (\(duration))")
        case .waiting, .extracting, .converting:
            break
        }
    }

    private func elapsed(_ id: UUID) -> String {
        guard let start = startedAt.removeValue(forKey: id) else { return "n/a" }
        return DebugLogFormatting.duration(since: start)
    }

    private static func byteCount(_ path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else {
            return "size unknown"
        }
        return "\(number.int64Value) bytes"
    }

    private static func fileKind(_ path: String) -> String {
        if FileIntake.isMkv(path) { return "mkv" }
        if FileIntake.isSup(path) { return "sup" }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "file" : ext
    }

    private static func trackSummary(_ tracks: [PGSSubtitleTrack]) -> String {
        if tracks.isEmpty { return "none" }
        return tracks.map { track in
            var text = "\(track.id) \(track.language)"
            if track.forced { text += " forced" }
            if track.isDefault { text += " default" }
            let name = track.name.replacingOccurrences(of: "\n", with: " ")
            if !name.isEmpty { text += " \"\(name)\"" }
            return text
        }.joined(separator: "; ")
    }

    private func publish() {
        onChange?()
    }

    private static func skipMessage(_ destination: OutputDestination) -> String {
        switch destination {
        case let .skipBecauseExists(path):
            let name = (path as NSString).lastPathComponent
            return "\(name) already exists, so this file was skipped."
        case let .skipBecauseReserved(path):
            let name = (path as NSString).lastPathComponent
            return "Another file in this batch is already being saved as \(name), so this one was skipped."
        case .write, .reject:
            return "Skipped."
        }
    }
}

/// A unique folder for one extracted `.sup`. Removed whether conversion finishes, fails, or is cancelled.
private enum TemporaryExtract {
    static func create() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PGS2SRT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        let name = url.lastPathComponent
        do {
            try FileManager.default.removeItem(at: url)
            DebugLog.shared.record(.mkv, "Temp folder removed \(name)")
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            DebugLog.shared.record(.mkv, "Temp folder removal failed \(name): \(detail)", isWarning: true)
        }
    }
}

/// Forwards recognition progress onto the main actor without blocking the reader.
private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var apply: (@Sendable (UUID, Int, Int) -> Void)?

    func setApply(_ apply: @escaping @Sendable (UUID, Int, Int) -> Void) {
        lock.lock()
        self.apply = apply
        lock.unlock()
    }

    func send(id: UUID, completed: Int, total: Int) {
        lock.lock()
        let apply = self.apply
        lock.unlock()
        apply?(id, completed, total)
    }
}
