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
            Text("This window is a placeholder. The Blu-ray subtitle decoder is already linked in (version \(PGSCoreInfo.version)). Drag-and-drop conversion will be added in the next update.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
