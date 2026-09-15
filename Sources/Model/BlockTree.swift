import Foundation

enum BlockTreeError: Error, Equatable {
    case missingBlock(UUID)
    case duplicateID(UUID)
    case invalidIndex(Int)
    case cyclicMove
}

/// An ordered forest: nil parents refer to the roots. Only this class changes relationships.
/// Blocks are shared references; changing their content does not replace them in the tree.
/// Like the note model, this is intended for serial use, not concurrent mutation.
final class BlockTree {
    private struct Node {
        let block: any Block
        var parent: UUID?
        var children: [UUID] = []
    }

    private var nodes: [UUID: Node] = [:]
    private var roots: [UUID] = []

    func block(id: UUID) -> (any Block)? { nodes[id]?.block }

    func children(of parent: UUID? = nil) throws -> [any Block] {
        try childIDs(of: parent).map { nodes[$0]!.block }
    }

    /// A root has no parent; an unknown ID is an error rather than another root.
    func parent(of id: UUID) throws -> (any Block)? {
        try node(id).parent.map { nodes[$0]!.block }
    }

    /// A nil index appends. Insertion accepts one new block; use move for existing blocks.
    func insert(_ block: any Block, under parent: UUID? = nil, at index: Int? = nil) throws {
        let id = block.id
        guard nodes[id] == nil else { throw BlockTreeError.duplicateID(id) }
        var siblings = try childIDs(of: parent)
        let position = index ?? siblings.count
        guard (0...siblings.count).contains(position) else {
            throw BlockTreeError.invalidIndex(position)
        }
        siblings.insert(id, at: position)
        nodes[id] = Node(block: block, parent: parent)
        setChildren(siblings, of: parent)
    }

    /// Moves the whole subtree. The index is measured after removing the moving block
    /// from its old position; nil appends. All validation happens before any mutation.
    func move(_ id: UUID, under parent: UUID? = nil, at index: Int? = nil) throws {
        let source = try node(id)
        var destination = try childIDs(of: parent)
        var ancestor = parent
        while let current = ancestor {
            guard current != id else { throw BlockTreeError.cyclicMove }
            ancestor = nodes[current]!.parent
        }
        if source.parent == parent { destination.removeAll { $0 == id } }
        let position = index ?? destination.count
        guard (0...destination.count).contains(position) else {
            throw BlockTreeError.invalidIndex(position)
        }
        destination.insert(id, at: position)

        if source.parent != parent {
            var previous = try childIDs(of: source.parent)
            previous.removeAll { $0 == id }
            setChildren(previous, of: source.parent)
        }
        setChildren(destination, of: parent)
        nodes[id]!.parent = parent
    }

    /// Removing a block removes every descendant from this tree as well.
    func remove(_ id: UUID) throws {
        let source = try node(id)
        var siblings = try childIDs(of: source.parent)
        siblings.removeAll { $0 == id }
        setChildren(siblings, of: source.parent)

        var pending = [id]
        while let current = pending.popLast() {
            let removed = nodes.removeValue(forKey: current)!
            pending.append(contentsOf: removed.children)
        }
    }

    /// Parents precede children, and siblings retain their order.
    func depthFirst() -> [any Block] {
        var result: [any Block] = []
        var pending = Array(roots.reversed())
        while let id = pending.popLast() {
            let current = nodes[id]!
            result.append(current.block)
            pending.append(contentsOf: current.children.reversed())
        }
        return result
    }

    private func node(_ id: UUID) throws -> Node {
        guard let node = nodes[id] else { throw BlockTreeError.missingBlock(id) }
        return node
    }

    private func childIDs(of parent: UUID?) throws -> [UUID] {
        guard let parent else { return roots }
        return try node(parent).children
    }

    // Callers validate parent IDs before committing a change, so these lookups must exist.
    private func setChildren(_ children: [UUID], of parent: UUID?) {
        if let parent {
            nodes[parent]!.children = children
        } else {
            roots = children
        }
    }
}
