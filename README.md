# Snipeshot

A small, native screenshot tool for macOS. Press ⇧⌘4, mark the capture up if you want, and drag it
wherever it needs to go.

- **Capture** an area, a window or the whole screen from the usual macOS keys. The screen freezes while
  you choose, with a pixel magnifier and the colour under the pointer. Space switches between area and
  window picking; a single click takes the window under the pointer.
- **Drag it anywhere.** Each capture lands as a card in the bottom-left corner. Drag the card into a
  Finder folder, a browser, a chat or a terminal and it arrives as a real PNG, edits included.
  Hover the card to copy, edit, pin, reveal or delete it.
- **Mark it up** with arrows, lines, rectangles, ellipses, pen, highlighter, text, numbered steps and
  redaction (pixelate, blur, black out). Crop, put it on a calm backdrop with padding and shadow,
  undo anything.
- **Nothing to save.** Originals are never changed; edits live in a hidden file next to each capture
  and are kept as you work. Copy or drag to get the finished image.
- **Library** of every capture, grouped by day, with the editor next to it.
- **Pin** any capture (or the clipboard) as a floating window above everything else.

Snipeshot lives in the menu bar, has no account, no analytics and no network access.

## Requirements

macOS 14 or later, and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Install from source

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

## Contributing

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [DESIGN.md](DESIGN.md).

## License

[MIT](LICENSE). Third-party notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
