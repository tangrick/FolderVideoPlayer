import Foundation

/// A tag profile's own folder, as a document.
///
/// What a profile owns used to be spread across the support directory: the
/// active profile's tags at `tags.json`, its readings at `metadata.json`, and
/// the rest inside `profiles/<slug>/`. The document model makes the profile one
/// self-contained folder, so "move my profile somewhere else" is a directory
/// move rather than a rewrite, and the File menu has one thing per profile to
/// open, close and publish.
///
///     profiles/quincy.fvpprofile/
///         profile.json          the manifest: format version, slug, device
///         tags.json             the tags themselves
///         readings.json         what was READ off the files (dates, cameras…)
///         headings.json         which tag is filed under which heading
///         faces.json            the person registry, plus faces/ vectors
///         jobs.json             the explicit-job ledger
///         suggestions.json      machine guesses and the accept/reject verdicts
///         marks.json            the human Safe/NSFW decisions
///         heads/<encoder>_…     fitted heads and priors, one set per encoder
///
/// What is deliberately NOT here is the machine's own work — fingerprints, the
/// durations, the analysis cache, the thumbnails, the downloaded models. They
/// are arithmetic on the videos and carry nobody's judgement, so sharing them
/// across profiles is what makes a second profile cheap instead of a second
/// full encode.
///
/// The directory is named `profiles/` rather than `Profiles/`: macOS filesystems
/// are case-insensitive, so the two are the same directory, and renaming it
/// would be churn for no behaviour.
enum ProfileBundle {

    /// The extension that marks a profile folder as a profile.
    static let extensionName = "fvpprofile"

    /// Written into every manifest. A build that finds a version it does not
    /// know must refuse the bundle rather than half-load it.
    static let formatVersion = 1

    static let manifestName = "profile.json"
    static let tagsName = "tags.json"
    static let readingsName = "readings.json"
    static let headingsName = "headings.json"
    static let headsDir = "heads"

    // MARK: - the manifest

    /// What a bundle says about itself, read without opening the profile.
    struct Manifest: Codable, Equatable {
        var version: Int = ProfileBundle.formatVersion
        /// The name the person goes by. The profile list in `state.json` is the
        /// authority; this copy is what lets a bundle be understood on its own.
        var name: String = ""
        var slug: String = ""
        /// Which machine publishes it — the `tags-<device>.json` name on the
        /// shares. Kept with the profile because it is a property of the
        /// document, not of the window that happens to have it open.
        var device: String = ""
        var created: Double = 0
        /// When this profile's tags were last pushed to the shares. Zero means
        /// never, which is different from "0 seconds ago" and is what the
        /// window title reads. Nothing to publish is not a publish.
        var lastPublishedAt: Double = 0
        /// Optional for bundles written before publication state was persisted.
        var publishedClean: Bool? = nil
    }

    // MARK: - where a bundle is

    /// The folder name for one profile.
    static func folder(_ profile: String) -> String {
        Paths.profileFolder(profile) + "." + extensionName
    }

    /// `profiles/<slug>.fvpprofile`, relative to the support root. Exposed
    /// because two helpers build their own absolute path from a test root and
    /// must agree with `dir` exactly.
    static func relativeDir(_ profile: String) -> String {
        Paths.profilesFolderName + "/" + folder(profile)
    }

    /// One profile's bundle, absolute.
    static func dir(_ profile: String, root: String = Paths.support) -> String {
        (root as NSString).appendingPathComponent(relativeDir(profile))
    }

    /// Whether a directory name is a profile bundle.
    static func isBundleName(_ name: String) -> Bool {
        name.hasSuffix("." + extensionName)
    }

    /// The profile slug a bundle directory name stands for. A name that is not
    /// a bundle is returned unchanged, so a caller parsing a path doesn't have
    /// to check first — `JobLedger` does exactly that with its own file's
    /// parent directory, and a stray suffix there would make every job of a
    /// profile look like a foreign one and be refused.
    static func slug(fromBundleName name: String) -> String {
        guard isBundleName(name), name.count > extensionName.count + 1 else { return name }
        return String(name.dropLast(extensionName.count + 1))
    }

    /// One path inside a profile's bundle, from an arbitrary root — the form
    /// the two head/prior helpers need, since they build their own path from a
    /// test root rather than from `Paths.support`.
    static func file(in profile: String, _ relative: String,
                     root: String = Paths.support) -> String {
        (dir(profile, root: root) as NSString).appendingPathComponent(relative)
    }

