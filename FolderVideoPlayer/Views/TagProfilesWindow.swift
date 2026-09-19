import SwiftUI

/// One guessed heading, ticked or not. Carries the video count so the sheet can
/// show what a heading is worth before it is accepted.
struct GroupProposal: Identifiable {
    let tag: String
    let group: String
    let count: Int
    var accepted: Bool
    var id: String { tag }
}

/// Tag profiles, and the tags inside them.
///
/// A tag profile is one person's set of tags. Several people can share a Mac
/// and a NAS without writing over each other, and one person with two machines
/// is still one profile — this window is where you say which you are, and the
/// only place tags are managed.
///
/// You can look at anybody's profile. You can only change your own: the tags
/// in another profile are that person's work, published from their devices,
/// and nothing here pretends otherwise.
struct TagProfilesWindow: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var suggestions: SuggestionStore

    @State private var chosen: String?
    @State private var shared: [SharePerson] = []
    @State private var otherTags: [(name: String, count: Int)] = []
    @State private var orphans: Set<String> = []
    @State private var selectedTags: Set<String> = []
    /// Tags under headings rather than one flat run.
    @State private var grouped = false
    /// Headings the app has guessed, waiting for the user to approve them.
    /// Empty when no sheet is up — the sheet's presence IS this being non-empty.
    @State private var proposals: [GroupProposal] = []
    /// Whether each tag shows how close it is to training.
    @State private var showHealth = true
    @State private var loading = false
    /// The Phase D training run: non-nil while a fit is in flight, and the
    /// result text shown beside the button afterwards.
    @State private var training: String?
    /// The Safe/NSFW correction-head fit, same shape as `training`.
    @State private var nsfwTraining: String?
    /// Said here rather than through the app model: that alert belongs to the
    /// player window, so anything reported through it brought the player to
    /// the front and left this window behind — which looked like the window
    /// closing itself after every action.
    @State private var notice: AppModel.Notice?

    private var profiles: [String] { library.allProfiles(includingShared: shared) }
    private var showing: String { chosen ?? library.activeProfile }
    private var isMine: Bool { library.isActive(showing) }

    var body: some View {
        HSplitView {
            profileList
            tagList
        }
        // Filling the window rather than sizing to the content: given only a
        // minimum, SwiftUI sizes this to whatever is inside it and the window
        // centres the result, which drops the whole interface down the page
        // the moment the content changes height.
        .frame(minWidth: 640, minHeight: 380,
               maxHeight: .infinity, alignment: .top)
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.detail))
        }
        .sheet(isPresented: Binding(get: { !proposals.isEmpty },
                                    set: { if !$0 { proposals = [] } })) {
            proposalSheet
        }
        .task { await load() }
        .onChange(of: showing) {
            Task { await loadTags() }
            deviceDraft = library.publishDeviceName
        }
    }

    // MARK: - the profiles

    /// The approval sheet for guessed headings.
    ///
    /// Grouped by heading rather than listed flat, because the question the
    /// user is actually answering is "are these all places?" — one glance per
    /// heading, not one decision per tag.
    private var proposalSheet: some View {
        let byGroup = Dictionary(grouping: proposals.indices, by: { proposals[$0].group })
        return VStack(alignment: .leading, spacing: 12) {
            Text("Headings for \(proposals.count) tags")
                .font(.headline)
            Text("Untick anything that looks wrong. Nothing is filed until you press Apply, and filing only sorts this list — it never changes a tag or a video.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(byGroup.keys.sorted(), id: \.self) { group in
                        let rows = byGroup[group]!
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(group).font(.subheadline).bold()
                                Text("\(rows.count)").foregroundStyle(.secondary)
                                Spacer()
                                // Whole heading at once: if the guess is wrong
                                // it is usually wrong for the group, not one tag.
                                Button(rows.allSatisfy { proposals[$0].accepted } ? "None" : "All") {
                                    let turnOn = !rows.allSatisfy { proposals[$0].accepted }
                                    for i in rows { proposals[i].accepted = turnOn }
                                }
                                .buttonStyle(.link)
                            }
                            ForEach(rows, id: \.self) { i in
                                Toggle(isOn: $proposals[i].accepted) {
                                    HStack(spacing: 6) {
                                        Text(proposals[i].tag)
                                        Text("\(proposals[i].count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 340)

            HStack {
                Text("\(proposals.filter(\.accepted).count) of \(proposals.count) ticked")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { proposals = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applyProposals() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!proposals.contains(where: \.accepted))
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(profiles, id: \.self, selection: $chosen) { name in
                HStack(spacing: 6) {
                    Image(systemName: library.isActive(name) ? "person.crop.circle.fill"
                                                             : "person.crop.circle")
                        .foregroundStyle(library.isActive(name) ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            // A row with nothing in it used to draw as nothing
                            // at all — an empty line between two profiles, with
                            // no way to tell what it was. Said here so it can be
                            // named or deleted on purpose.
                            Text(library.isNameless(name) ? "No name" : name)
                                .fontWeight(library.isActive(name) ? .semibold : .regular)
                                .foregroundStyle(library.isNameless(name)
                                                 ? Color.secondary : Color.primary)
                            if library.isActive(name) {
                                Text("yours").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let note = note(for: name) {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(name)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("New Profile…") { newProfile() }
                    Button("Duplicate…") { duplicate() }
                    Spacer()
                    Button("Use This Profile") { use(showing) }
                        .disabled(isMine)
                }
                HStack {
                    // Rename works on the row that is picked, not only on the
                    // profile in force: a blank row can never BE in force (an
                    // empty name is refused by every path that opens one), so
                    // naming it is the only way to keep what is in it. Deleting
                    // is refused for the profile that is actually open, and for
                    // nothing else — including while no profile is open, when a
                    // blank row is all there is to clear.
                    Button("Rename…") { rename() }
                        .disabled(!isMine && !library.isNameless(showing))
                    Button("Delete…") { deleteProfile() }
                        .disabled(library.isOpen(showing))
                    Spacer()
                }
                Toggle("Ask which profile at startup", isOn: $library.askProfileAtStartup)
                    .font(.caption)
                if isMine {
                    // What this Mac publishes as: the `<device>` of
                    // `tags-<device>.json` in this profile's share folder.
                    // Visible AND editable — the maintainer's decision of
                    // 2026-09-17, because a device name like "macbook-4f2a"
                    // is unreadable on the TV's profile list.
                    HStack(spacing: 6) {
                        Text("Publishes as").font(.caption).foregroundStyle(.secondary)
                        TextField("device name", text: $deviceDraft, onCommit: commitDevice)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .frame(maxWidth: 130)
                            .disabled(library.isPublishing)
                            .help("The file name your tags publish under on the shares "
                                  + "(tags-<name>.json). One name per Mac.")
                        Button("Set") { commitDevice() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(deviceDraft == library.publishDeviceName
                                      || library.isPublishing)
                    }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 340, maxHeight: .infinity)
    }

    private func note(for name: String) -> String? {
        if library.isNameless(name) {
            // Said rather than left blank: a row with nothing in it cannot be
            // opened, so the two things it CAN do are named here.
            return "no name — name it or delete it"
        }
        if library.isActive(name) {
            return "\(library.tagCounts.count) tags · this device"
        }
        guard let entry = shared.first(where: { slug($0.name) == slug(name) }) else {
            return "on this Mac only"
        }
        let devices = entry.devices == 1 ? "1 device" : "\(entry.devices) devices"
        return entry.changed > 0
            ? "\(devices) · \(entry.videos.count) videos · \(whenWords(entry.changed))"
            : "\(devices) · \(entry.videos.count) videos"
    }

    // MARK: - the tags inside one

    private var tagList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isMine ? "Your tags" : "\(showing)’s tags").font(.headline)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if isMine {
                    Toggle("Grouped", isOn: $grouped)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("File tags under headings like Place, Person, Event")
                    Toggle("Readiness", isOn: $showHealth)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("Show how many yes and no examples each tag has, and what it still needs")
                }
                Text("\(rows.count) tags").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()

            if rows.isEmpty {
                ContentUnavailableView(
                    loading ? "Reading…" : "No tags yet",
                    systemImage: "tag",
                    description: Text(isMine
                        ? "Tag a video with ⌘T and it will appear here."
                        : "Nothing has been published under this profile."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isMine && grouped {
                // Under headings. Only offered for your own tags: a published
                // profile is read-only, so filing it would be a lie.
                //
                // Readiness is worked out once here and passed down. Read from
                // inside the row instead, it is rebuilt for every row drawn.
                let standings = showHealth ? health : [:]
                List(selection: $selectedTags) {
                    ForEach(library.tagsByGroup(), id: \.group) { section in
                        Section(section.group ?? "Not filed yet") {
                            ForEach(section.tags, id: \.self) { name in
                                tagRow(name, library.count(of: name), standings[name])
                                    .tag(name)
                            }
                        }
                    }
                }
            } else {
                let standings = showHealth ? health : [:]
                List(rows, id: \.name, selection: $selectedTags) { row in
                    tagRow(row.name, row.count, standings[row.name]).tag(row.name)
                }
            }

            Divider()
            HStack {
                if isMine {
                    Button("Rename…") { renameTag() }.disabled(selectedTags.count != 1)
                    Button("Merge…") { mergeTags() }
                        .disabled(selectedTags.count < 2)
                        .help(selectedTags.count < 2
                              ? "Pick two or more tags to fold into one"
                              : "Fold \(selectedTags.count) tags into one")
                    Menu("File under…") {
                        ForEach(library.knownGroups(), id: \.self) { g in
                            Button(g) { library.setGroup(g, for: Array(selectedTags)) }
                        }
                        if !library.knownGroups().isEmpty { Divider() }
                        Button("New Heading…") { newGroup() }
                        Button("Remove from Heading") {
                            library.setGroup(nil, for: Array(selectedTags))
                        }
                    }
                    .fixedSize()
                    .disabled(selectedTags.isEmpty)
                    // Outside the menu above, which needs a selection: this one
                    // is about the whole list, and is most wanted when nothing
                    // is filed and so nothing is selected.
                    Button("Sort All…") { proposeGroups() }
                        .help("Suggest a heading for every tag — you approve before anything is filed")
                    Button("Delete…") { deleteTag() }.disabled(selectedTags.isEmpty)
                    // Whatever the last destructive edit was, one click puts it
                    // back — including after a quit, since it is kept on disk.
                    Button(undoLabel) { undo() }
                        .disabled(library.undoable == nil && !library.hasStoredUndo)
                    Spacer()
                    Button(training == nil ? "Train Tags from Me" : "Training…") {
                        trainFromDecisions()
                    }
                    .disabled(training != nil)
                    Button(nsfwTraining == nil ? "Train Safe/NSFW Boundary" : "Training…") {
                        trainNsfwBoundary()
                    }
                    .disabled(nsfwTraining != nil)
                    Button("Clear Orphans…") { clearOrphans() }
                    Button("Publish Now") { publish() }
                } else {
                    // Somebody else's work, published from their devices.
                    Label("Only \(showing)’s own devices can change these tags.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(10)
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One tag: its name, whether it is stranded, how many videos carry it,
    /// and how close it is to being trainable.
    private func tagRow(_ name: String, _ count: Int, _ standing: TagHealth?) -> some View {
        HStack(spacing: 6) {
            Text(name)
            if isMine && orphans.contains(name) {
                Text("nothing left").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isMine && showHealth, let standing { healthBadge(standing) }
            Text("\(count)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var rows: [(name: String, count: Int)] {
        isMine ? library.assignableTags().map { ($0, library.count(of: $0)) } : otherTags
    }

    // MARK: - tag health

    /// How close a tag is to being able to train, per the engine's floors.
    ///
    /// The 4-and-4 gate was invisible: a tag could sit at 23 positives and 0
    /// rejections forever with nothing on screen to say why it never trained.
    /// This puts the two numbers and the verdict next to the tag itself.
    struct TagHealth {
        var positives = 0
        var rejections = 0
        /// Both floors met, so the next training pass will fit a head.
        var trainable: Bool { positives >= 4 && rejections >= 4 }
        /// What it is short of, in the user's words.
        var need: String? {
            if trainable { return nil }
            var wants: [String] = []
            if positives < 4 { wants.append("\(4 - positives) more yes") }
            if rejections < 4 { wants.append("\(4 - rejections) more no") }
            return wants.joined(separator: ", ")
        }
    }

    /// Readiness for every tag at once.
    ///
    /// Built in one pass and handed to the rows, because it used to be a
    /// computed property that each row read by name: with the badges showing,
    /// drawing N tags rebuilt this N times, and each rebuild walked the whole
    /// vocabulary again for every suggestion on file. That is what made
    /// clicking a tag feel slow.
    private var health: [String: TagHealth] {
        guard let suggestions = app.suggestions else { return [:] }
        let names = library.assignableTags()
        var out: [String: TagHealth] = [:]
        out.reserveCapacity(names.count)
        // One index by lowercased name, so matching a suggestion to its tag is
        // a lookup rather than a scan through every tag.
        var byLowercased: [String: String] = [:]
        byLowercased.reserveCapacity(names.count)
        for name in names {
            out[name] = TagHealth(positives: library.count(of: name), rejections: 0)
            byLowercased[name.lowercased()] = name
        }
        for entry in suggestions.exampleCounts() {
            guard let display = byLowercased[entry.tag.lowercased()] else { continue }
            out[display]?.rejections = entry.rejected
        }
        return out
    }

    /// One tag's standing, drawn small beside its name.
    @ViewBuilder
    private func healthBadge(_ h: TagHealth) -> some View {
        HStack(spacing: 4) {
            Text("\(h.positives)✓ \(h.rejections)✗")
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(.secondary)
            if h.trainable {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .help("Enough examples — the next training pass will fit a head for this tag")
            } else if let need = h.need {
                Text(need)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("A tag needs 4 yes and 4 no before a head can be fitted")
            }
        }
    }

    // MARK: - doing things

    /// Every report this window makes stays in this window.
    private func say(_ title: String, _ detail: String) {
        notice = AppModel.Notice(title: title, detail: detail)
    }

    // MARK: - Phase D: train per-tag heads from the user's own decisions

    /// Fit a small head per tag from everything the user has ruled on.
    ///
    /// Labels come from the whole library here (this window's scope): the
    /// tag library as positives, chip rejections and exclusive-pair rules as
    /// negatives. Frame hashes come from the analysis store, keyed the same
    /// share-relative way — so a video contributes its cached vectors without
    /// re-reading a single pixel. Results are said here, in this window, per
    /// tag. The playlist's Train button runs the same builder scoped to its
    /// own rows.
    private func trainFromDecisions() {
        guard let analysis = app.analysis, let engine = app.engine else { return }
        guard let library = app.library else { return }
        let set = TrainingSetBuilder.build(scopeKeys: nil,
                                           library: library,
                                           suggestions: suggestions,
                                           analysis: analysis)
        guard !set.labels.isEmpty else {
            return say("Nothing to train on yet",
                       "Tag some videos first — typed tags, or accepted "
                       + "suggestions (⌘T while a video plays). A tag needs "
                       + "at least 4 accepted and 4 rejected videos before a "
                       + "head can be fitted for it, so rejection clicks "
                       + "(⌥click a wrong chip) matter too.")
        }
        // The engine reads ONLY cached embeddings. Labelled videos it has
        // never analysed would silently drop out of the fit, so they are
        // reported in the result instead of whispered away.
        let frameHashes = set.frameHashes
        let parkedByTag = parkedCounts(in: set)
        training = ""
        Task {
            do {
                let fits = try await engine.trainHeads(labels: set.labels,
                                                       frameHashes: frameHashes)
                let lines = fits.map { fit in
                    fit.fitted
                        ? "✓ \(fit.tag): fitted on \(fit.videos ?? 0) videos, "
                          + "held-out precision \(fit.precision.map { "\($0)" } ?? "–")"
                        : "– \(fit.tag): \(fit.reason ?? "skipped")"
                }
                var parkedLines: [String] = []
                for (tag, n) in parkedByTag.sorted(by: { $0.value > $1.value }) {
                    parkedLines.append("⏳ \(tag): \(n) tagged video\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") Analyse first")
                }
                training = nil
                let all = lines + parkedLines
                say(fits.contains(where: \.fitted) ? "Trained" : "Nothing fitted",
                    all.isEmpty ? "No tag had enough examples." : all.joined(separator: "\n"))
            } catch {
                training = nil
                say("Training failed", error.localizedDescription)
            }
        }
    }

    /// How many tagged videos per tag have no cached embeddings yet — they
    /// cannot teach until an Analyse pass has seen them.
    private func parkedCounts(in set: TrainingSetBuilder.Result) -> [String: Int] {
        let unanalysed = Set(set.unanalysed)
        var counts: [String: Int] = [:]
        for (tag, perKey) in set.labels {
            for key in perKey.keys where unanalysed.contains(key) {
                counts[tag, default: 0] += 1
            }
        }
        return counts
    }

    /// Fit the Safe/NSFW correction head from the user's mark history.
    ///
    /// Safe/NSFW is a forced-binary verdict, not a tag, but the user's marks
    /// were being recorded and never used — this closes that loop. A mark
    /// (userLabel) plus the video's cached frame hashes become one labelled
    /// example; NSFW = positive, Safe = negative. Reported here (not through
    /// the app model) so the window stays put, exactly like tag training.
    private func trainNsfwBoundary() {
        guard let analysis = app.analysis, let engine = app.engine else { return }
        var labels: [String: Bool] = [:]
        var frameHashes: [String: [String]] = [:]
        var parked = 0
        for (key, record) in analysis.records {
            guard let label = record.userLabel else { continue }
            let hashes = record.frameScores.map(\.hash)
            if hashes.isEmpty { parked += 1; continue }
            labels[key] = (label == .nsfw)
            frameHashes[key] = hashes
        }
        guard !labels.isEmpty else {
            return say("Nothing to train on",
                       "Mark some videos Safe or NSFW first. A marked video "
                       + "must also have been Analysed — its embeddings are "
                       + "what the head learns from.")
        }
        nsfwTraining = ""
        Task {
            do {
                let fit = try await engine.trainNsfw(labels: labels,
                                                     frameHashes: frameHashes)
                nsfwTraining = nil
                var detail: String
                if fit.fitted {
                    detail = "✓ fitted on \(fit.videos ?? 0) marks, "
                        + "held-out precision \(fit.precision.map { "\($0)" } ?? "–")"
                    if let recall = fit.recall { detail += ", recall \(recall)" }
                } else {
                    detail = fit.reason ?? "skipped"
                }
                if parked > 0 {
                    detail += "\n⏳ \(parked) marked video\(parked == 1 ? "" : "s") "
                        + "not classified yet — run Classify, then Train again"
                }
                say(fit.fitted ? "Trained Safe/NSFW boundary" : "Nothing fitted", detail)
            } catch {
                nsfwTraining = nil
                say("Training failed", error.localizedDescription)
            }
        }
    }

    /// Videos whose Safe/NSFW mark the user set by hand — the strongest label
    /// there is. Kept for the record: a Safe/NSFW mark is a verdict, not a
    /// tag, so it is not fed to the per-tag heads.
    private var labelledAnalysisVideos: [(key: String, tag: String)] {
        guard let analysis = app.analysis else { return [] }
        return analysis.records
            .filter { $0.value.userLabel != nil && !$0.value.frameScores.isEmpty }
            .map { (key: $0.key, tag: "marked \($0.value.userLabel!.rawValue)") }
    }

    private func load() async {
        await loadTags()
        shared = await library.sharePeople()
    }

    private func loadTags() async {
        selectedTags = []
        loading = true
        defer { loading = false }
        if isMine {
            orphans = Set(await library.orphanedTags())
            otherTags = []
        } else {
            orphans = []
            otherTags = Library.counts(in: await library.tags(ofProfile: showing))
        }
    }

    /// Having taken a profile on, claim its folder on every share and take in
    /// what its other devices have already said.
    private func adopt() async {
        // The share side of adopting a profile lives in `Library` now, because
        // File ▸ Open Profile has to do exactly the same four things in exactly
        // the same order — a claim before a merge, a merge before a publish.
        await library.adoptProfileOnShares()
        await load()
    }

    /// Copy a profile — the way to start from somebody else's tags, or to take
    /// a working copy before changing anything, rather than from nothing.
    /// Put a different profile in force. Nothing is lost either way: the one
    /// being left keeps its tags in its own file.
    private func use(_ name: String) {
        // Nothing from the old profile stays on screen. Its playlist was built
        // from ITS tags, so the rows would be a list the new profile never
        // chose, with one of them playing.
        app.playback?.closePlaylist()
        // Ticked rows point at the old profile's videos, so they go too.
        app.selectNone()
        library.switchProfile(to: name)
        Task {
            await adopt()
            app.playback?.rebuildRows()
        }
    }

    private func duplicate() {
        let source = showing
        guard let name = ask("Duplicate “\(source)”",
                             "Its tags are copied into a new profile that is yours to "
                             + "change. “\(source)” is left exactly as it is.",
                             source + " copy") else { return }
        Task {
            app.playback?.closePlaylist()
            app.selectNone()
            guard await library.duplicateProfile(source, as: name) else {
                return say("That name is taken",
                               "A profile is already called that. Choose another name.")
            }
            chosen = name
            app.playback?.rebuildRows()
            await adopt()
        }
    }

    private func newProfile() {
        // Said plainly, because an empty tag list after this looked like the
        // tags had been lost rather than set aside.
        let count = library.tagCounts.count
        let kept = count == 0 ? ""
            : " Your \(count) tags stay with “\(library.activeProfile)” and come back "
              + "when you choose it again."
        guard let name = ask("New tag profile",
                             "Tags are kept per profile, so two people sharing this Mac "
                             + "never write over each other. A new profile starts empty."
                             + kept,
                             "") else { return }
        library.createProfile(name)
        chosen = name
        // A brand new profile has no tags and no folders, so it certainly has
        // no playlist. Cleared for the same reason as a switch.
        app.playback?.closePlaylist()
        app.selectNone()
        Task { await adopt() }
    }

    /// Renaming keeps the tags and changes the name. Creating a profile is the
    /// other thing, and the two are one click apart, so this says which it is.
    ///
    /// A blank row is routed first, and separately: it cannot be opened at all,
    /// so "the profile in force" is the wrong thing to rename — and in the
    /// closed state an empty name reads as `isMine`, which would have sent it
    /// through the rename of a profile that is not really there.
    private func rename() {
        let old = showing
        if library.isNameless(old) { return nameNameless() }
        guard let name = ask("Rename “\(old)”",
                             "It keeps its \(library.tagCounts.count) tags and its place on "
                             + "the shares — only the name changes. To start an empty "
                             + "profile instead, use New Profile.",
                             old)
        else { return }
        guard library.renameActiveProfile(to: name) else {
            return say("That name is taken",
                           "Another profile is already called that. Renaming into it would "
                           + "publish these tags over theirs.")
        }
        chosen = name
        Task {
            // The folder on the share goes with it. Without this the old name
            // stayed there and came back in the list as a second profile,
            // which read as the rename having made one rather than moved one.
            let moved = await library.renameOnShares(from: old, to: name)
            await adopt()
            if !moved.isEmpty {
                say("Renamed to “\(name)”",
                        "Its folder was moved on: \(moved.joined(separator: ", ")).\n\n"
                        + "Any other device still set to “\(old)” will make that name "
                        + "again the next time it publishes — change it there too.")
            }
        }
    }

    /// A blank row's rename IS its naming: there is no name to keep, and
    /// nothing can put such a row in force, so this is the only way to keep
    /// what it holds — its readings, its suggestions, the people it knows.
    /// Everything it has moves under the new name.
    private func nameNameless() {
        guard let name = ask("Name this profile",
                             "It has no name, so nothing can open it and nothing "
                             + "publishes for it. Naming it keeps everything it holds "
                             + "and files it under the new name — the same as renaming "
                             + "any other profile.",
                             "") else { return }
        guard library.nameNamelessProfile(to: name) else {
            return say("That name is taken",
                       "Another profile is already called that, and two profiles must not "
                       + "share one folder on the shares. Choose another name.")
        }
        chosen = name
        Task { await adopt() }
    }

    /// Deleting a profile, for good.
    ///
    /// Everything goes: this Mac's copy and the folder on every mounted share,
    /// which is every device's tags for that profile and not only this one's.
    /// There is no undo, so the name has to be typed — a button nobody reads
    /// is not a safeguard.
    private func deleteProfile() {
        let name = showing
        let onShares = shared.first { slug($0.name) == slug(name) }?.shares ?? []
        let where_ = onShares.isEmpty ? "this Mac"
                                      : "this Mac and " + onShares.joined(separator: ", ")
        guard confirmDelete(name, from: where_) else { return }
        chosen = nil
        Task {
            let (cleared, failed) = await library.deleteProfile(name)
            var lines = cleared.map { "✓ \($0)" } + failed.map { "✗ \($0.0): \($0.1)" }
            if !failed.isEmpty {
                lines.append("\nA share that refused still holds the folder. Deleting it "
                             + "in Finder needs ⌥⌘⌫, since a NAS share usually has no "
                             + "Trash to move it to.")
            }
            say(failed.isEmpty ? "“\(name)” deleted" : "Deleted here, but a share refused",
                lines.isEmpty ? "It was only on this Mac." : lines.joined(separator: "\n"))
            await load()
        }
    }

    /// The safeguard, and the reason a blank row could not be deleted at all:
    /// the rule is that you type the profile's name, but the name of a blank
    /// row is nothing, and `ask` hands back nil for an empty field — so that
    /// confirmation could never be satisfied. A row with no name is confirmed
    /// by its own button instead, and the alert says what goes.
    private func confirmDelete(_ name: String, from where_: String) -> Bool {
        guard library.isNameless(name) else {
            guard let typed = ask("Delete “\(name)”?",
                                  "Its tags go from \(where_) — every device's, not just this "
                                  + "one's — and this cannot be undone.\n\n"
                                  + "Type the profile's name to confirm.", ""),
                  slug(typed) == slug(name) else { return false }
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Delete the profile with no name?"
        alert.informativeText = "A blank row holds no tags — it is a name that never got "
            + "written. Deleting it clears \(where_) files for it and takes the row out "
            + "of this list.\n\n"
            + "A profile that is actually called “unknown” is left alone: an empty name "
            + "and that word share one slug, and its folder is not this row's to delete."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - the device name

    /// The draft sits in local state so typing is free and a Cancel-shaped
    /// edit (just leaving it) writes nothing. Seeded whenever the profile
    /// showing changes; committed only through Set or Return.
    @State private var deviceDraft: String = ""
    private func commitDevice() {
        library.setPublishDeviceName(deviceDraft)
        deviceDraft = library.publishDeviceName
    }

    private var undoLabel: String {
        library.undoable.map { "Undo \($0.label)" } ?? "Undo"
    }

    private func undo() {
        guard library.undoTagChange() else {
            return say("Nothing to undo", "No destructive change is on record.")
        }
        selectedTags = []
        app.playback?.refreshMembership()
        Task { await loadTags() }
    }

    private func renameTag() {
        guard isMine, let tag = selectedTags.first, selectedTags.count == 1,
              let name = ask("Rename tag", "What should “\(tag)” be called?", tag) else { return }
        library.renameTag(tag, to: name)
        selectedTags = [name]
        app.playback?.refreshMembership()
    }

    /// Fold several tags into one of them.
    ///
    /// Rename cannot do this — renaming onto a name a video already carries
    /// would leave it holding the tag twice. The survivor is the one carried
    /// by the most videos, which is almost always the spelling meant to win.
    private func mergeTags() {
        guard isMine, selectedTags.count > 1 else { return }
        let picked = Array(selectedTags).sorted {
            (library.count(of: $0), $1) > (library.count(of: $1), $0)
        }
        guard let target = ask("Merge tags",
                               "\(picked.count) tags become one. Which name survives?",
                               picked[0]) else { return }
        let losing = picked.filter { $0.caseInsensitiveCompare(target) != .orderedSame }
        guard !losing.isEmpty else {
            return say("Nothing to merge", "That name is the only one picked.")
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(losing.count) tags into “\(target)”?"
        alert.informativeText = losing.joined(separator: ", ")
            + "\n\nEvery video carrying those gets “\(target)” instead. "
            + "A video that already has it keeps just the one. The videos "
            + "themselves are untouched, and this can be undone."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let touched = library.mergeTags(losing, into: target)
        selectedTags = [target]
        app.playback?.refreshMembership()
        say("Merged", "\(touched) videos now carry “\(target)”.")
    }

    /// Guess a heading for every unfiled tag and show the guesses for approval.
    ///
    /// Nothing is filed by this call. The guesses go into `proposals`, a sheet
    /// lists them with a tick each, and only what survives that sheet is
    /// written. Filing is cheap to undo but tedious to check, so the check
    /// happens once, up front, where the whole list can be seen at a glance.
    private func proposeGroups() {
        guard isMine else { return }
        // Evidence, not word lists: people are whoever has a face on file, and
        // places include anything the metadata tagger wrote from GPS.
        let people = Set((app.faceStore?.people ?? []).map { $0.name.lowercased() })
        let places = Set(library.assignableTags()
            .filter { library.group(of: $0) == TagKinds.place }
            .map { $0.lowercased() })
        var out: [GroupProposal] = []
        for tag in library.assignableTags() where library.group(of: tag) == nil {
            if let g = TagKinds.guess(tag, knownPeople: people, knownPlaces: places) {
                out.append(GroupProposal(tag: tag, group: g,
                                         count: library.count(of: tag), accepted: true))
            }
        }
        if out.isEmpty {
            notice = .init(title: "Nothing to sort",
                           detail: "Every tag the app recognises already has a heading.")
            return
        }
        proposals = out.sorted { ($0.group, -$1.count) < ($1.group, -$0.count) }
    }

    /// Write the ticked proposals, one group at a time.
    private func applyProposals() {
        let byGroup = Dictionary(grouping: proposals.filter(\.accepted), by: \.group)
        for (group, rows) in byGroup {
            library.setGroup(group, for: rows.map(\.tag))
        }
        let n = proposals.filter(\.accepted).count
        proposals = []
        grouped = true          // show the result, or the work looks like nothing happened
        notice = .init(title: "Filed",
                       detail: n == 1 ? "1 tag now has a heading."
                                      : "\(n) tags now have headings.")
    }

    /// Start a new heading and file the picked tags under it in one go — a
    /// heading with nothing in it would be a row that does nothing.
    private func newGroup() {
        guard isMine, !selectedTags.isEmpty,
              let name = ask("New heading",
                             "What kind of thing are these tags? (Place, Person, Event…)",
                             "") else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        library.setGroup(clean, for: Array(selectedTags))
    }

    private func deleteTag() {
        guard isMine, !selectedTags.isEmpty else { return }
        let doomed = Array(selectedTags).sorted()
        let count = doomed.reduce(0) { $0 + library.count(of: $1) }
        let alert = NSAlert()
        alert.messageText = doomed.count == 1
            ? "Delete the tag “\(doomed[0])”?"
            : "Delete \(doomed.count) tags?"
        alert.informativeText = (doomed.count == 1 ? "" : doomed.joined(separator: ", ") + "\n\n")
            + (count == 1
               ? "It comes off 1 video. The video itself is untouched."
               : "They come off \(count) videos. The videos themselves are untouched.")
        alert.addButton(withTitle: doomed.count == 1 ? "Delete Tag" : "Delete Tags")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tag in doomed { library.deleteTag(tag) }
        selectedTags = []
        app.playback?.refreshMembership()
    }

    private func clearOrphans() {
        let count = orphans.count
        let alert = NSAlert()
        alert.messageText = "Clear tags whose videos have gone?"
        alert.informativeText = count == 0
            ? "Every entry whose file is missing is dropped. Nothing on disk is touched."
            : "\(count) tags have nothing left behind them. Every entry whose file is "
              + "missing is dropped. Nothing on disk is touched — but a drive that is "
              + "merely unplugged looks exactly like one whose files have gone, so do "
              + "this with your shares mounted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let gone = await library.clearOrphans()
            orphans = Set(await library.orphanedTags())
            say("Cleaned up", gone == 0
                    ? "Every tagged video is still where it was."
                    : "Dropped \(gone) entries whose video has gone.")
        }
    }

    private func publish() {
        Task {
            await library.claimName()
            let (written, skipped) = await library.publishTags()
            let lines = written.map { "✓ \($0.0): \($0.1) videos" }
                + skipped.map { "✗ \($0.0): \($0.1)" }
            say(skipped.isEmpty ? "Tags published" : "Some shares were not written",
                    lines.isEmpty
                        ? "This profile has no tags on any mounted share, so there was "
                          + "nothing to publish."
                        : lines.joined(separator: "\n\n"))
            shared = await library.sharePeople()
        }
    }
}
