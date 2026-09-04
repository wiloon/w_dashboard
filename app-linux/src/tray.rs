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

/// Spawn the tray. `Some` once the StatusNotifierItem is registered; `None` when
/// there is no tray host (SDD §11.4 step 6 — the caller then shows the in-window
/// fallback) or on non-Linux platforms.
#[cfg(target_os = "linux")]
pub fn spawn_pomodoro_tray(tx: Sender<PomodoroEvent>) -> Option<PomodoroTray> {
    imp::spawn(tx)
}

#[cfg(not(target_os = "linux"))]
pub fn spawn_pomodoro_tray(_tx: Sender<PomodoroEvent>) -> Option<PomodoroTray> {
    None
}

#[cfg(not(target_os = "linux"))]
mod stub {
    use w_dashboard_linux::pomodoro::PomodoroPhase;

    /// Never constructed off Linux (`spawn_pomodoro_tray` returns `None`).
    pub struct PomodoroTray(());

    impl PomodoroTray {
        pub fn set_phase(&self, _phase: PomodoroPhase) {}
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

    /// A filled disc in the phase colour. `dim` fades it for the dark half of the
    /// alert flash. ARGB32, network byte order, as the SNI spec wants.
    fn disc_icon(phase: PomodoroPhase, dim: bool) -> ksni::Icon {
        let (r, g, b) = phase_rgb(phase);
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
        /// Toggled by the flash thread; only affects rendering while alerting.
        flash_bright: bool,
        tx: Sender<PomodoroEvent>,
    }

    impl ksni::Tray for Tray {
        fn id(&self) -> String {
            "w_dashboard.pomodoro".into()
        }

        fn title(&self) -> String {
            phase_title(self.phase).into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            let dim = is_alerting(self.phase) && !self.flash_bright;
            vec![disc_icon(self.phase, dim)]
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                title: phase_title(self.phase).into(),
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

    /// Owns the tray handle and the flash thread. Dropping it shuts the tray
    /// down and lets the flash thread exit.
    pub struct PomodoroTray {
        handle: Handle<Tray>,
        phase: Arc<Mutex<PomodoroPhase>>,
    }

    impl PomodoroTray {
        /// Called from the UI thread on every state change.
        pub fn set_phase(&self, phase: PomodoroPhase) {
            *self.phase.lock().unwrap() = phase;
            self.handle.update(move |t: &mut Tray| {
                t.phase = phase;
                t.flash_bright = true;
            });
        }
    }

    impl Drop for PomodoroTray {
        fn drop(&mut self) {
            self.handle.shutdown();
        }
    }

    pub fn spawn(tx: Sender<PomodoroEvent>) -> Option<PomodoroTray> {
        let tray = Tray {
            phase: PomodoroPhase::Idle,
            flash_bright: true,
            tx,
        };
        let handle = tray.spawn().ok()?;

        let phase = Arc::new(Mutex::new(PomodoroPhase::Idle));
        {
            let handle = handle.clone();
            let phase = phase.clone();
            thread::spawn(move || loop {
                thread::sleep(FLASH_INTERVAL);
                if handle.is_closed() {
                    return;
                }
                if is_alerting(*phase.lock().unwrap()) {
                    handle.update(|t: &mut Tray| t.flash_bright = !t.flash_bright);
                }
            });
        }

        Some(PomodoroTray { handle, phase })
    }
}
