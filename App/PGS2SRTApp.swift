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
