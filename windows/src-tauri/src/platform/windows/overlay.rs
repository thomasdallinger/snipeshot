//! The selector: one topmost borderless window per monitor showing the frozen screen, lightly
//! dimmed. Drag for an area, click for the window under the pointer, Space switches area/window
//! mode, Esc or right-click cancels, Alt hides the loupe.
//!
//! Drawing is double-buffered: each window keeps a DIB back buffer, repaints only the invalidated
//! region (the old and new positions of the guides, loupe, labels and selection) and blits it in one go.

use std::{cell::RefCell, mem::size_of, sync::Once};

use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM},
        Graphics::{
            Dwm::{DwmSetWindowAttribute, DWMWA_TRANSITIONS_FORCEDISABLED},
            Gdi::{
                BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, CreateFontW, CreateRectRgn, DeleteDC,
                DeleteObject, EndPaint, GdiFlush, GetRegionData, GetTextExtentPoint32W, GetUpdateRgn, InvalidateRect,
                SelectObject, SetBkMode, SetTextColor, TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
                CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DEFAULT_PITCH, DIB_RGB_COLORS, FF_DONTCARE,
                FW_NORMAL, FW_SEMIBOLD, HBITMAP, HDC, HFONT, HGDIOBJ, OUT_DEFAULT_PRECIS, PAINTSTRUCT, RGNDATA,
                RGNDATAHEADER, SRCCOPY, TRANSPARENT,
            },
        },
        System::{LibraryLoader::GetModuleHandleW, Threading::{AttachThreadInput, GetCurrentThreadId}},
        UI::{
            Input::KeyboardAndMouse::{
                ReleaseCapture, SetCapture, SetFocus, TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT, VIRTUAL_KEY, VK_ESCAPE,
                VK_LMENU, VK_MENU, VK_RMENU, VK_SPACE,
            },
            WindowsAndMessaging::{
                BringWindowToTop, CallNextHookEx, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
                GetForegroundWindow, GetMessageW, GetWindowThreadProcessId, IsWindow, LoadCursorW, PostMessageW, PostQuitMessage,
                RegisterClassExW, SetCursor, SetForegroundWindow, SetWindowsHookExW, ShowWindow, TranslateMessage,
                UnhookWindowsHookEx, HC_ACTION, IDC_CROSS, KBDLLHOOKSTRUCT, MSG, SC_KEYMENU, SW_SHOW, WH_KEYBOARD_LL,
                WM_CLOSE, WM_DISPLAYCHANGE, WM_ERASEBKGND, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP,
                WM_MOUSEMOVE, WM_PAINT, WM_RBUTTONUP, WM_SYSCOMMAND, WM_SYSKEYDOWN, WM_SYSKEYUP,
                WM_APP, WNDCLASSEXW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
            },
        },
    },
};

use super::grab::Frozen;
use crate::{
    layout::{loupe_origin, size_tag_origin, window_at, Rect},
    platform::PickMode,
    raster::{compose_dimmed, rrect_sdf, Canvas, RectF, Rgb, BLACK, WHITE},
};

const CLASS: PCWSTR = w!("SnipeshotSelector");
/// Brightness kept by the dim: 0.12 black over the whole screen, 0.32 around a selection.
const KEEP_LIGHT: u32 = 225;
const KEEP_DARK: u32 = 174;
const LOUPE_CELLS: i32 = 15;

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// Runs `f` on the live session; None when there is none or it is busy (a re-entrant message).
fn with_session<R>(f: impl FnOnce(&mut Session) -> R) -> Option<R> {
    SESSION.with(|cell| cell.try_borrow_mut().ok().and_then(|mut s| s.as_mut().map(f)))
}

struct Session {
    mode: PickMode,
    hide_loupe: bool,
    space_down: bool,
    done: bool,
    result: Option<(usize, Rect)>,
    /// Pickable windows, virtual-screen pixels, front to back.
    targets: Vec<Rect>,
    overlays: Vec<Overlay>,
}

struct Fonts {
    tag: HFONT,
    key: HFONT,
    text: HFONT,
}

