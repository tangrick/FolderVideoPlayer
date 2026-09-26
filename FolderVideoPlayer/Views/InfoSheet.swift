import AVFoundation
import AppKit
import SwiftUI

/// Everything known about one video, in one place — ⌘I.
///
/// The facts were all in the app already and all somewhere else: size and date
/// in two playlist columns, tags in the panel, the verdict in a third column,
/// the duration only in the transport bar while it plays, and the full path
/// nowhere at all. A person asking "what IS this file?" had to look in four
/// places and still could not copy the path.
///
/// A WINDOW rather than a sheet since 2026-09-17, at the maintainer's request:
/// a sheet blocks the app, so answering "what is this one?" about a second
/// video meant closing the first answer. `InfoWindow` below follows whichever
/// video is in hand, so the question can be asked over and over without the
/// window being tidied away between answers.
///
/// The view itself is unchanged and still takes a plain `path`: it is built
/// fresh per video by `InfoWindow`, which is what keeps its measured `@State`
/// from describing the previous file.
struct InfoSheet: View {
    /// The video this is about. Passed in as a plain value — a sheet gets no
    /// ancestors, so it is told rather than asked.
    let path: String
    let onClose: () -> Void

    @EnvironmentObject var library: Library
    @EnvironmentObject var media: MediaCache
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var suggestions: SuggestionStore

    /// Measured on appear, off the main thread: a stat is an SMB round trip
    /// and a sleeping share answers its first one in seconds.
    @State private var size: Int64?
    @State private var added: Double?
    @State private var modified: Double?
    @State private var duration: Double?
    @State private var dimensions: String?
    @State private var poster: NSImage?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("File") {
                        row("Name", (path as NSString).lastPathComponent)
                        row("Kind", (path as NSString).pathExtension.uppercased() + " video")
                        row("Size", size.map { humanSize($0) } ?? "—")
                        row("Length", duration.map { clock($0) } ?? "—")
                        row("Picture", dimensions ?? "—")
                    }
                    section("When") {
                        row("Added", added.map { dateText($0) } ?? "—")
                        row("Changed", modified.map { dateText($0) } ?? "—")
                        row("Watched to", watchedText)
                    }
                    section("Tags") { tagsBlock }
                    section("The engine") { engineBlock }
                    section("Where") { whereBlock }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { await measure() }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, height: 59)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text((path as NSString).lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - the blocks

    @ViewBuilder
    private var tagsBlock: some View {
        let names = library.tagsFor(path).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if names.isEmpty {
            Text("None yet — ⌘T adds some.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ChipFlow(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 5))
                }
            }
        }
        let rejected = (suggestions.entry(path)?.verdicts ?? [:])
            .filter { $0.value == .rejected }
            .keys.sorted()
        if !rejected.isEmpty {
            Text("You said it is not: " + rejected.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // What the app read off the file, kept visually apart from the tags
        // above: a plain grey chip, because these are not yours to change here
        // and a chip that looks editable would invite the attempt.
        let readings = library.factsFor(path)
        if !readings.isEmpty {
            Text("Read from the file")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ChipFlow(spacing: 6) {
                ForEach(readings, id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 5))
                }
            }
        }
    }

    @ViewBuilder
    private var engineBlock: some View {
        let record = app.analysis?.analysis(for: path)
        if let record {
            row("Verdict", verdictText(record))
            if let prediction = record.prediction {
                row("Confidence", String(format: "%.0f%%", prediction.score * 100))
                row("Frames seen", "\(prediction.frames)")
                row("Model", prediction.modelID)
                // Which model produced the score. The row above is the embedding
                // space a frame hash resolves in — different question, and both
                // belong on screen now that two models share one record.
                row("Classifier", prediction.classifier)
                row("Classified", dateText(prediction.classifiedAt))
            }
            if !record.history.isEmpty {
                row("Corrections", "\(record.history.count) by you")
            }
        } else {
            // Only point at Classify when it can run: without the model that
            // item is disabled, and the hint would lead to a dead end.
            Text(app.ai.reason(.classify).map { why in
                    let fixable = (app.ai.blockers[.classify] ?? []).contains { $0.fixableInApp }
                    return "Not classified yet. \(why)" + (fixable ? " Settings → AI can download it." : "")
                 } ?? "Not classified yet. AI ▾ → Classify runs it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whereBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Filed under “\(Paths.tagKey(path))” — the key your other devices use.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                copied = true
            }
            .disabled(copied)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)])
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - the words for a verdict

    /// What the app believes this video is, and who said so. The user's own
    /// mark always outranks the machine's — the same rule the playlist column
    /// follows, said in words here.
    private func verdictText(_ record: VideoAnalysis) -> String {
        if let label = record.userLabel { return "\(label.title) — you said so" }
        if let machine = AnalysisStore.machineVerdict(record) {
            return "\(machine.title) — the engine's guess"
        }
        switch record.phase {
        case .queued: return "Waiting to be classified"
        case .analyzing: return "Being classified now"
        case .failed: return "The engine could not read it"
        case .done: return "No verdict"
        }
    }

    private var watchedText: String {
        let position = library.resumePoint(path)
        guard position > 0 else { return "Not started, or finished" }
        guard let duration, duration > 0 else { return clock(position) }
        return "\(clock(position)) of \(clock(duration)) "
            + String(format: "(%.0f%%)", position / duration * 100)
    }

    // MARK: - measuring

    /// Stat the file, ask AVFoundation for its shape, and fetch a frame — all
    /// off the main thread, all once. Nothing here is required for the sheet
    /// to be useful: every field falls back to an em dash.
    private func measure() async {
        poster = await media.poster(path, big: false)
        let facts = await Task.detached(priority: .userInitiated) {
            () -> (Int64?, Double?, Double?, Double?, String?) in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            let added = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970
            let changed = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            var shape: String?
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                shape = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
            }
            return (size, added, changed, seconds, shape)
        }.value
        size = facts.0
        added = facts.1
        modified = facts.2
        duration = facts.3 ?? media.length(path)
        dimensions = facts.4
    }

    // MARK: - layout helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}


/// ⌘I as a window: the info for whichever video is in hand, updating as that
/// changes rather than holding the app still.
///
/// `AppModel.infoTarget` is the rule — the ticked row when exactly one is
/// ticked, otherwise the video playing — so clicking a different row in the
/// playlist re-answers here with no clicking in this window at all.
///
/// `.id(path)` is load-bearing. `InfoSheet` measures size, dates, duration and
/// a poster into `@State` when it appears; handing the same view a new `path`
/// would leave all of that describing the previous video until each async
/// measurement happened to land. A new identity per path builds a fresh one,
/// so the window is either right or visibly still measuring.
struct InfoWindow: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var media: MediaCache
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var suggestions: SuggestionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let path = app.infoTarget {
                InfoSheet(path: path) { dismiss() }
                    .id(path)
            } else {
                // Nothing playing and nothing ticked. Says so, rather than
                // showing the last video as though it were still the answer.
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No video selected")
                        .foregroundStyle(.secondary)
                    Text("Pick a video in the playlist, or play one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 520, height: 560)
            }
        }
    }
}
