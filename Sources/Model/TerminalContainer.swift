import AppKit

/// A Terminal tab. Tab titles churn as commands run, so a title-keyed note would vanish
/// mid-build; the tty (/dev/ttys003) is the only stable tab identity, and it costs one
/// Apple event on the 0.4s poll.
final class TerminalContainer: GenericAppContainer {
    static let bundleID = "com.apple.Terminal"

    private static let ttyScript = NSAppleScript(
        source: """
            tell application "Terminal"
                if (count of windows) is 0 then return ""
                return tty of selected tab of front window
            end tell
            """)

    private let tty: String?

    override init?(app: NSRunningApplication) {
        tty = TerminalContainer.currentTTY()
        super.init(app: app)
    }

    /// nil when Terminal has no window, or when the automation prompt was denied — the
    /// container then binds at window level rather than failing.
    static func currentTTY() -> String? {
        var err: NSDictionary?
        guard let s = ttyScript?.executeAndReturnError(&err).stringValue, !s.isEmpty else {
            return nil
        }
        return s
    }

    override var path: [String] {
        guard let tty else { return [bundleID, ident] }  // no tty → window level
        return [bundleID, ident, tty]
    }

    override var finestKey: String? {
        guard let tty else { return nil }
        return Container.key(path: [bundleID, tty], level: 1)
    }
}
