import AppKit

/// Everything the app puts in a menu: the status-bar menu and the invisible
/// Edit menu. No tracking state lives here — the stored properties it touches
/// stay on `AppDelegate`.
extension AppDelegate {
    /// The status-bar item. Retained by the caller; the bar only keeps a weak hold.
    func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.addItem(
            makeItem("Add note here", #selector(addNote), symbol: "note.text", key: "n"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Tack", #selector(openTack), symbol: "macwindow", key: "o"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Tack", #selector(quit), symbol: "power", key: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        return item
    }

    /// Creates a status-bar menu item with its action, keyboard shortcut, and SF Symbol.
    private func makeItem(_ title: String, _ action: Selector, symbol: String, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        img?.isTemplate = true  // menus recolour template images to match highlight/light-dark
        i.image = img
        return i
    }

    /// Shows the current container's note, or creates a centred empty note when none is saved.
    @objc func addNote() {
        guard let container = resolve(), let f = container.frame() else { return }
        let hit: (note: Note, level: Int)?
        do {
            hit = try container.load()
        } catch {
            reportPersistenceError(error)
            return
        }
        let start = Coord.center(note: NotePreferences.shared.defaultSize, window: f.bounds.size)
        guard showNote(
            hit?.note ?? Note(text: "", dx: start.dx, dy: start.dy), frame: f, container: container,
            level: hit?.level ?? container.finestLevel)  // finest available, promote later
        else { return }
        current = container
        NSApp.activate(ignoringOtherApps: true)
        note.focusForEditing()
    }

    /// Opens the Tack window — empty for now, the future home of note management.
    @objc func openTack() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Terminates Tack through AppKit, which first asks the app delegate to flush pending saves.
    @objc func quit() { NSApp.terminate(nil) }
}
