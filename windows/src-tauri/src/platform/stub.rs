//! Stand-ins so the crate builds and its tests run on macOS and Linux. Snipeshot for Windows only
//! ships on Windows; nothing here pretends to capture or drag.

use std::{fs, io, path::Path};

use tauri::WebviewWindow;

use super::{Grab, PickMode};
use crate::accel::Hotkey;

const UNSUPPORTED: &str = "Only available on Windows.";

pub fn pick(_mode: PickMode) -> Result<Option<Grab>, String> {
    Err(UNSUPPORTED.into())
}

pub fn grab_screen() -> Result<Option<Grab>, String> {
    Err(UNSUPPORTED.into())
}

pub fn write_hidden(path: &Path, bytes: &[u8]) -> io::Result<()> {
    fs::write(path, bytes)
}

pub fn is_hidden(_meta: &fs::Metadata) -> bool {
    false
}

pub fn play_sound(_wav: &'static [u8]) {}

pub fn beep() {}

pub fn set_clipboard_image(_png: &[u8], _rgba: &[u8], _width: u32, _height: u32) -> Result<(), String> {
    Err(UNSUPPORTED.into())
}

/// PNG bytes and scale of the image on the clipboard.
pub fn clipboard_image() -> Option<(Vec<u8>, f64)> {
    None
}

/// Runs a file drag from `window`; true when it was dropped somewhere.
pub fn drag_file(_window: &WebviewWindow, _path: &Path) -> Result<bool, String> {
    Err(UNSUPPORTED.into())
}

/// Shelf and pins: kept out of our own captures.
pub fn prepare_floating(_window: &WebviewWindow) {}

pub fn show_without_focus(window: &WebviewWindow) {
    let _ = window.show();
}

pub fn hide(window: &WebviewWindow) {
    let _ = window.hide();
}

pub fn mouse_button_down() -> bool {
    false
}

pub fn accent_color() -> String {
    "#0078D4".into()
}

pub fn print_screen_opens_snipping_tool() -> bool {
    false
}

pub fn set_print_screen_opens_snipping_tool(_enabled: bool) -> Result<(), String> {
    Err(UNSUPPORTED.into())
}

pub fn show_in_explorer(path: &Path) -> Result<(), String> {
    open_folder(path.parent().unwrap_or(path))
}

pub fn open_folder(path: &Path) -> Result<(), String> {
    std::process::Command::new("open").arg(path).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Global hotkeys; on other systems nothing is registered and nothing reports as blocked.
pub struct Hotkeys;

impl Hotkeys {
    pub fn start(_on_hotkey: impl Fn(usize) + Send + 'static) -> Hotkeys {
        Hotkeys
    }

    /// Replaces all registrations; returns the ids that could not be registered.
    pub fn register(&self, _bindings: Vec<(usize, Hotkey)>) -> Vec<usize> {
        Vec::new()
    }

    pub fn unregister_all(&self) {}
}
