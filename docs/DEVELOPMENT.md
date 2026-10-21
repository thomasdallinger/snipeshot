# Development

```bash
swift build                      # debug build
./scripts/build-app.sh           # release .app in dist/
./scripts/install.sh             # build, install to /Applications, launch
```

The `xcrun: error: unable to lookup item 'PlatformPath'` lines during builds come from the Command
Line Tools and are harmless.

## Checks without Xcode or permissions

The Command Line Tools ship without XCTest, so checks run inside the app binary via launch flags
(`Sources/Snipeshot/App/DevTools.swift`). Dev runs use throwaway preferences and remove any capture
they create.

```bash
BIN=$(swift build --show-bin-path)/Snipeshot

# Edit-file format, shortcut handling, every canvas tool driven by synthesized mouse events,
# undo/redo, crop, backdrop export size, edits surviving a reload, and the file a drag hands out.
$BIN --self-test

# Renders the shelf card, library window, selector, settings and a flattened export into a folder,
# using any image instead of the screen. Needs no Screen Recording permission.
$BIN --snapshot-ui /tmp/ui any-image.png

# Runs the after-capture steps (save, clipboard, shelf) with an existing image, handy for trying drag & drop.
./dist/Snipeshot.app/Contents/MacOS/Snipeshot --simulate-capture any-image.png
```

## Signing

`scripts/setup-signing.sh` creates a self-signed "Local Code Signing" identity in its own keychain
(`~/Library/Keychains/local-codesign.keychain-db`; your login keychain is not touched). The build signs
with it, so the app's designated requirement stays the same across rebuilds. Ad-hoc signatures change on
every build, and macOS would forget the Screen Recording permission each time.

## Renaming

Product naming lives in two places: `Sources/Snipeshot/App/AppIdentity.swift` and `scripts/app.env`.

## Layout

| Path | What |
|---|---|
| `App/` | App delegate (wiring, after-capture steps), menu bar item, dev flags, self-test |
| `Capture/` | ScreenCaptureKit stills and the selector overlay |
| `Hotkeys/` | Global shortcuts (Carbon) and the macOS screenshot shortcut switch |
| `Shelf/` | Bottom-left capture cards and the file drag source |
| `Editor/` | Model and edit-file format, renderer, canvas, header, inspector, status bar |
| `Library/` | Library window and sidebar |
| `Store/` | Capture folder, edit files, previews, drag export |
| `Pin/` | Floating pinned images |
| `Settings/` | Preferences and the settings window |

## Edit file format

Each capture `Capture 2026-10-21 14.03.22.png` may have a hidden `.Capture 2026-10-21 14.03.22.png.snipeshot.json`:

```json
{
  "format": 1,
  "scale": 2,
  "crop": [20, 20, 200, 150],
  "backdrop": { "enabled": true, "preset": "mist", "padding": 48, "radius": 10, "shadow": true },
  "annotations": [
    { "id": "…", "type": "arrow", "color": "#E5342E", "points": [[200, 200], [300, 250]], "stroke": 4 },
    { "id": "…", "type": "text", "color": "#E5342E", "frame": [40, 60, 120, 34], "text": "Check this", "text_size": 28 }
  ]
}
```

Coordinates are in image points with the origin at the top left. `scale` is pixels per point.
