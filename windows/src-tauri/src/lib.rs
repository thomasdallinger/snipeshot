//! Snipeshot for Windows: a tray app that captures the screen, keeps captures in a folder and hands
//! the library, settings, shelf and pins to the Svelte frontend. The IPC surface is documented in
//! `windows/docs/ipc.md`.

mod accel;
mod capture;
mod commands;
mod edits;
mod imagefile;
mod layout;
mod library;
mod naming;
mod pins;
mod platform;
// The rasterizer only draws the Windows selector.
#[cfg_attr(not(windows), allow(dead_code))]
mod raster;
mod settings;
mod shelf;
mod shortcuts;

use std::{
    path::{Path, PathBuf},
    sync::atomic::AtomicU32,
    thread,
    time::Duration,
};

use parking_lot::{Mutex, RwLock};
use serde_json::json;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    webview::PageLoadEvent,
    AppHandle, Emitter, Manager, RunEvent, Theme, WindowEvent,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};

use settings::{Appearance, CaptureKind, Settings};

pub const LIBRARY: &str = "library";
pub const SETTINGS: &str = "settings";

/// Everything the commands share.
pub struct AppState {
    pub settings: RwLock<Settings>,
    pub settings_file: PathBuf,
    pub edits: edits::Paths,
    /// Throwaway files: drag copies of edited captures and clipboard pins.
    pub temp_dir: PathBuf,
    pub shelf: Mutex<shelf::Shelf>,
    pub shortcuts: shortcuts::Shortcuts,
    pub watcher: Mutex<Option<library::Watcher>>,
    /// Tab to show once the settings page has loaded (first launch).
    pub pending_settings_tab: Mutex<Option<String>>,
    pub last_export_dir: Mutex<Option<PathBuf>>,
    pub pin_counter: AtomicU32,
    pub tray_items: Mutex<Vec<(CaptureKind, MenuItem<tauri::Wry>)>>,
}

pub fn state(app: &AppHandle) -> tauri::State<'_, AppState> {
    app.state::<AppState>()
}

// ---------- events ----------

pub fn emit_library_changed(app: &AppHandle) {
    let _ = app.emit("library-changed", ());
}

pub fn emit_edits_changed(app: &AppHandle, path: &str) {
    let _ = app.emit("edits-changed", json!({ "path": path }));
    if shelf::contains(app, Path::new(path)) {
        shelf::changed(app);
    }
}

// ---------- windows ----------

