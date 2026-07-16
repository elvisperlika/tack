import Foundation

/// One post-it: text, its offset (dx, dy) from the Finder window's top-left corner, and
/// its colour as an "RRGGBB" hex string (nil == default yellow, keeps old files valid).
struct Note: Codable, Equatable {
    var text: String
    var dx: Double
    var dy: Double
    var color: String? = nil
}

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
        if note.text.isEmpty {
            try? FileManager.default.removeItem(at: url)  // empty text == delete the note
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

    static func save(key: String, note: Note) {
        var dict = all()
        dict[key] = note.text.isEmpty ? nil : note  // empty text == delete
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url)
    }
}
