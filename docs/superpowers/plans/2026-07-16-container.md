# Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `AppController`'s `Target` enum with a polymorphic `Container` class so a note can attach to an app, one of its windows, or one tab inside it, and so per-app identity rules have somewhere to live.

**Architecture:** A `Container` exposes `path: [String]` — the identity of the focused surface, coarse → fine (`[app, window, tab]`). The attach level is an index into that path; the note key is `path.prefix(level + 1).joined(separator: "|")`. The level is never stored — lookup walks finest → coarsest and reports which prefix hit, which is what makes a window-level note visible from every tab in that window. Subclasses override identity and storage; `Container.resolve(front:)` picks the subclass.

**Tech Stack:** Swift 6.1 (language mode v5), AppKit, Accessibility API, NSAppleScript. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-07-16-container-design.md`

## Global Constraints

- **macOS 13+**, Swift tools 6.1, `swiftLanguageMode(.v5)` — do not add strict-concurrency ceremony (`Package.swift:9`).
- **Zero dependencies.** AppKit, Foundation, ApplicationServices only. Do not add a package.
- **Key format is a compatibility guarantee.** `Container.key(path: ["com.foo.Bar", "doc.txt"], level: 1)` must equal `"com.foo.Bar|doc.txt"` — byte-identical to the key `AXWindows.focused` builds today (`AXWindows.swift:25`). Existing `appnotes.json` files depend on it. Task 1 locks this with a test.
- **Empty note text means delete** in both stores. Preserve this; promotion relies on it.
- **Tests are `assert`-based**, run by `swift run swift-executable --selftest`, no framework, no UI (`Sources/SelfTest.swift`). Every new pure function gets one.
- **Identity resolution happens only on the 0.4s poll, never at 60fps.** The tracking path calls `frame()` and nothing else. This is what makes AX tree digging and Apple events affordable.
- **Mark deliberate shortcuts** with a `ponytail:` comment naming the ceiling.
- Formatting is `swift-format` on save via `.vscode/settings.json`; match the existing 4-space, 100-column style.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Container.swift` | **New.** `Frame`, `Container` base, the subclasses, `resolve`. The only place per-app rules live. |
| `Sources/AppController.swift` | Timers, menu, and wiring. Loses `Target` and all five switches. |
| `Sources/AXWindows.swift` | Raw AX reads. Gains a web-area URL helper; `string(_:_:)` becomes internal. |
| `Sources/SelfTest.swift` | The `assert` checks, including `FakeContainer`. |
| `Sources/NoteWindow.swift` | Untouched. |
| `Info.plist` | Apple-events usage string (Task 7). |

---

### Task 1: Container base class

The pure logic — identity paths, key building, lookup order, promotion. Nothing uses it yet, so this task cannot change behavior. It ends with the compatibility guarantee locked under test.

**Files:**
- Create: `Sources/Container.swift`
- Modify: `Sources/SelfTest.swift:6-13` (register checks), append `FakeContainer` + checks

**Interfaces:**
- Consumes: `Note` (`NoteStore.swift:5`) — `Note(text:dx:dy:color:)`, `Equatable`.
- Produces:
  - `struct Frame { var bounds: CGRect; var covering: [CGRect] = [] }`
  - `class Container` with `var path: [String]`, `var minLevel: Int`, `var finestLevel: Int`, `static func key(path: [String], level: Int) -> String`, `func key(at: Int) -> String`, `func note(at: Int) -> Note?`, `func write(_: Note, at: Int)`, `func frame() -> Frame?`, `func tracker(onMove: @escaping (Frame) -> Void) -> AnyObject?`, `final func load() -> (note: Note, level: Int)?`, `final func move(_: Note, from: Int, to: Int)`

Note the naming: the spec sketched `save(_:level:)`; the implementation calls it `write(_:at:)` because it is the subclass storage hook that `load()` and `move()` both build on. There is no separate `save`.

- [ ] **Step 1: Write the failing tests**

Append to `Sources/SelfTest.swift`:

```swift
/// A Container with in-memory storage, so the lookup and promotion logic can be tested
/// without an app, a window, or an Accessibility grant. This is the payoff of the class
/// over the old enum.
final class FakeContainer: Container {
    private var storage: [String: Note] = [:]
    private let ident: [String]

    init(path: [String]) { self.ident = path }

    override var path: [String] { ident }
    override func note(at level: Int) -> Note? { storage[key(at: level)] }
    override func write(_ note: Note, at level: Int) {
        storage[key(at: level)] = note.text.isEmpty ? nil : note  // empty text == delete
    }
}

extension SelfTest {
    static func containerKeys() {
        let p = ["com.foo.Bar", "doc.txt"]
        assert(Container.key(path: p, level: 0) == "com.foo.Bar", "app level should be the bundle ID")

        // The no-migration guarantee: identical to the old `bundle + "|" + ident` key
        // (AXWindows.swift:25). If this fails, every existing app note is orphaned.
        assert(Container.key(path: p, level: 1) == "com.foo.Bar|doc.txt", "key format changed")

        assert(Container.key(path: ["a", "b", "c"], level: 1) == "a|b", "should join a prefix only")
        assert(Container.key(path: ["a", "b", "c"], level: 2) == "a|b|c", "finest should join all")
    }

    static func containerLoadFallback() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2)

        assert(c.load() == nil, "no note anywhere should not resolve")

        c.write(n, at: 1)  // a window-level note
        guard let hit = c.load() else {
            assert(false, "a window note should be visible from the tab")
            return
        }
        assert(hit.note == n && hit.level == 1, "should fall back to the window level: \(hit)")

        c.write(Note(text: "tab", dx: 3, dy: 4), at: 2)
        assert(c.load()?.level == 2, "the finest note wins when both exist")
    }

    static func containerPromotion() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2)
        c.write(n, at: 2)

        c.move(n, from: 2, to: 1)
        assert(c.note(at: 2) == nil, "the old key should be gone after promotion")
        assert(c.note(at: 1) == n, "the note should live at the window level now")
        assert(c.load()?.level == 1, "and lookup should find it there")
    }
}
```

