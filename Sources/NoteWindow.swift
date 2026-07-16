import AppKit

/// Coordinate math, kept pure so it can be asserted in --selftest.
enum Coord {
    /// AppleScript top-left screen point of the note -> Cocoa point for `setFrameTopLeftPoint`.
    static func cocoaTopLeft(finderLeft: Double, finderTop: Double, dx: Double, dy: Double, primaryHeight: Double) -> NSPoint {
        NSPoint(x: finderLeft + dx, y: primaryHeight - (finderTop + dy))
    }

    /// Holds the note inside the tracked window: the offset is clamped so the note's whole
    /// rect stays within the window. A window smaller than the note pins it to the top-left.
    static func clamp(dx: Double, dy: Double, note: CGSize, window: CGSize) -> (dx: Double, dy: Double) {
        (min(max(0, dx), max(0, Double(window.width - note.width))),
         min(max(0, dy), max(0, Double(window.height - note.height))))
    }
}

enum Screens {
    // ponytail: single-display assumption; refine for multi-monitor if needed
    static func primaryHeight() -> Double {
        Double((NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame.height ?? 0)
    }
}

/// "RRGGBB" hex <-> NSColor, kept pure so it can be asserted in --selftest.
enum Swatch {
    static let defaultHex = "FFEB73" // sticky-note yellow

    static func color(fromHex hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return color(fromHex: defaultHex) }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// The app-wide list of palette colours, persisted in UserDefaults. Starts with 3 presets
/// and grows via the "+" in the colour menu.
enum Palette {
    private static let key = "paletteColors"
    static let presets = ["FFEB73", "FFB3BA", "AEC6FF"] // yellow, pink, blue

    static var colors: [String] { UserDefaults.standard.stringArray(forKey: key) ?? presets }

    static func add(_ hex: String) {
        var list = colors
        guard !list.contains(hex) else { return }
        list.append(hex)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ hex: String) {
        var list = colors
        guard list.count > 1, let i = list.firstIndex(of: hex) else { return } // keep at least one
        list.remove(at: i)
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// Borderless windows can't become key by default, so text editing wouldn't work.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A palette swatch button that remembers which colour it is.
private final class ColorSwatchButton: NSButton {
    var hex = ""
}

/// One reusable floating yellow post-it. Follows the Finder window by keeping a fixed
/// offset (dx, dy) from its top-left; dragging the note updates and persists that offset.
final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: KeyableWindow
    private let textView: NSTextView
    private let closeButton: NSButton
    private let colorButton: NSButton

    /// Called after the user deletes the note (so the app can stop tracking it).
    var onDelete: (() -> Void)?

    private var colorHex = Swatch.defaultHex
    private var saveHandler: (Note) -> Void = { _ in } // where the current note persists
    private var finderLeft = 0.0
    private var finderTop = 0.0
    private var windowSize = CGSize.zero // tracked window's size, so the note can't be dragged out of it
    private var dx = 20.0
    private var dy = 40.0
    private var isProgrammaticMove = false
    private var saveWork: DispatchWorkItem?
    private var active = false   // current folder has a note to show
    private var occluded = false // the note's spot on the Finder window is covered
    private var shown = false    // what the last pop animated toward (the window stays visible while popping out)

    override init() {
        let w: CGFloat = 220, h: CGFloat = 170, strip: CGFloat = 28, radius: CGFloat = 12
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear // rounded card is drawn by the content layer below
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // ponytail: can't query a window's Space via public API, so the note binds to the
        // desktop that's active when its folder becomes frontmost, and stays there.
        window.collectionBehavior = [.moveToActiveSpace]

        // Rounded yellow card like a Mac window. Its bare background is the drag area.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.45, alpha: 1.0).cgColor
        content.layer?.cornerRadius = radius
        content.layer?.masksToBounds = true

        // Editable text, below the top drag strip.
        let scroll = NSScrollView(frame: NSRect(x: 4, y: 4, width: w - 8, height: h - strip - 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]
        textView = NSTextView(frame: scroll.bounds)
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .black
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)

        // Colour selector, top-left: a swatch button that pops up the palette menu.
        colorButton = NSButton(frame: NSRect(x: 6, y: h - 24, width: 20, height: 20))
        colorButton.isBordered = false
        colorButton.imagePosition = .imageOnly
        content.addSubview(colorButton)

        // Delete button, top-right (added last so it sits above everything).
        closeButton = NSButton(frame: NSRect(x: w - 26, y: h - 24, width: 20, height: 20))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete note")
        closeButton.contentTintColor = NSColor.black.withAlphaComponent(0.35)
        content.addSubview(closeButton)

        window.contentView = content
        super.init()
        window.delegate = self
        textView.delegate = self
        closeButton.target = self
        closeButton.action = #selector(deleteTapped)
        colorButton.target = self
        colorButton.action = #selector(pickColor)
        colorButton.image = swatchImage(hex: colorHex)
        window.invalidateShadow()
    }

    // Pop up the palette menu below the swatch button.
    @objc private func pickColor() {
        let menu = NSMenu()
        menu.addItem(paletteGridItem())
        menu.addItem(.separator())
        let plus = NSMenuItem(title: "Aggiungi colore…", action: #selector(addColor), keyEquivalent: "")
        plus.target = self
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add colour")
        menu.addItem(plus)

        if Palette.colors.count > 1 { // a "Remove" submenu of swatches (never empty the palette)
            let remove = NSMenuItem(title: "Rimuovi colore", action: nil, keyEquivalent: "")
            remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove colour")
            let sub = NSMenu()
            for hex in Palette.colors {
                let it = NSMenuItem(title: "", action: #selector(removeColor(_:)), keyEquivalent: "")
                it.target = self
                it.image = swatchImage(hex: hex)
                it.representedObject = hex
                sub.addItem(it)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: colorButton.bounds.height + 4), in: colorButton)
    }

    @objc private func removeColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        Palette.remove(hex)
    }

    // Colour swatches laid out in a grid, max 5 per row.
    private func paletteGridItem() -> NSMenuItem {
        let colors = Palette.colors
        let cols = min(colors.count, 5)
        let rows = (colors.count + 4) / 5
        let cell: CGFloat = 26, pad: CGFloat = 8
        let width = CGFloat(cols) * cell + pad * 2
        let height = CGFloat(rows) * cell + pad * 2
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (i, hex) in colors.enumerated() {
            let cellX = pad + CGFloat(i % 5) * cell
            let cellY = height - pad - CGFloat(i / 5 + 1) * cell // fill top-to-bottom
            let btn = ColorSwatchButton(frame: NSRect(x: cellX + 2, y: cellY + 2, width: cell - 4, height: cell - 4))
            btn.hex = hex
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.image = swatchImage(hex: hex, size: 20)
            btn.target = self
            btn.action = #selector(swatchClicked(_:))
            view.addSubview(btn)
        }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func swatchClicked(_ sender: ColorSwatchButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking() // close the menu
        apply(color: Swatch.color(fromHex: sender.hex))
    }

    // "+": pick a new colour in the system panel; it previews live and joins the palette on close.
    @objc private func addColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged))
        panel.color = Swatch.color(fromHex: colorHex)
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosed),
                                               name: NSWindow.willCloseNotification, object: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelColorChanged() { apply(color: NSColorPanel.shared.color) }

