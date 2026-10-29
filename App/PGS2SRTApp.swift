import SwiftUI

@main
struct PGS2SRTApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
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
