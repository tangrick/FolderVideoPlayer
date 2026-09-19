import Foundation

/// Kept versions of an installed pack — what makes "which pack" a real choice
/// rather than a choice of one, and the rollback half of T03.
///
/// An install is destructive by design: every asset lands at the fixed path its
/// catalog entry names, so installing revision 2 of a pack overwrites revision
/// 1 and there is nothing left to go back to. Model files are also the one
/// thing here that cannot be re-derived — they are 18 MB to 350 MB of weights
/// that arrived over a network, and a user who finds a new revision worse has no
/// way back but downloading the old one again.
///
/// So every install keeps a copy of what it installed, under
/// `models/packs/<bundle>/<digest>/`, and activating a kept version is the
/// ordinary install transaction fed with those files instead of a download: no
/// network, no compiler, no second transaction to get wrong.
///
/// What this is deliberately not: a second answer to "is it installed". The
/// live files plus the receipt stay the authority (`AIBundle.isInstalled`,
/// `InstalledReceipt`). A kept version is an OFFLINE copy — it changes nothing
/// on its own, and `isLive(root:)` answers "is this the one in force" by asking
/// the receipt, not by keeping a note of its own.
///
/// Layout, all app-owned and reserved from catalogs:
///
///     models/packs/<bundle id, sanitised>/<first 12 of the catalog digest>/
///         version.json                     what this version is — written LAST
///         <the asset's own install path>   the files, exactly as installed
///
/// The directory is named by the digest of the bundle's catalog data, so the
/// same catalog entry kept twice is one directory while a changed bundle is a
/// new one. `version.json` is written last and the directory is built under a
/// temporary name and moved into place, so a copy that crashed is invisible
/// rather than offered as a version that would half-install.
struct StoredVersion: Codable, Equatable {
    /// Directory name: the first 12 hex of `digest`.
    var token: String
    /// SHA-256 of the bundle's canonical catalog encoding, as
    /// `InstalledReceipt.catalogDigest` computes it — the same number the
    /// receipt carries, which is how this version is compared against what is
    /// actually installed right now.
    var digest: String
    /// The bundle as it was catalogued. Kept whole: activation needs the asset
    /// list and their checksums, and a version that could not name its own
    /// files would be a version that cannot be re-installed.
    var bundle: AIBundle
    var storedAt: Date
    /// Measured on disk when it was kept, not the catalog's claim.
    var bytes: Int64

    /// What the pack calls itself.
    var title: String { bundle.title }

    var revision: String { bundle.pack?.revision ?? "" }

    var capability: AICapability.Feature? { bundle.capabilityFeature }

    /// "SigLIP2 base · revision r1" — or just the title for a pack that
    /// declared no descriptor, where inventing a revision would be a lie.
    var summary: String {
        revision.isEmpty ? title : title + " · revision " + String(revision.prefix(12))
    }

    /// Is this the version actually installed (rather than merely kept)?
    ///
    /// Asked of the receipt, so there is one answer to that question and it is
    /// the same one every other part of the app reads.
    func isLive(root: String = Paths.support) -> Bool {
        InstalledReceipt.read(bundleID: bundle.id, root: root)?.catalogDigest == digest
    }
}

/// Where kept versions live, and how they are made, listed, activated and
/// removed. The store never decides readiness and never touches a live file:
/// activation goes through `ModelInstaller.activate` like any other install.
enum ModelStore {

    /// How many versions of one pack are kept. Weights are large and a rollback
    /// target two revisions stale is worth less than the disk it occupies; the
    /// oldest is dropped when a newer one is kept.
    static let keepPerBundle = 3

    /// App-owned, beside the receipts and the choice record, and reserved from
    /// catalogs for the same reason they are: an install path here could
    /// overwrite a kept version, or forge one.
    static let directoryName = "models/packs"

    static func packsRoot(root: String = Paths.support) -> String {
        (root as NSString).appendingPathComponent(directoryName)
    }

