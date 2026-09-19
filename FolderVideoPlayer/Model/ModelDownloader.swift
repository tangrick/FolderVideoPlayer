import Foundation
import CryptoKit
import CoreML

// MARK: - the catalogue
//
// Phase 5's premise: the shipped app is empty on purpose. Nothing here carries
// data from any machine — the models are the only thing a user has to fetch, and
// they fetch them from inside the app, one feature at a time, rather than from a
// 2 GB DMG or a page of instructions about Homebrew.
//
// ## Why the catalogue is fetched and not compiled in
//
// The bundles are release assets, and their SHA-256s are hashes of the
// *uploaded* artifacts — which cannot exist until the release does. Hardcoding
// them here would mean either a placeholder that never works or a hash that
// silently goes stale the first time an asset is rebuilt. So the catalogue is a
// small JSON published beside the release (`ai-bundles.json`, produced by
// `docs/coreml-spike/pack_bundles.sh`), and this file only knows how to read it.
//
// A catalogue that cannot be fetched is REPORTED, never acted on: the Settings
// row says so rather than offering a button that downloads nothing (pitfall 0).

/// The catalogue: everything the user can choose to download.
///
/// Codable because it is fetched, and `Equatable` because the tests drive it
/// from fixtures and compare whole values.
struct AIBundleManifest: Codable, Equatable {
    /// A newer manifest is REFUSED rather than guessed at — a future version
    /// may rename a field, and installing half of a bundle from a shape this
    /// build does not understand is worse than saying it is too new.
    static let currentVersion = 1

    /// Where the catalogue is published. `latest/download` is GitHub's own
    /// redirect to the newest release's asset of that name, so this never has
    /// to be edited per release.
    ///
    /// **A PUBLIC repo, and it is not the app's repo.** The app fetches this
    /// with no token and no account, so a private repo answers 404 to it — the
    /// source repo is private, and pointing this at it (which is what it used
    /// to do) meant the download list could never be read by anyone, including
    /// the developer's own Mac. `FolderVideoPlayerSwift-AI` is public and holds
    /// nothing but release assets: the bundles and this catalogue. Renaming
    /// or replacing it is a repack plus this one line.
    static let assetsRepo = "tangrick/FolderVideoPlayerSwift-AI"
    static let defaultURL =
        "https://github.com/\(assetsRepo)/releases/latest/download/ai-bundles.json"

    var version: Int
    var bundles: [AIBundle]
}

