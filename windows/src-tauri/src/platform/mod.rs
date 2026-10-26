//! Everything that talks to the OS directly: capture and the selector, clipboard, file drag-out,
//! hotkeys, window styles, sound and the registry. `windows/` is the real implementation; `stub.rs`
//! keeps the crate building and testable on other systems.

use crate::layout::Rect;

/// Captured pixels: RGBA, top-down, with the scale of the monitor they came from.
pub struct Grab {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    /// The monitor the pixels came from, in virtual-screen pixels.
    pub monitor: Rect,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PickMode {
    Area,
    Window,
}

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(not(windows))]
mod stub;
#[cfg(not(windows))]
pub use stub::*;
