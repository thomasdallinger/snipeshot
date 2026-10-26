//! Taking a capture and everything that follows, in the macOS order:
//! save → copy (setting) → sound (setting) → shelf (setting) → editor (setting).

use std::{
    sync::atomic::{AtomicBool, Ordering},
    thread,
};

use tauri::AppHandle;

use crate::{
    imagefile, library, naming,
    platform::{self, Grab, PickMode},
    settings::{CaptureKind, FileFormat},
    shelf, state,
};

/// The capture sound, shared with the macOS app.
pub static CAPTURE_WAV: &[u8] = include_bytes!("../../../assets/sounds/capture.wav");

/// One selector at a time; a second shortcut press while it is open does nothing.
static BUSY: AtomicBool = AtomicBool::new(false);

pub fn capture(app: &AppHandle, kind: CaptureKind) {
    if BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    let spawned = thread::Builder::new().name("capture".into()).spawn(move || {
        let result = match kind {
            CaptureKind::Area => platform::pick(PickMode::Area),
            CaptureKind::Window => platform::pick(PickMode::Window),
            CaptureKind::Screen => platform::grab_screen(),
        };
        BUSY.store(false, Ordering::SeqCst);
        match result {
            Ok(Some(grab)) => did_grab(&app, grab),
            Ok(None) => {}
            Err(e) => crate::show_error(&app, "The screen could not be captured", &e),
        }
    });
    if spawned.is_err() {
        BUSY.store(false, Ordering::SeqCst);
    }
}

fn did_grab(app: &AppHandle, grab: Grab) {
    let s = state(app).settings.read().clone();
    let Grab { rgba, width, height, scale, monitor } = grab;
    let png = (s.file_format == FileFormat::Png || s.copy_after_capture)
        .then(|| imagefile::encode_png(&rgba, width, height, scale));
    let encoded = match (s.file_format, &png) {
        (FileFormat::Png, Some(Ok(bytes))) => Ok(bytes.clone()),
        (FileFormat::Png, Some(Err(e))) => Err(e.clone()),
        _ => imagefile::encode_jpeg(&rgba, width, height, scale, s.jpeg_quality),
    };
    let base = naming::capture_name(chrono::Local::now().naive_local());
    let saved = encoded.and_then(|bytes| {
        library::write_new(&s.save_folder(), &base, s.file_format.extension(), &bytes).map_err(|e| e.to_string())
    });
    let path = match saved {
        Ok(p) => p,
        Err(e) => return crate::show_error(app, "The capture was not saved", &e),
    };
    log::info!("saved {} ({width}×{height} px, scale {scale})", path.display());
    crate::emit_library_changed(app);

    if s.copy_after_capture {
        if let Some(Ok(png)) = &png {
            if let Err(e) = platform::set_clipboard_image(png, &rgba, width, height) {
                log::warn!("capture not copied: {e}");
            }
        }
    }
    if s.capture_sound {
        platform::play_sound(CAPTURE_WAV);
    }
    if s.show_shelf {
        shelf::add(app, path.clone(), width, height, monitor);
    }
    if s.edit_after_capture {
        crate::open_library(app, Some(&path.to_string_lossy()));
    }
}