struct Overlay {
    hwnd: HWND,
    screen: Frozen,
    dc: HDC,
    bitmap: HBITMAP,
    old_bitmap: HGDIOBJ,
    bits: *mut u8,
    fonts: Fonts,
    cursor: Option<(i32, i32)>,
    anchor: Option<(i32, i32)>,
    current: Option<(i32, i32)>,
    dragging: bool,
    tracking: bool,
    /// What the last paint drew on top of the plain dimmed screen.
    painted: Vec<Rect>,
    painted_dark: bool,
}

/// A text label: its plate and where the text goes.
struct Tag {
    plate: Rect,
    text: Vec<u16>,
    at: (i32, i32),
}

struct Hint {
    cap: Rect,
    key: Vec<u16>,
    key_at: (i32, i32),
    label: Vec<u16>,
    label_at: (i32, i32),
}

/// Everything one frame draws, in window pixels.
#[derive(Default)]
struct Frame {
    cutout: Option<Rect>,
    selection: Option<Rect>,
    window: Option<Rect>,
    guides: Option<(i32, i32)>,
    size_tag: Option<Tag>,
    loupe: Option<(Rect, (i32, i32), Tag)>,
    hints: Option<(Rect, Vec<Hint>)>,
}

impl Overlay {
    fn bounds(&self) -> Rect {
        Rect::new(0, 0, self.screen.rect.w, self.screen.rect.h)
    }

    /// Points to pixels on this monitor.
    fn p(&self, points: f64) -> i32 {
        (points * self.screen.scale).round() as i32
    }

    fn line(&self) -> i32 {
        self.p(1.0).max(1)
    }

