import SwiftUI

/// Top "Now" card (docs/sdd.md §9, ADR-013): the pomodoro controls and the
/// timezone clocks share one card — both are "right now" state. When the
/// pomodoro is disabled the card degrades to clocks only (the old Clocks card).
struct NowPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            if appState.config.pomodoro.enabled {
                PomodoroPanelView()
                Divider().frame(height: 76)
            }
            ClocksView()
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}
