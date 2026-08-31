import AppKit

/// A browser tab. The generic key can't tell one Chrome tab from another — they share a window
/// identity that mutates as you switch — so the URL becomes the third path component.
///
/// Note the path keeps `ident` as its second component rather than a prefixed variant, so the
/// level-1 key still matches the pre-Container format and old title-keyed browser notes resolve
/// as window-level notes instead of orphaning.
final class BrowserContainer: GenericAppContainer {
    // Any Chromium/WebKit browser qualifies if it exposes an AXWebArea with a URL — that's the
    // only thing focusedURL needs. Arc is Chromium, so it rides the same path as Chrome.
    static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",  // Arc
    ]
    private let url: String?

    override init?(app: NSRunningApplication) {
        url = AXWindows.focusedURL(pid: app.processIdentifier).map(BrowserContainer.normalize)
        super.init(app: app)
    }

    override var path: [String] {
        guard let url, !url.isEmpty else { return [bundleID, ident] }  // no URL → window level
        return [bundleID, ident, url]
    }

    override var finestKey: String? {
        guard let url, !url.isEmpty else { return nil }
        return Container.key(path: [bundleID, url], level: 1)
    }

    /// scheme + host + path. Query and fragment are session noise.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.host != nil else { return raw }
        c.query = nil
        c.fragment = nil
        return c.url?.absoluteString ?? raw
    }
}
