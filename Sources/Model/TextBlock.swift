import Foundation

/// Markdown content, preserved verbatim. Rendering and persistence are separate concerns.
final class TextBlock: Block {
    let id: UUID
    var text: String

    init(text: String, id: UUID = UUID()) {
        self.id = id
        self.text = text
    }
}
