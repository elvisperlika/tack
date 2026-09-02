import AppKit

/// The note's control cluster, parked in the card's top-right corner. One control instead of
/// three things scattered over the card: at rest it's a bare glass dot; the cursor reaching it
/// opens it leftwards to uncover three dots — typeface, colour, delete — and clicking either of
/// the first two opens that dot's picker in place. It *floats* over the text throughout, the way
/// iOS's new bars do — the note's own words blur under it, so nothing is carved out for it.
///
/// It reads `styler` to know what is currently chosen (which dot to wear, which choice to ring)
/// but never writes to it: a pick, and the live preview a hover shows, both leave through
/// `onFont` / `onColor`, so the assembler stays the one place that decides what choosing means.
final class NotePill: NSObject {
    /// The capsule to mount in the note's card.
    let view: HoverPill

    /// A typeface the user is hovering (`commit: false`) or has chosen (`true`).
    var onFont: (NoteFont, Bool) -> Void = { _, _ in }
    /// A colour the user is hovering (`commit: false`) or has chosen (`true`).
    var onColor: (NSColor, Bool) -> Void = { _, _ in }
    var onDelete: () -> Void = {}

    private let styler: NoteStyler  // read-only: what is currently chosen
    private let fontDot: NSButton  // wears a "T" in the note's face; opens the face picker
    private let colorDot: NSButton  // wears the note's colour; opens the palette picker
    private let deleteDot: NSButton  // red: deletes the note

    /// What the pill is showing. `.font` / `.color` are the picker: the pill widens and the three
    /// dots give way to the choices, which is why this is a mode and not a bool.
    private enum Mode { case closed, open, font, color }
    private var mode = Mode.closed
    private var choiceDots: [NSButton] = []  // the picker's dots, built per opening

    // MARK: - Geometry

    // Bigger dots in the same pill: the padding and the gap give up what the dots take, so the
    // capsule stays 20pt tall and ~60 wide open.
    private static let dotSize: CGFloat = 16
    private static let dotGap: CGFloat = 4
    private static let pillPad = NSSize(width: 5, height: 3)
    private static let deleteHex = "FF5F57"  // the red of a window's close button

    static let pillInset: CGFloat = 6  // gap between the pill and the card's top-right corner

    /// Closed, the pill is a circle — same height, so the `height / 2` corner radius rounds it
    /// the whole way with no second radius to keep in sync.
    static var pillClosedSize: NSSize { NSSize(width: pillOpenSize.height, height: pillOpenSize.height) }
    static var pillOpenSize: NSSize { pillSize(dots: 3) }

    /// How many dots a note `width` wide can hold — `pillSize` inverted, so the two can't drift.
    /// Never below 1: a picker with nothing in it would be a dead end.
    static func pillDots(fitting width: CGFloat) -> Int {
        let room = width - pillInset * 2 - pillPad.width * 2 + dotGap
        return max(1, Int(room / (dotSize + dotGap)))
    }

    static func pillSize(dots: Int) -> NSSize {
        NSSize(
            width: CGFloat(dots) * dotSize + CGFloat(dots - 1) * dotGap + pillPad.width * 2,
            height: dotSize + pillPad.height * 2)
    }

    /// Where the nth dot sits inside the pill. One formula, so `pillSize` and every dot agree.
    private static func dotFrame(index: Int) -> NSRect {
        NSRect(
            x: pillPad.width + CGFloat(index) * (dotSize + dotGap), y: pillPad.height,
            width: dotSize, height: dotSize)
    }

    private static func dotButton(index: Int, name: String) -> NSButton {
        let b = NSButton(frame: dotFrame(index: index))
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.setAccessibilityLabel(name)
        b.toolTip = name
        return b
    }

    private static func capsule(cardWidth: CGFloat, cardHeight: CGFloat) -> HoverPill {
        let size = pillClosedSize
        let v = HoverPill(
            frame: NSRect(
                x: cardWidth - pillInset - size.width, y: cardHeight - pillInset - size.height,
                width: size.width, height: size.height))
        v.material = .popover
        v.blendingMode = .withinWindow  // blur the note's own text under it, not the desktop
        v.state = .active
        v.appearance = NSAppearance(named: .aqua)
        v.wantsLayer = true
        v.layer?.cornerRadius = size.height / 2
        v.layer?.masksToBounds = true  // rounds the blur; within-window blending is layer-drawn
        v.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        v.layer?.borderWidth = 1
        v.autoresizingMask = [.minXMargin, .minYMargin]  // top-right corner, whatever the size
        return v
    }

