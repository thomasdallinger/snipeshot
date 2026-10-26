//! System-wide shortcuts through RegisterHotKey on a thread of their own. RegisterHotKey fails when
//! another app owns the combination, which is how blocked shortcuts are detected.

use std::{
    sync::mpsc::{channel, Sender},
    thread,
};

use windows::Win32::{
    Foundation::{LPARAM, WPARAM},
    System::Threading::GetCurrentThreadId,
    UI::{
        Input::KeyboardAndMouse::{RegisterHotKey, UnregisterHotKey, HOT_KEY_MODIFIERS, MOD_NOREPEAT},
        WindowsAndMessaging::{GetMessageW, PeekMessageW, PostThreadMessageW, MSG, PM_NOREMOVE, WM_APP, WM_HOTKEY, WM_USER},
    },
};

use crate::accel::Hotkey;

const WM_COMMAND_QUEUED: u32 = WM_APP + 7;

enum Command {
    Register(Vec<(usize, Hotkey)>, Sender<Vec<usize>>),
    UnregisterAll(Sender<()>),
}

pub struct Hotkeys {
    thread: u32,
    commands: Sender<Command>,
}

impl Hotkeys {
    /// Starts the hotkey thread; `on_hotkey` gets the binding id.
    pub fn start(on_hotkey: impl Fn(usize) + Send + 'static) -> Hotkeys {
        let (commands, inbox) = channel::<Command>();
        let (ready_tx, ready) = channel();
        thread::Builder::new()
            .name("hotkeys".into())
            .spawn(move || unsafe {
                let mut msg = MSG::default();
                // Creates the thread's message queue before anyone posts to it.
                let _ = PeekMessageW(&mut msg, None, WM_USER, WM_USER, PM_NOREMOVE);
                let _ = ready_tx.send(GetCurrentThreadId());
                let mut registered: Vec<i32> = Vec::new();
                while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                    match msg.message {
                        WM_HOTKEY => on_hotkey(msg.wParam.0),
                        WM_COMMAND_QUEUED => {
                            while let Ok(cmd) = inbox.try_recv() {
                                for id in registered.drain(..) {
                                    let _ = UnregisterHotKey(None, id);
                                }
                                match cmd {
                                    Command::Register(bindings, reply) => {
                                        let mut failed = Vec::new();
                                        for (id, hk) in bindings {
                                            let mods = HOT_KEY_MODIFIERS(hk.modifiers) | MOD_NOREPEAT;
                                            match RegisterHotKey(None, id as i32, mods, hk.vk) {
                                                Ok(()) => registered.push(id as i32),
                                                Err(e) => {
                                                    log::warn!("hotkey {id} not registered: {e}");
                                                    failed.push(id);
                                                }
                                            }
                                        }
                                        let _ = reply.send(failed);
                                    }
                                    Command::UnregisterAll(reply) => {
                                        let _ = reply.send(());
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            })
            .expect("hotkey thread");
        Hotkeys { thread: ready.recv().unwrap_or(0), commands }
    }

    fn send(&self, cmd: Command) -> bool {
        self.commands.send(cmd).is_ok()
            && unsafe { PostThreadMessageW(self.thread, WM_COMMAND_QUEUED, WPARAM(0), LPARAM(0)) }.is_ok()
    }

    /// Replaces all registrations; returns the ids that could not be registered.
    pub fn register(&self, bindings: Vec<(usize, Hotkey)>) -> Vec<usize> {
        let ids: Vec<usize> = bindings.iter().map(|b| b.0).collect();
        let (tx, rx) = channel();
        if !self.send(Command::Register(bindings, tx)) {
            return ids;
        }
        rx.recv().unwrap_or(ids)
    }

    pub fn unregister_all(&self) {
        let (tx, rx) = channel();
        if self.send(Command::UnregisterAll(tx)) {
            let _ = rx.recv();
        }
    }
}
