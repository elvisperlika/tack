import AppKit
import Foundation

/// `swift run swift-executable --selftest` — the runnable checks for the non-trivial logic.
enum SelfTest {
    static func run() {
        noteStoreRoundTrip()
        corruptJSONIsPreserved()
        writeFailureIsReported()
        centralBackupKeepsPreviousVersion()
        appNotesRoundTrip()
        stableKeyMigration()
        coordFlip()
        fitToWindow()
        clampToWindow()
        containResize()
        centerNewNote()
        colorHexRoundTrip()
        containerKeys()
        containerLoadFallback()
        containerPromotion()
        containerMovePreservesSourceOnFailure()
        finderContainerRoundTrip()
        genericKeyMatchesLegacyFormat()
        levelLabels()
        debouncerCollapses()
        markdownSpans()
        markdownParse()
        markdownListEditing()
        markdownRoundTrip()
        markdownInlineClosing()
        blockStyleAtCaret()
        blockNavigation()
        backspaceAtTheEnd()
        noteSizeIsOptional()
        urlNormalization()
        notePreferencesPalette()
        fontFaces()
        pillGeometry()
        print("✅ all self-tests passed")
    }

    static func appNotesRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let key = "selftest|" + UUID().uuidString  // unique: never clobbers a real note
        let n = Note(text: "hello", dx: 12, dy: 34)
        try! AppNotes.save(key: key, note: n, to: url)
        let loaded = try! AppNotes.load(key: key, from: url)
        assert(loaded == n, "app note round-trip mismatch")