    /// A bundle id is catalog-controlled, so it is made safe for a single
    /// path component before it names a directory.
    static func safeID(_ bundleID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = bundleID.map { allowed.contains($0) ? $0 : "-" }
        let name = String(mapped)
        return name.isEmpty || name == "." || name == ".." ? "bundle" : name
    }

    static func token(forDigest digest: String) -> String {
        String(digest.prefix(12))
    }

    static func digest(of bundle: AIBundle) -> String {
        InstalledReceipt.catalogDigest(of: bundle)
    }

    /// The directory one version of one bundle lives in.
    static func directory(root: String = Paths.support, bundleID: String, token: String) -> String {
        let perBundle = (packsRoot(root: root) as NSString).appendingPathComponent(safeID(bundleID))
        return (perBundle as NSString).appendingPathComponent(token)
    }

    static func directory(root: String = Paths.support, version: StoredVersion) -> String {
        directory(root: root, bundleID: version.bundle.id, token: version.token)
    }

    private static func versionFile(_ directory: String) -> String {
        (directory as NSString).appendingPathComponent("version.json")
    }

    /// A token is the first 12 hex of a digest, and every other function here
    /// uses it as a path component. Nothing else is allowed near `remove` or
    /// `prepared`, both of which act on a token that came from somewhere else.
    static func isToken(_ value: String) -> Bool {
        value.count == 12 && value == value.lowercased() && value.allSatisfy { $0.isHexDigit }
    }

