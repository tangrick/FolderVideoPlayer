import SwiftUI
import UniformTypeIdentifiers

/// People: who the face engine recognises.
///
/// The flow is face-first, never tag-first: the user adds a person by pointing
/// at a video or photo, the engine detects the biggest faces, the user picks
/// one and names it, and the engine scans the library and tags every video
/// that face appears in. There is no unnamed-cluster dump — the user only ever
/// sees people they added themselves.
struct PeopleWindow: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var faceStore: FaceStore
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    @State private var showingAdd = false
    /// The person the user asked to remove — drives the confirmation.
    @State private var removing: FacePerson?
    /// A problem worth reporting from the last photo pick (no face / bad file).
    @State private var photoProblem: String?
    /// Which row the cursor is over — drives the camera hint on the avatar.
    @State private var hoveringRow: String?
    /// Person whose photo source dialog is open.
    @State private var photoPickerFor: String?
    /// Person whose system-faces picker sheet is open.
    @State private var facePickerName: String?

    /// Shown in place of everything when face recognition is switched off.
    private var offMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Face Recognition is off")
                .font(.headline)
            Text("The app is not looking for faces in your videos. "
                 + "People you have already named are kept, and their tags still work.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Turn Face Recognition On") { library.facesEnabled = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var people: [FacePerson] {
        faceStore.people.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.facesEnabled {
                header
                Divider()
                content
            } else {
                // The window can still be reached — by a lingering menu, or
                // because it was already open when the switch was thrown. It
                // says why it is empty rather than showing stale people and
                // buttons that would do nothing.
                offMessage
            }
        }
        .frame(minWidth: 460, minHeight: 400, maxHeight: .infinity, alignment: .top)
        .task {
            if faceStore.people.isEmpty && library.facesEnabled {
                await faceStore.reload()
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddPersonSheet()
        }
        .confirmationDialog(
            removing.map { "Remove “\($0.name)”?" } ?? "Remove this person?",
            isPresented: Binding(get: { removing != nil },
                                 set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            if let person = removing {
                let tagged = library.count(of: person.name)
                Button("Remove Person, Keep Tag", role: .destructive) {
                    let name = person.name
                    removing = nil
                    Task { await faceStore.forgetPerson(name, alsoRemoveTag: false) }
                }
                Button("Remove Person and Tag (\(tagged) video\(tagged == 1 ? "" : "s"))",
                       role: .destructive) {
                    let name = person.name
                    removing = nil
                    Task { await faceStore.forgetPerson(name, alsoRemoveTag: true) }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            }
        } message: {
            Text("The app will stop recognising this face and stop suggesting the name. "
                 + "The face pictures stay, so you can name that face again later.")
        }
        .alert("Could not change the photo",
               isPresented: Binding(get: { photoProblem != nil },
                                    set: { if !$0 { photoProblem = nil } })) {
            Button("OK") { photoProblem = nil }
        } message: {
            Text(photoProblem ?? "")
        }
        .confirmationDialog(
            photoPickerFor.map { "Picture for “\($0)”" } ?? "Picture",
            isPresented: Binding(get: { photoPickerFor != nil },
                                 set: { if !$0 { photoPickerFor = nil } }),
            titleVisibility: .visible
        ) {
            if let name = photoPickerFor {
                Button("Choose from faces the system has seen") {
                    facePickerName = name
                    photoPickerFor = nil
                }
                Button("Choose from a photo file…") {
                    pickPhoto(for: name)
                    photoPickerFor = nil
                }
                Button("Cancel", role: .cancel) { photoPickerFor = nil }
            }
        } message: {
            Text("Faces the app has seen that look like this person, or a picture from your own files.")
        }
        .sheet(isPresented: Binding(get: { facePickerName != nil },
                                   set: { if !$0 { facePickerName = nil } })) {
            if let name = facePickerName {
                FacePickerSheet(personName: name)
            }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text("People").font(.headline)
            if faceStore.loading {
                ProgressView().controlSize(.small)
            }
            if faceStore.indexing && !faceStore.indexProgress.isEmpty {
                Text(faceStore.indexProgress)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if faceStore.indexing {
                Button {
                    faceStore.cancelIndex()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .help("Stop the scan at the next video")
            } else {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Person", systemImage: "person.badge.plus")
                }
                .disabled(faceStore.loading)
                .help("Add a person from a video or photo — the app finds them everywhere")
            }
            Button {
                Task { await faceStore.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(faceStore.loading || faceStore.indexing)
            .help("Re-read the engine's people")
            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close the People window")
        }
        .padding(10)
    }

    // MARK: - body

    @ViewBuilder
    private var content: some View {
        if faceStore.loading && faceStore.people.isEmpty {
            Spacer()
            ProgressView("Reading people…")
                .controlSize(.small)
            Spacer()
        } else if people.isEmpty {
            ContentUnavailableView(
                "No people yet",
                systemImage: "person.2",
                description: Text("Add a person from a video or photo. The app finds every "
                                  + "video that face appears in and tags it, so you can "
                                  + "filter, sort and group by person like any other tag."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(people, id: \.name) { person in
                        personRow(person)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func personRow(_ person: FacePerson) -> some View {
        let videos = library.count(of: person.name)
        return HStack(spacing: 8) {
            // The avatar is a button: click it to choose a picture for this
            // person — either a face the system already saw, or a file.
            Button {
                photoPickerFor = person.name
            } label: {
                faceImage(person.representative)
                    .overlay(alignment: .bottomTrailing) {
                        if hoveringRow == person.name {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 2, y: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hoveringRow = inside ? person.name : (hoveringRow == person.name ? nil : hoveringRow)
            }
            .help("Choose a picture to use for \(person.name)")

            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                Text("\(videos) video\(videos == 1 ? "" : "s") · \(person.faces) face\(person.faces == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.renamePerson(person)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename \(person.name)")
            Button {
                photoPickerFor = person.name
            } label: {
                Image(systemName: "camera")
            }
            .buttonStyle(.borderless)
            .help("Choose a picture to use for \(person.name)")
            Button {
                removing = person
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(person.name) from the app's people")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contextMenu {
            Button("Rename \(person.name)…") { app.renamePerson(person) }
            Button("Choose from Faces Seen…") { facePickerName = person.name }
            Button("Choose from Photo File…") { pickPhoto(for: person.name) }
            Button("Remove \(person.name)…", role: .destructive) { removing = person }
        }
    }

    /// Pick an image file and use its face as this person's thumbnail. The
    /// engine crops the biggest face out of the picture; a picture with no
    /// face is reported, never silently ignored.
    private func pickPhoto(for name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await faceStore.setPhoto(name, path: url.path) {
            case .success:
                break // the row visibly updates to the new face
            case .noFace:
                photoProblem = "No face found in that picture — \(name)'s thumbnail was not changed."
            case .failed:
                photoProblem = "Could not use that picture. Choose a jpg, png or other image file."
            }
        }
    }

    // MARK: - the face thumbnails

    @ViewBuilder
    private func faceImage(_ hash: String?) -> some View {
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
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }
}

/// A grid of faces the system has already seen that look most like a person.
/// Picking one makes it that person's representative thumbnail immediately.
/// The engine ranks the whole cached face library by similarity to the
/// person's stored vectors, so every angle and lighting of them across their
/// videos is right here — best match first.
struct FacePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var faceStore: FaceStore

    let personName: String

    @State private var faces: [String] = []
    @State private var loading = true
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a face for \(personName)").font(.headline)
                    Text("Faces the app has seen that look most like \(personName) — best match first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching faces the app has seen…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
            } else if faces.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No similar faces found yet.")
                        .font(.caption.weight(.semibold))
                    Text("The app has not seen \(personName) clearly enough to rank faces. "
                         + "Choose a photo file instead, and the faces will build up as videos are played.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { dismiss() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                              spacing: 10) {
                        ForEach(faces, id: \.self) { hash in
                            faceChoice(hash)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 360)
                Text("Click a face to use it. It also joins \(personName)'s recognition, "
                     + "so matching improves from that angle too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 560)
        .task {
            faces = await faceStore.similarFaces(personName)
            loading = false
        }
    }

    private func faceChoice(_ hash: String) -> some View {
        Button {
            applying = true
            Task {
                _ = await faceStore.setRepresentative(personName, hash: hash)
                applying = false
                dismiss()
            }
        } label: {
            Group {
                if let image = FaceStore.thumbnail(hash) {
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            .overlay {
                if applying {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Use this face for \(personName)")
    }
}

/// Name the faces in a video, one after another, until Done.
///
/// The engine finds the most prominent people in a source (a video or photo)
/// and the user says who each one is: pick a face, pick the person or type a
/// new name, and go on to the next. Every add is saved as it is made — the
/// sheet used to close after ONE face, and looked at the whole video again
/// each time it was reopened for the next. Now the video is looked at once
/// (`FaceStore.detectFaces` keeps what it found), a face that is already
/// someone says so, and a wrong one can be taken back where it was made.
///
/// When opened from the classify panel it is seeded with the current video, so
/// the faces already on screen are offered immediately — no file picker needed.
struct AddPersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var faceStore: FaceStore
    @EnvironmentObject var app: AppModel

    /// A video to detect from immediately, when opened from the classify panel
    /// while something is playing. Nil means start from the file picker.
    let initialVideo: String?

    @State private var sourcePath: String?
    @State private var faces: [String] = []
    /// Who each face is — bound to a person, or only looking like one — read
    /// again after every add and removal so the grid shows what was saved,
    /// not what the sheet hoped was saved.
    @State private var identities: [String: FaceIdentity] = [:]
    @State private var selectedFace: String?
    @State private var name = ""
    @State private var detecting = false
    @State private var scanStopped = false
    @State private var scanProblem: String?
    @State private var scanStage = "Opening file"
    @State private var scanCompleted = 0
    @State private var scanTotal = 0
    @State private var scanStarted = Date()
    @State private var stageStarted = Date()
    @State private var lastScanProgress = Date()
    /// An add or a removal is on its way to the registry. The buttons wait for
    /// it, so Return held down cannot add one face twice.
    @State private var working = false
    /// Bumped by Look Again: the same file, looked at afresh.
    @State private var lookAgain = 0
    /// Set when the user picked someone they already have, instead of typing a
    /// new name. The chosen face is then MERGED into that person.
    @State private var pickedExisting: String?
    /// A clear portrait photo for a NEW person, so their row shows a proper
    /// face instead of a blurry mid-video crop. Only applies to new people —
    /// matching to an existing person reuses that person's own photo.
    @State private var photoPath: String?
    /// The video each name was put on by an add made in this sitting, keyed by
    /// the folded name. Taking the last such face back takes the tag off again;
    /// a tag the video already carried is never this sheet's to remove.
    @State private var taggedHere: [String: String] = [:]
    @State private var problem: String?

    /// What the detection pass is for: a file, and how many times it has been
    /// asked to look again.
    private struct Pass: Equatable {
        var path: String?
        var again: Int
        var stopped: Bool
    }

    init(initialVideo: String? = nil) {
        self.initialVideo = initialVideo
        _sourcePath = State(initialValue: initialVideo)
    }

    /// The name the selected face is about to be given.
    private var target: String {
        (pickedExisting ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The person the selected face already belongs to, when it has one.
    private var selectedOwner: String? {
        guard let face = selectedFace, let who = identities[face], who.bound else { return nil }
        return who.name
    }

    /// Who the selected face looks like, when nobody has said.
    private var selectedGuess: String? {
        guard let face = selectedFace, let who = identities[face], !who.bound else { return nil }
        return who.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The way out is ALWAYS in the same corner, in every state —
            // including while detecting and when no faces were found. A
            // state without a close control is a dead end: the user asked
            // to leave, and there was nothing on screen that let them.
            HStack {
                Text("Add faces").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close — everything added so far is kept")
                .accessibilityLabel("Close")
            }
            Text("Pick a face, say who it is, and go on to the next. "
                 + "Each one is saved as you add it.")
                .font(.caption).foregroundStyle(.secondary)

            if let path = sourcePath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if detecting {
                scanProgressView
            } else if sourcePath == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick a video or photo that shows the person.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose video or photo…") { pickSource() }
                }
            } else if scanStopped || scanProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scanProblem.map { "Couldn’t look for faces: \($0)" } ?? "Face search stopped.")
                        .font(.caption).foregroundStyle(scanProblem == nil ? Color.secondary : Color.red)
                    HStack {
                        Button("Try Again") { scanStopped = false; lookAgain += 1 }
                        Button("Choose a different file…") { setSource(nil) }
                    }
                }
            } else if faces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No faces found in that file.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Look Again") { lookAgain += 1 }
                            .help("Go through the file again instead of using what was found last time")
                        Button("Choose a different file…") { setSource(nil) }
                    }
                }
            } else {
                // Section 1 — the people the app found, each saying who they
                // are when it knows.
                HStack {
                    Text("STEP 1 — Faces found in this video")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Look Again") { lookAgain += 1 }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(working)
                        .help("Go through the video again instead of using what was found last time")
                }
                Text("Select a face. A name under it means it is already that person; "
                     + "a name with a question mark is the app's guess.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                    ForEach(faces, id: \.self) { hash in
                        faceChoice(hash)
                    }
                }

                Divider().padding(.vertical, 2)

                if let face = selectedFace, let owner = selectedOwner {
                    namedSection(face, owner)
                } else {
                    // Section 2 — match it to a person already in the library,
                    // or type a brand-new name.
                    Text("STEP 2 — Match it to someone you know")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                    knownPeopleSection

                    Text(matchHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("New name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, typed in
                            // Typing a name means a new person, not the picked one.
                            if !typed.isEmpty { pickedExisting = nil }
                        }
                        .onSubmit(add)

                    // A new person (not a match to an existing one) can carry a
                    // portrait photo, so their row shows a clear face instead of a
                    // blurry mid-video crop. The engine picks the biggest face in
                    // the photo and makes it the person's thumbnail.
                    if pickedExisting == nil && !target.isEmpty {
                        photoSection
                    }
                }

                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .help("Close — everything added so far is kept")
                    Text(namedSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                    } else if selectedFace == nil {
                        Text("Select a face first")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if selectedOwner == nil {
                        Button(pickedExisting == nil ? "Add Person" : "This is \(pickedExisting ?? "")") { add() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(target.isEmpty || selectedFace == nil || working)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 470)
        .task {
            // The known-people row must be populated even when the sheet is
            // opened straight from the classify panel.
            if faceStore.people.isEmpty { await faceStore.reload() }
        }
        .task(id: Pass(path: sourcePath, again: lookAgain, stopped: scanStopped)) {
            guard let path = sourcePath, !scanStopped else { return }
            detecting = true
            scanProblem = nil
            scanStage = "Opening file"
            scanCompleted = 0
            scanTotal = 0
            scanStarted = Date()
            stageStarted = scanStarted
            lastScanProgress = scanStarted
            do {
                let found = try await faceStore.detectFaces(path: path, lookAgain: lookAgain > 0) { stage, completed, total in
                    guard !Task.isCancelled else { return }
                    if stage != scanStage { stageStarted = Date() }
                    scanStage = stage
                    scanCompleted = completed
                    scanTotal = total
                    lastScanProgress = Date()
                }
                try Task.checkCancellation()
                scanStage = "Matching faces to known people"
                scanCompleted = 0
                scanTotal = 0
                lastScanProgress = Date()
                let who = await faceStore.identify(found)
                try Task.checkCancellation()
                faces = found
                identities = who
                detecting = false
                selectNext(after: nil)
            } catch {
                guard !Task.isCancelled else { return }
                detecting = false
                scanProblem = error.localizedDescription
            }
        }
    }

    private var scanProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(scanStage).font(.callout)
                Spacer()
                Button("Stop") {
                    scanStopped = true
                    detecting = false
                }
            }
            if scanTotal > 0 {
                ProgressView(value: Double(scanCompleted), total: Double(scanTotal))
                Text("\(scanCompleted) of \(scanTotal) frames")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            TimelineView(.periodic(from: scanStarted, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(scanStarted)))
                let quiet = context.date.timeIntervalSince(lastScanProgress)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Elapsed: \(elapsed / 60)m \(elapsed % 60)s")
                    if quiet >= 30 {
                        Text("No new progress for \(Int(quiet)) seconds. You can stop and try another file.")
                    } else if scanCompleted >= 3 && scanCompleted < scanTotal {
                        let remaining = max(1, Int(ceil(context.date.timeIntervalSince(stageStarted)
                            / Double(scanCompleted) * Double(scanTotal - scanCompleted))))
                        Text("About \(remaining) seconds left in this step")
                    } else if scanTotal > 0 && scanCompleted < scanTotal {
                        Text("Estimating time remaining for this step…")
                    } else {
                        Text("Time remaining isn’t available for this step.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Text("Reads frames across the video, then checks for faces. Results are saved for next time.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var namedSummary: String {
        let named = faces.filter { identities[$0]?.bound == true }.count
        return "\(named) of \(faces.count) named"
    }

    private var matchHint: String {
        if let guess = selectedGuess, pickedExisting == guess {
            return "This looks like \(guess). Press Return if it is — or pick someone else, "
                 + "or type a new name below."
        }
        return faceStore.people.isEmpty
            ? "You have no people yet — type a name below."
            : "Pick the person this face belongs to, or type a new name below."
    }

    /// A face that is already someone: say so, and offer the way back. Shown
    /// in place of step 2, because a face bound to one person and then matched
    /// to a second would be both of them from then on.
    private func namedSection(_ face: String, _ owner: String) -> some View {
        let addedHere = taggedHere[owner.casefolded] != nil
        return HStack(spacing: 10) {
            faceThumb(face, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("This face is \(owner)")
                    .font(.callout.weight(.semibold))
                Text(addedHere
                     ? "Added just now, and this video is tagged \(owner)."
                     : "The app recognises \(owner) by it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not \(owner)") { remove(face, from: owner) }
                .disabled(working)
                .help(addedHere
                      ? "Takes this face off \(owner), and the tag it put on this video"
                      : "Takes this face off \(owner). The video's tags are left alone.")
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// The people already in the library — the match targets. Picking one
    /// MERGES the selected face into that person, so the app recognises them
    /// from this angle next time instead of creating a duplicate.
    @ViewBuilder
    private var knownPeopleSection: some View {
        let known = knownPeople
        if !known.isEmpty {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                          spacing: 10) {
                    ForEach(known, id: \.name) { person in
                        knownPersonChip(person)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 150)
        }
    }

    /// Alphabetical, except that whoever the selected face looks like leads:
    /// the grid scrolls, and a guess picked for the user must not be a ring
    /// around somebody out of sight.
    private var knownPeople: [FacePerson] {
        var known = faceStore.people.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let guess = selectedGuess,
           let index = known.firstIndex(where: { $0.name == guess }) {
            known.insert(known.remove(at: index), at: 0)
        }
        return known
    }

    /// Optional portrait photo for a brand-new person: preview + pick +
    /// remove. The engine crops the biggest face out of the chosen picture
    /// when the person is added, so this row previews the picture itself.
    private var photoSection: some View {
        HStack(spacing: 8) {
            photoPreview
            VStack(alignment: .leading, spacing: 4) {
                Text("Portrait photo")
                    .font(.caption.weight(.semibold))
                Text(photoPath == nil
                     ? "Optional — a clear picture makes a better thumbnail than a video crop."
                     : "The biggest face in this picture becomes their thumbnail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Choose photo…") { pickPhoto() }
                    if photoPath != nil {
                        Button("Remove") { photoPath = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// The preview shown for the portrait photo: the picture itself, or the
    /// face crop chosen in step 1 when no picture was picked yet.
    @ViewBuilder
    private var photoPreview: some View {
        Group {
            if let photoPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: photoPath)),
               let ns = NSImage(data: data) {
                Image(nsImage: ns)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let face = selectedFace, let image = FaceStore.thumbnail(face) {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            photoPath = url.path
        }
    }

    private func knownPersonChip(_ person: FacePerson) -> some View {
        let chosen = pickedExisting == person.name
        return Button {
            // Picking a person and typing a name are two answers to the same
            // question, so each clears the other.
            pickedExisting = chosen ? nil : person.name
            name = ""
        } label: {
            VStack(spacing: 3) {
                faceThumb(person.representative, size: 56)
                    .overlay(Circle().stroke(chosen ? Color.accentColor : .clear, lineWidth: 3))
                Text(person.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .help(chosen ? "Selected — the chosen face will be matched to \(person.name)"
                     : "This face is \(person.name)")
    }

    /// One found face: its crop, and under it who it is. A tick means the
    /// registry holds it under that name; a question mark means the app is
    /// guessing and nothing has been saved.
    private func faceChoice(_ hash: String) -> some View {
        let who = identities[hash]
        let bound = who?.bound == true
        return Button {
            select(selectedFace == hash ? nil : hash)
        } label: {
            VStack(spacing: 3) {
                faceThumb(hash, size: 64)
                    .overlay(Circle().stroke(
                        selectedFace == hash ? Color.accentColor : .clear, lineWidth: 3))
                    .overlay(alignment: .bottomTrailing) {
                        if bound {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .green)
                        }
                    }
                // A line is always there, so naming a face never moves the grid.
                Text(who.map { bound ? $0.name : "\($0.name)?" } ?? " ")
                    .font(.caption2)
                    .foregroundStyle(bound ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 76)
            }
        }
        .buttonStyle(.plain)
        .help(who.map { bound ? "This face is \($0.name)" : "Looks like \($0.name) — not confirmed" }
              ?? "Nobody the app knows yet")
    }

    /// A face crop — or a person's — as a round thumbnail, with the plain
    /// person symbol when there is no picture on disk.
    private func faceThumb(_ hash: String?, size: CGFloat) -> some View {
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

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .image]
        if panel.runModal() == .OK, let url = panel.url {
            setSource(url.path)
        }
    }

    /// Move to another file — or to none, which is the file picker again.
    /// Everything that was about the old one goes with it.
    private func setSource(_ path: String?) {
        sourcePath = path
        scanStopped = false
        scanProblem = nil
        detecting = false
        lookAgain = 0
        faces = []
        identities = [:]
        taggedHere = [:]
        select(nil)
    }

    /// Select a face, or nothing. A face that looks like someone starts with
    /// them picked, so confirming the app's guess is one press of Return —
    /// but only picked: nothing is saved until the user says so.
    private func select(_ hash: String?) {
        selectedFace = hash
        name = ""
        photoPath = nil
        problem = nil
        if let hash, let who = identities[hash], !who.bound {
            pickedExisting = who.name
        } else {
            pickedExisting = nil
        }
    }

    /// On to the next face nobody has named, going round from the one just
    /// dealt with — so a stranger skipped on purpose is not offered again
    /// until the rest are done.
    private func selectNext(after hash: String?) {
        let start = hash.flatMap { faces.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let round = faces[start...] + faces[..<start]
        select(round.first { identities[$0]?.bound != true })
    }

    /// The source gets the tag whenever it is a VIDEO — whether it is the
    /// video playing now or one the user picked. The face was taken from
    /// it, so that video definitely shows this person; a photo is not part
    /// of the library and gets nothing.
    private var sourceVideo: String? {
        guard let p = sourcePath else { return nil }
        let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
        return videoExtensions.contains(ext) ? p : nil
    }

    private func add() {
        guard let face = selectedFace, selectedOwner == nil, !working else { return }
        // Picking an existing person wins over the text field, so the face
        // merges into that person instead of creating a near-duplicate name.
        let who = target
        guard !who.isEmpty else { return }
        // A portrait is for a new person only: it would replace the picture
        // an existing one already has.
        let photo = pickedExisting == nil ? photoPath : nil
        working = true
        problem = nil
        Task {
            let done = await faceStore.addPerson(who, faceHash: face,
                                                 sourceVideo: sourceVideo, photoPath: photo)
            if let video = done?.tagged { taggedHere[who.casefolded] = video }
            identities = await faceStore.identify(faces)
            working = false
            if identities[face]?.bound == true {
                selectNext(after: face)
            } else {
                problem = "That face could not be added — nothing was changed."
            }
        }
    }

    /// Take a face back off the person it is filed under. The tag goes with it
    /// only when an add in this sitting put it on the video, and only once no
    /// other face here still says that person is in it.
    private func remove(_ face: String, from owner: String) {
        guard !working else { return }
        let key = owner.casefolded
        let stillHere = faces.contains {
            $0 != face && identities[$0]?.bound == true
                && identities[$0]?.name.casefolded == key
        }
        let untag = stillHere ? nil : taggedHere[key]
        working = true
        problem = nil
        Task {
            await faceStore.removeFace(face, from: owner, untag: untag)
            if untag != nil { taggedHere[key] = nil }
            identities = await faceStore.identify(faces)
            working = false
            select(face)
        }
    }
}
