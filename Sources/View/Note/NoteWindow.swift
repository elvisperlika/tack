import AppKit

/// The dashboard's background: a soft diagonal gradient through the colours of its notes.
/// Layer-hosting (the layer is set before `wantsLayer`), so colour changes animate on their own.
private final class GradientView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 1)  // top-left to bottom-right
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Washed over the pane rather than painted solid, so it reads as a tint of the notes, and
    /// the notes' own glass stays the strongest colour on screen.
    func show(_ hexes: [String]) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        gradient.colors = hexes.map { Swatch.color(fromHex: $0).withAlphaComponent(0.45).cgColor }
        CATransaction.commit()
    }
}

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

    /// The pin levels the note can move between, pushed by the controller so NoteWindow stays
    /// ignorant of Container: the pill owns *how* one is chosen, the controller what it *means*.
    private var pinChoices: [NotePill.PinChoice] = []
    private var onPickLevel: (Int) -> Bool = { _ in true }
    private let saver = Debouncer(delay: 0.5)  // collapse typing/drag bursts into one write

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    /// The pill's "all notes" dot: open the Tack window.
    var onOpenAll: (() -> Void)?

    /// Every edit as it lands, ahead of the debounce that writes it — for anything showing the
    /// same note live. An empty note is a deletion, the same as everywhere else.
    var onLiveEdit: ((Note) -> Void)?

    private var saveHandler: (Note) -> Bool = { _ in true }  // persists or reports failure
    private var active = false  // current folder has a note to show
    private var occluded = false  // the note's spot on the Finder window is covered
    private var shown = false  // what the last pop animated toward (the window stays visible while popping out)
    /// The note is the dashboard, or on its way to or from it. It is let go of its tracked
    /// window meanwhile: neither the tracker nor the window delegate may touch the frame.
    private var lifting = false

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
        card.pill.onPin = { [weak self] level in self?.pick(level: level) }
        card.pill.onOpenAll = { [weak self] in self?.onOpenAll?() }
        card.pill.onCollapse = { [weak self] in self?.onCollapse?() }
        card.pill.onSettings = { [weak self] in self?.onSettings?() }
        card.onPress = { [weak self] in
            if self?.isExpanded == true { self?.onDashboardPress?() }  // the strip, the glass edge
        }
        card.view.onDrag = { [weak self] origin in
            guard let self else { return }
            // The dashboard is a window of its own: it goes where it is dragged.
            if isExpanded { window.setFrameOrigin(origin) } else { anchor.dragTo(origin: origin) }
        }
        window.delegate = self
        window.invalidateShadow()
    }

    // MARK: - Pin level

    /// The scopes this note can pin to. The controller pushes them (with the current one) on
    /// every show; the pill shows its pin dot only when there are at least two.
    func setPinLevels(
        _ choices: [NotePill.PinChoice], current: Int,
        onPick: @escaping (Int) -> Bool
    ) {
        pinChoices = choices
        onPickLevel = onPick
        card.pill.setPinLevels(choices, current: current)
    }

    /// Move the note to `level`, picked from the pill's pin dot.
    private func pick(level: Int) {
        guard saver.flush() else { return }  // never move an older version after a failed save
        guard onPickLevel(level) else { return }
        card.pill.setPinLevels(pinChoices, current: level)  // the picker rings the new level
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
        if isExpanded { pendingLive = note } else { card.load(note) }
    }

    /// Show `note`, positioned relative to the tracked window's top-left; `save` persists edits.
    func show(note: Note, bounds: CGRect, save: @escaping (Note) -> Bool) {
        // A save that keeps failing (a read-only folder) must not hold every other note hostage.
        // The save handler has already told the user, so the edit that can't land is dropped.
        if !saver.flush() { saver.cancel() }
        self.saveHandler = save
        active = true
        occluded = false  // re-evaluated on the next tracking frame
        card.load(note)
        anchor.begin(note: note, bounds: bounds)
        // Switching between two notes reuses this one window, so pop unconditionally rather than
        // going through applyVisibility — otherwise the incoming note would just teleport in.
        shown = true
        popIn()
    }

    /// Hide when another window covers the note's spot on the Finder window (and vice versa).
    func setOccluded(_ value: Bool) {
        guard !lifting, value != occluded else { return }
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
        // The dashboard stays up; collapsing it sees there is no note left to turn back into.
        if !lifting { applyVisibility() }
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

    /// The tracked window moved or resized — keep the offset, reposition.
    func updateWindow(bounds: CGRect) {
        guard !lifting else { return }
        anchor.updateWindow(bounds: bounds)
    }

    // The dashboard moves and resizes the window too; read back as the user's, it would be saved
    // as the note's new spot and size.
    func windowDidMove(_ notification: Notification) {
        if !lifting { anchor.windowDidMove() }
    }

    func windowDidResize(_ notification: Notification) {
        if !lifting { anchor.windowDidResize() }
    }

    // MARK: - Dashboard

    private static let growDuration = 0.38
    private static let contentFade = 0.18
    private static let dashboardLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    /// The dashboard's background, built on first expand and kept for the next one.
    private lazy var backdrop = GradientView(frame: .zero)

    /// Repaint the dashboard's background from its notes' colours (see `NoteGrid.colors`).
    func setDashboardColors(_ hexes: [String]) { backdrop.show(hexes) }

    /// While this note is the dashboard: what it shows, and what to put back afterwards.
    private var dashboard: (content: NSView, home: NSRect, limits: (NSSize, NSSize))?
    var isExpanded: Bool { dashboard != nil }
    /// The note's own window frame — where the dashboard is, while it is one.
    var frame: NSRect { window.frame }

    /// A click on the dashboard itself, off its page — the strip it is dragged by, its edges.
    var onDashboardPress: (() -> Void)?
    /// The pill's settings dot: the owner decides which page to show next.
    var onSettings: (() -> Void)?
    /// The pill's way back from the dashboard: the owner collapses it (and saves what it must first).
    var onCollapse: (() -> Void)?
    /// An edit to this note from a dashboard cell, held until the note is a note again — loading
    /// it into the hidden card now would repaint the pane in the note's colour.
    private var pendingLive: Note?

    /// The note becomes the Tack dashboard: it lets go of its window, grows into `frame` while
    /// its colour washes over to `color` and its words fade, and `content` — every note — fades
    /// in once it has arrived. A window with no note up starts as a small card in the middle.
    func expand(showing content: NSView, to frame: NSRect, color: NSColor) {
        guard !isExpanded else { return }
        lifting = true  // the tracker and the delegate keep their hands off the frame from here
        let home = window.frame
        let limits = (window.minSize, window.maxSize)
        dashboard = (content, home, limits)

        window.contentView?.layer?.removeAnimation(forKey: "pop")
        window.minSize = NSSize(width: 360, height: 260)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        window.level = Self.dashboardLevel  // above every other note
        if shown {
            card.fadeToPane(color, duration: Self.growDuration)
        } else {
            let size = NotePreferences.shared.defaultSize
            window.setFrame(
                NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                       width: size.width, height: size.height), display: false)
            card.fadeToPane(color, duration: 0)
            window.alphaValue = 1
            window.orderFront(nil)
        }
        shown = true

        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Self.growDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                mount(content)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            })
    }

    /// Lay the dashboard into the card: the grid under a strip that drags the window. The pill
    /// stays in the strip's corner — the same glass to hover — now offering the way back.
    private func mount(_ content: NSView) {
        let bounds = card.view.bounds
        let strip: CGFloat = 30
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - strip)
        content.autoresizingMask = [.width, .height]
        // Faded out isn't gone: an invisible editor still takes clicks and keystrokes, and the
        // strip above the grid would be typing into the hidden note.
        card.editor.view.isHidden = true
        card.pill.isDashboard = true
        card.pill.showingSettings = false  // a dashboard always opens on its notes
        content.alphaValue = 0
        card.view.addSubview(content, positioned: .below, relativeTo: card.pill.view)
        // The whole card, strip included, under whatever page is up.
        backdrop.frame = bounds
        backdrop.alphaValue = 0
        card.view.addSubview(backdrop, positioned: .below, relativeTo: content)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.contentFade
            backdrop.animator().alphaValue = 1
            content.animator().alphaValue = 1
            card.pill.view.animator().alphaValue = 1
        }
    }

    /// Swap what the dashboard shows — its notes, or the settings page — with a cross-fade, in
    /// the same place. `settings` tells the pill which page is now up.
    func showPage(_ page: NSView, settings: Bool) {
        guard let current = dashboard?.content, current !== page, !collapsing else { return }
        page.frame = current.frame
        page.autoresizingMask = [.width, .height]
        page.alphaValue = 0
        card.view.addSubview(page, positioned: .below, relativeTo: card.pill.view)
        dashboard?.content = page
        card.pill.showingSettings = settings
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Self.contentFade
                current.animator().alphaValue = 0
                page.animator().alphaValue = 1
            },
            completionHandler: {
                current.removeFromSuperview()
                current.alphaValue = 1  // ready for the next time it is shown
            })
    }

    /// The dashboard turns back into the note: every note fades out, and the pane shrinks back
    /// onto the window the note belongs to while its colour and words return. A dashboard that
    /// was never a note — or whose note has gone meanwhile — shrinks into its middle and is gone.
    func collapse() {
        guard let dashboard, !collapsing else { return }
        collapsing = true
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Self.contentFade
                dashboard.content.animator().alphaValue = 0
                backdrop.animator().alphaValue = 0
                card.pill.view.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                dashboard.content.removeFromSuperview()
                backdrop.removeFromSuperview()
                card.editor.view.isHidden = false  // still faded out: the shrink brings it back
                card.pill.isDashboard = false
                shrink(dashboard)
            })
    }
    private var collapsing = false

    private func shrink(_ dashboard: (content: NSView, home: NSRect, limits: (NSSize, NSSize))) {
        let returning = active
        let target: NSRect
        if returning {
            target = dashboard.home
            if let pendingLive { card.load(pendingLive) }  // under the pane; the wash reveals it
            pendingLive = nil
            card.fadeFromPane(card.styler.paneColor, duration: Self.growDuration)
        } else {
            let f = window.frame
            target = NSRect(x: f.midX - 40, y: f.midY - 30, width: 80, height: 60)
        }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Self.growDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
                if !returning { window.animator().alphaValue = 0 }
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                (window.minSize, window.maxSize) = dashboard.limits
                window.level = .floating
                self.dashboard = nil
                collapsing = false
                lifting = false
                if returning {
                    shown = true
                    occluded = false  // the next tracking frame hides it again if something covers it
                } else {
                    window.orderOut(nil)
                    window.setFrame(dashboard.home, display: false)
                    window.alphaValue = 1
                    card.restorePane()
                    shown = false
                }
            })
    }

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
