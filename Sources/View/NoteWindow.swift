import AppKit

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Clicking a `[ ]` ticks it; every other click is an ordinary click.
private final class MarkdownTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let box = Markdown.todoBox(in: string, at: i) else {
            return super.mouseDown(with: event)
        }
        let ticked = (string as NSString).substring(with: box) == "[ ]" ? "[x]" : "[ ]"
        // shouldChangeText/didChangeText registers the undo *and* posts the change notification,
        // so the existing textDidChange path restyles and saves. No second save path to keep honest.
        guard shouldChangeText(in: box, replacementString: ticked) else { return }
        textStorage?.replaceCharacters(in: box, with: ticked)
        didChangeText()
    }
}

/// Drags the note itself instead of isMovableByWindowBackground: the clamp applies *before*
/// each move, so the note stops dead at the tracked window's border — AppKit's own drag moved
/// it out first and let the delegate snap it back, which flickered at the edge.
private final class DragGlassView: NSVisualEffectView {
    var onDrag: ((NSPoint) -> Void)?  // proposed window origin, Cocoa coords
    private var grab = NSPoint.zero  // mouse-to-origin offset captured at mouseDown

    override func mouseDown(with event: NSEvent) {
        guard let origin = window?.frame.origin else { return }
        let mouse = NSEvent.mouseLocation
        grab = NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        onDrag?(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }
}

/// One reusable floating post-it. Follows the tracked window by keeping a fixed offset (dx, dy)
/// from its top-left; dragging the note updates and persists that offset.
final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: KeyableWindow
    private let tintView: NSView  // the palette colour, sheer, over the glass
    private let textView: NSTextView
    private let hider = MarkerHider()  // collapses markdown markers the caret isn't on
    private let menuButton: NSButton  // the note's only button: colour, pin level, delete
    private lazy var paletteMenu = PaletteMenu { [weak self] in self?.apply(color: $0) }

    /// The pin levels the note can move between, pushed by the controller so NoteWindow stays
    /// ignorant of Container — the same split as the colour menu, which owns *how* one is chosen
    /// while the controller owns what it *means*.
    private var pinChoices: [(level: Int, label: String)] = []
    private var pinCurrent = 0
    private var onPickLevel: (Int) -> Void = { _ in }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    private var colorHex = NotePreferences.shared.defaultColorHex
    private var saveHandler: (Note) -> Void = { _ in }  // where the current note persists
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
        // Default stack, so the text view owns (and retains) its own storage/layout/container.
        // Setting `layoutManager.delegate = hider` after super.init forces TextKit 1 compatibility
        // mode, which is what makes `hider`'s shouldGenerateGlyphs hook fire.
        textView = MarkdownTextView(frame: scroll.bounds)
        textView.drawsBackground = false
        textView.font = MarkdownStyle.baseFont
        textView.textColor = .black
        textView.isRichText = false
        textView.allowsUndo = true  // off by default — without it ⌘Z reaches an empty undo stack
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        glass.addSubview(scroll)

        // The note's one button, top-right: pops the menu with colour, pin level and delete.
        menuButton = NSButton(frame: NSRect(x: w - 26, y: h - 24, width: 20, height: 20))
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Note menu")
        menuButton.contentTintColor = NSColor.black.withAlphaComponent(0.35)
        menuButton.autoresizingMask = [.minYMargin, .minXMargin]  // stays top-right on resize
        glass.addSubview(menuButton)

