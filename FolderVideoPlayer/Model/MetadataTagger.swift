import Foundation
import AVFoundation
import CoreLocation

/// Scans a folder the user chose (subfolders optional) and works out, per
/// video, which tags its path, dates and metadata would earn — without
/// touching any tags. The sheet shows the plan with per-rule counts and the
/// user decides what to apply; apply() merges in only the enabled rules.
///
/// Two passes, and the second one is never paid for unless it is wanted:
///
/// * the **fast pass** (path + file dates) covers the folder and date rules.
///   One stat per video, a few at a time, and the plan is on screen as soon
///   as it finishes.
/// * the **detail pass** opens each video to read its metadata, which is what
///   the camera, quality and places rules need. It runs only when one of
///   those rules is ticked, and only over videos already walked.
///
/// Everything heavy is bounded: a folder of ten thousand videos on a NAS
/// opens a handful of files at a time, not ten thousand. Opening them all at
/// once is what made this appear to hang — the share was answering thousands
/// of simultaneous requests and the app had nothing to do but wait.
@MainActor
final class MetadataTagger: ObservableObject {

    /// How many files to have open at once. A NAS answers a handful of
    /// parallel requests faster than it answers a thousand; past this the
    /// share is the bottleneck and every extra request just queues.
    private static let parallel = 6

    /// One kind of tag the scan can add. Deliberately fine-grained: "places"
    /// as a single rule meant ticking it to get countries and receiving four
    /// hundred city tags as well. Each of these is a category you choose.
    enum Rule: String, CaseIterable, Identifiable {
        case folder, year, month, camera, quality, city, country
        var id: String { rawValue }

        var title: String {
            switch self {
            case .folder:  return "Folder names"
            case .year:    return "Year"
            case .month:   return "Month"
            case .camera:  return "Camera"
            case .quality: return "Quality & speed"
            case .city:    return "City"
            case .country: return "Country"
            }
        }

        var detail: String {
            switch self {
            case .folder:  return "the folders a video sits in — Cruise, 2024"
            case .year:    return "the capture year — 2024"
            case .month:   return "the capture month — May 2024"
            case .camera:  return "from the file's own metadata — iPhone 15 Pro"
            case .quality: return "4K · 1080p · 720p · 480p · Slow-mo"
            case .city:    return "town or city from GPS — many tags on a big library"
            case .country: return "country from GPS — a handful of tags at most"
            }
        }

        /// Whether the rule needs the slow pass that opens every video.
        var needsDetails: Bool {
            self == .camera || self == .quality || self == .city || self == .country
        }

        /// Whether the rule needs a network lookup on top of the file read.
        var needsNetwork: Bool { self == .city || self == .country }

        static let displayOrder: [Rule] = [.folder, .year, .month, .camera,
                                           .quality, .country, .city]
        /// Folder and year to begin with: cheap to work out, and few enough
        /// tags that nobody is surprised by the result.
        static let defaultOn: Set<Rule> = [.folder, .year]
    }

    enum Phase: Equatable {
        case idle
        case walking(Int)          // videos found so far
        case dating(Int, Int)      // fast pass: done, total
        case reading(Int, Int)     // detail pass: done, total
        case done
        case failed(String)
    }

    struct Plan {
        let root: String
        var videos = 0
        /// Per rule: how many videos would gain at least one tag from it.
        var hits: [Rule: Int] = [:]
        /// Per rule: how many *distinct* tag names it would create. This is
        /// the number that matters — "City" tagging 4,000 videos is fine,
        /// "City" creating 900 new tag names is a library nobody can use.
        var distinct: [Rule: Int] = [:]
        /// The names a rule would introduce, sorted — what the preview shows.
        var names: [Rule: [String]] = [:]
        /// Per video: the tags each scanned rule earned it.
        var detail: [String: [Rule: [String]]] = [:]
        /// Whether the metadata pass has been run over these videos.
        var readDetails = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: Plan?
    /// What the last apply did, for the sheet's summary line and Undo.
    @Published var result: (files: Int, tags: Int)?
    @Published var enabled: Set<Rule> = Rule.defaultOn

    /// The videos the walk found, kept so ticking a metadata rule reads them
    /// without walking the folder again.
    private var walked: [String] = []
    private var work: Task<Void, Never>?

