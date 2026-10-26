//! The `invoke` surface, exactly as listed in `windows/docs/ipc.md`. Errors are plain messages.
//! Anything that touches the disk runs off the main thread (async commands).

use std::{
    fs,
    path::{Path, PathBuf},
};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{ipc::InvokeBody, AppHandle, Emitter, Manager, WebviewWindow};
use tauri_plugin_dialog::DialogExt;

use crate::{
    capture, imagefile, library, naming, pins, platform,
    settings::{CaptureKind, Settings, Shortcuts},
    shelf, shortcuts, state, LIBRARY, SETTINGS,
};

type Res<T> = Result<T, String>;

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Res<T> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())
}

// ---------- settings ----------

fn current_settings(app: &AppHandle) -> Settings {
    let mut s = state(app).settings.read().clone();
    s.open_at_login = crate::open_at_login(app);
    s
}

fn apply_settings(app: &AppHandle, patch: &Value) -> Res<Settings> {
    let st = state(app);
    let old = current_settings(app);
    let mut next = Settings::merged(&old, patch);
    if next.open_at_login != old.open_at_login {
        crate::set_open_at_login(app, next.open_at_login);
        next.open_at_login = crate::open_at_login(app);
    }
    next.save(&st.settings_file).map_err(|e| format!("Settings could not be saved: {e}"))?;
    *st.settings.write() = next.clone();

    if next.shortcuts != old.shortcuts {
        shortcuts::register(app);
        crate::update_tray(app);
    }
    if next.save_folder != old.save_folder {
        library::watch_save_folder(app);
        crate::emit_library_changed(app);
    }
    if next.appearance != old.appearance {
        crate::apply_appearance(app);
    }
    if !next.show_shelf && old.show_shelf {
        shelf::clear(app);
    }
    let _ = app.emit("settings-changed", &next);
    Ok(next)
}

#[tauri::command]
pub fn get_settings(app: AppHandle) -> Settings {
    current_settings(&app)
}

#[tauri::command]
pub async fn set_settings(app: AppHandle, patch: Value) -> Res<Settings> {
    apply_settings(&app, &patch)
}

#[tauri::command]
pub async fn reset_shortcuts(app: AppHandle) -> Res<Settings> {
    apply_settings(&app, &json!({ "shortcuts": Shortcuts::defaults() }))
}

#[tauri::command]
pub async fn shortcut_status(app: AppHandle) -> shortcuts::ShortcutStatus {
    shortcuts::status(&app)
}

#[tauri::command]
pub async fn set_print_screen_opens_snipping_tool(app: AppHandle, enabled: bool) -> Res<shortcuts::ShortcutStatus> {
    platform::set_print_screen_opens_snipping_tool(enabled)?;
    // The shell lets go of (or takes) Print Screen shortly after the setting changes.
    std::thread::sleep(std::time::Duration::from_millis(300));
    shortcuts::register(&app);
    Ok(shortcuts::status(&app))
}

#[tauri::command]
pub async fn pause_shortcuts(app: AppHandle) {
    shortcuts::pause(&app);
}

