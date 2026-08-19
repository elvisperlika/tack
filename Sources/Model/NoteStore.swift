import Foundation

/// Reads/writes a hidden `.tack.json` inside the folder itself, so notes travel
/// with the folder when it's moved or copied.
enum NoteStore {
    static let fileName = ".tack.json"

    static func fileURL(forFolder folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(fileName)
    }

    static func load(folder: String) -> Note? {
        guard let data = try? Data(contentsOf: fileURL(forFolder: folder)) else { return nil }
        return try? JSONDecoder().decode(Note.self, from: data)
    }

    // ponytail: best-effort write, in-memory fallback (read-only/network folders just don't persist)
    static func save(folder: String, note: Note) {
        let url = fileURL(forFolder: folder)
        if note.isDeletion {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: url)
    }
}

/// Notes bound to app windows (not Finder folders) live in one central JSON, keyed by a
/// window identity string, since a generic app window has no folder to write into.
enum AppNotes {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent("Tack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appnotes.json")
    }()

    private static func all() -> [String: Note] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Note].self, from: data)) ?? [:]
    }

    static func load(key: String) -> Note? { all()[key] }

    /// Load a stable key, migrating the old title-dependent key on first access.
    static func load(key: String, migrating legacyKey: String) -> Note? {
        if let note = load(key: key) { return note }
        guard legacyKey != key, let note = load(key: legacyKey) else { return nil }
        save(key: key, note: note)
        save(key: legacyKey, note: Note(text: "", dx: note.dx, dy: note.dy))
        return note
    }

    static func save(key: String, note: Note) {
        var dict = all()
        dict[key] = note.isDeletion ? nil : note
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url)
    }
}
