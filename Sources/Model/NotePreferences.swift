import AppKit

/// Single source of truth for app-wide note defaults: the colour and size a new note starts
/// with, plus the shared palette. Per-note settings live in `Note`; this owns only the globals
/// that used to be scattered across `NoteWindow` (sizes) and `Palette` (the colour list).
///
/// A class with a `shared` instance rather than an `enum` namespace, so `UserDefaults` can be
/// injected — `--selftest` exercises the palette rules against a throwaway suite instead of the
/// real domain. `Swatch` stays separate: it's pure hex↔colour maths with its own bad-input
/// fallback, and does not belong behind a preferences store.
final class NotePreferences {
    static let shared = NotePreferences()

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - New-note defaults

    private static let colorKey = "defaultNoteColor"

    /// Colour a new note starts with, "RRGGBB". Persisted; unset falls back to `Swatch.defaultHex`.
    var defaultColorHex: String {
        get { defaults.string(forKey: Self.colorKey) ?? Swatch.defaultHex }
        set { defaults.set(newValue, forKey: Self.colorKey) }
    }

    /// The size a new note opens at, and the floor it can't shrink below. Fixed for now — no
    /// setters until there's UI to drive them. ponytail: make these `var` + persisted when that lands.
    let defaultSize = NSSize(width: 220, height: 170)
    /// Any smaller and the pill of dots and the drag strip leave no room for text.
    let minSize = NSSize(width: 160, height: 120)

    // MARK: - Palette

    // Unchanged key: existing users' palettes must keep decoding (compatibility guarantee).
    private static let paletteKey = "paletteColors"
    private static let presets = ["FFEB73", "FFB3BA", "AEC6FF", "FFFFFF"]  // yellow, pink, blue, Notion white

    /// The app-wide swatch list. Starts at `presets` and grows via the colour menu's "+".
    var palette: [String] { defaults.stringArray(forKey: Self.paletteKey) ?? Self.presets }

    func addColor(_ hex: String) {
        var list = palette
        guard !list.contains(hex) else { return }
        list.append(hex)
        defaults.set(list, forKey: Self.paletteKey)
    }

    func removeColor(_ hex: String) {
        var list = palette
        guard list.count > 1, let i = list.firstIndex(of: hex) else { return }  // keep at least one
        list.remove(at: i)
        defaults.set(list, forKey: Self.paletteKey)
    }
}
