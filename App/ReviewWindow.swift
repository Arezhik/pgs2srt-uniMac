import AppKit
import SwiftUI
import PGSCore

enum ReviewScope: String, Hashable {
    case all
    case problems
    case edited
}

struct ReviewRowSummary: Equatable {
    var statusText: String
    var badge: ReviewProblemBadge?
    /// Hold-for-review rows use the blue Review button until the first save.
    var prominentReview: Bool
    var canReveal: Bool
    var needsWriting: Bool
    var hasUnsavedEdits: Bool
}

enum ReviewFormat {
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func cues(_ count: Int) -> String {
        count == 1 ? "1 cue" : "\(grouped(count)) cues"
    }

    static func title(for name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        if ext == "sup" || ext == "mkv" || ext == "srt" {
            let base = url.deletingPathExtension().lastPathComponent
            if !base.isEmpty { return base }
        }
        let base = url.lastPathComponent
        return base.isEmpty ? name : base
    }

    static func subtitle(cueCount: Int, edited: Int, needsWriting: Bool) -> String {
        var parts = [cues(cueCount)]
        if edited > 0 { parts.append("Edited") }
        if needsWriting { parts.append("not saved yet") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class ReviewWindowState: ObservableObject, Identifiable {
    let id: UUID
    @Published var itemID: UUID

    init(itemID: UUID) {
        self.id = UUID()
        self.itemID = itemID
    }
}

/// The open review for one queue row. The document itself lives on the queue.
@MainActor
final class ReviewFileModel: ObservableObject {
    let itemID: UUID
    private let queue: ConversionQueue
    private let onChange: () -> Void
    @Published var scope: ReviewScope = .all
    @Published var selection: Set<UUID> = []
    @Published var searchText = ""
    @Published var showPicturesInList = false
    @Published private(set) var revision = 0
    private var stickyProblemIDs: Set<UUID>?
    private var suppressedGroupIDs: Set<UUID> = []
    private var didSelectInitial = false

    init(itemID: UUID, queue: ConversionQueue, onChange: @escaping () -> Void) {
        self.itemID = itemID
        self.queue = queue
        self.onChange = onChange
    }

    var document: CueDocument {
        queue.reviewDocument(for: itemID) ?? .empty
    }

    var plannedPath: String { queue.reviewPlannedPath(for: itemID) ?? "" }
    var savedPath: String? { queue.reviewSavedPath(for: itemID) }
    var pictureDirectory: String? { queue.reviewPictureDirectory(for: itemID) }

    var summary: ReviewRowSummary {
        let document = document
        let saved = savedPath
        let cueText = ReviewFormat.cues(document.cues.count)
        let status: String
        if saved == nil {
            status = "Ready to review · \(cueText) · not saved yet"
        } else {
            let name = URL(fileURLWithPath: saved ?? "").lastPathComponent
            var text = "Done · \(cueText)"
            if document.ocrFailedCount > 0 {
                let failed = document.ocrFailedCount == 1 ? "1 [OCR failed]" : "\(document.ocrFailedCount) [OCR failed]"
                text += " · \(failed)"
            }
            text += " · \(name)"
            if document.needsWriting {
                text += " · not saved yet"
            }
            status = text
        }
        return ReviewRowSummary(
            statusText: status,
            badge: ReviewProblemBadge.make(ocrFailed: document.ocrFailedCount, lowConfidence: document.lowConfidenceCount),
            prominentReview: saved == nil,
            canReveal: saved != nil,
            needsWriting: document.needsWriting,
            hasUnsavedEdits: document.hasUnsavedEdits
        )
    }

    var orderedSelection: [ReviewCue] {
        let ids = selection
        return document.cues.filter { ids.contains($0.id) }
    }

    var selectedGroup: WordByWordGroup? {
        let ids = Set(orderedSelection.map(\.id))
        guard ids.count >= 2 else { return nil }
        return document.wordByWordGroups().first { Set($0.cueIDs) == ids }
    }

    var canMerge: Bool {
        if document.canMerge(ids: orderedSelection.map(\.id)) { return true }
        guard orderedSelection.count == 1, let only = orderedSelection.first,
              let index = document.cues.firstIndex(where: { $0.id == only.id }),
              index + 1 < document.cues.count else { return false }
        return true
    }

    func visibleCues() -> [ReviewCue] {
        let document = document
        let base: [ReviewCue]
        switch scope {
        case .all:
            base = document.cues
        case .problems:
            let sticky = stickyProblemIDs ?? []
            base = document.cues.filter { sticky.contains($0.id) }
        case .edited:
            base = document.cues.filter(\.isEdited)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.listPrimaryText.localizedCaseInsensitiveContains(query)
                || $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    func problemScopeCount() -> Int {
        if scope == .problems, let stickyProblemIDs {
            let alive = Set(document.cues.map(\.id))
            return stickyProblemIDs.intersection(alive).count
        }
        return document.problemCues.count
    }

    func selectInitialIfNeeded() {
        guard !didSelectInitial else { return }
        didSelectInitial = true
        if let problem = document.problemCues.first {
            selection = [problem.id]
        } else if let first = document.cues.first {
            selection = [first.id]
        }
    }

    func setScope(_ scope: ReviewScope) {
        self.scope = scope
        if scope == .problems {
            stickyProblemIDs = Set(document.problemCues.map(\.id))
        } else {
            stickyProblemIDs = nil
        }
    }

    func moveSelection(by step: Int) {
        let ids = visibleCues().map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = orderedSelection.first?.id, let index = ids.firstIndex(of: current) else {
            selection = [ids[0]]
            return
        }
        let next = index + step
        guard ids.indices.contains(next) else { return }
        selection = [ids[next]]
    }

    func moveProblem(by step: Int) {
        let ids = document.problemCues.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = orderedSelection.first?.id, let index = ids.firstIndex(of: current) else {
            selection = [step < 0 ? ids[ids.count - 1] : ids[0]]
            return
        }
        var next = index + step
        if next < 0 { next = ids.count - 1 }
        if next >= ids.count { next = 0 }
        selection = [ids[next]]
    }

    func find(step: Int) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let matches = document.cues.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.listPrimaryText.localizedCaseInsensitiveContains(query)
        }.map(\.id)
        guard !matches.isEmpty else { return }
        guard let current = orderedSelection.first?.id, let index = matches.firstIndex(of: current) else {
            selection = [matches[0]]
            return
        }
        var next = index + step
        if next < 0 { next = matches.count - 1 }
        if next >= matches.count { next = 0 }
        selection = [matches[next]]
    }

    func setText(id: UUID, text: String) {
        update { $0.setText(id: id, text: text) }
    }

    func revertText() {
        update { $0.revertCoalescedText() }
    }

    func endCoalescing() {
        var document = document
        guard document.endTextCoalescing() else { return }
        queue.setReviewDocument(document, for: itemID)
        revision += 1
        onChange()
    }

    func setTiming(id: UUID, startPTS: UInt32, endPTS: UInt32) {
        update { document in
            try? document.setTiming(id: id, startPTS: startPTS, endPTS: endPTS)
        }
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let previous = document.cues.map(\.id)
        let anchor = previous.firstIndex { ids.contains($0) } ?? 0
        update { document in
            _ = document.delete(ids: ids)
        }
        let remaining = document.cues.map(\.id)
        if remaining.isEmpty {
            selection = []
        } else {
            let index = min(anchor, remaining.count - 1)
            selection = [remaining[index]]
        }
    }

    func mergeSelection() {
        let chosen = orderedSelection.map(\.id)
        let ids: [UUID]
        if chosen.count >= 2 {
            ids = chosen
        } else if let only = chosen.first,
                  let index = document.cues.firstIndex(where: { $0.id == only }),
                  index + 1 < document.cues.count {
            ids = [only, document.cues[index + 1].id]
        } else {
            return
        }
        var created: UUID?
        update { document in
            created = document.merge(ids: ids)
        }
        if let created {
            if var sticky = stickyProblemIDs, ids.contains(where: { sticky.contains($0) }) {
                sticky.insert(created)
                stickyProblemIDs = sticky
            }
            selection = [created]
        }
    }

    func mergeAllGroups() {
        update { document in
            _ = document.mergeAllWordByWordGroups()
        }
        if scope == .problems {
            stickyProblemIDs = Set(document.problemCues.map(\.id))
        }
        if let first = document.cues.first {
            selection = [first.id]
        }
    }

    func keepGroupSeparate(_ id: UUID) {
        suppressedGroupIDs.insert(id)
        if let first = orderedSelection.first {
            selection = [first.id]
        }
    }

    func selectGroup(_ ids: [UUID]) {
        selection = Set(ids)
    }

    func isGroupSuppressed(_ id: UUID) -> Bool {
        suppressedGroupIDs.contains(id)
    }

    func undo() {
        update { $0.undo() }
    }

    func redo() {
        update { $0.redo() }
    }

    func discardUnsavedEdits() {
        update { $0.discardUnsavedEdits() }
    }

    /// Save updated the queue's copy. Refresh the window without writing again.
    func noteExternalChange() {
        revision += 1
        onChange()
    }

    private func update(_ mutate: (inout CueDocument) -> Void) {
        var document = document
        mutate(&document)
        queue.setReviewDocument(document, for: itemID)
        revision += 1
        onChange()
    }
}

struct ReviewActions {
    var save: () -> Void
    var saveAs: () -> Void
    var saveAll: () -> Void
    var canSaveAll: Bool
    var undo: () -> Void
    var redo: () -> Void
    var canUndo: Bool
    var canRedo: Bool
    var merge: () -> Void
    var canMerge: Bool
    var deleteCues: () -> Void
    var canDelete: Bool
    var previousCue: () -> Void
    var nextCue: () -> Void
    var nextProblem: () -> Void
    var previousProblem: () -> Void
    var canStepProblem: Bool
    var nextFile: () -> Void
    var canNextFile: Bool
    var showAll: () -> Void
    var showProblems: () -> Void
    var showEdited: () -> Void
    var togglePictures: () -> Void
    var showPictures: Bool
    var findNext: () -> Void
    var findPrevious: () -> Void
}

struct QueueActions {
    var review: () -> Void
    var reviewNewWindow: () -> Void
    var canReview: Bool
}

private struct ReviewActionsKey: FocusedValueKey {
    typealias Value = ReviewActions
}

private struct QueueActionsKey: FocusedValueKey {
    typealias Value = QueueActions
}

extension FocusedValues {
    var reviewActions: ReviewActions? {
        get { self[ReviewActionsKey.self] }
        set { self[ReviewActionsKey.self] = newValue }
    }

    var queueActions: QueueActions? {
        get { self[QueueActionsKey.self] }
        set { self[QueueActionsKey.self] = newValue }
    }
}

struct ReviewRoot: View {
    var windowID: UUID?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let windowID, let state = model.reviewWindows.first(where: { $0.id == windowID }) {
            ReviewScreen(state: state)
        } else {
            Text("Nothing to review")
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

private struct ReviewScreen: View {
    @ObservedObject var state: ReviewWindowState
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let file = model.reviewFile(for: state.itemID) {
            ReviewEditor(file: file, state: state)
                .id(file.itemID)
        } else {
            Text("This file is no longer in the queue.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ReviewEditor: View {
    @ObservedObject var file: ReviewFileModel
    @ObservedObject var state: ReviewWindowState
    @EnvironmentObject private var model: AppModel
    @State private var focusRequest = 0
    @State private var editorActive = false

    var body: some View {
        let itemName = model.items.first { $0.id == file.itemID }?.name ?? "Subtitles"
        let summary = file.summary
        let document = file.document
        VStack(spacing: 0) {
            NavigationSplitView {
                cueColumn
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
            } detail: {
                detail
            }
            .navigationTitle(ReviewFormat.title(for: itemName))
            .navigationSubtitle(ReviewFormat.subtitle(
                cueCount: document.cues.count,
                edited: document.editedCount,
                needsWriting: summary.needsWriting
            ))
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .background {
            ReviewWindowInstaller(
                isDirty: { file.document.hasUnsavedEdits },
                isDocumentEdited: summary.hasUnsavedEdits,
                onKey: { model.noteReviewWindowKey(state.id) },
                onClose: { model.closeReviewWindow(state.id) },
                onAttemptClose: { completion in
                    Task { @MainActor in
                        let host = NSApp.keyWindow
                        let allowed = await model.resolveUnsavedEdits(for: file.itemID, host: host)
                        completion(allowed)
                    }
                }
            )
            ReturnToEditCatcher(enabled: file.orderedSelection.count == 1) {
                focusRequest += 1
            }
        }
        .searchable(text: $file.searchText, placement: .toolbar, prompt: "Search text")
        .toolbar { toolbar }
        .focusedSceneValue(\.reviewActions, actions)
        .onAppear {
            file.selectInitialIfNeeded()
            model.noteReviewWindowKey(state.id)
        }
        .onChange(of: file.selection) { _ in
            file.endCoalescing()
        }
    }

    private var actions: ReviewActions {
        let document = file.document
        return ReviewActions(
            save: { Task { await model.saveReview(itemID: file.itemID, host: NSApp.keyWindow) } },
            saveAs: { Task { await model.saveReviewAs(itemID: file.itemID, host: NSApp.keyWindow) } },
            saveAll: { Task { await model.saveAllReviewed() } },
            canSaveAll: model.hasReviewsNeedingSave,
            undo: { file.undo() },
            redo: { file.redo() },
            canUndo: document.canUndo,
            canRedo: document.canRedo,
            merge: { file.mergeSelection() },
            canMerge: file.canMerge,
            deleteCues: { file.deleteSelection() },
            canDelete: !file.selection.isEmpty,
            previousCue: { file.moveSelection(by: -1) },
            nextCue: { file.moveSelection(by: 1) },
            nextProblem: { file.moveProblem(by: 1) },
            previousProblem: { file.moveProblem(by: -1) },
            canStepProblem: !document.problemCues.isEmpty,
            nextFile: { goToNextFile() },
            canNextFile: model.nextReviewFile(after: file.itemID) != nil,
            showAll: { file.setScope(.all) },
            showProblems: { file.setScope(.problems) },
            showEdited: { file.setScope(.edited) },
            togglePictures: { file.showPicturesInList.toggle() },
            showPictures: file.showPicturesInList,
            findNext: { file.find(step: 1) },
            findPrevious: { file.find(step: -1) }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { file.moveSelection(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous cue (⌥⌘↑)")
            .disabled(file.document.cues.isEmpty)
            Button { file.moveSelection(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next cue (⌥⌘↓)")
            .disabled(file.document.cues.isEmpty)
            Button { file.moveProblem(by: 1) } label: {
                Label("Next Problem", systemImage: "exclamationmark.triangle")
            }
            .disabled(file.document.problemCues.isEmpty)
        }
        ToolbarItemGroup {
            Button { file.mergeSelection() } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .disabled(!file.canMerge)
            .help("Merge cues (⌘K)")
            Button { file.deleteSelection() } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(file.selection.isEmpty)
            .help("Delete cue (⌘⌫)")
            if model.finishedReviewCount >= 2 {
                HStack(spacing: 8) {
                    batchLabel
                    Button("Next File") { goToNextFile() }
                        .disabled(model.nextReviewFile(after: file.itemID) == nil)
                }
            }
            Button {
                Task { await model.saveReview(itemID: file.itemID, host: NSApp.keyWindow) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save (⌘S)")
        }
    }

    @ViewBuilder
    private var batchLabel: some View {
        if let position = model.batchPosition(for: file.itemID) {
            Text("File \(position.index) of \(position.total) to review")
                .foregroundStyle(.secondary)
        } else if let total = model.batchPosition(for: model.nextReviewFile(after: file.itemID) ?? file.itemID)?.total, total > 0 {
            Text("\(total) to review")
                .foregroundStyle(.secondary)
        }
    }

    private var cueColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scope", selection: Binding(
                get: { file.scope },
                set: { file.setScope($0) }
            )) {
                Text("All \(ReviewFormat.grouped(file.document.cues.count))").tag(ReviewScope.all)
                Text("Problems \(ReviewFormat.grouped(file.problemScopeCount()))").tag(ReviewScope.problems)
                Text("Edited \(ReviewFormat.grouped(file.document.editedCount))").tag(ReviewScope.edited)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Scope")
            .padding(.horizontal, 10)
            .padding(.top, 8)

            let marks = groupMarks()
            ScrollViewReader { proxy in
                List(file.visibleCues(), selection: $file.selection) { cue in
                    CueListRow(
                        cue: cue,
                        number: file.document.cueNumber(of: cue.id) ?? 0,
                        edge: marks.edge[cue.id],
                        groupIDs: marks.leadIDs[cue.id],
                        showPicture: file.showPicturesInList,
                        directory: file.pictureDirectory,
                        onSelectGroup: { file.selectGroup($0) }
                    )
                    .tag(cue.id)
                    .id(cue.id)
                }
                .listStyle(.inset)
                .onChange(of: file.orderedSelection.first?.id) { id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }

            if file.scope == .problems {
                Text("Showing \(file.visibleCues().count) of \(file.document.cues.count) cues. Fixed cues stay in this list until you switch to All, so the rows don't jump while you work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let group = file.selectedGroup, !file.isGroupSuppressed(group.id) {
            MergeOffer(file: file, group: group)
        } else if file.orderedSelection.count > 1 {
            multiDetail
        } else if let cue = file.orderedSelection.first {
            CueDetail(
                file: file,
                cue: cue,
                focusRequest: focusRequest,
                editorActive: $editorActive,
                onCommit: {
                    file.endCoalescing()
                    file.moveSelection(by: 1)
                    focusRequest += 1
                }
            )
        } else {
            Text("Select a cue")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var multiDetail: some View {
        VStack(spacing: 12) {
            Text("\(file.orderedSelection.count) cues selected")
                .font(.title3)
            Button("Merge \(file.orderedSelection.count) Cues") { file.mergeSelection() }
                .disabled(!file.canMerge)
            Button("Delete") { file.deleteSelection() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        let document = file.document
        return HStack(spacing: 14) {
            Text(ReviewFormat.cues(document.cues.count))
            if document.ocrFailedCount > 0 {
                Label("\(document.ocrFailedCount) OCR failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(document.ocrFailedCount) OCR failed")
            }
            if document.lowConfidenceCount > 0 {
                Label("\(document.lowConfidenceCount) low confidence", systemImage: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(document.lowConfidenceCount) low confidence")
            }
            if document.editedCount > 0 {
                Label("\(document.editedCount) edited", systemImage: "pencil.circle.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("\(document.editedCount) edited")
            }
            let groups = document.wordByWordGroups().count
            if groups > 0 {
                Label("\(groups) word-by-word groups", systemImage: "rectangle.stack")
                    .accessibilityLabel("\(groups) word-by-word groups")
            }
            Spacer()
            statusTrailing
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if file.orderedSelection.count > 1 {
            Text("\(file.orderedSelection.count) selected")
        } else if let id = file.orderedSelection.first?.id {
            let problems = file.document.problemCues
            if let index = problems.firstIndex(where: { $0.id == id }) {
                Text("Problem \(index + 1) of \(problems.count)")
            } else if !problems.isEmpty {
                Text("Next problem ⌘'")
            }
        }
    }

    private func goToNextFile() {
        guard let next = model.nextReviewFile(after: file.itemID) else { return }
        let host = NSApp.keyWindow
        Task { @MainActor in
            let allowed = await model.resolveUnsavedEdits(for: file.itemID, host: host)
            guard allowed else { return }
            state.itemID = next
        }
    }

    private func groupMarks() -> GroupMarks {
        var marks = GroupMarks()
        for group in file.document.wordByWordGroups() {
            for (offset, id) in group.cueIDs.enumerated() {
                if offset == 0 {
                    marks.edge[id] = .first
                    marks.leadIDs[id] = group.cueIDs
                } else if offset == group.cueIDs.count - 1 {
                    marks.edge[id] = .last
                } else {
                    marks.edge[id] = .middle
                }
            }
        }
        return marks
    }
}

private struct GroupMarks {
    var edge: [UUID: GroupEdge] = [:]
    var leadIDs: [UUID: [UUID]] = [:]
}

private enum GroupEdge {
    case first, middle, last
}

private struct CueListRow: View {
    var cue: ReviewCue
    var number: Int
    var edge: GroupEdge?
    var groupIDs: [UUID]?
    var showPicture: Bool
    var directory: String?
    var onSelectGroup: ([UUID]) -> Void
    @State private var thumb: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            bracket
            if showPicture {
                picture
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    flag
                    Text("\(number)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                    Text(cue.listPrimaryText)
                        .lineLimit(2)
                        .font(cue.showsOCRFailure ? Font.body.italic() : Font.body)
                        .foregroundStyle(textColor)
                    if let groupIDs {
                        Button {
                            onSelectGroup(groupIDs)
                        } label: {
                            Text("Word-by-word · \(groupIDs.count)")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Word-by-word group of \(groupIDs.count)")
                    }
                }
                Text("\(SRTWriter.timestamp(pts: cue.startPTS)) → \(SRTWriter.timestamp(pts: cue.endPTS))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
        .task(id: showPicture ? cue.pictureID : nil) {
            await loadThumb()
        }
    }

    private var textColor: Color {
        if cue.showsOCRFailure { return .red }
        if cue.showsLowConfidence { return .orange }
        return .primary
    }

    @ViewBuilder
    private var flag: some View {
        if cue.showsOCRFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("OCR failed")
        } else if cue.showsLowConfidence {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Low confidence")
        } else if cue.isEdited {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("Edited")
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var bracket: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(edge == nil ? Color.clear : Color.secondary.opacity(0.55))
            .frame(width: 3)
            .padding(.vertical, edge == .first ? 4 : (edge == .last ? 4 : 0))
    }

    @ViewBuilder
    private var picture: some View {
        ZStack {
            Checkerboard()
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 72, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }

    private func loadThumb() async {
        guard showPicture, let pictureID = cue.pictureID, let directory else {
            thumb = nil
            return
        }
        let picture = await Task.detached(priority: .utility) {
            CuePictureFiles.read(id: pictureID, from: directory)
        }.value
        thumb = picture.flatMap { CueImageRenderer.image(from: $0) }
    }
}

private struct CueDetail: View {
    @ObservedObject var file: ReviewFileModel
    var cue: ReviewCue
    var focusRequest: Int
    @Binding var editorActive: Bool
    var onCommit: () -> Void

    var body: some View {
        let number = file.document.cueNumber(of: cue.id) ?? 0
        let neighbors = file.document.neighbors(of: cue.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Cue \(number)")
                        .font(.title3)
                    flagCapsule
                    Spacer()
                }
                pictureBlock
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Text")
                            .font(.headline)
                        Spacer()
                        Text(cue.showsOCRFailure ? "Return: save & next cue · ⌥Return: line break · Esc: revert" : "Return: save & next cue · ⌥Return: line break")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ZStack(alignment: .topLeading) {
                        CueTextEditor(
                            cueID: cue.id,
                            text: cue.text,
                            focusRequest: focusRequest,
                            onTextChange: { file.setText(id: cue.id, text: $0) },
                            onCommit: onCommit,
                            onRevert: { file.revertText() },
                            onDeleteCue: { file.deleteSelection() },
                            onUndo: { file.undo() },
                            onRedo: { file.redo() },
                            onFocus: { editorActive = $0 },
                            onEndCoalescing: { file.endCoalescing() }
                        )
                        .frame(minHeight: 64, maxHeight: 96)
                        if cue.text.isEmpty {
                            Text("Type the text shown in the picture")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    CueTimeField(title: "Start", pts: cue.startPTS) { next in
                        file.setTiming(id: cue.id, startPTS: next, endPTS: max(next, cue.endPTS))
                    }
                    CueTimeField(title: "End", pts: cue.endPTS) { next in
                        file.setTiming(id: cue.id, startPTS: min(cue.startPTS, next), endPTS: next)
                    }
                    CueDurationField(title: "Duration", duration: cue.durationPTS) { next in
                        file.setTiming(id: cue.id, startPTS: cue.startPTS, endPTS: CueClock.end(start: cue.startPTS, duration: next))
                    }
                }
                around(neighbors)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var flagCapsule: some View {
        if cue.showsOCRFailure {
            // Retry OCR (issue #27) belongs beside this capsule.
            Label("OCR failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .accessibilityLabel("OCR failed. \(cue.failureMessage ?? "No text recognized")")
        } else if cue.showsLowConfidence, let percent = cue.lowConfidencePercent {
            // Other readings and Mark as Correct (issue #19) belong beside this capsule.
            Label("Low confidence · \(percent)%", systemImage: "questionmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .accessibilityLabel("Low confidence, \(percent) percent")
        }
    }

    private var pictureBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Original picture")
                .font(.headline)
            CuePictureWell(pictureID: cue.pictureID, directory: file.pictureDirectory)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
        }
    }

    private func around(_ neighbors: (previous: ReviewCue?, current: ReviewCue?, next: ReviewCue?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Around this cue")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                if let previous = neighbors.previous {
                    neighborLine(previous, current: false)
                }
                neighborLine(cue, current: true)
                if let next = neighbors.next {
                    neighborLine(next, current: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func neighborLine(_ cue: ReviewCue, current: Bool) -> some View {
        let number = file.document.cueNumber(of: cue.id) ?? 0
        return HStack {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            Text(cue.listPrimaryText)
                .lineLimit(1)
                .fontWeight(current ? .semibold : .regular)
                .font(cue.showsOCRFailure ? Font.body.italic() : Font.body)
            Spacer()
            Text(SRTWriter.timestamp(pts: cue.startPTS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct MergeOffer: View {
    @ObservedObject var file: ReviewFileModel
    var group: WordByWordGroup

    var body: some View {
        let cues = file.document.cues.filter { group.cueIDs.contains($0.id) }
        let count = cues.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(count) Cues Selected")
                        .font(.title3)
                    Text("Word-by-word reveal · \(rangeText(cues))")
                        .foregroundStyle(.secondary)
                }
                Text("Original pictures")
                    .font(.headline)
                VStack(spacing: 8) {
                    ForEach(cues) { cue in
                        HStack(alignment: .center, spacing: 10) {
                            Text("\(file.document.cueNumber(of: cue.id) ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            CuePictureWell(pictureID: cue.pictureID, directory: file.pictureDirectory)
                                .frame(height: 48)
                            Text(cue.text)
                                .lineLimit(2)
                            Spacer()
                            Text("\(SRTWriter.timestamp(pts: cue.startPTS)) → \(SRTWriter.timestamp(pts: cue.endPTS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Merge into one cue? Keeps the last line's text and runs from the first cue's start to the last cue's end.")
                    if let first = cues.first, let last = cues.last {
                        Text("Result: “\(last.text)” · \(SRTWriter.timestamp(pts: first.startPTS)) → \(SRTWriter.timestamp(pts: last.endPTS))")
                            .font(.callout)
                    }
                    HStack {
                        Button("Merge \(count) Cues") { file.mergeSelection() }
                        Button("Keep as Reveal") { file.keepGroupSeparate(group.id) }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("Or keep them separate")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep as Reveal") { file.keepGroupSeparate(group.id) }
                    if file.document.wordByWordGroups().count > 1 {
                        Button("Merge All \(file.document.wordByWordGroups().count) Reveal Groups…") {
                            confirmMergeAll()
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func rangeText(_ cues: [ReviewCue]) -> String {
        let numbers = cues.compactMap { file.document.cueNumber(of: $0.id) }
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    private func confirmMergeAll() {
        let count = file.document.wordByWordGroups().count
        let alert = NSAlert()
        alert.messageText = "Merge all \(count) word-by-word groups?"
        alert.informativeText = "Each group becomes one cue. The last line is kept, from the first cue's start to the last cue's end. You can undo this."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\u{1b}"
        }
        if alert.runModal() == .alertFirstButtonReturn {
            file.mergeAllGroups()
        }
    }
}

private struct CuePictureWell: View {
    var pictureID: UUID?
    var directory: String?
    @State private var image: NSImage?
    @State private var picture: SubtitleImage?

    var body: some View {
        ZStack {
            Checkerboard()
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                Text("No picture for this cue")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if let picture {
                Text("\(picture.videoWidth) × \(picture.videoHeight) canvas · text cropped \(picture.width) × \(picture.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .accessibilityLabel("Original subtitle picture")
        .task(id: pictureID) {
            await load()
        }
    }

    private func load() async {
        guard let pictureID, let directory else {
            image = nil
            picture = nil
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            CuePictureFiles.read(id: pictureID, from: directory)
        }.value
        picture = loaded
        image = loaded.flatMap { CueImageRenderer.image(from: $0) }
    }
}

private struct Checkerboard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            let light = NSColor(calibratedWhite: colorScheme == .dark ? 0.16 : 0.94, alpha: 1)
            let dark = NSColor(calibratedWhite: colorScheme == .dark ? 0.28 : 0.78, alpha: 1)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: light)))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? cell : 0
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(nsColor: dark)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}

enum CueImageRenderer {
    static func image(from picture: SubtitleImage) -> NSImage? {
        guard picture.width > 0, picture.height > 0, picture.rgba.count == picture.width * picture.height * 4 else {
            return nil
        }
        let data = Data(picture.rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cgImage = CGImage(
            width: picture.width,
            height: picture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: picture.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: picture.width, height: picture.height))
    }
}

private struct CueTimeField: View {
    var title: String
    var pts: UInt32
    var onCommit: (UInt32) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            HStack(spacing: 4) {
                TextField(title, text: $draft)
                    .focused($focused)
                    .onSubmit { commit() }
                    .frame(width: 120)
                Stepper(title, onIncrement: { nudge(1) }, onDecrement: { nudge(-1) })
                    .labelsHidden()
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { draft = SRTWriter.timestamp(pts: pts) }
        .onChange(of: pts) { newValue in
            if !focused { draft = SRTWriter.timestamp(pts: newValue) }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func nudge(_ steps: Int) {
        let next = CueClock.nudging(pts, bySteps: steps)
        draft = SRTWriter.timestamp(pts: next)
        onCommit(next)
    }

    private func commit() {
        guard let parsed = CueClock.parse(draft) else {
            draft = SRTWriter.timestamp(pts: pts)
            return
        }
        draft = SRTWriter.timestamp(pts: parsed)
        if parsed != pts { onCommit(parsed) }
    }
}

private struct CueDurationField: View {
    var title: String
    var duration: UInt32
    var onCommit: (UInt32) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            HStack(spacing: 4) {
                TextField(title, text: $draft)
                    .focused($focused)
                    .onSubmit { commit() }
                    .frame(width: 90)
                Stepper(title, onIncrement: { nudge(1) }, onDecrement: { nudge(-1) })
                    .labelsHidden()
            }
        }
        .onAppear { draft = Self.label(duration) }
        .onChange(of: duration) { newValue in
            if !focused { draft = Self.label(newValue) }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func nudge(_ steps: Int) {
        let next = CueClock.nudging(duration, bySteps: steps)
        draft = Self.label(next)
        onCommit(next)
    }

    private func commit() {
        guard let parsed = Self.parse(draft) else {
            draft = Self.label(duration)
            return
        }
        draft = Self.label(parsed)
        if parsed != duration { onCommit(parsed) }
    }

    private static func label(_ pts: UInt32) -> String {
        let millis = (UInt64(pts) * 1000 + 45_000) / 90_000
        return String(format: "%.3f s", Double(millis) / 1000)
    }

    private static func parse(_ text: String) -> UInt32? {
        let cleaned = text.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)
        guard let seconds = Double(cleaned), seconds >= 0 else { return nil }
        let millis = UInt64((seconds * 1000).rounded())
        let pts = millis * 90
        guard pts <= UInt64(UInt32.max) else { return nil }
        return UInt32(pts)
    }
}

enum UnsavedEditChoice {
    case save
    case discard
    case cancel
}

enum UnsavedPrompt {
    @MainActor
    static func ask(fileName: String, host: NSWindow?) async -> UnsavedEditChoice {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes to “\(fileName)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            if alert.buttons.count > 2 {
                alert.buttons[2].keyEquivalent = "\u{1b}"
            }
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .save)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .discard)
                default:
                    continuation.resume(returning: .cancel)
                }
            }
            if let host {
                alert.beginSheetModal(for: host) { response in
                    finish(response)
                }
            } else {
                finish(alert.runModal())
            }
        }
    }
}

private struct ReturnToEditCatcher: NSViewRepresentable {
    var enabled: Bool
    var onReturn: () -> Void

    func makeNSView(context: Context) -> ReturnCatcherView {
        let view = ReturnCatcherView()
        view.onReturn = onReturn
        view.isEnabled = enabled
        return view
    }

    func updateNSView(_ view: ReturnCatcherView, context: Context) {
        view.onReturn = onReturn
        view.isEnabled = enabled
    }
}

private final class ReturnCatcherView: NSView {
    var onReturn: () -> Void = {}
    var isEnabled = true
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isEnabled, event.window === self.window else { return event }
            if event.window?.attachedSheet != nil { return event }
            let characters = event.charactersIgnoringModifiers ?? ""
            guard characters == "\r" || characters == "\n" else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.option) || flags.contains(.command) || flags.contains(.control) {
                return event
            }
            if self.window?.firstResponder is NSTextView { return event }
            self.onReturn()
            return nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private struct ReviewWindowInstaller: NSViewRepresentable {
    var isDirty: () -> Bool
    var isDocumentEdited: Bool
    var onKey: () -> Void
    var onClose: () -> Void
    var onAttemptClose: (@escaping (Bool) -> Void) -> Void

    func makeNSView(context: Context) -> ReviewWindowAnchor {
        let view = ReviewWindowAnchor()
        view.isDirty = isDirty
        view.onKey = onKey
        view.onClose = onClose
        view.onAttemptClose = onAttemptClose
        view.documentEdited = isDocumentEdited
        return view
    }

    func updateNSView(_ view: ReviewWindowAnchor, context: Context) {
        view.isDirty = isDirty
        view.onKey = onKey
        view.onClose = onClose
        view.onAttemptClose = onAttemptClose
        view.documentEdited = isDocumentEdited
        view.window?.isDocumentEdited = isDocumentEdited
        view.install()
    }
}

private final class ReviewWindowAnchor: NSView {
    var isDirty: () -> Bool = { false }
    var onKey: () -> Void = {}
    var onClose: () -> Void = {}
    var onAttemptClose: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var documentEdited = false
    private let proxy = ReviewCloseProxy()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    override func layout() {
        super.layout()
        install()
    }

    func install() {
        guard let window else { return }
        window.isDocumentEdited = documentEdited
        proxy.isDirty = isDirty
        proxy.onKey = onKey
        proxy.onClose = onClose
        proxy.onAttemptClose = onAttemptClose
        if window.delegate !== proxy {
            proxy.forward = window.delegate
            window.delegate = proxy
        }
    }
}

private final class ReviewCloseProxy: NSObject, NSWindowDelegate {
    weak var forward: NSWindowDelegate?
    var allowClose = false
    var isDirty: () -> Bool = { false }
    var onKey: () -> Void = {}
    var onClose: () -> Void = {}
    var onAttemptClose: (@escaping (Bool) -> Void) -> Void = { $0(false) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose {
            allowClose = false
            return true
        }
        guard isDirty() else { return true }
        onAttemptClose { [weak self, weak sender] shouldClose in
            guard shouldClose, let sender else { return }
            self?.allowClose = true
            sender.close()
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onKey()
        forward?.windowDidBecomeKey?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        forward?.windowWillClose?(notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forward?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return forward
    }
}
