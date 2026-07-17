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
    /// How the shown note follows its window. One value instead of a timer optional plus a
    /// tracker optional, so "both running at once" is not a state that can exist.
    private enum Tracking {
        case none
        case events(AnyObject)  // the container pushes moves itself (AXObserver)
        case polling(Timer)  // 60fps fallback for containers that can't (Finder)
    }

    private let note = NoteWindow()
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var tracking: Tracking = .none {
        didSet {  // a timer outliving its slot in the enum would tick forever
            if case .polling(let old) = oldValue { old.invalidate() }
        }
    }

    private var current: Container?
    private var currentBox: LevelBox?  // the level cell the shown note's save closure captures

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "📌"
        statusItem = item  // retained here; the bar only keeps a weak hold

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Add note here", action: #selector(addNote), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self  // pin items are rebuilt per open, from the live path
        item.menu = menu

        installEditMenu()
        note.onDelete = { [weak self] in self?.stopTracking() }
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
    }

    /// ⌘C/⌘V/⌘Z only reach a text view through the main menu's key equivalents. An agent app has
    /// no menu bar to show a menu in, but NSApp still dispatches through `mainMenu` — so this
    /// invisible Edit menu is the whole reason copy, paste and undo work inside a note.
    private func installEditMenu() {
        let edit = NSMenu()
        let items: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),  // capital Z is ⌘⇧Z
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        // Target stays nil on purpose: each one walks the responder chain to whatever text view
        // is focused, which is exactly the note being edited.
        items.forEach { edit.addItem(NSMenuItem(title: $0, action: $1, keyEquivalent: $2)) }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
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
        // ponytail: opt-in path logging for diagnosing identity. Enable with
        //   defaults write com.tack.app debugPaths -bool YES
        // then watch with: log stream --predicate 'process == "Tack"'
        if UserDefaults.standard.bool(forKey: "debugPaths") {
            NSLog("[tack] path=%@", container.path.joined(separator: " / "))
        }
        if let hit = container.load() {
            showNote(hit.note, frame: f, container: container, level: hit.level)
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
        tracking = .none  // release the old observer before creating the next one
        if let tracker = container.tracker(onMove: { [weak self] f in self?.apply(f) }) {
            tracking = .events(tracker)
        } else {
            tracking = .polling(
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
                    [weak self] _ in
                    self?.trackTarget()
                })
        }
    }

    // MARK: - Show / hide

    private func showNote(_ n: Note, frame f: Frame, container: Container, level: Int) {
        let box = LevelBox(level)  // this note's own level cell — see LevelBox
        currentBox = box
        note.show(note: n, bounds: f.bounds) { edited in container.write(edited, at: box.value) }
        apply(f)
        startTracking(container)
    }

    private func hideNote() {
        note.hide()
        currentBox = nil  // the hidden note's level cell must not outlive it
        stopTracking()
    }

    private func stopTracking() {
        tracking = .none  // didSet invalidates a polling timer on the way out
    }

    // MARK: - Menu

    @objc private func addNote() {
        guard let container = resolve(), let f = container.frame() else { return }
        current = container
        let hit = container.load()
        showNote(
            hit?.note ?? Note(text: "", dx: 20, dy: 40), frame: f, container: container,
            level: hit?.level ?? container.finestLevel)  // finest available, promote later
        NSApp.activate(ignoringOtherApps: true)
        note.focusForEditing()
    }

    /// Move the current note to a coarser (or finer) level. Delete-then-write, so the note
    /// never exists at two keys at once.
    @objc private func pin(_ sender: NSMenuItem) {
        guard let container = current, let hit = container.load() else { return }
        container.move(hit.note, from: hit.level, to: sender.tag)
        currentBox?.value = sender.tag  // redirect this note's later edits to the new level
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The pin items depend on whatever is focused *right now*, so they're rebuilt each time the
/// menu opens rather than stored.
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag != 0 || $0.action == #selector(pin(_:)) }
            .forEach(menu.removeItem)

        guard let container = current, let hit = container.load(),
            container.finestLevel > container.minLevel  // nothing to choose between
        else { return }

        var index = 1  // just after "Add note here"
        for level in container.minLevel...container.finestLevel {
            let item = NSMenuItem(
                title: LevelName.label(level: level, of: container.path.count),
                action: #selector(pin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = level == hit.level ? .on : .off
            menu.insertItem(item, at: index)
            index += 1
        }
    }
}
