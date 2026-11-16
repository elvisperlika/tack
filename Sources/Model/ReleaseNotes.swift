import Foundation

/// One release's what's-new note: its version, and the Markdown a card shows as is.
struct Release: Equatable {
    let version: String
    let text: String
}

/// The what's-new notes that ship inside Tack.app, one `releases/<version>.md` per release.
/// Read only: they never touch the note stores.
enum ReleaseNotes {
    /// Where bundle.sh puts them. nil, or a missing folder, in a build that has none.
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("releases") }

    /// Every release in `folder`, newest first. Only files named like a version count, so a
    /// stray README or draft never sorts in as version 0.
    static func all(in folder: URL?) -> [Release] {
        guard let folder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return names
            .filter { $0.range(of: #"^\d+(\.\d+)*\.md$"#, options: .regularExpression) != nil }
            .compactMap { name in
                guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                else { return nil }
                return Release(version: String(name.dropLast(3)), text: text)
            }
            .sorted { Updater.isNewer($0.version, than: $1.version) }
    }

    /// Open the releases page by itself: the first launch of a version that has a note.
    static func shouldOpen(installed: String, lastOpened: String?, available: [Release]) -> Bool {
        installed != lastOpened && available.contains { $0.version == installed }
    }
}
