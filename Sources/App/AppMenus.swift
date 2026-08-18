import AppKit

/// Everything the app puts in a menu: the status-bar menu, its Default color
/// submenu, and the invisible Edit menu. No tracking state lives here — the
/// stored properties it touches stay on `AppDelegate`.
extension AppDelegate {

    /// The status-bar item. Retained by the caller; the bar only keeps a weak hold.
    func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Add note here", action: #selector(addNote), keyEquivalent: ""))
        menu.addItem(.separator())
        let defColor = NSMenuItem(title: "Default color", action: nil, keyEquivalent: "")
        menu.addItem(defColor)
        defaultColorItem = defColor
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self  // rebuilds the Default color submenu on open
        item.menu = menu
        return item
    }

    /// Rebuild the Default color submenu on open so it shows the current pick and any palette edits.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = defaultColorItem else { return }
        let hex = NotePreferences.shared.defaultColorHex
        item.image = Swatch.image(hex: hex)
        item.submenu = defaultColorMenu.menu(currentHex: hex)
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

    @objc func quit() { NSApp.terminate(nil) }
}
