import Foundation

/// Shared interface for block content. Identity must stay constant for the object's lifetime.
/// Relationships belong to BlockTree, so every block type can contain any other block type.
protocol Block: AnyObject {
    var id: UUID { get }
}