/// One thing worth downloading, as the user understands it: a feature.
struct AIBundle: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// What the user gets, in their words.
    var what: String
    /// `AICapability.Feature.rawValue` — which feature lights up when this
    /// bundle is installed. Parsed leniently: an id this build does not know is
    /// skipped, so an app can outlive a catalogue that grew a new bundle.
    var feature: String
    var assets: [AIBundleAsset]
    /// Absent in legacy catalogs; never invent revision or license evidence.
    var pack: ModelPackDescriptor? = nil

    /// What the bundle will cost on disk — the sum of what it installs, which
    /// is what the row says before anything is downloaded.
    var bytes: Int64 {
        assets.reduce(0) { sum, asset in
            let next = sum.addingReportingOverflow(max(0, asset.bytes))
            return next.overflow ? Int64.max : next.partialValue
        }
    }

    var incompatibility: String? {
        pack?.incompatibility(feature: feature)
    }

    /// Installed means PROVEN installed, not merely present.
    ///
    /// A receipt written by this build decides when there is one — and it
    /// decides NO just as much as yes. A receipt carrying another bundle's
    /// digest means a different version is installed at these paths (a switch
    /// put it there), so reporting this one installed would offer Remove for a
    /// pack that is not on disk and hide the way back to it.
    ///
    /// With no receipt at all — a legacy pack installed before receipts existed,
    /// or a support root restored from a backup — fall back to the old existence
    /// check, which is exactly as strong as it always was.
    func isInstalled(root: String = Paths.support) -> Bool {
        guard (try? ModelCatalogPolicy.validate(self)) != nil else { return false }
        if let receipt = InstalledReceipt.read(bundleID: id, root: root) {
            return receipt.catalogDigest == InstalledReceipt.catalogDigest(of: self)
                && receipt.matches(root: root)
        }
        return assets.allSatisfy { asset in
            guard let url = try? ModelCatalogPolicy.destination(asset.install, root: root) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    var capabilityFeature: AICapability.Feature? {
        AICapability.Feature(rawValue: feature)
    }
}

/// One file inside a bundle.
struct AIBundleAsset: Codable, Equatable {
    enum Kind: String, Codable {
        /// A Core ML `.mlpackage`. It is COMPILED before it is installed, and
        /// what lands on disk is the `.mlmodelc` directory.
        case coreMLPackage
        /// Anything else — the prompt table's two files.
        case file
    }

    var url: String
    /// Lowercase hex. Required: an unverified 164 MB model is a model whose
    /// bytes nobody has checked, and this app loads one straight into Core ML.
    var sha256: String
    var bytes: Int64
    var kind: Kind
    /// Where it ends up, relative to the support directory — and for a
    /// `.coreMLPackage`, the path the compiled directory takes. This is what
    /// keeps `MLModel.compileModel`'s naming trap out of the install code: the
    /// destination is stated here, so the compiler's output name never matters.
    var install: String
}

// MARK: - the network and the disk

/// The network, behind an interface.
///
/// Everything that can go wrong in this feature — a truncated download, a
/// corrupted byte, a hash that disagrees, an install that half-lands — is worth
/// a test, and none of those tests may depend on a release existing. So the
/// installer talks to this protocol, the app uses `URLSessionTransport`, and the
/// gate uses a fixture that can serve the wrong bytes on purpose.
protocol ModelTransport: Sendable {
    /// Fetch a small document (the catalogue).
    func fetch(_ url: URL) async throws -> Data
    /// Download one file to `destination`, reporting (received, expected) as it
    /// goes. `expected` is 0 when the server does not say.
    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

/// The real network: URLSession, with progress and resumable downloads.
///
/// Resume matters here more than usual: the bundles run from **18 MB** (faces)
/// to **164 MB** (Safe / NSFW), and the alternative to resuming is starting a
/// quarter of a gigabyte again on a connection that has already failed once.
final class URLSessionTransport: NSObject, ModelTransport, @unchecked Sendable {

    func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelInstallError.http(url.absoluteString, http.statusCode)
        }
        return data
    }

    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let resumeURL = URL(fileURLWithPath: destination.path + ".resume")
        let resumeData = try? Data(contentsOf: resumeURL)

        let delegate = DownloadDelegate(destination: destination,
                                        resumeURL: resumeURL,
                                        progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate,
                                delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            task.resume()
        }
    }

    /// One download's delegate. A fresh instance per download, because progress
    /// and the continuation are per-task state — sharing one would mix two
    /// bundles' bytes together the moment two installs overlapped.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let destination: URL
        let resumeURL: URL
        let progress: @Sendable (Int64, Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?

        init(destination: URL, resumeURL: URL,
             progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.resumeURL = resumeURL
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        /// The file must be moved HERE, synchronously: URLSession deletes the
        /// temporary file the moment this returns.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: location, to: destination)
                try? fm.removeItem(at: resumeURL)      // a finished download has nothing to resume
            } catch {
                finish(.failure(ModelInstallError.installFailed(
                    destination.path, error.localizedDescription)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error else { return finish(.success(())) }
            // Keep what the server already sent, so the retry is a continuation
            // rather than a fresh 164 MB.
            if let data = (error as NSError)
                .userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL)
            }
            if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return finish(.failure(ModelInstallError.http(
                    task.currentRequest?.url?.absoluteString ?? destination.path,
                    http.statusCode)))
            }
            finish(.failure(ModelInstallError.transport(error.localizedDescription)))
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

// MARK: - verification

enum ModelVerifier {
    /// The SHA-256 of a file, streamed in 1 MB chunks.
    ///
    /// Streamed on purpose: a 164 MB model read into one `Data` to be hashed is
    /// 164 MB of memory the app does not need to spend, on a machine that may be
    /// busy playing a video.
    static func sha256(fileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ModelInstallError.unreadable(path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Does this file hash to what the catalogue says?
    ///
    /// Qualified on purpose: the parameter is called `sha256`, which shadows the
    /// static function of that name — the unqualified call compiles as an attempt
    /// to call a String.
    static func matches(fileAt path: String, sha256: String) -> Bool {
        guard let got = try? ModelVerifier.sha256(fileAt: path) else { return false }
        return got.caseInsensitiveCompare(sha256) == .orderedSame
    }
}

// MARK: - installing

/// What is installed, as the app can prove it — not as the catalog hopes.
///
/// Existence checks cannot tell a complete model from a mixed-version one, and
/// a support root restored from a backup may hold files from two releases.
/// Written only after a whole bundle is in place, the receipt records the
/// catalog bundle it came from and, for every asset, the install path, the
/// catalog checksum, the size MEASURED as it landed, and the asset kind —
/// which decides how it can be re-checked: plain files re-hash against their
/// catalog checksum; a compiled package is the compiler's own artifact and can
/// only be checked by existence and size.
///
/// A missing receipt never downgrades an existing installation: legacy packs
/// installed before receipts existed stay usable, and `isInstalled` treats
/// them as present. A receipt is REMOVED as soon as its bundle is not, so a
/// stale receipt can never make a deleted model look installed.
struct InstalledReceipt: Codable, Equatable {
    var bundleID: String
    var catalogDigest: String
    var catalogVersion: Int
    var feature: String
    var installedAt: Date
    var assets: [Entry]

    struct Entry: Codable, Equatable {
        var install: String
        var sha256: String
        var bytes: Int64
        /// What the installer was handed: a plain file's bytes are exactly the
        /// catalog's, so they can be re-hashed; a compiled package's output is
        /// the compiler's own artifact and can only be checked by existence
        /// and size (re-hashing it against the archive's digest would always
        /// fail — the compiler writes its own bytes).
        var kind: AIBundleAsset.Kind
    }

    /// SHA-256 of the canonical encoding of a bundle's catalog data — the same
    /// bundle JSON in a different order is a different catalog.
    static func catalogDigest(of bundle: AIBundle) -> String {
        guard let data = try? canonicalEncoder().encode(bundle) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// An encoder whose output for one value is always the same bytes.
    ///
    /// `JSONEncoder` promises nothing about key order, and this build does not
    /// keep one: encoding the same unchanged bundle twice produced two different
    /// documents, so the digest of it was a different number every time it was
    /// taken. That silently weakened every install: the comparison in
    /// `AIBundle.isInstalled` only matched when two encodings happened to agree,
    /// so a receipt almost never identified its bundle and readiness fell back
    /// to the existence check. A digest has to be taken over canonical bytes —
    /// sorted keys are what makes them canonical.
    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func url(bundleID: String, root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("models/receipts/\(bundleID).json"))
    }

    /// Write the receipt AFTER the last asset lands, BEFORE backups are freed.
    static func write(bundle: AIBundle, assets: [(asset: AIBundleAsset, destination: String)],
                      root: String) throws {
        let fm = FileManager.default
        let file = url(bundleID: bundle.id, root: root)
        try fm.createDirectory(atPath: file.deletingLastPathComponent().path,
                               withIntermediateDirectories: true)
        let receipt = InstalledReceipt(
            bundleID: bundle.id,
            catalogDigest: catalogDigest(of: bundle),
            catalogVersion: AIBundleManifest.currentVersion,
            feature: bundle.feature,
            installedAt: Date(),
            // Size is what was MEASURED as this bundle landed, not what the
            // catalog declared: the receipt compares install-time reality
            // against the current disk, and catalogs may round or misstate
            // bytes (the checksum is the declared identity, not the size).
            assets: assets.map { item in
                .init(install: item.asset.install,
                      sha256: item.asset.sha256,
                      bytes: fileSize(at: item.destination) ?? 0,
                      kind: item.asset.kind)
            })
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: file, options: .atomic)
    }

    static func read(bundleID: String, root: String) -> InstalledReceipt? {
        guard let data = try? Data(contentsOf: url(bundleID: bundleID, root: root)) else { return nil }
        return try? JSONDecoder().decode(InstalledReceipt.self, from: data)
    }

    /// Drop the receipt the moment its bundle is not on disk, so a deleted
    /// model can never look installed.
    static func remove(bundleID: String, root: String) {
        try? FileManager.default.removeItem(at: url(bundleID: bundleID, root: root))
    }

    /// Cheap trustworthiness: every asset exists with the size measured when
    /// this bundle was installed. Catches truncation, deletion and
    /// whole-file replacement; not same-size content edits.
    func matches(root: String) -> Bool {
        guard !assets.isEmpty else { return false }
        return assets.allSatisfy { asset in
            guard let size = Self.fileSize(at: (root as NSString).appendingPathComponent(asset.install))
            else { return false }
            return size == asset.bytes
        }
    }

    /// Can the installed files still be trusted as this bundle?
    ///
    /// Every asset must exist with the size measured at install time, and
    /// every plain file must still hash to the checksum the catalog declared —
    /// the same number the installer verified at download time. What this
    /// proves: the files are exactly what was installed, not a leftover from
    /// another version. What it cannot prove: that the files came from a
    /// trustworthy catalog in the first place (that is authentication, T03's
    /// remaining release gate).
    func verify(root: String) -> Bool {
        guard matches(root: root) else { return false }
        return assets.allSatisfy { asset in
            switch asset.kind {
            case .file:
                return ModelVerifier.matches(
                    fileAt: (root as NSString).appendingPathComponent(asset.install),
                    sha256: asset.sha256)
            case .coreMLPackage:
                // The compiled tree is the compiler's output; size + existence
                // is the identity it has. Re-hashing it against the shipped
                // archive's digest would fail by construction.
                return true
            }
        }
    }

    private static func fileSize(at path: String) -> Int64? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            // A compiled package is a directory; its identity is the whole tree.
            guard let walk = FileManager.default.enumerator(atPath: path) else { return nil }
            var total: Int64 = 0
            for item in walk {
                let itemPath = (path as NSString).appendingPathComponent(item as! String)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: itemPath),
                      let size = attributes[.size] as? Int64 else { return nil }
                total += size
            }
            return total
        }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }
}

