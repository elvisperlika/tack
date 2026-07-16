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
        app.setActivationPolicy(.accessory) // menu-bar agent, no dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let note = NoteWindow()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?  // slow: which window is focused (~0.4s)
    private var trackTimer: Timer? // fast: glue the note to the Finder window (60fps)
    private var appTracker: AXWindowTracker? // app windows follow via AX notifications, not polling

    /// What a note is bound to.
    private enum Target: Equatable {
        case folder(path: String)          // Finder folder → .tack.json in the folder
        case appWindow(key: String, pid: pid_t) // any other app window → central store
    }
    private var current: Target?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📌"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Add note here", action: #selector(addNote), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        note.onDelete = { [weak self] in self?.stopTracking() }
        AXWindows.promptForPermission() // needed to bind notes to non-Finder app windows

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
    }

    // MARK: - Target resolution

    /// The window the user is focused on right now (or `current` while we're editing our own note).
    private func resolve() -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return current }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return current } // our note is key: keep
        if front.bundleIdentifier == "com.apple.finder" {
            guard let state = FinderWatcher.current() else { return nil }
            return .folder(path: state.path)
        }
        guard let info = AXWindows.focused(of: front) else { return nil }
        return .appWindow(key: info.key, pid: front.processIdentifier)
    }

    private func bounds(for target: Target) -> CGRect? {
        switch target {
        case .folder: return FinderWatcher.frontFinderWindow()?.bounds
        case .appWindow(_, let pid): return AXWindows.focusedBounds(pid: pid)
        }
    }

    private func load(_ target: Target) -> Note? {
        switch target {
        case .folder(let path): return NoteStore.load(folder: path)
        case .appWindow(let key, _): return AppNotes.load(key: key)
        }
    }

    private func saver(for target: Target) -> (Note) -> Void {
        switch target {
        case .folder(let path): return { NoteStore.save(folder: path, note: $0) }
        case .appWindow(let key, _): return { AppNotes.save(key: key, note: $0) }
        }
    }

    // MARK: - Loops

    private func pollTarget() {
        guard let target = resolve() else { hideNote(); current = nil; return }
        guard target != current else { return }
        current = target
        if let n = load(target), let b = bounds(for: target) {
            showNote(n, bounds: b, save: saver(for: target))
            startAppTracking(target)
        } else {
            hideNote()
        }
    }

    private func trackTarget() {
        guard let target = current else { return }
        switch target {
        case .folder:
            guard let info = FinderWatcher.frontFinderWindow() else { return }
            note.updateWindow(left: Double(info.bounds.minX), top: Double(info.bounds.minY))
            note.setOccluded(info.coveringRects.contains { $0.intersects(note.screenRectTopLeft()) })
        case .appWindow(_, let pid):
            guard appTracker == nil else { return } // AX notifications drive it; poll only as fallback
            guard let b = AXWindows.focusedBounds(pid: pid) else { return }
            note.updateWindow(left: Double(b.minX), top: Double(b.minY))
            note.setOccluded(false) // a focused app window is already on top
        }
    }

    /// App windows glide via AX move/resize notifications instead of 60fps polling.
    private func startAppTracking(_ target: Target) {
        appTracker = nil
        guard case let .appWindow(_, pid) = target, let win = AXWindows.focusedWindow(pid: pid) else { return }
        appTracker = AXWindowTracker(pid: pid, window: win) { [weak self] b in
            self?.note.updateWindow(left: Double(b.minX), top: Double(b.minY))
            self?.note.setOccluded(false)
        }
    }

    // MARK: - Show / hide

    private func showNote(_ n: Note, bounds b: CGRect, save: @escaping (Note) -> Void) {
        note.show(note: n, left: Double(b.minX), top: Double(b.minY), save: save)
        if trackTimer == nil {
            trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.trackTarget()
            }
        }
    }

    private func hideNote() { note.hide(); stopTracking() }
    private func stopTracking() { trackTimer?.invalidate(); trackTimer = nil; appTracker = nil }

    // MARK: - Menu

    @objc private func addNote() {
        guard let target = resolve(), let b = bounds(for: target) else { return }
        current = target
        showNote(load(target) ?? Note(text: "", dx: 20, dy: 40), bounds: b, save: saver(for: target))
        startAppTracking(target)
        NSApp.activate(ignoringOtherApps: true)
        note.focusForEditing()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