Register them in `SelfTest.run()` (`Sources/SelfTest.swift:6-13`), which becomes:

```swift
    static func run() {
        noteStoreRoundTrip()
        appNotesRoundTrip()
        coordFlip()
        clampToWindow()
        colorHexRoundTrip()
        containerKeys()
        containerLoadFallback()
        containerPromotion()
        print("✅ all self-tests passed")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'Container' in scope` / `cannot find type 'Container' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Container.swift`:

```swift
import AppKit

/// Where a tracked window is, and what's stacked above it. The two travel together because
/// this is read at 60fps: splitting them would double the CGWindowList traversal per frame.
struct Frame {
    var bounds: CGRect  // top-left screen coords, like Finder/CGWindow
    var covering: [CGRect] = []  // normal windows sitting above it
}

/// The focused surface a note sticks to: an app, one of its windows, or one tab inside it.
///
/// Identity is a path, coarse → fine — ["com.apple.Preview", "Report.pdf"] — and the attach
/// level is an index into it. Tack only ever cares about the focused surface, so there is no
/// tree here: just the path to the current leaf.
///
/// Subclasses supply identity (`path`) and storage (`note(at:)` / `write(_:at:)`).
class Container {
    /// Identity, coarse → fine: [app, window, tab]. Only as deep as the app actually resolves.
    var path: [String] { [] }

    /// The coarsest level a note may attach at. Finder overrides this: its notes live in a
    /// .tack.json inside the folder, so "a note on all of Finder" has no file to live in.
    var minLevel: Int { 0 }

    var finestLevel: Int { path.count - 1 }

    /// The note key for a prefix of `path`. Pure, and the format is a compatibility
    /// guarantee: at the finest level of a 2-part path it reproduces the pre-Container
    /// key exactly, so existing appnotes.json files keep resolving.
    static func key(path: [String], level: Int) -> String {
        path.prefix(level + 1).joined(separator: "|")
    }

    func key(at level: Int) -> String { Self.key(path: path, level: level) }

    // MARK: - Storage (subclass supplies)

    func note(at level: Int) -> Note? { nil }
    func write(_ note: Note, at level: Int) {}

    // MARK: - Position (subclass supplies)

    func frame() -> Frame? { nil }

    /// Non-nil = this container pushes move events and the caller should not poll.
    /// nil = the caller polls `frame()` instead.
    func tracker(onMove: @escaping (Frame) -> Void) -> AnyObject? { nil }

    // MARK: - Lookup

    /// Finest → coarsest, first hit wins, reporting the level it hit at.
    ///
    /// This is why the level is never stored in the Note: it *is* whichever prefix the note
    /// was written under. A window-level note is therefore found by every tab in that window
    /// for free, and there's no chicken-and-egg where you'd need the level to build the key
    /// to load the note that holds the level.
    final func load() -> (note: Note, level: Int)? {
        guard !path.isEmpty else { return nil }
        for level in stride(from: finestLevel, through: minLevel, by: -1) {
            if let n = note(at: level) { return (n, level) }
        }
        return nil
    }

    /// Promotion. Empty text is the delete convention in both stores, so this is
    /// delete-at-the-old-key then write-at-the-new-one.
    final func move(_ note: Note, from: Int, to: Int) {
        guard from != to else { return }
        write(Note(text: "", dx: note.dx, dy: note.dy, color: note.color), at: from)
        write(note, at: to)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build && swift run swift-executable --selftest`
Expected: `✅ all self-tests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/Container.swift Sources/SelfTest.swift
git commit -m "feat: add Container base — identity path, implicit attach level"
```

---

### Task 2: FinderContainer, GenericAppContainer, and resolve

Port the two existing targets onto the base. Still nothing calls them — `AppController` is untouched — so behavior cannot change yet.

**Files:**
- Modify: `Sources/Container.swift` (append)
- Modify: `Sources/AXWindows.swift:46-52` (make `string(_:_:)` internal)
- Modify: `Sources/SelfTest.swift` (append two checks + register)

