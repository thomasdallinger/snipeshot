//! The capture library: every image in the save folder, newest first, kept fresh by a folder
//! watcher. Also writing new captures, importing files and moving captures to the Recycle Bin.

use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::mpsc::{channel, RecvTimeoutError},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use notify::{RecursiveMode, Watcher as _};
use parking_lot::Mutex;
use serde::Serialize;
use tauri::AppHandle;

use crate::{edits, imagefile, naming, platform, state};

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureFile {
    pub path: String,
    pub name: String,
    pub created_at: i64,
    pub modified_at: i64,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub has_edits: bool,
    pub preview_path: String,
    pub flattened_stale: bool,
}

pub fn millis(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Builds the entry for one image, or None when it is not a visible capture.
pub fn capture_file(path: &Path, meta: &fs::Metadata, paths: &edits::Paths) -> Option<CaptureFile> {
    if !meta.is_file() || !naming::is_image(path) || naming::is_dot_file(path) || platform::is_hidden(meta) {
        return None;
    }
    let (width, height, file_scale) = imagefile::info(path).unwrap_or((0, 0, 1.0));
    let edit = paths.state(path);
    let scale = if edit.has_edits() { paths.read(path).as_ref().and_then(edits::scale) } else { None };
    let modified = meta.modified().ok();
    let modified_at = millis(modified.max(edit.edit_modified).unwrap_or(UNIX_EPOCH));
    Some(CaptureFile {
        path: path.to_string_lossy().into_owned(),
        name: naming::stem(path),
        created_at: millis(meta.created().ok().or(modified).unwrap_or(UNIX_EPOCH)),
        modified_at,
        width,
        height,
        scale: scale.unwrap_or(file_scale),
        has_edits: edit.has_edits(),
        preview_path: edit.cache.as_deref().unwrap_or(path).to_string_lossy().into_owned(),
        flattened_stale: edit.has_edits() && edit.cache.is_none(),
    })
}

/// Images in `dir`, newest first.
pub fn scan(dir: &Path, paths: &edits::Paths) -> Vec<CaptureFile> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<CaptureFile> = entries
        .flatten()
        .filter_map(|e| capture_file(&e.path(), &e.metadata().ok()?, paths))
        .collect();
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| b.name.cmp(&a.name)));
    out
}

/// Serializes picking a name and creating the file, so two quick captures never share a name.
static SAVE_LOCK: Mutex<()> = Mutex::new(());

/// Writes `bytes` as `dir/base.ext`, or `base (2).ext`… when the name is taken.
pub fn write_new(dir: &Path, base: &str, ext: &str, bytes: &[u8]) -> io::Result<PathBuf> {
    let _guard = SAVE_LOCK.lock();
    fs::create_dir_all(dir)?;
    let path = naming::unique_path(dir, base, ext, |p| p.exists());
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&path)?;
    file.write_all(bytes)?;
    Ok(path)
}

/// Copies image files into the save folder, keeping their names.
pub fn import(dir: &Path, sources: &[PathBuf]) -> Vec<PathBuf> {
    let _guard = SAVE_LOCK.lock();
    let _ = fs::create_dir_all(dir);
    let mut imported = Vec::new();
    for src in sources.iter().filter(|p| naming::is_image(p)) {
        let ext = src.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        let dest = naming::unique_path(dir, &naming::stem(src), &ext, |p| p.exists());
        match fs::copy(src, &dest) {
            Ok(_) => imported.push(dest),
            Err(e) => log::warn!("skipped {} while importing: {e}", src.display()),
        }
    }
    imported
}

/// Moves a capture to the Recycle Bin; its edit file and cache are removed.
pub fn trash(path: &Path, paths: &edits::Paths) -> Result<(), String> {
    let target = path.to_path_buf();
    // The trash crate sets up COM per thread; a thread of its own keeps that away from async workers.
    let result = thread::spawn(move || trash::delete(&target).map_err(|e| e.to_string()))
        .join()
        .unwrap_or_else(|_| Err("The Recycle Bin did not respond.".into()));
    paths.remove_all(path);
    result
}