    fn back(&mut self) -> Canvas<'_> {
        let (w, h) = (self.screen.rect.w, self.screen.rect.h);
        let px = unsafe { std::slice::from_raw_parts_mut(self.bits, (w * h * 4) as usize) };
        Canvas { px, w, h }
    }

    fn measure(&self, font: HFONT, text: &[u16]) -> (i32, i32) {
        let mut size = Default::default();
        unsafe {
            SelectObject(self.dc, font.into());
            let _ = GetTextExtentPoint32W(self.dc, text, &mut size);
        }
        (size.cx, size.cy)
    }

    fn tag(&self, text: &str, origin: (i32, i32)) -> Tag {
        let text: Vec<u16> = text.encode_utf16().collect();
        let (tw, th) = self.measure(self.fonts.tag, &text);
        let (px, py) = (self.p(6.0), self.p(3.0));
        Tag { plate: Rect::new(origin.0, origin.1, tw + 2 * px, th + 2 * py), text, at: (origin.0 + px, origin.1 + py) }
    }

    fn hex(&self, x: i32, y: i32) -> String {
        if !self.bounds().contains(x, y) {
            return String::new();
        }
        let i = ((y * self.screen.rect.w + x) * 4) as usize;
        let b = &self.screen.bgra[i..i + 3];
        format!("#{:02X}{:02X}{:02X}", b[2], b[1], b[0])
    }

    /// The window under the pointer, clipped to this monitor, in window pixels.
    fn hovered(&self, targets: &[Rect]) -> Option<Rect> {
        let (x, y) = self.cursor?;
        let origin = (self.screen.rect.x, self.screen.rect.y);
        let t = window_at(targets, x + origin.0, y + origin.1)?;
        let local = t.offset(-origin.0, -origin.1).intersect(&self.bounds());
        (!local.is_empty()).then_some(local)
    }

    fn selection(&self, mode: PickMode) -> Option<Rect> {
        if mode != PickMode::Area || !self.dragging {
            return None;
        }
        let r = Rect::spanning(self.anchor?, self.current?).intersect(&self.bounds());
        (!r.is_empty()).then_some(r)
    }

    fn frame(&self, mode: PickMode, hide_loupe: bool, targets: &[Rect]) -> Frame {
        let mut f = Frame::default();
        let bounds = self.bounds();
        if let Some(sel) = self.selection(mode) {
            f.cutout = Some(sel);
            f.selection = Some(sel);
            let w = sel.w;
            let h = sel.h;
            let probe = self.tag(&format!("{w} \u{00D7} {h}"), (0, 0));
            let at = size_tag_origin(sel, probe.plate.w, probe.plate.h, self.p(6.0), self.p(4.0), bounds);
            f.size_tag = Some(self.tag(&format!("{w} \u{00D7} {h}"), at));
        } else if let (PickMode::Window, Some(win)) = (mode, self.hovered(targets)) {
            f.cutout = Some(win);
            f.window = Some(win);
        } else if mode == PickMode::Area {
            f.guides = self.cursor;
        }
        if let (Some(p), PickMode::Area, false) = (self.cursor, mode, hide_loupe) {
            let side = self.p(112.0);
            let origin = loupe_origin(p, side, self.p(20.0), self.p(30.0), bounds);
            let loupe = Rect::new(origin.0, origin.1, side, side);
            let (gx, gy) = (p.0 + self.screen.rect.x, p.1 + self.screen.rect.y);
            let tag = self.tag(&format!("{gx}, {gy}   {}", self.hex(p.0, p.1)), (loupe.x, loupe.bottom() + self.p(6.0)));
            f.loupe = Some((loupe, p, tag));
        }
        if self.cursor.is_some() {
            f.hints = Some(self.hints(mode));
        }
        f
    }

    /// One line of keycaps at the bottom of the monitor.
    fn hints(&self, mode: PickMode) -> (Rect, Vec<Hint>) {
        let pairs: &[(&str, &str)] = match mode {
            PickMode::Area => {
                &[("drag", "area"), ("click", "window"), ("space", "pick windows"), ("alt", "no magnifier"), ("esc", "cancel")]
            }
            PickMode::Window => &[("click", "window"), ("space", "draw an area"), ("esc", "cancel")],
        };
        let (pad, cap_pad, after_cap, gap) = (self.p(12.0), self.p(5.0), self.p(6.0), self.p(16.0));
        let measured: Vec<_> = pairs
            .iter()
            .map(|(k, t)| {
                let (k, t): (Vec<u16>, Vec<u16>) = (k.encode_utf16().collect(), t.encode_utf16().collect());
                let (ks, ts) = (self.measure(self.fonts.key, &k), self.measure(self.fonts.text, &t));
                (k, ks, t, ts)
            })
            .collect();
        let total: i32 = measured.iter().map(|(_, ks, _, ts)| ks.0 + 2 * cap_pad + after_cap + ts.0).sum::<i32>()
            + gap * (measured.len() as i32 - 1);
        let (bar_w, bar_h) = (total + 2 * pad, self.p(30.0));
        let bounds = self.bounds();
        let bar = Rect::new((bounds.w - bar_w) / 2, bounds.h - self.p(64.0), bar_w, bar_h);
        let mid = bar.y + bar_h / 2;
        let cap_h = self.p(18.0);
        let mut x = bar.x + pad;
        let mut items = Vec::new();
        for (key, ks, label, ts) in measured {
            let cap = Rect::new(x, mid - cap_h / 2, ks.0 + 2 * cap_pad, cap_h);
            let key_at = (cap.x + cap_pad, mid - ks.1 / 2);
            x = cap.right() + after_cap;
            let label_at = (x, mid - ts.1 / 2);
            x += ts.0 + gap;
            items.push(Hint { cap, key, key_at, label, label_at });
        }
        (bar, items)
    }

    /// Areas that differ from the plain dimmed screen; repainted when they change.
    fn dirty(&self, f: &Frame) -> Vec<Rect> {
        let mut out = Vec::new();
        let grow = self.p(2.0) + 2;
        if let Some(c) = f.cutout {
            out.push(c.inset(-grow));
        }
        if let Some((x, y)) = f.guides {
            let l = self.line();
            out.push(Rect::new(0, y, self.screen.rect.w, l));
            out.push(Rect::new(x, 0, l, self.screen.rect.h));
        }
        if let Some(t) = &f.size_tag {
            out.push(t.plate);
        }
        if let Some((loupe, _, tag)) = &f.loupe {
            let blur = self.p(10.0) + self.p(2.0) + 2;
            out.push(loupe.inset(-blur));
            out.push(tag.plate);
        }
        if let Some((bar, _)) = &f.hints {
            out.push(*bar);
        }
        out
    }

    fn text(&self, font: HFONT, color: Rgb, at: (i32, i32), text: &[u16]) {
        unsafe {
            SelectObject(self.dc, font.into());
            SetTextColor(self.dc, COLORREF(color[0] as u32 | (color[1] as u32) << 8 | (color[2] as u32) << 16));
            let _ = TextOutW(self.dc, at.0, at.1, text);
        }
    }

    fn draw_tag(&mut self, tag: &Tag) {
        let radius = self.p(4.0) as f32;
        self.back().fill_round_rect(tag.plate.into(), radius, BLACK, 0.78);
        self.text(self.fonts.tag, WHITE, tag.at, &tag.text);
        unsafe {
            let _ = GdiFlush();
        }
    }

    /// Magnified pixels around the pointer with a pixel grid, the pointer's pixel outlined.
    fn draw_loupe(&mut self, loupe: Rect, p: (i32, i32)) {
        let radius = self.p(8.0) as f32;
        let shape: RectF = loupe.into();
        let shadow = RectF { y: shape.y + self.p(2.0) as f32, ..shape };
        let blur = self.p(10.0) as f32;
        let cell = loupe.w as f32 / LOUPE_CELLS as f32;
        let half = LOUPE_CELLS / 2;
        let grid: Vec<bool> = (0..loupe.w)
            .map(|i| (1..LOUPE_CELLS).any(|k| (k as f32 * cell).round() as i32 == i))
            .collect();
        let (sw, sh) = (self.screen.rect.w, self.screen.rect.h);
        let src = self.screen.bgra.as_ptr();
        let mut canvas = self.back();
        canvas.shadow(shadow, radius, blur, 0.4);
        for dy in 0..loupe.h {
            for dx in 0..loupe.w {
                let (x, y) = (loupe.x + dx, loupe.y + dy);
                let cov = (0.5 - rrect_sdf(x as f32 + 0.5, y as f32 + 0.5, shape, radius)).clamp(0.0, 1.0);
                if cov <= 0.0 {
                    continue;
                }
                let cx = ((dx as f32 / cell) as i32).min(LOUPE_CELLS - 1);
                let cy = ((dy as f32 / cell) as i32).min(LOUPE_CELLS - 1);
                let (sx, sy) = (p.0 - half + cx, p.1 - half + cy);
                let mut c: Rgb = if sx >= 0 && sy >= 0 && sx < sw && sy < sh {
                    let i = ((sy * sw + sx) * 4) as usize;
                    // SAFETY: index is inside the frozen buffer of sw × sh pixels.
                    unsafe { [*src.add(i + 2), *src.add(i + 1), *src.add(i)] }
                } else {
                    BLACK
                };
                if grid[dx as usize] || grid[dy as usize] {
                    c = c.map(|v| (v as f32 * 0.85) as u8);
                }
                canvas.blend(x, y, c, cov);
            }
        }
        let a = (half as f32 * cell).round() as i32;
        let b = ((half + 1) as f32 * cell).round() as i32;
        let ring = (self.screen.scale * 1.5).round().max(1.0) as i32;
        let center = Rect::new(loupe.x + a, loupe.y + a, b - a, b - a).inset(-(ring / 2));
        let line = self.line() as f32;
        let mut canvas = self.back();
        canvas.stroke_rect(center, ring, WHITE, 1.0);
        canvas.stroke_round_rect(shape, radius, line, WHITE, 0.7);
    }

    fn draw(&mut self, f: &Frame) {
        let line = self.line();
        if let Some(sel) = f.selection {
            self.back().stroke_rect(sel.inset(-line), line, WHITE, 1.0);
        }
        if let Some(win) = f.window {
            let width = self.p(2.0).max(1);
            self.back().stroke_rect(win, width, WHITE, 1.0);
        }
        if let Some((x, y)) = f.guides {
            let (w, h) = (self.screen.rect.w, self.screen.rect.h);
            let mut c = self.back();
            c.fill_rect(Rect::new(0, y, w, line), WHITE, 0.35);
            c.fill_rect(Rect::new(x, 0, line, y), WHITE, 0.35);
            c.fill_rect(Rect::new(x, y + line, line, h - y - line), WHITE, 0.35);
        }
        if let Some(tag) = &f.size_tag {
            self.draw_tag(tag);
        }
        if let Some((loupe, p, tag)) = &f.loupe {
            self.draw_loupe(*loupe, *p);
            self.draw_tag(tag);
        }
        if let Some((bar, items)) = &f.hints {
            let (r8, r4) = (self.p(8.0) as f32, self.p(4.0) as f32);
            {
                let mut c = self.back();
                c.fill_round_rect((*bar).into(), r8, BLACK, 0.72);
                for item in items {
                    c.fill_round_rect(item.cap.into(), r4, WHITE, 0.16);
                }
            }
            for item in items {
                self.text(self.fonts.key, WHITE, item.key_at, &item.key);
                self.text(self.fonts.text, [214, 214, 214], item.label_at, &item.label);
            }
        }
    }
}