    // MARK: - Life cycle

    init(cardWidth: CGFloat, cardHeight: CGFloat, styler: NoteStyler) {
        self.styler = styler
        view = Self.capsule(cardWidth: cardWidth, cardHeight: cardHeight)
        fontDot = Self.dotButton(index: 0, name: "Font")
        colorDot = Self.dotButton(index: 1, name: "Colour")
        deleteDot = Self.dotButton(index: 2, name: "Delete note")
        deleteDot.image = Swatch.image(
            hex: Self.deleteHex, size: Self.dotSize, radius: Self.dotSize / 2)
        super.init()

        // One click is the whole gesture for each; the rarer choices (editing the palette, the
        // pin level) are a right-click on the card. Hidden until the pill opens — the clip only
        // hides them from view, and a dot outside the closed pill would still take clicks.
        for dot in [fontDot, colorDot, deleteDot] {
            dot.isHidden = true
            view.addSubview(dot)
        }
        fontDot.target = self
        fontDot.action = #selector(pickFont)
        colorDot.target = self
        colorDot.action = #selector(pickColor)
        deleteDot.target = self
        deleteDot.action = #selector(deleteTapped)

        // Leaving cancels whatever picker is open. Arriving only opens the pill *from rest*: every
        // frame change rebuilds the tracking area, which re-posts mouseEntered with the cursor
        // already inside — unguarded, that snapped an open picker straight back to the three dots
        // (and only for the colours, whose strip is the one that changes the pill's width).
        view.onHover = { [weak self] inside in
            guard let self else { return }
            if !inside {
                // Only the bare three dots follow the cursor away. A picker is a question already
                // asked: it stays up until it's answered, or until a click on the card drops it.
                if mode == .open { set(.closed) }
            } else if mode == .closed {
                set(.open)
            }
        }
        refreshDots()
    }

    /// The picker's way out: a click anywhere on the card drops whatever is open.
    func close() { set(.closed) }

    /// The window is reused between notes: never arrive already open.
    func reset() { set(.closed, animated: false) }

    /// The two dots that wear the current choice. Full strength on the colour one: it's the
    /// colour's label, not another sheer wash of it. Refreshed whenever the three dots are about
    /// to be shown, so a colour chosen from the card's right-click menu lands here too.
    func refreshDots() {
        fontDot.image = styler.family.dotImage(size: Self.dotSize)
        colorDot.image = Swatch.image(
            hex: styler.colorHex, size: Self.dotSize, radius: Self.dotSize / 2)
    }

    // MARK: - Modes

    /// What the current mode puts in the pill, left to right.
    private func shownDots() -> [NSButton] {
        switch mode {
        case .closed: return []
        case .open: return [fontDot, colorDot, deleteDot]
        case .font, .color: return choiceDots
        }
    }