/// Keeps the folder watcher alive; dropping it stops the debounce thread too.
pub struct Watcher(#[allow(dead_code)] notify::RecommendedWatcher);

/// Watches the save folder and emits `library-changed` 250 ms after the last change.
pub fn watch_save_folder(app: &AppHandle) {
    let st = state(app);
    let dir = st.settings.read().save_folder();
    let _ = fs::create_dir_all(&dir);
    let (tx, rx) = channel::<()>();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if res.is_ok() {
            let _ = tx.send(());
        }
    });
    let mut watcher = match watcher {
        Ok(w) => w,
        Err(e) => {
            log::warn!("folder watcher not started: {e}");
            *st.watcher.lock() = None;
            return;
        }
    };
    if let Err(e) = watcher.watch(&dir, RecursiveMode::NonRecursive) {
        log::warn!("{} not watched: {e}", dir.display());
    }
    *st.watcher.lock() = Some(Watcher(watcher));
    let app = app.clone();
    thread::spawn(move || {
        while rx.recv().is_ok() {
            loop {
                match rx.recv_timeout(Duration::from_millis(250)) {
                    Ok(()) => continue,
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            crate::emit_library_changed(&app);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("snipeshot-lib-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn write_new_never_overwrites() {
        let dir = temp("write");
        let a = write_new(&dir, "Capture 2026-10-21 14.03.22", "png", b"a").unwrap();
        let b = write_new(&dir, "Capture 2026-10-21 14.03.22", "png", b"b").unwrap();
        assert_eq!(a.file_name().unwrap(), "Capture 2026-10-21 14.03.22.png");
        assert_eq!(b.file_name().unwrap(), "Capture 2026-10-21 14.03.22 (2).png");
        assert_eq!(fs::read(&a).unwrap(), b"a");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_lists_images_newest_first_with_edit_state() {
        let dir = temp("scan");
        let paths = edits::Paths { flattened_dir: dir.join("cache") };
        let png = imagefile::encode_png(&[1, 2, 3, 255, 4, 5, 6, 255], 2, 1, 2.0).unwrap();
        let old = write_new(&dir, "Old", "png", &png).unwrap();
        thread::sleep(Duration::from_millis(30));
        let new = write_new(&dir, "New", "png", &png).unwrap();
        fs::write(dir.join("notes.txt"), b"x").unwrap();
        fs::write(dir.join(".hidden.png"), &png).unwrap();
        paths.write(&old, Some(&serde_json::json!({"scale": 3, "crop": [0, 0, 1, 1]}))).unwrap();

        let list = scan(&dir, &paths);
        assert_eq!(list.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["New", "Old"]);
        assert_eq!((list[0].width, list[0].height, list[0].scale), (2, 1, 2.0));
        assert!(!list[0].has_edits && !list[0].flattened_stale);
        assert_eq!(list[0].preview_path, new.to_string_lossy());
        assert!(list[1].has_edits && list[1].flattened_stale);
        assert_eq!(list[1].scale, 3.0);
        assert!(list[1].modified_at >= list[1].created_at);

        let cache = paths.write_flattened(&old, &png).unwrap();
        let list = scan(&dir, &paths);
        assert!(!list[1].flattened_stale);
        assert_eq!(list[1].preview_path, cache.to_string_lossy());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn import_copies_images_only() {
        let src = temp("import-src");
        let dir = temp("import-dst");
        fs::write(src.join("Shot.PNG"), b"png").unwrap();
        fs::write(src.join("readme.md"), b"md").unwrap();
        fs::write(dir.join("Shot.png"), b"existing").unwrap();
        let out = import(&dir, &[src.join("Shot.PNG"), src.join("readme.md")]);
        assert_eq!(out, vec![dir.join("Shot (2).png")]);
        assert_eq!(fs::read(&out[0]).unwrap(), b"png");
        let _ = fs::remove_dir_all(&src);
        let _ = fs::remove_dir_all(&dir);
    }
}
