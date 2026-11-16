import AppKit

/// The dashboard's what's-new page: one card per release, newest first, in a column that
/// scrolls under the strip like the notes grid. The cards are notes to read, not to keep —
/// not editable, and nothing here ever reaches a note store. Each card's pill moves to the card
/// above or below it, gliding it into the middle of the page; the page itself scrolls freely.
final class ReleasesView: NSObject {
    /// The page, to mount in the dashboard like the grid's view.
    let view: FocusScrollView

    private static let cardWidth: CGFloat = 380
    private static let gap: CGFloat = 16
    private static let glideDuration: TimeInterval = 0.4

    /// Kept alive by the page: a NoteCard owns the wiring its view relies on, and a tracking
    /// area holds its owner only weakly.
    private var cards: [NoteCard] = []
    private var watchers: [HoverWatcher] = []

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
            column.addSubview(Self.label("No release notes in this build"))
        }
        for (i, release) in releases.enumerated() {
            let card = Self.card(for: release)
            // Moves are set before the pill turns reader, which lays its arrows out from them.
            card.pill.onUp = i > 0 ? { [weak self] in self?.glide(to: i - 1) } : nil
            card.pill.onDown = i < releases.count - 1 ? { [weak self] in self?.glide(to: i + 1) } : nil
            card.pill.isReader = true
            // One release has nowhere to move to: an empty pill would be a dead end.
            card.pill.view.isHidden = releases.count == 1
            // The arrows show only while the cursor is on the card; at rest the card is bare.
            card.pill.view.alphaValue = 0
            let pill = card.pill
            watchers.append(HoverWatcher(card.view) { inside in
                if inside { pill.open() } else { pill.close() }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    pill.view.animator().alphaValue = inside ? 1 : 0
                }
            })
            cards.append(card)
            column.addSubview(card.view)
        }
        view.documentView = column
    }

    // MARK: - Moving

    /// How far the page is scrolled, measured from the top of what shows below the strip.
    private var offset: CGFloat { view.contentView.bounds.origin.y + view.contentInsets.top }
    private var viewport: CGFloat { view.contentSize.height - view.contentInsets.top - view.contentInsets.bottom }

    /// Glide card `index` into the middle of the page.
    private func glide(to index: Int) {
        guard cards.indices.contains(index), let column = view.documentView else { return }
        let frame = cards[index].view.frame
        let target = Self.centredOffset(
            card: frame.minY...frame.maxY, viewport: viewport, limits: 0...max(0, column.frame.height - viewport))
        guard abs(target - offset) > 0.5 else { return }
        let clip = view.contentView
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.glideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target - view.contentInsets.top))
        } completionHandler: { [weak self] in
            guard let self else { return }
            view.reflectScrolledClipView(view.contentView)
        }
    }

    /// The offset that puts `card` — its top-down extent, in offset coordinates — in the middle
    /// of the page; or, for a card taller than the page, lines its top up so its title shows.
    /// Held inside `limits`, the range the page can scroll.
    static func centredOffset(card: ClosedRange<CGFloat>, viewport: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        let height = card.upperBound - card.lowerBound
        let y = height > viewport ? card.lowerBound : card.lowerBound + height / 2 - viewport / 2
        return min(max(y, limits.lowerBound), limits.upperBound)
    }

    // MARK: - Cards

    private static func card(for release: Release) -> NoteCard {
        let card = NoteCard(size: NSSize(width: cardWidth, height: 200), blending: .withinWindow)
        // Always the palette's yellow, whatever colour new notes start in: what's new reads as a post-it.
        card.load(Note(text: release.text, dx: 0, dy: 0, color: "FFEB73"))
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

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.sizeToFit()
        return label
    }

    /// Reports the cursor entering and leaving a view, even while Tack is in the background.
    private final class HoverWatcher: NSObject {
        private let onHover: (Bool) -> Void

        init(_ view: NSView, onHover: @escaping (Bool) -> Void) {
            self.onHover = onHover
            super.init()
            view.addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self))
        }

        @objc func mouseEntered(with event: NSEvent) { onHover(true) }
        @objc func mouseExited(with event: NSEvent) { onHover(false) }
    }

    /// Top-down and centred, one card per row, with room above the first and below the last
    /// for each of them to sit in the middle of the page too.
    private final class Column: NSView {
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let shown = enclosingScrollView.map { $0.contentSize.height - $0.contentInsets.top - $0.contentInsets.bottom } ?? 0
            func pad(_ view: NSView?) -> CGFloat { max(ReleasesView.gap, ((shown - (view?.frame.height ?? 0)) / 2).rounded()) }
            var y = pad(subviews.first)
            for sub in subviews {
                sub.setFrameOrigin(NSPoint(x: ((bounds.width - sub.frame.width) / 2).rounded(), y: y))
                y += sub.frame.height + ReleasesView.gap
            }
            let height = max(y - ReleasesView.gap + pad(subviews.last), shown)
            if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        }
    }
}
