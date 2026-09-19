import Foundation

/// Which model pack each capability is set to use — the persisted half of T02.
///
/// Until this existed, "which model is in force" was an accident of the disk:
/// the first bundle in the catalogue the app found for a feature, and after an
/// install, whatever that install happened to leave behind. That is adequate
/// with exactly one pack per feature and wrong the moment there are two —
/// nothing could say which one the user chose, nothing survived a relaunch, and
/// nothing could refuse a pack this build cannot run *before* the download.
///
/// So the choice is a record rather than a guess: one selection per capability,
/// written when an install completes or when the user picks, cleared when that
/// pack is removed. The installed artifacts stay the authority for "is it
/// there" — that is still the receipt's job. This decides WHICH of them a
/// capability uses.
///
/// What this deliberately is not: authentication, or a substitute for the space
/// identity. A selection names a pack; `ModelSpace` proves what those bytes
/// actually are, and a pack that installs to a different space still invalidates
/// heads and prototypes exactly as before.
struct ModelSelection: Codable, Equatable {
    /// `AICapability.Feature.rawValue`.
    var feature: String
    /// The catalogue bundle this capability uses.
    var bundleID: String
    /// The title the catalogue gave it, for a row that has to name the pack even
    /// when the catalogue no longer offers it.
    var title: String
    /// The contract the pack declared when it was chosen — the same descriptor
    /// the catalogue is validated against, kept so the choice can be re-checked
    /// later against a build that may no longer support it. Nil for a pack that
    /// declared none (legacy bundles), where "nothing declared" is the honest
    /// answer and a made-up revision would not be.
    var pack: ModelPackDescriptor?
    var chosenAt: Date

    var capability: AICapability.Feature? { AICapability.Feature(rawValue: feature) }

    /// What the pack calls itself, or the catalogue title when it declared no
    /// descriptor at all.
    var modelID: String { pack?.modelID ?? title }
    var revision: String { pack?.revision ?? "" }

    /// "Falconsai · revision abc1234" — or just the title for a legacy pack.
    var summary: String {
        revision.isEmpty ? modelID : modelID + " · revision " + String(revision.prefix(12))
    }

    /// Why this choice cannot run here any more, if it cannot.
    ///
    /// Re-asked on every capability probe, because a choice outlives the build
    /// that made it: an app update that drops an adapter, a downgrade, a support
    /// root restored from a backup. The catalogue's own check cannot catch any of
    /// those — it only ever sees what is on offer today.
    func incompatibility(feature: AICapability.Feature,
                         environment: ModelPackEnvironment = .current) -> String? {
        guard let pack else { return nil }
        return pack.incompatibility(feature: feature.rawValue, environment: environment)
    }
}

/// The selection file: at most one selection per capability, versioned so a
/// future shape can be refused rather than misread.
struct ModelRegistry: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = ModelRegistry.currentVersion
    var selections: [ModelSelection] = []

    /// Beside the receipts and the space identity, and reserved from catalogs
    /// for the same reason: a download that could write this could choose which
    /// model the app loads, which is a decision the user makes.
    static func file(root: String = Paths.support) -> String {
        (root as NSString).appendingPathComponent("models/selected.json")
    }

    /// What the user has chosen. A missing or malformed file reads as "nothing
    /// chosen" — the app then behaves exactly as it did before selections
    /// existed, which is the safe direction (a catalogue's first compatible
    /// pack), not an invented choice.
    static func read(root: String = Paths.support) -> ModelRegistry {
        let found = JSONStore.load(file(root: root), fallback: ModelRegistry())
        guard found.version <= currentVersion else { return ModelRegistry() }
        return found
    }

    func selection(for feature: AICapability.Feature) -> ModelSelection? {
        selections.first { $0.feature == feature.rawValue }
    }

    func isChosen(_ bundle: AIBundle) -> Bool {
        guard let feature = bundle.capabilityFeature else { return false }
        return selection(for: feature)?.bundleID == bundle.id
    }

    /// Choose the pack a capability uses, and record what it called itself.
    ///
    /// Refuses a pack this build cannot run — naming the reason — because a
    /// record that named such a pack would be a promise the app then breaks at
    /// load time. Sole writer of the file, so the in-memory copy a row reads can
    /// never disagree with the disk.
    @discardableResult
    static func choose(_ bundle: AIBundle, root: String = Paths.support,
                       at date: Date = Date()) throws -> ModelRegistry {
        guard let feature = bundle.capabilityFeature else {
            throw ModelInstallError.incompatible(
                "That download is not one of this app's AI features, so there is nothing to choose.")
        }
        if let why = bundle.incompatibility {
            throw ModelInstallError.incompatible(why)
        }
        var registry = read(root: root)
        // One per capability: a second choice replaces the first rather than
        // sitting beside it, or "which pack is in force" would be ambiguous.
        registry.selections.removeAll { $0.feature == feature.rawValue }
        registry.selections.append(ModelSelection(feature: feature.rawValue,
                                                 bundleID: bundle.id,
                                                 title: bundle.title,
                                                 pack: bundle.pack,
                                                 chosenAt: date))
        registry.selections.sort { $0.feature < $1.feature }
        if let why = JSONStore.write(file(root: root), registry) {
            throw ModelInstallError.installFailed("the model choice", why)
        }
        return registry
    }

    /// Forget whichever capability had chosen this bundle. Used when a pack is
    /// removed: a record naming a pack that is gone would refuse a feature the
    /// user could otherwise use with the pack the catalogue offers instead.
    @discardableResult
    static func forget(bundleID: String, root: String = Paths.support) -> ModelRegistry {
        var registry = read(root: root)
        let before = registry.selections.count
        registry.selections.removeAll { $0.bundleID == bundleID }
        if registry.selections.count != before {
            _ = JSONStore.write(file(root: root), registry)
        }
        return registry
    }
}
