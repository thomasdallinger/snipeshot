//! Dragging a capture out as a real file. The shell builds the data object (CF_HDROP, shell ID
//! lists, file contents) and the default drop source with its drag image, so Explorer, browsers,
//! chat apps and terminals all accept it. Copy only: a drop never moves the capture away.

use std::path::Path;

use tauri::WebviewWindow;
use windows::{
    core::PCWSTR,
    Win32::{
        Foundation::HWND,
        System::{
            Com::IDataObject,
            Ole::{IDropSource, DROPEFFECT_COPY, DROPEFFECT_NONE},
        },
        UI::Shell::{IShellItem, SHCreateItemFromParsingName, SHDoDragDrop, BHID_DataObject},
    },
};

use super::wide;

/// Runs a modal OLE drag of `path`; must be called on the main (STA) thread while a mouse button is
/// down. True when a target accepted the drop.
pub fn drag_file(window: &WebviewWindow, path: &Path) -> Result<bool, String> {
    let hwnd = window.hwnd().ok().map(|h| HWND(h.0 as _));
    let path = wide(path);
    unsafe {
        let item: IShellItem =
            SHCreateItemFromParsingName(PCWSTR(path.as_ptr()), None).map_err(|e| format!("The file could not be dragged: {e}"))?;
        let data: IDataObject =
            item.BindToHandler(None, &BHID_DataObject).map_err(|e| format!("The file could not be dragged: {e}"))?;
        let effect = SHDoDragDrop(hwnd, &data, None::<&IDropSource>, DROPEFFECT_COPY)
            .map_err(|e| format!("The drag stopped: {e}"))?;
        Ok(effect != DROPEFFECT_NONE)
    }
}
