import AppKit

/// Owns the app's lifecycle and the two loops that decide which note is on screen
/// and where. Menu construction lives in AppMenus.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let note = NoteWindow()
    private var statusItem: NSStatusItem?
    /// The Tack window, built lazily on first open. Empty placeholder for now.
    lazy var mainWindow: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.setFrameAutosaveName("tackMain")
        w.center()
        w.isReleasedWhenClosed = false
        return w
    }()
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackLink: CADisplayLink? {  // vsync glue: the shown note follows its window
        didSet { oldValue?.invalidate() }  // an outlived link would keep firing
    }
    private var lastPersistenceError: String?

    var current: Container?

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
        note.flushPendingSave() ? .terminateNow : .terminateCancel
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
        let choices = (container.minLevel...container.finestLevel).map {
            (level: $0, label: LevelName.label(level: $0, of: container.path.count))
        }
        note.setPinLevels(choices, current: level) { [weak self] newLevel in
            guard let self else { return false }
            let moved = persist {
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
        stopTracking()
    }

    private func stopTracking() {
        trackLink = nil  // didSet invalidates it on the way out
    }
}
