import AppKit
import Security

/// Keeps Tack current from its GitHub Releases: looks for a newer version once a day (and when
/// asked from the menu), and — only once the user says yes — downloads the zip built for this
/// Mac's chip, checks it, swaps it in for the running app and relaunches.
final class Updater {
    static let repo = "elvisperlika/tack"

    /// A release worth offering: its version (no "v"), this Mac's zip, and its page.
    struct Release: Equatable {
        let version: String
        let download: URL
        let page: URL
    }

    /// The version this copy was built as, stamped into Info.plist by bundle.sh.
    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var timer: Timer?
    private var busy = false  // one check or install at a time
    /// A version the user put off this session: the daily check won't ask about it again until
    /// the next launch. A check from the menu always asks.
    private var postponed: String?

    /// First look a little after launch, so it never competes with Tack starting up; then daily.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(quietly: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(quietly: true)
        }
        timer?.tolerance = 60 * 60
    }

    /// `quietly`: the scheduled check, which says nothing unless there is something to install.
    func check(quietly: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            do {
                let found = try await Self.latest()
                self?.offer(found, quietly: quietly)
            } catch {
                if !quietly { Self.alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    // MARK: - Finding a release

    private static func latest() async throws -> Release? {
        try release(from: await api("releases/latest"), appleSilicon: runningOnAppleSilicon)
    }

    /// How many stars the repository has — for the settings page.
    static func stars() async throws -> Int { try stars(from: await api("")) }

    static func stars(from json: Data) throws -> Int {
        struct Repo: Decodable { let stargazers_count: Int }
        return try JSONDecoder().decode(Repo.self, from: json).stargazers_count
    }

    /// One unauthenticated call to GitHub's API about this repository (60 an hour per address,
    /// far more than a daily check and the odd settings visit need).
    private static func api(_ path: String) async throws -> Data {
        let base = "https://api.github.com/repos/\(repo)"
        var request = URLRequest(url: URL(string: path.isEmpty ? base : "\(base)/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tack-Updater", forHTTPHeaderField: "User-Agent")  // GitHub's API requires one
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.unreachable
        }
        return data
    }

    /// The Apple-silicon zip on an arm64 build, the Intel one otherwise. Compile time on purpose:
    /// an Intel build under Rosetta keeps updating to the Intel build it is.
    static var runningOnAppleSilicon: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    /// GitHub's "latest release" reply, cut down to what an update needs. nil when the release
    /// has no zip for this chip — a half-published release is not an update yet.
    static func release(from json: Data, appleSilicon: Bool) throws -> Release? {
        struct Reply: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: json)
        let wanted = "Tack-\(reply.tag_name)-\(appleSilicon ? "apple-silicon" : "intel").zip"
        guard let zip = reply.assets.first(where: { $0.name == wanted }) else { return nil }
        let version = reply.tag_name.hasPrefix("v") ? String(reply.tag_name.dropFirst()) : reply.tag_name
        return Release(version: version, download: zip.browser_download_url, page: reply.html_url)
    }

    /// "1.10.0" is newer than "1.9.2": compared number by number, not as text. A part that
    /// isn't a number counts as 0, and a missing one as 0, so "1.7" equals "1.7.0".
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let bare = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let numbers = bare.split(separator: ".").map { Int($0) ?? 0 }
            return numbers + Array(repeating: 0, count: max(0, 3 - numbers.count))
        }
        let a = parts(candidate)
        let b = parts(installed)
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    // MARK: - Offering it

    @MainActor private func offer(_ release: Release?, quietly: Bool) {
        let installed = Self.installedVersion
        guard let release, Self.isNewer(release.version, than: installed) else {
            if !quietly { Self.alert("Tack is up to date", "You have the latest version, \(installed).") }
            return
        }
        if quietly && postponed == release.version { return }

        let alert = NSAlert()
        alert.messageText = "Tack \(release.version) is available"
        alert.informativeText =
            "You have \(installed). Tack will download the new version, replace itself and restart. Your notes are not touched."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "What's New")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.page)
            postponed = release.version
        default:
            postponed = release.version
        }
    }

    // MARK: - Installing it

    enum UpdateError: LocalizedError {
        case unreachable, notInstalled, badArchive, wrongApp, badSignature(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unreachable: return "GitHub didn't answer. Try again later."
            case .notInstalled: return "Only an installed Tack.app can update itself."
            case .badArchive: return "The download didn't contain Tack.app."
            case .wrongApp: return "The download isn't the version that was offered."
            case .badSignature(let status): return "The download's signature is not valid (\(status))."
            }
        }
    }

    @MainActor private func install(_ release: Release) {
        busy = true
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            do {
                let app = try await Self.download(release)
                try Self.swapIn(app)
                Self.relaunch()
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Tack couldn't update itself"
                alert.informativeText = error.localizedDescription + "\nYou can download it by hand instead."
                alert.addButton(withTitle: "Open the Release Page")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    /// Downloads and unpacks the zip, and checks that what came out is the Tack that was offered,
    /// intact. Returns the unpacked Tack.app, still in a temporary folder.
    ///
    /// shortcut: trust rests on HTTPS from GitHub plus a valid signature, not on *whose*
    /// signature it is. Once every release is signed with the CI certificate, pin its leaf hash
    /// here (a SecRequirement) so a compromised release page can't hand over another signer's app.
    private static func download(_ release: Release) async throws -> URL {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw UpdateError.notInstalled }
        let (file, _) = try await URLSession.shared.download(from: release.download)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tack-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("Tack.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        // ditto, not a zip library: it is what CI packed the bundle with, and keeps its metadata.
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])

        let app = folder.appendingPathComponent("Tack.app")
        guard let bundle = Bundle(url: app) else { throw UpdateError.badArchive }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
            bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version
        else { throw UpdateError.wrongApp }

        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        if status == errSecSuccess, let code {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
            status = SecStaticCodeCheckValidity(code, flags, nil)
        }
        guard status == errSecSuccess else { throw UpdateError.badSignature(status) }
        return app
    }

    /// Puts the new app where the running one lives. Safe while Tack runs: the running binary
    /// stays mapped until it quits, and the old bundle goes only once the new one is in place.
    private static func swapIn(_ app: URL) throws {
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
    }

    /// Quits through AppKit — which flushes every pending save first — and opens the new copy
    /// once this process has gone. The path goes in as an argument, never into the script text.
    private static func relaunch() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        try? wait.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { p in
                p.terminationStatus == 0 ? done.resume() : done.resume(throwing: UpdateError.badArchive)
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
