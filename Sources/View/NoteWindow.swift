import AppKit

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Clicking a checkbox glyph ticks it; every other click is an ordinary click.
private final class MarkdownTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let ns = string as NSString
        // A click on the glyph can resolve to either side of it, so check both insertion sides.
        for cand in [i, i - 1] where cand >= 0 && cand < ns.length {
            let ch = ns.substring(with: NSRange(location: cand, length: 1))
            if ch == "\u{2610}" || ch == "\u{2611}" { toggleCheckbox(at: cand); return }
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at i: Int) {
        guard let ts = textStorage else { return }
        let becomingDone = (ts.string as NSString).substring(with: NSRange(location: i, length: 1)) == "\u{2610}"
        let box = NSRange(location: i, length: 1)
        // shouldChangeText/didChangeText registers the undo *and* posts the change notification.
        guard shouldChangeText(in: box, replacementString: becomingDone ? "\u{2611}" : "\u{2610}") else { return }
        ts.replaceCharacters(in: box, with: becomingDone ? "\u{2611}" : "\u{2610}")
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
    var contextMenu: (() -> NSMenu?)?  // right-click on the card: palette editing and pin level
    // nil unless a drag actually began on the glass. A mouseDragged with no grab is one that
    // bubbled up the responder chain — e.g. a checkbox click in the text view, whose mouseDown we
    // handled without consuming the gesture. Acting on it would drag the note with a stale offset,
    // so it's ignored: the glass only moves the note for drags it started itself.
    private var grab: NSPoint?

    override func mouseDown(with event: NSEvent) {
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

/// One reusable floating post-it. Follows the tracked window by keeping a fixed offset (dx, dy)
/// from its top-left; dragging the note updates and persists that offset.
final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: KeyableWindow
    private let tintView: NSView  // the palette colour, sheer, over the glass
    private let textView: NSTextView
    private let colorDot: NSButton  // wears the note's colour; each click takes the next one
    private let deleteDot: NSButton  // red: deletes the note
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

    private static let dotSize: CGFloat = 13
    private static let deleteHex = "FF5F57"  // the red of a window's close button

    private static func dotButton(x: CGFloat, y: CGFloat, name: String) -> NSButton {
        let b = NSButton(frame: NSRect(x: x, y: y, width: dotSize, height: dotSize))
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.setAccessibilityLabel(name)
        b.toolTip = name
        b.autoresizingMask = [.minYMargin, .minXMargin]  // stays top-right on resize
        return b
    }

    override init() {
        let w = NotePreferences.shared.defaultSize.width
        let h = NotePreferences.shared.defaultSize.height
        let strip: CGFloat = 28
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

        // Editable text, below the top drag strip.
        let scroll = NSScrollView(frame: NSRect(x: 4, y: 4, width: w - 8, height: h - strip - 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]
        textView = MarkdownTextView(frame: scroll.bounds)
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

        // Two dots, top-right: the first wears the note's colour and steps through the palette on
        // each click, the red one at the corner deletes the note. The rarer choices (editing the palette, the pin level) are a
        // right-click on the card — one click has to be the whole gesture for the common ones.
        let dot = Self.dotSize
        colorDot = Self.dotButton(x: w - 8 - dot * 2 - 6, y: h - 8 - dot, name: "Next colour")
        glass.addSubview(colorDot)
        deleteDot = Self.dotButton(x: w - 8 - dot, y: h - 8 - dot, name: "Delete note")
        deleteDot.image = Swatch.image(hex: Self.deleteHex, size: dot, radius: dot / 2)
        glass.addSubview(deleteDot)

        window.contentView = glass
        super.init()
        glass.onDrag = { [weak self] origin in self?.dragTo(origin: origin) }
        glass.contextMenu = { [weak self] in self?.buildMenu() }
        window.delegate = self
        textView.delegate = self
        colorDot.target = self
        colorDot.action = #selector(cycleColor)
        deleteDot.target = self
        deleteDot.action = #selector(deleteTapped)
        applyTint(Swatch.color(fromHex: colorHex))  // one source of truth for the default yellow
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

    /// The colour dot: step to the next palette colour. No menu — one click, one colour.
    @objc private func cycleColor() {
        apply(
            color: Swatch.color(
                fromHex: Swatch.next(after: colorHex, in: NotePreferences.shared.palette)))
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
        // Load markdown as rich text (markers consumed into attributes). Programmatic, so it
        // fires no textDidChange — nothing to save, and no input rule should run on a load.
        textView.textStorage?.setAttributedString(MarkdownDocument.parse(note.text))
        textView.typingAttributes = MarkdownStyle.base
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

    /// Enter starts a body line; Backspace at a heading's start un-headings it. Everything else
    /// falls through to the text view's own handling.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        MarkdownInput.handle(selector, textView)
    }

    private func scheduleSave() {
        // Serialize the rich text back to markdown — the buffer has no markers, disk does.
        let text = textView.textStorage.map(MarkdownDocument.serialize) ?? textView.string
        let note = Note(
            text: text, dx: dx, dy: dy, color: colorHex,
            w: Double(desired.width), h: Double(desired.height))  // intended size, not the capped one
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        let save = saveHandler
        saver.call { save(note) }
    }
}
