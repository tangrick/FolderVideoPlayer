import SwiftUI

/// The "Tag from Metadata…" flow: scan the folder the user picked (subfolders
/// optional), show what its videos would earn — rule by rule, with counts —
/// and apply the ticked rules as one undoable edit. Nothing is written until
/// Apply; the scan only reads.
struct AutoTagSheet: View {
    let root: String
    var onClose: () -> Void

    @EnvironmentObject var library: Library
    @StateObject private var tagger = MetadataTagger()
    @State private var includeSubfolders = false
    /// Which rule's tag names are being listed, if any.
    @State private var showingNames: MetadataTagger.Rule?
    /// Folder and date rules to begin with: they cost one stat a video. The
    /// metadata rules are ticked by the user, which is what asks for the
    /// pass that opens every file.
    @State private var enabled: Set<MetadataTagger.Rule> = MetadataTagger.Rule.defaultOn

    private var name: String { (root as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch tagger.phase {
            case .idle:
                ProgressView().frame(maxWidth: .infinity)
            case .walking(let found):
                ProgressView()
                Text(found == 0 ? "Finding videos…" : "Found \(found) videos…")
                    .font(.callout).foregroundStyle(.secondary)
            case .dating(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Checking \(done) of \(total) videos…")
                    .font(.callout).foregroundStyle(.secondary)
            case .reading(let done, let total):
                // The plan stays on screen while the metadata pass runs: the
                // folder and date rules are already decided, and hiding them
                // behind a bar for minutes is what made this feel stuck.
                if let plan = tagger.plan { planView(plan) }
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack(spacing: 6) {
                    Text("Reading metadata \(done) of \(total)…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { tagger.cancel() }
                        .controlSize(.mini)
                }
            case .failed(let why):
                Text("Could not scan: \(why)").foregroundStyle(.red)
            case .done:
                if let result = tagger.result { applied(result) }
                else if let plan = tagger.plan { planView(plan) }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 480, height: 470)
        .task(id: "\(root)|\(includeSubfolders)") {
            // Hidden videos are not part of the app's library, so the scan
            // does not read them or propose tags for them.
            tagger.run(root: root, includeSubfolders: includeSubfolders,
                       hidden: library.hidden)
        }
        .onDisappear { tagger.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tag from Metadata")
                .font(.headline)
            Text("“\(name)” — tags are worked out and merged in; nothing is "
                 + "overwritten, and ⌘Z undoes the whole batch.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include subfolders", isOn: $includeSubfolders)
                .font(.callout)
                .disabled(tagger.result != nil)
        }
    }

    @ViewBuilder
    private func planView(_ plan: MetadataTagger.Plan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plan.videos == 0 ? "No videos here."
                                  : "\(plan.videos) videos — pick the tags you want:")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(MetadataTagger.Rule.displayOrder) { rule in
                        // A rule with hits is offered with its count. The
                        // metadata rules are offered before their pass has
                        // run too — ticking one is how you ask for it — but
                        // a rule that was read and found nothing stays hidden.
                        let hits = plan.hits[rule, default: 0]
                        let unread = rule.needsDetails && !plan.readDetails
                        if hits > 0 || unread {
                            ruleRow(rule, plan: plan, hits: hits, unread: unread)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One rule, with how many videos it covers and — the number that
    /// decides whether you want it — how many distinct tag names it would
    /// create. A rule that would mint dozens says so in orange, and its
    /// names can be listed before you commit to them.
    @ViewBuilder
    private func ruleRow(_ rule: MetadataTagger.Rule, plan: MetadataTagger.Plan,
                         hits: Int, unread: Bool) -> some View {
        let made = plan.distinct[rule, default: 0]
        let heavy = made > 25
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: binding(for: rule)) {
                HStack(spacing: 6) {
                    Text(rule.title)
                    if !unread && made > 0 {
                        Text("\(made) tag\(made == 1 ? "" : "s")")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(heavy ? Color.orange.opacity(0.22)
                                              : Color.secondary.opacity(0.16),
                                        in: .capsule)
                            .foregroundStyle(heavy ? .orange : .secondary)
                    }
                }
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text(unread ? "reads every file — tick to check"
                            : "\(rule.detail) · \(hits) videos")
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !unread, let names = plan.names[rule], !names.isEmpty {
                    Button(showingNames == rule ? "hide" : "show") {
                        showingNames = showingNames == rule ? nil : rule
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            if showingNames == rule, let names = plan.names[rule] {
                Text(names.prefix(40).joined(separator: " · ")
                     + (names.count > 40 ? " … +\(names.count - 40) more" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.trailing, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func applied(_ result: (files: Int, tags: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Added \(result.tags) tags to \(result.files) videos",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Undo removes every tag this batch added.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(for rule: MetadataTagger.Rule) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(rule) },
            set: { on in
                if on { enabled.insert(rule) } else { enabled.remove(rule) }
                tagger.enabled = enabled
                // Ticking is free. It used to be the request to go and read
                // every file, so choosing three rules meant sitting through a
                // pass after the first tick and the box you wanted to tick
                // next was behind a progress bar (reported 2026-09-17). The
                // reading now happens once, when Apply is pressed.
            }
        )
    }

    /// Apply: read the files first if any ticked rule needs them, then tag.
    ///
    /// The read is the expensive half — it opens every video — so it is paid
    /// once, here, for whatever the user actually ticked, rather than on each
    /// tick. `readDetails` returns early when the pass has already run, so a
    /// plan that is already complete applies immediately.
    private func applyNow() async {
        if enabled.contains(where: \.needsDetails), tagger.plan?.readDetails == false {
            await tagger.readDetails()
            // Cancelled mid-read, or the read failed: the plan cannot be
            // trusted to describe the files, so nothing is written.
            guard tagger.plan?.readDetails == true else { return }
        }
        tagger.apply(enabled: enabled, library: library)
    }

    /// Says what the press will actually do. A rule that needs the file's own
    /// metadata means Apply reads every video first, which can take minutes —
    /// worth saying on the button rather than discovering it afterwards.
    private var applyTitle: String {
        enabled.contains(where: \.needsDetails) && tagger.plan?.readDetails == false
            ? "Read Files & Apply"
            : "Apply"
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if tagger.result != nil {
                // The header above promises ⌘Z undoes the batch, so the key
                // has to actually do it. Scoped to this sheet rather than
                // replacing the Edit menu's Undo, so ⌘Z in a text field stays
                // the text field's.
                Button("Undo") {
                    library.undoTagChange()
                    tagger.result = nil
                }
                .keyboardShortcut("z")
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel") { onClose() }
                Button(applyTitle) { Task { await applyNow() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(tagger.isBusy || tagger.plan == nil
                              || tagger.plan?.videos == 0 || enabled.isEmpty)
            }
        }
    }
}
