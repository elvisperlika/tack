/// A Finder folder. The note lives in a hidden .tack.json inside the folder itself, which is
/// why it travels with the folder when you move or copy it — and why it can't be promoted.
final class FinderContainer: Container {
    static let bundleID = "com.apple.finder"
    let folder: String

    init(folder: String) { self.folder = folder }

    override var path: [String] { [Self.bundleID, folder] }
    override var minLevel: Int { 1 }

    // ponytail: one level exists here, so `level` is always 1 and the folder is the key
    override func note(at level: Int) throws -> Note? { try NoteStore.load(folder: folder) }
    override func write(_ note: Note, at level: Int) throws {
        try NoteStore.save(folder: folder, note: note)
    }

    /// Polled at 60fps to glue the note to the window. CGWindowList gives bounds and
    /// occluders in the same pass.
    override func frame() -> Frame? {
        guard let info = FinderWatcher.frontFinderWindow() else { return nil }
        return Frame(bounds: info.bounds, covering: info.coveringRects)
    }
}
