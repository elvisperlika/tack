# Container: generalising the surface a note sticks to

**Date:** 2026-07-16
**Status:** approved design, not yet implemented

## Problem

A note binds to a surface. Today that surface is modelled as an enum in `AppController.swift`:

```swift
private enum Target: Equatable {
    case folder(path: String)
    case appWindow(key: String, pid: pid_t)
}
```

Three things are wrong with it:

1. **It doesn't scale.** Every capability of a target is a separate `switch` over the same two cases: `bounds(for:)`, `load(_:)`, `saver(for:)`, `startAppTracking(_:)`, and a fifth inside `trackTarget()`. Adding an app means editing five switches.
2. **Per-app identity has nowhere to live.** The key is built one way for everything (`AXDocument ?? AXTitle`), inside `AXWindows.focused`. An app whose tab identity isn't in those two attributes — a browser — cannot be expressed.
3. **The hierarchy is invisible.** An app has windows; a window has tabs (Preview) or sub-pages (Settings). The enum flattens all of that into one opaque `key` string, so a note can only ever bind to the finest surface, never to "this window regardless of tab".

## Design

### The identity path

Tack only ever cares about the *focused* surface. It never enumerates an app's other windows or tabs. So the model is not a tree — it is the **path to the current leaf**:

```
Finder folder    ["com.apple.finder", "/Users/me/Docs"]
Preview tab      ["com.apple.Preview", "Report.pdf"]        // generic: AXDocument follows the tab
Chrome tab       ["com.google.Chrome", "Inbox", "https://github.com/x/y"]
Unknown app      ["com.foo.Bar", "Untitled 1"]
```

Note that a path is only as deep as the app's identity actually resolves. Preview is two components under `GenericAppContainer`, because `AXDocument` already names the active tab — the tab *is* the finest level it exposes. A third component appears only where a subclass digs one out, as `BrowserContainer` does for the URL.

Coarse → fine. The app/window/tab hierarchy becomes an array index:

- **Attach level** = an index into `path`.
- **Finest available** = `path.count - 1`.
- **Note key** = `path.prefix(level + 1).joined(separator: "|")`.
- **Promotion** = decrement the level.

A tree of `App` → `[Window]` → `[Tab]` objects was rejected: resolving the focused leaf would mean enumerating every window and tab on every 0.4s poll and discarding all but one, to build a structure nothing traverses.

### The level is not stored

It is implied by **which prefix a note was saved under**. Lookup walks finest → coarsest and returns the first hit, along with the level it hit at.

This gives three things for free:

- A note saved at window level is found by every tab in that window — the "shared across tabs" requirement, with no extra code.
- `Note` needs no schema change, so every existing `.tack.json` and `appnotes.json` stays valid.
- No chicken-and-egg. If the level were a field *inside* `Note`, you would need the level to build the key to load the note that holds the level.

### No storage migration

For a generic app window, `path` is `[bundleID, ident]`, finest level is `1`, and the key is:

```
path.prefix(2).joined(separator: "|")   ==   bundle + "|" + ident
```

Byte-identical to the key `AXWindows.focused` builds today (`AXWindows.swift:25`). Existing `appnotes.json` files keep resolving. This is a guarantee, and it gets a self-test (see Testing).

### The base class

```swift
/// Bounds and occlusion together: this is read at 60fps and must stay one syscall.
struct Frame {
    var bounds: CGRect       // top-left screen coords
    var covering: [CGRect] = []   // normal windows stacked above it
}

/// The focused surface a note can stick to. Subclasses supply identity and storage.
class Container {
    /// Identity, coarse → fine: [app, window, tab].
    var path: [String] { [] }

    /// Coarsest level this container allows a note at. Finder overrides to 1.
    var minLevel: Int { 0 }

    /// Bounds + occluders in ONE call.
    func frame() -> Frame? { nil }

    /// Finest → coarsest; first hit wins, reports the level it was found at.
    func load() -> (note: Note, level: Int)? { nil }
    func save(_ note: Note, level: Int) {}

    /// Non-nil = the container pushes move events; nil = the caller polls frame().
    func tracker(onMove: @escaping (Frame) -> Void) -> AnyObject? { nil }

    static func key(path: [String], level: Int) -> String   // pure, tested
    static func resolve(front: NSRunningApplication) -> Container?
}
```

`frame()` returns bounds and occluders together on purpose. `trackTarget()` currently makes one `FinderWatcher.frontFinderWindow()` call per tick and reads both fields off the result (`AppController.swift:109-112`). Two separate accessors would double the `CGWindowList` traversal at 60fps. The struct makes that property structural instead of accidental.

