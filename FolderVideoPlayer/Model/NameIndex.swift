import Foundation

/// A per-share index of every video file, filed next to the tags in
/// `.FolderVideoPlayer/name-index.json`. The moved-video scan walks the whole
/// share once to build it; after that, "where is Beach.mp4?" is a dictionary
/// lookup plus one stat, instead of a 39-second SMB walk.
///
/// Keys are share-relative (the same convention as tag keys), so the file
/// means the same thing whichever Mac mounts the share. Entries can go stale
/// when files move on — every hit is verified with a stat before use, and a
/// miss just falls back to a targeted hunt.
struct NameIndex: Codable {
    var generated: Date
    /// lowercased file name → share-relative paths (tag-key style)
    var files: [String: [String]]

    static let maxAge: TimeInterval = 7 * 24 * 3600

    static func url(forShare share: String) -> URL {
        URL(fileURLWithPath: Paths.volumes + share)
            .appendingPathComponent(Paths.shareDir)
            .appendingPathComponent("name-index.json")
    }

    /// The index for a share, or nil when there is none yet.
    static func load(share: String) -> NameIndex? {
        guard let data = try? Data(contentsOf: url(forShare: share)) else { return nil }
        return try? JSONDecoder().decode(NameIndex.self, from: data)
    }

    /// Every fresh index across the mounted shares, merged.
    static func freshAcrossShares(_ shares: [String], now: Date = Date()) -> [String: [String]] {
        var merged: [String: [String]] = [:]
        for share in shares {
            guard let index = load(share: share),
                  now.timeIntervalSince(index.generated) < maxAge else { continue }
            for (name, keys) in index.files {
                merged[name, default: []].append(contentsOf: keys)
            }
        }
        return merged
    }

    /// Write atomically — a half-written index is worse than none.
    func save(share: String) {
        let url = Self.url(forShare: share)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Replace one share's entries with a fresh walk, keeping the others.
    /// Shape: share name → name → share-relative keys (what locateNames saw).
    static func absorb(_ seen: [String: [String: [String]]]) {
        for (share, files) in seen {
            NameIndex(generated: Date(), files: files).save(share: share)
        }
    }

    /// Pure: split orphan names into index-verified hits and names that need
    /// a real hunt. `exists` is injected so tests can fake the disk.
    nonisolated static func resolve(
        names: Set<String>,
        index: [String: [String]],
        exists: (String) -> Bool
    ) -> (found: [String: [String]], hunt: Set<String>) {
        var found: [String: [String]] = [:]
        var hunt = Set<String>()
        for name in names {
            let live = (index[name] ?? []).filter(exists)
            if live.isEmpty {
                hunt.insert(name)
            } else {
                found[name] = live
            }
        }
        return (found, hunt)
    }
}