**Interfaces:**
- Consumes: `Container`, `Frame` (Task 1); `NoteStore.load(folder:)` / `.save(folder:note:)` (`NoteStore.swift:21,27`); `AppNotes.load(key:)` / `.save(key:note:)` (`NoteStore.swift:55,57`); `FinderWatcher.current() -> FinderState?` (`FinderWatcher.swift:34`); `FinderWatcher.frontFinderWindow() -> FinderWindowInfo?` (`FinderWatcher.swift:53`); `AXWindows.focusedWindow(pid:) -> AXUIElement?`, `AXWindows.focusedBounds(pid:) -> CGRect?`, `AXWindowTracker.init?(pid:window:onMove:)` (`AXWindows.swift:34,29,77`).
- Produces:
  - `final class FinderContainer: Container` — `init(folder: String)`, `static let bundleID = "com.apple.finder"`
  - `class GenericAppContainer: Container` — `init?(app: NSRunningApplication)`, with `let bundleID: String`, `let pid: pid_t`, `let ident: String` all internal (Tasks 5 and 7 subclass this and read `bundleID`/`ident`)
  - `static func Container.resolve(front: NSRunningApplication) -> Container?`

- [ ] **Step 1: Write the failing tests**

Append to `Sources/SelfTest.swift`:

```swift
extension SelfTest {
    static func finderContainerRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let c = FinderContainer(folder: dir.path)
        assert(c.path == ["com.apple.finder", dir.path], "finder path wrong: \(c.path)")

        // A folder note can't be promoted: it lives in a .tack.json *inside* the folder,
        // so level 0 ("all of Finder") would have no file to live in.
        assert(c.minLevel == 1, "Finder should not offer promotion")
        assert(c.finestLevel == 1, "finder path should be two components")

        let n = Note(text: "hi", dx: 1, dy: 2)
        c.write(n, at: 1)
        guard let hit = c.load() else {
            assert(false, "finder note should round-trip")
            return
        }
        assert(hit.note == n && hit.level == 1, "finder round-trip mismatch: \(hit)")

        c.write(Note(text: "", dx: 1, dy: 2), at: 1)
        assert(c.load() == nil, "empty text should delete the folder note")
    }

    static func genericKeyMatchesLegacyFormat() {
        // Belt and braces alongside containerKeys(): the generic container's finest key must
        // be exactly what AXWindows.focused built before Container existed.
        let legacy = "com.foo.Bar" + "|" + "Untitled 1"
        assert(
            Container.key(path: ["com.foo.Bar", "Untitled 1"], level: 1) == legacy,
            "generic key drifted from the legacy format — existing notes would orphan")
    }
}
```

Register both in `SelfTest.run()` after `containerPromotion()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'FinderContainer' in scope`.

- [ ] **Step 3: Write the implementation**

First make the AX string reader available to subclasses. In `Sources/AXWindows.swift:46`, change:

```swift
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
```

to:

```swift
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
```

Then append to `Sources/Container.swift`:

```swift
// MARK: - Finder

/// A Finder folder. The note lives in a hidden .tack.json inside the folder itself, which is
/// why it travels with the folder when you move or copy it — and why it can't be promoted.
final class FinderContainer: Container {
    static let bundleID = "com.apple.finder"
    let folder: String

    init(folder: String) { self.folder = folder }

    override var path: [String] { [Self.bundleID, folder] }
    override var minLevel: Int { 1 }

    // ponytail: one level exists here, so `level` is always 1 and the folder is the key
    override func note(at level: Int) -> Note? { NoteStore.load(folder: folder) }
    override func write(_ note: Note, at level: Int) { NoteStore.save(folder: folder, note: note) }

    /// Finder pushes no move events over Apple events, so `tracker` stays nil and the caller
    /// polls this at 60fps. CGWindowList gives bounds and occluders in the same pass.
    override func frame() -> Frame? {
        guard let info = FinderWatcher.frontFinderWindow() else { return nil }
        return Frame(bounds: info.bounds, covering: info.coveringRects)
    }
}

// MARK: - Any other app

/// Any app window readable through the Accessibility API. AXDocument names the focused
/// document and follows Preview's active tab; AXTitle is the fuzzy fallback and follows the
/// Settings pane. Non-final: BrowserContainer and TerminalContainer refine the identity.
class GenericAppContainer: Container {
    let bundleID: String
    let pid: pid_t
    let ident: String

    init?(app: NSRunningApplication) {
        guard let win = AXWindows.focusedWindow(pid: app.processIdentifier),
            let id = AXWindows.string(win, kAXDocumentAttribute)
                ?? AXWindows.string(win, kAXTitleAttribute),
            !id.isEmpty
        else { return nil }
        self.bundleID = app.bundleIdentifier ?? app.localizedName ?? "app"
        self.pid = app.processIdentifier
        self.ident = id
    }

    override var path: [String] { [bundleID, ident] }

    override func note(at level: Int) -> Note? { AppNotes.load(key: key(at: level)) }
    override func write(_ note: Note, at level: Int) {
        AppNotes.save(key: key(at: level), note: note)
    }

    /// A focused app window is already on top, so nothing covers the note — `covering` stays
    /// empty and the caller's occlusion test collapses to false on its own.
    override func frame() -> Frame? {
        AXWindows.focusedBounds(pid: pid).map { Frame(bounds: $0) }
    }

    /// App windows glide via AX move/resize notifications instead of 60fps polling.
    override func tracker(onMove: @escaping (Frame) -> Void) -> AnyObject? {
        guard let win = AXWindows.focusedWindow(pid: pid) else { return nil }
        return AXWindowTracker(pid: pid, window: win) { onMove(Frame(bounds: $0)) }
    }
}

// MARK: - Resolution

extension Container {
    /// Which container the frontmost app gets. The one place per-app rules live.
    static func resolve(front: NSRunningApplication) -> Container? {
        if front.bundleIdentifier == FinderContainer.bundleID {
            guard let state = FinderWatcher.current() else { return nil }
            return FinderContainer(folder: state.path)
        }
        return GenericAppContainer(app: front)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build && swift run swift-executable --selftest`
