import AppKit

extension AppDelegate {
    /// ⌘C/⌘V/⌘Z only reach a text view through the main menu's key equivalents. An agent app has
    /// no menu bar to show a menu in, but NSApp still dispatches through `mainMenu` — so this
    /// menu is the whole reason copy, paste and undo work inside a note.
    ///
    /// It stops being invisible the moment the Tack window puts the app in the Dock, so it is
    /// built as a real menu bar: item 0 is the application menu (macOS titles it with the app
    /// name and expects Quit in it), and the editing commands sit under their own Edit title.
    func installEditMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Tack", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let edit = NSMenu(title: "Edit")
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
        editItem.title = "Edit"
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
