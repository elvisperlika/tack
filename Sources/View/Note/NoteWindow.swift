import AppKit

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One reusable floating post-it: the window, where the note sits (`NoteAnchor`), and the card
/// that fills it (`NoteCard`). The card owns what the note says and how it looks; this class
/// owns everything about it being a *floating window* — showing and hiding, following the
/// tracked window, the pin menu — and, because only it knows both halves, saving.
final class NoteWindow: NSObject, NSWindowDelegate {
    private let window: KeyableWindow
    /// Where the note sits: the offset it keeps from the tracked window, and the size it wants.
    private let anchor: NoteAnchor
    private let card: NoteCard
    private lazy var paletteMenu = PaletteMenu { [weak self] in
        self?.card.choose(color: $0, commit: true)
    }

    /// The pin levels the note can move between, pushed by the controller so NoteWindow stays
    /// ignorant of Container — the same split as the colour menu, which owns *how* one is chosen
    /// while the controller owns what it *means*.
    private var pinChoices: [(level: Int, label: String)] = []
    private var pinCurrent = 0
    private var onPickLevel: (Int) -> Bool = { _ in true }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    /// Every edit as it lands, ahead of the debounce that writes it — for anything showing the
    /// same note live. An empty note is a deletion, the same as everywhere else.
    var onLiveEdit: ((Note) -> Void)?

    private var saveHandler: (Note) -> Bool = { _ in true }  // persists or reports failure
    private var active = false  // current folder has a note to show
    private var occluded = false  // the note's spot on the Finder window is covered
    private var shown = false  // what the last pop animated toward (the window stays visible while popping out)

    override init() {
        let size = NotePreferences.shared.defaultSize
        // .resizable on a borderless window gets edge-dragging from AppKit for free — no grow
        // box, no drag tracking of our own.
        window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: size),
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
        card = NoteCard(size: size)
        window.contentView = card.view

        super.init()
        anchor.onChange = { [weak self] in self?.scheduleSave() }
        card.onEdit = { [weak self] in self?.scheduleSave() }
        card.onDelete = { [weak self] in self?.deleteConfirmed() }
        card.view.onDrag = { [weak self] origin in self?.anchor.dragTo(origin: origin) }
        card.view.contextMenu = { [weak self] in self?.buildMenu() }
        window.delegate = self
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
        color.image = Swatch.image(hex: card.styler.colorHex)
        color.submenu = paletteMenu.menu(currentHex: card.styler.colorHex)
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

    // MARK: - Show / hide

    /// The card has already asked; this is what saying yes means for a floating note.
    private func deleteConfirmed() {
        let deletion = card.deletion(keeping: Note(text: "", dx: anchor.dx, dy: anchor.dy))
        guard saveHandler(deletion) else { return }
        onLiveEdit?(deletion)  // so an open dashboard drops it too, rather than showing a ghost
        saver.cancel()  // a stale delayed save must not recreate the successfully deleted note
        active = false
        applyVisibility()
        onDelete?()
    }

    /// Adopt a version of this note edited somewhere else — the dashboard. `NoteEditor.load` is
    /// programmatic and fires no textDidChange, so this can't echo back out through `onLiveEdit`.
    /// The pending save is dropped rather than merged: it is older than what just arrived, and
    /// whoever sent this is the one persisting it.
    func applyLive(_ note: Note) {
        guard active else { return }
        saver.cancel()
        card.load(note)
    }

    /// Show `note`, positioned relative to the tracked window's top-left; `save` persists edits.
    @discardableResult
    func show(note: Note, bounds: CGRect, save: @escaping (Note) -> Bool) -> Bool {
        guard saver.flush() else { return false }
        self.saveHandler = save
        active = true
        occluded = false  // re-evaluated on the next tracking frame
        card.load(note)
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
        card.focus(in: window)
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

    /// The one place a whole note is assembled: the card says what it says and how it looks,
    /// this adds where it sits — neither half can build one alone.
    private func scheduleSave() {
        let note = card.note(keeping: Note(
            text: "", dx: anchor.dx, dy: anchor.dy,
            // intended size, not the capped one
            w: Double(anchor.desired.width), h: Double(anchor.desired.height)))
        // snapshot: an in-flight save must use the handler — and level — of the note it was
        // scheduled for, not whichever note is showing 0.5s later
        onLiveEdit?(note)  // the screen keeps up with the typing; the disk waits for a pause
        let save = saveHandler
        saver.call { save(note) }
    }
}
