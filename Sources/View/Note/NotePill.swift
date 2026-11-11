import AppKit

/// The note's control cluster, parked in the card's top-right corner. One control instead of
/// three things scattered over the card: at rest it's a bare glass dot; the cursor reaching it
/// opens it leftwards to uncover its dots — typeface, colour, pin level, delete — and clicking
/// any but the last opens that dot's picker in place. It *floats* over the text throughout, the way
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
    /// A pin level the user picked. The owner moves the note and reports back through
    /// `setPinLevels`, so a move that fails leaves the picker ringing the level it had.
    var onPin: (Int) -> Void = { _ in }
    /// Open the Tack window on every note. nil hides the dot: a card already *in* that window
    /// has nowhere to go.
    var onOpenAll: (() -> Void)?
    /// Bring forward the app, tab or folder this note lives on. nil hides the dot: a floating
    /// note is already sitting on it.
    var onReveal: (() -> Void)?
    /// Turn the dashboard back into the note — the one resting dot while the note is the dashboard.
    var onCollapse: () -> Void = {}

    /// The note is the dashboard: the pill keeps its place and its glass, but offers what the
    /// dashboard does rather than what a note does.
    var isDashboard = false {
        didSet {
            guard isDashboard != oldValue else { return }
            reset()
            for (i, dot) in restingDots.enumerated() { dot.frame = Self.dotFrame(index: i) }
        }
    }

    /// One place a note can be pinned: its level, the menu wording, and the symbol its dot wears.
    typealias PinChoice = (level: Int, label: String, symbol: String)

    private let styler: NoteStyler  // read-only: what is currently chosen
    private let fontDot: NSButton  // wears a "T" in the note's face; opens the face picker
    private let colorDot: NSButton  // wears the note's colour; opens the palette picker
    private let pinDot: NSButton  // wears the current level's symbol; opens the level picker
    private let allDot: NSButton  // a stack of notes; opens the Tack window on all of them
    private let backDot: NSButton  // the dashboard's way back to the note
    private let revealDot: NSButton  // a dashboard card's way to the app it lives on
    private let deleteDot: NSButton  // red: deletes the note

    /// Where this note can be pinned, and where it is. Fewer than two is no choice at all, so
    /// the pin dot stays away — a Finder note, or a card in the Tack window.
    private var pinChoices: [PinChoice] = []
    private var pinCurrent = 0

    /// What the pill is showing. `.font` / `.color` / `.pin` are the picker: the pill widens and
    /// the resting dots give way to the choices, which is why this is a mode and not a bool.
    private enum Mode { case closed, open, font, color, pin }
    private var mode = Mode.closed
    private var choiceDots: [NSButton] = []  // the picker's dots, built per opening
    /// A hovered face or colour is showing on the note without being chosen. It stays up while
    /// the cursor crosses the gaps between dots — snapping back to the chosen one in every gap
    /// flickered — and is put back only when the cursor leaves the pill or the picker closes.
    private var previewing = false

    // MARK: - Geometry

    // Bigger dots in the same pill: the padding and the gap give up what the dots take, so the
    // capsule stays 20pt tall and ~60 wide open.
    static let dotSize: CGFloat = 16
    private static let dotGap: CGFloat = 4
    private static let pillPad = NSSize(width: 5, height: 3)
    private static let deleteHex = "FF5F57"  // the red of a window's close button

    static let pillInset: CGFloat = 6  // gap between the pill and the card's top-right corner

    /// Closed, the pill is a circle — same height, so the `height / 2` corner radius rounds it
    /// the whole way with no second radius to keep in sync.
    static var pillClosedSize: NSSize { NSSize(width: pillOpenSize.height, height: pillOpenSize.height) }
    static var pillOpenSize: NSSize { pillSize(dots: 5) }  // the most dots the pill shows at rest

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
        pinDot = Self.dotButton(index: 2, name: "Pin level")
        allDot = Self.dotButton(index: 2, name: "All notes")
        allDot.image = Self.symbolDot("rectangle.stack.fill")
        revealDot = Self.dotButton(index: 2, name: "Open where it lives")
        revealDot.image = Self.symbolDot("arrow.up.forward.app.fill")
        backDot = Self.dotButton(index: 0, name: "Back to the note")
        backDot.image = Self.symbolDot("arrow.down.right.and.arrow.up.left")
        deleteDot = Self.dotButton(index: 2, name: "Delete note")
        deleteDot.image = Self.symbolDot(
            "trash.fill", fill: Swatch.color(fromHex: Self.deleteHex), ink: .white)
        super.init()

        // One click is the whole gesture for each. Hidden until the pill opens — the clip only
        // hides them from view, and a dot outside the closed pill would still take clicks.
        for dot in [fontDot, colorDot, pinDot, allDot, revealDot, backDot, deleteDot] {
            dot.isHidden = true
            view.addSubview(dot)
        }
        backDot.target = self
        backDot.action = #selector(collapseTapped)
        revealDot.target = self
        revealDot.action = #selector(revealTapped)
        allDot.target = self
        allDot.action = #selector(openAll)
        pinDot.target = self
        pinDot.action = #selector(pickPin)
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
                // Only the resting dots follow the cursor away. A picker is a question already
                // asked: it stays up until it's answered, or until a click on the card drops it —
                // but whatever it was previewing goes back.
                endPreview()
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

    /// Put the note's own face or colour back over a hover preview. No-op when nothing is
    /// previewed, so a plain open and close never re-renders the text.
    private func endPreview() {
        guard previewing else { return }
        previewing = false
        switch mode {
        case .font: onFont(styler.family, false)
        case .color: onColor(Swatch.color(fromHex: styler.colorHex), false)
        default: break
        }
    }

    /// The levels the shown note can be pinned at, and the one it is at now. Pushed on every
    /// show and after every move, always while the picker is shut, so nothing needs redrawing.
    func setPinLevels(_ choices: [PinChoice], current: Int) {
        pinChoices = choices
        pinCurrent = current
        // Like the font and colour dots, the pin dot wears what is chosen: the current level.
        let chosen = choices.first { $0.level == current }
        pinDot.image = chosen.map { Self.symbolDot($0.symbol) }
        pinDot.toolTip = chosen?.label
        // Placed now, unanimated: the window is reused, and a delete dot left one slot over by
        // the previous note would otherwise slide into place the first time the pill opens.
        for (i, dot) in restingDots.enumerated() { dot.frame = Self.dotFrame(index: i) }
    }

    /// The dots the open pill shows at rest. Laid out by position in this list, so the delete
    /// dot simply sits one place further left of the corner when the pin dot is there.
    private var restingDots: [NSButton] {
        if isDashboard { return [backDot] }
        return [fontDot, colorDot] + (pinChoices.count > 1 ? [pinDot] : [])
            + (onOpenAll != nil ? [allDot] : []) + (onReveal != nil ? [revealDot] : []) + [deleteDot]
    }

    /// A dot wearing an SF Symbol: white with a grey glyph for the pin level and its picker, red
    /// with a white bin for delete. The glyph is centred by its ink — see `drawInkCentered`.
    static func symbolDot(
        _ name: String, borderWidth: CGFloat = 1,
        fill: NSColor = NSColor.white.withAlphaComponent(0.75),
        ink: NSColor = NSColor.black.withAlphaComponent(0.65)
    ) -> NSImage {
        let size = dotSize
        let config = NSImage.SymbolConfiguration(pointSize: size - 8, weight: .semibold)
            .applying(.init(paletteColors: [ink]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2))
            fill.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            circle.lineWidth = borderWidth
            circle.stroke()
            symbol?.drawInkCentered(in: rect)
            return true
        }
    }

    /// The two dots that wear the current choice. Full strength on the colour one: it's the
    /// colour's label, not another sheer wash of it. Refreshed whenever the resting dots are
    /// about to be shown, so they always arrive current.
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
        case .open: return restingDots
        case .font, .color, .pin: return choiceDots
        }
    }

    /// Lay the row of dots out and size the capsule around it — every dot is the same circle,
    /// so `pillSize` is the one place that arithmetic lives.
    ///
    /// The capsule grows leftwards (`maxX` fixed), so opening it pushes its left edge out and
    /// every dot's right edge stays put. That's what keeps the cursor on the dot it just opened.
    private func layout() {
        let shown = shownDots()
        for (i, dot) in shown.enumerated() { dot.animator().frame = Self.dotFrame(index: i) }
        let width = shown.isEmpty ? Self.pillClosedSize.width : Self.pillSize(dots: shown.count).width
        let frame = view.frame
        view.animator().frame = NSRect(
            x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }

    /// Move the pill to `mode`, growing it leftwards from its right edge so the corner it's
    /// parked in stays put. Whatever the mode shows is just an ordered list of dots, so one
    /// width and one layout serve the three dots and both pickers alike.
    private func set(_ mode: Mode, animated: Bool = true) {
        guard mode != self.mode else { return }
        endPreview()  // read against the mode being left, before it changes
        self.mode = mode
        let spent = choiceDots  // the picker dots the previous mode built; dropped once faded out
        switch mode {
        case .closed, .open: choiceDots = []
        case .font: choiceDots = fontChoices()
        case .color: choiceDots = colorChoices()
        case .pin: choiceDots = pinDots()
        }
        choiceDots.forEach(view.addSubview)
        if mode == .open { refreshDots() }  // before they're shown, so they arrive current

        let shown = shownDots()
        let gone = spent + [fontDot, colorDot, pinDot, allDot, revealDot, backDot, deleteDot].filter { !shown.contains($0) }
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

    /// One dot per typeface, each wearing its own "T". Hovering previews the face in the note's
    /// own text, which is the thing you actually want to read it in.
    private func fontChoices() -> [NSButton] {
        NoteFont.allCases.enumerated().map { i, face in
            let b = FontChoiceButton(frame: Self.dotFrame(index: i))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(face.rawValue)
            b.toolTip = face.rawValue
            b.face = face
            b.image = face.dotImage(
                size: Self.dotSize, borderWidth: face == styler.family ? 2 : 1)
            b.target = self
            b.action = #selector(fontChosen(_:))
            b.onHover = { [weak self] inside in
                guard let self, inside else { return }  // leaving a dot keeps its preview
                previewing = true
                onFont(face, false)
            }
            return b
        }
    }

    /// One dot per palette colour. shortcut: colours past what the note is wide enough to hold
    /// are dropped, and nothing else lists them; wrap the strip onto a second row if palettes
    /// that long turn up.
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
                guard inside else { return }  // leaving a dot keeps its preview
                previewing = true
                onColor(Swatch.color(fromHex: hex), false)
            }
            b.target = self
            b.action = #selector(colorChosen(_:))
            return b
        }
    }

    /// One dot per level the note can be pinned at; the current one wears the heavier ring,
    /// like the chosen face and colour do. No hover preview: a level has nothing to show early.
    private func pinDots() -> [NSButton] {
        pinChoices.enumerated().map { i, choice in
            let b = Self.dotButton(index: i, name: choice.label)
            b.image = Self.symbolDot(choice.symbol, borderWidth: choice.level == pinCurrent ? 2 : 1)
            b.tag = choice.level
            b.target = self
            b.action = #selector(pinChosen(_:))
            return b
        }
    }

    // MARK: - Actions

    @objc private func pickFont() { set(.font) }
    @objc private func pickColor() { set(.color) }
    @objc private func pickPin() { set(.pin) }

    @objc private func pinChosen(_ sender: NSButton) {
        onPin(sender.tag)
        set(.open)
    }
    @objc private func deleteTapped() { onDelete() }
    @objc private func openAll() { onOpenAll?() }
    @objc private func collapseTapped() { onCollapse() }
    @objc private func revealTapped() { onReveal?() }

    @objc private func fontChosen(_ sender: NSButton) {
        guard let choice = sender as? FontChoiceButton else { return }
        previewing = false  // a commit is not a preview to put back
        onFont(choice.face, true)
        set(.open)
    }

    @objc private func colorChosen(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        previewing = false  // a commit is not a preview to put back
        onColor(Swatch.color(fromHex: swatch.hex), true)
        set(.open)
    }
}
