import Foundation

/// One selected PGS track inside a multi-track MKV row.
public struct ConversionTrack: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var track: PGSSubtitleTrack
    public var status: ConversionStatus

    public init(id: UUID, track: PGSSubtitleTrack, status: ConversionStatus) {
        self.id = id
        self.track = track
        self.status = status
    }
}

/// One `.sup` or `.mkv` file in the window's queue.
public struct ConversionItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sourcePath: String
    public var name: String
    public var status: ConversionStatus

    /// PGS tracks found in an MKV. Nil until the file has been listed.
    public var listedTracks: [PGSSubtitleTrack]?
    /// Track ids checked in the picker. The default track starts checked.
    public var selectedTrackIDs: [Int]
    /// The queue is still reading the track list, so this row waits.
    public var awaitsTrackList: Bool
    /// Two or more PGS tracks are waiting for the picker to close.
    public var awaitsTrackChoice: Bool
    /// The person closed the picker, or this file does not need one.
    public var trackChoiceConfirmed: Bool
    /// One sub-row per selected track when more than one track is converted.
    public var tracks: [ConversionTrack]

    public init(
        id: UUID,
        sourcePath: String,
        name: String,
        status: ConversionStatus,
        listedTracks: [PGSSubtitleTrack]? = nil,
        selectedTrackIDs: [Int] = [],
        awaitsTrackList: Bool = false,
        awaitsTrackChoice: Bool = false,
        trackChoiceConfirmed: Bool = true,
        tracks: [ConversionTrack] = []
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.name = name
        self.status = status
        self.listedTracks = listedTracks
        self.selectedTrackIDs = selectedTrackIDs
        self.awaitsTrackList = awaitsTrackList
        self.awaitsTrackChoice = awaitsTrackChoice
        self.trackChoiceConfirmed = trackChoiceConfirmed
        self.tracks = tracks
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
    public var native: MKVNativeClient

    public init(
        read: @escaping @Sendable (String) async throws -> Data,
        write: @escaping @Sendable (String, String) async throws -> Void,
        fileExists: @escaping @Sendable (String) -> Bool,
        directoryExists: @escaping @Sendable (String) -> Bool,
        listing: DirectoryListing,
        convert: @escaping @Sendable (ConversionWork) async throws -> TranscriptionResult,
        mkv: MKVClient = .live,
        native: MKVNativeClient = .live
    ) {
        self.read = read
        self.write = write
        self.fileExists = fileExists
        self.directoryExists = directoryExists
        self.listing = listing
        self.convert = convert
        self.mkv = mkv
        self.native = native
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
    public var onBatchStarted: (@MainActor () -> Void)?
    /// Throttled batch progress for the Dock icon. This does not rebuild the window.
    public var onMeter: (@MainActor (BatchMeter) -> Void)?
    /// Skip the native reader and use MKVToolNix. `PGS2SRT_FORCE_MKV_FALLBACK=1` turns this on.
    public var forceMKVToolNixFallback: Bool

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
    private var batchIDs: Set<UUID> = []
    private var batchStartedAt: Date?
    private var finishedLine: BatchLine?
    private var hideFinishedLine = false
    private var extractFraction: Double = 0
    private var lastMeter = Date.distantPast
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
        var title: String?
        var trackNumber: Int?
    }

    private var heldReviews: [UUID: HeldReview] = [:]
    private let pictureSession = CuePictureSession()

    public init(preferences: ConversionPreferences = .default, services: ConversionServices) {
        self.storedPreferences = preferences.normalized
        self.services = services
        self.forceMKVToolNixFallback = ProcessInfo.processInfo.environment["PGS2SRT_FORCE_MKV_FALLBACK"] == "1"
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
            finishedLine = nil
            hideFinishedLine = false
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
            var item = ConversionItem(
                id: id,
                sourcePath: path,
                name: name,
                status: .waiting
            )
            if FileIntake.isMkv(path) && chooseTrack == nil {
                item.awaitsTrackList = true
            }
            items.append(item)
            batchIDs.insert(id)
            DebugLog.shared.record(.queue, "Added \(name) (\(Self.byteCount(path)), \(Self.fileKind(path))) \(path)")
            if item.awaitsTrackList {
                scheduleTrackList(id: id, path: path)
            }
        }
        for notice in intake.notices where notice.isFile {
            guard let path = notice.path else { continue }
            let id = UUID()
            items.append(ConversionItem(
                id: id,
                sourcePath: path,
                name: FileIntake.lastComponent(path),
                status: .skipped(notice.message)
            ))
            DebugLog.shared.record(.queue, "Skipped \(notice.message)")
            if batchOpen {
                batchIDs.insert(id)
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

    /// True when Clear Finished has at least one row it can take off the list.
    public var canClearFinished: Bool {
        items.contains { item in
            if !item.tracks.isEmpty {
                return item.tracks.contains { $0.status.isRemovable }
            }
            return item.status.isRemovable
        }
    }

    /// Takes one finished row off the list. Waiting and converting rows are left
    /// alone. This does not delete the `.sup` or the `.srt`.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        if let index = items.firstIndex(where: { $0.tracks.contains { $0.id == id } }) {
            return removeTrack(itemID: items[index].id, trackID: id)
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].status.isRemovable else { return false }
        for track in items[index].tracks {
            discardReview(track.id)
        }
        items.remove(at: index)
        tasks[id] = nil
        discardReview(id)
        if items.isEmpty {
            clearSummary()
        }
        publish()
        return true
    }

    /// Takes one finished track off a multi-track row. The file row leaves when its last track does.
    @discardableResult
    public func removeTrack(itemID: UUID, trackID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        guard let trackIndex = items[index].tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        guard items[index].tracks[trackIndex].status.isRemovable else { return false }
        items[index].tracks.remove(at: trackIndex)
        discardReview(trackID)
        if items[index].tracks.isEmpty {
            items.remove(at: index)
            tasks[itemID] = nil
            discardReview(itemID)
        }
        if items.isEmpty {
            clearSummary()
        }
        publish()
        return true
    }

    /// Checks or unchecks PGS tracks. Ignored once that file has started converting.
    public func setSelectedTracks(id: UUID, trackIDs: [Int]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .waiting = items[index].status else { return }
        items[index].selectedTrackIDs = trackIDs
        publish()
    }

    /// The track popover closed. A multi-track MKV can start with the checked tracks.
    public func confirmTrackSelection(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].awaitsTrackChoice else { return }
        items[index].awaitsTrackChoice = false
        items[index].trackChoiceConfirmed = true
        publish()
        startPump()
    }

    /// Takes every done, failed, skipped, and cancelled row off the list.
    /// Waiting and converting rows stay. Nothing on disk is deleted.
    /// An empty list is the window's drop screen.
    public func clearFinished() {
        var changed = false
        for index in items.indices.reversed() {
            if !items[index].tracks.isEmpty {
                let finished = items[index].tracks.filter(\.status.isRemovable)
                guard !finished.isEmpty else { continue }
                changed = true
                for track in finished {
                    discardReview(track.id)
                }
                items[index].tracks.removeAll { $0.status.isRemovable }
                if items[index].tracks.isEmpty {
                    tasks[items[index].id] = nil
                    discardReview(items[index].id)
                    items.remove(at: index)
                }
            } else if items[index].status.isRemovable {
                changed = true
                tasks[items[index].id] = nil
                discardReview(items[index].id)
                items.remove(at: index)
            }
        }
        guard changed else { return }
        clearSummary()
        if items.isEmpty {
            batchOpen = false
        }
        publish()
    }

    public func dismissBanner(at index: Int) {
        guard banners.indices.contains(index) else { return }
        banners.remove(at: index)
        publish()
    }

    public var hasCancellableWork: Bool {
        items.contains(where: \.status.isActive)
    }

    /// The footer summary. Nil while a single output is running, and after the summary is cleared.
    public var batchLine: BatchLine? {
        if batchOpen {
            let total = outputTotal()
            if total <= 1 { return nil }
            let finished = finishedOutputs
            let current = min(total, max(1, finished + 1))
            return BatchLine(
                text: BatchSummaryText.running(current: current, total: total),
                failed: false,
                running: true
            )
        }
        if hideFinishedLine || items.isEmpty { return nil }
        return finishedLine
    }

    /// Whole-batch Dock inputs. Idle after the batch finishes or is cancelled.
    public var batchMeter: BatchMeter {
        guard batchOpen else { return .idle }
        let total = outputTotal()
        let finished = finishedOutputs
        let remaining = max(0, total - finished)
        let fraction = total > 0 ? (Double(finished) + currentUnitFraction()) / Double(total) : 0
        return BatchMeter(active: true, remaining: remaining, fraction: min(1, max(0, fraction)))
    }

    private var finishedOutputs: Int {
        batch.done + batch.failed + batch.cancelled + batch.skipped
    }

    private func outputTotal() -> Int {
        items.reduce(0) { total, item in
            guard batchIDs.contains(item.id) else { return total }
            return total + (item.tracks.isEmpty ? 1 : item.tracks.count)
        }
    }

    private func currentUnitFraction() -> Double {
        for item in items {
            let statuses = item.tracks.isEmpty ? [item.status] : item.tracks.map(\.status)
            for status in statuses {
                if case let .converting(completed, total) = status, total > 0 {
                    return min(1, Double(completed) / Double(total))
                }
            }
        }
        if items.contains(where: { if case .extracting = $0.status { return true }; return false }) {
            return extractFraction
        }
        return 0
    }

    private func clearSummary() {
        finishedLine = nil
        hideFinishedLine = true
    }

    private func isActive(_ path: String) -> Bool {
        items.contains { $0.sourcePath == path && $0.status.isActive }
    }

    private func ensureBatch() {
        if !batchOpen {
            batch = .zero
            batchOpen = true
            batchIDs.removeAll()
            batchStartedAt = Date()
            extractFraction = 0
            reserved.removeAll()
            rememberedOverwrite = nil
            onBatchStarted?()
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
        items.first { item in
            guard case .waiting = item.status else { return false }
            if item.awaitsTrackList || item.awaitsTrackChoice { return false }
            return true
        }?.id
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

    /// Lists PGS tracks, extracts the chosen ones in one pass, then runs the `.sup` pipeline.
    /// A native read that fails falls back to MKVToolNix when it is installed.
    /// Temporary `.sup` files from that fallback are removed on every way out.
    private func performMKV(id: UUID, source: String, outputFolder: String?) async {
        guard isStillRunning(id) else { return }
        let fileName = FileIntake.lastComponent(source)
        let parsed: [PGSSubtitleTrack]
        do {
            if let listed = items.first(where: { $0.id == id })?.listedTracks {
                parsed = listed
                DebugLog.shared.record(.mkv, "Tracks \(fileName): \(Self.trackSummary(parsed))")
            } else {
                parsed = try await listMKVTracks(source: source, fileName: fileName, log: true)
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].listedTracks = parsed
                }
            }
        } catch is CancellationError {
            setStatus(id, .cancelled)
            return
        } catch {
            setStatus(id, .failed(ConversionFailureText.message(for: error)))
            return
        }
        guard isStillRunning(id) else { return }
        guard let suggested = MKVIdentify.preferredTrack(in: parsed) else {
            setStatus(id, .skipped(MKVCopy.noPGS))
            return
        }

        let chosen = await chooseTracks(id: id, fileName: fileName, parsed: parsed, suggested: suggested)
        guard let chosen else { return }
        if chosen.isEmpty {
            setStatus(id, .skipped(MKVCopy.noTracksSelected))
            return
        }
        let multi = chosen.count > 1
        if multi {
            installTracks(id: id, tracks: chosen)
        }
        guard markExtracting(id) else { return }

        var jobs: [MKVTrackJob] = []
        for track in chosen {
            if !isStillRunning(id) { return }
            let trackID = multi ? trackRowID(itemID: id, trackID: track.id) : nil
            let named = outputSource(source, tracks: chosen, track: track)
            guard let prepared = await resolveDestination(
                id: id,
                trackID: trackID,
                source: named,
                outputFolder: outputFolder
            ) else {
                if !multi || !isStillRunning(id) { return }
                continue
            }
            jobs.append(MKVTrackJob(track: track, trackID: trackID, prepared: prepared))
        }
        guard !jobs.isEmpty, isStillRunning(id) else { return }

        let temp = TempFolder()
        defer { temp.remove() }
        let extracted: [Int: Data]
        do {
            extracted = try await extractChosen(source: source, fileName: fileName, tracks: jobs.map(\.track), temp: temp)
        } catch is CancellationError {
            stopMKV(id, multi: multi, .cancelled)
            return
        } catch {
            let message = ConversionFailureText.message(for: error)
            if multi {
                for job in jobs {
                    if let trackID = job.trackID {
                        setTrackStatus(itemID: id, trackID: trackID, .failed(message))
                    }
                }
                refreshParent(id)
            } else {
                setStatus(id, .failed(message))
            }
            return
        }
        if Task.isCancelled || !isStillRunning(id) {
            stopMKV(id, multi: multi, .cancelled)
            return
        }

        for job in jobs {
            if Task.isCancelled || !isStillRunning(id) {
                stopMKV(id, multi: multi, .cancelled)
                return
            }
            guard let data = extracted[job.track.id] else {
                let message = ConversionFailureText.message(for: MKVFailure.extractFailed)
                if let trackID = job.trackID {
                    setTrackStatus(itemID: id, trackID: trackID, .failed(message))
                } else {
                    setStatus(id, .failed(message))
                }
                continue
            }
            let heading = multi ? reviewHeading(fileName: fileName, track: job.track) : nil
            await beginConversion(
                id: id,
                trackID: job.trackID,
                readPath: source,
                preloaded: data,
                prepared: job.prepared,
                heading: heading
            )
        }
        if multi {
            refreshParent(id)
        }
    }

    private func scheduleTrackList(id: UUID, path: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = FileIntake.lastComponent(path)
            do {
                let tracks = try await self.listMKVTracks(source: path, fileName: name, log: false)
                self.applyListedTracks(id: id, tracks: tracks)
            } catch is CancellationError {
                self.applyListedTracks(id: id, tracks: nil)
            } catch {
                self.applyListedTracks(id: id, tracks: nil)
            }
        }
    }

    private func applyListedTracks(id: UUID, tracks: [PGSSubtitleTrack]?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .waiting = items[index].status else { return }
        items[index].awaitsTrackList = false
        if let tracks {
            items[index].listedTracks = tracks
            if items[index].selectedTrackIDs.isEmpty, let preferred = MKVIdentify.preferredTrack(in: tracks) {
                items[index].selectedTrackIDs = [preferred.id]
            }
            if preferences.chooseMKVTrack && tracks.count >= 2 && chooseTrack == nil {
                items[index].awaitsTrackChoice = true
                items[index].trackChoiceConfirmed = false
            }
        }
        publish()
        startPump()
    }

    private func listMKVTracks(source: String, fileName: String, log: Bool) async throws -> [PGSSubtitleTrack] {
        if !forceMKVToolNixFallback {
            do {
                let started = Date()
                if log {
                    DebugLog.shared.record(.mkv, "Native read started \(fileName)")
                }
                let native = self.services.native
                let tracks = try await offMain {
                    try native.listTracks(source)
                }
                if log {
                    DebugLog.shared.record(
                        .mkv,
                        "Native read finished \(fileName), \(DebugLogFormatting.duration(since: started)), tracks \(Self.trackSummary(tracks))"
                    )
                }
                return tracks
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if services.mkv.locate() == nil {
                    throw error
                }
                if log {
                    DebugLog.shared.record(
                        .mkv,
                        "Fell back to MKVToolNix for \(fileName): \(ConversionFailureText.message(for: error))"
                    )
                }
            }
        } else if log {
            DebugLog.shared.record(.mkv, "Fell back to MKVToolNix for \(fileName): forced")
        }
        guard let tools = services.mkv.locate() else {
            throw MKVReadError.unreadable
        }
        if log {
            DebugLog.shared.record(
                .mkv,
                "MKVToolNix mkvmerge \(tools.mkvmerge), mkvextract \(tools.mkvextract)"
            )
        }
        let started = Date()
        if log {
            DebugLog.shared.record(.mkv, "Identify started \(fileName)")
        }
        let json = try await services.mkv.identify(tools.mkvmerge, source)
        let tracks = try MKVIdentify.tracks(in: json)
        if log {
            DebugLog.shared.record(
                .mkv,
                "Identify finished \(fileName), \(DebugLogFormatting.duration(since: started)), tracks \(Self.trackSummary(tracks))"
            )
        }
        return tracks
    }

    /// Nil means the row was skipped or cancelled. An empty array is "none checked".
    private func chooseTracks(
        id: UUID,
        fileName: String,
        parsed: [PGSSubtitleTrack],
        suggested: PGSSubtitleTrack
    ) async -> [PGSSubtitleTrack]? {
        if preferences.chooseMKVTrack, let chooseTrack {
            DebugLog.shared.record(.mkv, "Asking which track in \(fileName)")
            let choice = await chooseTrack(fileName, parsed, suggested.id)
            if Task.isCancelled || !isStillRunning(id) {
                setStatus(id, .cancelled)
                return nil
            }
            switch choice {
            case let .convert(trackID):
                let track = parsed.first { $0.id == trackID } ?? suggested
                DebugLog.shared.record(.mkv, "Track chosen \(track.id) \(track.language) for \(fileName)")
                return [track]
            case .skip:
                DebugLog.shared.record(.mkv, "Track choice skipped \(fileName)")
                setStatus(id, .skipped(MKVCopy.skippedTrack))
                return nil
            case .cancel:
                DebugLog.shared.record(.mkv, "Track choice cancelled \(fileName)")
                setStatus(id, .cancelled)
                return nil
            }
        }
        if preferences.chooseMKVTrack && parsed.count >= 2 && chooseTrack == nil {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            if !items[index].trackChoiceConfirmed {
                items[index].listedTracks = parsed
                if items[index].selectedTrackIDs.isEmpty {
                    items[index].selectedTrackIDs = [suggested.id]
                }
                items[index].awaitsTrackChoice = true
                items[index].status = .waiting
                publish()
                return nil
            }
            let selected = items[index].selectedTrackIDs
            let chosen = parsed.filter { selected.contains($0.id) }
            DebugLog.shared.record(
                .mkv,
                "Tracks chosen \(chosen.map { String($0.id) }.joined(separator: ",")) for \(fileName)"
            )
            return chosen
        }
        DebugLog.shared.record(.mkv, "Track chosen \(suggested.id) \(suggested.language) for \(fileName)")
        return [suggested]
    }

    private func installTracks(id: UUID, tracks: [PGSSubtitleTrack]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].tracks = tracks.map { track in
            ConversionTrack(id: UUID(), track: track, status: .waiting)
        }
        publish()
    }

    private func trackRowID(itemID: UUID, trackID: Int) -> UUID? {
        items.first { $0.id == itemID }?.tracks.first { $0.track.id == trackID }?.id
    }

    private func outputSource(_ source: String, tracks: [PGSSubtitleTrack], track: PGSSubtitleTrack) -> String {
        let suffix = MKVOutputName.suffixes(for: tracks)[track.id] ?? ""
        if suffix.isEmpty { return source }
        let stem = MKVOutputName.stem(of: source)
        let name = "\(stem).\(suffix).mkv"
        let directory = (source as NSString).deletingLastPathComponent
        if directory.isEmpty || directory == "." { return name }
        return (directory as NSString).appendingPathComponent(name)
    }

    private func reviewHeading(fileName: String, track: PGSSubtitleTrack) -> (title: String, trackNumber: Int) {
        let base = (fileName as NSString).deletingPathExtension
        let title = base.isEmpty ? fileName : base
        return ("\(title) — \(track.displayLanguage)", track.number)
    }

    private func extractChosen(
        source: String,
        fileName: String,
        tracks: [PGSSubtitleTrack],
        temp: TempFolder
    ) async throws -> [Int: Data] {
        let ids = Set(tracks.map(\.id))
        if !forceMKVToolNixFallback {
            do {
                let started = Date()
                DebugLog.shared.record(.mkv, "Native extract started \(fileName) tracks \(ids.sorted())")
                let services = self.services
                let data = try await offMain {
                    try services.native.extract(source, ids) { _, _ in }
                }
                DebugLog.shared.record(
                    .mkv,
                    "Native extract finished \(fileName), \(DebugLogFormatting.duration(since: started))"
                )
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if services.mkv.locate() == nil {
                    throw error
                }
                DebugLog.shared.record(
                    .mkv,
                    "Fell back to MKVToolNix for \(fileName): \(ConversionFailureText.message(for: error))"
                )
            }
        } else {
            DebugLog.shared.record(.mkv, "Fell back to MKVToolNix for \(fileName): forced")
        }
        guard let tools = services.mkv.locate() else {
            throw MKVReadError.unreadable
        }
        let json = try await services.mkv.identify(tools.mkvmerge, source)
        let toolTracks = try MKVIdentify.tracks(in: json)
        let folder = try TemporaryExtract.create()
        temp.url = folder
        var pairs: [(Int, String)] = []
        var paths: [Int: String] = [:]
        for track in tracks {
            let match = toolTracks.first { $0.number == track.number } ?? toolTracks.first { $0.id == track.id }
            guard let match else {
                throw MKVFailure.extractFailed
            }
            let path = folder.appendingPathComponent("\(track.id).sup").path
            pairs.append((match.id, path))
            paths[track.id] = path
        }
        let started = Date()
        DebugLog.shared.record(.mkv, "Extract started \(fileName) tracks \(pairs.map(\.0))")
        try await services.mkv.extractMany(tools.mkvextract, source, pairs)
        let readServices = self.services
        var data: [Int: Data] = [:]
        for (id, path) in paths {
            let bytes = try await offMain {
                try await readServices.read(path)
            }
            data[id] = bytes
        }
        DebugLog.shared.record(
            .mkv,
            "Extract finished \(fileName), \(DebugLogFormatting.duration(since: started))"
        )
        return data
    }

    private func stopMKV(_ id: UUID, multi: Bool, _ status: ConversionStatus) {
        if multi {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            for track in items[index].tracks where track.status.isActive {
                setTrackStatus(itemID: id, trackID: track.id, status)
            }
            refreshParent(id)
        } else {
            setStatus(id, status)
        }
    }

    private func setTrackStatus(itemID: UUID, trackID: UUID, _ status: ConversionStatus) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let trackIndex = items[index].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard items[index].tracks[trackIndex].status.isActive else { return }
        let name = items[index].tracks[trackIndex].track.displayLanguage
        items[index].tracks[trackIndex].status = status
        if batchOpen {
            switch status {
            case .done, .awaitingReview: batch.done += 1
            case .failed: batch.failed += 1
            case .cancelled: batch.cancelled += 1
            case .skipped: batch.skipped += 1
            case .waiting, .extracting, .converting: break
            }
        }
        switch status {
        case .done, .awaitingReview, .failed, .cancelled, .skipped:
            DebugLog.shared.record(.queue, "Track \(name) \(items[index].name) \(Self.statusWord(status))")
        case .waiting, .extracting, .converting:
            break
        }
        refreshParent(itemID)
        publish()
    }

    private func refreshParent(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let tracks = items[index].tracks
        guard !tracks.isEmpty else { return }
        if tracks.contains(where: \.status.isActive) {
            if tracks.contains(where: { if case .converting = $0.status { return true }; return false }) {
                if case .converting = items[index].status {
                    return
                }
                items[index].status = .converting(completed: 0, total: 0)
            } else if case .extracting = items[index].status {
                return
            } else {
                items[index].status = .extracting
            }
            return
        }
        if tracks.contains(where: { if case .done = $0.status { return true }; return false })
            || tracks.contains(where: { if case .awaitingReview = $0.status { return true }; return false })
            || tracks.contains(where: { if case .failed = $0.status { return true }; return false }) {
            items[index].status = .done(cueCount: 0, unrecognizedCount: 0, outputPath: "")
        } else if tracks.contains(where: { if case .cancelled = $0.status { return true }; return false }) {
            items[index].status = .cancelled
        } else if let skipped = tracks.first(where: { if case .skipped = $0.status { return true }; return false }) {
            items[index].status = skipped.status
        }
    }

    private static func statusWord(_ status: ConversionStatus) -> String {
        switch status {
        case .done: return "done"
        case .awaitingReview: return "held for review"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .skipped: return "skipped"
        case .waiting, .extracting, .converting: return "working"
        }
    }

    private func markExtracting(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].status.isActive else { return false }
        items[index].status = .extracting
        publish()
        return true
    }

    private func resolveDestination(
        id: UUID,
        trackID: UUID? = nil,
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
                stopMKV(id, multi: trackID != nil, .cancelled)
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
                stopMKV(id, multi: trackID != nil, .cancelled)
                return nil
            }
        case let .ready(output):
            destination = output
        }
        switch destination {
        case let .write(path):
            return (path, prefs)
        case .skipBecauseExists, .skipBecauseReserved:
            noteTerminal(id, trackID: trackID, .skipped(Self.skipMessage(destination)))
            return nil
        case let .reject(message):
            noteTerminal(id, trackID: trackID, .failed(message))
            return nil
        }
    }

    private func noteTerminal(_ id: UUID, trackID: UUID?, _ status: ConversionStatus) {
        if let trackID {
            setTrackStatus(itemID: id, trackID: trackID, status)
        } else {
            setStatus(id, status)
        }
    }

    private func beginConversion(
        id: UUID,
        trackID: UUID? = nil,
        readPath: String,
        preloaded: Data? = nil,
        prepared: (path: String, preferences: ConversionPreferences),
        heading: (title: String, trackNumber: Int)? = nil
    ) async {
        guard isStillRunning(id) else { return }
        reserved.insert(prepared.path)
        if let trackID {
            setTrackStatus(itemID: id, trackID: trackID, .converting(completed: 0, total: 0))
            let name = items.first { $0.id == id }?.name ?? ""
            DebugLog.shared.record(.queue, "Convert started \(name)")
        } else if let current = items.firstIndex(where: { $0.id == id }) {
            items[current].status = .converting(completed: 0, total: 0)
            DebugLog.shared.record(.queue, "Convert started \(items[current].name)")
            publish()
        } else {
            return
        }
        await convert(
            id: id,
            trackID: trackID,
            readPath: readPath,
            preloaded: preloaded,
            path: prepared.path,
            preferences: prepared.preferences,
            heading: heading
        )
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
        trackID: UUID? = nil,
        readPath: String,
        preloaded: Data? = nil,
        path: String,
        preferences: ConversionPreferences,
        heading: (title: String, trackNumber: Int)? = nil
    ) async {
        let services = self.services
        let sink = progressSink
        let reviewID = trackID ?? id
        var spilledDirectory: String?
        let fileName = items.first(where: { $0.id == id })?.name ?? FileIntake.lastComponent(readPath)
        do {
            try Task.checkCancellation()
            let data: Data
            if let preloaded {
                data = preloaded
            } else {
                let readStarted = Date()
                DebugLog.shared.record(.queue, "Read started \(fileName)")
                data = try await offMain {
                    try await services.read(readPath)
                }
                DebugLog.shared.record(
                    .queue,
                    "Read finished \(fileName), \(data.count) bytes, \(DebugLogFormatting.duration(since: readStarted))"
                )
            }
            try Task.checkCancellation()
            let work = ConversionWork(
                data: data,
                languages: [preferences.language],
                maxConcurrent: preferences.concurrency,
                italics: preferences.experimentalItalics,
                keepPictures: true,
                progress: { progress in
                    sink.send(id: reviewID, completed: progress.completed, total: progress.total)
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
                id: reviewID,
                document: document,
                directory: packed.pictureDirectory,
                plannedPath: path,
                savedPath: savedPath,
                title: heading?.title,
                trackNumber: heading?.trackNumber
            )
            spilledDirectory = nil
            if timing == .immediately {
                noteTerminal(
                    id,
                    trackID: trackID,
                    .done(
                        cueCount: packed.cueCount,
                        unrecognizedCount: packed.unrecognizedCount,
                        outputPath: path
                    )
                )
            } else {
                noteTerminal(
                    id,
                    trackID: trackID,
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
            noteTerminal(id, trackID: trackID, .cancelled)
        } catch {
            CuePictureFiles.remove(spilledDirectory)
            reserved.remove(path)
            noteTerminal(id, trackID: trackID, .failed(ConversionFailureText.message(for: error)))
        }
    }

    /// The editable cues for a finished file, when this queue kept them.
    public func reviewDocument(for id: UUID) -> CueDocument? {
        heldReviews[id]?.document
    }

    public func reviewTrackNumber(for id: UUID) -> Int? {
        heldReviews[id]?.trackNumber
    }

    public func reviewTitle(for id: UUID) -> String? {
        heldReviews[id]?.title
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
        savedPath: String?,
        title: String? = nil,
        trackNumber: Int? = nil
    ) {
        heldReviews[id] = HeldReview(
            document: document,
            plannedPath: plannedPath,
            savedPath: savedPath,
            title: title,
            trackNumber: trackNumber
        )
        pictureSession.store(directory, for: id)
    }

    private func discardReview(_ id: UUID) {
        heldReviews[id] = nil
        pictureSession.discard(id)
    }

    private func markSaved(id: UUID, path: String, document: CueDocument) {
        let updated = ConversionStatus.done(
            cueCount: document.cues.count,
            unrecognizedCount: document.ocrFailedCount,
            outputPath: path
        )
        if let index = items.firstIndex(where: { $0.tracks.contains { $0.id == id } }),
           let trackIndex = items[index].tracks.firstIndex(where: { $0.id == id }) {
            switch items[index].tracks[trackIndex].status {
            case .done, .awaitingReview:
                items[index].tracks[trackIndex].status = updated
                refreshParent(items[index].id)
                publish()
            default:
                break
            }
            return
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .done, .awaitingReview:
            items[index].status = updated
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
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard case .converting = items[index].status else { return }
            items[index].status = .converting(completed: completed, total: total)
            publish()
            return
        }
        for index in items.indices {
            guard let trackIndex = items[index].tracks.firstIndex(where: { $0.id == id }) else { continue }
            guard case .converting = items[index].tracks[trackIndex].status else { return }
            items[index].tracks[trackIndex].status = .converting(completed: completed, total: total)
            publish()
            return
        }
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
        let elapsed = Date().timeIntervalSince(batchStartedAt ?? Date())
        let text = BatchSummaryText.finished(outcome, elapsed: elapsed)
        finishedLine = BatchLine(text: text, failed: outcome.failed > 0, running: false)
        hideFinishedLine = false
        DebugLog.shared.record(.queue, "Batch finished. \(text)")
        onBatchFinished?(outcome)
        publish()
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
        onMeter?(batchMeter)
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

private struct MKVTrackJob {
    var track: PGSSubtitleTrack
    var trackID: UUID?
    var prepared: (path: String, preferences: ConversionPreferences)
}

private final class TempFolder: @unchecked Sendable {
    var url: URL?

    func remove() {
        guard let url else { return }
        self.url = nil
        TemporaryExtract.remove(url)
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
