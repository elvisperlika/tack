# 📌 Taaaaaaaaaack

Sticky notes that stick to windows, not your desktop.

![Tack in finder](example.gif)

![Tack in other apps](example2.gif)

Tack is a tiny macOS menu-bar app. Pin a note to a Finder folder or to any app window — the note follows the window as it moves, stays inside its bounds, and reappears when you come back to that window.

- **Finder folders:** the note is saved as a hidden `.tack.json` *inside the folder*, so it travels with the folder when you move or copy it.
- **Other app windows:** notes are kept in a central store, keyed to the window.

No dock icon, no Electron, no dependencies — just AppKit and the Accessibility API.

## Install

```sh
git clone <repo-url>
cd tack
./bundle.sh && open Tack.app
```

Requires macOS 13+ and Xcode command-line tools.

On first launch, macOS asks for permission to control Finder and for Accessibility access (needed to track app windows). Grant both; the 📌 appears in the menu bar.

## Use

1. Focus a Finder folder or any app window.
2. Click 📌 → **Add note here**.
3. Type. Drag the note where you want it — it stays glued to that window.

Emptying a note's text deletes it.

## Development

```sh
swift build            # debug build
swift run swift-executable --selftest   # run the built-in checks
./bundle.sh            # build + package Tack.app (ad-hoc signed)
```

