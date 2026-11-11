import Foundation

/// One post-it: text, its offset (dx, dy) from the Finder window's top-left corner, its colour
/// as an "RRGGBB" hex string, and its size. Colour and size are optional for the same reason —
/// nil means "the default", which is what every file written before they existed decodes to.
struct Note: Codable, Equatable {
    var text: String
    var dx: Double
    var dy: Double
    var color: String? = nil
    var font: String? = nil  // NoteFont.rawValue
    var w: Double? = nil
    var h: Double? = nil

    /// The app-wide deletion convention: an empty note is not stored, it's removed. Every store
    /// honours this one property, so "does trimming count as empty?" can only ever have one answer.
    var isDeletion: Bool { text.isEmpty }

    /// What to write when saving `mine` over a file that may have changed since Tack last read
    /// or wrote it (`seen`) — a script, another app, the dashboard. Field by field, for the
    /// text, the colour and the typeface: whatever this save changed is the user's and goes as
    /// is; whatever it left alone takes the file's value, so somebody else's change survives.
    /// Placement (position, size) is always `mine`: only the note on screen knows where it is.
    /// Nobody else wrote, or nothing to compare against: `mine` as is.
    static func merge(mine: Note, seen: Note?, disk: Note?) -> Note {
        guard let disk, let seen, disk != seen else { return mine }
        var merged = mine
        if mine.text == seen.text { merged.text = disk.text }
        if mine.color == seen.color { merged.color = disk.color }
        if mine.font == seen.font { merged.font = disk.font }
        return merged
    }
}
