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

/// One reusable floating post-it. Follows the tracked window by keeping a fixed offset (dx, dy)
/// from its top-left; dragging the note updates and persists that offset.
final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: KeyableWindow
    private let tintView: NSView  // the palette colour, sheer, over the glass
    private let textView: NSTextView
    private let closeButton: NSButton
    private let colorButton: NSButton
    private lazy var paletteMenu = PaletteMenu { [weak self] in self?.apply(color: $0) }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    private var colorHex = Swatch.defaultHex
    private var saveHandler: (Note) -> Void = { _ in }  // where the current note persists
    /// The tracked window, top-left screen coords. One value, because its origin and size only
    /// ever change together — three loose fields drifting apart was a bug waiting to happen.
    private var tracked = CGRect.zero
    private var dx = 20.0
    private var dy = 40.0
    private var isProgrammaticMove = false
    private var active = false  // current folder has a note to show
    private var occluded = false  // the note's spot on the Finder window is covered
    private var shown = false  // what the last pop animated toward (the window stays visible while popping out)

    static let defaultSize = NSSize(width: 220, height: 170)
    /// Any smaller and the swatch and trash buttons start eating the text.
    static let minSize = NSSize(width: 160, height: 120)

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
        let w = Self.defaultSize.width
        let h = Self.defaultSize.height
        let strip: CGFloat = 28
        let radius: CGFloat = 12
        // .resizable on a borderless window gets edge-dragging from AppKit for free — no grow
        // box, no drag tracking of our own.
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.minSize = Self.minSize
        window.level = .floating
        window.isMovableByWindowBackground = true
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
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
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
        textView.isRichText = false
        textView.allowsUndo = true  // off by default — without it ⌘Z reaches an empty undo stack
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        glass.addSubview(scroll)

        // Colour selector, top-left: a swatch button that pops up the palette menu.
        colorButton = NSButton(frame: NSRect(x: 6, y: h - 24, width: 20, height: 20))
        colorButton.isBordered = false
        colorButton.imagePosition = .imageOnly
        colorButton.autoresizingMask = [.minYMargin, .maxXMargin]  // stays top-left on resize
        glass.addSubview(colorButton)

        // Delete button, top-right (added last so it sits above everything).
        closeButton = NSButton(frame: NSRect(x: w - 26, y: h - 24, width: 20, height: 20))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "trash.fill", accessibilityDescription: "Delete note")
        closeButton.contentTintColor = NSColor.black.withAlphaComponent(0.35)
        closeButton.autoresizingMask = [.minYMargin, .minXMargin]  // stays top-right on resize
        glass.addSubview(closeButton)

        window.contentView = glass
        super.init()
        window.delegate = self
        textView.delegate = self
        closeButton.target = self
        closeButton.action = #selector(deleteTapped)
        colorButton.target = self
        colorButton.action = #selector(pickColor)
        colorButton.image = Swatch.image(hex: colorHex)
        applyTint(Swatch.color(fromHex: colorHex))  // one source of truth for the default yellow
        window.invalidateShadow()
    }

    // MARK: - Colour

    @objc private func pickColor() {
        paletteMenu.popUp(from: colorButton, currentHex: colorHex)
    }

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
        colorButton.image = Swatch.image(hex: colorHex)
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
        colorHex = note.color ?? Swatch.defaultHex
        applyTint(Swatch.color(fromHex: colorHex))
        colorButton.image = Swatch.image(hex: colorHex)
        textView.string = note.text  // programmatic set does not fire textDidChange
        restyle()  // ...so style it here by hand
        withProgrammaticMove {
            window.setFrame(
                NSRect(
                    origin: window.frame.origin,
                    size: NSSize(
                        width: note.w ?? Self.defaultSize.width,
                        height: note.h ?? Self.defaultSize.height)),
                display: false)
        }
        applyPosition()  // after the resize: clamping depends on the note's size
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
        let c = Coord.clamp(dx: dx, dy: dy, note: window.frame.size, window: tracked.size)
        dx = c.dx
        dy = c.dy
        withProgrammaticMove {
            window.setFrameTopLeftPoint(
                Coord.cocoaTopLeft(
                    finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
                    dx: dx, dy: dy, primaryHeight: Screens.primaryHeight()))
        }
    }

    // User dragged or resized the note: recompute the offset from the Finder window's top-left,
    // clamp it back inside the window, then save.
    // ponytail: snapping back in the delegate rides AppKit's own drag loop; if it ever feels
    // jittery at the border, take over the drag in the content view's mouseDragged instead.
    private func noteGeometryChanged() {
        guard !isProgrammaticMove else { return }
        let f = window.frame
        (dx, dy) = Coord.offsets(
            noteMinX: Double(f.minX), noteCocoaMaxY: Double(f.maxY),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        applyPosition()  // clamps dx/dy and snaps the note back if the drag left the window
        scheduleSave()
    }

    func windowDidMove(_ notification: Notification) { noteGeometryChanged() }

    /// Dragging the top or left edge moves the note's top-left corner without moving the frame's
    /// origin, so windowDidMove never fires — a resize has to recompute the offset too, not just
    /// re-clamp, or those two edges would fight the user.
    func windowDidResize(_ notification: Notification) { noteGeometryChanged() }

    // MARK: - Text and saving

    /// Style the markdown where it sits. The buffer keeps every marker — they just fade — so
    /// `textView.string` stays the note's source and nothing needs serialising back.
    private func restyle() {
        guard let ts = textView.textStorage else { return }
        MarkdownStyle.apply(to: ts)
    }

    func textDidChange(_ notification: Notification) {
        restyle()
        scheduleSave()
    }

    private func scheduleSave() {
        let note = Note(
            text: textView.string, dx: dx, dy: dy, color: colorHex,
            w: Double(window.frame.width), h: Double(window.frame.height))
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        let save = saveHandler
        saver.call { save(note) }
    }
}
