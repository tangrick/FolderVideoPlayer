import Foundation

/// What the AI half of the app can actually do on THIS Mac, right now.
///
/// The app has to work for somebody who has downloaded a DMG and nothing else.
/// Everything that is not AI — playing, tagging, favorites, duplicates, tag
/// profiles — has no dependency beyond macOS itself. The AI features do, and
/// until now those dependencies were discovered by failing: press Classify on
/// a Mac without the right Python and you got "no python3 found on this Mac"
/// buried in a notice, with nothing to do about it.
///
/// This type is the single place that knows what is missing and what that
/// costs the user. Every AI entry point asks it first, and every refusal names
/// the reason — the same rule as pitfall 0 (never a silent no-op), applied to
/// a whole feature area rather than one button.
///
/// It is deliberately a plain value with a static probe rather than a store:
/// nothing here is user state, it is a fact about the machine, and it is cheap
/// enough to re-read whenever a window opens.
struct AICapability: Equatable {
    /// The three things a user would recognise as separate features. Each can
    /// be missing on its own, so each is offered and reported on its own.
    enum Feature: String, CaseIterable, Identifiable {
        case classify      // Safe / NSFW verdicts
        case tags          // tag suggestions, look-alikes, training
        case faces         // recognising people
        case speech        // what is said, in words

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classify: return "Safe / NSFW classification"
            case .tags: return "Tag suggestions and look-alikes"
            case .faces: return "Face recognition"
            case .speech: return "Speech transcription"
            }
        }

        /// What the user loses without it, in their words rather than ours.
        var what: String {
            switch self {
            case .classify:
                return "Sorts a library into Safe and NSFW, and learns from your corrections."
            case .tags:
                return "Offers tags for what is on screen, and finds videos that look alike."
            case .faces:
                return "Puts a name to a face once, then finds that person everywhere."
            case .speech:
                return "Writes down what is said, so you can find a video by its words."
            }
        }

        var symbol: String {
            switch self {
            case .classify: return "checkmark.shield"
            case .tags: return "tag"
            case .faces: return "person.crop.circle"
            case .speech: return "waveform"
            }
        }

        /// The model files this feature actually loads, relative to the support
        /// directory. Read off disk rather than named in a constant, because
        /// the vision model has already been swapped once (MobileCLIP S2 →
        /// SigLIP2) and a hardcoded label would have gone on claiming the old
        /// name — which is precisely the lie this display exists to prevent.
        var modelLocations: [String] {
            switch self {
            case .tags:
                return ["tags"]
            case .classify:
                return ["models/laion_nsfw_l14.npz",
                        "models/openai_clip-vit-large-patch14_trained_heads.npz"]
            case .faces:
                return ["models/face_detection_yunet_2023mar.onnx",
                        "models/face_recognition_sface_2021dec.onnx"]
            case .speech:
                // Under models/ like the classify and faces files: the catalogue
                // may only install into tags/ or models/, and a path outside
                // those makes the app refuse the whole catalogue, not just this
                // bundle.
                return ["models/speech"]
            }
        }

        /// What is on disk right now, as names a person can read back to us.
        ///
        /// Empty when nothing is installed — the row already says the feature
        /// is not ready, and an empty list is honest where a remembered name
        /// would not be.
        func installedModelNames(root: String = Paths.support) -> [String] {
            let fm = FileManager.default
            var found: [String] = []
            for location in modelLocations {
                let full = (root as NSString).appendingPathComponent(location)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // A directory of model parts (tags/): name the models
                    // inside it, not the folder.
                    let inside = (try? fm.contentsOfDirectory(atPath: full)) ?? []
                    found += inside
                        .filter { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
                        .sorted()
                } else {
                    found.append((location as NSString).lastPathComponent)
                }
            }
            return found
        }
    }

    /// Why a feature cannot run. Ordered roughly by how fixable it is.
    enum Blocker: Equatable {
        case noPython            // nothing on this Mac can run the engine
        case noFFmpeg            // frames cannot be sampled
        case engineMissing       // the script did not install
        case modelMissing(String) // a specific model file is not downloaded
        /// The pack this feature is SET TO USE cannot run here — a choice that
        /// outlived the build that made it (an app update, a downgrade, a
        /// support root restored from a backup). The sentence comes from the
        /// descriptor contract, so the reason here is the same one the
        /// catalogue would give.
        case packIncompatible(String)

        /// One honest sentence, written for somebody who did not build this.
        var reason: String {
            switch self {
            case .noPython:
                return "The AI engine needs Python with PyTorch, which this Mac does not have."
            case .noFFmpeg:
                return "The AI engine needs ffmpeg to take frames out of a video."
            case .engineMissing:
                return "The AI engine did not install. Reinstalling the app should fix it."
            case .modelMissing(let name):
                return "The \(name) model has not been downloaded yet."
            case .packIncompatible(let why):
                return why
            }
        }

        /// Whether the app itself could fix this, or the user must.
        var fixableInApp: Bool {
            switch self {
            case .modelMissing: return true
            case .noPython, .noFFmpeg, .engineMissing, .packIncompatible: return false
            }
        }
    }

    /// What is blocking each feature. An empty list means the feature works.
    var blockers: [Feature: [Blocker]] = [:]

    func works(_ feature: Feature) -> Bool {
        (blockers[feature] ?? []).isEmpty
    }

    /// The first reason a feature cannot run, for a tooltip or a notice.
    func reason(_ feature: Feature) -> String? {
        blockers[feature]?.first?.reason
    }

    /// Is any AI feature usable at all? Drives whether the AI menus are worth
    /// showing as more than an invitation to install.
    var anythingWorks: Bool {
        Feature.allCases.contains { works($0) }
    }

    // MARK: - probing the machine

    /// Where a python that can run the engine might be. Shared with the engine
    /// itself so the two can never disagree about what counts as installed —
    /// they used to keep separate lists, which is how a capability check
    /// reports "ready" for an engine that then refuses to start.
    static let pythonCandidates = [
        "/opt/anaconda3/bin/python3", "/usr/bin/python3",
        "/usr/local/bin/python3", "/opt/homebrew/bin/python3",
    ]

    /// The ffmpeg the engine shells out to. Hardcoded there today; named here
    /// so the check and the use are the same path.
    static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
    ]

    static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Which engine this process will actually use. The probe has to report on
    /// the machine that will do the work: in Core ML mode — the default — there
    /// is no Python and no ffmpeg involved, and telling the user "the AI engine
    /// needs Python with PyTorch" while the Core ML path is busy classifying
    /// would be a plain lie about their own Mac.
    static var usesCoreML: Bool { CoreMLClassifier.mode == .coreml }

    /// Look at the machine and report. Cheap: a handful of file checks, no
    /// process is started and nothing is downloaded.
    ///
    /// Deliberately does NOT ask the engine whether it works — that would mean
    /// spawning it, which is the thing this check exists to avoid doing on a
    /// machine that cannot.
    static func probe() -> AICapability {
        usesCoreML ? probeCoreML() : probePython()
    }

    /// What the Core ML engine needs: two files beside each other, and no
    /// Python, no ffmpeg, no torch, no download of 1.7 GB at first run.
    static func probeCoreML() -> AICapability {
        var found = AICapability()

        // Scoped per feature, NOT shared across all of them. The image tower
        // and the prompt table are what the visual features read; face
        // recognition is YuNet plus SFace and touches neither. Listing them as
        // shared blockers meant someone who downloaded only the face pack was
        // told face recognition was not ready, and no amount of installing the
        // face pack could clear a reason that named the vision model —
        // pitfall 0 again, reported from a real clean-start install
        // (2026-09-17). `probePython` has always scoped these correctly; this
        // is the Core ML probe catching up.
        var visual: [Blocker] = []
        if !VisionEmbedder.isInstalled(root: Paths.support) {
            visual.append(.modelMissing("vision"))
        }
        if !PromptTable.isInstalled(root: Paths.support) {
            visual.append(.modelMissing("prompt table"))
        }

        for feature in Feature.allCases {
            var blockers: [Blocker] = []
            switch feature {
            case .classify, .tags: blockers = visual
            case .faces, .speech: break
            }
            // Safe/NSFW is Falconsai's job, so classify needs that model as
            // well. Tag suggestions do not: they ride on the image model and
            // the prompt table alone.
            if feature == .classify, !NSFWClassifier.isInstalled(root: Paths.support) {
                blockers.append(.modelMissing("Safe / NSFW classifier"))
            }
            // Faces need BOTH packages — the ported YuNet detector and the
            // SFace embedder — and the reason is a plain download reason like
            // any other: `.modelMissing` is the one blocker the app can fix
            // itself, so the Faces row gets a real Install button instead of a
            // pointer to a row that does not exist.
            //
            // Until Phase 6.2–6.4 this appended an unconditional blocker saying
            // "not ported to Core ML yet", which was true then and is not now.
            // Its cost was worse than being out of date: the text it produced
            // ("Settings → AI can download what is missing") sent the user to a
            // catalogue entry that was never published, so the instruction led
            // nowhere — pitfall 0 in its most irritating form.
            if feature == .faces, !FaceRegistry.isInstalled(root: Paths.support) {
                blockers.append(.modelMissing("face recognition"))
            }
            // Speech needs its own pack and nothing else; it shares no model
            // with any other feature, so a missing voice model must not read as
            // a missing vision model or the other way round.
            if feature == .speech, !hasSpeechModels() {
                blockers.append(.modelMissing("speech model"))
            }
            // The pack this feature is set to use, re-checked against THIS build
            // on every probe. A choice outlives the build that made it — an app
            // update that drops an adapter, a downgrade, a support root restored
            // from a backup — and none of those are visible to the catalogue's
            // own check, which only ever sees what is on offer today. The
            // sentence is the descriptor's, so this and the catalogue agree.
            if let chosen = ModelRegistry.read(root: Paths.support).selection(for: feature),
               let why = chosen.incompatibility(feature: feature) {
                blockers.append(.packIncompatible(why))
            }
            found.blockers[feature] = blockers
        }
        return found
    }

    /// The all-or-nothing speech check, shared by both probes.
    ///
    /// The pack is 22 files that only mean anything together, so "installed"
    /// means the four compiled model directories are all present. A pack that
    /// half-installed would otherwise fail at load time with something much
    /// less clear than "the speech model is not downloaded".
    private static func hasSpeechModels(root: String = Paths.support) -> Bool {
        for directory in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
                          "MelSpectrogram.mlmodelc", "TextDecoderContextPrefill.mlmodelc"] {
            let path = ((root as NSString).appendingPathComponent("models/speech") as NSString)
                .appendingPathComponent(directory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return false }
        }
        return true
    }

    /// The all-or-nothing face-model check, shared by both probes.
    private static func hasFaceModels() -> Bool {
        for file in ["face_detection_yunet_2023mar.onnx",
                     "face_recognition_sface_2021dec.onnx"] {
            let path = (AnalysisEngine.modelsDir as NSString).appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path) { return false }
        }
        return true
    }

    private static func probePython() -> AICapability {
        var found = AICapability()
        let fm = FileManager.default

        var shared: [Blocker] = []
        if firstExecutable(pythonCandidates) == nil { shared.append(.noPython) }
        if firstExecutable(ffmpegCandidates) == nil { shared.append(.noFFmpeg) }
        if !fm.fileExists(atPath: AnalysisEngine.installedScript)
            && Bundle.main.url(forResource: "engine", withExtension: "py") == nil {
            shared.append(.engineMissing)
        }

        // The vision model is the one download everything else waits on: no
        // embeddings means no verdict, no suggestion and no look-alike.
        let hf = (AnalysisEngine.modelsDir as NSString).appendingPathComponent("hf")
        let hasVisionModel = ((try? fm.contentsOfDirectory(atPath: hf)) ?? []).isEmpty == false

        for feature in Feature.allCases {
            // Speech is exempt from the engine's blockers in BOTH probes: it runs
            // in-process on the speech model and reads audio through AVFoundation,
            // so it uses neither the Python engine nor ffmpeg. Inheriting them
            // here would tell someone to install a thing speech never touches —
            // the same class of mistake the vision/face split fixed above.
            var blockers = feature == .speech ? [] : shared
            switch feature {
            case .classify, .tags:
                if !hasVisionModel { blockers.append(.modelMissing("vision")) }
            case .faces:
                if !hasFaceModels() { blockers.append(.modelMissing("face recognition")) }
            case .speech:
                if !hasSpeechModels() { blockers.append(.modelMissing("speech model")) }
            }
            found.blockers[feature] = blockers
        }
        return found
    }

    /// How much room the models take up, for the Settings row that offers to
    /// remove them. Walked off the main thread by the caller.
    static func modelsFootprint() -> Int64 {
        let url = URL(fileURLWithPath: AnalysisEngine.modelsDir)
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