    @objc private func panelClosed(_ note: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        NSColorPanel.shared.setTarget(nil)
        Palette.add(Swatch.hex(from: NSColorPanel.shared.color))
    }

    private func apply(color: NSColor) {
        colorHex = Swatch.hex(from: color)
        window.contentView?.layer?.backgroundColor = color.cgColor
        colorButton.image = swatchImage(hex: colorHex)
        scheduleSave()
    }

    private func swatchImage(hex: String, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2), xRadius: 3, yRadius: 3)
        Swatch.color(fromHex: hex).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.stroke()
        img.unlockFocus()
        return img
    }

    @objc private func deleteTapped() {
        saveHandler(Note(text: "", dx: dx, dy: dy, color: colorHex)) // empty text removes the note
        active = false
        applyVisibility()
        onDelete?()
    }

    /// Show `note`, positioned relative to the tracked window's top-left; `save` persists edits.
    func show(note: Note, bounds: CGRect, save: @escaping (Note) -> Void) {
        self.saveHandler = save
        self.dx = note.dx
        self.dy = note.dy
        self.finderLeft = Double(bounds.minX)
        self.finderTop = Double(bounds.minY)
        self.windowSize = bounds.size
        active = true
        occluded = false // re-evaluated on the next tracking frame
        colorHex = note.color ?? Swatch.defaultHex
        let c = Swatch.color(fromHex: colorHex)
        window.contentView?.layer?.backgroundColor = c.cgColor
        colorButton.image = swatchImage(hex: colorHex)
        textView.string = note.text // programmatic set does not fire textDidChange
        applyPosition()
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
        return CGRect(x: f.minX, y: Screens.primaryHeight() - f.maxY, width: f.width, height: f.height)
    }

    private func applyVisibility() {
        let visible = active && !occluded
        guard visible != shown else { return } // already going the right way
        shown = visible
        if visible { popIn() } else { popOut() }
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.popDuration
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return } // popped back in mid-fade: leave it alone
            self.window.orderOut(nil)
            self.window.contentView?.layer?.removeAnimation(forKey: "pop")
            self.window.alphaValue = 1
        })
    }

    /// The tracked window moved or resized — keep the offset, reposition. No-op if unchanged.
    /// A resize re-clamps, so shrinking the window pulls the note back inside with it.
    func updateWindow(bounds: CGRect) {
        let (left, top) = (Double(bounds.minX), Double(bounds.minY))
        guard left != finderLeft || top != finderTop || bounds.size != windowSize else { return }
        finderLeft = left
        finderTop = top
        windowSize = bounds.size
        applyPosition()
    }

    func hide() {
        active = false
        applyVisibility()
    }

    func focusForEditing() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func applyPosition() {
        let c = Coord.clamp(dx: dx, dy: dy, note: window.frame.size, window: windowSize)
        dx = c.dx
        dy = c.dy
        isProgrammaticMove = true
        window.setFrameTopLeftPoint(Coord.cocoaTopLeft(finderLeft: finderLeft, finderTop: finderTop,
                                                        dx: dx, dy: dy, primaryHeight: Screens.primaryHeight()))
        isProgrammaticMove = false
    }

    // User dragged the note: recompute the offset from the Finder window's top-left, clamp it
    // back inside the window, then save.
    // ponytail: snapping back in windowDidMove rides AppKit's own drag loop; if it ever feels
    // jittery at the border, take over the drag in the content view's mouseDragged instead.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        let f = window.frame
        let noteTopLeftY = Screens.primaryHeight() - Double(f.maxY) // Cocoa -> top-left screen coords
        dx = Double(f.minX) - finderLeft
        dy = noteTopLeftY - finderTop
        applyPosition() // clamps dx/dy and snaps the note back if the drag left the window
        scheduleSave()
    }

    func textDidChange(_ notification: Notification) { scheduleSave() }

    private func scheduleSave() {
        saveWork?.cancel()
        let note = Note(text: textView.string, dx: dx, dy: dy, color: colorHex)
        let save = saveHandler
        let work = DispatchWorkItem { save(note) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
