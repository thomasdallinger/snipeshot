# Snipeshot

A small screenshot tool for macOS and Windows. Press a key, mark the capture up if you want, and drag it
wherever it needs to go.

- **Capture** an area, a window or the whole screen from the usual keys (⇧⌘3/4/5 on macOS, Print Screen on
  Windows). The screen freezes while you choose, with a pixel magnifier and the colour under the pointer.
  Space switches between area and window picking; a single click takes the window under the pointer.
- **Drag it anywhere.** Each capture lands as a card in the bottom-left corner of the screen you are working
  on, and moves with the pointer to another monitor. Drag the card into a folder, a browser, a chat or a
  terminal and it arrives as a real PNG, edits included. Hover the card to copy, edit, pin, reveal or delete it.
- **Mark it up** with arrows, lines, rectangles, ellipses, pen, highlighter, text, numbered steps and
  redaction (pixelate, blur, black out). Crop, put it on a calm backdrop with padding and shadow,
  undo anything.
- **Nothing to save.** Originals are never changed; edits live in a hidden file next to each capture
  and are kept as you work. Copy or drag to get the finished image. The edit files are the same on both
  platforms.
- **Library** of every capture, grouped by day, with the editor next to it.
- **Pin** any capture (or the clipboard) as a floating window above everything else.

Snipeshot lives in the menu bar (macOS) or the notification area (Windows), has no account, no analytics and
no network access.

## Install on macOS

**You need:** macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is
not needed.

```bash
git clone https://github.com/thomasdallinger/snipeshot.git
cd snipeshot
./scripts/setup-signing.sh   # once: a local signing identity so macOS remembers permissions across rebuilds
./scripts/install.sh         # builds, copies to /Applications and launches
```

### First run

1. **Screen Recording.** On the first capture macOS asks for permission. Turn Snipeshot on in
   System Settings › Privacy & Security › Screen Recording, then quit and reopen it.
2. **Screenshot keys.** Settings › Shortcuts shows whether macOS still answers ⇧⌘3, ⇧⌘4 or ⇧⌘5 with its
   own tool and turns those system shortcuts off with one click. You can also pick other keys.
3. **Open at login** is in Settings › General.

Captures are saved to `~/Pictures/Snipeshot` (changeable in Settings › Saving).

**Updating.** `git pull && ./scripts/install.sh`. Settings, captures and the Screen Recording permission stay.

## Install on Windows

The Windows app lives in [`windows/`](windows) (Tauri 2 + Svelte) and runs on Windows 10 and 11 (x64).

**You need:** [Rust](https://rustup.rs) (stable, with the MSVC toolchain and the Visual Studio Build Tools it
asks for), [Node](https://nodejs.org) 22 or later and Git. The WebView2 runtime is part of Windows 11; on
Windows 10 the installer fetches it if it is missing.

```powershell
git clone https://github.com/thomasdallinger/snipeshot.git
cd snipeshot\windows
npm install
npm run tauri build
```

Then run the installer in `src-tauri\target\release\bundle\nsis\` (`Snipeshot_…_x64-setup.exe`). It installs
for the current user only and needs no administrator rights. The installer is not code signed, so SmartScreen
may ask: choose *More info › Run anyway*.

### First run

1. **Find it** in the notification area (click the arrow next to the clock if it is hidden). Settings opens on
   the first launch.
2. **Print Screen.** Windows 11 opens the Snipping Tool on Print Screen by default. Settings › Shortcuts
   shows this and turns it off with one click (if Print Screen still opens the Snipping Tool, sign out and
   back in once). Default keys: Print Screen (area), Alt+Print Screen (window), Ctrl+Print Screen (whole
   screen). You can pick other keys.
3. **Open at login** is in Settings › General.

Captures are saved to `Pictures\Snipeshot` (changeable in Settings › Saving).

**Updating.** `git pull`, `npm install`, `npm run tauri build`, then run the new installer over the old one.
Settings (`%APPDATA%\io.github.thomasdallinger.snipeshot`) and captures stay.

**Building on a Mac.** `npx tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc --no-bundle`
cross-compiles `snipeshot.exe` (needs `rustup target add x86_64-pc-windows-msvc` and
`cargo install cargo-xwin`). The exe runs on its own; copy it to the Windows machine.

## Keyboard

| Key | Action |
|---|---|
| V R O A L | Select, Rectangle, Ellipse, Arrow, Line |
| P H T N | Pen, Highlighter, Text, Step number |
| B C | Redact, Crop |
| ⌘C / ⇧⌘E | Copy the edited image / Export a copy |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌫ / ⌘D / arrows | Delete, duplicate, nudge the selection |
| ⌘0 / ⌘1 / ⌘+ / ⌘− | Fit, actual size, zoom in, zoom out |
| Return / Esc | Keep or discard a crop |

On Windows, Ctrl takes the place of ⌘ (Ctrl+Y also redoes) and Delete deletes.

## Contributing

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [DESIGN.md](DESIGN.md).

## License

[MIT](LICENSE). Third-party notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