Expected: `✅ all self-tests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/Container.swift Sources/AXWindows.swift Sources/SelfTest.swift
git commit -m "feat: port Finder and generic app targets onto Container"
```

---

### Task 3: Port AppController onto Container

**This task must produce zero user-visible change.** Same notes, same keys, same behavior. If a note moves, flickers, or disappears after this, the port is wrong. All five switches over `Target` go away.

**Files:**
- Modify: `Sources/AppController.swift:18-167` (most of `AppDelegate`)

**Interfaces:**
- Consumes: `Container`, `Frame`, `Container.resolve(front:)`, `container.load()`, `container.write(_:at:)`, `container.frame()`, `container.tracker(onMove:)`, `container.finestLevel` (Tasks 1–2); `NoteWindow.show(note:bounds:save:)` (`NoteWindow.swift:303`), `.updateWindow(bounds:)` (`:389`), `.setOccluded(_:)` (`:325`), `.hide()` (`:398`), `.screenRectTopLeft()` (`:332`), `.focusForEditing()` (`:403`), `.onDelete` (`:98`).
- Produces: nothing later tasks consume except `AppDelegate.current: Container?` and `AppDelegate.currentLevel: Int`, which Task 4's menu reads.

- [ ] **Step 1: Replace the state and target resolution**

In `Sources/AppController.swift`, replace lines 18-30 (the stored properties and the `Target` enum) with:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let note = NoteWindow()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackTimer: Timer?  // fast: glue the note to the window (60fps), only when
    private var tracker: AnyObject?  // the container can't push moves itself

    private var current: Container?
    private var currentLevel = 0  // the level the shown note was found at — edits save back here
```

The `Target` enum is deleted outright.

- [ ] **Step 2: Replace target resolution and the four switches**

Replace lines 52-85 (the whole `// MARK: - Target resolution` section: `resolve`, `bounds(for:)`, `load(_:)`, `saver(for:)`) with just:

```swift
    // MARK: - Target resolution

    /// The surface the user is focused on right now (or `current` while we're editing our own
    /// note, which would otherwise resolve to Tack itself).
    private func resolve() -> Container? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return current }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return current }
        return Container.resolve(front: front)
    }
```

`bounds(for:)`, `load(_:)`, and `saver(for:)` are gone — they're `container.frame()`, `container.load()`, and `container.write(_:at:)`.

- [ ] **Step 3: Replace the loops**

Replace lines 87-130 (the whole `// MARK: - Loops` section: `pollTarget`, `trackTarget`, `startAppTracking`) with:

```swift
    // MARK: - Loops

    private func pollTarget() {
        guard let container = resolve() else {
            hideNote()
            current = nil
            return
        }
        // Container is a class, so identity is the path, not the object.
        guard container.path != current?.path else { return }
        current = container
        if let hit = container.load(), let f = container.frame() {
            currentLevel = hit.level
            showNote(hit.note, frame: f, container: container)
        } else {
            hideNote()
        }
    }

    private func trackTarget() {
        guard let f = current?.frame() else { return }
        apply(f)
    }

    /// The one place the note follows its window. Containers that can't be covered report no
    /// occluders, so the same two lines serve Finder and app windows alike.
    private func apply(_ f: Frame) {
        note.updateWindow(bounds: f.bounds)
        note.setOccluded(f.covering.contains { $0.intersects(note.screenRectTopLeft()) })
    }

    /// Prefer the container's own move events; fall back to the 60fps timer only if it has none.
    private func startTracking(_ container: Container) {
        tracker = container.tracker { [weak self] f in self?.apply(f) }
        guard tracker == nil else {
            trackTimer?.invalidate()
            trackTimer = nil
            return
        }
        guard trackTimer == nil else { return }
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            self?.trackTarget()
        }
    }
```

- [ ] **Step 4: Replace show/hide and addNote**

Replace lines 132-164 (`showNote`, `hideNote`, `stopTracking`, `addNote`) with:

```swift
    // MARK: - Show / hide

    private func showNote(_ n: Note, frame f: Frame, container: Container) {
        note.show(note: n, bounds: f.bounds) { [weak self] edited in
            guard let self else { return }
            container.write(edited, at: self.currentLevel)  // read late: promotion moves it
        }
        apply(f)
        startTracking(container)
    }

    private func hideNote() {
        note.hide()
        stopTracking()
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        tracker = nil
    }

    // MARK: - Menu

    @objc private func addNote() {
        guard let container = resolve(), let f = container.frame() else { return }
        current = container
        let hit = container.load()
        currentLevel = hit?.level ?? container.finestLevel  // finest available, promote later
        showNote(hit?.note ?? Note(text: "", dx: 20, dy: 40), frame: f, container: container)
        NSApp.activate(ignoringOtherApps: true)
        note.focusForEditing()
    }
```

The save closure reads `self.currentLevel` at call time rather than capturing it — that's what lets Task 4's promotion redirect subsequent edits without rebuilding the note.

- [ ] **Step 5: Build and run the self-tests**

Run: `swift build && swift run swift-executable --selftest`
Expected: `✅ all self-tests passed`, no warnings about unused `appTracker`/`Target`.

