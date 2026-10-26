//! Windows integrations. Capture, the selector, hotkeys, clipboard and drag live in their own files;
//! this one holds the small things: hidden files, sound, window styles, registry and Explorer.

mod clipboard;
mod drag;
mod grab;
mod hotkeys;
mod overlay;

use std::{
    fs, io,
    os::windows::{fs::MetadataExt, fs::OpenOptionsExt, process::CommandExt},
    path::Path,
};

use tauri::WebviewWindow;
use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{ERROR_SUCCESS, HWND, LPARAM, WPARAM},
        Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT},
        Storage::FileSystem::FILE_ATTRIBUTE_HIDDEN,
        System::{
            Diagnostics::Debug::MessageBeep,
            Registry::{RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_DWORD, RRF_RT_REG_DWORD},
        },
        UI::{
            Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_MBUTTON, VK_RBUTTON},
            WindowsAndMessaging::{
                SendMessageTimeoutW, SetWindowDisplayAffinity, SetWindowPos, ShowWindow, HWND_BROADCAST, HWND_TOPMOST,
                MB_OK, SMTO_ABORTIFHUNG, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_HIDE,
                SW_SHOWNOACTIVATE, WDA_EXCLUDEFROMCAPTURE, WM_SETTINGCHANGE,
            },
        },
    },
};

pub use self::{
    clipboard::{clipboard_image, set_clipboard_image},
    drag::drag_file,
    grab::{grab_screen, pick},
    hotkeys::Hotkeys,
};

pub(crate) fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    s.as_ref().encode_wide().chain([0]).collect()
}

fn hwnd(window: &WebviewWindow) -> Option<HWND> {
    window.hwnd().ok().map(|h| HWND(h.0 as _))
}

/// Writes a file with the hidden attribute. Plain `fs::write` cannot overwrite a hidden file
/// (CREATE_ALWAYS needs the attribute repeated), so the attribute goes into the open call.
pub fn write_hidden(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .attributes(FILE_ATTRIBUTE_HIDDEN.0)
        .open(path)?;
    file.write_all(bytes)
}

pub fn is_hidden(meta: &fs::Metadata) -> bool {
    meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN.0 != 0
}

/// `wav` must outlive the sound: SND_ASYNC keeps reading the buffer while it plays.
pub fn play_sound(wav: &'static [u8]) {
    unsafe {
        let _ = PlaySoundW(PCWSTR(wav.as_ptr().cast()), None, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    }
}

pub fn beep() {
    unsafe {
        let _ = MessageBeep(MB_OK);
    }
}

/// Shelf and pins stay out of our own captures (and any other screen capture) without hiding them.
pub fn prepare_floating(window: &WebviewWindow) {
    let Some(h) = hwnd(window) else { return };
    let h = h.0 as isize;
    let _ = window.run_on_main_thread(move || unsafe {
        if let Err(e) = SetWindowDisplayAffinity(HWND(h as _), WDA_EXCLUDEFROMCAPTURE) {
            log::warn!("display affinity not set: {e}");
        }
    });
}

/// Shows a window without activating it, so the app the user is in keeps the keyboard.
pub fn show_without_focus(window: &WebviewWindow) {
    let Some(h) = hwnd(window) else { return };
    let h = h.0 as isize;
    let _ = window.run_on_main_thread(move || unsafe {
        let h = HWND(h as _);
        let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
        let _ = SetWindowPos(h, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    });
}

/// Hides a window shown with `show_without_focus` (Tauri's own flag never saw it shown).
pub fn hide(window: &WebviewWindow) {
    let Some(h) = hwnd(window) else { return };
    let h = h.0 as isize;
    let _ = window.run_on_main_thread(move || unsafe {
        let _ = ShowWindow(HWND(h as _), SW_HIDE);
    });
}

pub fn mouse_button_down() -> bool {
    [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON].iter().any(|vk| unsafe { GetAsyncKeyState(vk.0 as i32) } as u16 & 0x8000 != 0)
}

fn reg_dword(subkey: PCWSTR, value: PCWSTR) -> Option<u32> {
    let mut data = 0u32;
    let mut size = 4u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey,
            value,
            RRF_RT_REG_DWORD,
            None,
            Some((&mut data as *mut u32).cast()),
            Some(&mut size),
        )
    };
    (status == ERROR_SUCCESS).then_some(data)
}

/// The Windows accent colour (stored as 0xAABBGGRR).
pub fn accent_color() -> String {
    match reg_dword(w!(r"Software\Microsoft\Windows\DWM"), w!("AccentColor")) {
        Some(abgr) => format!("#{:02X}{:02X}{:02X}", abgr & 0xFF, (abgr >> 8) & 0xFF, (abgr >> 16) & 0xFF),
        None => "#0078D4".into(),
    }
}

const KEYBOARD_KEY: PCWSTR = w!(r"Control Panel\Keyboard");
const SNIPPING_VALUE: PCWSTR = w!("PrintScreenKeyForSnippingEnabled");

pub fn print_screen_opens_snipping_tool() -> bool {
    reg_dword(KEYBOARD_KEY, SNIPPING_VALUE) == Some(1)
}

pub fn set_print_screen_opens_snipping_tool(enabled: bool) -> Result<(), String> {
    let value: u32 = enabled.into();
    let status = unsafe {
        RegSetKeyValueW(HKEY_CURRENT_USER, KEYBOARD_KEY, SNIPPING_VALUE, REG_DWORD.0, Some((&value as *const u32).cast()), 4)
    };
    if status != ERROR_SUCCESS {
        return Err(format!("The keyboard setting could not be changed ({}).", status.0));
    }
    // Lets the shell pick the change up without signing out.
    let area = wide("Keyboard");
    unsafe {
        let _ = SendMessageTimeoutW(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            WPARAM(0),
            LPARAM(area.as_ptr() as isize),
            SMTO_ABORTIFHUNG,
            500,
            None,
        );
    }
    Ok(())
}

pub fn show_in_explorer(path: &Path) -> Result<(), String> {
    std::process::Command::new("explorer")
        .raw_arg(format!("/select,\"{}\"", path.display()))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

pub fn open_folder(path: &Path) -> Result<(), String> {
    std::process::Command::new("explorer")
        .raw_arg(format!("\"{}\"", path.display()))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}