enum ModelInstallError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case badURL(String)
    case invalidCatalogue(String)
    case incompatible(String)
    case http(String, Int)
    case transport(String)
    case unreadable(String)
    case hashMismatch(String, expected: String, got: String)
    case tooNew(Int)
    case noCatalogue(String)
    case installFailed(String, String)
    case nothingToRemove(String)
    case oversizedAsset(String, limit: Int64)

    var description: String {
        switch self {
        case .badURL(let url):
            return "the catalogue lists a download address that is not a URL with secure HTTPS: \(url)"
        case .invalidCatalogue(let why):
            return "the download list is invalid: \(why)"
        case .incompatible(let why):
            return why
        case .http(let url, let code):
            return "the download was refused (HTTP \(code)) — \(url)"
        case .transport(let why):
            return "the download did not finish: \(why)"
        case .unreadable(let path):
            return "could not read the downloaded file at \(path)"
        case .hashMismatch(let what, let expected, let got):
            return "\(what) did not match its checksum (expected \(expected.prefix(12))…, "
                 + "got \(got.prefix(12))…) — nothing was installed"
        case .tooNew(let version):
            return "the download list was written for a newer version of the app "
                 + "(v\(version)) — ignoring it rather than guessing"
        case .noCatalogue(let why):
            return "could not read the list of downloads: \(why)"
        case .installFailed(let what, let why):
            return "could not install \(what): \(why)"
        case .nothingToRemove(let what):
            return "\(what) is not installed"
        case .oversizedAsset(let what, let limit):
            return "the download for \(what) is bigger than the \(limit)-byte size its catalog "
                 + "entry declared — the catalog is wrong or lying, and nothing was installed"
        }
    }

    var errorDescription: String? { description }
}

/// Download → verify → prepare all → activate transactionally. Compilation
/// failures preserve the existing bundle; a placement failure now rolls the
/// whole bundle back to its previous version.
///
/// The order matters and is the whole point of this type:
///
///  1. **every** asset is downloaded and its SHA-256 checked before **any** of
///     them is installed. A bundle is only useful with all of it, and a failure
///     on the second file must not leave the first one installed — that is a
///     feature that reports Ready and then fails at the first frame.
///  2. each install lands through a `.partial` beside the destination and is
///     renamed into place, so a crash cannot leave a model the app would load.
///  3. activation is transactional: every new asset is staged as
///     `<destination>.partial`, every old version is set aside as
///     `<destination>.previous`, and only when all of them are in place is the
///     receipt written and the backups discarded. A placement failure rolls
///     every moved asset back, so a bundle is the old complete one or the new
///     complete one — never a mix of the two. A crash between renames leaves
///     only staging/backup names, which the next install removes or rolls
///     forward via `recover(_:root:)` before it touches anything.
///
/// Existence checks alone still cannot detect a *logically* mixed installation
/// (two files from different releases that both exist); the receipt's
/// per-asset digests are what make readiness checkable. Versioned activation
/// across bundles and verified install receipts remain the release-line gate.
enum ModelInstaller {

    /// Turn one downloaded asset into the thing that gets installed.
    ///
    /// The seam exists because a downloaded artifact and an installable one are
    /// not the same file: a release asset is a single file and a Core ML package
    /// is a directory, so a package arrives zipped and has to be unwrapped and
    /// compiled. The gate injects its own, so no test needs a real 83 MB model
    /// to prove the install path.
    typealias Preparer = @Sendable (URL, AIBundleAsset) async throws -> URL
    typealias Report = @Sendable (Int64, Int64) -> Void

    /// Where downloads are staged. Under `models/` because that is where the
    /// app's non-encoder artifacts already live. Each install owns and cleans
    /// its own scratch directory; removal must not erase another job's work.
    /// The name carries the owning process ID so `recover` can tell a scratch
    /// directory an install is still using from one a crash left behind.
    static func scratchDir(root: String = Paths.support) -> String {
        (root as NSString).appendingPathComponent("models/downloads")
    }

    /// Size of one file, or nil when it cannot be read.
    private static func fileSize(at path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }

    /// What the app does with a downloaded asset: unwrap it if it is a package,
    /// compile it, and hand back the directory to install.
    static let prepare: Preparer = { file, asset in
        switch asset.kind {
        case .coreMLPackage:
            return try await MLModel.compileModel(at: try ModelArchive.unwrapPackage(file))
        case .file:
            return file
        }
    }

