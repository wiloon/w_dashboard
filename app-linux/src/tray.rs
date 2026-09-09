//! Pomodoro system-tray icon (SDD §11.4, ADR-012).
//!
//! Linux: a StatusNotifierItem via `ksni` (a `cfg(target_os = "linux")`
//! dependency). The icon colour tracks the phase and *flashes* while a session
//! is in its `*Ended` alert state — red for `FocusEnded`, orange for
//! `BreakEnded`. Menu items post `PomodoroEvent`s back to the UI thread.
//!
//! Other platforms: a no-op stub with the same public surface, so `main.rs`
//! calls it unconditionally. (macOS has its own `NSStatusItem` path — not here.)

use std::sync::mpsc::Sender;

use w_dashboard_linux::pomodoro::PomodoroEvent;

#[cfg(target_os = "linux")]
pub use imp::PomodoroTray;

#[cfg(not(target_os = "linux"))]
pub use stub::PomodoroTray;

/// Spawn the tray. `Some` once set up — either the StatusNotifierItem is
/// registered, or `show_icon` is `false` and only the pomodoro D-Bus service
/// (for the optional KDE Plasma widget, see `app-linux/plasmoid/`) was
/// started. `None` when `show_icon` is `true` but there is no tray host (SDD
/// §11.4 step 6 — the caller then shows the in-window fallback), or on
/// non-Linux platforms.
#[cfg(target_os = "linux")]
pub fn spawn_pomodoro_tray(tx: Sender<PomodoroEvent>, show_icon: bool) -> Option<PomodoroTray> {
    imp::spawn(tx, show_icon)
}

#[cfg(not(target_os = "linux"))]
pub fn spawn_pomodoro_tray(_tx: Sender<PomodoroEvent>, _show_icon: bool) -> Option<PomodoroTray> {
    None
}

#[cfg(not(target_os = "linux"))]
mod stub {
    use w_dashboard_linux::pomodoro::PomodoroPhase;

    /// Never constructed off Linux (`spawn_pomodoro_tray` returns `None`).
    pub struct PomodoroTray(());

    impl PomodoroTray {
        pub fn set_phase(&self, _phase: PomodoroPhase) {}
        pub fn set_nudging(&self, _nudging: bool) {}
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::sync::mpsc::Sender;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    use ksni::blocking::{Handle, TrayMethods};

    use w_dashboard_linux::pomodoro::{PomodoroEvent, PomodoroPhase};

    /// Flash half-period.
    const FLASH_INTERVAL: Duration = Duration::from_millis(650);
    const ICON_SIZE: i32 = 32;
    /// Amber — the morning "start your first focus" nudge (docs/sdd.md §11.4 step 8).
    /// Distinct from the `*Ended` red/orange so the two reasons to flash read apart.
    const NUDGE_RGB: (u8, u8, u8) = (0xf5, 0xa6, 0x23);

    fn phase_rgb(phase: PomodoroPhase) -> (u8, u8, u8) {
        match phase {
            PomodoroPhase::Idle => (0x8a, 0x8a, 0x8a),
            PomodoroPhase::Focus => (0x4c, 0xaf, 0x50),
            PomodoroPhase::Break => (0x42, 0x9c, 0xd6),
            PomodoroPhase::FocusEnded => (0xe4, 0x37, 0x2e),
            PomodoroPhase::BreakEnded => (0xff, 0x7a, 0x1a),
        }
    }

    fn phase_title(phase: PomodoroPhase) -> &'static str {
        match phase {
            PomodoroPhase::Idle => "Pomodoro: idle",
            PomodoroPhase::Focus => "Pomodoro: focusing",
            PomodoroPhase::Break => "Pomodoro: break",
            PomodoroPhase::FocusEnded => "Pomodoro: focus done — take a break",
            PomodoroPhase::BreakEnded => "Pomodoro: break over — back to focus",
        }
    }

    fn is_alerting(phase: PomodoroPhase) -> bool {
        matches!(phase, PomodoroPhase::FocusEnded | PomodoroPhase::BreakEnded)
    }

