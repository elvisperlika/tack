import AppKit

/// Any app window readable through the Accessibility API. AXDocument names the focused
/// document and follows Preview's active tab; AXTitle is the fuzzy fallback and follows the
/// Settings pane. Non-final: BrowserContainer and TerminalContainer refine the identity.
class GenericAppContainer: Container {
    let bundleID: String
    let pid: pid_t
    let ident: String

    init?(app: NSRunningApplication) {
        guard let win = AXWindows.focusedWindow(pid: app.processIdentifier),
            let id = AXWindows.string(win, kAXDocumentAttribute)
                ?? AXWindows.string(win, kAXTitleAttribute),
            !id.isEmpty
        else { return nil }
        self.bundleID = app.bundleIdentifier ?? app.localizedName ?? "app"
        self.pid = app.processIdentifier
        self.ident = id
    }

    override var path: [String] { [bundleID, ident] }

    override func note(at level: Int) throws -> Note? {
        let currentKey = key(at: level)
        // Before stable tab keys, the mutable title was part of the key. Migrate on first read;
        // writing the new key before deleting the old one makes an interrupted migration harmless.
        let legacyKey = Container.key(path: path, level: level)
        return try AppNotes.load(key: currentKey, migrating: legacyKey)
    }
    override func write(_ note: Note, at level: Int) throws {
        try AppNotes.save(key: key(at: level), note: note)
    }

    /// A focused app window is already on top, so nothing covers the note — `covering` stays
    /// empty and the caller's occlusion test collapses to false on its own.
    ///
    /// Bounds come from the window server, not AX: an AX read is a synchronous round-trip
    /// into the app's main thread, which is busy servicing the event loop during a drag, so
    /// the note trailed and stuttered. CGWindowList is fresh every frame — same source that
    /// keeps Finder tracking smooth. AX stays as the fallback for windows the list can't see.
    override func frame() -> Frame? {
        if let rect = WindowServer.frontWindowBounds(pid: pid) { return Frame(bounds: rect) }
        return AXWindows.focusedBounds(pid: pid).map { Frame(bounds: $0) }
    }
}
