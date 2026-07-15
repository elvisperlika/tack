import AppKit
import Foundation

/// `swift run swift-executable --selftest` — the runnable checks for the non-trivial logic.
enum SelfTest {
    static func run() {
        noteStoreRoundTrip()
        coordFlip()
        colorHexRoundTrip()
        print("✅ all self-tests passed")
    }

    static func colorHexRoundTrip() {
        assert(Swatch.hex(from: Swatch.color(fromHex: "FFEB73")) == "FFEB73", "hex round-trip failed")
        assert(Swatch.hex(from: Swatch.color(fromHex: "bad")) == Swatch.defaultHex, "bad hex should fall back to default")
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
        assert(!FileManager.default.fileExists(atPath: NoteStore.fileURL(forFolder: folder).path), "file should be gone")
    }

    static func coordFlip() {
        // primary height 1000, window top-left (100,50), offset (20,40) -> note TL (120,90) -> Cocoa y 910
        let p = Coord.cocoaTopLeft(finderLeft: 100, finderTop: 50, dx: 20, dy: 40, primaryHeight: 1000)
        assert(p.x == 120 && p.y == 910, "coord flip wrong: \(p)")
    }
}