    // MARK: - what a subfolder toggle must not pay for twice
    //
    // Ticking "Include subfolders" re-runs the scan, and it used to redo all
    // of it: the directory walk, and one stat per video for the dates. Ticking
    // it off and on again paid for the same answers three times over
    // (reported 2026-09-17).
    //
    // Both halves are cached against the root they were taken under. Turning
    // the box OFF now costs nothing at all — the smaller walk and every one of
    // its dates are already known. Turning it ON walks once more, but stats
    // only the videos the deeper walk added.
    //
    // Scope is one sheet: the caches live on this object, which the sheet owns
    // and drops when it closes. Within that window a file edited on disk would
    // keep its remembered date — acceptable for a preview the user approves
    // before anything is written, and the alternative is re-stat'ing thousands
    // of files on every toggle.
    private var cacheRoot: String?
    private var walkCache: [Bool: [String]] = [:]
    private var dateCache: [String: Date] = [:]

    /// Forget what was learned under a different folder.
    private func useCache(for root: String) {
        guard cacheRoot != root else { return }
        cacheRoot = root
        walkCache = [:]
        dateCache = [:]
    }

    deinit { work?.cancel() }

    var isBusy: Bool {
        switch phase {
        case .walking, .dating, .reading: return true
        default: return false
        }
    }

    /// Walk the folder and work out the folder and date tags. Fast: one stat
    /// a video, a few at a time. The metadata rules wait until asked for.
    func run(root: String, includeSubfolders: Bool, hidden: Set<String> = []) {
        work?.cancel()
        phase = .walking(0)
        plan = nil
        result = nil
        walked = []
        work = Task { [weak self] in
            guard let self else { return }
            self.useCache(for: root)
            let walked: [String]
            if let known = self.walkCache[includeSubfolders] {
                walked = known
            } else {
                walked = await Self.walk(root, includeSubfolders: includeSubfolders)
                guard !Task.isCancelled else { return }
                self.walkCache[includeSubfolders] = walked
            }
            // A hidden video is invisible to the app, so the metadata scan
            // must not read it, count it, or propose a tag for it.
            let paths = hidden.isEmpty
                ? walked
                : walked.filter { !hidden.contains(Paths.tagKey($0)) }
            self.walked = paths
            guard !paths.isEmpty else {
                self.plan = Plan(root: root, videos: 0)
                self.phase = .done
                return
            }
            // Only the videos whose date is not already known are stat'ed.
            // After a toggle that is the newly included subfolders, and after
            // a toggle back it is none of them.
            let unknown = paths.filter { self.dateCache[$0] == nil }
            var dates = self.dateCache
            if !unknown.isEmpty {
                self.phase = .dating(0, unknown.count)
                dates.reserveCapacity(dates.count + unknown.count)
                var seen = 0
                await Self.forEach(unknown, parallel: Self.parallel) { path in
                    (path, Self.fileDate(path))
                } onResult: { path, date in
                    if let date { dates[path] = date }
                    seen += 1
                    if seen.isMultiple(of: 50) || seen == unknown.count {
                        self.phase = .dating(seen, unknown.count)
                    }
                }
                guard !Task.isCancelled else { return }
                self.dateCache = dates
            }

            // The plan itself is arithmetic on strings — off the main actor,
            // because a folder of thousands would otherwise stutter the
            // window while it is built.
            var plan = await Task.detached(priority: .userInitiated) {
                var plan = Plan(root: root, videos: paths.count)
                plan.detail.reserveCapacity(paths.count)
                var seen: [Rule: Set<String>] = [:]
                for path in paths {
                    var tags: [Rule: [String]] = [:]
                    let folders = AutoTagCore.folderTags(of: path, under: root, depth: 2)
                    if !folders.isEmpty {
                        tags[.folder] = folders
                        plan.hits[.folder, default: 0] += 1
                        seen[.folder, default: []].formUnion(folders)
                    }
                    if let date = dates[path] {
                        if let year = AutoTagCore.yearTag(date) {
                            tags[.year] = [year]
                            plan.hits[.year, default: 0] += 1
                            seen[.year, default: []].insert(year)
                        }
                        let month = AutoTagCore.monthTag(date)
                        if !month.isEmpty {
                            tags[.month] = month
                            plan.hits[.month, default: 0] += 1
                            seen[.month, default: []].formUnion(month)
                        }
                    }
                    plan.detail[path] = tags
                }
                for (rule, names) in seen {
                    plan.distinct[rule] = names.count
                    plan.names[rule] = names.sorted()
                }
                return plan
            }.value
            guard !Task.isCancelled else { return }
            plan.readDetails = false
            self.plan = plan
            self.phase = .done

            // Deliberately does NOT read the files here, even when a metadata
            // rule is already ticked. Reading is Apply's job (2026-09-17):
            // this runs again whenever the subfolder toggle rebuilds the plan,
            // so auto-reading here put the user back in a minutes-long pass
            // for a box they ticked earlier.
        }
    }

