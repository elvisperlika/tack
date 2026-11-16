import AppKit

/// The dashboard's what's-new page: one card per release, newest first, in a column that
/// scrolls under the strip like the notes grid. The cards are notes to read, not to keep —
/// no pill, not editable, and nothing here ever reaches a note store.
final class ReleasesView: NSObject {
    /// The page, to mount in the dashboard like the grid's view.
    let view: FocusScrollView

    private static let cardWidth: CGFloat = 380
    private static let gap: CGFloat = 16

    override init() {
        view = FocusScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        view.topBand = NoteGrid.strip  // the column scrolls up under the strip the dashboard is dragged by
        view.bottomFade = 16
        view.autoresizingMask = [.width, .height]
        view.drawsBackground = false
        view.hasVerticalScroller = false  // the wheel and the trackpad still scroll, like the grid
        super.init()

        let column = Column(frame: NSRect(origin: .zero, size: view.contentSize))
        column.autoresizingMask = [.width]
        let releases = ReleaseNotes.all(in: ReleaseNotes.folder)
        if releases.isEmpty {
            column.addSubview(Self.label("No release notes in this build", size: 13))
        }
        for release in releases {
            column.addSubview(Self.label("Tack \(release.version)", size: 11))
            let card = Self.card(for: release)
            cards.append(card)
            column.addSubview(card.view)
        }
        view.documentView = column
    }

    /// Kept alive by the page: a NoteCard owns the wiring its view relies on.
    private var cards: [NoteCard] = []

    private static func card(for release: Release) -> NoteCard {
        let card = NoteCard(size: NSSize(width: cardWidth, height: 200), blending: .withinWindow)
        card.load(Note(text: release.text, dx: 0, dy: 0))
        card.pill.view.isHidden = true
        let text = card.editor.textView
        text.isEditable = false
        card.editor.view.scrollsItself = false  // the page scrolls; a card never does on its own
        // As tall as its text, so nothing is clipped inside the card: the laid-out text, its
        // insets, the drag strip it starts below and the fade it ends in.
        var height: CGFloat = 200
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            height = ceil(layout.usedRect(for: container).height + text.textContainerInset.height * 2) + 18 + 8 + 8
        }
        card.view.setFrameSize(NSSize(width: cardWidth, height: height))
        card.view.autoresizingMask = []
        return card
    }

    private static func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.sizeToFit()
        return label
    }

    /// Top-down, centred: each subview on its own row.
    private final class Column: NSView {
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            var y = ReleasesView.gap
            for sub in subviews {
                sub.setFrameOrigin(NSPoint(x: ((bounds.width - sub.frame.width) / 2).rounded(), y: y))
                // A label sits close to the card it names; a card leaves a gap before the next one.
                y += sub.frame.height + (sub is NSTextField ? 4 : ReleasesView.gap)
            }
            let shown = enclosingScrollView.map { $0.contentSize.height - $0.contentInsets.top - $0.contentInsets.bottom } ?? 0
            let height = max(y, shown)
            if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        }
    }
}
