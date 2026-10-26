//! File names and paths shared with the macOS app: capture names, collision suffixes, the hidden
//! edit file next to each image and the flattened cache.

use std::{
    path::{Path, PathBuf},
    time::SystemTime,
};

use chrono::NaiveDateTime;

pub const IMAGE_EXTENSIONS: [&str; 8] = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp"];
/// Edit files sit next to each capture as `.<file>.<suffix>`.
pub const EDIT_FILE_SUFFIX: &str = "snipeshot.json";

pub fn is_image(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// "Capture 2026-10-21 14.03.22"
pub fn capture_name(at: NaiveDateTime) -> String {
    format!("Capture {}", at.format("%Y-%m-%d %H.%M.%S"))
}

/// `dir/base.ext`, or `dir/base (2).ext`, `(3)`… when taken.
pub fn unique_path(dir: &Path, base: &str, ext: &str, exists: impl Fn(&Path) -> bool) -> PathBuf {
    let mut path = dir.join(format!("{base}.{ext}"));
    let mut n = 2;
    while exists(&path) {
        path = dir.join(format!("{base} ({n}).{ext}"));
        n += 1;
    }
    path
}

pub fn edit_file_path(image: &Path) -> PathBuf {
    let name = image.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    image.with_file_name(format!(".{name}.{EDIT_FILE_SUFFIX}"))
}

/// Edit files and other dot files are not captures.
pub fn is_dot_file(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.'))
}

/// `<cache dir>/<sha1 of the path string>.png`
pub fn flattened_cache_path(cache_dir: &Path, image: &Path) -> PathBuf {
    let digest = sha1_smol::Sha1::from(image.to_string_lossy().as_bytes()).digest().to_string();
    cache_dir.join(format!("{digest}.png"))
}

/// The cache is fresh when it exists and is not older than the edit file.
pub fn is_fresh(cache_modified: Option<SystemTime>, edit_modified: Option<SystemTime>) -> bool {
    match (cache_modified, edit_modified) {
        (Some(cache), Some(edit)) => cache >= edit,
        (Some(_), None) => true,
        (None, _) => false,
    }
}

/// File name without extension, the capture's display name.
pub fn stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

const URI_UNRESERVED: &[u8] = b"-_.!~*'()";

/// Same output as JavaScript's `encodeURIComponent`.
pub fn encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || URI_UNRESERVED.contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Inverse of `encodeURIComponent`; malformed escapes are kept as they are.
pub fn decode_uri_component(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |b: u8| (b as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use std::{collections::HashSet, time::Duration};

    #[test]
    fn capture_names_match_macos() {
        let at = NaiveDate::from_ymd_opt(2026, 10, 21).unwrap().and_hms_opt(14, 3, 22).unwrap();
        assert_eq!(capture_name(at), "Capture 2026-10-21 14.03.22");
    }

    #[test]
    fn unique_paths_count_up() {
        let dir = Path::new("/caps");
        let taken: HashSet<PathBuf> =
            ["/caps/Capture.png", "/caps/Capture (2).png"].iter().map(PathBuf::from).collect();
        assert_eq!(unique_path(dir, "Capture", "png", |p| taken.contains(p)), PathBuf::from("/caps/Capture (3).png"));
        assert_eq!(unique_path(dir, "Other", "jpg", |p| taken.contains(p)), PathBuf::from("/caps/Other.jpg"));
    }

    #[test]
    fn edit_file_sits_next_to_the_image() {
        let p = Path::new("/caps/Capture 2026-10-21 14.03.22.png");
        assert_eq!(edit_file_path(p), PathBuf::from("/caps/.Capture 2026-10-21 14.03.22.png.snipeshot.json"));
        assert!(is_dot_file(&edit_file_path(p)));
        assert!(!is_dot_file(p));
    }

    #[test]
    fn image_extensions() {
        assert!(is_image(Path::new("a.PNG")));
        assert!(is_image(Path::new("a.jpeg")));
        assert!(is_image(Path::new("a.webp")));
        assert!(!is_image(Path::new("a.heic")));
        assert!(!is_image(Path::new("a.json")));
        assert!(!is_image(Path::new("png")));
    }

    #[test]
    fn flattened_cache_uses_sha1_of_the_path() {
        let p = flattened_cache_path(Path::new("/cache"), Path::new("abc"));
        // sha1("abc")
        assert_eq!(p, PathBuf::from("/cache/a9993e364706816aba3e25717850c26c9cd0d89d.png"));
    }

    #[test]
    fn freshness() {
        let t = SystemTime::UNIX_EPOCH + Duration::from_secs(1000);
        let later = t + Duration::from_millis(1);
        assert!(is_fresh(Some(t), Some(t)));
        assert!(is_fresh(Some(later), Some(t)));
        assert!(!is_fresh(Some(t), Some(later)));
        assert!(!is_fresh(None, Some(t)));
        assert!(is_fresh(Some(t), None));
    }

    #[test]
    fn uri_component_round_trip() {
        let path = r"C:\Users\Zoë\Pictures\Snipeshot\Capture 2026-10-21 14.03.22 (2).png";
        let enc = encode_uri_component(path);
        assert_eq!(&enc[..12], "C%3A%5CUsers");
        assert!(enc.contains("Zo%C3%AB"));
        assert!(enc.contains("(2).png"));
        assert_eq!(decode_uri_component(&enc), path);
        assert_eq!(decode_uri_component("100%"), "100%");
        assert_eq!(decode_uri_component("%zz%41"), "%zzA");
    }
}
