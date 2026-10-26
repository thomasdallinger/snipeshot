//! Freezes every monitor with GDI before the selector appears, and lists the windows that can be
//! picked. All coordinates are physical pixels of the virtual screen (the thread is per-monitor-v2).

use std::mem::size_of;

use windows::{
    core::BOOL,
    Win32::{
        Foundation::{HWND, LPARAM, POINT, RECT},
        Graphics::{
            Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS},
            Gdi::{
                BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, EnumDisplayMonitors, GdiFlush,
                GetDC, GetMonitorInfoW, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT,
                DIB_RGB_COLORS, HDC, HMONITOR, MONITORINFO, SRCCOPY,
            },
        },
        UI::{
            HiDpi::{GetDpiForMonitor, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI},
            WindowsAndMessaging::{
                EnumWindows, GetClassNameW, GetCursorPos, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId,
                IsIconic, IsWindowVisible, GWL_EXSTYLE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
            },
        },
    },
};

use super::overlay;
use crate::{
    layout::Rect,
    platform::{Grab, PickMode},
};

/// One monitor's pixels: top-down BGRA (alpha undefined).
pub(super) struct Frozen {
    pub rect: Rect,
    pub scale: f64,
    pub bgra: Vec<u8>,
}

impl Frozen {
    /// The pixels inside `local` as an opaque RGBA grab.
    fn crop(&self, local: Rect) -> Grab {
        let r = local.intersect(&Rect::new(0, 0, self.rect.w, self.rect.h));
        let mut rgba = Vec::with_capacity((r.w * r.h * 4).max(0) as usize);
        for y in r.y..r.bottom() {
            let start = ((y * self.rect.w + r.x) * 4) as usize;
            for p in self.bgra[start..start + r.w as usize * 4].chunks_exact(4) {
                rgba.extend_from_slice(&[p[2], p[1], p[0], 255]);
            }
        }
        Grab { rgba, width: r.w as u32, height: r.h as u32, scale: self.scale, monitor: self.rect }
    }
}

fn dpi_aware_thread() {
    unsafe {
        let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}

fn monitors() -> Vec<(Rect, f64)> {
    unsafe extern "system" fn each(monitor: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let out = unsafe { &mut *(data.0 as *mut Vec<(Rect, f64)>) };
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        if unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) };
            out.push((rect(info.rcMonitor), dx as f64 / 96.0));
        }
        true.into()
    }
    let mut out: Vec<(Rect, f64)> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

fn rect(r: RECT) -> Rect {
    Rect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
}

/// Copies a screen rectangle through a DIB section.
fn bitblt(area: Rect) -> Result<Vec<u8>, String> {
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return Err("The screen could not be read.".into());
        }
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: area.w,
                biHeight: -area.h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let result = match CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(dib) => {
                let old = SelectObject(mem, dib.into());
                // CAPTUREBLT includes layered windows (menus, tooltips, translucent apps).
                let copied = BitBlt(mem, 0, 0, area.w, area.h, Some(screen), area.x, area.y, SRCCOPY | CAPTUREBLT);
                let _ = GdiFlush();
                let out = copied
                    .map(|_| std::slice::from_raw_parts(bits as *const u8, (area.w * area.h * 4) as usize).to_vec())
                    .map_err(|e| format!("The screen could not be copied: {e}"));
                SelectObject(mem, old);
                let _ = DeleteObject(dib.into());
                out
            }
            Err(e) => Err(format!("No memory for the capture: {e}")),
        };
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        result
    }
}

fn freeze_all() -> Result<Vec<Frozen>, String> {
    let mut out = Vec::new();
    for (rect, scale) in monitors() {
        match bitblt(rect) {
            Ok(bgra) => out.push(Frozen { rect, scale, bgra }),
            Err(e) => log::warn!("monitor at {},{} not captured: {e}", rect.x, rect.y),
        }
    }
    if out.is_empty() {
        return Err("There is no screen to capture.".into());
    }
    Ok(out)
}

fn cursor() -> (i32, i32) {
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    (p.x, p.y)
}

/// Shell surfaces that are not windows you would pick.
const SKIPPED_CLASSES: [&str; 4] = ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"];

/// Normal, visible app windows front to back, by their visible frame (without the resize border).
fn window_targets() -> Vec<Rect> {
    unsafe extern "system" fn each(hwnd: HWND, data: LPARAM) -> BOOL {
        let out = unsafe { &mut *(data.0 as *mut Vec<Rect>) };
        if let Some(r) = unsafe { target(hwnd) } {
            out.push(r);
        }
        true.into()
    }
    let mut out: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

unsafe fn target(hwnd: HWND) -> Option<Rect> {
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == std::process::id() {
            return None;
        }
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        if ex & (WS_EX_TOOLWINDOW.0 | WS_EX_TRANSPARENT.0) != 0 {
            return None;
        }
        let mut cloaked = 0u32;
        if DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), 4).is_ok() && cloaked != 0 {
            return None;
        }
        let mut class = [0u16; 64];
        let len = GetClassNameW(hwnd, &mut class) as usize;
        let class = String::from_utf16_lossy(&class[..len]);
        if SKIPPED_CLASSES.contains(&class.as_str()) {
            return None;
        }
        let mut r = RECT::default();
        let framed =
            DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, (&mut r as *mut RECT).cast(), size_of::<RECT>() as u32);
        if framed.is_err() && GetWindowRect(hwnd, &mut r).is_err() {
            return None;
        }
        let r = rect(r);
        (r.w > 40 && r.h > 40).then_some(r)
    }
}

/// Runs the selector over frozen screens. None when the user cancels.
pub fn pick(mode: PickMode) -> Result<Option<Grab>, String> {
    dpi_aware_thread();
    let frozen = freeze_all()?;
    let targets = window_targets();
    Ok(overlay::run(frozen, targets, mode, cursor())?.map(|(screen, local)| screen.crop(local)))
}

/// The whole monitor under the pointer, no selector.
pub fn grab_screen() -> Result<Option<Grab>, String> {
    dpi_aware_thread();
    let (x, y) = cursor();
    let all = monitors();
    let (rect, scale) = all
        .iter()
        .find(|(r, _)| r.contains(x, y))
        .or(all.first())
        .copied()
        .ok_or("There is no screen to capture.")?;
    let frozen = Frozen { rect, scale, bgra: bitblt(rect)? };
    Ok(Some(frozen.crop(Rect::new(0, 0, rect.w, rect.h))))
}
