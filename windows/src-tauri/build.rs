fn main() {
    // The default manifest only adds Common Controls v6 (needed by the dialogs); ours also declares
    // per-monitor-v2 DPI awareness so it holds before the event loop starts.
    let windows = tauri_build::WindowsAttributes::new().app_manifest(include_str!("app.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows)).expect("failed to run tauri-build");
}