impl Session {
    fn index(&self, hwnd: HWND) -> Option<usize> {
        self.overlays.iter().position(|o| o.hwnd == hwnd)
    }

    fn frame(&self, i: usize) -> Frame {
        self.overlays[i].frame(self.mode, self.hide_loupe, &self.targets)
    }

    /// Invalidates what was painted last time and what the next frame will paint.
    fn refresh(&mut self, i: usize) {
        let f = self.frame(i);
        let o = &self.overlays[i];
        let dark = f.cutout.is_some();
        unsafe {
            if dark != o.painted_dark {
                let _ = InvalidateRect(Some(o.hwnd), None, false);
                return;
            }
            for r in o.painted.iter().chain(o.dirty(&f).iter()) {
                let rc = RECT { left: r.x, top: r.y, right: r.right(), bottom: r.bottom() };
                let _ = InvalidateRect(Some(o.hwnd), Some(&rc), false);
            }
        }
    }

    fn refresh_all(&mut self) {
        for i in 0..self.overlays.len() {
            self.refresh(i);
        }
    }

    fn paint(&mut self, i: usize) {
        let f = self.frame(i);
        let o = &mut self.overlays[i];
        unsafe {
            let region = CreateRectRgn(0, 0, 0, 0);
            GetUpdateRgn(o.hwnd, region, false);
            let mut rects = region_rects(region);
            let _ = DeleteObject(region.into());
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(o.hwnd, &mut ps);
            if rects.is_empty() {
                let rc = ps.rcPaint;
                rects.push(Rect::new(rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top));
            }
            let (w, h) = (o.screen.rect.w, o.screen.rect.h);
            let keep = if f.cutout.is_some() { KEEP_DARK } else { KEEP_LIGHT };
            let back = std::slice::from_raw_parts_mut(o.bits, (w * h * 4) as usize);
            for r in &rects {
                compose_dimmed(&o.screen.bgra, back, w, *r, f.cutout, keep);
            }
            o.draw(&f);
            let _ = GdiFlush();
            let rc = ps.rcPaint;
            let _ = BitBlt(hdc, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, Some(o.dc), rc.left, rc.top, SRCCOPY);
            let _ = EndPaint(o.hwnd, &ps);
        }
        o.painted = o.dirty(&f);
        o.painted_dark = f.cutout.is_some();
    }

