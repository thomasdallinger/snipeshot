//! Images on the clipboard as CF_DIB (every app) plus the registered "PNG" format (browsers, Office,
//! chat apps, which keep alpha and DPI).

use std::{thread, time::Duration};

use windows::{
    core::w,
    Win32::{
        Foundation::{GlobalFree, HANDLE, HGLOBAL},
        System::{
            DataExchange::{
                CloseClipboard, EmptyClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
                RegisterClipboardFormatW, SetClipboardData,
            },
            Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE},
            Ole::CF_DIB,
        },
    },
};

use crate::imagefile;

fn png_format() -> u32 {
    unsafe { RegisterClipboardFormatW(w!("PNG")) }
}

/// Another app may hold the clipboard for a moment; try a few times.
fn open() -> Result<(), String> {
    for _ in 0..10 {
        if unsafe { OpenClipboard(None) }.is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(15));
    }
    Err("The clipboard is busy.".into())
}

unsafe fn put(format: u32, bytes: &[u8]) -> Result<(), String> {
    unsafe {
        let mem = GlobalAlloc(GMEM_MOVEABLE, bytes.len()).map_err(|e| e.to_string())?;
        let ptr = GlobalLock(mem) as *mut u8;
        if ptr.is_null() {
            let _ = GlobalFree(Some(mem));
            return Err("No memory for the clipboard.".into());
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        let _ = GlobalUnlock(mem);
        // On success the clipboard owns the memory.
        SetClipboardData(format, Some(HANDLE(mem.0))).map(|_| ()).map_err(|e| {
            let _ = GlobalFree(Some(mem));
            e.to_string()
        })
    }
}

pub fn set_clipboard_image(png: &[u8], rgba: &[u8], width: u32, height: u32) -> Result<(), String> {
    let dib = imagefile::dib_from_rgba(rgba, width, height);
    let png_format = png_format();
    open()?;
    let result = unsafe {
        let _ = EmptyClipboard();
        put(CF_DIB.0 as u32, &dib).and_then(|_| put(png_format, png))
    };
    unsafe {
        let _ = CloseClipboard();
    }
    result
}

/// The raw "PNG" clipboard data, when another app put one there.
fn clipboard_png() -> Option<Vec<u8>> {
    let format = png_format();
    unsafe {
        if IsClipboardFormatAvailable(format).is_err() {
            return None;
        }
        open().ok()?;
        let bytes = GetClipboardData(format).ok().and_then(|h| {
            let mem = HGLOBAL(h.0);
            let ptr = GlobalLock(mem) as *const u8;
            if ptr.is_null() {
                return None;
            }
            let out = std::slice::from_raw_parts(ptr, GlobalSize(mem)).to_vec();
            let _ = GlobalUnlock(mem);
            Some(out)
        });
        let _ = CloseClipboard();
        bytes
    }
}

fn png_with_scale(bytes: Vec<u8>) -> Option<(Vec<u8>, f64)> {
    if imagefile::png_size(&bytes).is_some() && imagefile::decode_rgba(&bytes).is_ok() {
        let scale = imagefile::scale_from_dpi(imagefile::png_dpi(&bytes));
        return Some((bytes, scale));
    }
    let img = imagefile::decode_rgba(&bytes).ok()?;
    let scale = imagefile::scale_from_dpi(imagefile::jpeg_dpi(&bytes));
    let png = imagefile::encode_png(img.as_raw(), img.width(), img.height(), scale).ok()?;
    Some((png, scale))
}

/// PNG bytes and scale of the clipboard image: a PNG, a bitmap, or a copied image file.
pub fn clipboard_image() -> Option<(Vec<u8>, f64)> {
    if let Some(found) = clipboard_png().and_then(png_with_scale) {
        return Some(found);
    }
    let mut cb = arboard::Clipboard::new().ok()?;
    if let Ok(img) = cb.get_image() {
        let png = imagefile::encode_png(&img.bytes, img.width as u32, img.height as u32, 1.0).ok()?;
        return Some((png, 1.0));
    }
    let files = cb.get().file_list().ok()?;
    let file = files.into_iter().find(|f| crate::naming::is_image(f))?;
    png_with_scale(std::fs::read(file).ok()?)
}