    /// Open each walked video and read its metadata — the camera, quality and
    /// places rules. Runs on demand: pressing Apply with one of those rules
    /// ticked is what asks for it, so a folder-and-dates run never opens a
    /// single file, and neither does ticking a box.
    ///
    /// Places are geocoded only when that rule is ticked: it is a network
    /// round trip per location, and doing it for a rule nobody asked for was
    /// a large part of what made a big folder feel stuck.
    func readDetails() async {
        guard let plan, !plan.readDetails, !walked.isEmpty, !isBusy else { return }
        let paths = walked
        let wantCity = enabled.contains(.city)
        let wantCountry = enabled.contains(.country)
        let wantPlaces = wantCity || wantCountry
        phase = .reading(0, paths.count)

        var metadata: [String: Metadata] = [:]
        metadata.reserveCapacity(paths.count)
        var done = 0
        await Self.forEach(paths, parallel: Self.parallel) { path in
            var meta = await Self.metadata(path)
            if wantPlaces, let iso = meta.iso6709,
               let coord = AutoTagCore.parseISO6709(iso) {
                // Country alone never needs the fine city lookup, so a
                // country-only run is answered from the coarse grid and
                // costs a fraction of the requests.
                let found = await PlaceNames.shared.place(for: coord, city: wantCity)
                meta.city = found.city
                meta.country = found.country
            }
            return (path, meta)
        } onResult: { path, meta in
            metadata[path] = meta
            done += 1
            // Every file, not every twenty-fifth: this is the pass that takes
            // minutes, and a bar that does not move reads as a hang.
            self.phase = .reading(done, paths.count)
        }
        guard !Task.isCancelled else { return }

        let scored = await Task.detached(priority: .userInitiated) { [plan] () -> Plan in
            var plan = plan
            var seen: [Rule: Set<String>] = [:]
            for path in paths {
                guard var tags = plan.detail[path], let meta = metadata[path] else { continue }
                if let camera = AutoTagCore.cameraTag(make: meta.make, model: meta.model) {
                    tags[.camera] = [camera]
                    plan.hits[.camera, default: 0] += 1
                    seen[.camera, default: []].insert(camera)
                }
                let quality = AutoTagCore.qualityTags(width: meta.width,
                                                      height: meta.height,
                                                      fps: meta.fps)
                if !quality.isEmpty {
                    tags[.quality] = quality
                    plan.hits[.quality, default: 0] += 1
                    seen[.quality, default: []].formUnion(quality)
                }
                if let city = meta.city, !city.isEmpty {
                    tags[.city] = [city]
                    plan.hits[.city, default: 0] += 1
                    seen[.city, default: []].insert(city)
                }
                if let country = meta.country, !country.isEmpty {
                    tags[.country] = [country]
                    plan.hits[.country, default: 0] += 1
                    seen[.country, default: []].insert(country)
                }
                plan.detail[path] = tags
            }
            for (rule, names) in seen {
                plan.distinct[rule] = names.count
                plan.names[rule] = names.sorted()
            }
            plan.readDetails = true
            return plan
        }.value
        guard !Task.isCancelled else { return }
        self.plan = scored
        self.phase = .done
    }

    func cancel() { work?.cancel(); work = nil; phase = .idle }

