import AppKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar agent, no dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let note = NoteWindow()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackTimer: Timer?  // fast: glue the note to the window (60fps), only when
    private var tracker: AnyObject?  // the container can't push moves itself

    private var current: Container?
    private var currentLevel = 0  // the level the shown note was found at — edits save back here

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📌"

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Add note here", action: #selector(addNote), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        note.onDelete = { [weak self] in self?.stopTracking() }
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
    }

    // MARK: - Target resolution

    /// The surface the user is focused on right now (or `current` while we're editing our own
    /// note, which would otherwise resolve to Tack itself).
    private func resolve() -> Container? {
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
        // Container is a class, so identity is the path, not the object. This guard comes first:
        // an unchanged surface must cost nothing per poll, and must never hide a showing note.
        guard container.path != current?.path else { return }
        // Don't latch a surface we can't place the note on — leaving `current` nil means the
        // next poll retries, rather than stranding the note hidden until the user focuses away.
        guard let f = container.frame() else {
            hideNote()
            current = nil
            return
        }
        current = container
        if let hit = container.load() {
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
        tracker = nil  // release the old observer before creating the next one
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

    @objc private func quit() { NSApp.terminate(nil) }
}
