// Menu bar (status bar) item. Click summons the main window.
//
// The item always shows the current Beijing time as `HH:mm`, preceded by a
// leading glyph that tracks the pomodoro phase (docs/sdd.md §11.4, ADR-012):
//   - idle:            the w_dashboard glyph
//   - focus / break:   a `timer` glyph
//   - *Ended (alert):   the whole item — glyph and time — *flashes* red (focus)
//                       or orange (break) until acknowledged.
// The clock rolls over each minute via `clockTimer`.
//
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

    /// Ticks every second; redraws only when the `HH:mm` actually rolls over.
    private var clockTimer: Timer?
    private var clockLabel = ""

    private static let beijingClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm"
        return f
    }()

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(handleClick)
            button.target = self
            button.imagePosition = .imageOnly
        }
        statusItem = item
        render()

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Self.beijingClockFormatter.string(from: Date()) != self.clockLabel {
                self.render()
            }
        }
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
        clockLabel = Self.beijingClockFormatter.string(from: Date())
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let image = Self.statusImage(phase: phase, time: clockLabel, flashOn: flashOn)
        button.image = image
        button.imagePosition = .imageOnly
    }

    /// Glyph + time drawn into a *single* image so the menu-bar item reads as one
    /// object. Non-alert phases are a template image (the system tints it to match
    /// the menu bar and inverts it as a unit when the menu opens). In the `*Ended`
    /// alert the whole thing — glyph and time together — flashes red (focus) or
    /// orange (break) until acknowledged.
    private static func statusImage(phase: PomodoroPhase, time: String, flashOn: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let symbolName = phase == .idle ? "square.grid.2x2" : "timer"
        let alerting = phase == .focusEnded || phase == .breakEnded
        let alertColor: NSColor = phase == .focusEnded ? .systemRed : .systemOrange

        let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: "w_dashboard")!
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular, scale: .small))!

        // Draw everything opaque black; a template image only cares about coverage,
        // and the alert tint (below) is painted over the whole thing afterwards.
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (time as NSString).size(withAttributes: attrs)

        let gap: CGFloat = 3
        let width = ceil(glyph.size.width + gap + textSize.width)
        let height = ceil(max(glyph.size.height, textSize.height))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let glyphRect = NSRect(
                x: 0, y: ((rect.height - glyph.size.height) / 2).rounded(),
                width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
            (time as NSString).draw(
                at: NSPoint(x: glyph.size.width + gap, y: ((rect.height - textSize.height) / 2).rounded()),
                withAttributes: attrs)
            if alerting {
                // Tint glyph + digits as one; the dim half-beat is the flash.
                (flashOn ? alertColor : alertColor.withAlphaComponent(0.25)).set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = !alerting
        return image
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
