import AppKit

/// The dashboard's what's-new page: one card per release, newest first, in a column that
/// scrolls under the strip like the notes grid. The cards are notes to read, not to keep —
/// no pill, not editable, and nothing here ever reaches a note store. A swipe settles on the
/// next card, centred in the page.
final class ReleasesView: NSObject {
    /// The page, to mount in the dashboard like the grid's view.
    let view: FocusScrollView

    private static let cardWidth: CGFloat = 380
    private static let gap: CGFloat = 16
    private static let snapDuration: TimeInterval = 0.4

    /// Kept alive by the page: a NoteCard owns the wiring its view relies on.
    private var cards: [NoteCard] = []
    /// Where the page sat when the swipe began, so a short swipe still means "the next one".
    private var swipeStart: CGFloat = 0

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
        for release in releases {
            let card = Self.card(for: release)
            cards.append(card)
            column.addSubview(card.view)
        }
        view.documentView = column

        // shortcut: only a live scroll (trackpad, Magic Mouse) snaps; a notched wheel scrolls
        // freely, since it never says when it has finished. Snap on a timer if that matters.
        let center = NotificationCenter.default
        center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: view, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            swipeStart = offset
        }
        center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: view, queue: .main) {
            [weak self] _ in self?.settle()
        }
    }

    // MARK: - Snapping

    /// How far the page is scrolled, measured from the top of what shows below the strip.
    private var offset: CGFloat { view.contentView.bounds.origin.y + view.contentInsets.top }
    private var viewport: CGFloat { view.contentSize.height - view.contentInsets.top - view.contentInsets.bottom }

    /// Glide to the card the swipe was heading for.
    private func settle() {
        guard let column = view.documentView else { return }
        let target = Self.snapOffset(
            cards: cards.map { $0.view.frame.minY...$0.view.frame.maxY }, viewport: viewport,
            limits: 0...max(0, column.frame.height - viewport), from: swipeStart, to: offset)
        guard abs(target - offset) > 0.5 else { return }
        let clip = view.contentView
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.snapDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target - view.contentInsets.top))
        } completionHandler: { [weak self] in
            guard let self else { return }
            view.reflectScrolledClipView(view.contentView)
        }
    }

    /// Where a swipe from `start` to `end` should settle: the card nearest the middle of the
    /// page, or — when the swipe was too short to reach another — the next card in its
    /// direction. Centred, unless the card is taller than the page: then its top lines up, so
    /// its title shows. `cards` are top-down extents, in the same coordinates as the offsets.
    static func snapOffset(
        cards: [ClosedRange<CGFloat>], viewport: CGFloat, limits: ClosedRange<CGFloat>,
        from start: CGFloat, to end: CGFloat
    ) -> CGFloat {
        func clamped(_ y: CGFloat) -> CGFloat { min(max(y, limits.lowerBound), limits.upperBound) }
        guard !cards.isEmpty else { return clamped(end) }
        func nearest(_ offset: CGFloat) -> Int {
            let middle = offset + viewport / 2
            return cards.indices.min {
                abs((cards[$0].lowerBound + cards[$0].upperBound) / 2 - middle)
                    < abs((cards[$1].lowerBound + cards[$1].upperBound) / 2 - middle)
            }!
        }
        let from = nearest(start)
        var to = nearest(end)
        if to == from, abs(end - start) > 8 {  // a couple of points is a nudge, not a swipe
            to = min(max(from + (end > start ? 1 : -1), 0), cards.count - 1)
        }
        let card = cards[to]
        let height = card.upperBound - card.lowerBound
        return clamped(height > viewport ? card.lowerBound : card.lowerBound + height / 2 - viewport / 2)
    }

    // MARK: - Cards

    private static func card(for release: Release) -> NoteCard {
        let card = NoteCard(size: NSSize(width: cardWidth, height: 200), blending: .withinWindow)
        // Always the palette's yellow, whatever colour new notes start in: what's new reads as a post-it.
        card.load(Note(text: release.text, dx: 0, dy: 0, color: "FFEB73"))
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

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.sizeToFit()
        return label
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
