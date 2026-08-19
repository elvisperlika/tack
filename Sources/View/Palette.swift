import AppKit

/// "RRGGBB" hex <-> NSColor, kept pure so it can be asserted in --selftest.
enum Swatch {
    static let defaultHex = "FFEB73"  // sticky-note yellow

    static func color(fromHex hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return color(fromHex: defaultHex) }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
    }

    /// The next colour after `hex`, wrapping. A colour that isn't in the palette (it was removed,
    /// or came from the "+" panel) starts the cycle over.
    static func next(after hex: String, in palette: [String]) -> String {
        guard let i = palette.firstIndex(of: hex) else { return palette.first ?? hex }
        return palette[(i + 1) % palette.count]
    }

    /// A rounded swatch of the colour, for menu items and the note's colour dot
    /// (`radius: size / 2` makes it a circle).
    static func image(hex: String, size: CGFloat = 16, radius: CGFloat = 3) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2), xRadius: radius,
            yRadius: radius)
        color(fromHex: hex).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.stroke()
        img.unlockFocus()
        return img
    }
}

/// A palette swatch button that remembers which colour it is.
private final class ColorSwatchButton: NSButton {
    var hex = ""
}

/// The colour-picking UI: the swatch grid (each swatch wears a tiny × to delete it) and the
/// "+" system-panel flow.
/// Its one job is reporting the chosen colour through `onPick` — it never touches the note, so
/// NoteWindow keeps owning what a colour *means* and this class only owns how one is chosen.
final class PaletteMenu: NSObject {
    private let onPick: (NSColor) -> Void
    private var currentHex = NotePreferences.shared.defaultColorHex  // what the "+" panel opens preloaded with

    init(onPick: @escaping (NSColor) -> Void) { self.onPick = onPick }

    /// The colour menu, rebuilt per call so palette edits show immediately. Hangs off the
    /// note's single menu button as a submenu.
    func menu(currentHex: String) -> NSMenu {
        self.currentHex = currentHex
        let menu = NSMenu()
        menu.addItem(gridItem())
        menu.addItem(.separator())
        let plus = NSMenuItem(
            title: "Add new…", action: #selector(addColor), keyEquivalent: "")
        plus.target = self
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add colour")
        menu.addItem(plus)
        return menu
    }

    // Colour swatches laid out in a grid, max 5 per row.
    private func gridItem() -> NSMenuItem {
        let colors = NotePreferences.shared.palette
        let cols = min(colors.count, 5)
        let rows = (colors.count + 4) / 5
        let cell: CGFloat = 26
        let pad: CGFloat = 8
        let width = CGFloat(cols) * cell + pad * 2
        let height = CGFloat(rows) * cell + pad * 2
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (i, hex) in colors.enumerated() {
            let cellX = pad + CGFloat(i % 5) * cell
            let cellY = height - pad - CGFloat(i / 5 + 1) * cell  // fill top-to-bottom
            let btn = ColorSwatchButton(
                frame: NSRect(x: cellX + 2, y: cellY + 2, width: cell - 4, height: cell - 4))
            btn.hex = hex
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.image = Swatch.image(hex: hex, size: 20)
            btn.target = self
            btn.action = #selector(swatchClicked(_:))
            view.addSubview(btn)
            if colors.count > 1 {  // no × when removing it would empty the palette
                let x = ColorSwatchButton(
                    frame: NSRect(x: cellX + cell - 13, y: cellY + cell - 13, width: 12, height: 12))
                x.hex = hex
                x.isBordered = false
                x.imagePosition = .imageOnly
                x.image = NSImage(
                    systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove colour")
                x.contentTintColor = NSColor.black.withAlphaComponent(0.55)
                x.target = self
                x.action = #selector(removeSwatchClicked(_:))
                view.addSubview(x)  // added after the swatch, so it sits on top of its corner
            }
        }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()  // close the menu
        guard let swatch = sender as? ColorSwatchButton else { return }
        onPick(Swatch.color(fromHex: swatch.hex))
    }

    @objc private func removeSwatchClicked(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()  // menus are rebuilt per open
        guard let swatch = sender as? ColorSwatchButton else { return }
        NotePreferences.shared.removeColor(swatch.hex)
    }

    // "+": pick a new colour in the system panel; it previews live and joins the palette on close.
    @objc private func addColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged))
        panel.color = Swatch.color(fromHex: currentHex)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelClosed),
            name: NSWindow.willCloseNotification, object: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelColorChanged() { onPick(NSColorPanel.shared.color) }

    @objc private func panelClosed(_ note: Notification) {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        NSColorPanel.shared.setTarget(nil)
        NotePreferences.shared.addColor(Swatch.hex(from: NSColorPanel.shared.color))
    }
}
