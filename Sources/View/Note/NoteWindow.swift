import AppKit

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One reusable floating post-it, and the assembler for the four parts that make one up: where
/// it sits (`NoteAnchor`), what it says (`NoteEditor`), how it looks (`NoteStyler`) and how you
/// change any of that (`NotePill`). Each part owns its own slice of a `Note`, so only this class
/// can build a whole one — which is why saving lives here and nowhere else.
///
/// What is left of its own: the window and its glass card, showing and hiding, and the
/// right-click menu.
final class NoteWindow: NSObject, NSWindowDelegate {
    private let window: KeyableWindow
    /// Where the note sits: the offset it keeps from the tracked window, and the size it wants.
    private let anchor: NoteAnchor
    private let editor: NoteEditor  // the text, its markdown rules, and the only writer to it
    private let styler: NoteStyler  // the note's colour and typeface, and the tint that shows one
    private let pill: NotePill  // the control cluster in the card's top-right corner
    private lazy var paletteMenu = PaletteMenu { [weak self] in self?.choose(color: $0, commit: true) }

    /// The pin levels the note can move between, pushed by the controller so NoteWindow stays
    /// ignorant of Container — the same split as the colour menu, which owns *how* one is chosen
    /// while the controller owns what it *means*.
    private var pinChoices: [(level: Int, label: String)] = []
    private var pinCurrent = 0
    private var onPickLevel: (Int) -> Bool = { _ in true }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    private var saveHandler: (Note) -> Bool = { _ in true }  // persists or reports failure
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
        anchor = NoteAnchor(window: window)

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
        // own layer's drawing, so a tint of our own needs a view of its own. The styler is the
        // only thing that paints it, so it's the only thing that keeps it.
        let tint = NSView(frame: glass.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        glass.addSubview(tint)
        styler = NoteStyler(tintView: tint)

        // Editable text: the full card below the drag strip.
        // ponytail: no inset for the pill — closed it's a dot in a corner and the text is meant to
        // blur under it; reserving a line's worth of space for it on every note costs more.
        editor = NoteEditor(frame: NSRect(x: 4, y: 4, width: w - 8, height: h - strip - 4))
        glass.addSubview(editor.view)

        pill = NotePill(cardWidth: w, cardHeight: h, styler: styler)
        glass.addSubview(pill.view)

        window.contentView = glass
        super.init()
        anchor.onChange = { [weak self] in self?.scheduleSave() }
        glass.onDrag = { [weak self] origin in self?.anchor.dragTo(origin: origin) }
        glass.onPress = { [weak self] in self?.pill.close() }  // the picker's way out
        editor.onPress = { [weak self] in self?.pill.close() }
        editor.onEdit = { [weak self] in self?.scheduleSave() }
        glass.contextMenu = { [weak self] in self?.buildMenu() }
        window.delegate = self
        pill.onFont = { [weak self] face, commit in self?.choose(family: face, commit: commit) }
        pill.onColor = { [weak self] color, commit in self?.choose(color: color, commit: commit) }
        pill.onDelete = { [weak self] in self?.deleteTapped() }
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
        color.image = Swatch.image(hex: styler.colorHex)
        color.submenu = paletteMenu.menu(currentHex: styler.colorHex)
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

    // MARK: - Choosing a look

    /// What choosing a typeface means, whether the pill is previewing one under the cursor or
    /// the user has settled on it. Preview and commit share the exact same rendering path; only
    /// a commit adopts the face, so leaving a choice restores the note without ever scheduling a
    /// save. A commit also keeps the caret, which a preview has nothing to put back.
    private func choose(family face: NoteFont, commit: Bool) {
        if commit { styler.commitFamily(face) } else { styler.useFamily(face) }
        editor.reflow(keepCaret: commit)
        guard commit else { return }
        pill.refreshDots()
        scheduleSave()
    }

    /// The same, for a colour — from a swatch under the cursor, a swatch click, or live from the
    /// system colour panel behind the card's right-click menu.
    private func choose(color: NSColor, commit: Bool) {
        if commit { styler.commitColor(color) } else { styler.showColor(color) }
        guard commit else { return }
        pill.refreshDots()
        scheduleSave()
    }

    // MARK: - Show / hide

    /// A single click on the red dot is the whole delete gesture, so a note with text asks first.
    private func confirmDelete() -> Bool {
        guard !editor.isBlank else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this note?"
        alert.informativeText = "Its text will be lost."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func deleteTapped() {
        guard confirmDelete() else { return }
        let deletion = Note(text: "", dx: anchor.dx, dy: anchor.dy, color: styler.colorHex)
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
        active = true
        occluded = false  // re-evaluated on the next tracking frame
        // Loaded before the parse in `editor.load`: it bakes the note's face into the text.
        styler.load(
            colorHex: note.color ?? NotePreferences.shared.defaultColorHex,
            family: note.font.flatMap(NoteFont.init(rawValue:)) ?? .sans)
        pill.reset()  // the window is reused: never arrive already open
        editor.load(note.text)
        anchor.begin(note: note, bounds: bounds)
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
    func screenRectTopLeft() -> CGRect { anchor.screenRectTopLeft() }

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
        window.makeFirstResponder(editor.textView)
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

    // MARK: - Tracking

    /// A display link synced to whatever display the note is on, so the caller samples the
    /// window's position in vsync phase at the real refresh rate (120Hz on ProMotion) instead
    /// of a fixed 60fps timer. Caller owns it: add to a run loop, invalidate to stop.
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        window.displayLink(target: target, selector: selector)
    }

    /// The tracked window moved or resized — keep the offset, reposition.
    func updateWindow(bounds: CGRect) { anchor.updateWindow(bounds: bounds) }

    func windowDidMove(_ notification: Notification) { anchor.windowDidMove() }

    func windowDidResize(_ notification: Notification) { anchor.windowDidResize() }

    // MARK: - Saving

    /// The one place a whole note is assembled: what it says, where it sits, and how it looks.
    /// Each part owns only its own slice, so nothing below this class can build one.
    private func scheduleSave() {
        let note = Note(
            text: editor.markdown, dx: anchor.dx, dy: anchor.dy, color: styler.colorHex,
            font: styler.family.rawValue,
            // intended size, not the capped one
            w: Double(anchor.desired.width), h: Double(anchor.desired.height))
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        let save = saveHandler
        saver.call { save(note) }
    }
}
