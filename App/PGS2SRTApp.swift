import SwiftUI

@main
struct PGS2SRTApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // This window does not open another copy of itself for a file or folder.
                .handlesExternalEvents(preferring: [], allowing: [])
        }
        // Reuse this window when Finder or the Dock opens a file. A new window
        // is created only when none is open.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    model.showOpenPanel()
                }
                .keyboardShortcut("o")
                Button("Cancel All") {
                    model.cancelAll()
                }
                .keyboardShortcut(".")
                .disabled(!model.hasCancellableWork)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