#[tauri::command]
pub async fn resume_shortcuts(app: AppHandle) {
    shortcuts::resume(&app);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemInfo {
    accent_color: String,
    version: String,
}

#[tauri::command]
pub fn system_info(app: AppHandle) -> SystemInfo {
    SystemInfo { accent_color: platform::accent_color(), version: app.package_info().version.to_string() }
}

// ---------- capture and library ----------

#[tauri::command]
pub fn capture(app: AppHandle, kind: CaptureKind) {
    capture::capture(&app, kind);
}

#[tauri::command]
pub async fn list_captures(app: AppHandle) -> Res<Vec<library::CaptureFile>> {
    let dir = state(&app).settings.read().save_folder();
    let handle = app.clone();
    blocking(move || library::scan(&dir, &state(&handle).edits)).await
}

#[tauri::command]
pub async fn read_edits(app: AppHandle, path: String) -> Option<Value> {
    state(&app).edits.read(Path::new(&path))
}

#[tauri::command]
pub async fn write_edits(app: AppHandle, path: String, edits: Option<Value>) -> Res<()> {
    state(&app).edits.write(Path::new(&path), edits.as_ref()).map_err(|e| format!("Edits could not be saved: {e}"))?;
    crate::emit_edits_changed(&app, &path);
    Ok(())
}

#[tauri::command]
pub async fn write_flattened(app: AppHandle, request: tauri::ipc::Request<'_>) -> Res<()> {
    let InvokeBody::Raw(png) = request.body() else { return Err("Expected PNG bytes.".into()) };
    let path = request
        .headers()
        .get("x-path")
        .and_then(|v| v.to_str().ok())
        .map(naming::decode_uri_component)
        .ok_or("The x-path header is missing.")?;
    if imagefile::png_size(png).is_none() {
        return Err("The rendering is not a PNG.".into());
    }
    state(&app).edits.write_flattened(Path::new(&path), png).map_err(|e| format!("The preview could not be saved: {e}"))?;
    crate::emit_edits_changed(&app, &path);
    Ok(())
}

/// PNG bytes for the clipboard plus the decoded pixels for CF_DIB.
fn clipboard_from_bytes(bytes: Vec<u8>, scale: f64) -> Res<()> {
    let img = imagefile::decode_rgba(&bytes)?;
    let png = if imagefile::png_size(&bytes).is_some() {
        bytes
    } else {
        imagefile::encode_png(img.as_raw(), img.width(), img.height(), scale)?
    };
    platform::set_clipboard_image(&png, img.as_raw(), img.width(), img.height())
}

#[tauri::command]
pub async fn copy_capture(app: AppHandle, path: String) -> Res<()> {
    let image = PathBuf::from(&path);
    let st = state(&app);
    let source = st.edits.flattened_or_original(&image);
    let scale = imagefile::info(&source).map(|i| i.2).unwrap_or(1.0);
    let bytes = fs::read(&source).map_err(|e| format!("The capture could not be read: {e}"))?;
    blocking(move || clipboard_from_bytes(bytes, scale)).await??;
    if shelf::contains(&app, &image) {
        let _ = app.emit_to(shelf::LABEL, "shelf-copied", json!({ "path": path }));
    }
    Ok(())
}

#[tauri::command]
pub async fn copy_png(request: tauri::ipc::Request<'_>) -> Res<()> {
    let InvokeBody::Raw(png) = request.body() else { return Err("Expected PNG bytes.".into()) };
    let bytes = png.clone();
    blocking(move || clipboard_from_bytes(bytes, 1.0)).await?
}

/// The file other apps get: the original, or for an edited capture a copy of the rendering
/// named after the capture (the cache itself has a hash for a name).
fn export_source(app: &AppHandle, image: &Path) -> Res<PathBuf> {
    let st = state(app);
    let source = st.edits.flattened_or_original(image);
    if source == image {
        return Ok(source);
    }
    let dir = st.temp_dir.join("Drag");
    let out = dir.join(format!("{}.png", naming::stem(image)));
    fs::create_dir_all(&dir).and_then(|_| fs::copy(&source, &out)).map_err(|e| e.to_string())?;
    Ok(out)
}

#[tauri::command]
pub async fn export_capture(app: AppHandle, window: WebviewWindow, path: String) -> Res<Option<String>> {
    let image = PathBuf::from(&path);
    let source = state(&app).edits.flattened_or_original(&image);
    let start = state(&app).last_export_dir.lock().clone().or_else(|| app.path().desktop_dir().ok());
    let name = format!("{}.png", naming::stem(&image));
    let dialog_app = app.clone();
    let picked = blocking(move || {
        let mut dialog = dialog_app.dialog().file().set_parent(&window).set_file_name(name).add_filter("PNG image", &["png"]);
        if let Some(dir) = start {
            dialog = dialog.set_directory(dir);
        }
        dialog.blocking_save_file()
    })
    .await?;
    let Some(target) = picked.and_then(|p| p.into_path().ok()) else { return Ok(None) };
    let bytes = fs::read(&source).map_err(|e| format!("The capture could not be read: {e}"))?;
    let png = if imagefile::png_size(&bytes).is_some() {
        bytes
    } else {
        let scale = imagefile::info(&source).map(|i| i.2).unwrap_or(1.0);
        let img = imagefile::decode_rgba(&bytes)?;
        imagefile::encode_png(img.as_raw(), img.width(), img.height(), scale)?
    };
    fs::write(&target, png).map_err(|e| format!("The file could not be written: {e}"))?;
    *state(&app).last_export_dir.lock() = target.parent().map(Path::to_path_buf);
    Ok(Some(target.to_string_lossy().into_owned()))
}

#[tauri::command]
pub fn show_in_explorer(path: String) -> Res<()> {
    platform::show_in_explorer(Path::new(&path))
}

#[tauri::command]
pub fn open_save_folder(app: AppHandle) -> Res<()> {
    let dir = state(&app).settings.read().save_folder();
    let _ = fs::create_dir_all(&dir);
    platform::open_folder(&dir)
}

#[tauri::command]
pub async fn choose_save_folder(app: AppHandle, window: WebviewWindow) -> Res<Option<String>> {
    let current = state(&app).settings.read().save_folder();
    let dialog_app = app.clone();
    let picked = blocking(move || {
        dialog_app.dialog().file().set_parent(&window).set_directory(current).blocking_pick_folder()
    })
    .await?;
    Ok(picked.and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned()))
}

