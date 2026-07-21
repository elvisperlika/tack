import AppKit
import Foundation

/// `swift run swift-executable --selftest` — the runnable checks for the non-trivial logic.
enum SelfTest {
    static func run() {
        noteStoreRoundTrip()
        appNotesRoundTrip()
        coordFlip()
        fitToWindow()
        clampToWindow()
        colorHexRoundTrip()
        containerKeys()
        containerLoadFallback()
        containerPromotion()
        finderContainerRoundTrip()
        genericKeyMatchesLegacyFormat()
        levelLabels()
        debouncerCollapses()
        markdownSpans()
        markdownParse()
        markdownRoundTrip()
        markdownInlineClosing()
        markdownTodoBox()
        noteSizeIsOptional()
        urlNormalization()
        notePreferencesPalette()
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
        d.call { hits.append(1) }
        d.call { hits.append(2) }  // must cancel the first
        // Spinning the main run loop drains the main dispatch queue in a CLI process.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assert(hits == [2], "only the last scheduled block should fire: \(hits)")
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
final class FakeContainer: Container {
    private var storage: [String: Note] = [:]
    private let ident: [String]

    init(path: [String]) { self.ident = path }

    override var path: [String] { ident }
    override func note(at level: Int) -> Note? { storage[key(at: level)] }
    override func write(_ note: Note, at level: Int) {
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
        assert(b.count == 1 && b[0].style == .bold, "one bold span expected: \(b)")
        assert(b[0].content == NSRange(location: 4, length: 4), "content should be 'milk': \(b[0])")
        assert(
            b[0].markers == [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)],
            "markers should be the two '**': \(b[0])")

        // The lookaround guard: the inner '*' of '**' must not read as italic.
        assert(styles("**bold**") == [.bold], "italic fired inside bold: \(styles("**bold**"))")
        assert(styles("*it*") == [.italic], "italic")
        assert(styles("_it_") == [.italic], "underscore italic")
        assert(styles("snake_case_here").isEmpty, "underscores inside a word are not italic")

        // First claim wins, and code claims first.
        assert(styles("`**x**`") == [.code], "code should claim its span: \(styles("`**x**`"))")

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

        assert(styles("~~gone~~") == [.strike], "strike")
        assert(styles("just text").isEmpty, "plain text has no spans — the no-migration case")
        assert(styles("**foo").isEmpty, "unterminated bold is not a span")

        // Line rules are reported before inline ones, so styling composes rather than flattens.
        assert(styles("- **milk** 2L") == [.bullet, .bold], "bullet then bold: \(styles("- **milk** 2L"))")
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

        // Bullets keep their literal marker (Phase 1); the dash is dimmed, not removed.
        let bullet = MarkdownDocument.parse("- milk")
        assert(bullet.string == "- milk", "bullet marker stays literal: \(bullet.string.debugDescription)")
        assert(
            (bullet.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == MarkdownStyle.dim,
            "the '- ' should be dimmed")
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
        for md in corpus {
            let round = MarkdownDocument.serialize(MarkdownDocument.parse(md))
            assert(round == md, "round-trip changed \(md.debugDescription) -> \(round.debugDescription)")
        }
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
        assert(n.text == "hi" && n.dx == 12, "the rest of the note should survive: \(n)")

        let sized = Note(text: "hi", dx: 1, dy: 2, color: nil, w: 300, h: 240)
        let data = try! JSONEncoder().encode(sized)
        assert(try! JSONDecoder().decode(Note.self, from: data) == sized, "size should round-trip")
    }

    static func markdownTodoBox() {
        // "- [ ] pay rent" — 0:'-' 1:' ' 2:'[' 3:' ' 4:']', so the box is {2,3}.
        let s = "- [ ] pay rent"
        let box = NSRange(location: 2, length: 3)
        assert(Markdown.todoBox(in: s, at: 2) == box, "the '[' should hit")
        assert(Markdown.todoBox(in: s, at: 3) == box, "the middle should hit")
        assert(Markdown.todoBox(in: s, at: 10) == nil, "a click on the text should miss")
        assert(Markdown.todoBox(in: "- milk", at: 2) == nil, "a plain bullet has no box")
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