    fn finish(&mut self, result: Option<(usize, Rect)>) {
        if self.done {
            return;
        }
        self.done = true;
        self.result = result;
        unsafe { PostQuitMessage(0) };
    }

    fn toggle_mode(&mut self) {
        self.mode = match self.mode {
            PickMode::Area => PickMode::Window,
            PickMode::Window => PickMode::Area,
        };
        for o in &mut self.overlays {
            o.anchor = None;
            o.current = None;
            o.dragging = false;
        }
        self.refresh_all();
    }

    fn set_hide_loupe(&mut self, hide: bool) {
        if self.hide_loupe != hide {
            self.hide_loupe = hide;
            self.refresh_all();
        }
    }

    fn key(&mut self, vk: VIRTUAL_KEY, down: bool) {
        match vk {
            VK_ESCAPE if down => self.finish(None),
            VK_SPACE => {
                if down && !self.space_down {
                    self.toggle_mode();
                }
                self.space_down = down;
            }
            VK_MENU | VK_LMENU | VK_RMENU => self.set_hide_loupe(down),
            _ => {}
        }
    }

    fn handle(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> Option<LRESULT> {
        let i = self.index(hwnd)?;
        let point = || ((lparam.0 & 0xFFFF) as i16 as i32, ((lparam.0 >> 16) & 0xFFFF) as i16 as i32);
        match msg {
            WM_PAINT => self.paint(i),
            WM_MOUSEMOVE => {
                let p = point();
                // The pointer left another monitor without a leave message (fast moves).
                for j in 0..self.overlays.len() {
                    if j != i && self.overlays[j].cursor.is_some() && self.overlays[j].anchor.is_none() {
                        self.overlays[j].cursor = None;
                        self.refresh(j);
                    }
                }
                let mode = self.mode;
                let o = &mut self.overlays[i];
                o.cursor = Some(p);
                if !o.tracking {
                    let mut tme = TRACKMOUSEEVENT {
                        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 0,
                    };
                    o.tracking = unsafe { TrackMouseEvent(&mut tme) }.is_ok();
                }
                if let (Some(a), PickMode::Area) = (o.anchor, mode) {
                    o.current = Some(p);
                    let threshold = 3.0 * o.screen.scale;
                    if !o.dragging && (((p.0 - a.0).pow(2) + (p.1 - a.1).pow(2)) as f64).sqrt() > threshold {
                        o.dragging = true;
                    }
                }
                self.refresh(i);
            }
            WM_MOUSELEAVE => {
                let o = &mut self.overlays[i];
                o.tracking = false;
                if o.anchor.is_none() {
                    o.cursor = None;
                    self.refresh(i);
                }
            }
            WM_LBUTTONDOWN => {
                let p = point();
                let o = &mut self.overlays[i];
                o.cursor = Some(p);
                o.anchor = Some(p);
                o.current = Some(p);
                o.dragging = false;
                unsafe { SetCapture(hwnd) };
            }
            WM_LBUTTONUP => {
                // Capture release is deferred: it sends WM_CAPTURECHANGED while we hold the session.
                let _ = unsafe { PostMessageW(Some(hwnd), WM_RELEASE, WPARAM(0), LPARAM(0)) };
                let p = point();
                let o = &mut self.overlays[i];
                // A button that went down before the selector appeared picks nothing.
                if o.anchor.is_none() {
                    return Some(LRESULT(0));
                }
                if o.dragging {
                    o.current = Some(p);
                }
                let o = &self.overlays[i];
                if let Some(sel) = o.selection(self.mode) {
                    // Tiny drags are treated as a slip, like macOS.
                    self.finish((sel.w >= 2 && sel.h >= 2).then_some((i, sel)));
                } else if let Some(win) = o.hovered(&self.targets) {
                    // A click without dragging takes the window under the pointer.
                    self.finish(Some((i, win)));
                } else {
                    let o = &mut self.overlays[i];
                    o.anchor = None;
                    o.current = None;
                    o.dragging = false;
                    self.refresh(i);
                }
            }
            WM_RBUTTONUP => self.finish(None),
            WM_KEYDOWN | WM_SYSKEYDOWN => self.key(VIRTUAL_KEY(wparam.0 as u16), true),
            WM_KEYUP | WM_SYSKEYUP => self.key(VIRTUAL_KEY(wparam.0 as u16), false),
            WM_DISPLAYCHANGE => self.finish(None),
            _ => return None,
        }
        Some(LRESULT(0))
    }
}

const WM_RELEASE: u32 = WM_APP + 1;
/// Lives in Win32_UI_Controls, which is otherwise not needed.
const WM_MOUSELEAVE: u32 = 0x02A3;

unsafe fn region_rects(region: windows::Win32::Graphics::Gdi::HRGN) -> Vec<Rect> {
    unsafe {
        let size = GetRegionData(region, 0, None);
        if size == 0 {
            return Vec::new();
        }
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let data = buf.as_mut_ptr() as *mut RGNDATA;
        if GetRegionData(region, size, Some(data)) == 0 {
            return Vec::new();
        }
        let header: &RGNDATAHEADER = &(*data).rdh;
        let first = (data as *const u8).add(header.dwSize as usize) as *const RECT;
        (0..header.nCount as usize)
            .map(|k| {
                let r = *first.add(k);
                Rect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
            })
            .collect()
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_ERASEBKGND => return LRESULT(1),
        // No menu-bar mode on Alt.
        WM_SYSCOMMAND if (wparam.0 & 0xFFF0) as u32 == SC_KEYMENU => return LRESULT(0),
        WM_RELEASE => {
            let _ = unsafe { ReleaseCapture() };
            return LRESULT(0);
        }
        WM_CLOSE => {
            with_session(|s| s.finish(None));
            return LRESULT(0);
        }
        _ => {}
    }
    with_session(|s| s.handle(hwnd, msg, wparam, lparam))
        .flatten()
        .unwrap_or_else(|| unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) })
}

