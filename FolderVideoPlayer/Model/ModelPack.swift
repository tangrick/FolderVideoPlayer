import Foundation

/// Optional catalog metadata. A version describes the pack contract, not the
/// model's marketing name. Legacy catalogs remain readable without this value.
struct ModelPackDescriptor: Codable, Equatable {
    var version: Int
    var modelID: String
    var revision: String
    var adapter: String
    var minimumMacOS: String
    var architectures: [String]
    var license: String
    var sourceURL: String

    /// This first slice describes only adapters already wired into the app.
    /// Adding a catalog entry cannot turn an arbitrary checkpoint into one.
    func incompatibility(feature: String, environment: ModelPackEnvironment = .current) -> String? {
        guard version == 1 else { return "This model pack needs a newer app." }
        let supported: [String: String] = [
            "tags": "siglip2-base-v1",
            "classify": "falconsai-v1",
            "faces": "yunet-sface-v1",
            // The speech adapter is the app's own WhisperKit wrapper. It is not a
            // URL or a model name: it is the contract that says the app knows how
            // to feed audio to this pack and read words back out. A catalogue
            // entry that names anything else is refused rather than half-used.
            "speech": "whisperkit-large-v3-turbo-v1"
        ]
        guard supported[feature] == adapter else {
            return "This app does not support the pack’s model adapter."
        }
        guard architectures.contains(environment.architecture) else {
            return "This model pack does not support this Mac’s architecture."
        }
        guard let required = Self.osComponents(minimumMacOS),
              let actual = Self.osComponents(environment.macOSVersion) else {
            return "The model pack has an invalid macOS requirement."
        }
        for (have, need) in zip(actual, required) {
            if have > need { return nil }
            if have < need { return "This model pack requires macOS \(minimumMacOS) or later." }
        }
        return nil
    }

    static func osComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        return values + Array(repeating: 0, count: 3 - values.count)
    }
}

struct ModelPackEnvironment {
    var architecture: String
    var macOSVersion: String

    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(architecture: architecture,
                    macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

/// Catalog data names files the app may replace or remove. Validate the whole
/// operation before any I/O, and resolve existing symlinks at the write boundary.
/// This is confinement, not catalog authentication (a separate release gate).
enum ModelCatalogPolicy {
    static func validate(_ manifest: AIBundleManifest) throws {
        guard manifest.version == AIBundleManifest.currentVersion else {
            if manifest.version > AIBundleManifest.currentVersion {
                throw ModelInstallError.tooNew(manifest.version)
            }
            throw ModelInstallError.invalidCatalogue("unsupported catalog version")
        }
        var ids = Set<String>()
        var destinations: [String] = []
        for bundle in manifest.bundles {
            guard ids.insert(bundle.id).inserted else {
                throw ModelInstallError.invalidCatalogue("duplicate bundle ID: \(bundle.id)")
            }
            try validate(bundle)
            for asset in bundle.assets {
                try addDestination(asset.install, to: &destinations)
            }
        }
    }

    static func validate(_ bundle: AIBundle) throws {
        guard !bundle.id.isEmpty, bundle.id.utf8.count <= 100,
              bundle.id.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 95
              }), !bundle.assets.isEmpty else {
            throw ModelInstallError.invalidCatalogue("invalid bundle ID or empty asset list")
        }
        var total: Int64 = 0
        var destinations: [String] = []
        for asset in bundle.assets {
            guard secureURL(asset.url) != nil else { throw ModelInstallError.badURL(asset.url) }
            guard asset.sha256.utf8.count == 64,
                  asset.sha256.utf8.allSatisfy({
                      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                  }), asset.bytes > 0 else {
                throw ModelInstallError.invalidCatalogue("invalid checksum or size: \(asset.install)")
            }
            let sum = total.addingReportingOverflow(asset.bytes)
            guard !sum.overflow else { throw ModelInstallError.invalidCatalogue("asset sizes overflow") }
            total = sum.partialValue
            try validatePath(asset.install)
            try addDestination(asset.install, to: &destinations)
        }
        if let pack = bundle.pack {
            guard !pack.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.adapter.isEmpty, !pack.license.isEmpty,
                  !pack.architectures.isEmpty, Set(pack.architectures).count == pack.architectures.count,
                  ModelPackDescriptor.osComponents(pack.minimumMacOS) != nil,
                  secureURL(pack.sourceURL) != nil else {
                throw ModelInstallError.invalidCatalogue("incomplete model pack metadata: \(bundle.id)")
            }
        }
    }

