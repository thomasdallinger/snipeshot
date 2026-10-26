//! Recent captures stacked in the bottom-left corner of the screen they were taken on. Rust owns
//! the list and the window's size and place; the cards are drawn by the frontend. The shelf follows
//! the pointer to other monitors, but never while a button is held or the pointer is over a card.

use std::{
    path::{Path, PathBuf},
    thread,
    time::Duration,
};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::{
    edits,
    layout::{self, Monitor, Rect},
    library::millis,
    platform, state,
};

pub const LABEL: &str = "shelf";

pub struct Entry {
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
}

#[derive(Default)]
pub struct Shelf {
    pub items: Vec<Entry>,
    pub monitor: Option<Monitor>,
    pub hovering: bool,
    /// Last frame applied to the window, to skip redundant moves.
    placed: Option<Rect>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfItem {
    pub path: String,
    pub width: u32,
    pub height: u32,
    pub preview_path: String,
    pub modified_at: i64,
}

pub fn create_window(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html#/shelf".into()))
        .title("Snipeshot shelf")
        .inner_size(layout::CARD_WIDTH + 36.0, 200.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focusable(false)
        .focused(false)
        .visible(false)
        .build()?;
    platform::prepare_floating(&window);
    Ok(())
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(LABEL)
}

/// Monitors with their work areas, in physical pixels.
pub fn monitors(app: &AppHandle) -> Vec<Monitor> {
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| {
            let (p, s, wa) = (m.position(), m.size(), m.work_area());
            Monitor {
                rect: Rect::new(p.x, p.y, s.width as i32, s.height as i32),
                work: Rect::new(wa.position.x, wa.position.y, wa.size.width as i32, wa.size.height as i32),
                scale: m.scale_factor(),
            }
        })
        .collect()
}

pub fn cursor_monitor(app: &AppHandle, all: &[Monitor]) -> Option<Monitor> {
    let p = app.cursor_position().ok()?;
    layout::monitor_at(all, p.x.floor() as i32, p.y.floor() as i32).copied()
}

fn item(paths: &edits::Paths, e: &Entry) -> ShelfItem {
    let edit = paths.state(&e.path);
    let image_modified = edits::modified(&e.path);
    ShelfItem {
        path: e.path.to_string_lossy().into_owned(),
        width: e.width,
        height: e.height,
        preview_path: edit.cache.as_deref().unwrap_or(&e.path).to_string_lossy().into_owned(),
        modified_at: image_modified.max(edit.edit_modified).map(millis).unwrap_or(0),
    }
}

/// Oldest first, top to bottom.
pub fn items(app: &AppHandle) -> Vec<ShelfItem> {
    let st = state(app);
    let shelf = st.shelf.lock();
    shelf.items.iter().map(|e| item(&st.edits, e)).collect()
}

pub fn contains(app: &AppHandle, path: &Path) -> bool {
    state(app).shelf.lock().items.iter().any(|e| e.path == path)
}

/// Tells the shelf page and puts the window where the cards are.
pub fn changed(app: &AppHandle) {
    let _ = app.emit_to(LABEL, "shelf-changed", items(app));
    place(app);
}

fn place(app: &AppHandle) {
    let Some(window) = window(app) else { return };
    let st = state(app);
    let mut shelf = st.shelf.lock();
    let Some(monitor) = shelf.monitor.filter(|_| !shelf.items.is_empty()) else {
        shelf.placed = None;
        drop(shelf);
        platform::hide(&window);
        return;
    };
    let dims: Vec<(u32, u32)> = shelf.items.iter().map(|e| (e.width, e.height)).collect();
    let frame = layout::shelf_frame(&dims, monitor.work, monitor.scale);
    if shelf.placed == Some(frame) {
        return;
    }
    shelf.placed = Some(frame);
    drop(shelf);
    // Position first so a DPI change between monitors does not rescale the new size.
    let _ = window.set_position(PhysicalPosition::new(frame.x, frame.y));
    let _ = window.set_size(PhysicalSize::new(frame.w as u32, frame.h as u32));
    let _ = window.set_position(PhysicalPosition::new(frame.x, frame.y));
    platform::show_without_focus(&window);
}

/// Adds a capture taken on `monitor` (the newest goes to the bottom; at most five).
pub fn add(app: &AppHandle, path: PathBuf, width: u32, height: u32, monitor: Rect) {
    let all = monitors(app);
    let target = all.iter().find(|m| m.rect == monitor).copied().or_else(|| cursor_monitor(app, &all)).or(all.first().copied());
    {
        let st = state(app);
        let mut shelf = st.shelf.lock();
        shelf.monitor = target.or(shelf.monitor);
        shelf.items.retain(|e| e.path != path);
        shelf.items.push(Entry { path, width, height });
        let excess = shelf.items.len().saturating_sub(layout::SHELF_MAX_ITEMS);
        shelf.items.drain(..excess);
    }
    changed(app);
}

pub fn remove(app: &AppHandle, path: &Path) {
    let removed = {
        let st = state(app);
        let mut shelf = st.shelf.lock();
        let before = shelf.items.len();
        shelf.items.retain(|e| e.path != path);
        if shelf.items.is_empty() {
            shelf.hovering = false;
        }
        shelf.items.len() != before
    };
    if removed {
        changed(app);
    }
}

pub fn clear(app: &AppHandle) {
    let had = {
        let st = state(app);
        let mut shelf = st.shelf.lock();
        let had = !shelf.items.is_empty();
        shelf.items.clear();
        shelf.hovering = false;
        had
    };
    if had {
        changed(app);
    }
}

pub fn set_hover(app: &AppHandle, hovering: bool) {
    state(app).shelf.lock().hovering = hovering;
}

/// Every 250 ms: move the shelf to the monitor under the pointer when the rules allow it.
pub fn spawn_follow(app: AppHandle) {
    thread::spawn(move || loop {
        thread::sleep(Duration::from_millis(250));
        let (anchor, hovering, empty) = {
            let st = state(&app);
            let shelf = st.shelf.lock();
            (shelf.monitor, shelf.hovering, shelf.items.is_empty())
        };
        if empty {
            continue;
        }
        let all = monitors(&app);
        let under = cursor_monitor(&app, &all);
        if layout::should_follow(anchor.as_ref(), under.as_ref(), platform::mouse_button_down(), hovering) {
            state(&app).shelf.lock().monitor = under;
            place(&app);
        } else if let Some(current) = anchor.and_then(|a| all.iter().find(|m| m.rect == a.rect && **m != a)) {
            // Same monitor, new work area or scale (taskbar moved, display settings changed).
            state(&app).shelf.lock().monitor = Some(*current);
            place(&app);
        }
    });
}