`minLevel` exists because **Finder cannot promote**. A Finder note lives in `.tack.json` *inside the folder* — that is the app's entire premise. Level 0 would mean "a note on all of Finder", which has no folder to live in. `FinderContainer.minLevel = 1` means the promotion menu simply offers it nothing.

### The subclasses

| Class | `path` | Storage | `tracker` |
|---|---|---|---|
| `FinderContainer` | `["com.apple.finder", folderPath]` | `.tack.json` in the folder | nil → 60fps poll (Finder pushes no move events) |
| `GenericAppContainer` | `[bundleID, ident]` from `AXDocument ?? AXTitle` | `AppNotes` | `AXWindowTracker` |
| `BrowserContainer` | `[bundleID, ident, normalizedURL]` | `AppNotes` | `AXWindowTracker` |
| `TerminalContainer` | `[bundleID, ident, tty]` | `AppNotes` | `AXWindowTracker` |

The browser and terminal paths keep the plain `ident` as their second component rather than a prefixed variant, so their level-1 key stays byte-identical to the legacy format. Old title-keyed browser and Terminal notes then resolve as window-level notes instead of orphaning — a prefix would have bought readability and cost compatibility.

`Container.resolve(front:)` replaces `AppController.resolve()` and picks the subclass by bundle ID, falling back to `GenericAppContainer`. It is the single place per-app rules live.

### Identity resolution cost

Identity is resolved **only on the 0.4s poll**, never at 60fps — the tracking path reads `frame()` alone. This bounds the cost of the expensive identity work (AX tree digging, Apple events) to 2.5 times per second, which is what makes the browser and terminal cases affordable at all.

### Browser identity

Chrome and Safari are the case the generic key genuinely cannot handle: every tab in a window shares one window-level identity that mutates as you switch tabs.

**Approach:** read `AXURL` from the window's `AXWebArea` descendant via the Accessibility API. Chrome and Safari both expose their full AX tree once a trusted AT client is present, which Tack already is (`AXIsProcessTrusted`).

Chosen over the Apple-event alternative (`tell application "Google Chrome" to get URL of active tab`) because AX needs **no new permission** — Tack already holds Accessibility. An Apple event to Chrome would trigger a separate automation consent prompt per browser, and `bundle.sh` ad-hoc signs the app, so every rebuild changes the code signature and can re-prompt.

**URL normalization** (pure function, tested): keep scheme + host + path, drop query and fragment. `https://github.com/x/y?tab=readme#install` → `https://github.com/x/y`. Query strings are session noise; a note pinned to a page should survive them.

**Fallback:** no `AXWebArea`, no `AXURL`, or an empty one → drop the third path component. The container degrades to a window-level note rather than failing.

### Terminal identity

Terminal tab titles churn as commands run, so a title-derived key is unstable — the note would vanish mid-`make`. The only stable identifier is the TTY (`/dev/ttys003`), reachable via one Apple event:

```applescript
tell application "Terminal" to get tty of selected tab of front window
```

**Known risks, accepted:**

- This triggers an automation consent prompt for Terminal. `NSAppleEventsUsageDescription` is already in `Info.plist` (currently worded for Finder only — it needs rewording to cover both).
- Ad-hoc signing means a rebuild can reset that consent.
- **Fallback:** event fails, is denied, or returns empty → drop the tty component and bind at window level.

iTerm2 is out of scope for this pass.

### Preview and Settings

`PreviewContainer` and `SettingsContainer` are **deliberately not written yet**, pending a probe.

The generic key likely already handles both: `kAXDocumentAttribute` tracks Preview's active tab, and `kAXTitleAttribute` tracks the Settings pane, so switching either already yields a different key and a different note. Writing subclasses now risks two empty overrides that do exactly what the base does.

**The probe** (implementation phase 5): with the base class in, log the resolved `path` on every poll change while clicking through Preview tabs and Settings panes. Add a subclass only where the observed key actually misbehaves — and then the subclass has a real, known reason to exist.

## Data flow

**Poll, every 0.4s — decides *what* the note is bound to:**

1. `front = NSWorkspace.shared.frontmostApplication`; if it's Tack itself, keep `current` (our own note holds focus while editing).
2. `container = Container.resolve(front:)`; nil → hide.
3. `container.path == current?.path` → return. (`Container` is a class, so this compares paths, replacing the `Equatable` enum check at `AppController.swift:95`.)
4. `current = container`; `currentLevel` = the level `load()` reports.
5. `load()` hits and `frame()` is non-nil → show + start tracking. Otherwise hide.

