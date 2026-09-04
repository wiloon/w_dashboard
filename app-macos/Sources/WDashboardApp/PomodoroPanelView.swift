import SwiftUI
import WDashboardCore

/// Pomodoro panel (docs/sdd.md §9 section 5 / §11.4 step 2). Renders
/// `appState.pomodoro` and posts `PomodoroEvent`s; all logic is in the core.
struct PomodoroPanelView: View {
    @EnvironmentObject var appState: AppState

    private var view: PomodoroView { appState.pomodoro }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pomodoro").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(phaseLabel)
                        .font(.system(.title3, weight: .semibold))
                    Spacer()
                    Text(timeLabel)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(view.alerting ? accent : Color.primary)
                }

                ProgressView(value: view.progress)
                    .tint(accent)

                HStack(spacing: 8) {
                    Button("Start focus") { appState.pomodoroEvent(.startFocus) }
                    Button("Start break") { appState.pomodoroEvent(.startBreak) }
                    Button("Stop") { appState.pomodoroEvent(.stop) }
                        .disabled(view.phase == .idle)
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(view.alerting ? accent : Color.clear, lineWidth: 2)
                    )
            )
        }
    }

    private var phaseLabel: String {
        switch view.phase {
        case .idle: return "Idle"
        case .focus: return "Focus"
        case .brk: return "Break"
        case .focusEnded: return "Focus done"
        case .breakEnded: return "Break done"
        }
    }

    private var timeLabel: String {
        switch view.phase {
        case .idle: return "--:--"
        case .focus, .brk: return Self.mmss(view.remainingSecs)
        case .focusEnded, .breakEnded: return "+" + Self.mmss(view.overtimeSecs)
        }
    }

    private var accent: Color {
        switch view.phase {
        case .idle: return .gray
        case .focus: return .green
        case .brk: return .blue
        case .focusEnded: return .red
        case .breakEnded: return .orange
        }
    }

    private static func mmss(_ secs: Int64) -> String {
        let s = max(0, secs)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
