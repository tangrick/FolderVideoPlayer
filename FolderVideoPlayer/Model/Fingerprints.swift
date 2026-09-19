import CryptoKit
import Foundation

/// What the index knows about one file.
struct PrintEntry: Codable {
    var size: Int64
    var mtime: Double
    var fp: String
    var full: String?
    var seen: Double
}

enum Fingerprints {
    /// A cheap identity for a video: its size, and both of its ends.
    ///
    /// Reading a whole file to find duplicates is the obvious design and the
    /// wrong one on a library this size — it means moving terabytes over SMB.
    /// Reading a chunk from each end costs the same 128 KB whether the file is
    /// 4 MB or 400 MB, and two videos agreeing on their size and both ends are
    /// not plausibly different videos. Not proof, which is why removing
    /// anything can still verify in full: this is the sieve, not the verdict.
    static func fingerprint(_ path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: Data(String(size).utf8))
        do {
            if let head = try handle.read(upToCount: Tuning.fpChunk) {
                hasher.update(data: head)
            }
            if size > Int64(Tuning.fpChunk * 2) {
                // Only worth a second read when the ends do not already overlap.
                try handle.seek(toOffset: UInt64(size - Int64(Tuning.fpChunk)))
                if let tail = try handle.read(upToCount: Tuning.fpChunk) {
                    hasher.update(data: tail)
                }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The whole file, for the handful that reach the last stage. `stop` is
    /// checked between blocks so a cancelled scan does not have to finish
    /// reading a 4 GB file first.
    static func fullHash(_ path: String, stop: () -> Bool) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if stop() { return nil }
            guard let block = try? handle.read(upToCount: Tuning.hashBlock),
                  !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Keys whose size is shared with something else — the only ones worth
    /// reading. Four files in five are eliminated here for free, because the
    /// size came with the directory listing.
    static func sizeCandidates(_ sizes: [String: Int64]) -> [String] {
        var counts: [Int64: Int] = [:]
        for size in sizes.values { counts[size, default: 0] += 1 }
        return sizes.filter { counts[$0.value, default: 0] > 1 }.keys.sorted()
    }

    /// The index turned into sets of files that are the same file.
    ///
    /// Grouped on the fingerprint, always. The full hash is a check applied
    /// inside a group, not a second way of grouping: keying on it meant a
    /// group only half verified split into a verified pair and an unverified
    /// leftover and then vanished from the results, which is an alarming
    /// thing for a feature about deleting files to do.
    ///
    /// Where two full hashes inside one group disagree, the fingerprint was
    /// wrong about at least one of them and the hashes win — the group splits
    /// by hash, and anything not yet read is left out until it has been.
    static func duplicateGroups(_ index: [String: PrintEntry],
                                verifiedOnly: Bool = false) -> [[String]] {
        var candidates: [String: [String]] = [:]
        for (key, entry) in index where !entry.fp.isEmpty {
            candidates[entry.fp, default: []].append(key)
        }
        var groups: [[String]] = []
        for keys in candidates.values where keys.count > 1 {
            let hashes = Set(keys.compactMap { index[$0]?.full })
            if hashes.count > 1 {
                for mark in hashes.sorted() {
                    let agree = keys.filter { index[$0]?.full == mark }.sorted()
                    if agree.count > 1 { groups.append(agree) }
                }
                continue
            }
            if verifiedOnly && !keys.allSatisfy({ index[$0]?.full != nil }) { continue }
            groups.append(keys.sorted())
        }
        return groups
    }
}