**Track, 60fps — decides *where* the note is drawn:**

```swift
guard let f = current?.frame() else { return }
note.updateWindow(bounds: f.bounds)
note.setOccluded(f.covering.contains { $0.intersects(note.screenRectTopLeft()) })
```

The `switch` in `trackTarget` **collapses entirely**. Today the Finder branch tests occlusion and the app branch hardcodes `setOccluded(false)` because a focused app window is already on top (`AppController.swift:117`). Under `Frame`, app containers return `covering: []`, so `contains {}` is `false` and the same line serves both. The timer still runs only while `tracker()` returned nil.

**Save:** the closure handed to `note.show(note:bounds:save:)` becomes `{ container.save($0, level: currentLevel) }` — edits go back to the key the note was found at, not the finest one.

**Add:** `resolve()`, then reuse the level of any existing note, else finest (`path.count - 1`).

**Promote:** save empty text at the old level (the existing delete convention), then save the note at the new level.

## Error handling

Every failure degrades to a coarser binding or to hiding the note. None of them are fatal, and none change existing behavior:

| Failure | Result |
|---|---|
| AX permission not granted | `focusedWindow` → nil → `resolve` → nil → note hides. Unchanged. |
| Browser URL unresolvable | Drop the URL component → window-level note. |
| Terminal Apple event denied/failed | Drop the tty component → window-level note. |
| `frame()` nil (window gone) | Note hides, as today's `guard let` already does. |
| Storage write fails (read-only/network folder) | Best-effort; unchanged (`NoteStore.swift:26`). |
| Note text emptied | Deletes at whichever level the note lives. Convention preserved. |

## Testing

`--selftest` style: `assert`-based, no UI, no framework (`SelfTest.swift`). The pure logic is where the bugs would be, so it is deliberately separable from AppKit:

1. **`Container.key(path:level:)`** — prefix join at each level.
2. **Key-format compatibility** — assert `Container.key(path: ["com.foo.Bar", "doc.txt"], level: 1) == "com.foo.Bar|doc.txt"`, literally. This is the no-migration guarantee; it should fail loudly if anyone changes the separator or ordering.
3. **Load fallback order** — a `FakeContainer` with in-memory storage: save at level 1, assert a level-2 path finds it and reports level 1.
4. **Promotion** — save at finest, promote to window, assert the old key is gone and the new key holds the note.
5. **`FinderContainer.minLevel == 1`** — no promotion offered for Finder.
6. **URL normalization** — `https://x.com/a?b=1#c` → `https://x.com/a`; malformed input falls back rather than crashing.

`FakeContainer` is what makes 3 and 4 testable without launching an app or granting permissions — it's a subclass overriding `path` and the storage pair, which is the payoff of the class over the enum.

## Files

| File | Change |
|---|---|
| `Sources/Container.swift` | **New.** Base + 4 subclasses + `resolve`. ~150 lines. |
| `Sources/AppController.swift` | Delete `Target` and 5 switches; talk to `Container`. Net shrink. |
| `Sources/AXWindows.swift` | Make `string(_:_:)` internal (subclasses need it); add `AXWebArea`/`AXURL` helper. |
| `Sources/SelfTest.swift` | Add the 6 checks above. |
| `Info.plist` | Reword `NSAppleEventsUsageDescription` to cover Terminal as well as Finder. |
| `Sources/NoteWindow.swift` | Untouched. |

## Implementation phases

1. `Container` base + `Frame` + `key` + `resolve`; port `FinderContainer` and `GenericAppContainer`; gut `AppController`'s switches. **Behavior must be identical here** — same keys, same notes, nothing new.
2. Self-tests 1–5. Verify no regression against existing notes.
3. Promotion menu (dynamic items from `path`, current level checkmarked, `minLevel` respected).
4. `BrowserContainer` + URL normalization + test 6.
5. **Probe** Preview and Settings; add subclasses only if the generic key misbehaves.
6. `TerminalContainer` (tty via Apple event, window-level fallback).

Phase 1 is a pure refactor with no user-visible change — if a note moves or disappears after it, the port is wrong.

## Out of scope

- iTerm2, VS Code editor tabs.
- Notes attached to more than one surface.
- Any change to `Note`, `NoteWindow`, or the note's visual behavior.
- Enumerating an app's non-focused windows or tabs.
