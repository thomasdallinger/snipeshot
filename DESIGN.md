# Design

The product is **the capture**. Everything around it (tools, settings, files) is instrument panel:
compact, neutral, exact. It should feel like a Mac tool made by people who care about pixels
(Preview, Pixelmator, Sketch), not like a web dashboard in a window.

## Principles

1. **The image wins.** The canvas gets the space and the contrast. Chrome is small, gray and flat, and it
   never competes with the screenshot in colour or weight.
2. **Native first.** System font, system materials only where macOS uses them (sidebar, HUD), system
   accent colour for selection and focus, light and dark following macOS. A Mac user should never meet a
   control that behaves differently from AppKit.
3. **Everything visible, nothing hidden.** Every tool has its own button and a single-letter shortcut.
   Properties live in an inspector you can see, not in popovers you have to discover.
4. **No save step.** Edits are kept the moment you make them. The status bar says so. There is no
   Done, no Save dialog unless you export.
5. **Drag is the main verb.** Every thumbnail (the floating card, every library row) can be dragged
   straight into Finder, a browser, a chat or a terminal as a real file.

## Tokens

| Role | Value | Use |
|---|---|---|
| Window | `windowBackgroundColor` | window chrome, header, inspector |
| Sidebar | `NSVisualEffectView.Material.sidebar` | capture list only |
| Canvas | light `#E8E8EA`, dark `#1A1A1C` | area behind the image |
| Text | `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | three levels, never more |
| Line | `separatorColor`, 1 px | between header, panes and status bar only |
| Accent | `controlAccentColor` (the user's choice) | selection, focus, the one primary button |
| Status | `systemGreen` / `systemOrange` / `systemRed` | always paired with words |

- **Annotation palette:** Red `#E5342E` (default), Orange `#F27A1A`, Yellow `#F5C518`, Green `#2E9E5B`,
  Blue `#2F6FEB`, Ink `#16171A`, White `#FFFFFF`, plus a custom colour well.
- **Stroke presets:** S 2 · M 4 (default) · L 8 · XL 14 pt. **Text presets:** S 18 · M 28 (default) · L 44 pt.
- **Backdrops:** Snow, Slate, Mist, Sky, Sage, Dusk. Flat or very low-contrast two-tone. Default padding 48,
  corner radius 10, soft shadow.
- **Type:** SF Pro via the system font. 11 (captions), 12 (secondary), 13 (body, controls), 15 (titles).
  Numbers use tabular figures. Weight contrast is regular vs semibold, nothing else.
- **Spacing:** 4 pt base. Tight inside a group (4–8), generous between groups (16–24).
- **Shape:** radius 5 (controls), 8 (thumbnails), 10 (floating cards, pins). No pills except the
  selector's size label.
- **Elevation:** shadows only on things that float above other apps: the shelf card, pinned images, the
  selector HUD. Nothing inside a window has a shadow.
- **Icons:** SF Symbols at regular weight, only on buttons that do something. Never next to a label for
  decoration, never inside a tinted rounded square.
- **Motion:** 120–180 ms ease-out. No bounce, no springs on chrome. Everything static when
  *Reduce motion* is on.

## Copy

Short, sentence case, verbs first ("Copy", "Show in Finder", "Turn off"). Say what happens, not how
great it is. No exclamation marks, no em dashes, no "seamless", "effortless", "powerful", "magic".

## Never

Purple, indigo or violet anywhere · decorative gradients · glass panels inside the window · glowing
borders · sparkle or wand icons · floating pill toolbars · capsule buttons · cards inside cards ·
icon-plus-label rows in settings · uppercase tracked eyebrows · `A · B · C` meta strings · emoji ·
cream + terracotta · forced dark mode.

## Surfaces

- **Library window:** sidebar (captures grouped by day: "Today", "Yesterday", "Monday 19 October";
  each row a small thumbnail, the time and the pixel size) · header (tools on the left, undo/redo and
  Copy on the right) · canvas · inspector (Style, Text, Redaction, Backdrop, contextual to the tool or
  selection) · status bar (size, save state, zoom).
- **Shelf:** one card per capture, stacked in the bottom-left corner of the screen you captured on.
  Plain thumbnail with a hairline edge. On hover a slim bar appears along the bottom with icon buttons
  (copy, edit, pin, show in Finder, delete) and a close button in the corner. Drag the card itself to
  share it.
- **Selector:** the frozen screen, lightly dimmed. Selection is a 1 px white rectangle with the size
  below it. A square loupe with a pixel grid and the hex value. One HUD line at the bottom with keycaps.
- **Settings:** three tabs (General, Shortcuts, Saving). Problems appear as one line with one button at
  the top of the relevant tab.