    /// Read the manifest of a directory, or nil when it is not a whole version.
    ///
    /// The manifest must name the directory it sits in. A copy that died before
    /// it was moved into place leaves `…<token>.keeping/version.json` behind,
    /// and without this check that file reads as a version whose token names a
    /// directory that does not exist: it would be listed in the Kept row, marked
    /// as the version in use (its digest is the live one), take up one of the
    /// kept slots so that a real version got pruned, and never be reclaimable.
    /// The same check is what keeps a token out of a path — this is the last
    /// place a manifest is believed.
    static func read(directory: String) -> StoredVersion? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: versionFile(directory))) else {
            return nil
        }
        guard let version = try? JSONDecoder().decode(StoredVersion.self, from: data) else { return nil }
        guard version.token == (directory as NSString).lastPathComponent,
              isToken(version.token) else { return nil }
        return version
    }

    /// Everything kept, newest first.
    ///
    /// The store is the record — there is no index to fall out of step with it,
    /// and a kept version deleted by hand simply stops being listed rather than
    /// leaving an entry that promises a switch that would fail.
    static func versions(root: String = Paths.support) -> [StoredVersion] {
        let fm = FileManager.default
        let packs = packsRoot(root: root)
        guard let bundles = try? fm.contentsOfDirectory(atPath: packs) else { return [] }
        var found: [StoredVersion] = []
        for bundleDir in bundles.sorted() {
            let perBundle = (packs as NSString).appendingPathComponent(bundleDir)
            guard let tokens = try? fm.contentsOfDirectory(atPath: perBundle) else { continue }
            for token in tokens.sorted() {
                if let version = read(directory: (perBundle as NSString).appendingPathComponent(token)) {
                    found.append(version)
                }
            }
        }
        return found.sorted {
            $0.storedAt == $1.storedAt ? $0.token < $1.token : $0.storedAt > $1.storedAt
        }
    }

    /// The versions kept for one bundle, newest first.
    static func versions(root: String = Paths.support, bundleID: String) -> [StoredVersion] {
        versions(root: root).filter { $0.bundle.id == bundleID }
    }

    /// Bytes a path costs, file or whole directory.
    static func bytes(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        guard let walk = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for item in walk {
            guard let name = item as? String else { continue }
            let child = (path as NSString).appendingPathComponent(name)
            guard let size = (try? fm.attributesOfItem(atPath: child)[.size]) as? Int64 else { continue }
            total += size
        }
        return total
    }

    static func totalBytes(root: String = Paths.support) -> Int64 {
        versions(root: root).reduce(0) { $0 + bytes(at: directory(root: root, version: $1)) }
    }

    /// Keep what is installed right now as a version.
    ///
    /// Copies from the LIVE paths, so what is kept is what the app is really
    /// loading — not what a catalog claimed. A plain file is re-hashed against
    /// the checksum its entry declares before it is kept: a copy of bytes that
    /// do not match the catalog would be kept as a version that installs
    /// something other than what it says (a compiled package is the compiler's
    /// output and has only its existence and size to be checked by, exactly as
    /// the receipt treats it).
    ///
    /// Returns the version now kept, and what was dropped to make room. Storing
    /// the same catalog entry again is a no-op: one directory per digest.
    @discardableResult
    static func keep(root: String = Paths.support,
                     bundle: AIBundle,
                     at date: Date = Date()) throws -> (version: StoredVersion, dropped: [StoredVersion]) {
        try ModelCatalogPolicy.validate(bundle)
        let digest = digest(of: bundle)
        guard !digest.isEmpty else {
            throw ModelInstallError.installFailed(bundle.title, "its catalog entry could not be identified")
        }
        let token = token(forDigest: digest)
        let destination = directory(root: root, bundleID: bundle.id, token: token)
        let fm = FileManager.default

        // Already kept in full: nothing to do, and nothing to drop.
        if let existing = read(directory: destination), existing.digest == digest {
            return (existing, [])
        }

        let building = destination + ".keeping"
        try? fm.removeItem(atPath: building)
        try fm.createDirectory(atPath: building, withIntermediateDirectories: true)

        var measured: Int64 = 0
        do {
            for asset in bundle.assets {
                let live = try ModelCatalogPolicy.destination(asset.install, root: root).path
                var isDirectory = ObjCBool(false)
                guard fm.fileExists(atPath: live, isDirectory: &isDirectory) else {
                    throw ModelInstallError.nothingToRemove(bundle.title + " — nothing to keep at " + asset.install)
                }
                if asset.kind == .file, !ModelVerifier.matches(fileAt: live, sha256: asset.sha256) {
                    let got = (try? ModelVerifier.sha256(fileAt: live)) ?? "unreadable"
                    throw ModelInstallError.hashMismatch(asset.install,
                                                         expected: asset.sha256, got: got)
                }
                let target = (building as NSString).appendingPathComponent(asset.install)
                try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try fm.copyItem(atPath: live, toPath: target)
                measured += bytes(at: target)
            }
            let version = StoredVersion(token: token, digest: digest, bundle: bundle,
                                        storedAt: date, bytes: measured)
            // Written last: until this exists the directory is not a version.
            guard let data = try? JSONEncoder().encode(version) else {
                throw ModelInstallError.installFailed(bundle.title, "the version could not be described")
            }
            try data.write(to: URL(fileURLWithPath: versionFile(building)), options: .atomic)
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination) { try? fm.removeItem(atPath: destination) }
            try fm.moveItem(atPath: building, toPath: destination)
            return (version, prune(root: root, bundleID: bundle.id, keeping: version.token))
        } catch {
            try? fm.removeItem(atPath: building)
            throw error
        }
    }

    /// Drop the oldest versions of one bundle beyond the kept count, or of
    /// every bundle when none is named.
    ///
    /// Only ever versions of the SAME bundle, with their own cap: the store
    /// holds several capabilities' packs, and a bundle that grew a fourth
    /// revision must not drop another capability's last version. Oldest first,
    /// and never the token named in `keeping` — a clock that stepped backwards
    /// must not be able to make this delete the copy that was just made, and
    /// keeping one extra version is a much smaller problem than losing the only
    /// way back. A version that IS dropped is reported, never deleted silently:
    /// switching to it later is a download again, which is the honest cost of a
    /// bounded store.
    @discardableResult
    static func prune(root: String = Paths.support, bundleID: String? = nil,
                      keeping token: String? = nil) -> [StoredVersion] {
        let fm = FileManager.default
        var dropped: [StoredVersion] = []
        let all = versions(root: root).filter { bundleID == nil || $0.bundle.id == bundleID }
        for (_, kept) in Dictionary(grouping: all, by: { $0.bundle.id }) {
            for old in kept.dropFirst(keepPerBundle) where old.token != token {
                let dir = directory(root: root, version: old)
                guard fm.fileExists(atPath: dir) else { continue }
                if (try? fm.removeItem(atPath: dir)) != nil { dropped.append(old) }
            }
        }
        return dropped
    }

    /// Does a kept version still hold what it says it holds?
    ///
    /// Re-hashes every plain file against its catalog checksum, and checks that
    /// a compiled package is present and non-empty. Returns the reason it cannot
    /// be trusted, or nil. Activation refuses a version that fails this: the
    /// whole point of a kept version is going back to known bytes.
    static func trust(root: String = Paths.support, version: StoredVersion) -> String? {
        let fm = FileManager.default
        // A version that came from somewhere other than `versions(root:)` — a
        // tampered manifest, say — never reaches a path here.
        guard isToken(version.token) else {
            return "the kept copy's name is not one this app writes"
        }
        let dir = directory(root: root, version: version)
        guard read(directory: dir) != nil else {
            return "the kept copy is gone"
        }
        for asset in version.bundle.assets {
            let file = (dir as NSString).appendingPathComponent(asset.install)
            guard fm.fileExists(atPath: file) else {
                return "the kept copy is missing \(asset.install)"
            }
            switch asset.kind {
            case .file:
                guard ModelVerifier.matches(fileAt: file, sha256: asset.sha256) else {
                    return "the kept copy of \(asset.install) does not match the checksum it was kept with"
                }
            case .coreMLPackage:
                guard bytes(at: file) > 0 else {
                    return "the kept copy of \(asset.install) is empty"
                }
            }
        }
        return nil
    }

    /// Hand a kept version's files to `ModelInstaller.activate`.
    ///
    /// Copies into staging rather than moving, because the store keeps its
    /// copy: activation moves what it is given, and one switch must not be the
    /// last. That copy is the price of activating an old version without a
    /// network, and it is temporary — `activate` moves each file into place.
    ///
    /// Refuses a version `trust(root:version:)` will not vouch for, before
    /// anything is copied.
    static func prepared(root: String = Paths.support,
                         version: StoredVersion,
                         staging: String) throws -> [(asset: AIBundleAsset, url: URL)] {
        if let why = trust(root: root, version: version) {
            throw ModelInstallError.installFailed(version.summary, why)
        }
        let fm = FileManager.default
        let dir = directory(root: root, version: version)
        try? fm.removeItem(atPath: staging)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var prepared: [(asset: AIBundleAsset, url: URL)] = []
        do {
            for asset in version.bundle.assets {
                let source = (dir as NSString).appendingPathComponent(asset.install)
                // The staged name never matters: `activate` moves the file to
                // the destination its catalog entry names.
                let target = (staging as NSString).appendingPathComponent("asset-\(prepared.count)")
                try fm.copyItem(atPath: source, toPath: target)
                prepared.append((asset, URL(fileURLWithPath: target)))
            }
            return prepared
        } catch {
            try? fm.removeItem(atPath: staging)
            throw ModelInstallError.installFailed(version.summary, error.localizedDescription)
        }
    }

    /// Forget a kept version. Never touches the live files: what is installed
    /// stays installed until it is removed as an install.
    static func remove(root: String = Paths.support, version: StoredVersion) throws {
        guard isToken(version.token) else {
            throw ModelInstallError.installFailed(version.summary,
                                                  "the kept copy's name is not one this app writes")
        }
        let dir = directory(root: root, version: version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else {
            throw ModelInstallError.nothingToRemove(version.summary)
        }
        do {
            try fm.removeItem(atPath: dir)
        } catch {
            throw ModelInstallError.installFailed(version.summary, error.localizedDescription)
        }
    }
}
