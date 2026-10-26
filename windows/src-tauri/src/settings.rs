//! Settings: the JSON file in the app config folder, defaults, tolerant parsing and partial updates.
//! A single bad or unknown value never resets the rest of the file.

use std::{
    fs, io,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureKind {
    Area,
    Window,
    Screen,
}

impl CaptureKind {
    pub const ALL: [CaptureKind; 3] = [CaptureKind::Area, CaptureKind::Window, CaptureKind::Screen];

    pub fn key(self) -> &'static str {
        match self {
            CaptureKind::Area => "area",
            CaptureKind::Window => "window",
            CaptureKind::Screen => "screen",
        }
    }

    pub fn menu_title(self) -> &'static str {
        match self {
            CaptureKind::Area => "Capture Area",
            CaptureKind::Window => "Capture Window",
            CaptureKind::Screen => "Capture Screen",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileFormat {
    Png,
    Jpeg,
}

impl FileFormat {
    pub fn extension(self) -> &'static str {
        match self {
            FileFormat::Png => "png",
            FileFormat::Jpeg => "jpg",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    System,
    Light,
    Dark,
}

/// Accelerator per capture kind. `None` means cleared on purpose, so the default does not come back.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Shortcuts {
    pub area: Option<String>,
    pub window: Option<String>,
    pub screen: Option<String>,
}

impl Shortcuts {
    pub fn defaults() -> Shortcuts {
        Shortcuts {
            area: Some("PrintScreen".into()),
            window: Some("Alt+PrintScreen".into()),
            screen: Some("Ctrl+PrintScreen".into()),
        }
    }

    pub fn get(&self, kind: CaptureKind) -> Option<&str> {
        match kind {
            CaptureKind::Area => self.area.as_deref(),
            CaptureKind::Window => self.window.as_deref(),
            CaptureKind::Screen => self.screen.as_deref(),
        }
    }

    fn slot(&mut self, kind: CaptureKind) -> &mut Option<String> {
        match kind {
            CaptureKind::Area => &mut self.area,
            CaptureKind::Window => &mut self.window,
            CaptureKind::Screen => &mut self.screen,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub save_folder: String,
    pub file_format: FileFormat,
    pub jpeg_quality: f64,
    pub show_shelf: bool,
    pub copy_after_capture: bool,
    pub edit_after_capture: bool,
    pub capture_sound: bool,
    pub close_shelf_item_after_drag: bool,
    pub appearance: Appearance,
    /// Backed by the autostart plugin; never read from the file.
    pub open_at_login: bool,
    pub shortcuts: Shortcuts,
    pub did_show_welcome: bool,
}

impl Settings {
    pub fn defaults(save_folder: &Path) -> Settings {
        Settings {
            save_folder: save_folder.to_string_lossy().into_owned(),
            file_format: FileFormat::Png,
            jpeg_quality: 0.9,
            show_shelf: true,
            copy_after_capture: true,
            edit_after_capture: false,
            capture_sound: true,
            close_shelf_item_after_drag: true,
            appearance: Appearance::System,
            open_at_login: false,
            shortcuts: Shortcuts::defaults(),
            did_show_welcome: false,
        }
    }

    /// `base` with every well-formed known field of `value` applied. Used for the file and for patches.
    pub fn merged(base: &Settings, value: &Value) -> Settings {
        let mut s = base.clone();
        let Some(obj) = value.as_object() else { return s };
        if let Some(v) = string(obj, "saveFolder") {
            s.save_folder = v;
        }
        if let Some(v) = enum_value(obj, "fileFormat") {
            s.file_format = v;
        }
        if let Some(v) = obj.get("jpegQuality").and_then(Value::as_f64) {
            s.jpeg_quality = v.clamp(0.0, 1.0);
        }
        let flags: [(&str, &mut bool); 7] = [
            ("showShelf", &mut s.show_shelf),
            ("copyAfterCapture", &mut s.copy_after_capture),
            ("editAfterCapture", &mut s.edit_after_capture),
            ("captureSound", &mut s.capture_sound),
            ("closeShelfItemAfterDrag", &mut s.close_shelf_item_after_drag),
            ("openAtLogin", &mut s.open_at_login),
            ("didShowWelcome", &mut s.did_show_welcome),
        ];
        for (key, slot) in flags {
            if let Some(v) = obj.get(key).and_then(Value::as_bool) {
                *slot = v;
            }
        }
        if let Some(v) = enum_value(obj, "appearance") {
            s.appearance = v;
        }
        if let Some(shortcuts) = obj.get("shortcuts").and_then(Value::as_object) {
            for kind in CaptureKind::ALL {
                match shortcuts.get(kind.key()) {
                    Some(Value::Null) => *s.shortcuts.slot(kind) = None,
                    Some(Value::String(acc)) => {
                        let acc = acc.trim();
                        *s.shortcuts.slot(kind) = (!acc.is_empty()).then(|| acc.to_string());
                    }
                    _ => {}
                }
            }
        }
        s
    }

    /// Reads the settings file; anything missing or malformed falls back to the defaults.
    pub fn parse(text: &str, default_folder: &Path) -> Settings {
        let defaults = Settings::defaults(default_folder);
        match serde_json::from_str::<Value>(text) {
            Ok(value) => Settings::merged(&defaults, &value),
            Err(_) => defaults,
        }
    }

    pub fn load(file: &Path, default_folder: &Path) -> Settings {
        match fs::read_to_string(file) {
            Ok(text) => Settings::parse(&text, default_folder),
            Err(_) => Settings::defaults(default_folder),
        }
    }

    /// The file form: everything except `openAtLogin`, which belongs to the autostart plugin.
    pub fn to_file_json(&self) -> String {
        let mut value = serde_json::to_value(self).unwrap_or(Value::Null);
        if let Some(obj) = value.as_object_mut() {
            obj.remove("openAtLogin");
        }
        serde_json::to_string_pretty(&value).unwrap_or_default()
    }

    /// Writes through a temporary file so a crash never leaves half a settings file behind.
    pub fn save(&self, file: &Path) -> io::Result<()> {
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = file.with_extension("json.tmp");
        fs::write(&tmp, self.to_file_json())?;
        fs::rename(&tmp, file)
    }

    pub fn save_folder(&self) -> PathBuf {
        PathBuf::from(&self.save_folder)
    }
}

fn string(obj: &Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

fn enum_value<T: for<'de> Deserialize<'de>>(obj: &Map<String, Value>, key: &str) -> Option<T> {
    obj.get(key).and_then(|v| serde_json::from_value(v.clone()).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn folder() -> PathBuf {
        PathBuf::from(r"C:\Users\me\Pictures\Snipeshot")
    }

    #[test]
    fn defaults_match_the_contract() {
        let s = Settings::defaults(&folder());
        assert_eq!(s.file_format, FileFormat::Png);
        assert_eq!(s.jpeg_quality, 0.9);
        assert!(s.show_shelf && s.copy_after_capture && s.capture_sound && s.close_shelf_item_after_drag);
        assert!(!s.edit_after_capture && !s.did_show_welcome);
        assert_eq!(s.appearance, Appearance::System);
        assert_eq!(s.shortcuts.get(CaptureKind::Area), Some("PrintScreen"));
        assert_eq!(s.shortcuts.get(CaptureKind::Window), Some("Alt+PrintScreen"));
        assert_eq!(s.shortcuts.get(CaptureKind::Screen), Some("Ctrl+PrintScreen"));
    }

    #[test]
    fn serializes_camel_case_with_null_for_cleared_shortcuts() {
        let mut s = Settings::defaults(&folder());
        s.shortcuts.window = None;
        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["saveFolder"], json!(r"C:\Users\me\Pictures\Snipeshot"));
        assert_eq!(v["fileFormat"], json!("png"));
        assert_eq!(v["closeShelfItemAfterDrag"], json!(true));
        assert_eq!(v["shortcuts"]["window"], Value::Null);
        assert_eq!(v["shortcuts"]["area"], json!("PrintScreen"));
        assert_eq!(v["didShowWelcome"], json!(false));
    }

    #[test]
    fn garbage_and_partial_files_keep_defaults() {
        let d = Settings::defaults(&folder());
        assert_eq!(Settings::parse("not json", &folder()), d);
        assert_eq!(Settings::parse("[1,2]", &folder()), d);
        let s = Settings::parse(r#"{"fileFormat":"gif","jpegQuality":"high","showShelf":false,"extra":1}"#, &folder());
        assert_eq!(s.file_format, FileFormat::Png);
        assert_eq!(s.jpeg_quality, 0.9);
        assert!(!s.show_shelf);
    }

    #[test]
    fn shortcuts_distinguish_missing_from_cleared() {
        let s = Settings::parse(r#"{"shortcuts":{"area":null,"screen":"F9","window":42}}"#, &folder());
        assert_eq!(s.shortcuts.area, None);
        assert_eq!(s.shortcuts.screen.as_deref(), Some("F9"));
        assert_eq!(s.shortcuts.window.as_deref(), Some("Alt+PrintScreen"));
        let s = Settings::parse(r#"{"shortcuts":{"area":"  "}}"#, &folder());
        assert_eq!(s.shortcuts.area, None);
    }

    #[test]
    fn values_are_clamped_and_empty_folder_ignored() {
        let s = Settings::parse(r#"{"jpegQuality":3,"saveFolder":""}"#, &folder());
        assert_eq!(s.jpeg_quality, 1.0);
        assert_eq!(s.save_folder(), folder());
    }

    #[test]
    fn patches_apply_on_top_of_current_values() {
        let mut current = Settings::defaults(&folder());
        current.capture_sound = false;
        let next = Settings::merged(&current, &json!({"fileFormat":"jpeg","appearance":"dark","shortcuts":{"screen":null}}));
        assert_eq!(next.file_format, FileFormat::Jpeg);
        assert_eq!(next.appearance, Appearance::Dark);
        assert!(!next.capture_sound);
        assert_eq!(next.shortcuts.screen, None);
        assert_eq!(next.shortcuts.area.as_deref(), Some("PrintScreen"));
    }

    #[test]
    fn file_round_trips_without_open_at_login() {
        let mut s = Settings::defaults(&folder());
        s.open_at_login = true;
        s.shortcuts.area = Some("Ctrl+Shift+4".into());
        let text = s.to_file_json();
        assert!(!text.contains("openAtLogin"));
        let back = Settings::parse(&text, Path::new("elsewhere"));
        assert!(!back.open_at_login);
        assert_eq!(back.shortcuts, s.shortcuts);
        assert_eq!(back.save_folder, s.save_folder);
    }

    #[test]
    fn save_and_load_through_a_file() {
        let dir = std::env::temp_dir().join(format!("snipeshot-settings-{}", std::process::id()));
        let file = dir.join("settings.json");
        let mut s = Settings::defaults(&folder());
        s.did_show_welcome = true;
        s.save(&file).unwrap();
        assert!(Settings::load(&file, &folder()).did_show_welcome);
        let _ = fs::remove_dir_all(&dir);
        assert!(!Settings::load(&file, &folder()).did_show_welcome);
    }
}