    /// Where one encoder's fitted artifact lives inside a bundle. A folder per
    /// encoder rather than loose files, so a profile trained on two embedding
    /// spaces reads as two sets rather than as a pile.
    static func headsRelative(_ encoderSlug: String, _ suffix: String) -> String {
        headsDir + "/" + encoderSlug + suffix
    }

    /// Every profile with a bundle on disk, sorted.
    static func slugs(root: String = Paths.support) -> [String] {
        let parent = (root as NSString).appendingPathComponent(Paths.profilesFolderName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent)
        else { return [] }
        return names.filter(isBundleName)
            .filter { isDirectory((parent as NSString).appendingPathComponent($0)) }
            .map(slug(fromBundleName:))
            .sorted()
    }

    static func isDirectory(_ path: String) -> Bool {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return false }
        return folder.boolValue
    }

    // MARK: - creating one

    static func manifest(_ profile: String, root: String = Paths.support) -> Manifest? {
        let path = (dir(profile, root: root) as NSString).appendingPathComponent(manifestName)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // An absent manifest is `nil`, not an empty one: "this bundle does not
        // say what it is" and "this bundle is version 0" are different answers.
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Make sure a profile has a bundle and a manifest, and say where it is.
    ///
    /// Idempotent, and never overwrites an existing manifest: a bundle that is
    /// already there belongs to the profile, and a second `ensure` from a path
    /// that happens to run later must not reset its created date or its
    /// published stamp. The closed state (an empty profile) is refused: it
    /// owns no folder, and ensuring one would build a stray bundle under
    /// `profiles/unknown/` that nothing opened and nothing would clean up.
    @discardableResult
    static func ensure(profile: String, name: String? = nil, device: String = "",
                       root: String = Paths.support) -> String {
        guard !profile.isEmpty else { return dir(profile, root: root) }
        let where_ = dir(profile, root: root)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: where_, withIntermediateDirectories: true)
        let manifestPath = (where_ as NSString).appendingPathComponent(manifestName)
        if !fm.fileExists(atPath: manifestPath) {
            var fresh = Manifest(name: name ?? profile, slug: Paths.profileFolder(profile))
            fresh.device = device
            fresh.created = Date().timeIntervalSince1970
            JSONStore.save(manifestPath, fresh)
        } else if var known = manifest(profile, root: root) {
            // Two fields a caller may correct on an existing bundle: the
            // display name, because a rename must not leave it claiming the
            // old one, and the device, because the publish name is editable —
            // the old name would otherwise sit in the manifest while the
            // shares already take the new one. A correction only ever WRITES
            // when something actually differs, so an ordinary `ensure` on
            // every heading save cannot churn the file.
            var changed = false
            if let name, known.name != name, !name.isEmpty {
                known.name = name
                changed = true
            }
            if !device.isEmpty, known.device != device {
                known.device = device
                changed = true
            }
            if changed { JSONStore.save(manifestPath, known) }
        }
        return where_
    }

    /// Record that this profile's tags reached the shares.
    ///
    /// Only called when a share actually took a write: a publish that was
    /// skipped because the NAS was asleep has not happened, and stamping it
    /// would make the window title claim something untrue. A stamp for the
    /// closed state (slug "") is refused: it would write a manifest into the
    /// stray `profiles/unknown/` bundle.
    static func markPublished(profile: String, at when: Double = Date().timeIntervalSince1970,
                              clean: Bool = true, root: String = Paths.support) {
        guard !profile.isEmpty,
              var known = manifest(profile, root: root) else { return }
        known.lastPublishedAt = when
        known.publishedClean = clean
        JSONStore.save((dir(profile, root: root) as NSString).appendingPathComponent(manifestName),
                       known)
    }

    static func markEdited(profile: String, root: String = Paths.support) {
        guard !profile.isEmpty, var known = manifest(profile, root: root) else { return }
        known.publishedClean = false
        JSONStore.save((dir(profile, root: root) as NSString).appendingPathComponent(manifestName), known)
    }


    // MARK: - the one-time migration

    /// What a migration run did, recorded so the next launch knows it happened.
    struct Migration: Codable, Equatable {
        var ran = false
        var created: [String] = []
        var skipped: [String] = []
    }

    /// Where the record lives. Dot-prefixed so nothing that lists profiles sees
    /// it, and inside `profiles/` because that is what it describes.
    static func marker(root: String = Paths.support) -> String {
        ((root as NSString).appendingPathComponent(Paths.profilesFolderName) as NSString)
            .appendingPathComponent(".bundles-migrated.json")
    }

    /// Move the old layout into bundles, once.
    ///
    /// **Copies, never moves.** The old files stay where they are, so a
    /// migration that turns out badly is undone by deleting the bundles and the
    /// marker — not by restoring a backup. Nothing here deletes user data.
    ///
    /// The marker is what makes this safe to run on every launch: without it, a
    /// profile the user deliberately deleted would come back the next time the
    /// app started, rebuilt from the legacy files that are still on disk. With
    /// it, migration happens exactly once and a deleted bundle stays deleted.
    ///
    /// Idempotent per profile as well as by the marker: a bundle that already
    /// exists is left completely alone.
    @discardableResult
    static func migrateIfNeeded(activeProfile: String,
                                names: [String: String] = [:],
                                device: String = "",
                                root: String = Paths.support) -> Migration {
        var report = Migration()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: marker(root: root)) else { return report }
        report.ran = true

        let parent = (root as NSString).appendingPathComponent(Paths.profilesFolderName)
        let activeSlug = Paths.profileFolder(activeProfile)
        let leaves = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
        func displayName(_ slug: String) -> String { names[slug] ?? slug }

        // 1. Every legacy profile FOLDER — where the AI state has always lived,
        //    for the active profile as much as any other.
        for leaf in leaves.sorted()
        where isBundleName(leaf) == false
            && isDirectory((parent as NSString).appendingPathComponent(leaf)) {
            let slug = leaf
            let into = dir(slug, root: root)
            if fm.fileExists(atPath: into) {
                report.skipped.append(slug)
                continue
            }
            try? fm.createDirectory(atPath: into, withIntermediateDirectories: true)
            let from = (parent as NSString).appendingPathComponent(leaf)
            for file in ((try? fm.contentsOfDirectory(atPath: from)) ?? []).sorted() {
                let source = (from as NSString).appendingPathComponent(file)
                guard isDirectory(source) == false else { continue }
                let destination = (into as NSString).appendingPathComponent(renamed(file, for: slug))
                // `copyItem` does not make the directory it copies into, and
                // one of these names now lives inside `heads/`. Without this
                // the fitted head silently failed to arrive — no error, because
                // the whole migration is best-effort by design and a `try?`
                // cannot tell you it dropped something.
                try? fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                try? fm.copyItem(atPath: source, toPath: destination)
            }
            ensure(profile: slug, name: displayName(slug), device: device, root: root)
            report.created.append(slug)
        }

        // 2. Loose legacy tag files: `profiles/<slug>.json`, every profile that
        //    is not the one in force. The one in force is handled in step 3,
        //    because its tags have always been the root file and that is the
        //    authoritative copy of the session's own tags.
        for leaf in leaves.sorted()
        where leaf.hasSuffix(".json") && !leaf.hasPrefix(".") {
            let slug = (leaf as NSString).deletingPathExtension
            guard slug != activeSlug else { continue }
            let into = ensure(profile: slug, name: displayName(slug), device: device, root: root)
            let source = (parent as NSString).appendingPathComponent(leaf)
            let destination = (into as NSString).appendingPathComponent(tagsName)
            if !fm.fileExists(atPath: destination) {
                try? fm.copyItem(atPath: source, toPath: destination)
            }
            if !report.created.contains(slug) { report.created.append(slug) }
        }

        // 3. The active profile's root files, which is where ITS tags and ITS
        //    readings have always been. These overwrite: the root tag file is
        //    the session's own tags, so it beats any stale copy of the same
        //    profile left in `profiles/` by an earlier switch away from it.
        let into = ensure(profile: activeSlug, name: displayName(activeSlug),
                          device: device, root: root)
        copy((root as NSString).appendingPathComponent("tags.json"),
             to: (into as NSString).appendingPathComponent(tagsName), overwrite: true)
        copy((root as NSString).appendingPathComponent("metadata.json"),
             to: (into as NSString).appendingPathComponent(readingsName), overwrite: true)
        if !report.created.contains(activeSlug) { report.created.append(activeSlug) }

        JSONStore.save(marker(root: root), report)
        return report
    }

    /// What a legacy file is called inside a bundle. Three names changed with
    /// the move: the heading map and the readings are named for what they hold
    /// rather than for where they came from, and the fitted heads get a folder
    /// so a bundle with several encoders does not read as a pile of files.
    private static func renamed(_ file: String, for slug: String) -> String {
        if file == "tag-groups.json" { return headingsName }
        if file == "metadata.json" { return readingsName }
        if file.hasSuffix("_trained_heads.json") || file.hasSuffix("_tag_priors.json") {
            return headsDir + "/" + file
        }
        return file
    }

    private static func copy(_ from: String, to: String, overwrite: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return }
        try? fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if overwrite { try? fm.removeItem(atPath: to) }
        else if fm.fileExists(atPath: to) { return }
        try? fm.copyItem(atPath: from, toPath: to)
    }
}
