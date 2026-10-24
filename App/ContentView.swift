import SwiftUI
import PGSCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("PGS2SRT")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Coming soon")
                .font(.title2)
            Text("This window is a placeholder. The Blu-ray subtitle decoder is linked in (version \(PGSCoreInfo.version)). On a Mac, the pgs2srt command can already turn a .sup file into an .srt file. Drag-and-drop conversion comes next.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
