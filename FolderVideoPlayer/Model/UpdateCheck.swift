import Foundation

/// Is there a newer release on the public repo than the one running?
///
/// Asked only when the user chooses Check for Updates — the app does not phone
/// home on its own. The answer is GitHub's "latest release" (drafts and
/// pre-releases excluded by GitHub itself), compared by version number.
enum UpdateCheck {
    static let repo = "tangrick/FolderVideoPlayer"

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let assets: [Asset]

        /// The tag without its "v": "v1.1.10" → "1.1.10".
        var version: String { UpdateCheck.bare(tag_name) }
        /// The disk image to download, when the release carries one.
        var dmg: URL? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                .flatMap { URL(string: $0.browser_download_url) }
        }
    }

    /// The version this build calls itself (MARKETING_VERSION).
    static var running: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func bare(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
    }

    /// Numeric, part by part: 1.1.10 is newer than 1.1.9, and 1.2 equals
    /// 1.2.0. A part that is not a number counts as 0, so a malformed tag can
    /// never read as newer than a real one.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(bare(candidate)), b = parts(bare(current))
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: - installing

    /// Why an update cannot be installed in place, so the check can fall back
    /// to handing the DMG to the browser.
    ///
    /// A build run from Xcode lives in DerivedData and must never be swapped
    /// for a release; a folder the user cannot write to cannot take the swap.
    static func cannotInstallInPlace(bundlePath: String) -> String? {
        if bundlePath.contains("/DerivedData/") || !bundlePath.hasSuffix(".app") {
            return "this copy is a development build"
        }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "the app's folder cannot be written to"
        }
        return nil
    }

    enum InstallFailure: Error, LocalizedError {
        case download(String)
        case mount
        case noApp
        case unsigned(String)
        case wrongVersion(String)
        case stage(String)

        var errorDescription: String? {
            switch self {
            case .download(let why): return "the download did not finish (\(why))"
            case .mount: return "the disk image could not be opened"
            case .noApp: return "the disk image has no FolderVideoPlayer app in it"
            case .unsigned(let why): return "the new app failed its signature check (\(why)) — nothing was installed"
            case .wrongVersion(let v): return "the disk image holds version \(v), not the one offered"
            case .stage(let why): return "the new app could not be put in place (\(why))"
            }
        }
    }

    /// The Developer ID team a bundle is signed by, from `codesign -dv`'s
    /// report ("TeamIdentifier=ABCDE12345"). Nil when unsigned or ad hoc.
    static func teamIdentifier(fromCodesignReport report: String) -> String? {
        for line in report.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return team.isEmpty || team == "not set" ? nil : team
        }
        return nil
    }

    /// Download the release's DMG, open it, and check the app inside before
    /// anything is replaced: a valid signature from the SAME team as the
    /// running app, Gatekeeper's approval, and the version the release claims.
    /// The checked app is copied beside the installed one, ready for the swap.
    /// Returns where it was put.
    static func prepare(_ release: Release, installedAt bundlePath: String) async throws -> String {
        guard let dmgURL = release.dmg else { throw InstallFailure.noApp }
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "fvp-update-\(UUID().uuidString)"
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: work) }

        let dmg = work + "/update.dmg"
        do {
            let (file, response) = try await URLSession.shared.download(from: dmgURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallFailure.download("HTTP \(http.statusCode)")
            }
            try fm.moveItem(at: file, to: URL(fileURLWithPath: dmg))
        } catch let failure as InstallFailure {
            throw failure
        } catch {
            throw InstallFailure.download(error.localizedDescription)
        }

        let mount = work + "/mount"
        try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
        guard try await tool("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-readonly", "-quiet",
                                                  "-mountpoint", mount]).status == 0
        else { throw InstallFailure.mount }
        // Detached before the work folder (which holds the mount point) goes,
        // whether the checks passed or not.
        let staged: Result<String, Error>
        do {
            staged = .success(try await stage(from: mount, release: release, installedAt: bundlePath))
        } catch {
            staged = .failure(error)
        }
        _ = try? await tool("/usr/bin/hdiutil", ["detach", mount, "-quiet", "-force"])
        return try staged.get()
    }

    /// Check the app on the mounted image and copy it beside the installed one.
    private static func stage(from mount: String, release: Release,
                              installedAt bundlePath: String) async throws -> String {
        let fm = FileManager.default
        let name = (bundlePath as NSString).lastPathComponent
        // The release's name, not the installed one's — a renamed copy still updates.
        let inside = (mount as NSString).appendingPathComponent("FolderVideoPlayer.app")
        guard fm.fileExists(atPath: inside) else { throw InstallFailure.noApp }

        // The same team that signed the app running now, and nothing weaker.
        let mine = teamIdentifier(fromCodesignReport: try await tool("/usr/bin/codesign",
                                                                     ["-dv", "--verbose=2", bundlePath]).text)
        let theirs = teamIdentifier(fromCodesignReport: try await tool("/usr/bin/codesign",
                                                                       ["-dv", "--verbose=2", inside]).text)
        guard try await tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", inside]).status == 0
        else { throw InstallFailure.unsigned("the signature is not valid") }
        guard let theirs, theirs == mine else {
            throw InstallFailure.unsigned("signed by \(theirs ?? "nobody"), not \(mine ?? "this app's team")")
        }
        guard try await tool("/usr/sbin/spctl", ["-a", "-t", "exec", inside]).status == 0
        else { throw InstallFailure.unsigned("Gatekeeper did not accept it") }

        let plist = (inside as NSString).appendingPathComponent("Contents/Info.plist")
        let version = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? "?"
        guard version == release.version else { throw InstallFailure.wrongVersion(version) }

        // Beside the installed app, so the swap is a rename on one volume.
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let staged = (parent as NSString).appendingPathComponent(".\(name).update")
        try? fm.removeItem(atPath: staged)
        guard try await tool("/usr/bin/ditto", [inside, staged]).status == 0 else {
            try? fm.removeItem(atPath: staged)
            throw InstallFailure.stage("copying it out of the disk image failed")
        }
        return staged
    }

    /// The script that finishes the job once the app has quit: an app cannot
    /// replace itself while running. It swaps rather than deletes-then-copies,
    /// and puts the old app back if the swap fails, so a failed update never
    /// leaves no app at all. Then it opens whichever app is in place.
    static func swapScript(installed: String, staged: String, pid: Int32) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        APP=\(q(installed))
        NEW=\(q(staged))
        OLD="$APP.old"
        for _ in $(seq 1 300); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        rm -rf "$OLD"
        if mv "$APP" "$OLD"; then
            if mv "$NEW" "$APP"; then
                rm -rf "$OLD"
            else
                mv "$OLD" "$APP"
            fi
        fi
        rm -rf "$NEW"
        open "$APP"
        rm -f "$0"
        """
    }

    /// Hand the swap to a detached script and return; the caller quits next.
    static func launchSwap(installed: String, staged: String) throws {
        let script = NSTemporaryDirectory() + "fvp-update-\(UUID().uuidString).sh"
        try swapScript(installed: installed, staged: staged,
                       pid: ProcessInfo.processInfo.processIdentifier)
            .write(toFile: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `nohup … &` so the script outlives the app it is waiting on.
        process.arguments = ["-c", "nohup /bin/bash \(swapQuote(script)) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
    }

    private static func swapQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ToolResult { var status: Int32; var text: String }

    /// Run a system tool and collect everything it printed, stdout and stderr
    /// together (`codesign -dv` reports on stderr).
    private static func tool(_ path: String, _ args: [String]) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ToolResult(status: finished.terminationStatus,
                                                          text: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// The latest published release. Throws on no network or a bad reply.
    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FolderVideoPlayer/\(running)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}