    /// Apply the enabled rules into the library, as one undoable edit.
    ///
    /// These land in the FACTS store, not the tag store. Everything this class
    /// produces is a reading off the file — the capture date, the resolution,
    /// the camera that shot it, the place its GPS names — and a reading is a
    /// statement about the file rather than a judgement about the video. Two
    /// stores keep the distinction honest: the AI never trains on "1080p", the
    /// chips never offer a year to stick on by hand, and the count beside
    /// "Beach" means the number of videos you called a beach.
    ///
    /// The user's own tag of the same name is left completely alone. Somebody
    /// who typed "2016" by hand keeps it as a tag; the scan's "2016" is a
    /// separate reading, and `Library.carries` shows the video's names once.
    func apply(enabled: Set<Rule>, library: Library) {
        guard let plan else { return }
        library.rememberForUndo("auto-tag “\((plan.root as NSString).lastPathComponent)”")
        var filesTagged = 0
        var tagsAdded = 0
        for (path, byRule) in plan.detail {
            let wanted = Rule.displayOrder
                .filter { enabled.contains($0) }
                .compactMap { byRule[$0] }
                .flatMap { $0 }
            if wanted.isEmpty { continue }
            let existing = library.factsFor(path)
            let merged = AutoTagCore.merged(existing: existing, adding: wanted)
            guard merged.count != existing.count else { continue }
            library.setFacts(merged, for: path)
            filesTagged += 1
            tagsAdded += merged.count - existing.count
        }
        library.saveFacts()
        result = (filesTagged, tagsAdded)
        self.enabled = enabled
    }

    // MARK: - bounded parallel work

    /// Run `job` over every item with at most `parallel` in flight, handing
    /// each result back as it lands.
    ///
    /// The point is the ceiling. A task group given ten thousand items starts
    /// ten thousand tasks, and ten thousand simultaneous reads of a network
    /// share is slower than six — much slower, and it looks like a hang
    /// because nothing finishes for a long time.
    private static func forEach<Item: Sendable, Value: Sendable>(
        _ items: [Item],
        parallel: Int,
        job: @escaping @Sendable (Item) async -> (String, Value),
        onResult: (String, Value) -> Void
    ) async {
        await withTaskGroup(of: (String, Value).self) { group in
            var next = items.makeIterator()
            var running = 0
            func start() {
                guard let item = next.next() else { return }
                running += 1
                group.addTask { await job(item) }
            }
            for _ in 0..<max(parallel, 1) { start() }
            while let (key, value) = await group.next() {
                running -= 1
                onResult(key, value)
                if Task.isCancelled { group.cancelAll(); return }
                start()
            }
        }
    }

    // MARK: - walking & metadata (off the main actor)

    struct Metadata: Sendable {
        var make: String?
        var model: String?
        var width = 0
        var height = 0
        var fps = 0.0
        var iso6709: String?
        var city: String?
        var country: String?
    }

    /// Every video under a folder, in no particular order — the plan does not
    /// care. Non-recursive stops at the top folder.
    nonisolated static func walk(_ root: String, includeSubfolders: Bool) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            var out: [String] = []
            let fm = FileManager.default
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                           includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles]) else { return [] }
            // Stepped by nextObject() rather than for-in: makeIterator is
            // unavailable from async contexts (Swift 6 will make it an error).
            while let url = walk.nextObject() as? URL {
                if Task.isCancelled { return out }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if !includeSubfolders { walk.skipDescendants() }
                    continue
                }
                if videoExtensions.contains(url.pathExtension.lowercased()) {
                    out.append(url.path)
                }
            }
            return out
        }.value
    }

    nonisolated static func fileDate(_ path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.creationDate] as? Date ?? attrs?[.modificationDate] as? Date
    }

    /// The metadata a video carries about itself: camera make/model, its
    /// geometry and frame rate, and the ISO 6709 location iPhone embeds.
    /// Any of it failing is fine — the file is simply tagged from what is
    /// there.
    nonisolated static func metadata(_ path: String) async -> Metadata {
        var meta = Metadata()
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let value = try? await item.load(.stringValue) else { continue }
                switch item.commonKey {
                case .commonKeyMake:     meta.make = value
                case .commonKeyModel:    meta.model = value
                case .commonKeyLocation: meta.iso6709 = value
                default: break
                }
            }
        }
        if let tracks = try? await asset.load(.tracks),
           let video = tracks.first(where: { $0.mediaType == .video }) {
            if let size = try? await video.load(.naturalSize) {
                meta.width = Int(size.width)
                meta.height = Int(size.height)
            }
            if let fps = try? await video.load(.nominalFrameRate) {
                meta.fps = Double(fps)
            }
        }
        return meta
    }
}

