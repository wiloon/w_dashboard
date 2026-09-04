import SwiftUI

@main
struct WDashboardApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.statusItemController.onSelect = {
                        NSApp.activate(ignoringOtherApps: true)
                        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
                            if window.isMiniaturized {
                                window.deminiaturize(nil)
                            }
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: "main")
                        }
                    }
                    // Drive the menu-bar icon from pomodoro phase changes (SDD §11.4).
                    appState.onPomodoroPhaseChange = { phase in
                        appDelegate.statusItemController.setPomodoroPhase(phase)
                    }
                }
        }
    }
}
