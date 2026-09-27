import SwiftUI

/// Making or changing a smart collection: a name, whether all or any of the
/// rules must hold, and the rules — with a live count of what matches, and a
/// sentence under any rule that cannot be answered as meant.
struct SmartCollectionEditor: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var smart: SmartCollectionStore
    @EnvironmentObject private var faceStore: FaceStore
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var draft = SmartCollection(name: "")
    @State private var isNew = true
    @State private var matches: Int?
    @State private var confirmDelete = false

    private var problems: [UUID: String] { smart.problems(in: draft) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)
                Picker("Show videos matching", selection: $draft.match) {
                    Text("all of these rules").tag(SmartCollection.Match.all)
                    Text("any of these rules").tag(SmartCollection.Match.any)
                }
                Section("Rules") {
                    if draft.rules.isEmpty {
                        Text("Add a rule to say which videos belong here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($draft.rules) { $rule in
                        RuleRow(rule: $rule, problem: problems[rule.id],
                                tags: library.handTaggableTags(),
                                people: faceStore.people.map(\.name).sorted(),
                                facts: library.factsByKind()) {
                            draft.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    Menu("Add Rule") {
                        ForEach(SmartRule.Kind.allCases) { kind in
                            Button(kind.title) { draft.rules.append(.fresh(kind)) }
                        }
                    }
                    .fixedSize()
                }
                Section {
                    Text("Smart collections look at every video this profile knows — tagged, rated, played, analysed or transcribed. Hidden videos are never included while the hidden list is locked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let matches {
                    Text("\(matches) video\(matches == 1 ? "" : "s") match right now")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Button("Cancel") { dismissWindow(id: "smart-collection") }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: load)
        .onChange(of: app.smartEditTarget) { _, _ in load() }
        .onChange(of: app.smartEditSeed) { _, _ in load() }
        .task(id: draft) {
            // A live count, a moment after the last change.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            matches = await smart.evaluate([draft])?[draft.id]?.count
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete Smart Collection", role: .destructive) {
                smart.delete(draft.id)
                app.playback?.collectionChanged(draft.id, name: nil)
                dismissWindow(id: "smart-collection")
            }
        } message: {
            Text("Only the collection is deleted. Its videos, their tags and files are untouched.")
        }
    }

    private func load() {
        matches = nil
        if let id = app.smartEditTarget, let existing = smart.collection(id) {
            draft = existing
            isNew = false
        } else {
            var seed = app.smartEditSeed ?? SmartCollection(name: "")
            if seed.name.isEmpty { seed.name = smart.uniqueName("Smart Collection") }
            draft = seed
            isNew = true
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if isNew || smart.collection(draft.id)?.name.caseInsensitiveCompare(draft.name) != .orderedSame {
            // Two collections with one name would be two rows nobody can tell apart.
            if smart.collections.contains(where: { $0.id != draft.id && $0.name.caseInsensitiveCompare(draft.name) == .orderedSame }) {
                draft.name = smart.uniqueName(draft.name)
            }
        }
        smart.save(draft)
        app.playback?.collectionChanged(draft.id, name: draft.name)
        app.smartEditSeed = nil
        dismissWindow(id: "smart-collection")
    }
}

/// One rule: what it is about, how it compares, the value, and what is wrong
/// with it if anything is.
private struct RuleRow: View {
    @Binding var rule: SmartRule
    let problem: String?
    let tags: [String]
    let people: [String]
    /// The file facts in the library, grouped the way the sidebar groups them.
    let facts: [(kind: String, names: [String])]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Kind", selection: Binding(
                    get: { rule.kind ?? .tag },
                    set: { kind in
                        let id = rule.id
                        rule = .fresh(kind)
                        rule.id = id
                    })) {
                    ForEach(SmartRule.Kind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(rule.kind == nil)
                if let kind = rule.kind {
                    Picker("Comparison", selection: $rule.op) {
                        ForEach(SmartRule.ops(for: kind)) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    value(for: kind)
                } else {
                    Text("“\(rule.type)” — not understood by this version")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                    .accessibilityLabel("Remove rule")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func value(for kind: SmartRule.Kind) -> some View {
        switch kind {
        case .tag, .person:
            let names = kind == .tag ? tags : people
            HStack(spacing: 4) {
                TextField(kind == .tag ? "Tag" : "Person", text: $rule.text)
                    .frame(minWidth: 120)
                Menu {
                    ForEach(names, id: \.self) { name in Button(name) { rule.text = name } }
                } label: { Image(systemName: "list.bullet") }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(names.isEmpty)
                .help(kind == .tag ? "Choose a tag" : "Choose a person")
            }
        case .fact:
            HStack(spacing: 4) {
                TextField("Date, camera, quality or place", text: $rule.text)
                    .frame(minWidth: 140)
                Menu {
                    ForEach(facts, id: \.kind) { group in
                        Section(group.kind) {
                            ForEach(group.names, id: \.self) { name in Button(name) { rule.text = name } }
                        }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(facts.isEmpty)
                .help(facts.isEmpty ? "No facts have been read from the files yet" : "Choose a file fact")
            }
        case .rating:
            Picker("Stars", selection: $rule.stars) {
                Text("Unrated").tag(0)
                ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
        case .recorded, .added:
            DatePicker("Date", selection: dateBinding(\.from), displayedComponents: .date)
                .labelsHidden()
            if rule.comparison == .between {
                Text("and")
                DatePicker("End date", selection: dateBinding(\.to), displayedComponents: .date)
                    .labelsHidden()
            }
        case .transcript:
            TextField("Words said", text: $rule.text)
                .frame(minWidth: 140)
        case .playback, .analysis, .verdict, .file:
            Picker("Value", selection: $rule.text) {
                ForEach(SmartRule.values(for: kind), id: \.raw) { Text($0.title).tag($0.raw) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func dateBinding(_ field: WritableKeyPath<SmartRule, Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: rule[keyPath: field]) },
                set: { rule[keyPath: field] = $0.timeIntervalSince1970 })
    }
}
