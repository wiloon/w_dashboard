import SwiftUI
import WDashboardCore

/// Pomodoro controls — the left half of the top "Now" card (docs/sdd.md §9 / §11.4
/// step 2, ADR-013). Renders `appState.pomodoro` and posts `PomodoroEvent`s; all
/// logic is in the core. The `*Ended` highlight border wraps only this subview,
/// never the clocks sharing the card.
struct PomodoroPanelView: View {
    @EnvironmentObject var appState: AppState

    private var view: PomodoroView { appState.pomodoro }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ring

            VStack(alignment: .leading, spacing: 10) {
                Text(phaseLabel)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(view.alerting ? accent : Color.primary)

                HStack(spacing: 8) {
                    // One toggle button that walks the cycle Focus → Break → Focus…
                    // (ADR-012 「Next」). Its label always names the *next* click, and
                    // in a `*Ended` phase that same click also acknowledges the alert.
                    Button(primaryLabel) { appState.pomodoroEvent(primaryEvent) }
                        .buttonStyle(.borderedProminent)
                        .tint(view.alerting ? accent : .accentColor)
                    Button("Stop") { appState.pomodoroEvent(.stop) }
                        .disabled(view.phase == .idle)
                }
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(view.alerting ? accent : Color.clear, lineWidth: 2)
        )
    }

    /// Circular progress ring with the remaining / overtime time centred
    /// (ADR-013: replaces the horizontal progress bar to save width).
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.0, min(1.0, view.progress)))
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(timeLabel)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(view.alerting ? accent : Color.primary)
                .monospacedDigit()
        }
        .frame(width: 76, height: 76)
        .animation(.linear(duration: 0.25), value: view.progress)
    }

    /// Focus / FocusEnded → the next click starts a break; every other phase
    /// (Idle, Break, BreakEnded) → the next click starts a focus segment.
    private var primaryEvent: PomodoroEvent {
        switch view.phase {
        case .focus, .focusEnded: return .startBreak
        case .idle, .brk, .breakEnded: return .startFocus
        }
    }

    private var primaryLabel: String {
        primaryEvent == .startBreak ? "Start break" : "Start focus"
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
