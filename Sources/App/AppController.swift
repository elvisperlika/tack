import AppKit

/// One app's note on screen: the window showing it and the surface it is glued to. Each app
/// gets its own, so the note on an app you have clicked away from stays where it is.
final class ShownNote {
    let window = NoteWindow()  // reused for every note this app shows
    /// The surface the note follows; nil while this app has no note up.
    var container: Container?
    var level = LevelBox(0)  // see LevelBox
    var lastBounds: CGRect?  // where the tracked window was at the last sample
    /// The note as Tack last read or wrote it — what a save compares the file against, so it
    /// never writes over a newer one (see Note.merge).
    var seen: Note?
    var stillFrames = 0  // samples since it last moved — see samples(stillFrames:)

    /// The storage key of the note on screen. Computed: a pin change moves the note to another
    /// level, and the key has to move with it.
    var key: String? { container.map { $0.key(at: level.value) } }
}

/// Owns the app's lifecycle and the two loops that decide which notes are on screen
/// and where. Menu construction lives in AppMenus.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The notes on screen, one per app, keyed by `Container.app`. An entry outlives its note
    /// (its window is reused), so "showing" is `container != nil`, not membership.
    private(set) var notes: [String: ShownNote] = [:]
    private var statusItem: NSStatusItem?
    let updater = Updater()
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackLink: CADisplayLink? {  // vsync glue: each shown note follows its window
        didSet { oldValue?.invalidate() }  // an outlived link would keep firing
    }
    private var lastPersistenceError: String?

    /// The focused surface, as of the last poll.
    var current: Container?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
        installEditMenu()
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows
        AXWindows.limitWaiting()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
            self?.syncFromDisk()
        }
        pollTimer?.tolerance = 0.1  // lets macOS line this wake-up up with others
        updater.start()

        // A note outlives its app's focus now, so nothing else would ever take it down when the
        // app quits: its window just vanishes from the list and the note would wait for it forever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.hideNote(app: id) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Everything is flushed before anything is judged: `&&` would skip the rest after a failure.
        let notesSaved = notes.values.map { $0.window.flushPendingSave() }.allSatisfy { $0 }
        let gridSaved = grid.flush()
        if notesSaved && gridSaved { return .terminateNow }
        // Refusing outright made Quit a dead button for as long as the save kept failing.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some edits could not be saved"
        alert.informativeText = "Quitting now loses them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Target resolution

    /// The surface the user is focused on right now (or `current` while we're editing our own
    /// note, which would otherwise resolve to Tack itself).
    func resolve() -> Container? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return current }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return current }
        return Container.resolve(front: front)
    }

    // MARK: - Loops

    /// Decides what the *focused* app shows. Only that app's note is ever changed here: the
    /// notes of every other app stay up, following their own windows.
    private func pollTarget() {
        // The note that is the dashboard keeps its app's slot until it turns back into a note:
        // re-showing or hiding that slot meanwhile would yank the dashboard away.
        if let host = dashboardNote,
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            notes[front]?.window === host
        {
            return
        }
        guard let container = resolve() else {
            // Nothing to pin to in front (no window, no folder): that app's note goes.
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                hideNote(app: front)
            }
            current = nil
            return
        }
        // Back on a surface whose note never left the screen: nothing to load or re-show. The
        // fresh container replaces the old one, though — it carries the window to follow, which
        // differs when the same folder or document is open in a second window.
        if let entry = notes[container.app], entry.container?.focusKey == container.focusKey {
            entry.container = container
            current = container
            return
        }
        // Container is a class, so compare its stable focus key rather than object identity.
        // Browser titles and Terminal titles may change without the actual tab changing.
        // an unchanged surface must cost nothing per poll, and must never hide a showing note.
        guard container.focusKey != current?.focusKey else { return }
        // Don't latch a surface we can't place the note on — leaving `current` nil means the
        // next poll retries, rather than stranding the note hidden until the user focuses away.
        guard let f = container.frame() else {
            hideNote(app: container.app)
            current = nil
            return
        }
        // ponytail: opt-in path logging for diagnosing identity. Enable with
        //   defaults write com.tack.app debugPaths -bool YES
        // then watch with: log stream --predicate 'process == "Tack"'
        if UserDefaults.standard.bool(forKey: "debugPaths") {
            NSLog("[tack] path=%@", container.path.joined(separator: " / "))
        }
        do {
            if let hit = try container.load() {
                showNote(hit.note, frame: f, container: container, level: hit.level)
            } else {
                hideNote(app: container.app)
            }
            current = container
            lastPersistenceError = nil
        } catch {
            hideNote(app: container.app)
            reportPersistenceError(error)
        }
    }

    @objc private func trackNotes() {
        var showing = false
        for entry in notes.values {
            guard let container = entry.container else { continue }
            showing = true
            entry.stillFrames += 1
            guard Self.samples(stillFrames: entry.stillFrames) else { continue }
            // No window to follow — minimised, hidden, on another Space. The note waits out of
            // sight and comes back with the window; only a new focus or a quit takes it down.
            guard let f = container.frame() else {
                entry.window.setOccluded(true)
                continue
            }
            if f.bounds != entry.lastBounds {
                entry.lastBounds = f.bounds
                entry.stillFrames = 0
            }
            apply(f, to: entry.window)
        }
        if !showing { trackLink = nil }  // nothing left to follow; showNote starts it again
    }

    /// Whether this frame reads the window list. Every frame while the window is moving; once it
    /// has sat still for 30, one frame in six — the read walks every window on screen, and a
    /// window at rest was paying for it at the full refresh rate.
    /// shortcut: the first frame of a new drag can be up to five frames late (~40ms at 120Hz);
    /// wake on AXWindowMoved instead if that ever shows.
    static func samples(stillFrames: Int) -> Bool { stillFrames < 30 || stillFrames % 6 == 0 }

    /// The one place a note follows its window, and hides while another window covers its spot
    /// — which is what keeps the note of an app in the background from floating over the app
    /// in front of it.
    private func apply(_ f: Frame, to note: NoteWindow) {
        note.updateWindow(bounds: f.bounds)
        let spot = note.screenRectTopLeft()
        note.setOccluded(f.covering.contains { $0.intersects(spot) })
    }

    /// Glue the shown notes to their windows, sampled in sync with the display's own refresh — a
    /// fixed 60fps timer updates at half a 120Hz window's rate and visibly stutters. Polling, not
    /// AX move events, is what keeps a note locked during a live drag: the OS coalesces
    /// AXWindowMoved notifications, so an event-driven note trails.
    ///
    /// The link comes from the screen, not from a note's window: a window's link pauses while
    /// the window is off screen, and a hidden note is exactly the one waiting to be told its
    /// window is back.
    /// shortcut: every note ticks at the main screen's rate, whatever display it is on; give each
    /// note its own screen's link if a mixed-refresh setup shows a stutter.
    private func startTracking() {
        guard trackLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(trackNotes))
        link.add(to: .main, forMode: .common)
        trackLink = link
    }

    // MARK: - Show / hide

    func showNote(_ n: Note, frame f: Frame, container: Container, level: Int) {
        let entry = notes[container.app] ?? ShownNote()
        notes[container.app] = entry
        let box = LevelBox(level)  // this note's own level cell — see LevelBox
        entry.container = container
        entry.level = box
        entry.lastBounds = nil
        entry.stillFrames = 0  // a note just shown tracks at full rate from its first frame
        let note = entry.window
        entry.seen = n
        note.show(note: n, bounds: f.bounds) { [weak self, weak entry] edited in
            guard let self else { return false }
            return persist {
                // Never over a newer file: a script may have rewritten it since — see Note.merge.
                let toWrite = Note.merge(
                    mine: edited, seen: entry?.seen, disk: try container.note(at: box.value))
                try container.write(toWrite, at: box.value)
                entry?.seen = toWrite
                if toWrite != edited { self.cascade(key: container.key(at: box.value), note: toWrite) }
            }
        }
        // Only an open dashboard cares, and only it knows this note by its storage key.
        note.onLiveEdit = { [weak self] edited in
            self?.grid.update(key: container.key(at: box.value), note: edited)
        }
        note.onDelete = { [weak entry] in entry?.container = nil }  // nothing left to follow
        note.onOpenAll = { [weak self, weak note] in
            guard let self, let note else { return }
            openDashboard(from: note)
        }
        let choices = container.pinLevels.map {
            (
                level: $0, label: LevelName.label(level: $0, of: container.path.count),
                symbol: LevelName.symbol(level: $0, of: container.path.count)
            )
        }
        note.setPinLevels(choices, current: level) { [weak self] newLevel in
            guard let self = self else { return false }
            let moved = self.persist {
                guard let hit = try container.load() else { return }
                try container.move(hit.note, from: hit.level, to: newLevel)
            }
            guard moved else { return false }
            box.value = newLevel  // redirect this note's later edits — same cell the save closure reads
            // The dashboard knows a note by its key, and the key just changed: left alone, its
            // cell would write the note back under the old one on the next edit there.
            self.grid.reload()
            return true
        }
        apply(f, to: note)
        startTracking()
    }

    @discardableResult
    func persist(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            lastPersistenceError = nil
            return true
        } catch {
            reportPersistenceError(error)
            return false
        }
    }

    // MARK: - Changes from outside

    /// Modification dates of the note files on screen, as last looked at.
    private var fileDates: [URL: Date?] = [:]

    /// Every poll: has a file behind a note on screen — a floating note, or a card in an open
    /// dashboard — changed since the last look? Then those notes are read again and shown.
    /// A date per file, not a watcher: one stat per file per poll is nothing, it survives the
    /// write-to-a-temp-file-and-rename most tools do, and Finder notes live in many folders.
    private func syncFromDisk() {
        var onScreen = notes.values.compactMap(\.key)
        if dashboardNote != nil { onScreen += grid.keys }
        var keysByFile: [URL: Set<String>] = [:]
        for key in onScreen {
            if let url = StoredNote.fileURL(of: key) { keysByFile[url, default: []].insert(key) }
        }
        // The dashboard also gains notes a script adds to the central store.
        if dashboardNote != nil, let store = AppNotes.storeURL, keysByFile[store] == nil {
            keysByFile[store] = []
        }

        for (url, keys) in keysByFile {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let known = fileDates[url]
            fileDates[url] = date
            guard let known, known != date else { continue }  // first look only records the date
            var changed = keys
            if url == AppNotes.storeURL, dashboardNote != nil, let all = try? AppNotes.all() {
                changed.formUnion(all.keys)
            }
            for key in changed {
                guard let disk = try? StoredNote.load(key: key) else {
                    adoptFromDisk(key: key, note: nil)
                    continue
                }
                adoptFromDisk(key: key, note: disk)
            }
        }
    }

    /// One note changed on disk: the floating note showing it adopts it unless the user is mid-edit
    /// there, and the dashboard follows (`cascade`). nil: the note was deleted there.
    private func adoptFromDisk(key: String, note: Note?) {
        if let entry = notes.values.first(where: { $0.key == key }) {
            if !entry.window.hasPendingEdit {
                if let note {
                    entry.seen = note
                    if entry.window.currentNote != note { entry.window.applyLive(note) }
                } else if Self.deletedElsewhere(seen: entry.seen) {
                    entry.seen = nil
                    hide(entry)
                }
            }
        }
        if dashboardNote != nil { grid.adoptFromDisk(key: key, note: note) }
    }

    /// A note missing from its file was deleted by somebody else only if Tack last knew it with words in it: an empty note is never stored (`Note.isDeletion`), so one dragged before being typed in, or just emptied, is missing because Tack saved it so, and hiding it would pull it from under the caret.
    static func deletedElsewhere(seen: Note?) -> Bool { seen?.isDeletion != true }

    /// Put `note` on every view of it — the floating note and the dashboard's card — because a
    /// save kept words from the file over the ones on screen.
    private func cascade(key: String, note: Note) {
        notes.values.first { $0.key == key }?.window.applyLive(note)
        if dashboardNote != nil { grid.update(key: key, note: note) }
    }

    // MARK: - Dashboard

    /// Every note at once. Built the first time the dashboard opens.
    private(set) lazy var grid: NoteGrid = {
        let grid = NoteGrid { [weak self] error in self?.reportPersistenceError(error) }
        grid.onLiveEdit = { [weak self] key, edited in
            // A note that isn't on screen has nothing to keep in step.
            guard let self, let entry = notes.values.first(where: { $0.key == key }) else { return }
            if edited.isDeletion { hide(entry) } else { entry.window.applyLive(edited) }
        }
        // The dashboard floats over everything: left up, it would hide the app it just brought
        // forward. It turns back into its note, and the poll shows that app's note as usual.
        grid.onReveal = { [weak self] in self?.closeDashboard() }
        grid.onChange = { [weak self] in
            guard let self, let host = dashboardNote else { return }
            host.setDashboardColors(self.grid.colors)
        }
        return grid
    }()

    /// The note that is the dashboard right now, if one is.
    private weak var dashboardNote: NoteWindow?
    /// The dashboard's other page, built the first time it is asked for.
    private lazy var settingsPage = SettingsView()
    private var onSettingsPage = false

    /// Becomes the dashboard when it is opened from the menu bar with no note on screen to grow.
    private lazy var looseNote = NoteWindow()

    /// `note` becomes the dashboard — or, from the menu bar, the note of the app in front, or a
    /// bare card when that app shows none. A dashboard already up just comes forward.
    func openDashboard(from note: NoteWindow?) {
        if let current = dashboardNote, current.isExpanded {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        notes.values.forEach { $0.window.flushPendingSave() }  // the grid is about to read disk
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let host = note ?? notes[front].flatMap { $0.container == nil ? nil : $0.window } ?? looseNote
        grid.reload()
        host.onCollapse = { [weak self] in self?.closeDashboard() }
        host.onDashboardPress = { [weak self] in self?.grid.unfocus() }
        host.onSettings = { [weak self, weak host] in
            guard let self, let host else { return }
            onSettingsPage.toggle()
            host.showPage(onSettingsPage ? settingsPage : grid.view, settings: onSettingsPage)
        }
        onSettingsPage = false
        host.expand(showing: grid.view, to: dashboardFrame(near: host.frame), color: Self.dashboardColor)
        dashboardNote = host
        host.setDashboardColors(grid.colors)
    }

    func closeDashboard() {
        guard let host = dashboardNote else { return }
        grid.flush()
        UserDefaults.standard.set(NSStringFromRect(host.frame), forKey: Self.dashboardFrameKey)
        dashboardNote = nil
        host.collapse()
    }

    private static let dashboardFrameKey = "dashboardFrame"

    /// Where the dashboard opens: where it was last left, while that is still on a screen;
    /// otherwise 760×560 in the middle of the screen `near` is on.
    private func dashboardFrame(near: NSRect) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: Self.dashboardFrameKey) {
            let frame = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(near) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(760, area.width - 40), height: min(560, area.height - 40))
        return NSRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// The dashboard's background, solid — what a growing note washes to. Read in the light
    /// appearance the cards are always drawn in, so the two never clash.
    private static var dashboardColor: NSColor {
        var color = NSColor.windowBackgroundColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            color = color.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    func reportPersistenceError(_ error: Error) {
        let message = error.localizedDescription
        guard message != lastPersistenceError else { return }
        lastPersistenceError = message
        NSLog("[tack] persistence error: %@", message)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Tack could not save your note"
        alert.informativeText = message
        alert.runModal()
    }

    /// Take down the note `app` is showing, if any. Every other app's note is left alone.
    private func hideNote(app: String) {
        if let entry = notes[app] { hide(entry) }
    }

    private func hide(_ entry: ShownNote) {
        entry.window.hide()
        entry.container = nil  // the tracker skips it from here on
    }
}