        window.contentView = glass
        super.init()
        textView.layoutManager?.delegate = hider  // weak; hider is retained above
        glass.onDrag = { [weak self] origin in self?.dragTo(origin: origin) }
        window.delegate = self
        textView.delegate = self
        menuButton.target = self
        menuButton.action = #selector(openMenu)
        applyTint(Swatch.color(fromHex: colorHex))  // one source of truth for the default yellow
        window.invalidateShadow()
    }

    // MARK: - Note menu

    /// The scopes this note can pin to. The controller pushes them (with the current one) on
    /// every show; `< 2` means nothing to choose, so the menu skips the pin section — matching
    /// Finder, which has one level.
    func setPinLevels(_ choices: [(level: Int, label: String)], current: Int, onPick: @escaping (Int) -> Void) {
        pinChoices = choices
        pinCurrent = current
        onPickLevel = onPick
    }

    /// Everything the note can do, behind the one button: colour, pin level, delete.
    /// Rebuilt per open so the palette and pin state are always current.
    @objc private func openMenu() {
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
        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: "Delete Note", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        delete.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete note")
        menu.addItem(delete)
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 4), in: menuButton)
    }

    @objc private func levelChosen(_ sender: NSMenuItem) {
        pinCurrent = sender.tag
        onPickLevel(sender.tag)
    }

    // MARK: - Colour

    /// How much of the palette colour sits over the blur. The material underneath (.popover)
    /// is already milky, so anything much past ~0.35 buries the blur and the card reads as
    /// solid pastel — which is exactly what it shipped as at 0.6, and why this is low now.
    private static let tintAlpha: CGFloat = 0.35

    private func applyTint(_ color: NSColor) {
        tintView.layer?.backgroundColor = color.withAlphaComponent(Self.tintAlpha).cgColor
    }

    /// The chosen colour lands here (from a swatch click or live from the system panel):
    /// remember it, show it, persist it.
    private func apply(color: NSColor) {
        colorHex = Swatch.hex(from: color)
        applyTint(color)
        scheduleSave()
    }

    // MARK: - Show / hide

    @objc private func deleteTapped() {
        saveHandler(Note(text: "", dx: dx, dy: dy, color: colorHex))  // empty text removes the note
        active = false
        applyVisibility()
        onDelete?()
    }

    /// Show `note`, positioned relative to the tracked window's top-left; `save` persists edits.
    func show(note: Note, bounds: CGRect, save: @escaping (Note) -> Void) {
        self.saveHandler = save
        self.dx = note.dx
        self.dy = note.dy
        self.tracked = bounds
        active = true
        occluded = false  // re-evaluated on the next tracking frame
        colorHex = note.color ?? NotePreferences.shared.defaultColorHex
        applyTint(Swatch.color(fromHex: colorHex))
        textView.string = note.text  // programmatic set does not fire textDidChange
        restyle()  // ...so style it here by hand
        desired = NSSize(
            width: note.w ?? NotePreferences.shared.defaultSize.width,
            height: note.h ?? NotePreferences.shared.defaultSize.height)
        applyPosition()  // sizes the note (capped to the tracked window) and positions it
        // Switching between two notes reuses this one window, so pop unconditionally rather than
        // going through applyVisibility — otherwise the incoming note would just teleport in.
        shown = true
        popIn()
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
    // recompute the offset from the Finder window's top-left, clamp it back inside, then save.
    private func noteGeometryChanged(resized: Bool) {
        guard !isProgrammaticMove else { return }
        let f = window.frame
        if resized { desired = f.size }  // the user's chosen size — kept even when a small window caps it
        (dx, dy) = Coord.offsets(
            noteMinX: Double(f.minX), noteCocoaMaxY: Double(f.maxY),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        storeClamped()
        applyPosition()
        scheduleSave()
    }

    func windowDidMove(_ notification: Notification) { noteGeometryChanged(resized: false) }

    /// Dragging the top or left edge moves the note's top-left corner without moving the frame's
    /// origin, so windowDidMove never fires — a resize has to recompute the offset too, not just
    /// re-clamp, or those two edges would fight the user.
    func windowDidResize(_ notification: Notification) { noteGeometryChanged(resized: true) }

    // MARK: - Text and saving

    /// Style the markdown where it sits. The buffer keeps every marker — they just fade — so
    /// `textView.string` stays the note's source and nothing needs serialising back.
    private func restyle() {
        guard let ts = textView.textStorage else { return }
        MarkdownStyle.apply(to: ts)
        refreshHiddenMarkers()
    }

    /// Recompute which markers collapse (it depends on the caret) and re-run glyph generation so
    /// the layout manager consults `hider` again. Cheap for a post-it; runs on edit and caret move.
    private func refreshHiddenMarkers() {
        guard let lm = textView.layoutManager, let ts = textView.textStorage else { return }
        hider.hidden = Markdown.hiddenMarkers(in: ts.string, selection: textView.selectedRange())
        let full = NSRange(location: 0, length: ts.length)
        lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
    }

    func textDidChange(_ notification: Notification) {
        restyle()
        scheduleSave()
    }

    // Caret moved: markers reveal/hide even when the text itself didn't change.
    func textViewDidChangeSelection(_ notification: Notification) {
        refreshHiddenMarkers()
    }

    private func scheduleSave() {
        let note = Note(
            text: textView.string, dx: dx, dy: dy, color: colorHex,
            w: Double(desired.width), h: Double(desired.height))  // intended size, not the capped one
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        let save = saveHandler
        saver.call { save(note) }
    }
}
