// Menu bar (status bar) icon that summons the main window on click.
// Kept separate from WDashboardApp.swift since NSStatusItem setup is AppKit,
// not SwiftUI Scene/View code.

import AppKit
import SwiftUI

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    /// Set by the App once it has access to `openWindow`.
    var onSelect: (() -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "w_dashboard")
            button.action = #selector(handleClick)
            button.target = self
        }
        statusItem = item
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
