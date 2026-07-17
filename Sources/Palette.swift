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

    /// A rounded swatch of the colour, for menu items and the note's colour button.
    static func image(hex: String, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2), xRadius: 3,
            yRadius: 3)
        color(fromHex: hex).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.stroke()
        img.unlockFocus()
        return img
    }
}

/// The app-wide list of palette colours, persisted in UserDefaults. Starts with 3 presets
/// and grows via the "+" in the colour menu.
enum Palette {
    private static let key = "paletteColors"
    static let presets = ["FFEB73", "FFB3BA", "AEC6FF"]  // yellow, pink, blue

    static var colors: [String] { UserDefaults.standard.stringArray(forKey: key) ?? presets }

    static func add(_ hex: String) {
        var list = colors
        guard !list.contains(hex) else { return }
        list.append(hex)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ hex: String) {
        var list = colors
        guard list.count > 1, let i = list.firstIndex(of: hex) else { return }  // keep at least one
        list.remove(at: i)
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// A palette swatch button that remembers which colour it is.
private final class ColorSwatchButton: NSButton {
    var hex = ""
}

/// The colour-picking UI: the swatch grid, the "Remove" submenu, and the "+" system-panel flow.
/// Its one job is reporting the chosen colour through `onPick` — it never touches the note, so
/// NoteWindow keeps owning what a colour *means* and this class only owns how one is chosen.
final class PaletteMenu: NSObject {
    private let onPick: (NSColor) -> Void
    private var currentHex = Swatch.defaultHex  // what the "+" panel opens preloaded with

    init(onPick: @escaping (NSColor) -> Void) { self.onPick = onPick }

    /// Pop up below `button`. The menu is rebuilt per open so palette edits show immediately.
    func popUp(from button: NSButton, currentHex: String) {
        self.currentHex = currentHex
        let menu = NSMenu()
        menu.addItem(gridItem())
        menu.addItem(.separator())
        let plus = NSMenuItem(
            title: "Aggiungi colore…", action: #selector(addColor), keyEquivalent: "")
        plus.target = self
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add colour")
        menu.addItem(plus)

        if Palette.colors.count > 1 {  // a "Remove" submenu of swatches (never empty the palette)
            let remove = NSMenuItem(title: "Rimuovi colore", action: nil, keyEquivalent: "")
            remove.image = NSImage(
                systemSymbolName: "minus", accessibilityDescription: "Remove colour")
            let sub = NSMenu()
            for hex in Palette.colors {
                let it = NSMenuItem(
                    title: "", action: #selector(removeColor(_:)), keyEquivalent: "")
                it.target = self
                it.image = Swatch.image(hex: hex)
                it.representedObject = hex
                sub.addItem(it)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // Colour swatches laid out in a grid, max 5 per row.
    private func gridItem() -> NSMenuItem {
        let colors = Palette.colors
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

    @objc private func removeColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        Palette.remove(hex)
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
        Palette.add(Swatch.hex(from: NSColorPanel.shared.color))
    }
}