    static func install(_ bundle: AIBundle,
                        root: String = Paths.support,
                        transport: ModelTransport,
                        prepare: Preparer = ModelInstaller.prepare,
                        progress: @escaping Report) async throws {
        try ModelCatalogPolicy.validate(bundle)
        if let why = bundle.incompatibility { throw ModelInstallError.incompatible(why) }
        for asset in bundle.assets {
            _ = try ModelCatalogPolicy.destination(asset.install, root: root)
        }
        // Validate the staging location too: a symlinked models directory must
        // not redirect downloads outside this support root.
        _ = try ModelCatalogPolicy.destination("models/staging-check", root: root)
        let scratchBase = URL(fileURLWithPath: scratchDir(root: root))
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: scratchBase.path)) == nil else {
            throw ModelInstallError.invalidCatalogue("symlink in download staging directory")
        }
        let fm = FileManager.default
        let total = max(bundle.bytes, 1)
        let scratch = (scratchDir(root: root) as NSString)
            .appendingPathComponent("\(bundle.id)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // 1. Everything down, everything checked.
        var staged: [(asset: AIBundleAsset, url: URL)] = []
        var done: Int64 = 0
        for (index, asset) in bundle.assets.enumerated() {
            try Task.checkCancellation()
            guard let url = ModelCatalogPolicy.secureURL(asset.url) else {
                throw ModelInstallError.badURL(asset.url)
            }
            let file = (scratch as NSString).appendingPathComponent("asset-\(index)")
            // `base` is a `let`, so the progress closure captures a value rather
            // than the running total — a `@Sendable` closure may not read a
            // variable another thread is still writing.
            let base = done
            try await transport.download(url, to: URL(fileURLWithPath: file)) { received, _ in
                progress(min(base + received, total), total)
            }
            // The catalog also bounds the download: a host may not stuff the
            // staging file with more bytes than the asset declared. An honest
            // host may still send FEWER bytes — the checksum catches those.
            if let got = fileSize(at: file), got > asset.bytes {
                throw ModelInstallError.oversizedAsset(asset.install, limit: asset.bytes)
            }
            guard ModelVerifier.matches(fileAt: file, sha256: asset.sha256) else {
                let got = (try? ModelVerifier.sha256(fileAt: file)) ?? "unreadable"
                throw ModelInstallError.hashMismatch(asset.install,
                                                     expected: asset.sha256, got: got)
            }
            staged.append((asset, URL(fileURLWithPath: file)))
            done += asset.bytes
            progress(min(done, total), total)
        }

        var prepared: [(asset: AIBundleAsset, url: URL)] = []
        defer {
            // Core ML's compiler may return a temporary directory outside our
            // scratch directory. Clean those up when install exits — anything
            // still here either was moved into place by `activate` (nothing
            // left to remove) or activation failed and it must not leak.
            for item in prepared where item.asset.kind == .coreMLPackage {
                try? fm.removeItem(at: item.url)
            }
        }
        // Compile every asset BEFORE replacing any installed asset. A late
        // compiler failure must not leave old weights with a new prompt table.
        // Nothing has been touched yet, so a crash here is harmless.
        for (asset, file) in staged {
            try Task.checkCancellation()
            prepared.append((asset, try await prepare(file, asset)))
        }
        try Task.checkCancellation()
        try Self.activate(prepared, bundle: bundle, root: root)
    }

    /// Move every prepared asset into place as one transaction, then write the
    /// installed receipt. See the type's contract for the crash cases.
    static func activate(_ prepared: [(asset: AIBundleAsset, url: URL)],
                         bundle: AIBundle,
                         root: String) throws {
        let fm = FileManager.default
        var placed: [(asset: AIBundleAsset, destination: String)] = []
        do {
            for (asset, file) in prepared {
                let destination = try ModelCatalogPolicy.destination(asset.install, root: root).path
                try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try place(file, at: destination, fm: fm)
                placed.append((asset, destination))
            }
            try InstalledReceipt.write(bundle: bundle, assets: placed, root: root)
            // The installed embedding space's identity is re-derived from disk
            // whenever the bundle that owns the image tower lands: any change
            // to it — weights, manifest, filenames — changes the digest, and
            // consumers bound to the old space refuse rather than mix. A
            // described bundle that does not carry the tower (faces, say) must
            // not stamp: the marker describes THIS space, not whichever model
            // happened to be installed last.
            if let pack = bundle.pack,
               bundle.assets.contains(where: {
                   $0.install.lowercased() == "tags/siglip2_base.mlmodelc"
               }) {
                try? ModelSpace.write(adapter: pack.adapter, dim: VisionEmbedder.dim,
                                      root: root, preprocess: ModelSpace.declaredPreprocess)
            }
        } catch {
            // Roll back to the complete previous version. Assets that had no
            // old version are removed; assets that displaced one are restored
            // from the `.previous` backup, which is only deleted on success.
            // The old receipt is deliberately KEPT: it describes exactly the
            // files the rollback restores, so provenance survives the failure.
            for (_, destination) in placed {
                let previous = destination + ".previous"
                if fm.fileExists(atPath: previous) {
                    try? fm.removeItem(atPath: destination)
                    try? fm.moveItem(atPath: previous, toPath: destination)
                } else {
                    try? fm.removeItem(atPath: destination)
                }
            }
            throw error
        }
        // Success: every backup is now dead weight. The receipt has already
        // recorded the identity of what was placed before anything is discarded.
        for (_, destination) in placed {
            try? fm.removeItem(atPath: destination + ".previous")
        }
    }

    /// Take a bundle out again: every path it installed, gone. The installed
    /// space's marker goes with it — but only when the removed bundle owns the
    /// tower itself, so removing an unrelated bundle never unbinds consumers
    /// from a tower that is still installed.
    ///
    /// Reports rather than swallows a path it cannot remove — a Settings row
    /// that says "Removed" over a model still on disk is the lie this app keeps
    /// having to fix.
    static func remove(_ bundle: AIBundle, root: String = Paths.support) throws {
        try ModelCatalogPolicy.validate(bundle)
        // Preflight every destination before removing the first one.
        let destinations = try bundle.assets.map {
            try ModelCatalogPolicy.destination($0.install, root: root).path
        }
        let fm = FileManager.default
        var removed = 0
        for path in destinations {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(atPath: path)
                removed += 1
            } catch {
                throw ModelInstallError.installFailed(path, error.localizedDescription)
            }
        }
        // The marker dies only with the tower it identifies: removing an
        // unrelated bundle must not unbind every consumer from a tower that
        // is still installed. Case-insensitive compare — the volume may not be.
        let towerPath = (root as NSString).appendingPathComponent("tags/siglip2_base.mlmodelc")
        if destinations.contains(where: { $0.lowercased() == towerPath.lowercased() }) {
            try? fm.removeItem(atPath: ModelSpace.digestFile(root: root))
        }
        InstalledReceipt.remove(bundleID: bundle.id, root: root)
        guard removed > 0 else { throw ModelInstallError.nothingToRemove(bundle.title) }
    }

    /// Make the support root honest about a crashed install before relying on
    /// it: finish or discard what a crash left behind.
    ///
    /// A crash mid-activation leaves only installer-owned names — `.partial`
    /// staged assets and `.previous` backups — never a half-set of live
    /// destinations. So recovery is safe without a transaction log: any live
    /// destination with a backup beside it was the half of a transaction whose
    /// new version never finished arriving; restore the backup. Every other
    /// installer-owned file is scratch from a transaction that never reached
    /// the live side; delete it.
    static func recover(_ bundle: AIBundle, root: String = Paths.support) throws {
        try ModelCatalogPolicy.validate(bundle)
        let fm = FileManager.default
        for asset in bundle.assets {
            let destination = try ModelCatalogPolicy.destination(asset.install, root: root).path
            let partial = destination + ".partial"
            let previous = destination + ".previous"
            let live = fm.fileExists(atPath: destination)
            let backup = fm.fileExists(atPath: previous)
            if backup {
                if live { try? fm.removeItem(atPath: destination) }
                do {
                    try fm.moveItem(atPath: previous, toPath: destination)
                } catch {
                    throw ModelInstallError.installFailed(destination, error.localizedDescription)
                }
            }
            if fm.fileExists(atPath: partial) { try? fm.removeItem(atPath: partial) }
        }
        // Staged downloads and their resume files live only in this install's
        // own scratch directory, which the install's `defer` normally cleans.
        // A crash can leave one behind. Entries carry the PID of the process
        // that made them: one made by THIS process may belong to an install
        // still running and is left alone; anything else under this bundle's
        // ID is stale and removed. No other bundle's entries are ever touched.
        let scratchBase = scratchDir(root: root)
        let pid = ProcessInfo.processInfo.processIdentifier
        if let entries = try? fm.contentsOfDirectory(atPath: scratchBase) {
            for entry in entries where entry == bundle.id || entry.hasPrefix(bundle.id + "-") {
                // "<id>-<pid>-<uuid>" — the token after the id names the owner.
                let rest = entry == bundle.id ? "" : String(entry.dropFirst(bundle.id.count + 1))
                var owner: Int?
                if let token = rest.split(separator: "-", maxSplits: 1).first {
                    owner = Int(token)
                }
                // processIdentifier is an Int32; the parsed token is an Int.
                guard owner != Int(pid) else { continue }
                try? fm.removeItem(atPath: (scratchBase as NSString).appendingPathComponent(entry))
            }
        }
    }

    /// Put a staged file or folder in place, whole or not at all.
    ///
    /// The new copy first moves in beside the destination as `<destination>.
    /// partial` — a name `ModelCatalogPolicy` reserves, so no catalog asset can
    /// ever be sitting where this writes. The old version then moves aside as
    /// `<destination>.previous` (kept by the caller for rollback), and only
    /// then does the new copy take the destination. A crash therefore leaves a
    /// `.partial` or a `.previous` — installer-owned names recovery understands
    /// — rather than a half-written model that `isInstalled` would call present.
    private static func place(_ staged: URL, at destination: String, fm: FileManager) throws {
        let partial = destination + ".partial"
        let previous = destination + ".previous"
        if fm.fileExists(atPath: partial) { try? fm.removeItem(atPath: partial) }
        do {
            try fm.moveItem(at: staged, to: URL(fileURLWithPath: partial))
        } catch {
            throw ModelInstallError.installFailed(destination, error.localizedDescription)
        }
        if fm.fileExists(atPath: destination) {
            if fm.fileExists(atPath: previous) { try? fm.removeItem(atPath: previous) }
            do {
                try fm.moveItem(atPath: destination, toPath: previous)
            } catch {
                throw ModelInstallError.installFailed(destination, error.localizedDescription)
            }
        }
        do {
            try fm.moveItem(atPath: partial, toPath: destination)
        } catch {
            // The backup is deliberately left in place: the caller's rollback
            // (or recovery after a crash) restores it.
            throw ModelInstallError.installFailed(destination, error.localizedDescription)
        }
    }
}

