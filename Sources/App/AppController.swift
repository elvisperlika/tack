import AppKit

/// One app's note on screen: the window showing it and the surface it is glued to. Each app
/// gets its own, so the note on an app you have clicked away from stays where it is.
final class ShownNote {
    let window = NoteWindow()  // reused for every note this app shows
    /// The surface the note follows; nil while this app has no note up.
    var container: Container?
    var level = LevelBox(0)  // see LevelBox
    var lastBounds: CGRect?  // where the tracked window was at the last sample
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
    /// The Tack window — every note at once. Nil until it is first opened, so a session that
    /// never opens it never builds a window.
    private(set) var grid: NoteGrid?
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
        }
        pollTimer?.tolerance = 0.1  // lets macOS line this wake-up up with others

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
        let gridSaved = grid?.flush() ?? true
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
        note.show(note: n, bounds: f.bounds) { [weak self] edited in
            self?.persist { try container.write(edited, at: box.value) } ?? false
        }
        // Only an open dashboard cares, and only it knows this note by its storage key.
        note.onLiveEdit = { [weak self] edited in
            self?.grid?.update(key: container.key(at: box.value), note: edited)
        }
        note.onDelete = { [weak entry] in entry?.container = nil }  // nothing left to follow
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
            self.grid?.reload()
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

    /// Builds the Tack window the first time it is asked for, and shows it.
    func openGrid() {
        let window = grid ?? NoteGrid { [weak self] error in self?.reportPersistenceError(error) }
        window.onLiveEdit = { [weak self] key, edited in
            // A note that isn't on screen has nothing to keep in step.
            guard let self, let entry = notes.values.first(where: { $0.key == key }) else { return }
            if edited.isDeletion { hide(entry) } else { entry.window.applyLive(edited) }
        }
        grid = window
        window.open()
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
