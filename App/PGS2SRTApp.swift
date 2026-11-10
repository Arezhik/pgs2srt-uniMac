import SwiftUI

@main
struct PGS2SRTApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // An open queue window takes the file, instead of a new window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // When no window is open, this scene may create one for a Dock or Open With drop.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 720, height: 520)
        .commands {
            AppCommands(model: model)
        }

        WindowGroup(id: "review", for: UUID.self) { windowID in
            ReviewRoot(windowID: windowID.wrappedValue)
                .environmentObject(model)
        }
        .defaultSize(width: 1080, height: 720)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @FocusedValue(\.reviewActions) private var review
    @FocusedValue(\.queueActions) private var queue

    var body: some Commands {
        let _ = traceCommands()
        CommandGroup(replacing: .saveItem) {
            Button("Save") { review?.save() }
                .keyboardShortcut("s")
                .disabled(review == nil)
            Button("Save As…") { review?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(review == nil)
            Button("Save All Reviewed") {
                Task { await model.saveAllReviewed() }
            }
            .disabled(!model.hasReviewsNeedingSave)
            Divider()
            Button("Review") {
                queue?.review()
            }
            .keyboardShortcut("r")
            .disabled(queue?.canReview != true)
            Button("Review in New Window") {
                queue?.reviewNewWindow()
            }
            .disabled(queue?.canReview != true)
        }

        CommandGroup(after: .newItem) {
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Cancel All") { model.cancelAll() }
                .keyboardShortcut(".")
                .disabled(!model.hasCancellableWork)
            Button("Clear Finished") { model.clearFinished() }
                .modifier(ClearFinishedShortcut(active: review == nil))
                .disabled(!model.canClearFinished)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { review?.undo() }
                .keyboardShortcut("z")
                .disabled(review?.canUndo != true)
            Button("Redo") { review?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(review?.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Merge Cues") { review?.merge() }
                .keyboardShortcut("k")
                .disabled(review?.canMerge != true)
            Button("Delete Cue") { review?.deleteCues() }
                .modifier(DeleteCueShortcut(active: review != nil))
                .disabled(review?.canDelete != true)
            Divider()
            Button("Find Next") { review?.findNext() }
                .keyboardShortcut("g")
                .disabled(review == nil)
            Button("Find Previous") { review?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(review == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Show All Cues") { review?.showAll() }
                .keyboardShortcut("1")
                .disabled(review == nil)
            Button("Show Problems") { review?.showProblems() }
                .keyboardShortcut("2")
                .disabled(review == nil)
            Button("Show Edited") { review?.showEdited() }
                .keyboardShortcut("3")
                .disabled(review == nil)
            Divider()
            Button {
                review?.togglePictures()
            } label: {
                if review?.showPictures == true {
                    Image(systemName: "checkmark")
                }
                Text("Show Pictures in List")
            }
            .disabled(review == nil)
        }

        CommandMenu("Go") {
            Button("Previous Cue") { review?.previousCue() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(review == nil)
            Button("Next Cue") { review?.nextCue() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(review == nil)
            Button("Next Problem") { review?.nextProblem() }
                .keyboardShortcut("'", modifiers: .command)
                .disabled(review?.canStepProblem != true)
            Button("Previous Problem") { review?.previousProblem() }
                .keyboardShortcut("\"", modifiers: [.command, .shift])
                .disabled(review?.canStepProblem != true)
            Divider()
            Button("Next File to Review") { review?.nextFile() }
                .disabled(review?.canNextFile != true)
        }

        CommandGroup(replacing: .help) {
            Button("Export Debug Log…") {
                model.exportDebugLog()
            }
        }
    }

    /// Reads command inputs only while tracing is on, so a cue tick does not do this work twice.
    private func traceCommands() {
        guard IssueDiagnosticLog.enabled else { return }
        IssueDiagnosticLog.recordCommands(
            hasCancellableWork: model.hasCancellableWork,
            canClearFinished: model.canClearFinished,
            hasReviewsNeedingSave: model.hasReviewsNeedingSave,
            reviewFocused: review != nil,
            queueCanReview: queue?.canReview == true
        )
    }
}

/// ⌘⌫ clears the queue only while a review window is not key, so Delete Cue can use it there.
private struct ClearFinishedShortcut: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(.delete, modifiers: .command)
        } else {
            content
        }
    }
}

private struct DeleteCueShortcut: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(.delete, modifiers: .command)
        } else {
            content
        }
    }
}
