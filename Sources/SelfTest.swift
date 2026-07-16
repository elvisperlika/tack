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
