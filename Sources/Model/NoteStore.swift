import Foundation

enum NotePersistenceError: LocalizedError {
    case createDirectory(URL, Error)
    case read(URL, Error)
    case invalidJSON(URL, recovery: URL?, Error)
    case encode(URL, Error)
    case backup(URL, Error)
    case write(URL, Error)
    case delete(URL, Error)

    var errorDescription: String? {
        switch self {
        case .createDirectory(let url, let error):
            return "Could not create the notes folder at \(url.path): \(error.localizedDescription)"
        case .read(let url, let error):
            return "Could not read notes at \(url.path): \(error.localizedDescription)"
        case .invalidJSON(let url, let recovery, let error):
            let preserved = recovery.map { " A recovery copy was kept at \($0.path)." }
                ?? " The original file was left untouched."
            return "Notes at \(url.path) contain invalid JSON: \(error.localizedDescription).\(preserved)"
        case .encode(let url, let error):
            return "Could not encode notes for \(url.path): \(error.localizedDescription)"
        case .backup(let url, let error):
            return "Could not back up notes at \(url.path): \(error.localizedDescription)"
        case .write(let url, let error):
            return "Could not save notes at \(url.path): \(error.localizedDescription)"
        case .delete(let url, let error):
            return "Could not delete notes at \(url.path): \(error.localizedDescription)"
        }
    }
}

/// The shared safety boundary for both JSON stores: missing is not an error, malformed is.
private enum JSONFile {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NotePersistenceError.read(url, error)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NotePersistenceError.invalidJSON(url, recovery: recoveryCopy(of: url), error)
        }
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL, backup: Bool = false) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw NotePersistenceError.encode(url, error)
        }

        if backup, FileManager.default.fileExists(atPath: url.path) {
            do {
                let existing = try Data(contentsOf: url)
                try existing.write(to: backupURL(for: url), options: .atomic)
            } catch {
                throw NotePersistenceError.backup(url, error)
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotePersistenceError.write(url, error)
        }
    }

    static func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw NotePersistenceError.delete(url, error)
        }
    }

    static func backupURL(for url: URL) -> URL { url.appendingPathExtension("backup") }

    private static func recoveryCopy(of url: URL) -> URL? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let copy = url.appendingPathExtension("corrupt-\(Int(date.timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil  // the invalid original remains untouched and is named in the error
        }
    }
}

/// Reads/writes a hidden `.tack.json` inside the folder itself, so notes travel
/// with the folder when it's moved or copied.
enum NoteStore {
    static let fileName = ".tack.json"

    static func fileURL(forFolder folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(fileName)
    }

    static func load(folder: String) throws -> Note? {
        try JSONFile.load(Note.self, from: fileURL(forFolder: folder))
    }

    static func save(folder: String, note: Note) throws {
        let url = fileURL(forFolder: folder)
        _ = try JSONFile.load(Note.self, from: url)  // never overwrite or delete malformed data
        if note.isDeletion {
            try JSONFile.delete(url)
        } else {
            try JSONFile.save(note, to: url)
        }
    }
}

/// Notes bound to app windows (not Finder folders) live in one central JSON, keyed by a
/// window identity string, since a generic app window has no folder to write into.
enum AppNotes {
    private static func fileURL() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tack", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw NotePersistenceError.createDirectory(dir, error)
        }
        return dir.appendingPathComponent("appnotes.json")
    }

    private static func all(at url: URL) throws -> [String: Note] {
        try JSONFile.load([String: Note].self, from: url) ?? [:]
    }

    static func load(key: String) throws -> Note? { try load(key: key, from: fileURL()) }

    static func load(key: String, from url: URL) throws -> Note? { try all(at: url)[key] }

    /// Load a stable key, migrating the old title-dependent key on first access.
    static func load(key: String, migrating legacyKey: String) throws -> Note? {
        try load(key: key, migrating: legacyKey, from: fileURL())
    }

    static func load(key: String, migrating legacyKey: String, from url: URL) throws -> Note? {
        if let note = try load(key: key, from: url) { return note }
        guard legacyKey != key, let note = try load(key: legacyKey, from: url) else { return nil }
        try save(key: key, note: note, to: url)
        try save(key: legacyKey, note: Note(text: "", dx: note.dx, dy: note.dy), to: url)
        return note
    }

    static func save(key: String, note: Note) throws {
        try save(key: key, note: note, to: fileURL())
    }

    static func save(key: String, note: Note, to url: URL) throws {
        var dict = try all(at: url)
        dict[key] = note.isDeletion ? nil : note
        try JSONFile.save(dict, to: url, backup: true)
    }
}
