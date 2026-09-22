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
