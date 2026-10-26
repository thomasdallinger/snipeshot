//! Global capture shortcuts: registration from settings, blocked ones, pausing while the settings
//! window records a new shortcut, and the Windows "Print Screen opens Snipping Tool" switch.

use parking_lot::Mutex;
use serde::Serialize;
use tauri::AppHandle;

use crate::{accel, platform, settings::CaptureKind, state};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutStatus {
    pub blocked: Vec<CaptureKind>,
    pub print_screen_opens_snipping_tool: bool,
}

pub struct Shortcuts {
    hotkeys: platform::Hotkeys,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    blocked: Vec<CaptureKind>,
    paused: bool,
}

/// Hotkey ids are 1-based positions in `CaptureKind::ALL`.
fn id(kind: CaptureKind) -> usize {
    CaptureKind::ALL.iter().position(|k| *k == kind).unwrap_or(0) + 1
}

impl Shortcuts {
    pub fn start(on_capture: impl Fn(CaptureKind) + Send + 'static) -> Shortcuts {
        let hotkeys = platform::Hotkeys::start(move |id| {
            if let Some(kind) = id.checked_sub(1).and_then(|i| CaptureKind::ALL.get(i)) {
                on_capture(*kind);
            }
        });
        Shortcuts { hotkeys, inner: Mutex::new(Inner::default()) }
    }

    pub fn unregister_all(&self) {
        self.hotkeys.unregister_all();
    }
}

/// Registers the configured shortcuts (unless paused) and records which ones are blocked.
pub fn register(app: &AppHandle) {
    let st = state(app);
    let shortcuts = st.settings.read().shortcuts.clone();
    let mut inner = st.shortcuts.inner.lock();
    if inner.paused {
        return;
    }
    let mut blocked = Vec::new();
    let mut bindings = Vec::new();
    for kind in CaptureKind::ALL {
        let Some(acc) = shortcuts.get(kind) else { continue };
        match accel::parse(acc) {
            Ok(hk) => bindings.push((id(kind), hk)),
            Err(e) => {
                log::warn!("shortcut for {} ignored: {e}", kind.key());
                blocked.push(kind);
            }
        }
    }
    let failed = st.shortcuts.hotkeys.register(bindings);
    blocked.extend(CaptureKind::ALL.into_iter().filter(|k| failed.contains(&id(*k))));
    blocked.sort_by_key(|k| id(*k));
    if blocked != inner.blocked {
        log::info!("blocked shortcuts: {:?}", blocked);
    }
    inner.blocked = blocked;
}

pub fn pause(app: &AppHandle) {
    let st = state(app);
    st.shortcuts.inner.lock().paused = true;
    st.shortcuts.hotkeys.unregister_all();
}

pub fn resume(app: &AppHandle) {
    state(app).shortcuts.inner.lock().paused = false;
    register(app);
}

/// Current status. Blocked shortcuts are retried, so they recover once the other app lets go.
pub fn status(app: &AppHandle) -> ShortcutStatus {
    let retry = {
        let st = state(app);
        let inner = st.shortcuts.inner.lock();
        !inner.paused && !inner.blocked.is_empty()
    };
    if retry {
        register(app);
    }
    let st = state(app);
    let blocked = st.shortcuts.inner.lock().blocked.clone();
    ShortcutStatus {
        blocked,
        print_screen_opens_snipping_tool: platform::print_screen_opens_snipping_tool(),
    }
}