        try! AppNotes.save(key: key, note: Note(text: "", dx: 12, dy: 34), to: url)
        let deleted = try! AppNotes.load(key: key, from: url)
        assert(deleted == nil, "empty text should delete the app note")
    }

    static func stableKeyMigration() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let id = UUID().uuidString
        let legacy = "selftest|old-title|\(id)"
        let stable = "selftest|\(id)"
        let n = Note(text: "migrate me", dx: 12, dy: 34)
        try! AppNotes.save(key: legacy, note: n, to: url)

        let migrated = try! AppNotes.load(key: stable, migrating: legacy, from: url)
        let stableNote = try! AppNotes.load(key: stable, from: url)
        let legacyNote = try! AppNotes.load(key: legacy, from: url)
        assert(migrated == n, "legacy note should migrate")
        assert(stableNote == n, "migrated note should use the stable key")
        assert(legacyNote == nil, "legacy title-dependent key should be removed")
    }

    static func notePreferencesPalette() {
        let suite = "selftest." + UUID().uuidString  // isolated: never touches the real palette
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = NotePreferences(defaults: defaults)

        let base = prefs.palette
        prefs.addColor("123456")
        assert(prefs.palette == base + ["123456"], "addColor should append")
        prefs.addColor("123456")
        assert(prefs.palette == base + ["123456"], "addColor should dedupe")
        prefs.removeColor("123456")
        assert(prefs.palette == base, "removeColor should drop the colour")

        // Never empty the palette: removing the last colour is a no-op.
        var only = prefs.palette
        while only.count > 1 { prefs.removeColor(only[0]); only = prefs.palette }
        let last = only[0]
        prefs.removeColor(last)
        assert(prefs.palette == [last], "palette must keep at least one colour")
    }

    static func centerNewNote() {
        let c = Coord.center(note: CGSize(width: 220, height: 170), window: CGSize(width: 500, height: 400))
        assert(c.dx == 140 && c.dy == 115, "a new note should start centred")
        // A window smaller than the note: it fills it, so there is nothing left to centre.
        let tight = Coord.center(note: CGSize(width: 220, height: 170), window: CGSize(width: 100, height: 100))
        assert(tight.dx == 0 && tight.dy == 0, "a note capped by the window sits at its top-left")
    }

    static func containResize() {
        let window = CGSize(width: 500, height: 400)
        // Right edge pushed past the border: cut there, left edge (dx) stays put.
        let right = Coord.contain(dx: 100, dy: 10, note: CGSize(width: 480, height: 50), window: window)
        assert(right.dx == 100 && right.size.width == 400, "right edge should stop at the border")
        // Top edge pushed above it: cut there, the bottom edge keeps its place (dy + height).
        let top = Coord.contain(dx: 10, dy: -30, note: CGSize(width: 50, height: 120), window: window)
        assert(top.dy == 0 && top.size.height == 90, "top edge should stop at the border")
        // Inside the window: untouched.
        let inside = Coord.contain(dx: 10, dy: 10, note: CGSize(width: 50, height: 60), window: window)
        assert(
            inside.dx == 10 && inside.dy == 10 && inside.size == CGSize(width: 50, height: 60),
            "a resize that fits should be left alone")
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
        try! NoteStore.save(folder: folder, note: n)
        let loaded = try! NoteStore.load(folder: folder)
        assert(loaded == n, "round-trip mismatch")

        try! NoteStore.save(folder: folder, note: Note(text: "", dx: 12, dy: 34))
        let deleted = try! NoteStore.load(folder: folder)
        assert(deleted == nil, "empty text should delete the note")
        assert(
            !FileManager.default.fileExists(atPath: NoteStore.fileURL(forFolder: folder).path),
            "file should be gone")
    }

    static func corruptJSONIsPreserved() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = NoteStore.fileURL(forFolder: dir.path)
        let corrupt = Data("{recover me".utf8)
        try! corrupt.write(to: url)

        do {
            _ = try NoteStore.load(folder: dir.path)
            assert(false, "invalid JSON must not look like a missing note")
        } catch NotePersistenceError.invalidJSON(_, let recovery, _) {
            assert(recovery != nil, "invalid JSON should get a recovery copy")
            assert((try? Data(contentsOf: recovery!)) == corrupt, "recovery copy changed the data")
        } catch {
            assert(false, "unexpected persistence error: \(error)")
        }

        do {
            try NoteStore.save(folder: dir.path, note: Note(text: "new", dx: 1, dy: 2))
            assert(false, "saving must not overwrite invalid JSON")
        } catch {}
        assert((try? Data(contentsOf: url)) == corrupt, "invalid original must remain untouched")
    }

    static func centralBackupKeepsPreviousVersion() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let old = Note(text: "first", dx: 1, dy: 2)
        let new = Note(text: "second", dx: 3, dy: 4)

        try! AppNotes.save(key: "old", note: old, to: url)
        try! AppNotes.save(key: "new", note: new, to: url)
        let current = try! AppNotes.load(key: "new", from: url)
        let backup = try! AppNotes.load(key: "old", from: url.appendingPathExtension("backup"))
        assert(current == new, "the current file should contain the new value")
        assert(backup == old, "the backup should preserve the previous complete value")
    }

    static func writeFailureIsReported() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing")
        do {
            try NoteStore.save(folder: missing.path, note: Note(text: "nope", dx: 1, dy: 2))
            assert(false, "an unwritable destination must throw")
        } catch NotePersistenceError.write(let url, _) {
            assert(url == NoteStore.fileURL(forFolder: missing.path), "error should name the file")
        } catch {
            assert(false, "unexpected persistence error: \(error)")
        }
    }

    static func fitToWindow() {
        let note = CGSize(width: 220, height: 170)

        // Window bigger than the note -> shown at its desired size.
        var f = Coord.fit(desired: note, window: CGSize(width: 800, height: 600))
        assert(f == note, "a big window should not shrink the note: \(f)")

        // Window narrower and shorter than the note -> capped to the window, per axis.
        f = Coord.fit(desired: note, window: CGSize(width: 100, height: 90))
        assert(f == CGSize(width: 100, height: 90), "note must never exceed the window: \(f)")

        // Only one axis too small -> only that axis is capped.
        f = Coord.fit(desired: note, window: CGSize(width: 100, height: 600))
        assert(f == CGSize(width: 100, height: 170), "only the tight axis should cap: \(f)")
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

    static func debouncerCollapses() {
        let d = Debouncer(delay: 0.05)
        var hits: [Int] = []
        d.call { hits.append(1); return true }
        d.call { hits.append(2); return true }  // must cancel the first
        // Spinning the main run loop drains the main dispatch queue in a CLI process.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assert(hits == [2], "only the last scheduled block should fire: \(hits)")

        d.call { hits.append(3); return true }
        d.flush()
        assert(hits == [2, 3], "flush should run the pending block immediately: \(hits)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(hits == [2, 3], "a flushed block must not run again: \(hits)")

        d.call { hits.append(4); return true }
        d.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(hits == [2, 3], "cancel should drop the pending block: \(hits)")

        var attempts = 0
        d.call {
            attempts += 1
            return attempts > 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(attempts == 1, "the scheduled save should have failed once")
        assert(d.flush() && attempts == 2, "flush should retry retained failed work")
    }

    static func coordFlip() {
        // primary height 1000, window top-left (100,50), offset (20,40) -> note TL (120,90) -> Cocoa y 910
        let p = Coord.cocoaTopLeft(
            finderLeft: 100, finderTop: 50, dx: 20, dy: 40, primaryHeight: 1000)
        assert(p.x == 120 && p.y == 910, "coord flip wrong: \(p)")

        // The round trip: offsets() must be cocoaTopLeft()'s exact inverse, or a drag would
        // shift the note by the drift every time the delegate recomputes dx/dy.
        // cocoaTopLeft returns the note's top-left in Cocoa coords, which is the frame's maxY.
        let back = Coord.offsets(
            noteMinX: Double(p.x), noteCocoaMaxY: Double(p.y),
            finderLeft: 100, finderTop: 50, primaryHeight: 1000)
        assert(back.dx == 20 && back.dy == 40, "flip round trip drifted: \(back)")
    }
}

/// A Container with in-memory storage, so the lookup and promotion logic can be tested
/// without an app, a window, or an Accessibility grant. This is the payoff of the class
/// over the old enum.
private enum FakeWriteError: Error { case blocked }

final class FakeContainer: Container {
    private var storage: [String: Note] = [:]
    private let ident: [String]
    private let stableFinestKey: String?
    var failingLevel: Int?
    var writes: [Int] = []

    init(path: [String], finestKey: String? = nil) {
        self.ident = path
        self.stableFinestKey = finestKey
    }

    override var path: [String] { ident }
    override var finestKey: String? { stableFinestKey }
    override func note(at level: Int) throws -> Note? { storage[key(at: level)] }
    override func write(_ note: Note, at level: Int) throws {
        writes.append(level)
        if failingLevel == level { throw FakeWriteError.blocked }
        storage[key(at: level)] = note.isDeletion ? nil : note
    }
}

extension SelfTest {
    static func containerKeys() {
        let p = ["com.foo.Bar", "doc.txt"]
        assert(Container.key(path: p, level: 0) == "com.foo.Bar", "app level should be the bundle ID")

        // The no-migration guarantee: identical to the `bundle + "|" + ident` key the app wrote
        // before Container existed. If this fails, every existing app note is orphaned.
        assert(Container.key(path: p, level: 1) == "com.foo.Bar|doc.txt", "key format changed")

        assert(Container.key(path: ["a", "b", "c"], level: 1) == "a|b", "should join a prefix only")
        assert(Container.key(path: ["a", "b", "c"], level: 2) == "a|b|c", "finest should join all")

        let stable = FakeContainer(path: ["app", "old title", "tab-id"], finestKey: "app|tab-id")
        assert(stable.key(at: 0) == "app", "stable tab key must not change coarser levels")
        assert(stable.key(at: 1) == "app|old title", "window level should retain its own identity")
        assert(stable.key(at: 2) == "app|tab-id", "tab key must exclude the mutable title")
        assert(stable.focusKey == "app|tab-id", "focus identity should use the stable tab key")
        let renamed = FakeContainer(path: ["app", "new title", "tab-id"], finestKey: "app|tab-id")
        assert(renamed.focusKey == stable.focusKey, "a title change must not change tab identity")
    }

    static func containerLoadFallback() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2)

        let empty = try! c.load()
        assert(empty == nil, "no note anywhere should not resolve")

        try! c.write(n, at: 1)  // a window-level note
        guard let hit = try! c.load() else {
            assert(false, "a window note should be visible from the tab")
            return
        }
        assert(hit.note == n && hit.level == 1, "should fall back to the window level: \(hit)")

        try! c.write(Note(text: "tab", dx: 3, dy: 4), at: 2)
        let finest = try! c.load()
        assert(finest?.level == 2, "the finest note wins when both exist")
    }

    static func containerPromotion() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2)
        try! c.write(n, at: 2)

        try! c.move(n, from: 2, to: 1)
        let old = try! c.note(at: 2)
        let promoted = try! c.note(at: 1)
        let loaded = try! c.load()
        assert(old == nil, "the old key should be gone after promotion")
        assert(promoted == n, "the note should live at the window level now")
        assert(loaded?.level == 1, "and lookup should find it there")
    }

    static func containerMovePreservesSourceOnFailure() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "safe", dx: 1, dy: 2)
        try! c.write(n, at: 2)
        c.writes = []
        c.failingLevel = 1

        do {
            try c.move(n, from: 2, to: 1)
            assert(false, "a failed destination write must throw")
        } catch {}
        assert(c.writes == [1], "destination must be attempted before source deletion")
        let source = try! c.note(at: 2)
        assert(source == n, "a failed destination write must preserve the source")

        c.writes = []
        c.failingLevel = 2
        do {
            try c.move(n, from: 2, to: 1)
            assert(false, "a failed source deletion must throw")
        } catch {}
        assert(c.writes == [1, 2], "move must write destination, then delete source")
        let duplicatedSource = try! c.note(at: 2)
        let destination = try! c.note(at: 1)
        assert(duplicatedSource == n && destination == n, "failure may duplicate, never lose the note")
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
        try! c.write(n, at: 1)
        guard let hit = try! c.load() else {
            assert(false, "finder note should round-trip")
            return
        }
        assert(hit.note == n && hit.level == 1, "finder round-trip mismatch: \(hit)")

        try! c.write(Note(text: "", dx: 1, dy: 2), at: 1)
        let deleted = try! c.load()
        assert(deleted == nil, "empty text should delete the folder note")
    }

    static func genericKeyMatchesLegacyFormat() {
        // Belt and braces alongside containerKeys(): the generic container's finest key must
        // be exactly what AXWindows.focused built before Container existed.
        let legacy = "com.foo.Bar" + "|" + "Untitled 1"
        assert(
            Container.key(path: ["com.foo.Bar", "Untitled 1"], level: 1) == legacy,
            "generic key drifted from the legacy format — existing notes would orphan")
    }

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

    static func markdownSpans() {
        func styles(_ s: String) -> [Markdown.Style] { Markdown.spans(in: s).map(\.style) }

        // Content excludes the markers, and both marker runs are reported so they can be dimmed.
        let b = Markdown.spans(in: "a **milk** b")
        assert(b.count == 1 && b[0].style == .inline(.bold), "one bold span expected: \(b)")
        assert(b[0].content == NSRange(location: 4, length: 4), "content should be 'milk': \(b[0])")
        assert(
            b[0].markers == [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)],
            "markers should be the two '**': \(b[0])")

        // The lookaround guard: the inner '*' of '**' must not read as italic.
        assert(
            styles("**bold**") == [.inline(.bold)],
            "italic fired inside bold: \(styles("**bold**"))")
        assert(styles("*it*") == [.inline(.italic)], "italic")
        assert(styles("_it_") == [.inline(.italic)], "underscore italic")
        assert(styles("snake_case_here").isEmpty, "underscores inside a word are not italic")

        // First claim wins, and code claims first.
        assert(
            styles("`**x**`") == [.inline(.code)],
            "code should claim its span: \(styles("`**x**`"))")

        let h = Markdown.spans(in: "## Shopping")
        assert(h.count == 1 && h[0].style == .heading(2), "should be an h2: \(h)")
        assert(
            h[0].content == NSRange(location: 3, length: 8), "content should be 'Shopping': \(h[0])")
        assert(styles("# a") == [.heading(1)] && styles("### a") == [.heading(3)], "levels 1 and 3")
        assert(styles("#### a").isEmpty, "four hashes is not a heading we style")

        // A todo line must never also read as a bullet.
        assert(styles("- [ ] pay rent") == [.todo(done: false)], "unticked: \(styles("- [ ] pay rent"))")
        assert(styles("- [x] pay rent") == [.todo(done: true)], "ticked")
        assert(styles("- [X] pay rent") == [.todo(done: true)], "uppercase X ticks too")
        assert(styles("- milk") == [.bullet], "plain bullet")

        assert(styles("~~gone~~") == [.inline(.strike)], "strike")
        assert(styles("just text").isEmpty, "plain text has no spans — the no-migration case")
        assert(styles("**foo").isEmpty, "unterminated bold is not a span")

        // Line rules are reported before inline ones, so styling composes rather than flattens.
        assert(
            styles("- **milk** 2L") == [.bullet, .inline(.bold)],
            "bullet then bold: \(styles("- **milk** 2L"))")
        assert(styles("# Shopping\n- milk") == [.heading(1), .bullet], "line rules match per line")
    }

    static func markdownInlineClosing() {
        // The autoformat trigger: a pattern is consumed only when its closing marker is under the
        // caret, so typing the final delimiter is what fires it.
        let b = Markdown.inlineClosingAt(8, in: "**bold**")
        assert(b?.style == .bold && b?.range == NSRange(location: 0, length: 8), "bold closes at 8")
        assert(Markdown.inlineClosingAt(5, in: "**bold**") == nil, "no completion mid-span")

        let c = Markdown.inlineClosingAt(3, in: "`x`")
        assert(c?.style == .code && c?.range == NSRange(location: 0, length: 3), "code closes at 3")

        assert(Markdown.inlineClosingAt(3, in: "*i* z")?.style == .italic, "italic closes at its '*'")
        assert(Markdown.inlineClosingAt(5, in: "*i* z") == nil, "caret past the span doesn't fire")
    }

    static func markdownParse() {
        func font(_ a: NSAttributedString, _ i: Int) -> NSFont? {
            a.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        }
        func isBold(_ f: NSFont?) -> Bool {
            f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        }

        // Inline markers are consumed into an attribute; the asterisks are gone from the string.
        let bold = MarkdownDocument.parse("**milk**")
        assert(bold.string == "milk", "the ** should be gone: \(bold.string.debugDescription)")
        assert(
            (bold.attribute(.tackInline, at: 0, effectiveRange: nil) as? String) == "bold"
                && isBold(font(bold, 0)), "content should be marked and rendered bold")

        // '#' is consumed too; the line carries a heading level and heading font.
        let h = MarkdownDocument.parse("# Title")
        assert(h.string == "Title", "the '# ' should be gone: \(h.string.debugDescription)")
        assert((h.attribute(.tackHeading, at: 0, effectiveRange: nil) as? Int) == 1, "h1 level")
        assert(font(h, 0)?.pointSize == 18, "h1 should be 18pt")

        // Heading + bold compose: bold inside a heading stays heading-sized.
        let hb = MarkdownDocument.parse("# **Big**")
        assert(hb.string == "Big", "both markers gone: \(hb.string.debugDescription)")
        assert(font(hb, 0)?.pointSize == 18 && isBold(font(hb, 0)), "heading-sized and bold")

        // List syntax becomes a semantic image attachment plus a space, so content starts at 2.
        let bullet = MarkdownDocument.parse("- milk")
        assert(bullet.string == "\u{FFFC} milk", "bullet should become an attachment")
        assert(ListGlyph.at(bullet, 0) == .bullet, "bullet attachment should retain its meaning")

        let open = MarkdownDocument.parse("- [ ] task")
        assert(open.string == "\u{FFFC} task", "open todo should become an attachment")
        assert(ListGlyph.at(open, 0) == .todoOpen, "open todo attachment should retain its meaning")
        assert(open.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) == nil, "open todo not struck")

        let done = MarkdownDocument.parse("- [x] done")
        assert(done.string == "\u{FFFC} done", "done todo should become an attachment")
        assert(ListGlyph.at(done, 0) == .todoDone, "done todo attachment should retain its meaning")
        assert(
            done.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) != nil,
            "a done todo strikes its content")
        let attachment = done.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        assert(attachment?.image?.size == NSSize(width: 14, height: 14), "marker image should be crisp at 14pt")
    }

    static func markdownListEditing() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "- "
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        assert(MarkdownInput.listRule(tv), "typing '- ' should create a bullet")
        guard let ts = tv.textStorage else {
            assert(false, "text view needs storage")
            return
        }
        assert(ListGlyph.at(ts, 0) == .bullet, "live bullet should be an attachment")

        ts.append(NSAttributedString(string: "milk", attributes: MarkdownStyle.base))
        tv.setSelectedRange(NSRange(location: ts.length, length: 0))
        assert(
            MarkdownInput.handle(#selector(NSStandardKeyBindingResponding.insertNewline(_:)), tv),
            "Enter should continue a bullet list")
        assert(ListGlyph.at(ts, 7) == .bullet, "continued list should use a bullet attachment")
        assert(MarkdownDocument.serialize(ts) == "- milk\n- ", "live bullet list should serialize")
    }

    static func markdownRoundTrip() {
        // The backward-compat guarantee: a note saved as markdown must survive parse -> serialize
        // unchanged, so .tack.json stays markdown and pre-Notion notes keep working.
        let corpus = [
            "**bold**", "*italic*", "`code`", "~~strike~~",
            "# Heading", "## Two", "### Three",
            "- item", "- [ ] task", "- [x] done",
            "# **Big**", "- **milk** 2L",
            "plain text",
            "# Title\nsome **bold** here\n- a\n- b",
            "",
        ]
        // Every face, because switching one re-parses the buffer through this round trip: what a
        // note is set in must never reach the file.
        for family in NoteFont.allCases {
            MarkdownStyle.family = family
            for md in corpus {
                let round = MarkdownDocument.serialize(MarkdownDocument.parse(md))
                assert(
                    round == md,
                    "round-trip in \(family) changed \(md.debugDescription) -> \(round.debugDescription)")
            }
        }
        MarkdownStyle.family = .sans
    }

    static func fontFaces() {
        assert(NoteFont(rawValue: "wat") == nil, "an unknown face falls back to the default")
        // Distinct faces, or the font picker would offer three identical choices.
        let faces = Set(NoteFont.allCases.map { $0.font(ofSize: 14).fontName })
        assert(faces.count == NoteFont.allCases.count, "the three faces should differ: \(faces)")
        // Hovering a choice opens the dot into the whole word, so the word has to be the wider of
        // the two — and the dot itself has to stay a circle, whatever the face measures.
        for face in NoteFont.allCases {
            let dot = face.dotImage(size: 16).size
            let word = face.wordImage(height: 16).size
            assert(dot.width == dot.height, "\(face)'s dot should stay a circle: \(dot)")
            assert(word.width > dot.width, "\(face) should widen to spell Tack: \(word)")
            assert(word.height == dot.height, "\(face) should only widen, not grow taller")
        }
    }

    /// The pill's two shapes: a circle at rest, wider when hovered, and never wider than the
    /// narrowest note it has to sit in.
    static func pillGeometry() {
        let closed = NotePill.pillClosedSize
        assert(closed.width == closed.height, "closed, the pill should be a circle: \(closed)")
        let open = NotePill.pillOpenSize
        assert(open.width > closed.width, "hovering should widen the pill")
        assert(open.height == closed.height, "only the width moves, so the corner radius holds")
        assert(
            open.width + NotePill.pillInset * 2 <= NotePreferences.shared.minSize.width,
            "the open pill should fit the smallest note: \(open.width)")

        // The picker's strip is cut to what the note can hold — inverting pillSize, so the two
        // can't drift apart. One dot is the floor: a picker with nothing in it is a dead end.
        assert(NotePill.pillDots(fitting: 10) == 1, "a hopeless width should still offer one dot")
        for width in [100.0, 160.0, 220.0, 400.0] as [CGFloat] {
            let n = NotePill.pillDots(fitting: width)
            let fits = NotePill.pillSize(dots: n).width + NotePill.pillInset * 2 <= width
            assert(fits, "\(n) dots should fit a \(width)pt note")
            assert(
                NotePill.pillSize(dots: n + 1).width + NotePill.pillInset * 2 > width,
                "\(n) dots is short of what fits a \(width)pt note")
        }
        assert(
            NotePill.pillDots(fitting: NotePreferences.shared.defaultSize.width)
                >= NotePreferences.shared.palette.count,
            "the preset palette should fit a default-sized note")
    }

    /// Blocks own their style: anywhere inside a heading block reports that heading, including its
    /// very start, where the caret's neighbour is the previous block's newline.
    static func blockStyleAtCaret() {
        let doc = MarkdownDocument.parse("# Title\nbody\n## Two")
        let start = (doc.string as NSString).range(of: "Title").location
        assert(MarkdownInput.blockHeading(doc, at: start) == 1, "block start should still be H1")
        assert(MarkdownInput.blockHeading(doc, at: start + 3) == 1, "mid-block should be H1")
        let body = (doc.string as NSString).range(of: "body").location
        assert(MarkdownInput.blockHeading(doc, at: body) == nil, "a body block has no heading")
        assert(
            MarkdownInput.blockHeading(doc, at: (doc.string as NSString).range(of: "Two").location) == 2,
            "the last block should be H2")
        // An empty block carries no mark, so there is nothing to report.
        let blank = MarkdownDocument.parse("a\n\nb")
        assert(MarkdownInput.blockHeading(blank, at: 2) == nil, "an empty block reports no heading")
    }

    /// Block mode's walk: Esc selects the caret's block, ↑/↓ step, Enter re-enters at its end.
    static func blockNavigation() {
        let text = "# Title\nbody\n\nlast" as NSString
        let first = Blocks.range(in: text, at: 3)
        assert(text.substring(with: first) == "# Title\n", "the caret's block is its paragraph")
        assert(Blocks.step(from: first, by: -1, in: text) == nil, "nothing above the first block")

        let second = Blocks.step(from: first, by: 1, in: text)!
        assert(text.substring(with: second) == "body\n", "↓ should step to the next block")
        assert(Blocks.step(from: second, by: -1, in: text) == first, "↑ should step back")

        let blank = Blocks.step(from: second, by: 1, in: text)!
        assert(text.substring(with: blank) == "\n", "an empty block is a block")
        let last = Blocks.step(from: blank, by: 1, in: text)!
        assert(Blocks.step(from: last, by: 1, in: text) == nil, "nothing below the last block")

        // Enter drops in after the text, never after the newline (that is the next block).
        assert(Blocks.contentEnd(first, in: text) == 7, "caret lands at the end of the block's text")
        assert(Blocks.contentEnd(last, in: text) == text.length, "a block without a newline ends at its end")
    }

    /// Backspace on an empty last block used to read an attribute one past the end of the text and
    /// take the app down with it. Nothing to handle here — it falls through to the text view.
    static func backspaceAtTheEnd() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.textStorage?.setAttributedString(MarkdownDocument.parse("a\n"))
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let handled = MarkdownInput.handle(
            #selector(NSStandardKeyBindingResponding.deleteBackward(_:)), tv)
        assert(!handled, "backspace on an empty last block is the text view's own deletion")
    }

    static func noteSizeIsOptional() {
        // The no-migration guarantee, same shape as the key-format one: a note written before
        // resizing existed must still decode, and say nothing about its size rather than 0x0.
        let old = #"{"text":"hi","dx":12,"dy":34}"#.data(using: .utf8)!
        guard let n = try? JSONDecoder().decode(Note.self, from: old) else {
            assert(false, "a pre-resize note should still decode")
            return
        }
        assert(n.w == nil && n.h == nil, "a missing size should decode as nil, not zero: \(n)")
        assert(n.font == nil, "a pre-font note should say nothing about its face: \(n)")
        assert(n.text == "hi" && n.dx == 12, "the rest of the note should survive: \(n)")

        let sized = Note(text: "hi", dx: 1, dy: 2, color: nil, w: 300, h: 240)
        let data = try! JSONEncoder().encode(sized)
        assert(try! JSONDecoder().decode(Note.self, from: data) == sized, "size should round-trip")
    }


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