/// Esc, Space and Alt reach the selector even when Windows refused to give it the foreground.
unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let kb = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let vk = VIRTUAL_KEY(kb.vkCode as u16);
        let down = matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        match vk {
            VK_ESCAPE | VK_SPACE => {
                with_session(|s| s.key(vk, down));
                return LRESULT(1);
            }
            // Alt passes through: swallowing it would leave other apps with a stuck modifier.
            VK_MENU | VK_LMENU | VK_RMENU => {
                with_session(|s| s.key(VK_MENU, down));
            }
            _ => {}
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

fn register_class() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: GetModuleHandleW(None).unwrap_or_default().into(),
            hCursor: LoadCursorW(None, IDC_CROSS).unwrap_or_default(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);
    });
}

fn font(height: i32, weight: u32) -> HFONT {
    unsafe {
        CreateFontW(
            -height,
            0,
            0,
            0,
            weight as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        )
    }
}

fn create_overlay(screen: Frozen) -> Result<Overlay, String> {
    let r = screen.rect;
    unsafe {
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS,
            w!("Snipeshot"),
            WS_POPUP,
            r.x,
            r.y,
            r.w,
            r.h,
            None,
            None,
            GetModuleHandleW(None).ok().map(Into::into),
            None,
        )
        .map_err(|e| format!("The selector could not open: {e}"))?;
        let off: i32 = 1;
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, (&off as *const i32).cast(), 4);

        let dc = CreateCompatibleDC(None);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: r.w,
                biHeight: -r.h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(b) => b,
            Err(e) => {
                let _ = DeleteDC(dc);
                let _ = DestroyWindow(hwnd);
                return Err(format!("No memory for the selector: {e}"));
            }
        };
        let old_bitmap = SelectObject(dc, bitmap.into());
        SetBkMode(dc, TRANSPARENT);
        let px = |pt: f64| (pt * screen.scale).round() as i32;
        let fonts = Fonts { tag: font(px(11.0), FW_SEMIBOLD.0), key: font(px(11.0), FW_SEMIBOLD.0), text: font(px(12.0), FW_NORMAL.0) };
        Ok(Overlay {
            hwnd,
            screen,
            dc,
            bitmap,
            old_bitmap,
            bits: bits as *mut u8,
            fonts,
            cursor: None,
            anchor: None,
            current: None,
            dragging: false,
            tracking: false,
            painted: Vec::new(),
            painted_dark: false,
        })
    }
}