    static func secureURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // Never permit catalog-driven replacement of tags.json or other user
        // records. Existing packs all live in these two model-only locations.
        guard parts.count >= 2, ["tags", "models"].contains(String(parts[0])),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
              !path.lowercased().hasPrefix("models/downloads/") else {
            throw ModelInstallError.invalidCatalogue("unsafe model install path: \(path)")
        }
        guard path.lowercased() != "models/downloads" else {
            throw ModelInstallError.invalidCatalogue("reserved model install path: \(path)")
        }
        // The installer stages every placement beside its destination as
        // `<destination>.partial` and replaces whatever is already there
        // without looking — that is the crash guard. So no catalog asset may
        // sit at, or inside a directory named like, a staging path: such an
        // asset is a file the installer is licensed to destroy, and installing
        // the next asset silently deleted the one before it. Reserved by shape
        // (any `.partial` component, any case, so order and case-insensitive
        // volumes cannot smuggle one past) rather than by filename, and here
        // rather than only in `validate(_:)` so the write boundary refuses it
        // too.
        guard !parts.contains(where: { $0.lowercased().hasSuffix(".partial") }) else {
            throw ModelInstallError.invalidCatalogue("reserved staging name in model install path: \(path)")
        }
        // Transactional activation keeps the previous version of every asset
        // beside it as `<destination>.previous` until the whole bundle is in
        // place, and records installed identities under `models/receipts`.
        // Both are installer-owned the same way: a catalog asset there would be
        // overwritten by a rollback or deleted by receipt maintenance.
        guard !parts.contains(where: { $0.lowercased().hasSuffix(".previous") }),
              !(parts.count >= 2 && parts[0].lowercased() == "models"
                && parts[1].lowercased() == "receipts") else {
            throw ModelInstallError.invalidCatalogue("reserved transaction name in model install path: \(path)")
        }
        // The model-choice record lives here too. A catalog that could write it
        // could choose which pack the app loads — a decision that belongs to the
        // user — and could also name a pack that is not installed.
        guard !(parts.count >= 2 && parts[0].lowercased() == "models"
                && parts[1].lowercased() == "selected.json") else {
            throw ModelInstallError.invalidCatalogue("reserved model-choice name in model install path: \(path)")
        }
        // The installed-space identity marker lives beside the artifacts it
        // identifies. A catalog that could write it could forge the identity
        // of its own space, so it is reserved like the receipts are.
        guard !(parts.count >= 2 && parts[0].lowercased() == "tags"
                && parts[1].lowercased() == "installed.digest") else {
            throw ModelInstallError.invalidCatalogue("reserved space-identity name in model install path: \(path)")
        }
        // And the kept versions of what was installed. A catalog that could
        // install here could overwrite a version the user can switch back to,
        // or plant one that installs something other than what it claims.
        guard !(parts.count >= 2 && parts[0].lowercased() == "models"
                && parts[1].lowercased() == "packs") else {
            throw ModelInstallError.invalidCatalogue("reserved kept-version path: \(path)")
        }
    }

    static func destination(_ path: String, root: String) throws -> URL {
        try validatePath(path)
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(path).standardizedFileURL
        // No symlink component is allowed, even if it currently points inside
        // the root: a later removal must never follow a catalog-controlled link.
        var component = base
        for part in path.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw ModelInstallError.invalidCatalogue("symlink in model install path: \(path)")
            }
        }
        guard target.path.hasPrefix(base.path + "/") else {
            throw ModelInstallError.invalidCatalogue("model install path leaves support directory")
        }
        return target
    }

    private static func addDestination(_ path: String, to existing: inout [String]) throws {
        // Default macOS volumes are case-insensitive. Reject aliasing on every
        // filesystem so the same catalog is safe on all supported machines.
        let key = path.precomposedStringWithCanonicalMapping.lowercased()
        guard !existing.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else {
            throw ModelInstallError.invalidCatalogue("overlapping model install paths: \(path)")
        }
        existing.append(key)
    }
}
