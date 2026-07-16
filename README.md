# 📌 Taaaaaaaaaack

Sticky notes that stick to windows, not your desktop.

<p align="center">
  <img src="example.gif" alt="Tack in finder" width="600">
  <br><br>
  <img src="example2.gif" alt="Tack in other apps" width="600">
</p>

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

## How it works

Tack is one process with two timers and a JSON file.

A slow timer fires every 0.4 seconds and asks macOS which app is frontmost. That decides what the note should attach to:

- If it's Finder, Tack sends a single Apple event asking for the front window's folder and position. The note for that folder lives in a hidden `.tack.json` inside the folder itself, which is why it survives the folder being moved, copied, or synced to another Mac.
- If it's any other app, Tack finds the focused window through the Accessibility API and looks the note up in a central store keyed to that window.

Keeping the note glued to its window works differently in the two cases. Finder doesn't push window-move events over Apple events, so while a folder note is showing, Tack polls the window position at 60fps. Regular app windows are cheaper: an `AXObserver` subscribes to moved and resized notifications, so the note only repaints when the window actually moves.

The note itself is a borderless `NSWindow` floating above everything else. Its position is stored as an offset from the tracked window's top-left corner, and that offset is clamped so the note can never escape the window's bounds. The coordinate math (AppleScript measures from the screen's top-left, Cocoa from the bottom-left) lives in pure functions, which is what `--selftest` asserts on without launching any UI.

Deleting is implicit: empty a note's text and its file, or store entry, is removed.
