import AppKit
import Foundation

/// `swift run swift-executable --selftest` — the runnable checks for the non-trivial logic.
enum SelfTest {
    static func run() {
        noteStoreRoundTrip()
        appNotesRoundTrip()
        coordFlip()
        clampToWindow()
        colorHexRoundTrip()
        containerKeys()
        containerLoadFallback()
        containerPromotion()
        finderContainerRoundTrip()
        genericKeyMatchesLegacyFormat()
        print("✅ all self-tests passed")
    }

    static func appNotesRoundTrip() {
        let key = "selftest|" + UUID().uuidString  // unique: never clobbers a real note
        let n = Note(text: "hello", dx: 12, dy: 34)
        AppNotes.save(key: key, note: n)
        assert(AppNotes.load(key: key) == n, "app note round-trip mismatch")

        AppNotes.save(key: key, note: Note(text: "", dx: 12, dy: 34))
        assert(AppNotes.load(key: key) == nil, "empty text should delete the app note")
    }

    static func colorHexRoundTrip() {
        assert(
            Swatch.hex(from: Swatch.color(fromHex: "FFEB73")) == "FFEB73", "hex round-trip failed")
        assert(
            Swatch.hex(from: Swatch.color(fromHex: "bad")) == Swatch.defaultHex,
            "bad hex should fall back to default")
    }

    static func noteStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.path

        let n = Note(text: "hello", dx: 12, dy: 34)
        NoteStore.save(folder: folder, note: n)
        assert(NoteStore.load(folder: folder) == n, "round-trip mismatch")

        NoteStore.save(folder: folder, note: Note(text: "", dx: 12, dy: 34))
        assert(NoteStore.load(folder: folder) == nil, "empty text should delete the note")
        assert(
            !FileManager.default.fileExists(atPath: NoteStore.fileURL(forFolder: folder).path),
            "file should be gone")
    }

    static func clampToWindow() {
        let note = CGSize(width: 220, height: 170)
        let win = CGSize(width: 800, height: 600)

        // already inside -> untouched
        var c = Coord.clamp(dx: 100, dy: 50, note: note, window: win)
        assert(c.dx == 100 && c.dy == 50, "inside should not move: \(c)")

        // past the right/bottom edge -> pulled back so the note's far edge sits on the border
        c = Coord.clamp(dx: 999, dy: 999, note: note, window: win)
        assert(c.dx == 580 && c.dy == 430, "should clamp to bottom-right: \(c)")

        // past the left/top edge -> pinned to the corner
        c = Coord.clamp(dx: -50, dy: -50, note: note, window: win)
        assert(c.dx == 0 && c.dy == 0, "should clamp to top-left: \(c)")

        // window smaller than the note -> corner, never a negative offset
        c = Coord.clamp(dx: 30, dy: 30, note: note, window: CGSize(width: 100, height: 100))
        assert(c.dx == 0 && c.dy == 0, "tiny window should pin to corner: \(c)")
    }

    static func coordFlip() {
        // primary height 1000, window top-left (100,50), offset (20,40) -> note TL (120,90) -> Cocoa y 910
        let p = Coord.cocoaTopLeft(
            finderLeft: 100, finderTop: 50, dx: 20, dy: 40, primaryHeight: 1000)
        assert(p.x == 120 && p.y == 910, "coord flip wrong: \(p)")
    }
}

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
