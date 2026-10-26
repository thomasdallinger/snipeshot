//! Edit files (hidden JSON next to each image, macOS format) and the flattened cache the frontend
//! uploads. Rust never renders edits: copy, drag, export, previews and pins use the cache.

use std::{
    fs, io,
    path::{Path, PathBuf},
    time::SystemTime,
};

use serde_json::{Map, Value};

use crate::{imagefile, naming, platform};

/// Same rule as the macOS `EditFile.hasEdits`: annotations, a crop or a backdrop.
pub fn has_edits(edits: &Value) -> bool {
    let annotations = edits.get("annotations").and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    let crop = edits.get("crop").and_then(Value::as_array).is_some_and(|c| c.len() == 4);
    let backdrop = edits.get("backdrop").and_then(|b| b.get("enabled")).and_then(Value::as_bool) == Some(true);
    annotations || crop || backdrop
}

/// Pixels per point stored in the edit file.
pub fn scale(edits: &Value) -> Option<f64> {
    edits.get("scale").and_then(Value::as_f64).filter(|s| s.is_finite() && *s > 0.0)
}

/// Keys sorted at every level, like the macOS encoder's `.sortedKeys`.
pub fn canonical(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), canonical(&map[k]));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        other => other.clone(),
    }
}

/// Where the image lives and where its derived files go.
pub struct Paths {
    pub flattened_dir: PathBuf,
}

impl Paths {
    pub fn cache_for(&self, image: &Path) -> PathBuf {
        naming::flattened_cache_path(&self.flattened_dir, image)
    }

    pub fn read(&self, image: &Path) -> Option<Value> {
        let text = fs::read_to_string(naming::edit_file_path(image)).ok()?;
        serde_json::from_str(&text).ok().filter(Value::is_object)
    }

    /// Writes or, for `None` / no edits, removes the edit file and the cache.
    pub fn write(&self, image: &Path, edits: Option<&Value>) -> io::Result<()> {
        let file = naming::edit_file_path(image);
        match edits.filter(|e| has_edits(e)) {
            Some(e) => {
                let text = serde_json::to_string(&canonical(e)).map_err(io::Error::other)?;
                platform::write_hidden(&file, text.as_bytes())
            }
            None => {
                remove_if_present(&file)?;
                remove_if_present(&self.cache_for(image))
            }
        }
    }

    /// Stores the frontend's rendering with the capture's DPI so copies and drags open at the right size.
    pub fn write_flattened(&self, image: &Path, png: &[u8]) -> io::Result<PathBuf> {
        let target = self.cache_for(image);
        fs::create_dir_all(&self.flattened_dir)?;
        let scale = self.read(image).as_ref().and_then(scale).or_else(|| imagefile::info(image).map(|i| i.2));
        let bytes = match scale {
            Some(s) => imagefile::with_png_dpi(png, imagefile::dpi_for_scale(s)),
            None => None,
        };
        let tmp = target.with_extension("png.tmp");
        fs::write(&tmp, bytes.as_deref().unwrap_or(png))?;
        fs::rename(&tmp, &target)?;
        Ok(target)
    }

    pub fn remove_all(&self, image: &Path) {
        let _ = remove_if_present(&naming::edit_file_path(image));
        let _ = remove_if_present(&self.cache_for(image));
    }

    /// Edit file and cache modification times.
    pub fn state(&self, image: &Path) -> EditState {
        let edit_modified = modified(&naming::edit_file_path(image));
        let cache = self.cache_for(image);
        let fresh = edit_modified.is_some() && naming::is_fresh(modified(&cache), edit_modified);
        EditState { edit_modified, cache: fresh.then_some(cache) }
    }

    /// The fresh cache when the image has edits, else the original.
    pub fn flattened_or_original(&self, image: &Path) -> PathBuf {
        self.state(image).cache.unwrap_or_else(|| image.to_path_buf())
    }
}

pub struct EditState {
    pub edit_modified: Option<SystemTime>,
    /// The flattened cache, only when it is fresh.
    pub cache: Option<PathBuf>,
}

impl EditState {
    pub fn has_edits(&self) -> bool {
        self.edit_modified.is_some()
    }
}

pub fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{thread, time::Duration};

    #[test]
    fn has_edits_follows_macos() {
        assert!(!has_edits(&json!({"format":1,"scale":2,"annotations":[],"backdrop":{"enabled":false}})));
        assert!(has_edits(&json!({"annotations":[{"id":"a","type":"arrow"}]})));
        assert!(has_edits(&json!({"crop":[20,20,200,150]})));
        assert!(!has_edits(&json!({"crop":[20,20]})));
        assert!(has_edits(&json!({"backdrop":{"enabled":true,"preset":"mist"}})));
    }

    #[test]
    fn canonical_sorts_nested_keys() {
        let v = json!({"scale":2,"annotations":[{"type":"text","id":"x"}],"format":1});
        assert_eq!(serde_json::to_string(&canonical(&v)).unwrap(), r#"{"annotations":[{"id":"x","type":"text"}],"format":1,"scale":2}"#);
    }

    #[test]
    fn edit_file_and_cache_lifecycle() {
        let root = std::env::temp_dir().join(format!("snipeshot-edits-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let image = root.join("Capture.png");
        fs::write(&image, imagefile::encode_png(&[0, 0, 0, 255], 1, 1, 1.5).unwrap()).unwrap();
        let paths = Paths { flattened_dir: root.join("Flattened") };

        assert_eq!(paths.flattened_or_original(&image), image);
        let edits = json!({"format":1,"scale":2,"annotations":[{"id":"a"}],"backdrop":{"enabled":false}});
        paths.write(&image, Some(&edits)).unwrap();
        assert_eq!(paths.read(&image), Some(canonical(&edits)));
        let state = paths.state(&image);
        assert!(state.has_edits() && state.cache.is_none());
        assert_eq!(paths.flattened_or_original(&image), image);

        thread::sleep(Duration::from_millis(20));
        let rendered = imagefile::encode_png(&[9, 9, 9, 255, 9, 9, 9, 255], 2, 1, 1.0).unwrap();
        let cache = paths.write_flattened(&image, &rendered).unwrap();
        assert_eq!(paths.flattened_or_original(&image), cache);
        // The cache takes the edit file's scale.
        assert_eq!(imagefile::info(&cache).map(|i| i.2), Some(2.0));

        // Newer edits make the cache stale until the next upload.
        thread::sleep(Duration::from_millis(20));
        paths.write(&image, Some(&edits)).unwrap();
        assert!(paths.state(&image).cache.is_none());

        paths.write(&image, Some(&json!({"annotations":[]}))).unwrap();
        assert!(!naming::edit_file_path(&image).exists());
        assert!(!cache.exists());
        assert!(paths.read(&image).is_none());
        paths.write(&image, None).unwrap();
        let _ = fs::remove_dir_all(&root);
    }
}