/// City and country names for a GPS fix, remembered so a thousand clips from
/// one holiday cost one lookup.
///
/// An actor rather than a static dictionary: the scan asks from several tasks
/// at once, and a plain dictionary written from parallel tasks is a data race
/// — the kind that corrupts rather than merely races.
actor PlaceNames {
    static let shared = PlaceNames()

    /// City names, keyed to ~1 km. Cities are small, so this has to be fine.
    private var cities: [String: String] = [:]
    /// Country names, keyed to a coarse ~55 km grid. A country does not
    /// change over half a degree, so one lookup covers a whole region — a
    /// fortnight's holiday clips usually cost a single request.
    private var countries: [String: String] = [:]
    /// Fixes already looked up and found to have no name, so a blank answer
    /// is not asked for again and again.
    private var barren: Set<String> = []
    /// When the last request went out. Apple rate-limits reverse geocoding
    /// (roughly a request a second before it starts refusing), and a refused
    /// request is what left a thousand clips with no place tag at all.
    private var lastRequest = Date.distantPast
    /// Set when the geocoder has started refusing. Cleared on the next
    /// success; while it is on, only cached answers are given out.
    private var throttledUntil = Date.distantPast

    /// City and country for a GPS fix.
    ///
    /// `city: false` answers from the coarse country grid alone and never
    /// asks for a fine lookup — a country-only run over a holiday's clips is
    /// typically one request, where asking per city would be hundreds and
    /// most would be refused.
    ///
    /// Country is the reliable half either way: if the network or the rate
    /// limit denies the city, the country still lands.
    func place(for coord: (lat: Double, lon: Double), city wantCity: Bool)
        async -> (city: String?, country: String?) {
        let cityKey = String(format: "%.2f,%.2f", coord.lat, coord.lon)
        let countryKey = Self.coarseKey(coord)
        let knownCity = cities[cityKey]
        let knownCountry = countries[countryKey]

        // Everything asked for is already known.
        if knownCountry != nil {
            if !wantCity { return (nil, knownCountry) }
            if knownCity != nil || barren.contains(cityKey) {
                return (knownCity, knownCountry)
            }
        }
        guard Date() >= throttledUntil else {
            return (wantCity ? knownCity : nil, knownCountry)
        }

        // One request at a time, spaced out: the geocoder refuses a burst.
        let gap = Date().timeIntervalSince(lastRequest)
        if gap < 1.1 {
            try? await Task.sleep(for: .milliseconds(Int((1.1 - gap) * 1000)))
        }
        guard !Task.isCancelled else { return (wantCity ? knownCity : nil, knownCountry) }
        lastRequest = Date()

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.lat, longitude: coord.lon)
        let placemarks: [CLPlacemark]?
        do {
            placemarks = try await geocoder.reverseGeocodeLocation(location)
            throttledUntil = .distantPast
        } catch {
            // Refused or offline. Back off so the rest of the scan does not
            // spend itself on requests that will not land.
            if (error as NSError).code == CLError.network.rawValue {
                throttledUntil = Date().addingTimeInterval(20)
            }
            return (wantCity ? knownCity : nil, knownCountry)
        }

        guard let place = placemarks?.first else {
            barren.insert(cityKey)
            return (nil, knownCountry)
        }
        var foundCity: String?
        if let locality = place.locality, !locality.isEmpty {
            cities[cityKey] = locality
            foundCity = locality
        } else {
            barren.insert(cityKey)
        }
        var foundCountry = knownCountry
        if let country = place.country, !country.isEmpty {
            countries[countryKey] = country
            foundCountry = country
        }
        return (wantCity ? foundCity : nil, foundCountry)
    }

    /// ~55 km cells: fine enough to keep countries apart anywhere it matters,
    /// coarse enough that a holiday's worth of clips shares one lookup.
    nonisolated static func coarseKey(_ coord: (lat: Double, lon: Double)) -> String {
        String(format: "%.1f,%.1f", (coord.lat * 2).rounded() / 2,
                                    (coord.lon * 2).rounded() / 2)
    }
}
