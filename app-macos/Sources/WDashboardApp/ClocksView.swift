import SwiftUI

struct ClocksView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clocks").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                ForEach(appState.clocks) { clock in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clock.label).font(.caption).foregroundStyle(.secondary)
                        Text(clock.time).font(.system(.title2, design: .monospaced))
                        Text(clock.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}