- [ ] **Step 6: Verify no behavior change by hand**

This is a refactor; the tests can't see the UI. Run: `./bundle.sh && open Tack.app`

Check all four, against notes that existed *before* this branch:

1. Focus a Finder folder that already has a note → the note appears, unchanged.
2. Drag the Finder window → the note follows smoothly at 60fps, and slides under a window stacked on top of it (occlusion still works).
3. Focus a non-Finder app window that already has a note → the note appears. Its key came from `appnotes.json` written by the old code; if it doesn't appear, the key format broke.
4. Drag that app window → the note glides via AX notifications, no 60fps timer.

Expected: identical to `main`. If anything differs, stop and fix before Task 4.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppController.swift
git commit -m "refactor: drive AppController from Container, deleting the Target switches"
```

---

### Task 4: Promotion menu

Lets a note move up from the tab it defaulted to. Menu items are built live from the current container's path, so an app with no tabs simply offers nothing.

**Files:**
- Modify: `Sources/Container.swift` (append `LevelName`)
- Modify: `Sources/AppController.swift` (menu construction, `NSMenuDelegate`, `pin(_:)`)
- Modify: `Sources/SelfTest.swift` (append `levelLabels` + register)

**Interfaces:**
- Consumes: `Container.minLevel`, `.finestLevel`, `.path`, `.load()`, `.move(_:from:to:)` (Tasks 1–2); `AppDelegate.current`, `.currentLevel` (Task 3).
- Produces: `enum LevelName { static func label(level: Int, of count: Int) -> String }`

- [ ] **Step 1: Write the failing test**

Append to `Sources/SelfTest.swift`:

```swift
extension SelfTest {
    static func levelLabels() {
        // 3-part path (a browser tab): app / window / tab
        assert(LevelName.label(level: 0, of: 3) == "Pin to this app", "level 0 is always the app")
        assert(LevelName.label(level: 1, of: 3) == "Pin to this window", "middle is the window")
        assert(LevelName.label(level: 2, of: 3) == "Pin to this tab", "deepest of 3 is the tab")

        // 2-part path (a plain app window, or Preview where AXDocument already names the tab):
        // the deepest level is the window itself, not a tab.
        assert(LevelName.label(level: 0, of: 2) == "Pin to this app", "level 0 is always the app")
        assert(LevelName.label(level: 1, of: 2) == "Pin to this window", "deepest of 2 is a window")
    }
}
```

Register `levelLabels()` in `SelfTest.run()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'LevelName' in scope`.

- [ ] **Step 3: Implement LevelName**

Append to `Sources/Container.swift`:

```swift
/// Menu wording for an attach level. Pure so it can be tested without a menu.
enum LevelName {
    /// Level 0 is always the app. The deepest level of a 3-part path is a tab; everything
    /// else is a window — a 2-part path bottoms out at the window, not a tab.
    static func label(level: Int, of count: Int) -> String {
        if level == 0 { return "Pin to this app" }
        if count > 2 && level == count - 1 { return "Pin to this tab" }
        return "Pin to this window"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift build && swift run swift-executable --selftest`
Expected: `✅ all self-tests passed`

- [ ] **Step 5: Wire the menu**

In `Sources/AppController.swift`, `applicationDidFinishLaunching` (currently lines 36-42), the menu gains a delegate and a marker item the pin items are inserted after:

```swift
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Add note here", action: #selector(addNote), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self  // pin items are rebuilt per open, from the live path
        statusItem.menu = menu
```

Then append this extension at the end of the file:

```swift
/// The pin items depend on whatever is focused *right now*, so they're rebuilt each time the
/// menu opens rather than stored.
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag != 0 || $0.action == #selector(pin(_:)) }
            .forEach(menu.removeItem)

        guard let container = current, let hit = container.load(),
            container.finestLevel > container.minLevel  // nothing to choose between
        else { return }

        var index = 1  // just after "Add note here"
        for level in container.minLevel...container.finestLevel {
            let item = NSMenuItem(
                title: LevelName.label(level: level, of: container.path.count),
                action: #selector(pin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = level == hit.level ? .on : .off
            menu.insertItem(item, at: index)
            index += 1
        }
        menu.insertItem(.separator(), at: index)
    }
}
```

The removal filter needs care: `tag != 0` catches the pin items for levels ≥ 1, and the `action` check catches level 0, whose tag is legitimately 0. The separator inserted alongside them has tag 0 and no action, so tag it on insert — change `menu.insertItem(.separator(), at: index)` to:

```swift
            let sep = NSMenuItem.separator()
            sep.tag = -1  // so the next rebuild removes it with the pin items
            menu.insertItem(sep, at: index)
```

- [ ] **Step 6: Implement the action**

Add to `AppDelegate`, next to `addNote`:

```swift
    /// Move the current note to a coarser (or finer) level. Delete-then-write, so the note
    /// never exists at two keys at once.
    @objc private func pin(_ sender: NSMenuItem) {
        guard let container = current, let hit = container.load() else { return }
        container.move(hit.note, from: hit.level, to: sender.tag)
        currentLevel = sender.tag  // the save closure reads this on the next edit
    }
```

- [ ] **Step 7: Verify by hand**

Run: `./bundle.sh && open Tack.app`

1. Focus a Finder folder with a note, open the 📌 menu → **no pin items** (`minLevel == finestLevel == 1`).
2. Focus a plain app window with a note, open the menu → "Pin to this app" and "Pin to this window", with "this window" checkmarked.
3. Click "Pin to this app". Reopen the menu → the checkmark is on "this app".
4. Focus a *different* window of that same app → the note appears there too. That's the promotion working: the tab-level lookup misses and the app-level prefix hits.
5. Type in the note, then focus away and back → the edit persisted at the app level, not the old one.

- [ ] **Step 8: Commit**

```bash
git add Sources/Container.swift Sources/AppController.swift Sources/SelfTest.swift
git commit -m "feat: promote a note to its window or app from the menu"
```

---

### Task 5: BrowserContainer

The case the generic key genuinely cannot handle: every Chrome tab in a window shares one window identity that mutates as you switch tabs. Identity comes from `AXURL` on the window's `AXWebArea` descendant — no new permission, because Tack already holds Accessibility.

**Files:**
- Modify: `Sources/AXWindows.swift` (append `focusedURL` + `webArea`)
- Modify: `Sources/Container.swift` (append `BrowserContainer`, extend `resolve`)
- Modify: `Sources/SelfTest.swift` (append `urlNormalization` + register)

**Interfaces:**
- Consumes: `GenericAppContainer` and its `bundleID` / `ident` (Task 2); `AXWindows.focusedWindow(pid:)`, `AXWindows.string(_:_:)` (Task 2 made it internal).
- Produces: `AXWindows.focusedURL(pid:) -> String?`; `final class BrowserContainer: GenericAppContainer` with `static let bundleIDs: Set<String>` and `static func normalize(_ raw: String) -> String`.

- [ ] **Step 1: Write the failing test**

Append to `Sources/SelfTest.swift`:

```swift
extension SelfTest {
    static func urlNormalization() {
        // Query and fragment are session noise; a note pinned to a page should survive them.
        assert(
            BrowserContainer.normalize("https://github.com/x/y?tab=readme#install")
                == "https://github.com/x/y", "should strip query and fragment")
        assert(
            BrowserContainer.normalize("https://x.com/a") == "https://x.com/a",
            "a clean URL should pass through untouched")

        // Anything unparseable is used as-is rather than crashing or collapsing to "".
        assert(BrowserContainer.normalize("notaurl") == "notaurl", "garbage should pass through")
        assert(BrowserContainer.normalize("") == "", "empty should pass through")
    }
}
```

Register `urlNormalization()` in `SelfTest.run()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'BrowserContainer' in scope`.

- [ ] **Step 3: Add the AX web-area reader**

Append inside `enum AXWindows` in `Sources/AXWindows.swift` (before the closing brace):

```swift
    /// The URL of the focused window's web area. Chrome and Safari expose their full AX tree
    /// once a trusted client is watching, which we are. nil → the caller binds to the window
    /// instead of the tab. Called on the 0.4s poll only, never per frame.
    static func focusedURL(pid: pid_t) -> String? {
        guard let win = focusedWindow(pid: pid), let area = webArea(in: win, depth: 0),
            let value = attribute(area, kAXURLAttribute)
        else { return nil }
        if let u = value as? URL { return u.absoluteString }
        return value as? String
    }