/// Getting a directory out of a single file.
///
/// A GitHub release asset is one file; a Core ML `.mlpackage` is a directory. So
/// a package ships as a zip and is unwrapped before Core ML compiles it.
///
/// `ditto -x -k` rather than a zip reader of our own: it is the tool macOS
/// itself creates archives with, so the two cannot disagree about a zip's shape,
/// and it is on every Mac. A raw package directory is accepted too, which is what
/// a dev install points at — one code path for both.
enum ModelArchive {

    static let ditto = "/usr/bin/ditto"

    /// How far an archive may expand relative to the bytes it arrived in.
    /// Real model packages stay far below this; a zip bomb exists to exceed it.
    static let expansionCeiling: Int64 = 8
    /// Absolute ceiling, so a legitimately dense large archive still cannot
    /// eat a disk by itself. The smallest real bundle is ~18 MB compressed.
    static let absoluteCeiling: Int64 = 4_000_000_000

    /// How many bytes an archive of `compressed` bytes may expand to: the
    /// proportional ceiling, capped by the absolute one.
    static func budget(forCompressed compressed: Int64) -> Int64 {
        let scaled = compressed.multipliedReportingOverflow(by: expansionCeiling)
        return min(scaled.overflow ? Int64.max : scaled.partialValue, absoluteCeiling)
    }

    /// Is `expanded` bytes acceptable for an archive of `compressed` bytes,
    /// with `free` bytes free on the destination volume? The arithmetic is a
    /// static function so the boundary cases get their own tests — the guard
    /// lives here, not in whoever calls it.
    static func wouldOvershoot(compressed: Int64, expanded: Int64, free: Int64) -> Bool {
        guard compressed > 0, expanded >= 0, free >= 0 else { return true }
        return expanded > budget(forCompressed: compressed) || expanded > free
    }

