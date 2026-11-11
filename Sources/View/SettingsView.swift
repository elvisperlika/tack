import AppKit

/// The dashboard's settings page. For now just which Tack this is and where it comes from.
final class SettingsView: NSView {
    /// "★ 12 stars" under the link. Empty until GitHub answers, and left empty if it doesn't:
    /// a page that can't reach the network just doesn't mention stars.
    private let stars = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        autoresizingMask = [.width, .height]

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Tack")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.textColor = .labelColor

        let version = NSTextField(labelWithString: "Version \(Updater.installedVersion)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true  // so a bug report can paste it

        let link = NSButton(
            title: "github.com/\(Updater.repo)", target: self, action: #selector(openGitHub))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 12)
        link.setAccessibilityLabel("Open Tack on GitHub")

        stars.font = .systemFont(ofSize: 12)
        stars.textColor = .secondaryLabelColor

        let column = NSStackView(views: [icon, name, version, link, stars])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.setCustomSpacing(12, after: icon)
        column.setCustomSpacing(12, after: version)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Every time the page goes up, so the count is fresh rather than from the first visit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let count = try? await Updater.stars() else { return }
            let line = NSMutableAttributedString(
                string: "★", attributes: [.foregroundColor: NSColor.systemYellow])
            line.append(NSAttributedString(
                string: " \(count) \(count == 1 ? "star" : "stars")",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            line.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: line.length))
            self?.stars.attributedStringValue = line
        }
    }

    // The cursor says it's a link, like the text says.
    override func resetCursorRects() {
        for case let button as NSButton in subviews.flatMap({ $0.subviews }) {
            addCursorRect(convert(button.bounds, from: button), cursor: .pointingHand)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/\(Updater.repo)") { NSWorkspace.shared.open(url) }
    }
}
