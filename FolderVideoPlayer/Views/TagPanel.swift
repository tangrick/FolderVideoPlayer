import SwiftUI

/// The tag editor, sliding up over the video. While it is open playback holds
/// at the end of the current video rather than moving on: you are looking at
/// this one because you are labelling it.
struct TagPanel: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var suggestions: SuggestionStore
    @EnvironmentObject var faceStore: FaceStore
    @EnvironmentObject var journal: EvidenceJournal
    @State private var typed = ""
    @State private var showingAddFace = false
    /// Which person chip the cursor is over — reveals its yes/no buttons.
    @State private var hoveredPerson: String?
    /// Which tag chip the cursor is over — its reject ✕ goes red.
    @State private var hoveredTag: String?
    /// What a rejection took off, by tag name, so ↺ can put it back.
    ///
    /// The ✕ removes the tag on every target that carried it AND records the
    /// no. Undoing only the no left the tag gone while the chip stopped saying
    /// "rejected" — the undo looked like it worked and the tag was still lost.
    @State private var rejectionTookOff: [String: [String]] = [:]
    /// The "why was this suggested?" popover: which chip is asking, and the
    /// evidence once it has been recomputed.
    @State private var whyTag: String?
    @State private var whyValue: SuggestionExplanation?
    @State private var whyLoading = false
    @State private var whyInCoreML = false

    /// Which sections are folded away. Remembered across launches; the
    /// suggested section force-opens whenever it has something in it, because
    /// a suggestion nobody sees is a suggestion that never gets judged.
    @AppStorage("tagPanelPeopleOpen") private var peopleOpen = true
    @AppStorage("tagPanelTagsOpen") private var tagsOpen = true
    @AppStorage("tagPanelRejectsOpen") private var rejectsOpen = true

    /// What is being tagged: the batch when several are picked, otherwise
    /// whatever is playing. A single picked row IS the playing one, so both
    /// arms agree there. Left unsorted — a thousand selected paths are not
    /// worth sorting for something nothing displays.
    private var targets: [String] {
        if app.selection.count > 1 { return Array(app.selection) }
        return playback.currentPath.map { [$0] } ?? []
    }

    /// Only tags every target already has count as applied — a chip that half
    /// the selection carries is offered rather than shown as done.
    ///
    /// Counted in one pass over the targets. Asking `hasTag` per tag per
    /// target walked the selection once for every tag it holds.
    private var applied: [String] {
        guard !targets.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for path in targets {
            for name in library.tagsFor(path) {
                counts[name.lowercased(), default: 0] += 1
                if display[name.lowercased()] == nil { display[name.lowercased()] = name }
            }
        }
        return counts.filter { $0.value == targets.count }.keys.sorted().compactMap { display[$0] }
    }

    /// Machine suggestions for the one video in view.
    ///
    /// Suppressed for a multi-video selection on purpose: a suggestion is about
    /// a specific video's pictures, and accepting one across a selection would
    /// attach it to videos the engine never looked at.
    private var pendingSuggestions: [TagSuggestion] {
        guard targets.count == 1, let path = targets.first else { return [] }
        // A tag the video already carries is not a suggestion, it is an echo.
        // The engine is right, and saying so wastes the one row the user reads.
        // Case-insensitively, because "waterfall" and "Waterfall" are one tag
        // everywhere else in the app.
        let carried = Set(library.tagsFor(path).map { $0.lowercased() })
        return suggestions.pending(path).filter { !carried.contains($0.tag.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    app.showTagPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (esc)")
                .accessibilityLabel("Close the tag panel")
            }

            // Section 1 — People: who the face engine knows in this library,
            // offered above the tag editor. A named person is a tag — clicking
            // their chip labels this video with it, exactly like accepting a
            // suggestion. Adding a person happens in the separate People window
            // (pick a face, name it, the engine scans). The plain tag editor is
            // section 2, below the divider.
            //
            // The entire section is skipped when face recognition is off:
            // people ARE the face feature here, so leaving the header and an
            // "Add Face…" button behind would promise something the app has
            // been told not to do.
            if library.facesEnabled {
            foldHeader("People", icon: "person.2", open: peopleOpen) {
                withAnimation(.easeOut(duration: 0.15)) { peopleOpen.toggle() }
            }
            if peopleOpen, !people.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(people, id: \.name) { person in
                        personChip(person,
                                   applied: applied.contains(where: {
                                       $0.caseInsensitiveCompare(person.name) == .orderedSame
                                   }))
                    }
                }
            }
            if peopleOpen, faceStore.indexing {
                HStack(spacing: 6) {
                    if !faceStore.indexProgress.isEmpty {
                        Text(faceStore.indexProgress)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Button("Stop") { faceStore.cancelIndex() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Stop the scan at the next video")
                }
            } else if peopleOpen {
                Button {
                    guard app.requireAI(.faces) else { return }
                    showingAddFace = true
                } label: {
                    Label("Add Face…", systemImage: "person.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Add a person from the current video — pick the face, name it, and the app finds them everywhere")
            }
            Divider().padding(.vertical, 2)
            }

            HStack {
                TextField("Type tags, separated by commas", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Apply", action: commit)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // No Suggest Tags button: opening a video starts the pass itself
            // (maintainer's decision, 2026-09-17). While it runs, say so —
            // silence here reads as a broken feature, which is what the button
            // was accidentally protecting against.
            if targets.count == 1, let path = targets.first, app.suggestingPath == path {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Suggesting tags…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // What the machine thinks fits, kept visually apart from the real
            // tags below and from the user's own vocabulary. Nothing here has
            // been applied to anything: each chip is an offer, and the panel
            // says so in as many words.
            if !pendingSuggestions.isEmpty, let path = targets.first {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pendingSuggestions.count == 1
                         ? "Suggested — click to add, ✕ to say it is not"
                         : "\(pendingSuggestions.count) suggested — click to add, ✕ to say it is not")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Named for what it does. "Not these" read like the ✕ on
                    // every chip beside it — a judgement — when it is the
                    // opposite: it clears the row without teaching anything.
                    Button("Dismiss All") {
                        suggestions.dismissRest(path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Clear these suggestions without saying yes or no to any of them — nothing is learned")
                    // The explicit ask, beside the chips it is about. It runs
                    // the same pass that runs when a video opens — which is
                    // also the pass that records the moments next to each tag —
                    // so a video suggested before the app kept moments can be
                    // asked again without waiting for anything automatic.
                    Button("Look Again") {
                        NotificationCenter.default.post(name: AppModel.suggestTagsNotification,
                                                       object: path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .disabled(app.suggestingPath != nil)
                    .help("Ask the engine about this video again. This is the pass that also records when each tag was seen, so it fills in the times beside the chips.")

                    // Transcribing is never automatic — 646 MB of model and
                    // minutes of compute should not start because a video was
                    // double-clicked — so this row is the only way in. It sits
                    // against the video it acts on, like Look Again beside it.
                    if app.transcribingPath == path {
                        Text(app.transcribeProgress?.label ?? "Transcribing…")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Cancel") {
                            NotificationCenter.default.post(
                                name: AppModel.cancelTranscribeNotification, object: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                        .help("Stop transcribing. Nothing is written for half a transcript.")
                    } else {
                        Button(app.transcriptLines[path].map { "Transcribed · \($0.formatted()) lines" } ?? "Transcribe") {
                            NotificationCenter.default.post(
                                name: AppModel.transcribeNotification, object: path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                        .disabled(app.transcribingPath != nil)
                        .help("Write down what is said in this video, with the times. The model runs on this Mac; nothing is uploaded.")
                    }
                }

                ChipFlow(spacing: 6) {
                    ForEach(pendingSuggestions, id: \.tag) { (s: TagSuggestion) in
                        suggestionChip(s, path: path)
                    }
                }
                Divider().padding(.vertical, 2)
            }

            // Every tag there is — the same list the left sidebar shows —
            // offered as one wrapped set, so an existing tag can be assigned
            // to this video by clicking it.
            //
            // Split three ways rather than run alphabetically, because the
            // list is 99 chips long and the two short groups are the ones
            // being looked for: what this video IS, and what it has been told
            // it is NOT. Alphabetical order scattered a handful of struck-out
            // chips through a scrolling box where they could not be found.
            // What a PERSON may apply. Metadata tags (2016, iPhone 7, 1080p)
            // are the scan's to write and are deliberately not offered here —
            // they stay browsable in the sidebar and Tag Profiles.
            let assignable = library.handTaggableTags()

            // --- read off the file ------------------------------------------
            //
            // The facts: the capture date, the folder, the camera, the GPS.
            // Shown, because they are on the video and hiding them would make
            // the panel disagree with the sidebar — but not offered, and not
            // removable from here. Nothing is deleted or rewritten: these are
            // the same tags as always, gathered into their own row.
            let fileTags = library.provenance
                .metadataTags(on: Paths.tagKey(targets.first ?? ""),
                              from: targets.count == 1
                                    ? library.tagsFor(targets[0]) : [])
            if !fileTags.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("From the file").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("read, not guessed")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                ChipFlow(spacing: 6) {
                    ForEach(fileTags, id: \.self) { (name: String) in
                        Text(name)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.12),
                                        in: Capsule())
                            .help("“\(name)” was read from the file itself — the capture date, the folder, the camera or the GPS. No AI involved. Re-run Auto-Tag to change it")
                    }
                }
                Divider().padding(.vertical, 2)
            }
            let rejectedTags = assignable.filter { name in
                !applied.contains(name) && targets.contains {
                    suggestions.entry($0)?.verdicts[name] == .rejected
                }
            }
            let unused = assignable.filter {
                !applied.contains($0) && !rejectedTags.contains($0)
            }
            if !assignable.isEmpty {
                HStack(spacing: 6) {
                    foldHeader("Your tags", icon: "tag",
                               open: tagsOpen || !applied.isEmpty) {
                        withAnimation(.easeOut(duration: 0.15)) { tagsOpen.toggle() }
                    }
                    Text("\(applied.count) on this video"
                         + (rejectedTags.isEmpty ? "" : " · \(rejectedTags.count) rejected"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if tagsOpen || !applied.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    ChipFlow(spacing: 6) {
                        // What the video already is, first: state before offers.
                        ForEach(assignable.filter { applied.contains($0) }, id: \.self) { name in
                            chip(name, applied: true)
                        }
                        ForEach(unused, id: \.self) { (name: String) in
                            chip(name, applied: false)
                        }
                    }
                }
                .frame(maxHeight: 132)
                }
            }

            // The negatives, gathered and labelled. These are half the training
            // data and were the hardest thing on the panel to see: a struck-out
            // chip is quiet by design, and quiet things get lost in a long list.
            // Kept at the bottom, out of the way, but never scrolled away.
            if !rejectedTags.isEmpty {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    foldHeader("Said not", icon: "xmark.circle", open: rejectsOpen) {
                        withAnimation(.easeOut(duration: 0.15)) { rejectsOpen.toggle() }
                    }
                    Text(rejectsOpen
                         ? "click one to take it back"
                         : "\(rejectedTags.count) — the half of training that is always short")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if rejectsOpen {
                    ChipFlow(spacing: 6) {
                        ForEach(rejectedTags, id: \.self) { (name: String) in
                            chip(name, applied: false)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An opaque base under the material: over a very dark video the bare
        // material let the dark labels sink into the picture.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingAddFace) {
            AddPersonSheet(initialVideo: targets.first)
        }
    }

    private var title: String {
        if targets.count > 1 { return "Tagging \(targets.count) videos" }
        return targets.first.map { ($0 as NSString).lastPathComponent } ?? "Nothing to tag"
    }

    /// One tag chip, in one of three states: on this video, ruled out, or on
    /// offer.
    ///
    /// One rule holds across every chip in this panel, and in the People strip
    /// below: **clicking the chip body is the yes, the trailing ✕ is the no,
    /// and ⌥click on the body is the same as the ✕.** The ✕ used to mean
    /// "take this tag off" on an applied chip and "this is NOT the tag" on an
    /// offered one — the same glyph doing two different jobs depending on a
    /// state the user cannot see at a glance.
    ///
    /// So an applied chip now wears a checkmark to say it is on, and clicking
    /// it takes the tag off exactly as before. Its ✕ says you were wrong: the
    /// tag comes off AND a negative example is recorded.
    ///
    /// Rejecting from THIS list is the answer to "how do I reject a tag the
    /// app never offered me?" — a tag no model has learned yet is never
    /// suggested, so it could never be rejected, so it could never be
    /// trained.
    ///
    /// The style branches are separate Buttons because a ternary between two
    /// button styles defeats generic inference inside a layout builder.
    @ViewBuilder
    private func chip(_ name: String, applied: Bool) -> some View {
        let rejected = !applied && targets.contains {
            suggestions.entry($0)?.verdicts[name] == .rejected
        }
        HStack(spacing: 3) {
            if applied {
                Button {
                    // Destructive: this records the undo, so an accidental
                    // click on a ticked chip is recoverable from the Undo
                    // button in Tag Profiles (or straight away by clicking
                    // the chip again).
                    library.removeTag(name, from: targets)
                    playback.refreshMembership()
                } label: {
                    Label(name, systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("This video is tagged “\(name)” — click to take the tag off")
                rejectButton(name, help: "Wrong — takes “\(name)” off and records it as NOT this")
            } else if rejected {
                Button { undoReject(name) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                        Text(name).font(.caption).strikethrough()
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("You said this is NOT “\(name)”. Click to take that back.")
                // A reserved slot even here, so a chip does not change width
                // when it moves between states and shove its neighbours along.
                Color.clear.frame(width: 22, height: 22)
            } else {
                Button {
                    if NSEvent.modifierFlags.contains(.option) { reject(name) }
                    else {
                        // Adding is not destructive — `addTag` is also
                        // idempotent, so a selection where half already carry
                        // it ends with all of them carrying it once.
                        library.addTag(name, to: targets)
                        playback.refreshMembership()
                    }
                } label: {
                    Text(name).font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Click to tag this “\(name)”; the ✕ says it is NOT")
                rejectButton(name, help: "Not “\(name)” — records a negative example for training")
            }
        }
        // Hover on the WHOLE pair, so moving the cursor from the chip onto
        // the ✕ never dims it.
        .onHover { inside in
            hoveredTag = inside ? name : (hoveredTag == name ? nil : hoveredTag)
        }
        .animation(.easeOut(duration: 0.12), value: hoveredTag)
    }

    /// A section heading that folds its section away — the same shape as the
    /// sidebar's Years group, so folding means the same thing everywhere.
    ///
    /// `open` is what the caller passes because a section can be forced open
    /// by its own contents (a video with five tags applied keeps the tag list
    /// visible whatever the remembered setting says).
    @ViewBuilder
    private func foldHeader(_ title: String, icon: String, open: Bool,
                            toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 8)
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(open ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }

    /// The one "no" control, shared by every state so it is always the same
    /// size, in the same place, meaning the same thing.
    ///
    /// ALWAYS drawn, only faded when the cursor is elsewhere. Revealing it on
    /// hover changed the chip's width, which reflowed the whole wrapping list
    /// — the chip slid out from under the cursor and the click missed. A
    /// reserved slot means nothing ever moves, and the target is a real 22 pt
    /// button rather than a 10 pt glyph.
    private func rejectButton(_ name: String, help: String) -> some View {
        Button { reject(name) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(hoveredTag == name ? Color.red : Color.secondary)
                .opacity(hoveredTag == name ? 1 : 0.55)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Not \(name)")
    }

    /// Record "these videos are NOT this tag".
    ///
    /// The negative half of training, reachable for any tag in the library
    /// rather than only for tags the engine happened to suggest.
    ///
    /// Where the tag is currently ON the video, this takes it off first. The
    /// ✕ means the same thing everywhere — "no, not this" — and on a chip the
    /// user had ticked, that has to include undoing the tick, or the ✕ would
    /// silently do nothing (see below for why it must not simply record the
    /// rejection alongside the tag).
    ///
    /// A video that still CARRIES the tag afterwards is skipped. Rejecting a
    /// tag on a video the user tagged with it is a contradiction, and the
    /// training builder applies negatives after positives — so one such
    /// rejection silently erased its own positive. Rejecting a whole tag
    /// playlist that way wiped every positive the tag had (the "I rejected 33
    /// and nothing recorded" bug: 33 rejections, 17 of them on the tag's own
    /// videos, 0 positives left to train on).
    private func reject(_ name: String) {
        // Who actually carried it, decided before anything changes — this is
        // both the list to take the tag off and the record ↺ needs to put it
        // back.
        let carriers = targets.filter { path in
            library.tagsFor(path).contains {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        if !carriers.isEmpty {
            library.removeTag(name, from: carriers)
            rejectionTookOff[name.lowercased()] = carriers
            playback.refreshMembership()
        }
        for path in targets {
            suggestions.decide(path, tag: name, verdict: .rejected)
        }
    }

    private func undoReject(_ name: String) {
        for path in targets { suggestions.undecide(path, tag: name) }
        // ...and put back whatever the ✕ took off. Only the paths this tag's
        // own rejection removed, so undoing one tag never re-adds another's.
        if let takenOff = rejectionTookOff.removeValue(forKey: name.lowercased()) {
            library.addTag(name, to: takenOff)
            playback.refreshMembership()
        }
    }

    /// One suggested tag.
    ///
    /// Same rule as every other chip here: the body is the yes, the trailing ✕
    /// is the no, ⌥click on the body is the same as the ✕. This one used to
    /// offer only ⌥click, so the "no" was invisible — and the no is the half
    /// of training that is always in short supply.
    ///
    /// Both are recorded as training signal, which is the whole point — the
    /// machine is meant to get better at THIS library, and it can only do that
    /// from decisions the user actually made.
    ///
    /// Dashed border and the sparkle keep it unmistakable from a real tag: a
    /// guess must never look like something the user vouched for.
    private func suggestionChip(_ s: TagSuggestion, path: String) -> some View {
        HStack(spacing: 3) {
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    suggestions.decide(path, tag: s.tag, verdict: .rejected)
                } else {
                    accept(s.tag, on: path)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: s.source == "face" ? "person.crop.circle.badge.checkmark"
                            : (s.source == "trained"
                                ? "checkmark.seal"
                                : (s.source == "library" ? "books.vertical.fill" : "sparkles")))
                        .font(.caption2)
                    Text(s.tag).font(.caption)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(.secondary)
                )
            }
            .buttonStyle(.plain)
            .help(chipEvidence(s, path: path)
                  + " Click to add; the ✕ says it is NOT.")

            // WHEN the app saw it, from the pass's own record rather than
            // recomputed here: a time on screen has to be a time the app
            // actually went to. Each is its own control, not part of the chip's
            // button — a time inside that button would add the tag when the user
            // only meant to look.
            sightingControls(s, path: path)

            Button {
                suggestions.decide(path, tag: s.tag, verdict: .rejected)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hoveredTag == s.tag ? Color.red : Color.secondary)
                    .opacity(hoveredTag == s.tag ? 1 : 0.55)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Not “\(s.tag)” — records a negative example for training")
            .accessibilityLabel("Not \(s.tag)")

            // The ⓘ is ALWAYS drawn, only its emphasis changes: a control that
            // appears on hover reflows the chip flow and the click lands on
            // whatever moved underneath it (that bug cost a round already).
            Button {
                askWhy(s, path: path)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(hoveredTag == s.tag ? Color.accentColor : Color.secondary)
                    .opacity(hoveredTag == s.tag ? 1 : 0.4)
                    .frame(width: 20, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Why was “\(s.tag)” suggested?")
            .accessibilityLabel("Why \(s.tag)")
            .popover(isPresented: Binding(
                get: { whyTag == s.tag },
                set: { if !$0 { whyTag = nil } }), arrowEdge: .bottom) {
                whyBody(s)
            }
        }
        .onHover { inside in
            hoveredTag = inside ? s.tag : (hoveredTag == s.tag ? nil : hoveredTag)
        }
        .animation(.easeOut(duration: 0.12), value: hoveredTag)
        .contextMenu {
            Button("Why was “\(s.tag)” suggested?") { askWhy(s, path: path) }
            Divider()
            Button("Add \(s.tag)") { accept(s.tag, on: path) }
            Button("Not \(s.tag)") {
                suggestions.decide(path, tag: s.tag, verdict: .rejected)
            }
        }
    }

    /// Ask the engine why this tag was suggested, then show what it says.
    ///
    /// The lookup happens BEFORE the popover opens, so the panel opens straight
    /// into either the evidence or a plain "still working" line — never an empty
    /// box. AppModel is read here, at the call site, rather than inside the
    /// popover: a popover is a fresh hosting context and inherits nothing
    /// (the sheet/popover environment trap that has bitten this codebase).
    private func askWhy(_ s: TagSuggestion, path: String) {
        whyTag = s.tag
        whyValue = nil
        whyLoading = true
        whyInCoreML = CoreMLClassifier.mode == .coreml
        Task {
            let found = await app.engine.explainSuggestion(
                tag: s.tag, source: s.source ?? "zeroshot", path: path)
            // Ignore a late answer for a chip the user has already closed.
            guard whyTag == s.tag else { return }
            whyValue = found
            whyLoading = false
        }
    }

    /// What the ⓘ shows. Plain values only — nothing here reaches the
    /// environment, so it renders identically wherever the popover is anchored.
    @ViewBuilder
    private func whyBody(_ s: TagSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: sourceGlyph(s.source ?? "zeroshot")).font(.caption)
                Text(s.tag).font(.headline)
                Text(sourceName(s.source ?? "zeroshot"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if whyLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Recomputing from the cached frames…").font(.caption)
                }
            } else if let w = whyValue {
                Text(w.headline).font(.caption).fixedSize(horizontal: false, vertical: true)

                if let phrase = w.winningPhrase {
                    labelled("Closest phrase", "“\(phrase)”")
                }
                if let pool = w.poolPhrase {
                    labelled("Beat", "“\(pool)”")
                }
                if w.source == "zeroshot" {
                    labelled("Margin", String(format: "%.4f", w.confidence)
                             + String(format: "  (bar %.2f)", w.bar))
                }
                if !w.learnedFrom.isEmpty {
                    labelled("Learned from", w.learnedFrom
                        .map { ($0 as NSString).lastPathComponent }
                        .prefix(4).joined(separator: ", "))
                }
                if let n = w.headAgreed {
                    labelled("Head agreed", "\(n) of \(w.framesSeen) frames")
                }

                if !w.hits.isEmpty {
                    Divider()
                    Text("Frames that agreed — strongest first").font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(w.hits.prefix(4), id: \.hash) { hit in
                        HStack(spacing: 6) {
                            Text(Self.clock(hit.at)).font(.caption2)
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(String(format: "%+.4f", hit.margin)).font(.caption2)
                        }
                    }
                    // The strongest few are the BEST of the evidence, not all of
                    // it, and showing only them makes a chip look far stronger
                    // than it is. On the clip that prompted this, the top three
                    // frames ran +0.0508 / +0.0419 / +0.0388 while the median of
                    // the 59 that agreed was +0.0277 — so how far the rest fell
                    // is the number that answers the question being asked.
                    if w.hits.count > 4 {
                        labelled("The rest",
                                 "\(w.hits.count - 4) more, down to "
                                 + String(format: "%+.4f", w.hits.last?.margin ?? 0)
                                 + "  (median "
                                 + String(format: "%+.4f", w.hits[w.hits.count / 2].margin)
                                 + ")")
                    }
                }
            } else {
                Text(whyInCoreML
                     ? "No cached frames for this video yet — run Classify on it first."
                     : "The Python engine cannot explain a suggestion yet; switch to the Core ML engine to see the evidence.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    /// A label above its value, so a long phrase wraps instead of truncating.
    @ViewBuilder
    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What a chip's hover text says the number means.
    ///
    /// NOT "how many frames contained this". Every source counts something
    /// different, and for a zero-shot chip the number is how many frames sat at
    /// least SUGGEST_MARGIN (0.02) closer to this tag's wording than to the
    /// blandest phrase in the table — a bar that water, sky, a deck, a corridor
    /// and a wide shot all clear. "Seen in N frames" made a phrasing guess read
    /// as a detection, which is exactly how it reads when the thing is not in
    /// the video at all.
    private func chipEvidence(_ s: TagSuggestion, path: String) -> String {
        let seen = suggestions.entry(path)?.framesSeen
        let of = seen.map { " of \($0)" } ?? ""
        switch s.source ?? "zeroshot" {
        case "library":
            return "“\(s.tag)” — your own videos: \(s.frames)\(of) frames look like videos "
                 + "you tagged “\(s.tag)”"
        case "trained":
            return "“\(s.tag)” — your trained head fired on \(s.frames)\(of) frames"
        case "face":
            return "“\(s.tag)” — a face you named appears in this video"
        default:
            return "“\(s.tag)” — a phrasing guess, not a detection: \(s.frames)\(of) frames "
                 + "scored closer to this tag's wording than to any ordinary scene (bar 0.02)"
        }
    }

    private func sourceGlyph(_ source: String) -> String {
        switch source {
        case "face": return "person.crop.circle.badge.checkmark"
        case "trained": return "checkmark.seal"
        case "library": return "books.vertical.fill"
        default: return "sparkles"
        }
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "face": return "a person you named"
        case "trained": return "your trained head"
        case "library": return "your own tags"
        default: return "the phrase list"
        }
    }

    /// m:ss — or h:mm:ss once there is an hour to show — for a frame's position
    /// in the video.
    ///
    /// Rounded rather than truncated because it names a frame, not a duration:
    /// a frame at 12.4s is nearer 0:12 than 0:00.9. Hours are shown because a
    /// two-hour video would otherwise read as "125:30" beside a transport bar
    /// saying 2:05:30 — the same clock, saying two different things.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (hours, rest) = total.quotientAndRemainder(dividingBy: 3600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// When the app saw this tag, as controls: each time seeks there, and a
    /// claim about a file that has since changed says so instead.
    ///
    /// Shown from the pass's own record — the evidence store — rather than
    /// recomputed. A library or face chip has no per-frame times of its own and
    /// therefore shows none: an invented time would be worse than a missing one,
    /// because the user would go there and not find what the chip implied.
    @ViewBuilder
    private func sightingControls(_ s: TagSuggestion, path: String) -> some View {
        let spans = journal.spans(for: path, label: s.tag)
        if spans.isEmpty {
            EmptyView()
        } else if spans.contains(where: { $0.isStale }) {
            // The times describe bytes that no longer exist. Offering them would
            // seek to a moment in a file the app never looked at, so the chip
            // offers the one useful thing instead: look again, now.
            Button {
                NotificationCenter.default.post(name: AppModel.suggestTagsNotification,
                                               object: path)
            } label: {
                Label("changed", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("This video's file has changed since the app looked at it, so the times it found then no longer point at anything. Click to look at the file as it is now.")
        } else {
            let shown = spans.prefix(3)
            HStack(spacing: 4) {
                ForEach(Array(shown)) { span in
                    Button {
                        playback.seek(to: span.start)
                    } label: {
                        Text(Self.clock(span.start))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help("Where the app saw “\(s.tag)” — click to jump there")
                }
                if spans.count > shown.count {
                    Text("+\(spans.count - shown.count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help("\(spans.count) separate moments in this video")
                }
            }
        }
    }

    /// Accept a suggestion: it becomes a real tag, and the decision is kept.
    private func accept(_ tag: String, on path: String) {
        var have = library.tagsFor(path)
        if !have.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            have.append(tag)
            library.setTags(have, for: path)
            library.saveTags()
        }
        suggestions.decide(path, tag: tag, verdict: .accepted)
        playback.refreshMembership()
    }

    private func commit() {
        let names = parseTags(typed)
        guard !names.isEmpty else { return }
        for path in targets {
            var have = library.tagsFor(path)
            for name in names where !have.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                have.append(name)
            }
            library.setTags(have, for: path)
        }
        library.saveTags()
        // A filter can name a tag, so the rows may no longer be the right ones.
        playback.refreshMembership()
        typed = ""
    }

    // MARK: - People

    /// Named people offered for THIS video, alphabetical. A person is offered
    /// when the engine suggests them for the video in view — by face match
    /// (source "face") or by CLIP appearance (source "library", the reliable
    /// signal for people with many tagged videos) — or when the video is
    /// already tagged with them (their chip is then a remove). A named person
    /// who is not in the video is not shown; a rejected suggestion is dropped.
    private var people: [FacePerson] {
        faceStore.people
            .filter { person in
                let appliedHere = applied.contains(where: {
                    $0.caseInsensitiveCompare(person.name) == .orderedSame
                })
                return appliedHere || suggested(person.name)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Is this person suggested for the video in view, and not rejected?
    /// Suggestions arrive when the video plays: a face match (source "face")
    /// or a CLIP appearance match (source "library").
    private func suggested(_ name: String) -> Bool {
        guard targets.count == 1, let path = targets.first,
              let entry = suggestions.entry(path) else { return false }
        return entry.suggestions.contains { s in
            s.tag.caseInsensitiveCompare(name) == .orderedSame
            && entry.verdicts[s.tag] != .rejected
        }
    }

    /// Tag every target with a person's name — the classify semantic. An add
    /// appends the name like `accept(_:on:)` does, across the whole selection
    /// like `commit()` does; an applied chip (every target already carries the
    /// name) removes it instead, mirroring the tag chips.
    private func togglePerson(_ name: String) {
        if applied.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            library.removeTag(name, from: targets)
        } else {
            for path in targets {
                var have = library.tagsFor(path)
                if !have.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    have.append(name)
                    library.setTags(have, for: path)
                }
            }
            library.saveTags()
        }
        playback.refreshMembership()
    }

    /// One named person as a chip: their face and name, styled exactly like a
    /// tag chip, and obeying the same rule — the chip body is the yes, the
    /// trailing ✕ is the no, and ⌥click on the body is the same as the ✕.
    ///
    /// An applied chip wears a checkmark, not an xmark: the xmark is reserved
    /// for "no, not this person", which also takes the name off if it is on.
    @ViewBuilder
    private func personChip(_ person: FacePerson, applied: Bool) -> some View {
        HStack(spacing: 4) {
            if applied {
                Button {
                    togglePerson(person.name)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.caption2)
                        personThumb(person.representative, size: 28)
                        Text(person.name).font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("\(person.name) is in this video — click to take the name off")
            } else {
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        rejectPerson(person.name)
                    } else {
                        togglePerson(person.name)
                    }
                } label: {
                    HStack(spacing: 4) {
                        personThumb(person.representative, size: 28)
                        Text(person.name).font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Click to say \(person.name) is in this video; the ✕ says they are not")
            }

            // Always drawn, only faded when the cursor is elsewhere — same as
            // the tag chips. It used to appear on hover, which changed the
            // chip's width and slid the row out from under the cursor.
            Button {
                rejectPerson(person.name)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hoveredPerson == person.name ? Color.red : Color.secondary)
                    .opacity(hoveredPerson == person.name ? 1 : 0.35)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(applied
                  ? "Wrong — takes \(person.name) off and records it as not them"
                  : "No — \(person.name) is not in this video")
        }
        .onHover { inside in
            hoveredPerson = inside ? person.name : (hoveredPerson == person.name ? nil : hoveredPerson)
        }
        .animation(.easeOut(duration: 0.12), value: hoveredPerson)
        .contextMenu {
            Button(applied ? "Take \(person.name) off" : "Add \(person.name)") {
                togglePerson(person.name)
            }
            Button("Not \(person.name)") { rejectPerson(person.name) }
        }
    }

    /// Reject a person on the video in view: "this video does NOT show them".
    ///
    /// Takes the name off first if it is on, so the ✕ means the same thing on
    /// an applied chip as on an offered one. Recorded exactly like a rejected
    /// suggestion — a negative example for that name, so training and the face
    /// matcher stop offering it here.
    private func rejectPerson(_ name: String) {
        guard targets.count == 1, let path = targets.first else { return }
        let has = library.tagsFor(path).contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
        if has { togglePerson(name) }
        suggestions.decide(path, tag: name, verdict: .rejected)
    }

    /// One unnamed identity cluster: its face, the videos it appears in, and a
    /// A face crop as a small round thumbnail; the plain person symbol when
    /// the engine never saved a representative image. Same crop as the People
    /// window's, at the size each row wants.
    @ViewBuilder
    private func personThumb(_ hash: String?, size: CGFloat) -> some View {
        Group {
            if let hash, let image = FaceStore.thumbnail(hash) {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Chips wrap into rows at the width they are offered, spilling to a new row
/// when the next chip will not fit — never a squeezed single line. The same
/// idea as the tvOS ChipShelf: children are measured at their natural size
/// and the proposed width decides where each row breaks.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        measure(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = measure(subviews, width: bounds.width).rows
        for row in rows {
            for (index, frame) in row {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + frame.minX,
                                y: bounds.minY + frame.minY),
                    proposal: .unspecified)
            }
        }
    }

    /// One row-math pass answers both questions, so the reported size and the
    /// placements cannot disagree. Children keep their natural size; a row
    /// starts a new line only when the next chip would cross the offered
    /// width (a lone chip always fits, even when it is wider than the row).
    private func measure(_ subviews: Subviews, width: CGFloat?)
        -> (size: CGSize, rows: [[(Int, CGRect)]]) {
        let available = width ?? .infinity
        var rows: [[(Int, CGRect)]] = [[]]
        var cursor: CGFloat = 0      // where the next chip starts on this row
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap = cursor == 0 ? 0 : spacing
            if cursor > 0, cursor + gap + size.width > available {
                // This row is done; the widest row so far decides the width
                // when nobody offered one.
                widestRow = max(widestRow, cursor)
                totalHeight += rowHeight + (rows.isEmpty ? 0 : spacing)
                rows.append([])
                cursor = 0
                rowHeight = 0
            }
            let gapNow = cursor == 0 ? 0 : spacing
            rows[rows.count - 1].append(
                (index, CGRect(x: cursor + gapNow, y: totalHeight,
                               width: size.width, height: size.height)))
            cursor += gapNow + size.width
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, cursor)
        totalHeight += rowHeight
        return (CGSize(width: min(widestRow, available), height: totalHeight), rows)
    }
}