    /// The `.mlpackage` inside `file`, or `file` itself when it already is one.
    static func unwrapPackage(_ file: URL) throws -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            return file                       // already a package (a dev install)
        }
        let into = file.deletingLastPathComponent()
            .appendingPathComponent("unwrapped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        // No cleanup here on purpose: `into` lives in the install's scratch
        // directory, which the install's own `defer` removes — deleting it at
        // return would destroy the package before activation could move it.
        // ditto expands without asking; the ceiling has to be checked during
        // the extraction, not after it, or a small archive has already grown
        // into a full disk by the time anything looks. A watchdog bounds what
        // the extractor may write while it runs, then the run is judged.
        let compressed = (try? FileManager.default.attributesOfItem(
            atPath: file.path)[.size] as? Int64) ?? 0
        // Volume free space comes from URL resource values — `attributesOfItem`
        // does not reliably carry it, and treating "unknown" as zero would
        // kill every honest extraction. Unknown means: skip the free-space
        // arm and rely on the proportional ceiling.
        let free = (try? URL(fileURLWithPath: into.path)
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
            .map(Int64.init) ?? .max
        try extract(file, into: into, budget: budget(forCompressed: compressed),
                    watching: into, withDiskFree: free)
        // A package archive holds exactly one item at the top level. More than
        // one is an archive we did not build, and guessing which is the model
        // would be how a stranger ends up with a broken install.
        let items = try FileManager.default.contentsOfDirectory(atPath: into.path)
            .filter { !$0.hasPrefix(".") }
        guard items.count == 1 else {
            throw ModelInstallError.installFailed(
                file.lastPathComponent,
                "the archive holds \(items.count) items, expected one")
        }
        return into.appendingPathComponent(items[0])
    }

    static func extract(_ archive: URL, into directory: URL) throws {
        try extract(archive, into: directory, budget: .max, watching: nil, withDiskFree: .max)
    }

    /// Extract with a growth ceiling: `ditto` runs while a watcher sums the
    /// extraction directory; past `budget` bytes (or past the disk's free
    /// space, when `withDiskFree` says what that is) the process is killed and
    /// the failure is reported before the disk fills.
    static func extract(_ archive: URL, into directory: URL,
                        budget: Int64, watching: URL?, withDiskFree free: Int64) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ditto)
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ModelInstallError.installFailed(archive.lastPathComponent,
                                                  error.localizedDescription)
        }
        var overBudget = false
        var ceiling: Int64 = .max
        if watching != nil, budget != .max {
            // The deadline has teeth: a bomb that outlives the poll loop must
            // be killed too, not merely stopped being watched.
            let deadline = Date().addingTimeInterval(600)
            ceiling = min(budget, free)
            while process.isRunning {
                if Date() > deadline {
                    overBudget = true
                    process.terminate()
                    break
                }
                if grown(in: watching!) > ceiling {
                    overBudget = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let text = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // An archive that finished between two polls — or before the first —
        // is measured once more: extraction is over either way if it exceeds
        // the ceiling. Honest archives sit at an eighth of their size, far
        // below the ceiling, so this never fires for them.
        if watching != nil, budget != .max, !overBudget, grown(in: watching!) > ceiling {
            overBudget = true
        }
        if overBudget {
            throw ModelInstallError.installFailed(
                archive.lastPathComponent,
                "the archive expands beyond what it declared it could — "
              + "extraction stopped before the disk filled")
        }
        guard process.terminationStatus == 0 else {
            let why = String(data: text, encoding: .utf8) ?? "ditto exited \(process.terminationStatus)"
            throw ModelInstallError.installFailed(archive.lastPathComponent,
                                                  why.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Total bytes of everything under `directory`, to the last poll.
    private static func grown(in directory: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for item in walk {
            let path = (directory.path as NSString).appendingPathComponent(item as! String)
            total += (try? FileManager.default.attributesOfItem(
                atPath: path)[.size] as? Int64) ?? 0
        }
        return total
    }
}

// MARK: - the app's side

/// What the AI tab and the empty screen talk to.
///
/// Deliberately thin: it holds the fetched catalogue and the state of the one
/// install in flight, and every decision with a right answer (the order, the
/// hashes, the atomicity) lives in `ModelInstaller` where the gate can reach it.
@MainActor
final class ModelDownloader: ObservableObject {

    struct Progress: Equatable {
        var received: Int64
        var total: Int64
        var fraction: Double { total > 0 ? min(Double(received) / Double(total), 1) : 0 }
    }

    enum State: Equatable {
        /// No catalogue yet, and none asked for.
        case idle
        /// The catalogue could not be read, with the reason — said out loud,
        /// because "no bundles listed" and "no internet" must not look alike.
        case unavailable(String)
        case downloading(bundle: String, progress: Progress)
        /// A downloaded bundle is being placed, or an unwanted one is being
        /// taken away. The row labels the two apart by which one it is looking
        /// at; nothing else sets this state.
        case installing(bundle: String)
        /// A kept version is being put back — placement with no download. Its
        /// own state, so a row that says "Removing…" cannot be what a user reads
        /// while a pack is being switched to.
        case switching(bundle: String)
        case failed(bundle: String, reason: String)
    }

    @Published private(set) var manifest: AIBundleManifest?
    @Published private(set) var state: State = .idle
    /// Bumped whenever the disk changed, so a view can refresh the capability
    /// probe without guessing whether an install finished.
    @Published private(set) var revision = 0 {
        didSet { onArtifactsChanged?() }
    }
    /// The app owns this callback, so closing Settings cannot detach the
    /// capability refresh. Called after disk work, including failed recovery.
    var onArtifactsChanged: (() -> Void)?
    /// Which pack each capability is set to use, kept in memory because the
    /// Settings rows read it on every render and a rendered row is not the place
    /// to answer from disk. Written through `choose`/`forget` only, so this copy
    /// and the file cannot disagree.
    @Published private(set) var registry = ModelRegistry()
    /// Versions of installed packs that are kept on this Mac, newest first —
    /// what a row can switch a capability back to without a download. The store
    /// on disk is the record; this is the copy a rendered row reads.
    @Published private(set) var kept: [StoredVersion] = []
    /// Why a version could not be kept, or why the choice could not be recorded,
    /// per bundle. Not a failure of the install — that succeeded and the model
    /// works — so it does not go in `state`, where it would read as one; the row
    /// says what is missing instead.
    private var notes: [String: String] = [:]
    /// The ID of the operation currently running, if any. One at a time, per
    /// downloader — the serialization guard for install and removal alike.
    @Published private(set) var inFlight: String?

    /// Whether a bundle is being installed or removed right now. Asked by the
    /// engine before it starts anything (`AnalysisEngine.isReplacingModels`), so
    /// it must be answerable without touching disk: a run that began after
    /// activation started would load one file from each version.
    var isReplacing: Bool { inFlight != nil }

    /// The AI's answer to "are you working right now", injected by the app
    /// (`engine.isInferring`). Asked before any install or removal begins, and
    /// the main actor is where both ends live — the downloader is main-actor and
    /// the engine's counter is lock-backed — so neither reads another actor's
    /// state.
    var isInferring: () -> Bool = { false }

    private let root: String
    private let transport: ModelTransport
    private let prepare: ModelInstaller.Preparer
    private let catalogueURL: URL

    init(root: String = Paths.support,
         transport: ModelTransport = URLSessionTransport(),
         prepare: @escaping ModelInstaller.Preparer = ModelInstaller.prepare,
         catalogueURL: URL = URL(string: AIBundleManifest.defaultURL)!) {
        self.root = root
        self.transport = transport
        self.prepare = prepare
        self.catalogueURL = catalogueURL
        self.registry = ModelRegistry.read(root: root)
        self.kept = ModelStore.versions(root: root)
    }

    /// What can be downloaded right now. Called when the AI tab appears — the
    /// catalogue is small and the answer changes when a release is published.
    func refreshCatalogue() async {
        do {
            let data = try await transport.fetch(catalogueURL)
            let decoded = try JSONDecoder().decode(AIBundleManifest.self, from: data)
            try ModelCatalogPolicy.validate(decoded)
            manifest = decoded
            // The choice can outlive the catalogue it was made from: a pack the
            // user chose yesterday may not be offered today, and the rows have to
            // say which pack is in force either way.
            registry = ModelRegistry.read(root: root)
            state = .idle
        } catch {
            state = .unavailable(ModelInstallError.noCatalogue(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription).description)
        }
    }

    func isInstalled(_ bundle: AIBundle) -> Bool { bundle.isInstalled(root: root) }

    /// Every catalogue bundle for a feature, in catalogue order: what the picker
    /// offers, including the ones this build cannot run (they are shown with
    /// their reason rather than hidden, or the row would silently lose options).
    func bundles(for feature: AICapability.Feature) -> [AIBundle] {
        manifest?.bundles.filter { $0.capabilityFeature == feature } ?? []
    }

    /// The bundle that turns a feature on. Nil means "nothing to offer here":
    /// either the catalogue has not arrived yet, or this build knows a feature
    /// the catalogue does not (an older catalogue is served by `releases/latest`
    /// for as long as it stays latest).
    ///
    /// The user's choice wins when it is still on offer. Otherwise the first
    /// compatible bundle — and if none is compatible, the first one anyway, so
    /// the row can show the pack and say why it cannot run rather than showing
    /// nothing at all.
    func bundle(for feature: AICapability.Feature) -> AIBundle? {
        let offered = bundles(for: feature)
        if let chosen = registry.selection(for: feature),
           let match = offered.first(where: { $0.id == chosen.bundleID }) {
            return match
        }
        return offered.first { $0.incompatibility == nil } ?? offered.first
    }

    /// Set which pack a capability uses. Refuses a pack this build cannot run —
    /// with the reason in `state`, which the row shows — and clears any previous
    /// complaint once a choice lands.
    func choose(_ bundle: AIBundle) {
        do {
            registry = try ModelRegistry.choose(bundle, root: root)
            state = .idle
        } catch {
            state = .failed(bundle: bundle.id, reason: Self.sentence(error))
        }
    }

    /// What to say about a feature's install right now, if anything.
    func note(for feature: AICapability.Feature) -> String? {
        guard let bundle = bundle(for: feature) else { return nil }
        if let why = bundle.incompatibility { return why }
        if case .failed(let id, let why) = state, id == bundle.id { return why }
        // Something about a completed install that the user should still know —
        // a copy that could not be kept, a choice that could not be recorded.
        return notes[bundle.id]
    }

    /// The pack in force for a feature, as a line a user can read back to us.
    /// Nil when nothing has been chosen — a pack installed before choices
    /// existed, where the catalogue's own order decides and saying otherwise
    /// would be an invented fact.
    func chosenPack(for feature: AICapability.Feature) -> ModelSelection? {
        registry.selection(for: feature)
    }

    /// Versions of a feature's packs that are kept on this Mac, newest first.
    /// What the row offers to switch back to, without a download.
    func keptVersions(for feature: AICapability.Feature) -> [StoredVersion] {
        kept.filter { $0.capability == feature }
    }

    /// Is this kept version the one installed right now? Asked of the receipt,
    /// so a row marks exactly what every other reader treats as in force.
    func isLive(_ version: StoredVersion) -> Bool { version.isLive(root: root) }

    /// Re-read the store. The disk is the record; this is the copy rows render.
    private func refreshKept() {
        kept = ModelStore.versions(root: root)
    }

    /// Fetch one bundle and put it in place.
    ///
    /// Failures are kept in `state` rather than thrown: the row that started
    /// this is what should say what happened, and it is on screen already.
    ///
    /// Operations are serialized per downloader: starting a second one while
    /// another is in flight fails fast with a reason, because two concurrent
    /// operations racing through the same destinations would be exactly the
    /// interleaving the transaction exists to prevent (pitfall 0: the refused
    /// press must SAY so, never do nothing silently).
    func install(_ bundle: AIBundle) async {
        guard beginOperation(bundle) else { return }
        defer { finishOperation() }
        let id = bundle.id
        state = .downloading(bundle: id, progress: Progress(received: 0, total: max(bundle.bytes, 1)))
        do {
            // Recovery first: any staging or backup state a crash left behind
            // is resolved before this install reads or writes anything.
            try await Task.detached(priority: .userInitiated) {
                try ModelInstaller.recover(bundle, root: self.root)
            }.value
            try await ModelInstaller.install(
                bundle, root: root, transport: transport, prepare: prepare
            ) { [weak self] received, total in
                Task { @MainActor in
                    guard let self, case .downloading(id, _) = self.state else { return }
                    self.state = .downloading(bundle: id, progress: Progress(received: received, total: total))
                }
            }
            state = .idle
            revision += 1
            // Anything about a completed install the user should still be told.
            // One message slot, so the problems are gathered and said together
            // rather than the last one winning — a download that worked can
            // still have failed to record the choice AND failed to keep a copy.
            var problems: [String] = []
            do {
                registry = try ModelRegistry.choose(bundle, root: root)
            } catch {
                problems.append("which pack to use could not be recorded: " + Self.sentence(error))
            }
            // Keep a copy of what just landed, so a later revision can be
            // switched back to without downloading it again. A failure here does
            // not fail the install — the model is on disk and working — but it is
            // the difference between "trying the new one is free" and "trying the
            // new one costs another 165 MB download", so the row says it.
            //
            // Off the main actor: this copies every asset and re-hashes every
            // plain file, which is 18 MB to 350 MB of work, and the install has
            // already returned to the UI by this point.
            do {
                let root = self.root
                try await Task.detached(priority: .userInitiated) {
                    _ = try ModelStore.keep(root: root, bundle: bundle)
                }.value
            } catch {
                problems.append("a copy to go back to could not be kept: " + Self.sentence(error))
            }
            notes[bundle.id] = problems.isEmpty
                ? nil
                : "Installed, but " + problems.joined(separator: ", and ") + "."
        } catch {
            revision += 1
            state = .failed(bundle: id, reason: Self.sentence(error))
        }
        refreshKept()
    }

    /// Switch a feature to a version of its pack that is already on this Mac.
    ///
    /// This is the install transaction fed from the store instead of the
    /// network: no download and no compiler, and the receipt and the space
    /// identity are written exactly as an install writes them, so nothing
    /// downstream can tell a switch from a fresh install of those bytes.
    ///
    /// Refused while the AI is working, like any other swap: a load that started
    /// before activation would read one file from each version.
    func activate(_ version: StoredVersion) async {
        guard beginOperation(version.bundle) else { return }
        defer { finishOperation() }
        state = .switching(bundle: version.bundle.id)
        do {
            let root = self.root
            try await Task.detached(priority: .userInitiated) {
                // Recovery first, as an install does: a crash mid-switch leaves
                // the same `.partial` and `.previous` names behind.
                try ModelInstaller.recover(version.bundle, root: root)
                let staging = (ModelInstaller.scratchDir(root: root) as NSString)
                    .appendingPathComponent("activate-\(version.token)-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(atPath: staging) }
                let prepared = try ModelStore.prepared(root: root, version: version, staging: staging)
                try ModelInstaller.activate(prepared, bundle: version.bundle, root: root)
            }.value
            state = .idle
            // The version that is now in force is recorded as the choice, so a
            // relaunch and every other reader agree with what the disk holds —
            // and if that write fails, this does not pretend otherwise.
            var problems: [String] = []
            do {
                registry = try ModelRegistry.choose(version.bundle, root: root)
            } catch {
                problems.append("which pack to use could not be recorded: " + Self.sentence(error))
            }
            // Any earlier "no copy to go back to" described the install this
            // switch just displaced, so it is replaced rather than left standing.
            notes[version.bundle.id] = problems.isEmpty
                ? nil
                : "Switched, but " + problems.joined(separator: ", and ") + "."
        } catch {
            state = .failed(bundle: version.bundle.id, reason: Self.sentence(error))
        }
        refreshKept()
        revision += 1
    }

    /// Throw a kept copy away. Never touches what is installed — that is what
    /// the bundle's own Remove is for — so this can also be how a user reclaims
    /// the disk a rollback target was using without losing the pack in use.
    func discard(_ version: StoredVersion) async {
        guard beginOperation(version.bundle) else { return }
        defer { finishOperation() }
        do {
            let root = self.root
            try await Task.detached(priority: .userInitiated) {
                try ModelStore.remove(root: root, version: version)
            }.value
            state = .idle
        } catch {
            state = .failed(bundle: version.bundle.id, reason: Self.sentence(error))
        }
        refreshKept()
        revision += 1
    }

    /// Removes a bundle on a background queue and reports the outcome in
    /// `state`, like `install` does — removal of a 165 MB compiled directory
    /// is not instant and must not hold the main thread.
    func remove(_ bundle: AIBundle) async {
        guard beginOperation(bundle) else { return }
        defer { finishOperation() }
        state = .installing(bundle: bundle.id)
        do {
            try await Task.detached(priority: .userInitiated) {
                try ModelInstaller.remove(bundle, root: self.root)
            }.value
            state = .idle
            // A choice naming a pack that is gone would refuse a feature the user
            // could otherwise have with the pack the catalogue offers instead.
            registry = ModelRegistry.forget(bundleID: bundle.id, root: root)
        } catch {
            state = .failed(bundle: bundle.id, reason: Self.sentence(error))
        }
        // A removed pack's KEPT versions stay: they are the way back without a
        // download, which is the one thing a removal would otherwise cost.
        refreshKept()
        revision += 1
    }

    /// One operation at a time per downloader. Returns false — and says why in
    /// `state` — when something is already running, or when the AI is working.
    private func beginOperation(_ bundle: AIBundle) -> Bool {
        if inFlight != nil {
            state = .failed(bundle: bundle.id, reason: "another download operation is already running")
            return false
        }
        // A model may not be swapped under a pass that is reading it: the load
        // either crashes or answers from a mix of both versions, and neither is
        // a failure the user can retry. Refused with the reason they can act on,
        // rather than letting the operation start and hoping.
        if isInferring() {
            state = .failed(bundle: bundle.id,
                            reason: "the AI is working right now — let it finish or stop the run, "
                                  + "then try again")
            return false
        }
        inFlight = bundle.id
        return true
    }

    private func finishOperation() {
        inFlight = nil
    }

    /// One honest sentence for the row.
    static func sentence(_ error: Error) -> String {
        if let install = error as? ModelInstallError { return install.description }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
