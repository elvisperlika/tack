import AppKit

/// Owns the app's lifecycle and the two loops that decide which note is on screen
/// and where. Menu construction lives in AppMenus.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let note = NoteWindow()
    private var statusItem: NSStatusItem?
    /// The Tack window — every note at once. Nil until it is first opened, so a session that
    /// never opens it never builds a window.
    private(set) var grid: NoteGrid?
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackLink: CADisplayLink? {  // vsync glue: the shown note follows its window
        didSet { oldValue?.invalidate() }  // an outlived link would keep firing
    }
    private var lastPersistenceError: String?

    var current: Container?

    /// The storage key of the note on screen. A closure, not a string: a pin change moves the
    /// note to another level, and the key has to move with it.
    private var shownKey: (() -> String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
        installEditMenu()
        note.onDelete = { [weak self] in self?.stopTracking() }
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        note.flushPendingSave() && (grid?.flush() ?? true) ? .terminateNow : .terminateCancel
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

    private func pollTarget() {
        guard let container = resolve() else {
            hideNote()
            current = nil
            return
        }
        // Container is a class, so compare its stable focus key rather than object identity.
        // Browser titles and Terminal titles may change without the actual tab changing.
        // an unchanged surface must cost nothing per poll, and must never hide a showing note.
        guard container.focusKey != current?.focusKey else { return }
        // Don't latch a surface we can't place the note on — leaving `current` nil means the
        // next poll retries, rather than stranding the note hidden until the user focuses away.
        guard let f = container.frame() else {
            hideNote()
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
                guard showNote(hit.note, frame: f, container: container, level: hit.level) else {
                    return
                }
            } else {
                hideNote()
            }
            current = container
            lastPersistenceError = nil
        } catch {
            hideNote()
            reportPersistenceError(error)
        }
    }

    @objc private func trackTarget() {
        guard let f = current?.frame() else { return }
        apply(f)
    }

    /// The one place the note follows its window. Containers that can't be covered report no
    /// occluders, so the same two lines serve Finder and app windows alike.
    private func apply(_ f: Frame) {
        note.updateWindow(bounds: f.bounds)
        note.setOccluded(f.covering.contains { $0.intersects(note.screenRectTopLeft()) })
    }

    /// Glue the shown note to its window, sampled in sync with the display's own refresh — the
    /// full rate on 120Hz ProMotion, where a fixed 60fps timer updates at half the window's rate
    /// and visibly stutters. Polling, not AX move events, is what keeps the note locked during a
    /// live drag: the OS coalesces AXWindowMoved notifications, so an event-driven note trails.
    private func startTracking() {
        let link = note.makeDisplayLink(target: self, selector: #selector(trackTarget))
        link.add(to: .main, forMode: .common)
        trackLink = link
    }

    // MARK: - Show / hide

    @discardableResult
    func showNote(_ n: Note, frame f: Frame, container: Container, level: Int) -> Bool {
        let box = LevelBox(level)  // this note's own level cell — see LevelBox
        let shown = note.show(note: n, bounds: f.bounds) { [weak self] edited in
            self?.persist { try container.write(edited, at: box.value) } ?? false
        }
        guard shown else { return false }
        // Only an open dashboard cares, and only it knows this note by its storage key.
        note.onLiveEdit = { [weak self] edited in
            self?.grid?.update(key: container.key(at: box.value), note: edited)
        }
        shownKey = { container.key(at: box.value) }
        let choices = (container.minLevel...container.finestLevel).map {
            (level: $0, label: LevelName.label(level: $0, of: container.path.count))
        }
        note.setPinLevels(choices, current: level) { [weak self] newLevel in
            guard let self = self else { return false }
            let moved = self.persist {
                guard let hit = try container.load() else { return }
                try container.move(hit.note, from: hit.level, to: newLevel)
            }
            guard moved else { return false }
            box.value = newLevel  // redirect this note's later edits — same cell the save closure reads
            return true
        }
        apply(f)
        startTracking()
        return true
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
            guard let self, shownKey?() == key else { return }  // a different note: nothing on screen
            if edited.isDeletion { hideNote() } else { note.applyLive(edited) }
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

    private func hideNote() {
        note.hide()
        shownKey = nil
        stopTracking()
    }

    private func stopTracking() {
        trackLink = nil  // didSet invalidates it on the way out
    }
}
