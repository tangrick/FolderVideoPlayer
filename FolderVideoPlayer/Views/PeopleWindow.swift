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

/// Step-by-step "add a person": the engine detects the biggest few faces in a
/// source (a video or photo) and the user picks which one to name. When opened
/// from the classify panel it is seeded with the current video, so the faces
/// already on screen are offered immediately — no file picker needed.
struct AddPersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var faceStore: FaceStore
    @EnvironmentObject var app: AppModel

    /// A video to detect from immediately, when opened from the classify panel
    /// while something is playing. Nil means start from the file picker.
    let initialVideo: String?

    @State private var sourcePath: String?
    @State private var faces: [String] = []
    @State private var selectedFace: String?
    @State private var name = ""
    @State private var detecting = false
    /// Set when the user picked someone they already have, instead of typing a
    /// new name. The chosen face is then MERGED into that person.
    @State private var pickedExisting: String?
    /// A clear portrait photo for a NEW person, so their row shows a proper
    /// face instead of a blurry mid-video crop. Only applies to new people —
    /// matching to an existing person reuses that person's own photo.
    @State private var photoPath: String?

    init(initialVideo: String? = nil) {
        self.initialVideo = initialVideo
        _sourcePath = State(initialValue: initialVideo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The way out is ALWAYS in the same corner, in every state —
            // including while detecting and when no faces were found. A
            // state without a close control is a dead end: the user asked
            // to leave, and there was nothing on screen that let them.
            HStack {
                Text("Add a face").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close without adding anyone")
                .accessibilityLabel("Close without adding anyone")
            }
            Text("Pick a face the app found, then match it to a person you know.")
                .font(.caption).foregroundStyle(.secondary)

            if let path = sourcePath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if detecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Detecting faces…").font(.caption).foregroundStyle(.secondary)
                }
            } else if sourcePath == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick a video or photo that shows the person.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose video or photo…") { pickSource() }
                }
            } else if faces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No faces found in that file.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose a different file…") { sourcePath = nil }
                }
            } else {
                // Section 1 — the faces the app found but could not put a name
                // to. The user picks the one they want to identify.
                Text("STEP 1 — Faces found in this video")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Select the face you want to name.")
                    .font(.caption).foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                    ForEach(faces, id: \.self) { hash in
                        faceChoice(hash)
                    }
                }

                Divider().padding(.vertical, 2)

                // Section 2 — match it to a person already in the library, or
                // type a brand-new name.
                Text("STEP 2 — Match it to someone you know")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                knownPeopleSection

                Text(faceStore.people.isEmpty
                     ? "You have no people yet — type a name below."
                     : "Pick the person this face belongs to, or type a new name below.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("New name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in
                        // Typing over a picked person means a new name again.
                        if let picked = pickedExisting, picked != name { pickedExisting = nil }
                    }
                    .onSubmit(add)

                // A new person (not a match to an existing one) can carry a
                // portrait photo, so their row shows a clear face instead of a
                // blurry mid-video crop. The engine picks the biggest face in
                // the photo and makes it the person's thumbnail.
                if pickedExisting == nil && !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    photoSection
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if selectedFace == nil {
                        Text("Select a face first")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(pickedExisting == nil ? "Add Person" : "This is \(pickedExisting ?? "")") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedFace == nil)
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
        .task(id: sourcePath) {
            guard let path = sourcePath else { return }
            detecting = true
            defer { detecting = false }
            faces = await faceStore.detectFaces(path: path)
            selectedFace = nil
        }
    }

    /// The people already in the library — the match targets. Picking one
    /// MERGES the selected face into that person, so the app recognises them
    /// from this angle next time instead of creating a duplicate.
    @ViewBuilder
    private var knownPeopleSection: some View {
        let known = faceStore.people.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
            if chosen {
                pickedExisting = nil
                name = ""
            } else {
                pickedExisting = person.name
                name = person.name
            }
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let hash = person.representative, let image = FaceStore.thumbnail(hash) {
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

    private func faceChoice(_ hash: String) -> some View {
        Button {
            selectedFace = (selectedFace == hash) ? nil : hash
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
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(
                selectedFace == hash ? Color.accentColor : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .image]
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
        }
    }

    private func add() {
        guard let face = selectedFace else { return }
        // Picking an existing person wins over the text field, so the face
        // merges into that person instead of creating a near-duplicate name.
        let n = (pickedExisting ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        // The source gets the tag whenever it is a VIDEO — whether it is the
        // video playing now or one the user picked. The face was taken from
        // it, so that video definitely shows this person; a photo is not part
        // of the library and gets nothing.
        let sourceVideo: String? = {
            guard let p = sourcePath else { return nil }
            let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
            return videoExtensions.contains(ext) ? p : nil
        }()
        dismiss()
        Task {
            await faceStore.addPerson(n, faceHash: face, sourceVideo: sourceVideo,
                                      photoPath: photoPath)
        }
    }
}