#[tauri::command]
pub async fn delete_capture(app: AppHandle, path: String) -> Res<()> {
    let image = PathBuf::from(&path);
    shelf::remove(&app, &image);
    let handle = app.clone();
    let target = image.clone();
    let result = blocking(move || library::trash(&target, &state(&handle).edits)).await?;
    crate::emit_library_changed(&app);
    result.map_err(|e| format!("The capture could not be moved to the Recycle Bin: {e}"))
}

#[tauri::command]
pub async fn import_files(app: AppHandle, paths: Vec<String>) -> Res<Vec<String>> {
    let dir = state(&app).settings.read().save_folder();
    let sources: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    let imported = blocking(move || library::import(&dir, &sources)).await?;
    crate::emit_library_changed(&app);
    Ok(imported.into_iter().map(|p| p.to_string_lossy().into_owned()).collect())
}

// ---------- windows ----------

#[tauri::command]
pub fn open_library(app: AppHandle, path: Option<String>) {
    crate::open_library(&app, path.as_deref());
}

#[tauri::command]
pub fn open_settings(app: AppHandle, tab: Option<String>) {
    crate::open_settings(&app, tab.as_deref());
}

#[tauri::command]
pub async fn pin_capture(app: AppHandle, path: String) -> Res<()> {
    let image = PathBuf::from(&path);
    let st = state(&app);
    let source = st.edits.flattened_or_original(&image);
    let scale = st
        .edits
        .read(&image)
        .as_ref()
        .and_then(crate::edits::scale)
        .or_else(|| imagefile::info(&source).map(|i| i.2))
        .unwrap_or(1.0);
    pins::open(&app, &source, scale)
}

#[tauri::command]
pub async fn pin_clipboard(app: AppHandle) {
    pins::pin_clipboard(&app);
}

#[tauri::command]
pub async fn shelf_items(app: AppHandle) -> Vec<shelf::ShelfItem> {
    shelf::items(&app)
}

#[tauri::command]
pub fn shelf_remove(app: AppHandle, path: String) {
    shelf::remove(&app, Path::new(&path));
}

#[tauri::command]
pub fn shelf_set_hover(app: AppHandle, hovering: bool) {
    shelf::set_hover(&app, hovering);
}

#[derive(Serialize)]
pub struct DragResult {
    dropped: bool,
}

#[tauri::command]
pub async fn start_drag(app: AppHandle, window: WebviewWindow, path: String) -> Res<DragResult> {
    let image = PathBuf::from(&path);
    let file = export_source(&app, &image)?;
    let (tx, rx) = std::sync::mpsc::channel();
    let source_window = window.clone();
    // OLE drag and drop runs a modal loop on the UI thread.
    window
        .run_on_main_thread(move || {
            let _ = tx.send(platform::drag_file(&source_window, &file));
        })
        .map_err(|e| e.to_string())?;
    let dropped = blocking(move || rx.recv().map_err(|e| e.to_string())).await???;
    let close = state(&app).settings.read().close_shelf_item_after_drag;
    if dropped && close && window.label() == shelf::LABEL {
        shelf::remove(&app, &image);
    }
    Ok(DragResult { dropped })
}

#[tauri::command]
pub fn close_window(window: WebviewWindow) {
    match window.label() {
        LIBRARY | SETTINGS => {
            let _ = window.hide();
        }
        shelf::LABEL => platform::hide(&window),
        _ => {
            let _ = window.destroy();
        }
    }
}
