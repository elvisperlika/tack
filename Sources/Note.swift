import Foundation

/// One post-it: text, its offset (dx, dy) from the Finder window's top-left corner, its colour
/// as an "RRGGBB" hex string, and its size. Colour and size are optional for the same reason —
/// nil means "the default", which is what every file written before they existed decodes to.
struct Note: Codable, Equatable {
    var text: String
    var dx: Double
    var dy: Double
    var color: String? = nil
    var w: Double? = nil
    var h: Double? = nil

    /// The app-wide deletion convention: an empty note is not stored, it's removed. Every store
    /// honours this one property, so "does trimming count as empty?" can only ever have one answer.
    var isDeletion: Bool { text.isEmpty }
}
