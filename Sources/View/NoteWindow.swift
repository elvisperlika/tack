import AppKit

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Clicking a checkbox glyph ticks it; every other click is an ordinary click. Also owns block
/// mode: Esc steps out of the text and selects the block the caret was in, ↑/↓ walk between
/// blocks, Enter drops back into one. A text view has no idea what a block is, so the selection
/// is drawn here rather than being a text selection.
private final class MarkdownTextView: NSTextView {
    var onPress: (() -> Void)?

    /// The selected block's paragraph range, or nil while editing. Nil is the normal state.
    private var selectedBlock: NSRange?

    private static let blockHighlight = NSColor.black.withAlphaComponent(0.07)  // a light grey wash

    // MARK: - Block mode

    /// Esc from editing selects the caret's block; Esc again, a click or typing leaves the mode.
    /// `doCommand(by:)` rather than the delegate hook, so block mode sees keys before the
    /// markdown rules do — in this mode ↑/↓ and Enter mean something else entirely.
    override func doCommand(by selector: Selector) {
        guard !handleBlockCommand(selector) else { return }
        super.doCommand(by: selector)
    }

    private func handleBlockCommand(_ selector: Selector) -> Bool {
        let ns = string as NSString
        guard let block = selectedBlock else {
            guard selector == #selector(cancelOperation(_:)) else { return false }
            selectBlock(Blocks.range(in: ns, at: selectedRange().location))
            return true
        }
        switch selector {
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let delta = selector == #selector(moveUp(_:)) ? -1 : 1
            if let next = Blocks.step(from: block, by: delta, in: ns) { selectBlock(next) }
        case #selector(insertNewline(_:)):
            editBlock(at: Blocks.contentEnd(block, in: ns))
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            deleteBlock(block)
        case #selector(cancelOperation(_:)):
            editBlock(at: selectedRange().location)
        default: break  // every other key is inert while a block is selected
        }
        return true
    }

    /// Canc removes the selected block and stays in block mode, selecting the one above — or
    /// whatever slides up into its place, when it was the first. Deleting is a block gesture, so
    /// it shouldn't drop you back into the text. Through shouldChangeText, so ⌘Z brings it back.
    private func deleteBlock(_ block: NSRange) {
        guard let ts = textStorage else { return }
        let ns = string as NSString
        // Measured before the text moves: the block above keeps its location whatever happens
        // below it, and when there is no block above, what follows slides up to the start.
        let landing = Blocks.step(from: block, by: -1, in: ns)?.location ?? 0
        var range = block
        // The last block has no newline of its own, so it takes the one that separates it from the
        // block above — otherwise deleting it would leave an empty block behind.
        if range.location + range.length == ns.length, range.location > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        ts.deleteCharacters(in: range)
        didChangeText()
        selectBlock(Blocks.range(in: string as NSString, at: landing))
    }

    private func selectBlock(_ range: NSRange) {
        selectedBlock = range
        scrollRangeToVisible(range)
        insertionPointColor = .clear  // the block is the selection now; a caret would be a second one
        needsDisplay = true
    }

    /// Back to editing, caret at `location`. Safe to call when no block is selected.
    func editBlock(at location: Int) {
        selectedBlock = nil
        insertionPointColor = MarkdownStyle.textColor
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        needsDisplay = true
    }