    // ponytail: depth-limited DFS; the web area sits a few levels under the window. Depth 6
    // covers Chrome and Safari today — raise it if a browser buries it deeper.
    private static func webArea(in el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 6 { return nil }
        if string(el, kAXRoleAttribute) == "AXWebArea" { return el }
        guard let value = attribute(el, kAXChildrenAttribute), let kids = value as? [AXUIElement]
        else { return nil }
        for kid in kids {
            if let hit = webArea(in: kid, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func attribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value
    }
```

- [ ] **Step 4: Add BrowserContainer**

Append to `Sources/Container.swift`:

```swift
/// A browser tab. The generic key can't tell one Chrome tab from another — they share a window
/// identity that mutates as you switch — so the URL becomes the third path component.
///
/// Note the path keeps `ident` as its second component rather than a prefixed variant, so the
/// level-1 key still matches the pre-Container format and old title-keyed browser notes resolve
/// as window-level notes instead of orphaning.
final class BrowserContainer: GenericAppContainer {
    static let bundleIDs: Set<String> = ["com.google.Chrome", "com.apple.Safari"]
    private let url: String?

    override init?(app: NSRunningApplication) {
        url = AXWindows.focusedURL(pid: app.processIdentifier).map(BrowserContainer.normalize)
        super.init(app: app)
    }

    override var path: [String] {
        guard let url, !url.isEmpty else { return [bundleID, ident] }  // no URL → window level
        return [bundleID, ident, url]
    }

    /// scheme + host + path. Query and fragment are session noise.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.host != nil else { return raw }
        c.query = nil
        c.fragment = nil
        return c.url?.absoluteString ?? raw
    }
}
```

- [ ] **Step 5: Extend resolve**

In `Sources/Container.swift`, `Container.resolve(front:)` becomes:

```swift
    static func resolve(front: NSRunningApplication) -> Container? {
        if front.bundleIdentifier == FinderContainer.bundleID {
            guard let state = FinderWatcher.current() else { return nil }
            return FinderContainer(folder: state.path)
        }
        if let id = front.bundleIdentifier, BrowserContainer.bundleIDs.contains(id) {
            return BrowserContainer(app: front)
        }
        return GenericAppContainer(app: front)
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift build && swift run swift-executable --selftest`
Expected: `✅ all self-tests passed`

- [ ] **Step 7: Verify by hand**

Run: `./bundle.sh && open Tack.app`

1. Open two Chrome tabs on different sites. Add a note to tab A.
2. Switch to tab B → the note disappears. Switch back → it returns. This is the whole point of the task; if the note shows on both, the URL isn't resolving and it silently bound at window level.
3. Open the menu on a browser tab → three pin items ("app" / "window" / "tab"), "tab" checkmarked.
4. Click "Pin to this window" → the note now shows on **both** tabs.
5. Reload tab A, or navigate within the same page adding a `?query` → the note stays. That's normalization.

- [ ] **Step 8: Commit**

```bash
git add Sources/AXWindows.swift Sources/Container.swift Sources/SelfTest.swift
git commit -m "feat: bind browser notes to the tab URL, not the window"
```

---

### Task 6: Probe Preview and Settings, then decide

The spec deferred `PreviewContainer` and `SettingsContainer` on the theory that the generic key already handles them — `AXDocument` follows Preview's active tab, `AXTitle` follows the Settings pane. **This task tests that theory rather than assuming it.** The deliverable is a decision recorded in the spec, plus a subclass only where the key actually misbehaves.

**Files:**
- Modify: `Sources/AppController.swift` (`pollTarget`, one line)
- Modify: `docs/superpowers/specs/2026-07-16-container-design.md` (record findings)

**Interfaces:**
- Consumes: `Container.path` (Task 1), `AppDelegate.pollTarget` (Task 3).
- Produces: nothing, unless the probe justifies a subclass.

- [ ] **Step 1: Add the debug logging**

In `pollTarget` (Task 3), just after `current = container`:

```swift
        current = container
        // ponytail: opt-in path logging for diagnosing identity. Enable with
        //   defaults write com.tack.app debugPaths -bool YES
        // then watch with: log stream --predicate 'process == "Tack"'
        if UserDefaults.standard.bool(forKey: "debugPaths") {
            NSLog("[tack] path=%@", container.path.joined(separator: " / "))
        }
```

- [ ] **Step 2: Build and enable the probe**

```bash
./bundle.sh && defaults write com.tack.app debugPaths -bool YES && open Tack.app
```

In a second terminal: `log stream --predicate 'process == "Tack"' --style compact`

- [ ] **Step 3: Observe Preview**

Open one Preview window with **two or more PDFs in tabs** (View ▸ Show Tab Bar). Click between tabs and watch the log.

**The criterion:** does the second path component change when you switch tabs?

- Changes per tab (e.g. `com.apple.Preview / Report.pdf` → `com.apple.Preview / Notes.pdf`) → **the generic container works. Write no subclass.**
- Stays identical across tabs → the generic key can't see the tab. `PreviewContainer` is justified; model it on `BrowserContainer` (Task 5), sourcing the third component from the tab's own AX element rather than `AXURL`.

- [ ] **Step 4: Observe Settings**

Open System Settings and click between panes (General, Displays, Network).

**The criterion:** does the second path component follow the pane?

- Changes per pane → **no subclass.**
- Stays on a constant like `System Settings` → `SettingsContainer` is justified; source the pane name from the selected sidebar row.

- [ ] **Step 5: Record the findings**

Replace the "Preview and Settings" section of the spec with what you actually saw — the observed paths, verbatim, and the decision each led to. If a subclass turned out unnecessary, say so explicitly and why; that record is what stops someone adding it speculatively later. If one was justified, note which attribute the identity came from.

- [ ] **Step 6: Turn the probe off and commit**

```bash
defaults delete com.tack.app debugPaths
git add Sources/AppController.swift docs/superpowers/specs/2026-07-16-container-design.md
git commit -m "feat: add opt-in path logging; record Preview/Settings findings"
```

---

### Task 7: TerminalContainer

Terminal tab titles churn as commands run, so a title-derived key is unstable — the note would vanish mid-`make`. The TTY is the only stable tab identity, and it costs one Apple event.

**Files:**
- Modify: `Sources/Container.swift` (append `TerminalContainer`, extend `resolve`)
- Modify: `Info.plist:15` (`NSAppleEventsUsageDescription`)

**Interfaces:**
- Consumes: `GenericAppContainer` and its `bundleID` / `ident` (Task 2).
- Produces: `final class TerminalContainer: GenericAppContainer` with `static let bundleID = "com.apple.Terminal"`.

There's no self-test here: the logic is one Apple event and an optional-map, both of which need a live Terminal. The fallback is verified by hand in Step 4.

- [ ] **Step 1: Add TerminalContainer**

Append to `Sources/Container.swift`:

```swift
/// A Terminal tab. Tab titles churn as commands run, so a title-keyed note would vanish
/// mid-build; the tty (/dev/ttys003) is the only stable tab identity, and it costs one
/// Apple event on the 0.4s poll.
final class TerminalContainer: GenericAppContainer {
    static let bundleID = "com.apple.Terminal"

    private static let ttyScript = NSAppleScript(
        source: """
            tell application "Terminal"
                if (count of windows) is 0 then return ""
                return tty of selected tab of front window
            end tell
            """)

    private let tty: String?

    override init?(app: NSRunningApplication) {
        tty = TerminalContainer.currentTTY()
        super.init(app: app)
    }

    /// nil when Terminal has no window, or when the automation prompt was denied — the
    /// container then binds at window level rather than failing.
    static func currentTTY() -> String? {
        var err: NSDictionary?
        guard let s = ttyScript?.executeAndReturnError(&err).stringValue, !s.isEmpty else {
            return nil
        }
        return s
    }

    override var path: [String] {
        guard let tty else { return [bundleID, ident] }  // no tty → window level
        return [bundleID, ident, tty]
    }
}
```

- [ ] **Step 2: Extend resolve**

`Container.resolve(front:)` gains one branch, becoming:

```swift
    static func resolve(front: NSRunningApplication) -> Container? {
        if front.bundleIdentifier == FinderContainer.bundleID {
            guard let state = FinderWatcher.current() else { return nil }
            return FinderContainer(folder: state.path)
        }
        if let id = front.bundleIdentifier {
            if BrowserContainer.bundleIDs.contains(id) { return BrowserContainer(app: front) }
            if id == TerminalContainer.bundleID { return TerminalContainer(app: front) }
        }
        return GenericAppContainer(app: front)
    }
```

- [ ] **Step 3: Reword the Apple-events usage string**

`Info.plist:15` currently reads:

```xml
    <key>NSAppleEventsUsageDescription</key><string>Tack watches which folder is open in Finder to show its notes.</string>
```

It's shown in the consent prompt for Terminal now too, so it must describe both:

```xml
    <key>NSAppleEventsUsageDescription</key><string>Tack watches which folder is open in Finder and which tab is active in Terminal, to show the right note.</string>
```

- [ ] **Step 4: Verify by hand**

Run: `swift build && swift run swift-executable --selftest` → `✅ all self-tests passed`

Then `./bundle.sh && open Tack.app`

1. Focus Terminal → macOS prompts to let Tack control Terminal, showing the new wording. **Allow.**
2. Add a note to a Terminal tab. Open a second tab (⌘T) → the note disappears. Back to tab 1 → it returns.
3. In tab 1, run something that rewrites the title: `sleep 5`. The note **must not disappear** while it runs. This is the whole reason the tty is the key rather than the title.
4. **Test the denial path.** Reset consent and deny it:
   ```bash
   tccutil reset AppleEvents com.tack.app
   ```
   Relaunch, focus Terminal, and **deny** the prompt. Expect: notes still work, bound at window level — one note for the whole Terminal window, no crash, no hang. Then re-allow with the same `tccutil reset` and grant.

Note: `bundle.sh` ad-hoc signs, so a rebuild changes the code signature and macOS may re-prompt. That's expected, not a bug.

- [ ] **Step 5: Commit**

```bash
git add Sources/Container.swift Info.plist
git commit -m "feat: bind Terminal notes to the tty, not the churning tab title"
```

---

### Task 8: Update the README

`README.md`'s "How it works" describes the old two-case model ("If it's Finder… If it's any other app…"). It's now wrong in a way that would mislead the next reader.

**Files:**
- Modify: `README.md` ("How it works", and "Use" for promotion)

- [ ] **Step 1: Rewrite the binding paragraph**

In "How it works", replace the two bullets describing the Finder/other-app split with a description of the container model: a note binds to a *path* — app, window, tab — and Tack picks the finest identity the app exposes. Finder notes still live in the folder's `.tack.json`; everything else lives in the central store, keyed by the path prefix. Mention that browsers key on the tab URL and Terminal on the tty, and why (their window identity mutates as you switch tabs).

Keep the existing voice: plain, concrete, no marketing.

- [ ] **Step 2: Document promotion under "Use"**

Add a step: a note defaults to the finest surface available (the tab), and the 📌 menu promotes it to the whole window or the whole app. Note the Finder exception — a folder note stays with its folder.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe the container model in the README"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Identity path, `key`, level-as-index | 1 |
| Level not stored / finest → coarsest lookup | 1 (`load`, tested) |
| No storage migration | 1 (`containerKeys`), 2 (`genericKeyMatchesLegacyFormat`) |
| `Frame` as one syscall | 1 (type), 2 (`FinderContainer.frame`) |
| `minLevel` / Finder can't promote | 2 (tested), 4 (menu respects it) |
| `FinderContainer`, `GenericAppContainer` | 2 |
| `resolve` | 2, extended in 5 and 7 |
| Data flow, switch collapse | 3 |
| Promotion menu | 4 |
| `BrowserContainer`, URL normalization | 5 |
| Preview/Settings probe | 6 |
| `TerminalContainer`, Info.plist | 7 |
| Error handling (every fallback) | 2 (`init?` → nil → hide), 5 (Step 7.2), 7 (Step 4.4) |
| Testing (all 6 checks) | 1, 2, 4, 5 |

**Deviations from the spec, deliberate:**

1. **`save(_:level:)` → `write(_:at:)`.** One storage hook, not two names for it.
2. **The `"win:"` prefix on browser and terminal paths is dropped.** The spec's table showed `[bundleID, "win:" + title, url]`. Without the prefix, the level-1 key is `bundleID|title` — exactly the legacy format — so old browser and Terminal notes resolve as window-level notes instead of orphaning. The prefix bought nothing but readability and cost compatibility. The spec is updated to match.