fn destroy_overlay(o: Overlay) -> Frozen {
    unsafe {
        let _ = DestroyWindow(o.hwnd);
        SelectObject(o.dc, o.old_bitmap);
        // Deleting the DC first frees the selected font, so the fonts can be deleted too.
        let _ = DeleteDC(o.dc);
        let _ = DeleteObject(o.bitmap.into());
        for f in [o.fonts.tag, o.fonts.key, o.fonts.text] {
            let _ = DeleteObject(f.into());
        }
    }
    o.screen
}

/// Brings `hwnd` to the front, borrowing the foreground thread's input state if Windows refuses.
fn force_foreground(hwnd: HWND) {
    unsafe {
        if SetForegroundWindow(hwnd).as_bool() {
            return;
        }
        let fg = GetForegroundWindow();
        let fg_thread = GetWindowThreadProcessId(fg, None);
        let me = GetCurrentThreadId();
        let attached = fg_thread != 0 && fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool();
        let _ = SetForegroundWindow(hwnd);
        let _ = BringWindowToTop(hwnd);
        let _ = SetFocus(Some(hwnd));
        if attached {
            let _ = AttachThreadInput(me, fg_thread, false);
        }
    }
}

/// Shows the selector over `screens` and blocks until the user picks or cancels.
/// Returns the chosen screen and the rectangle on it, in its pixels.
pub(super) fn run(screens: Vec<Frozen>, targets: Vec<Rect>, mode: PickMode, cursor: (i32, i32)) -> Result<Option<(Frozen, Rect)>, String> {
    register_class();
    let previous = unsafe { GetForegroundWindow() };
    let mut overlays = Vec::new();
    for screen in screens {
        match create_overlay(screen) {
            Ok(o) => overlays.push(o),
            Err(e) => {
                overlays.into_iter().for_each(|o| drop(destroy_overlay(o)));
                return Err(e);
            }
        }
    }
    let mut key_window = overlays[0].hwnd;
    for o in &mut overlays {
        let r = o.screen.rect;
        if r.contains(cursor.0, cursor.1) {
            o.cursor = Some((cursor.0 - r.x, cursor.1 - r.y));
            key_window = o.hwnd;
        }
    }
    let hwnds: Vec<HWND> = overlays.iter().map(|o| o.hwnd).collect();
    SESSION.with(|s| {
        *s.borrow_mut() = Some(Session {
            mode,
            hide_loupe: false,
            space_down: false,
            done: false,
            result: None,
            targets,
            overlays,
        })
    });

    let hook = unsafe {
        for &h in &hwnds {
            let _ = ShowWindow(h, SW_SHOW);
        }
        force_foreground(key_window);
        // The class cursor only applies after the next mouse move.
        if let Ok(cross) = LoadCursorW(None, IDC_CROSS) {
            SetCursor(Some(cross));
        }
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), GetModuleHandleW(None).ok().map(Into::into), 0)
    };
    if let Err(e) = &hook {
        log::warn!("keyboard hook not installed, keys need the selector focused: {e}");
    }

    let mut msg = MSG::default();
    loop {
        if with_session(|s| s.done).unwrap_or(true) {
            break;
        }
        let got = unsafe { GetMessageW(&mut msg, None, 0, 0) };
        if got.0 <= 0 {
            break;
        }
        unsafe {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    if let Ok(hook) = hook {
        let _ = unsafe { UnhookWindowsHookEx(hook) };
    }
    let session = SESSION.with(|s| s.borrow_mut().take());
    let Some(session) = session else { return Ok(None) };
    let chosen = session.result;
    let mut picked = None;
    for (i, o) in session.overlays.into_iter().enumerate() {
        let screen = destroy_overlay(o);
        if let Some((index, rect)) = chosen {
            if index == i {
                picked = Some((screen, rect));
            }
        }
    }
    unsafe {
        if !previous.is_invalid() && IsWindow(Some(previous)).as_bool() {
            let _ = SetForegroundWindow(previous);
        }
    }
    Ok(picked)
}