    /// Typing with a block selected drops into it and appends, rather than doing nothing.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let block = selectedBlock {
            editBlock(at: Blocks.contentEnd(block, in: self.string as NSString))
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rect = selectedBlock.flatMap(blockRect) {
            Self.blockHighlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    /// The selected block's wash: as tall as its lines (paragraph spacing excluded, so the gap
    /// between blocks stays a gap) and as wide as the note.
    private func blockRect(_ block: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let ns = string as NSString
        let safe = NSIntersectionRange(block, NSRange(location: 0, length: ns.length))
        var box = NSRect.zero
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)) {
            _, used, _, _, _ in
            box = box.isEmpty ? used : box.union(used)
        }
        if box.isEmpty { box = lm.extraLineFragmentUsedRect }  // the document's final empty block
        guard box.height > 0 else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: 2, y: box.minY + origin.y - 2, width: bounds.width - 4, height: box.height + 4)
    }

    // MARK: - Checkboxes

    override func mouseDown(with event: NSEvent) {
        onPress?()
        editBlock(at: selectedRange().location)  // a click is always editing
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let ts = textStorage else { return }
        // A click on the attachment can resolve to either insertion side.
        for cand in [i, i - 1] where cand >= 0 && cand < ts.length {
            if let glyph = ListGlyph.at(ts, cand), glyph != .bullet {
                toggleCheckbox(at: cand, glyph: glyph)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at i: Int, glyph: ListGlyph) {
        guard let ts = textStorage else { return }
        let becomingDone = glyph == .todoOpen
        let replacement = (becomingDone ? ListGlyph.todoDone : .todoOpen)
            .symbol(attributes: MarkdownStyle.base)
        let box = NSRange(location: i, length: 1)
        // shouldChangeText/didChangeText registers the undo *and* posts the change notification.
        guard shouldChangeText(in: box, replacementString: replacement.string) else { return }
        ts.replaceCharacters(in: box, with: replacement)
        didChangeText()

        // Strike / un-strike the item's content to match the new state.
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        let contentLen = line.length - ListGlyph.width - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
        guard contentLen > 0 else { return }
        let range = NSRange(location: line.location + ListGlyph.width, length: contentLen)
        if becomingDone {
            MarkdownDocument.strikeThrough(ts, range)
        } else {
            ts.removeAttribute(.strikethroughStyle, range: range)
            ts.addAttribute(.foregroundColor, value: MarkdownStyle.textColor, range: range)
        }
    }

    // ⌘B / ⌘I reach here through the responder chain from the invisible Edit menu (the text view
    // is first responder). Target-nil menu items find these on whatever text view is focused.
    @objc func toggleBold(_ sender: Any?) { MarkdownInput.toggle(.bold, self) }
    @objc func toggleItalic(_ sender: Any?) { MarkdownInput.toggle(.italic, self) }
}

/// Drags the note itself instead of isMovableByWindowBackground: the clamp applies *before*
/// each move, so the note stops dead at the tracked window's border — AppKit's own drag moved
/// it out first and let the delegate snap it back, which flickered at the edge.
private final class DragGlassView: NSVisualEffectView {
    var onDrag: ((NSPoint) -> Void)?  // proposed window origin, Cocoa coords
    var onPress: (() -> Void)?  // a click anywhere on the card: dismisses an open picker
    var contextMenu: (() -> NSMenu?)?  // right-click on the card: palette editing and pin level
    // nil unless a drag actually began on the glass. A mouseDragged with no grab is one that
    // bubbled up the responder chain — e.g. a checkbox click in the text view, whose mouseDown we
    // handled without consuming the gesture. Acting on it would drag the note with a stale offset,
    // so it's ignored: the glass only moves the note for drags it started itself.
    private var grab: NSPoint?

    override func mouseDown(with event: NSEvent) {
        onPress?()
        guard let origin = window?.frame.origin else { return }
        let mouse = NSEvent.mouseLocation
        grab = NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let mouse = NSEvent.mouseLocation
        onDrag?(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) { grab = nil }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

/// The control pill, which is a bare glass dot until the cursor reaches it. `.activeAlways`
/// because Tack is an agent: the note is almost never in the active app, and the default
/// `.activeInKeyWindow` would only track after a click. `.inVisibleRect` re-fits the area to
/// the bounds for free, which matters because those bounds are exactly what hovering changes.
private final class HoverPill: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One face in the font picker. At rest it's the same dot as everything else in the pill; under
/// the cursor it opens out to spell "Tack" in its own face, which is the only way to see what
/// you're picking before you pick it. Its width *is* its image's, so there's no second
/// measurement to keep in step with what's drawn.
private final class FontChoiceButton: NSButton {
    var face = NoteFont.sans
    var onHover: ((Bool) -> Void)?
    var narrow = NSImage()
    var wide = NSImage()
    var expanded = false { didSet { image = expanded ? wide : narrow } }
    var width: CGFloat { (expanded ? wide : narrow).size.width }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One reusable floating post-it. Follows the tracked window by keeping a fixed offset (dx, dy)
/// from its top-left; dragging the note updates and persists that offset.
final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: KeyableWindow
    private let tintView: NSView  // the palette colour, sheer, over the glass
    private let textView: MarkdownTextView
    private let fontDot: NSButton  // wears an "A" in the note's face; opens the face picker
    private let colorDot: NSButton  // wears the note's colour; opens the palette picker
    private let deleteDot: NSButton  // red: deletes the note
    private let pill: HoverPill  // holds the three dots; a bare dot until hovered
    /// What the pill is showing. `.font` / `.color` are the picker: the pill widens and the three
    /// dots give way to the choices, which is why this is a mode and not a bool.
    private enum PillMode { case closed, open, font, color }
    private var pillMode = PillMode.closed
    private var choiceDots: [NSButton] = []  // the picker's dots, built per opening
    private var reforming = false  // guards the input rules' own edits from re-entering textDidChange
    private lazy var paletteMenu = PaletteMenu { [weak self] in self?.apply(color: $0) }

    /// The pin levels the note can move between, pushed by the controller so NoteWindow stays
    /// ignorant of Container — the same split as the colour menu, which owns *how* one is chosen
    /// while the controller owns what it *means*.
    private var pinChoices: [(level: Int, label: String)] = []
    private var pinCurrent = 0
    private var onPickLevel: (Int) -> Bool = { _ in true }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    private var colorHex = NotePreferences.shared.defaultColorHex
    private var family = NoteFont.sans
    private var saveHandler: (Note) -> Bool = { _ in true }  // persists or reports failure
    /// The tracked window, top-left screen coords. One value, because its origin and size only
    /// ever change together — three loose fields drifting apart was a bug waiting to happen.
    private var tracked = CGRect.zero
    private var dx = 20.0
    private var dy = 40.0
    /// The size the note wants to be. The shown size is this capped to the tracked window, so a
    /// note never spills outside the window it's pinned to — and restores when the window grows.
    private var desired = NotePreferences.shared.defaultSize
    private var isProgrammaticMove = false
    private var active = false  // current folder has a note to show
    private var occluded = false  // the note's spot on the Finder window is covered
    private var shown = false  // what the last pop animated toward (the window stays visible while popping out)

    /// Rounds the *material*. A .behindWindow blur is shaped by the window server from this
    /// mask's alpha, not by the layer, so `cornerRadius` alone leaves a square pane of frost
    /// (and a square shadow) around the rounded card. Stretchable, because the note resizes:
    /// the cap insets pin the corners and the 1pt middle takes the stretch.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Bigger dots in the same pill: the padding and the gap give up what the dots take, so the
    // capsule stays 20pt tall and ~60 wide open.
    private static let dotSize: CGFloat = 16
    private static let dotGap: CGFloat = 4
    private static let pillPad = NSSize(width: 5, height: 3)
    private static let deleteHex = "FF5F57"  // the red of a window's close button

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

    static let pillInset: CGFloat = 6  // gap between the pill and the card's top-right corner

    /// Closed, the pill is a circle — same height, so the `height / 2` corner radius rounds it
    /// the whole way with no second radius to keep in sync.
    static var pillClosedSize: NSSize { NSSize(width: pillOpenSize.height, height: pillOpenSize.height) }
    static var pillOpenSize: NSSize { pillSize(dots: 3) }

    /// One control cluster instead of three things scattered over the card, parked in the
    /// top-right corner. At rest it's a bare glass dot; the cursor reaching it opens it leftwards
    /// (`setPill`) to uncover the three dots. It *floats* over the text either way, the way iOS's
    /// new bars do — the note's own words blur under it, so nothing is carved out for it.
    private static func pillView(width: CGFloat, height: CGFloat) -> HoverPill {
        let size = pillClosedSize
        let v = HoverPill(
            frame: NSRect(
                x: width - pillInset - size.width, y: height - pillInset - size.height,
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

    override init() {
        let w = NotePreferences.shared.defaultSize.width
        let h = NotePreferences.shared.defaultSize.height
        let strip: CGFloat = 18  // top drag handle; the pill parks in its right corner
        let radius: CGFloat = 12
        // .resizable on a borderless window gets edge-dragging from AppKit for free — no grow
        // box, no drag tracking of our own.
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.minSize = NotePreferences.shared.minSize
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear  // the rounded glass card below is the whole background
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // ponytail: can't query a window's Space via public API, so the note binds to the
        // desktop that's active when its folder becomes frontmost, and stays there.
        window.collectionBehavior = [.moveToActiveSpace]

        // Rounded glass card: a blur of whatever sits behind the note, with the palette colour
        // as a sheer tint over it. The bare tint is the drag area.
        // ponytail: NSVisualEffectView is the glass this deployment target has — Apple's Liquid
        // Glass (NSGlassEffectView) is macOS 26+, and Tack targets 13. Material is taste.
        let glass = DragGlassView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        glass.material = .popover
        glass.blendingMode = .behindWindow  // blur what's behind the note, not what's inside it
        glass.state = .active  // stay frosted while the note isn't key, which is most of the time
        glass.appearance = NSAppearance(named: .aqua)  // a light card with black text, even in dark mode
        glass.maskImage = Self.roundedMask(radius: radius)  // rounds the material — see above
        glass.wantsLayer = true
        glass.layer?.cornerRadius = radius  // rounds the tint and text on top of it
        glass.layer?.masksToBounds = true

        // The palette colour lives here rather than on the glass: NSVisualEffectView owns its
        // own layer's drawing, so a tint of our own needs a view of its own.
        tintView = NSView(frame: glass.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        glass.addSubview(tintView)

        // Editable text: the full card below the drag strip.
        // ponytail: no inset for the pill — closed it's a dot in a corner and the text is meant to
        // blur under it; reserving a line's worth of space for it on every note costs more.
        let scroll = NSScrollView(frame: NSRect(x: 4, y: 4, width: w - 8, height: h - strip - 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]
        scroll.automaticallyAdjustsContentInsets = false
        textView = MarkdownTextView(frame: scroll.bounds)
        _ = textView.layoutManager  // block mode measures line fragments: take TextKit 1 now, not mid-draw
        textView.drawsBackground = false
        textView.font = MarkdownStyle.baseFont
        textView.textColor = .black
        textView.isRichText = true  // emphasis rides as attributes; markdown lives only on disk
        textView.isAutomaticTextReplacementEnabled = false  // no smart quotes/dashes mangling markdown
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.allowsUndo = true  // off by default — without it ⌘Z reaches an empty undo stack
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        glass.addSubview(scroll)

        // The three dots, left to right: the note's typeface, its colour, and red for delete. One
        // click is the whole gesture for each; the rarer choices (editing the palette, the pin
        // level) are a right-click on the card. Hidden until the pill opens — the clip only hides
        // them from view, and a dot outside the closed pill would still take clicks.
        pill = Self.pillView(width: w, height: h)
        fontDot = Self.dotButton(index: 0, name: "Font")
        colorDot = Self.dotButton(index: 1, name: "Colour")
        deleteDot = Self.dotButton(index: 2, name: "Delete note")
        deleteDot.image = Swatch.image(hex: Self.deleteHex, size: Self.dotSize, radius: Self.dotSize / 2)
        for dot in [fontDot, colorDot, deleteDot] {
            dot.isHidden = true
            pill.addSubview(dot)
        }
        glass.addSubview(pill)

        window.contentView = glass
        super.init()
        glass.onDrag = { [weak self] origin in self?.dragTo(origin: origin) }
        glass.onPress = { [weak self] in self?.setPill(.closed) }  // the picker's way out
        textView.onPress = { [weak self] in self?.setPill(.closed) }
        glass.contextMenu = { [weak self] in self?.buildMenu() }
        window.delegate = self
        textView.delegate = self
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
        pill.onHover = { [weak self] inside in
            guard let self else { return }
            if !inside {
                // Only the bare three dots follow the cursor away. A picker is a question already
                // asked: it stays up until it's answered, or until a click on the card drops it.
                if pillMode == .open { setPill(.closed) }
            } else if pillMode == .closed {
                setPill(.open)
            }
        }
        applyTint(Swatch.color(fromHex: colorHex))  // one source of truth for the default colour
        fontDot.image = family.dotImage(size: Self.dotSize)
        window.invalidateShadow()
    }

    // MARK: - Note menu

    /// The scopes this note can pin to. The controller pushes them (with the current one) on
    /// every show; `< 2` means nothing to choose, so the menu skips the pin section — matching
    /// Finder, which has one level.
    func setPinLevels(
        _ choices: [(level: Int, label: String)], current: Int,
        onPick: @escaping (Int) -> Bool
    ) {
        pinChoices = choices
        pinCurrent = current
        onPickLevel = onPick
    }

    /// What the dots don't cover, on right-click: the palette itself (add / remove a colour) and
    /// the pin level. Rebuilt per open so both are always current.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.image = Swatch.image(hex: colorHex)
        color.submenu = paletteMenu.menu(currentHex: colorHex)
        menu.addItem(color)
        if pinChoices.count >= 2 {
            let pin = NSMenuItem(title: "Pin", action: nil, keyEquivalent: "")
            pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin level")
            let sub = NSMenu()
            for choice in pinChoices {
                let item = NSMenuItem(
                    title: choice.label, action: #selector(levelChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = choice.level
                item.state = choice.level == pinCurrent ? .on : .off
                sub.addItem(item)
            }
            pin.submenu = sub
            menu.addItem(pin)
        }
        return menu
    }

    @objc private func levelChosen(_ sender: NSMenuItem) {
        guard saver.flush() else { return }  // never move an older version after a failed save
        guard onPickLevel(sender.tag) else { return }
        pinCurrent = sender.tag
    }

    // MARK: - Pill

    /// Move the pill to `mode`, growing it leftwards from its right edge so the corner it's
    /// parked in stays put. Whatever the mode shows is just an ordered list of dots, so one
    /// width and one layout serve the three dots and both pickers alike.
    /// What the current mode puts in the pill, left to right.
    private func shownDots() -> [NSButton] {
        switch pillMode {
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
    private func layoutPill() {
        let shown = shownDots()
        var x = Self.pillPad.width
        for dot in shown {
            let w = (dot as? FontChoiceButton)?.width ?? Self.dotSize
            dot.animator().frame = NSRect(x: x, y: Self.pillPad.height, width: w, height: Self.dotSize)
            x += w + Self.dotGap
        }
        let width = shown.isEmpty ? Self.pillClosedSize.width : x - Self.dotGap + Self.pillPad.width
        let frame = pill.frame
        pill.animator().frame = NSRect(
            x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }

    private func setPill(_ mode: PillMode, animated: Bool = true) {
        guard mode != pillMode else { return }
        pillMode = mode
        let spent = choiceDots  // the picker dots the previous mode built; dropped once faded out
        switch mode {
        case .closed, .open: choiceDots = []
        case .font: choiceDots = fontChoices()
        case .color: choiceDots = colorChoices()
        }
        choiceDots.forEach(pill.addSubview)

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
                layoutPill()
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
            let borderWidth: CGFloat = face == family ? 2 : 1
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
                renderFamily(inside ? face : family)
                // Slower than the pill's own 0.14, and on a long tail rather than easeOut: this
                // one you're meant to *read* — the word unrolling is the preview.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    self.layoutPill()
                }
            }
            return b
        }
    }

    /// One dot per palette colour. ponytail: colours past what the note is wide enough to hold are
    /// dropped — the right-click grid is the full palette, and it scrolls with the menu.
    private func colorChoices() -> [NSButton] {
        let room = Self.pillDots(fitting: pill.superview?.bounds.width ?? window.frame.width)
        return NotePreferences.shared.palette.prefix(room).enumerated().map { i, hex in
            let b = ColorSwatchButton(frame: Self.dotFrame(index: i))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(hex)
            b.hex = hex
            b.image = Swatch.image(
                hex: hex, size: Self.dotSize, radius: Self.dotSize / 2,
                borderWidth: hex == colorHex ? 2 : 1)
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
                applyTint(Swatch.color(fromHex: inside ? hex : colorHex))
            }
            b.target = self
            b.action = #selector(colorChosen(_:))
            return b
        }
    }

    @objc private func pickFont() { setPill(.font) }
    @objc private func pickColor() { setPill(.color) }

    @objc private func fontChosen(_ sender: NSButton) {
        guard let choice = sender as? FontChoiceButton else { return }
        family = choice.face
        applyFamily()
        scheduleSave()
        setPill(.open)
    }

    @objc private func colorChosen(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        apply(color: Swatch.color(fromHex: swatch.hex))
        setPill(.open)
    }

    // MARK: - Colour

    /// How much of the palette colour sits over the blur. The material underneath (.popover)
    /// is already milky, so anything much past ~0.35 buries the blur and the card reads as
    /// solid pastel — which is exactly what it shipped as at 0.6, and why this is low now.
    private static let tintAlpha: CGFloat = 0.35

    private func applyTint(_ color: NSColor) {
        tintView.layer?.backgroundColor = color.withAlphaComponent(Self.tintAlpha).cgColor
        // Full strength on the dot: it's the colour's label, not another sheer wash of it.
        colorDot.image = Swatch.image(
            hex: Swatch.hex(from: color), size: Self.dotSize, radius: Self.dotSize / 2)
    }

    /// The chosen colour lands here (from a swatch click or live from the system panel):
    /// remember it, show it, persist it.
    private func apply(color: NSColor) {
        colorHex = Swatch.hex(from: color)
        applyTint(color)
        scheduleSave()
    }

    /// Re-render the buffer in the current face: markdown out, family set, markdown back in. The
    /// round trip is the one `show` already does, and `--selftest` asserts it's lossless — mapping
    /// every run's font by hand would be the same result with more ways to get it wrong.
    private func applyFamily() {
        let caret = textView.selectedRange().location
        renderFamily(family)
        textView.editBlock(at: caret)  // also drops any block selection, whose rect just moved
    }

    /// Preview and commit share the exact same rendering path; only `family` itself is persisted,
    /// so leaving a choice can restore it without ever scheduling a save.
    private func renderFamily(_ face: NoteFont) {
        MarkdownStyle.family = face
        fontDot.image = face.dotImage(size: Self.dotSize)
        guard let ts = textView.textStorage else { return }
        // No `textView.font =` here: that setter rewrites the font of *all* the text, wiping the
        // heading, bold and code runs the parse just laid down.
        ts.setAttributedString(MarkdownDocument.parse(MarkdownDocument.serialize(ts)))
        textView.typingAttributes = MarkdownStyle.base
        MarkdownInput.syncTypingToBlock(textView)
    }

    // MARK: - Show / hide

    /// A single click on the red dot is the whole delete gesture, so a note with text asks first.
    private func confirmDelete() -> Bool {
        guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this note?"
        alert.informativeText = "Its text will be lost."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func deleteTapped() {
        guard confirmDelete() else { return }
        let deletion = Note(text: "", dx: dx, dy: dy, color: colorHex)
        guard saveHandler(deletion) else { return }
        saver.cancel()  // a stale delayed save must not recreate the successfully deleted note
        active = false
        applyVisibility()
        onDelete?()
    }

    /// Show `note`, positioned relative to the tracked window's top-left; `save` persists edits.
    @discardableResult
    func show(note: Note, bounds: CGRect, save: @escaping (Note) -> Bool) -> Bool {
        guard saver.flush() else { return false }
        self.saveHandler = save
        self.dx = note.dx
        self.dy = note.dy
        self.tracked = bounds
        active = true
        occluded = false  // re-evaluated on the next tracking frame
        colorHex = note.color ?? NotePreferences.shared.defaultColorHex
        applyTint(Swatch.color(fromHex: colorHex))
        family = note.font.flatMap(NoteFont.init(rawValue:)) ?? .sans
        MarkdownStyle.family = family  // set before the parse below: it bakes the fonts in
        fontDot.image = family.dotImage(size: Self.dotSize)
        setPill(.closed, animated: false)  // the window is reused: never arrive already open
        // Load markdown as rich text (markers consumed into attributes). Programmatic, so it
        // fires no textDidChange — nothing to save, and no input rule should run on a load.
        textView.editBlock(at: 0)  // the window is reused: never carry a block selection over
        textView.textStorage?.setAttributedString(MarkdownDocument.parse(note.text))
        textView.typingAttributes = MarkdownStyle.base
        MarkdownInput.syncTypingToBlock(textView)  // a note that opens on a heading types as one
        desired = NSSize(
            width: note.w ?? NotePreferences.shared.defaultSize.width,
            height: note.h ?? NotePreferences.shared.defaultSize.height)
        applyPosition()  // sizes the note (capped to the tracked window) and positions it
        // Switching between two notes reuses this one window, so pop unconditionally rather than
        // going through applyVisibility — otherwise the incoming note would just teleport in.
        shown = true
        popIn()
        return true
    }

    /// Hide when another window covers the note's spot on the Finder window (and vice versa).
    func setOccluded(_ value: Bool) {
        guard value != occluded else { return }
        occluded = value
        applyVisibility()
    }

    /// The note's on-screen rect in top-left screen coords, for occlusion tests.
    func screenRectTopLeft() -> CGRect {
        let f = window.frame
        return CGRect(
            x: f.minX, y: Screens.primaryHeight() - f.maxY, width: f.width, height: f.height)
    }

    private func applyVisibility() {
        let visible = active && !occluded
        guard visible != shown else { return }  // already going the right way
        shown = visible
        if visible { popIn() } else { popOut() }
    }

    func hide() {
        active = false
        applyVisibility()
    }

    /// The process may terminate before the debounce delay expires.
    @discardableResult func flushPendingSave() -> Bool { saver.flush() }

    func focusForEditing() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    // MARK: - Pop animation

    private static let popDuration = 0.16

    /// Scales the card about its centre. The window frame is left alone — the 60fps tracker owns
    /// it, and animating the frame would fight it — so the pop lives on the content layer instead.
    private func popScale(from: Double, to: Double, curve: CAMediaTimingFunctionName) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = to
        scale.duration = Self.popDuration
        scale.timingFunction = CAMediaTimingFunction(name: curve)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        window.contentView?.layer?.add(scale, forKey: "pop")
    }

    private func popIn() {
        window.alphaValue = 0
        window.orderFront(nil)
        popScale(from: 0.85, to: 1, curve: .easeOut)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.popDuration
            window.animator().alphaValue = 1
        }
    }

    private func popOut() {
        popScale(from: 1, to: 0.9, curve: .easeIn)
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Self.popDuration
                window.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, !self.shown else { return }  // popped back in mid-fade: leave it alone
                self.window.orderOut(nil)
                self.window.contentView?.layer?.removeAnimation(forKey: "pop")
                self.window.alphaValue = 1
            })
    }

    // MARK: - Geometry

    /// A display link synced to whatever display the note is on, so the caller samples the
    /// window's position in vsync phase at the real refresh rate (120Hz on ProMotion) instead
    /// of a fixed 60fps timer. Caller owns it: add to a run loop, invalidate to stop.
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        window.displayLink(target: target, selector: selector)
    }

    /// The tracked window moved or resized — keep the offset, reposition. No-op if unchanged.
    /// A resize re-clamps, so shrinking the window pulls the note back inside with it.
    func updateWindow(bounds: CGRect) {
        guard bounds != tracked else { return }
        tracked = bounds
        applyPosition()
    }

    /// Frame changes of our own must not read back as the user's: the window delegate fires
    /// either way, and this flag is what tells the two apart. A bracket rather than two bare
    /// assignments, so no early return can ever leave the flag stuck on.
    private func withProgrammaticMove(_ body: () -> Void) {
        isProgrammaticMove = true
        body()
        isProgrammaticMove = false
    }

    private func applyPosition() {
        let fit = Coord.fit(desired: desired, window: tracked.size)
        // Let the note shrink below its usual floor when the window is smaller than that floor,
        // and stop the user resizing it past the window — both keep the note inside the surface.
        window.minSize = Coord.fit(desired: NotePreferences.shared.minSize, window: tracked.size)
        window.maxSize = tracked.size
        // Display-only clamp: stored dx/dy keep the note's true spot, mirroring `desired` for
        // size. Writing the clamp back means one frame of tracking a bogus window rewrites
        // where the note lives for good. The user paths (drag, resize) clamp-and-store
        // themselves — there the border genuinely is the new position.
        let c = Coord.clamp(dx: dx, dy: dy, note: fit, window: tracked.size)
        let topLeft = Coord.cocoaTopLeft(
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            dx: c.dx, dy: c.dy, primaryHeight: Screens.primaryHeight())
        withProgrammaticMove {
            window.setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - fit.height, width: fit.width, height: fit.height),
                display: true)
        }
    }

    /// Live drag from DragGlassView: turn the proposed origin into an offset, clamp, move.
    /// The clamp runs before the frame changes, so the note is blocked at the border instead
    /// of escaping and snapping back.
    private func dragTo(origin: NSPoint) {
        (dx, dy) = Coord.offsets(
            noteMinX: Double(origin.x), noteCocoaMaxY: Double(origin.y + window.frame.height),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        storeClamped()
        applyPosition()
        scheduleSave()
    }

    /// Clamp the stored offset itself — only for user actions, where the border really is
    /// the note's new position. Programmatic tracking must never do this (see applyPosition).
    private func storeClamped() {
        let fit = Coord.fit(desired: desired, window: tracked.size)
        (dx, dy) = Coord.clamp(dx: dx, dy: dy, note: fit, window: tracked.size)
    }

    // User resized the note (drags don't land here — DragGlassView feeds dragTo directly):
    // recompute the offset from the Finder window's top-left, hold it back inside, then save.
    private func noteGeometryChanged(resized: Bool) {
        guard !isProgrammaticMove else { return }
        let f = window.frame
        (dx, dy) = Coord.offsets(
            noteMinX: Double(f.minX), noteCocoaMaxY: Double(f.maxY),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        if resized {
            // A resize stops dead at the border, like a drag does: cut the edge the user pushed
            // past it, don't slide the note over — sliding is what made the note grow out of the
            // opposite side. What survives the cut is the size the note keeps (`desired`).
            let c = Coord.contain(dx: dx, dy: dy, note: f.size, window: tracked.size)
            (dx, dy) = (c.dx, c.dy)
            desired = c.size
        } else {
            storeClamped()
        }
        applyPosition()
        scheduleSave()
    }

    func windowDidMove(_ notification: Notification) { noteGeometryChanged(resized: false) }

    /// Dragging the top or left edge moves the note's top-left corner without moving the frame's
    /// origin, so windowDidMove never fires — a resize has to recompute the offset too, not just
    /// re-clamp, or those two edges would fight the user.
    func windowDidResize(_ notification: Notification) { noteGeometryChanged(resized: true) }

    // MARK: - Text and saving

    /// Run the markdown input rules, then keep bullet/todo styling fresh. `reforming` guards the
    /// rules' own edits (which post didChangeText) from re-entering and running the rules again.
    func textDidChange(_ notification: Notification) {
        if !reforming {
            reforming = true
            MarkdownInput.autoformat(textView)
            MarkdownInput.headingRule(textView)
            MarkdownInput.listRule(textView)
            reforming = false
        }
        scheduleSave()
    }

    /// Blocks keep their style wherever you type in them: on every caret move the block under it
    /// hands its heading level to the typing attributes.
    func textViewDidChangeSelection(_ notification: Notification) {
        MarkdownInput.syncTypingToBlock(textView)
    }

    /// Enter starts a body line; Backspace at a heading's start un-headings it. Everything else
    /// falls through to the text view's own handling.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        MarkdownInput.handle(selector, textView)
    }

    private func scheduleSave() {
        // Serialize the rich text back to markdown — the buffer has no markers, disk does.
        let text = textView.textStorage.map(MarkdownDocument.serialize) ?? textView.string
        let note = Note(
            text: text, dx: dx, dy: dy, color: colorHex, font: family.rawValue,
            w: Double(desired.width), h: Double(desired.height))  // intended size, not the capped one
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        let save = saveHandler
        saver.call { save(note) }
    }
}