fn show_and_focus(app: &AppHandle, label: &str) {
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

pub fn open_library(app: &AppHandle, path: Option<&str>) {
    show_and_focus(app, LIBRARY);
    if let Some(path) = path {
        let _ = app.emit_to(LIBRARY, "open-capture", json!({ "path": path }));
    }
}

pub fn open_settings(app: &AppHandle, tab: Option<&str>) {
    show_and_focus(app, SETTINGS);
    if let Some(tab) = tab {
        let _ = app.emit_to(SETTINGS, "open-settings-tab", json!({ "tab": tab }));
    }
}

/// Title bars of the library and settings follow the appearance setting.
pub fn apply_appearance(app: &AppHandle) {
    let theme = match state(app).settings.read().appearance {
        Appearance::System => None,
        Appearance::Light => Some(Theme::Light),
        Appearance::Dark => Some(Theme::Dark),
    };
    for label in [LIBRARY, SETTINGS] {
        if let Some(w) = app.get_webview_window(label) {
            let _ = w.set_theme(theme);
        }
    }
}

pub fn show_error(app: &AppHandle, title: &str, message: &str) {
    log::error!("{title}: {message}");
    app.dialog().message(message).title(title).kind(MessageDialogKind::Error).show(|_| {});
}

// ---------- autostart ----------

pub fn open_at_login(app: &AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

pub fn set_open_at_login(app: &AppHandle, enabled: bool) {
    let al = app.autolaunch();
    let result = if enabled { al.enable() } else { al.disable() };
    if let Err(e) = result {
        log::warn!("open at login not changed: {e}");
    }
}

// ---------- tray ----------

fn capture_item_text(kind: CaptureKind, settings: &Settings) -> String {
    // A tab puts the shortcut in the menu's accelerator column without registering it.
    match settings.shortcuts.get(kind) {
        Some(acc) => format!("{}\t{}", kind.menu_title(), accel::display(acc)),
        None => kind.menu_title().to_string(),
    }
}

pub fn update_tray(app: &AppHandle) {
    let st = state(app);
    let settings = st.settings.read().clone();
    for (kind, item) in st.tray_items.lock().iter() {
        let _ = item.set_text(capture_item_text(*kind, &settings));
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let settings = state(app).settings.read().clone();
    let mut capture_items = Vec::new();
    for kind in CaptureKind::ALL {
        let item = MenuItem::with_id(app, format!("capture-{}", kind.key()), capture_item_text(kind, &settings), true, None::<&str>)?;
        capture_items.push((kind, item));
    }
    let later = MenuItem::with_id(app, "capture-later", "Capture Screen in 5 Seconds", true, None::<&str>)?;
    let library = MenuItem::with_id(app, "library", "Open Library", true, None::<&str>)?;
    let pin = MenuItem::with_id(app, "pin-clipboard", "Pin Clipboard Image", true, None::<&str>)?;
    let settings_item = MenuItem::with_id(app, "settings", "Settings\u{2026}", true, None::<&str>)?;
    let about = MenuItem::with_id(app, "about", "About Snipeshot", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Snipeshot", true, None::<&str>)?;
    let separator = || PredefinedMenuItem::separator(app);
    let menu = Menu::with_items(
        app,
        &[
            &capture_items[0].1,
            &capture_items[1].1,
            &capture_items[2].1,
            &later,
            &separator()?,
            &library,
            &pin,
            &separator()?,
            &settings_item,
            &about,
            &quit,
        ],
    )?;
    *state(app).tray_items.lock() = capture_items;
    TrayIconBuilder::with_id("snipeshot")
        .icon(tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?)
        .tooltip("Snipeshot")
        .menu(&menu)
        .on_menu_event(|app, e| {
            let app = app.clone();
            match e.id().as_ref() {
                id if id.starts_with("capture-") && id != "capture-later" => {
                    let Some(kind) = CaptureKind::ALL.into_iter().find(|k| id == format!("capture-{}", k.key())) else {
                        return;
                    };
                    // Give the menu time to fade before the screen freezes.
                    thread::spawn(move || {
                        thread::sleep(Duration::from_millis(150));
                        capture::capture(&app, kind);
                    });
                }
                "capture-later" => {
                    thread::spawn(move || {
                        thread::sleep(Duration::from_secs(5));
                        capture::capture(&app, CaptureKind::Screen);
                    });
                }
                "library" => open_library(&app, None),
                "pin-clipboard" => pins::pin_clipboard(&app),
                "settings" => open_settings(&app, None),
                "about" => {
                    let version = app.package_info().version.to_string();
                    app.dialog()
                        .message(format!("Version {version}\n\nCapture, mark up and drag screenshots anywhere."))
                        .title("About Snipeshot")
                        .show(|_| {});
                }
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .build(app)?;
    Ok(())
}

// ---------- logging ----------

fn init_logging(dir: &Path) {
    struct FileLog(Mutex<std::fs::File>);
    impl log::Log for FileLog {
        fn enabled(&self, m: &log::Metadata) -> bool {
            m.level() <= log::Level::Info && m.target().starts_with("snipeshot")
        }
        fn log(&self, r: &log::Record) {
            if self.enabled(r.metadata()) {
                use std::io::Write;
                let line = format!("{} {:<5} {}\n", chrono::Local::now().format("%F %T%.3f"), r.level(), r.args());
                eprint!("{line}");
                let _ = self.0.lock().write_all(line.as_bytes());
            }
        }
        fn flush(&self) {}
    }
    let _ = std::fs::create_dir_all(dir);
    let file = dir.join("snipeshot.log");
    // Start over once the log passes 1 MB.
    if std::fs::metadata(&file).is_ok_and(|m| m.len() > 1_000_000) {
        let _ = std::fs::remove_file(&file);
    }
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(file) {
        let _ = log::set_boxed_logger(Box::new(FileLog(Mutex::new(f))));
        log::set_max_level(log::LevelFilter::Info);
    }
}

// ---------- startup ----------

fn setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let handle = app.handle().clone();
    let paths = app.path();
    init_logging(&paths.app_log_dir()?);
    log::info!("Snipeshot {} starting", app.package_info().version);

    let default_folder = paths.picture_dir().or_else(|_| paths.home_dir())?.join("Snipeshot");
    let settings_file = paths.app_config_dir()?.join("settings.json");
    let mut settings = Settings::load(&settings_file, &default_folder);
    settings.open_at_login = open_at_login(&handle);
    let temp_dir = paths.app_cache_dir()?.join("Temp");
    let _ = std::fs::remove_dir_all(&temp_dir);
    let flattened_dir = paths.app_local_data_dir()?.join("Flattened");

    let first_launch = !settings.did_show_welcome;
    if first_launch {
        settings.did_show_welcome = true;
        if let Err(e) = settings.save(&settings_file) {
            log::warn!("settings not saved: {e}");
        }
    }
    let _ = std::fs::create_dir_all(settings.save_folder());

    let hotkey_app = handle.clone();
    app.manage(AppState {
        settings: RwLock::new(settings),
        settings_file,
        edits: edits::Paths { flattened_dir },
        temp_dir,
        shelf: Mutex::new(shelf::Shelf::default()),
        shortcuts: shortcuts::Shortcuts::start(move |kind| capture::capture(&hotkey_app, kind)),
        watcher: Mutex::new(None),
        pending_settings_tab: Mutex::new(None),
        last_export_dir: Mutex::new(None),
        pin_counter: AtomicU32::new(1),
        tray_items: Mutex::new(Vec::new()),
    });

    shortcuts::register(&handle);
    library::watch_save_folder(&handle);
    shelf::create_window(&handle)?;
    shelf::spawn_follow(handle.clone());
    build_tray(&handle)?;
    apply_appearance(&handle);

    if first_launch {
        *state(&handle).pending_settings_tab.lock() = Some("shortcuts".into());
        open_settings(&handle, None);
        // In case the page finished loading before we started listening for it.
        let app = handle.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(4));
            flush_pending_settings_tab(&app);
        });
    }
    Ok(())
}

fn flush_pending_settings_tab(app: &AppHandle) {
    if let Some(tab) = state(app).pending_settings_tab.lock().take() {
        let _ = app.emit_to(SETTINGS, "open-settings-tab", json!({ "tab": tab }));
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| open_library(app, None)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec!["--autostart"])))
        .plugin(tauri_plugin_dialog::init())
        .setup(setup)
        .on_page_load(|webview, payload| {
            if webview.label() == SETTINGS && payload.event() == PageLoadEvent::Finished {
                // Listeners register right after the page loads.
                let app = webview.app_handle().clone();
                thread::spawn(move || {
                    thread::sleep(Duration::from_millis(500));
                    flush_pending_settings_tab(&app);
                });
            }
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if matches!(window.label(), LIBRARY | SETTINGS | shelf::LABEL) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::set_settings,
            commands::reset_shortcuts,
            commands::shortcut_status,
            commands::set_print_screen_opens_snipping_tool,
            commands::pause_shortcuts,
            commands::resume_shortcuts,
            commands::system_info,
            commands::capture,
            commands::list_captures,
            commands::read_edits,
            commands::write_edits,
            commands::write_flattened,
            commands::copy_capture,
            commands::copy_png,
            commands::export_capture,
            commands::show_in_explorer,
            commands::open_save_folder,
            commands::choose_save_folder,
            commands::delete_capture,
            commands::import_files,
            commands::open_library,
            commands::open_settings,
            commands::pin_capture,
            commands::pin_clipboard,
            commands::shelf_items,
            commands::shelf_remove,
            commands::shelf_set_hover,
            commands::start_drag,
            commands::close_window,
        ])
        .build(tauri::generate_context!())
        .expect("error while building Snipeshot");

    app.run(|app, event| match event {
        // A tray app keeps running with no window open; only Quit ends it.
        RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
        RunEvent::Exit => {
            if let Some(st) = app.try_state::<AppState>() {
                st.shortcuts.unregister_all();
                let _ = std::fs::remove_dir_all(&st.temp_dir);
            }
        }
        _ => {}
    });
}
