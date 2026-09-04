// Menu bar (status bar) icon. Click summons the main window; while a pomodoro
// session is running the icon reflects the phase, and it *flashes* red/orange
// while a `*Ended` alert is unacknowledged (docs/sdd.md §11.4, ADR-012).
// Kept separate from WDashboardApp.swift since NSStatusItem setup is AppKit.

import AppKit
import SwiftUI
import WDashboardCore

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    /// Set by the App once it has access to `openWindow`.
    var onSelect: (() -> Void)?

    private var phase: PomodoroPhase = .idle
    private var flashOn = true
    private var flashTimer: Timer?
    private var attentionRequest: Int?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.action = #selector(handleClick)
            button.target = self
        }
        statusItem = item
        render()
    }

    /// Called from the UI whenever the pomodoro phase changes (docs/sdd.md §11.4).
    func setPomodoroPhase(_ phase: PomodoroPhase) {
        self.phase = phase
        flashOn = true
        flashTimer?.invalidate()
        flashTimer = nil

        if phase == .focusEnded || phase == .breakEnded {
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
                self?.flashOn.toggle()
                self?.render()
            }
            if attentionRequest == nil {
                attentionRequest = NSApp.requestUserAttention(.criticalRequest)
            }
        } else if let request = attentionRequest {
            NSApp.cancelUserAttentionRequest(request)
            attentionRequest = nil
        }

        render()
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        switch phase {
        case .idle:
            let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "w_dashboard")
            img?.isTemplate = true
            button.image = img
        case .focus, .brk:
            let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro running")
            img?.isTemplate = true
            button.image = img
        case .focusEnded, .breakEnded:
            let base: NSColor = phase == .focusEnded ? .systemRed : .systemOrange
            let color = flashOn ? base : base.withAlphaComponent(0.2)
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro alert")?
                .withSymbolConfiguration(config)
            img?.isTemplate = false
            button.image = img
        }
    }

    @objc private func handleClick() {
        onSelect?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.setup()
    }
}
