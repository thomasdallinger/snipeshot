//! Pinned images: borderless always-on-top windows showing a capture at its size in points.
//! Moving, resizing, copying and closing happen in the frontend.

use std::{fs, path::Path, sync::atomic::Ordering};

use tauri::{AppHandle, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

use crate::{imagefile, layout, naming, platform, shelf, state};

/// Opens `image` (already flattened) in a new `pin-<n>` window centred on the monitor under the pointer.
pub fn open(app: &AppHandle, image: &Path, scale: f64) -> Result<(), String> {
    let (width, height, _) = imagefile::info(image).ok_or("The image could not be read.")?;
    let all = shelf::monitors(app);
    let monitor = shelf::cursor_monitor(app, &all).or(all.first().copied()).ok_or("There is no screen to pin to.")?;
    let frame = layout::pin_frame(width, height, scale, &monitor);
    let n = state(app).pin_counter.fetch_add(1, Ordering::Relaxed);
    let url = format!("index.html#/pin?path={}&scale={}", naming::encode_uri_component(&image.to_string_lossy()), scale);
    let window = WebviewWindowBuilder::new(app, format!("pin-{n}"), WebviewUrl::App(url.into()))
        .title("Pinned image")
        .decorations(false)
        .transparent(true)
        .shadow(true)
        .resizable(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;
    let _ = window.set_position(PhysicalPosition::new(frame.x, frame.y));
    let _ = window.set_size(PhysicalSize::new(frame.w as u32, frame.h as u32));
    let _ = window.set_position(PhysicalPosition::new(frame.x, frame.y));
    platform::prepare_floating(&window);
    let _ = window.show();
    let _ = window.set_focus();
    Ok(())
}

/// The clipboard image as a pin; a beep when there is none.
pub fn pin_clipboard(app: &AppHandle) {
    let Some((png, scale)) = platform::clipboard_image() else {
        platform::beep();
        return;
    };
    let dir = state(app).temp_dir.join("Pins");
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S-%3f");
    let path = dir.join(format!("Clipboard {stamp}.png"));
    let written = fs::create_dir_all(&dir).and_then(|_| fs::write(&path, &png));
    if let Err(e) = written.map_err(|e| e.to_string()).and_then(|_| open(app, &path, scale)) {
        log::warn!("clipboard image not pinned: {e}");
        platform::beep();
    }
}
