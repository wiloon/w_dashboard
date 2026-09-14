import SwiftUI

/// Clocks — the right half of the top "Now" card (docs/sdd.md §9, ADR-013).
/// One column per configured timezone. The date is shown small / on hover
/// (Beijing & New York rarely differ from the local date).
struct ClocksView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(appState.clocks) { clock in
                VStack(alignment: .leading, spacing: 2) {
                    Text(clock.label).font(.caption).foregroundStyle(.secondary)
                    Text(clock.time).font(.system(.title2, design: .monospaced))
                    Text(clock.date).font(.caption2).foregroundStyle(.tertiary)
                }
                .help(clock.date)
            }
        }
    }
}
