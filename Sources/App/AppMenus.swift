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
            makeItem("Add note here", #selector(addNote), symbol: "note.text", key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Tack", #selector(openTack), symbol: "macwindow", key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Tack", #selector(quit), symbol: "power", key: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        return item
    }

    private func makeItem(_ title: String, _ action: Selector, symbol: String, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        img?.isTemplate = true  // menus recolour template images to match highlight/light-dark
        i.image = img
        return i
    }

    /// ⌘C/⌘V/⌘Z only reach a text view through the main menu's key equivalents. An agent app has
    /// no menu bar to show a menu in, but NSApp still dispatches through `mainMenu` — so this
    /// invisible Edit menu is the whole reason copy, paste and undo work inside a note.
    func installEditMenu() {
        let edit = NSMenu()
        let items: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),  // capital Z is ⌘⇧Z
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
            ("Bold", Selector(("toggleBold:")), "b"),  // MarkdownTextView implements these
            ("Italic", Selector(("toggleItalic:")), "i"),
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

    @objc func addNote() {
        guard let container = resolve(), let f = container.frame() else { return }
        current = container
        let hit = container.load()
        showNote(
            hit?.note ?? Note(text: "", dx: 20, dy: 40), frame: f, container: container,
            level: hit?.level ?? container.finestLevel)  // finest available, promote later
        NSApp.activate(ignoringOtherApps: true)
        note.focusForEditing()
    }

    /// Opens the Tack window — empty for now, the future home of note management.
    @objc func openTack() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() { NSApp.terminate(nil) }
}