    /// Lay the row out and size the capsule around it. Widths stop being uniform the moment a
    /// font choice opens into "Tack", so the row is walked rather than indexed — `pillSize` is
    /// this same sum for the uniform case, which is all the closed and open sizes need.
    ///
    /// The capsule grows leftwards (`maxX` fixed), so a dot that widens by Δ pushes the pill's
    /// left edge out by the same Δ: its own right edge, and every dot to its right, stay put.
    /// That's what keeps the cursor on the dot it just opened.
    private func layout() {
        let shown = shownDots()
        var x = Self.pillPad.width
        for dot in shown {
            let w = (dot as? FontChoiceButton)?.width ?? Self.dotSize
            dot.animator().frame = NSRect(x: x, y: Self.pillPad.height, width: w, height: Self.dotSize)
            x += w + Self.dotGap
        }
        let width = shown.isEmpty ? Self.pillClosedSize.width : x - Self.dotGap + Self.pillPad.width
        let frame = view.frame
        view.animator().frame = NSRect(
            x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }

    /// Move the pill to `mode`, growing it leftwards from its right edge so the corner it's
    /// parked in stays put. Whatever the mode shows is just an ordered list of dots, so one
    /// width and one layout serve the three dots and both pickers alike.
    private func set(_ mode: Mode, animated: Bool = true) {
        guard mode != self.mode else { return }
        self.mode = mode
        let spent = choiceDots  // the picker dots the previous mode built; dropped once faded out
        switch mode {
        case .closed, .open: choiceDots = []
        case .font: choiceDots = fontChoices()
        case .color: choiceDots = colorChoices()
        }
        choiceDots.forEach(view.addSubview)
        if mode == .open { refreshDots() }  // before they're shown, so they arrive current

        let shown = shownDots()
        let gone = spent + [fontDot, colorDot, deleteDot].filter { !shown.contains($0) }
        shown.forEach { $0.isHidden = false }
        // Hide the outgoing dots now, not on completion: a delete dot lingering under the swatches
        // for the length of the animation is a note deleted by accident. Closing is the exception —
        // there the shrinking capsule is *meant* to wipe them away.
        if mode != .closed { gone.forEach { $0.isHidden = true } }

        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = animated ? 0.14 : 0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layout()
            },
            completionHandler: {
                if mode == .closed { gone.forEach { $0.isHidden = true } }
                spent.forEach { $0.removeFromSuperview() }
            })
    }

    // MARK: - Pickers

    /// One dot per typeface, each wearing its own "T" — and opening to the whole word under the
    /// cursor, which is the preview: you read "Tack" in the face before you commit to it.
    private func fontChoices() -> [NSButton] {
        NoteFont.allCases.enumerated().map { i, face in
            let b = FontChoiceButton(frame: Self.dotFrame(index: i))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(face.rawValue)
            b.toolTip = face.rawValue
            b.face = face
            let borderWidth: CGFloat = face == styler.family ? 2 : 1
            b.narrow = face.dotImage(size: Self.dotSize, borderWidth: borderWidth)
            b.wide = face.wordImage(height: Self.dotSize, borderWidth: borderWidth)
            b.image = b.narrow
            b.target = self
            b.action = #selector(fontChosen(_:))
            // The guard is load-bearing: opening the dot changes its frame, which rebuilds the
            // tracking area, which re-posts mouseEntered — without it that loops forever.
            b.onHover = { [weak self, weak b] inside in
                guard let self, let b, b.expanded != inside else { return }
                b.expanded = inside
                onFont(inside ? face : styler.family, false)
                // Slower than the pill's own 0.14, and on a long tail rather than easeOut: this
                // one you're meant to *read* — the word unrolling is the preview.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    self.layout()
                }
            }
            return b
        }
    }

    /// One dot per palette colour. ponytail: colours past what the note is wide enough to hold are
    /// dropped — the right-click grid is the full palette, and it scrolls with the menu.
    private func colorChoices() -> [NSButton] {
        // The superview is the note's card; it is only nil before the pill is mounted.
        let card = view.superview?.bounds.width ?? NotePreferences.shared.defaultSize.width
        return NotePreferences.shared.palette.prefix(Self.pillDots(fitting: card)).enumerated().map {
            i, hex in
            let b = ColorSwatchButton(frame: Self.dotFrame(index: i))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(hex)
            b.hex = hex
            b.image = Swatch.image(
                hex: hex, size: Self.dotSize, radius: Self.dotSize / 2,
                borderWidth: hex == styler.colorHex ? 2 : 1)
            b.wantsLayer = true
            b.onHover = { [weak self, weak b] inside in
                guard let self, let layer = b?.layer else { return }
                let target = inside ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = layer.presentation()?.transform ?? layer.transform
                animation.toValue = target
                animation.duration = 0.14
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "hoverScale")
                layer.transform = target
                onColor(Swatch.color(fromHex: inside ? hex : styler.colorHex), false)
            }
            b.target = self
            b.action = #selector(colorChosen(_:))
            return b
        }
    }

    // MARK: - Actions

    @objc private func pickFont() { set(.font) }
    @objc private func pickColor() { set(.color) }
    @objc private func deleteTapped() { onDelete() }

    @objc private func fontChosen(_ sender: NSButton) {
        guard let choice = sender as? FontChoiceButton else { return }
        onFont(choice.face, true)
        set(.open)
    }

    @objc private func colorChosen(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        onColor(Swatch.color(fromHex: swatch.hex), true)
        set(.open)
    }
}