    /// Short id used on the D-Bus `GetState` reply (see `dbus_service`) and
    /// matched against in the Plasma widget's QML (`plasmoid/…/main.qml`).
    fn phase_id(phase: PomodoroPhase) -> &'static str {
        match phase {
            PomodoroPhase::Idle => "idle",
            PomodoroPhase::Focus => "focus",
            PomodoroPhase::Break => "break",
            PomodoroPhase::FocusEnded => "focus_ended",
            PomodoroPhase::BreakEnded => "break_ended",
        }
    }

    /// A filled disc in the phase colour. `dim` fades it for the dark half of the
    /// alert flash. ARGB32, network byte order, as the SNI spec wants.
    fn disc_icon(phase: PomodoroPhase, dim: bool) -> ksni::Icon {
        disc_icon_rgb(phase_rgb(phase), dim)
    }

    /// A filled disc in an explicit colour (used for the amber morning nudge).
    fn disc_icon_rgb((r, g, b): (u8, u8, u8), dim: bool) -> ksni::Icon {
        let alpha: u8 = if dim { 55 } else { 255 };
        let mut data = vec![0u8; (ICON_SIZE * ICON_SIZE * 4) as usize];
        let center = (ICON_SIZE as f32 - 1.0) / 2.0;
        let radius = ICON_SIZE as f32 / 2.0 - 2.0;
        for y in 0..ICON_SIZE {
            for x in 0..ICON_SIZE {
                let dx = x as f32 - center;
                let dy = y as f32 - center;
                if dx * dx + dy * dy <= radius * radius {
                    let i = ((y * ICON_SIZE + x) * 4) as usize;
                    data[i] = alpha;
                    data[i + 1] = r;
                    data[i + 2] = g;
                    data[i + 3] = b;
                }
            }
        }
        ksni::Icon {
            width: ICON_SIZE,
            height: ICON_SIZE,
            data,
        }
    }

    struct Tray {
        phase: PomodoroPhase,
        /// Morning "start your first focus" nudge (docs/sdd.md §11.4 step 8).
        /// Flashes amber while `phase == Idle`; the `*Ended` alert outranks it.
        nudging: bool,
        /// Toggled by the flash thread; only affects rendering while alerting or nudging.
        flash_bright: bool,
        tx: Sender<PomodoroEvent>,
    }

    impl Tray {
        /// The amber morning nudge shows only while idle and not alerting.
        fn showing_nudge(&self) -> bool {
            self.nudging && !is_alerting(self.phase)
        }

        fn tray_title(&self) -> &'static str {
            if self.showing_nudge() {
                "Pomodoro: start your first focus"
            } else {
                phase_title(self.phase)
            }
        }
    }

    impl ksni::Tray for Tray {
        fn id(&self) -> String {
            "w_dashboard.pomodoro".into()
        }

        fn title(&self) -> String {
            self.tray_title().into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            if self.showing_nudge() {
                return vec![disc_icon_rgb(NUDGE_RGB, !self.flash_bright)];
            }
            let dim = is_alerting(self.phase) && !self.flash_bright;
            vec![disc_icon(self.phase, dim)]
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                title: self.tray_title().into(),
                description: String::new(),
                icon_name: String::new(),
                icon_pixmap: Vec::new(),
            }
        }

        fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
            use ksni::menu::StandardItem;
            let send = |event: PomodoroEvent| {
                Box::new(move |t: &mut Self| {
                    let _ = t.tx.send(event);
                }) as Box<dyn Fn(&mut Self) + Send>
            };
            vec![
                StandardItem {
                    label: "Start focus".into(),
                    activate: send(PomodoroEvent::StartFocus),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Start break".into(),
                    activate: send(PomodoroEvent::StartBreak),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Stop".into(),
                    enabled: self.phase != PomodoroPhase::Idle,
                    activate: send(PomodoroEvent::Stop),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    /// Owns the tray handle (when `show_icon` was `true`) and its flash
    /// thread. Dropping it shuts the tray down and lets the flash thread
    /// exit; the D-Bus service (see `dbus_service`) outlives it — it has no
    /// handle to shut down, and is meant to keep running for the process's
    /// lifetime regardless of this icon.
    pub struct PomodoroTray {
        handle: Option<Handle<Tray>>,
        phase: Arc<Mutex<PomodoroPhase>>,
        nudging: Arc<Mutex<bool>>,
    }

    impl PomodoroTray {
        /// Called from the UI thread on every state change.
        pub fn set_phase(&self, phase: PomodoroPhase) {
            *self.phase.lock().unwrap() = phase;
            if let Some(handle) = &self.handle {
                handle.update(move |t: &mut Tray| {
                    t.phase = phase;
                    t.flash_bright = true;
                });
            }
        }

        /// Called from the UI thread when the morning nudge turns on or off
        /// (docs/sdd.md §11.4 step 8).
        pub fn set_nudging(&self, nudging: bool) {
            *self.nudging.lock().unwrap() = nudging;
            if let Some(handle) = &self.handle {
                handle.update(move |t: &mut Tray| {
                    t.nudging = nudging;
                    t.flash_bright = true;
                });
            }
        }
    }

    impl Drop for PomodoroTray {
        fn drop(&mut self) {
            if let Some(handle) = &self.handle {
                handle.shutdown();
            }
        }
    }

    /// `show_icon = false` skips registering the StatusNotifierItem
    /// entirely (`[pomodoro] tray_icon = false`) — only the D-Bus service
    /// starts, for setups using the KDE Plasma widget instead
    /// (`app-linux/plasmoid/README.md`).
    pub fn spawn(tx: Sender<PomodoroEvent>, show_icon: bool) -> Option<PomodoroTray> {
        let phase = Arc::new(Mutex::new(PomodoroPhase::Idle));
        let nudging = Arc::new(Mutex::new(false));
        dbus_service::spawn(phase.clone(), nudging.clone(), tx.clone());

        if !show_icon {
            return Some(PomodoroTray {
                handle: None,
                phase,
                nudging,
            });
        }

        let tray = Tray {
            phase: PomodoroPhase::Idle,
            nudging: false,
            flash_bright: true,
            tx,
        };
        let handle = tray.spawn().ok()?;
        {
            let handle = handle.clone();
            let phase = phase.clone();
            let nudging = nudging.clone();
            thread::spawn(move || loop {
                thread::sleep(FLASH_INTERVAL);
                if handle.is_closed() {
                    return;
                }
                let flashing =
                    is_alerting(*phase.lock().unwrap()) || *nudging.lock().unwrap();
                if flashing {
                    handle.update(|t: &mut Tray| t.flash_bright = !t.flash_bright);
                }
            });
        }

        Some(PomodoroTray {
            handle: Some(handle),
            phase,
            nudging,
        })
    }

    /// A small session-bus service mirroring the pomodoro state, so the
    /// optional KDE Plasma widget (`app-linux/plasmoid/`) can show it with
    /// arbitrary-width text — something the SNI tray's fixed square icon
    /// can't do. Polled by the widget's QML over `busctl` (see its README);
    /// purely additive, the SNI tray above is unaffected either way.
    mod dbus_service {
        use std::sync::mpsc::Sender;
        use std::sync::{Arc, Mutex};
        use std::thread;
        use std::time::Duration;

        use zbus::blocking::connection::Builder;
        use zbus::interface;

        use w_dashboard_linux::pomodoro::{PomodoroEvent, PomodoroPhase};

        use super::phase_id;

        pub const BUS_NAME: &str = "dev.wdashboard.Pomodoro";
        pub const OBJECT_PATH: &str = "/dev/wdashboard/Pomodoro";
        // Interface name is "dev.wdashboard.Pomodoro1" — set via the
        // `#[interface(name = "…")]` attribute below (must be a literal).

        struct PomodoroDbus {
            phase: Arc<Mutex<PomodoroPhase>>,
            nudging: Arc<Mutex<bool>>,
            tx: Sender<PomodoroEvent>,
        }

        #[interface(name = "dev.wdashboard.Pomodoro1")]
        impl PomodoroDbus {
            /// `(phase_id, nudging)` — see `phase_id` for the id strings.
            fn get_state(&self) -> (String, bool) {
                let phase = *self.phase.lock().unwrap();
                let nudging = *self.nudging.lock().unwrap();
                (phase_id(phase).into(), nudging)
            }

            fn start_focus(&self) {
                let _ = self.tx.send(PomodoroEvent::StartFocus);
            }

            fn start_break(&self) {
                let _ = self.tx.send(PomodoroEvent::StartBreak);
            }

            fn stop(&self) {
                let _ = self.tx.send(PomodoroEvent::Stop);
            }
        }

        /// How long to wait before retrying after a failed bind (e.g. losing
        /// a startup race for `BUS_NAME` against another instance that's
        /// since exited).
        const RETRY_INTERVAL: Duration = Duration::from_secs(5);
        /// How often to confirm we still own `BUS_NAME`, so a lost
        /// connection (bus restart, name stolen) gets rebuilt instead of
        /// leaving the Plasma widget polling a name nobody answers on.
        const HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(30);

        /// Spawn the service on its own thread, retrying indefinitely on
        /// failure or if the bus name is ever lost — otherwise a transient
        /// startup race (or a bus restart) would silently strand the Plasma
        /// widget polling a name nobody answers on. The SNI tray is
        /// unaffected either way.
        pub fn spawn(
            phase: Arc<Mutex<PomodoroPhase>>,
            nudging: Arc<Mutex<bool>>,
            tx: Sender<PomodoroEvent>,
        ) {
            thread::spawn(move || loop {
                let iface = PomodoroDbus {
                    phase: phase.clone(),
                    nudging: nudging.clone(),
                    tx: tx.clone(),
                };
                let conn = Builder::session()
                    .and_then(|b| b.name(BUS_NAME))
                    .and_then(|b| b.serve_at(OBJECT_PATH, iface))
                    .and_then(|b| b.build());
                let conn = match conn {
                    Ok(conn) => conn,
                    Err(err) => {
                        eprintln!(
                            "w_dashboard: pomodoro D-Bus service failed ({err}); retrying in {}s",
                            RETRY_INTERVAL.as_secs()
                        );
                        thread::sleep(RETRY_INTERVAL);
                        continue;
                    }
                };

                // Hold the connection as long as we still own BUS_NAME.
                loop {
                    thread::sleep(HEALTH_CHECK_INTERVAL);
                    let still_owned = conn
                        .call_method(
                            Some("org.freedesktop.DBus"),
                            "/org/freedesktop/DBus",
                            Some("org.freedesktop.DBus"),
                            "GetNameOwner",
                            &(BUS_NAME,),
                        )
                        .ok()
                        .and_then(|reply| reply.body().deserialize::<String>().ok())
                        .is_some_and(|owner| {
                            conn.unique_name().is_some_and(|us| owner == us.as_str())
                        });
                    if !still_owned {
                        eprintln!("w_dashboard: pomodoro D-Bus service lost {BUS_NAME}; reconnecting");
                        break;
                    }
                }
            });
        }
    }
}
