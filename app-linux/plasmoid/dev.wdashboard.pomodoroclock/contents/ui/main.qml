// Panel widget showing Beijing time + the w_dashboard pomodoro phase as
// ordinary wide text — the macOS-menu-bar-style item the SNI tray icon
// (app-linux/src/tray.rs) can't be, since Plasma's system tray gives every
// StatusNotifierItem a fixed square cell.
//
// State comes from the w_dashboard process's own tiny D-Bus service
// (dev.wdashboard.Pomodoro, see tray.rs's `dbus_service` module) via
// `busctl`, using Plasma's "executable" data engine — no C++ plugin needed.
//
// The clock is computed in plain JS, not via Plasma's "time" data engine:
// that engine hands back a QDateTime already converted to the requested
// zone, but exposing it as a QML `date` and formatting it with
// Qt.formatTime() re-renders it in the *system* timezone regardless —
// Qt/QML's date→JS-Date bridge keeps the instant but drops which zone it
// was "meant" to be read in. Doing the UTC+8 math ourselves and reading it
// back with the UTC getters sidesteps that entirely. Asia/Shanghai has a
// fixed UTC+8 offset (no DST), so this is exact, not an approximation.

import QtQuick
import QtQuick.Layouts

import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    readonly property string busName: "dev.wdashboard.Pomodoro"
    readonly property string objectPath: "/dev/wdashboard/Pomodoro"
    readonly property string iface: "dev.wdashboard.Pomodoro1"
    readonly property string dbusPrefix: "busctl --user call " + busName + " " + objectPath + " " + iface + " "

    property string phase: "idle"
    property bool nudging: false
    property bool flashOn: true
    // Whether the last GetState poll actually reached w_dashboard (see
    // stateSource below). Starts false — nothing's confirmed yet.
    property bool connected: false

    readonly property bool alerting: connected && (phase === "focus_ended" || phase === "break_ended")
    readonly property bool showingNudge: connected && nudging && !alerting
    readonly property bool flashing: alerting || showingNudge
    readonly property bool dimmed: flashing && !flashOn

    // Same palette as the SNI tray icon (tray.rs's `phase_rgb`/`NUDGE_RGB`).
    // Disconnected reuses the idle gray — `dotOpacity`/`textOpacity` below
    // are what actually make "disconnected" read differently from "idle".
    readonly property string phaseColor: {
        if (!connected) return "#8a8a8a";
        if (showingNudge) return "#f5a623";
        switch (phase) {
        case "focus": return "#4caf50";
        case "break": return "#429cd6";
        case "focus_ended": return "#e4372e";
        case "break_ended": return "#ff7a1a";
        default: return "#8a8a8a";
        }
    }

    // Faded when disconnected (stale — the process isn't answering), and the
    // normal alert/nudge flash on top of that once connected.
    readonly property real dotOpacity: !connected ? 0.4 : (dimmed ? 0.25 : 1.0)
    readonly property real textOpacity: !connected ? 0.4 : (dimmed ? 0.35 : 1.0)

    readonly property string statusText: {
        if (!connected) return i18n("w_dashboard: not running");
        if (showingNudge) return i18n("Pomodoro: start your first focus");
        switch (phase) {
        case "focus": return i18n("Pomodoro: focusing");
        case "break": return i18n("Pomodoro: break");
        case "focus_ended": return i18n("Pomodoro: focus done — take a break");
        case "break_ended": return i18n("Pomodoro: break over — back to focus");
        default: return i18n("Pomodoro: idle");
        }
    }

    toolTipMainText: statusText
    toolTipSubText: i18n("Beijing time %1", beijingLabel)

    preferredRepresentation: compactRepresentation
    switchWidth: 0
    switchHeight: 0

    // ---- Beijing clock, independent of the system's own timezone. ----
    property string beijingLabel: "--:--"
    function updateBeijingLabel() {
        // Date.getTime() is already a true, timezone-invariant UTC instant —
        // no system-offset correction needed. Add Beijing's fixed UTC+8 and
        // read it back with the *UTC* getters, so nothing re-renders it in
        // the system zone (see the note up top).
        const shifted = new Date(Date.now() + 8 * 3600000);
        const hh = String(shifted.getUTCHours()).padStart(2, "0");
        const mm = String(shifted.getUTCMinutes()).padStart(2, "0");
        beijingLabel = hh + ":" + mm;
    }
    Component.onCompleted: updateBeijingLabel()
    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.updateBeijingLabel()
    }

    // ---- Pomodoro state, polled from the w_dashboard process. ----
    P5Support.DataSource {
        id: stateSource
        engine: "executable"
        connectedSources: [root.dbusPrefix + "GetState --json=short"]
        interval: 1000
        onNewData: (sourceName, data) => {
            const out = (data["stdout"] || "").toString().trim();
            let parsed = null;
            if (out) {
                try {
                    const obj = JSON.parse(out);
                    if (obj && Array.isArray(obj.data) && obj.data.length === 2) {
                        parsed = obj.data;
                    }
                } catch (e) {
                    parsed = null;
                }
            }
            if (parsed) {
                root.phase = parsed[0];
                root.nudging = parsed[1];
                root.connected = true;
            } else {
                // w_dashboard isn't running (or the D-Bus service hasn't
                // come up yet) — GetState's stderr explains why. Don't
                // trust the last-known phase/nudging any more; the compact
                // representation fades to signal that (see `dotOpacity`).
                root.connected = false;
            }
        }
    }

    // ---- Alert / morning-nudge flash, same 650ms cadence as the tray icon. ----
    Timer {
        interval: 650
        running: root.flashing
        repeat: true
        onTriggered: root.flashOn = !root.flashOn
        onRunningChanged: if (!running) root.flashOn = true
    }

    // Display-only: no menu, no way to start/stop a session from here. Use
    // the SNI tray icon or the main window for that.
    compactRepresentation: RowLayout {
        id: row

        Layout.minimumWidth: implicitWidth + units.smallSpacing * 2
        Layout.minimumHeight: implicitHeight
        Layout.preferredWidth: Layout.minimumWidth
        spacing: 4

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 8
            height: 8
            radius: 4
            color: root.phaseColor
            opacity: root.dotOpacity
        }

        PlasmaComponents3.Label {
            text: root.beijingLabel
            font.family: "monospace"
            color: root.phaseColor
            opacity: root.textOpacity
        }
    }
}
