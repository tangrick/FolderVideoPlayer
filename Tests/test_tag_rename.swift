// A renamed or merged tag takes what the engine holds under its name with it:
//
//   1. the suggestion store: the chips and the verdicts on them move to the new
//      name, a video offered both names keeps one chip, and two answers fold
//      into one — so the rejections go on teaching the tag under its new name;
//   2. the fitted heads: the head moves bit for bit, a head the new name
//      already has stays, every encoder's file is covered, and a file this
//      build cannot read is left exactly as it was;
//   3. the library: rename and merge tell the stores, and Undo puts the tags,
//      the verdicts and the head back together.
//
// The failure this guards: "Richard Tang" renamed to "Richard", and the old
// name offered for good beside the new tag — where accepting the chip brought
// the old tag back as a duplicate.
//
// Run: Tests/run_tag_rename.sh

@testable import FVPModel
import Foundation

@main
struct TagRenameTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        func sugg(_ tag: String, _ confidence: Double, _ source: String? = nil) -> TagSuggestion {
            TagSuggestion(tag: tag, confidence: confidence, frames: 3, source: source)
        }

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-tag-rename-\(UUID().uuidString)"
        func dir(_ path: String) -> String {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        Paths.support = dir(root + "/support")
        let media = dir(root + "/media")
        let a = media + "/a.mp4", b = media + "/b.mp4", c = media + "/c.mp4", d = media + "/d.mp4"

        // --- 1. the suggestion store ---------------------------------------------------

        let file = root + "/support/suggestions-test.json"
        let store = SuggestionStore(file: file)
        func verdicts(_ path: String) -> [String: SuggestionVerdict] { store.entry(path)?.verdicts ?? [:] }
        func chips(_ path: String) -> [String] { (store.entry(path)?.suggestions ?? []).map(\.tag) }

        store.record(a, suggestions: [sugg("Richard Tang", 0.91, "trained"), sugg("Beach", 0.03)],
                     model: "test", framesSeen: 3)
        store.record(b, suggestions: [sugg("richard tang", 0.80, "trained")], model: "test", framesSeen: 3)
        store.decide(b, tag: "richard tang", verdict: .rejected)
        store.record(c, suggestions: [sugg("Beach", 0.04)], model: "test", framesSeen: 3)
        store.decide(c, tag: "Beach", verdict: .accepted)
        let untouched = store.entry(c)

        let before = store.renameTag(["Richard Tang"], to: "Richard")
        check("a pending chip is offered under the new name, with what it scored",
              store.pending(a).first == sugg("Richard", 0.91, "trained"), "\(store.pending(a))")
        check("...and the old name is gone from the video", !chips(a).contains("Richard Tang"))
        check("...while its other chips stay as they were", chips(a) == ["Richard", "Beach"], "\(chips(a))")
        check("the old name is matched whatever its case, and its verdict moves",
              chips(b) == ["Richard"] && verdicts(b) == ["Richard": .rejected], "\(chips(b)) \(verdicts(b))")
        check("so the rejection is a training label for the new name",
              store.labelledExamples.contains { $0.tag == "Richard" && !$0.accepted }
                && !store.labelledExamples.contains { $0.tag.lowercased() == "richard tang" })
        check("a video that never had the name is not touched",
              chips(c) == ["Beach"] && verdicts(c) == untouched?.verdicts && before[Paths.tagKey(c)] == nil)
        check("what is handed back is the changed entries, as they were",
              Set(before.keys) == [Paths.tagKey(a), Paths.tagKey(b)]
                && before[Paths.tagKey(b)]?.verdicts == ["richard tang": .rejected])
        check("renaming a name nothing holds changes nothing",
              store.renameTag(["Nobody"], to: "Somebody").isEmpty)

        store.flush()
        let reread = SuggestionStore(file: file)
        check("the new name is what is written",
              reread.pending(a).first?.tag == "Richard" && reread.entry(b)?.verdicts == ["Richard": .rejected])

        store.restore(before)
        check("restore puts the old name back exactly",
              chips(a) == ["Richard Tang", "Beach"] && chips(b) == ["richard tang"]
                && verdicts(b) == ["richard tang": .rejected], "\(chips(a)) \(verdicts(b))")

        // Both names on one video: one chip, one answer.
        store.record(d, suggestions: [sugg("Bob", 0.20, "face"), sugg("Pier", 0.03),
                                      sugg("Bob Meyer", 0.88, "trained"), sugg("Bobby", 0.10, "library")],
                     model: "test", framesSeen: 3)
        store.renameTag(["Bob Meyer", "Bobby"], to: "Bob")
        check("a video offered both names keeps one chip, where the first stood",
              chips(d) == ["Bob", "Pier"], "\(chips(d))")
        check("...and it is the stronger of them",
              store.entry(d)?.suggestions.first == sugg("Bob", 0.88, "trained"))

        func folded(_ old: SuggestionVerdict, _ new: SuggestionVerdict) -> SuggestionVerdict? {
            let path = media + "/fold-\(old.rawValue)-\(new.rawValue).mp4"
            store.decide(path, tag: "Bob Meyer", verdict: old)
            store.decide(path, tag: "Bob", verdict: new)
            store.renameTag(["Bob Meyer"], to: "Bob")
            let now = verdicts(path)
            return now.count == 1 ? now["Bob"] : nil
        }
        check("a yes to either name is a yes to the one they became",
              folded(.accepted, .rejected) == .accepted && folded(.rejected, .accepted) == .accepted)
        check("a no outranks a chip that was only passed over",
              folded(.rejected, .ignored) == .rejected && folded(.ignored, .rejected) == .rejected)
        check("two that agree stay one", folded(.ignored, .ignored) == .ignored)

        store.record(a, suggestions: [sugg("richard", 0.5)], model: "test", framesSeen: 3)
        store.renameTag(["richard"], to: "Richard")
        check("a rename that only changes the case is carried too", chips(a) == ["Richard"], "\(chips(a))")

        // --- 2. the fitted heads -----------------------------------------------------------

        let slug = "test_slug"
        func head(_ w: [Float], _ b: Float, _ n: Float) -> LogisticHead { LogisticHead(w: w, b: b, n: n) }
        func bits(_ h: LogisticHead?) -> [UInt32] { (h?.w ?? []).map(\.bitPattern) + [h?.b.bitPattern ?? 0] }
        // A repeating third and a denormal, as in the storage gate: a head that
        // came back rounded would score differently for no reason.
        let richard = head([0.1, -1.0 / 3.0, 1e-30, 1.5e30], -0.371212, 23)
        let beach = head([1, -2, 3.5, -4.25], 0.490852, 20)
        let nsfw = head([0.25, -0.25, 0.5, -0.5], -0.180558, 20)
        try! TrainedHeads(slug: slug, dim: 4, tags: ["Richard Tang": richard, "Beach": beach], nsfw: nsfw)
            .save(root: root + "/support", merging: false)
        let headsFile = TrainedHeads.file(slug: slug)
        let bytesBefore = fm.contents(atPath: headsFile)

        check("renaming a name with no head rewrites nothing",
              TrainedHeads.rename(["Nobody"], to: "Somebody").isEmpty
                && fm.contents(atPath: headsFile) == bytesBefore)
        let headsBefore = TrainedHeads.rename(["richard tang"], to: "Richard")
        var loaded = TrainedHeads.load(slug: slug)
        check("the head is filed under the new name and the old one is gone",
              loaded.tags.keys.sorted() == ["Beach", "Richard"], "\(loaded.tags.keys.sorted())")
        check("...bit for bit, with the videos it was fitted from",
              bits(loaded.tags["Richard"]) == bits(richard) && loaded.tags["Richard"]?.n == 23)
        check("the other heads and the Safe/NSFW head are untouched",
              bits(loaded.tags["Beach"]) == bits(beach) && bits(loaded.nsfw) == bits(nsfw)
                && loaded.dim == 4 && loaded.problem == nil)
        check("what is handed back is the file as it was", headsBefore == [headsFile: bytesBefore!])
        TrainedHeads.restore(headsBefore)
        check("restore puts the file back byte for byte", fm.contents(atPath: headsFile) == bytesBefore)

        // The new name already has a head of its own.
        let own = head([9, 9, 9, 9], 9, 5)
        try! TrainedHeads(slug: slug, dim: 4, tags: ["Richard": own]).save(root: root + "/support")
        TrainedHeads.rename(["Richard Tang"], to: "Richard")
        loaded = TrainedHeads.load(slug: slug)
        check("a head the new name already has stays, and the old name's is dropped",
              bits(loaded.tags["Richard"]) == bits(own) && loaded.tags["Richard Tang"] == nil)

        // Several folded into a name with no head.
        let few = head([1, 1, 1, 1], 1, 6), many = head([2, 2, 2, 2], 2, 40)
        try! TrainedHeads(slug: slug, dim: 4, tags: ["Iceland trip": few, "Iceland 2019": many])
            .save(root: root + "/support", merging: false)
        TrainedHeads.rename(["Iceland trip", "Iceland 2019"], to: "Iceland")
        loaded = TrainedHeads.load(slug: slug)
        check("folding several, the head fitted from the most videos is the one that moves",
              loaded.tags.keys.sorted() == ["Iceland"] && bits(loaded.tags["Iceland"]) == bits(many),
              "\(loaded.tags.keys.sorted())")

        // Another encoder's file, and one this build cannot read.
        try! TrainedHeads(slug: "other_slug", dim: 4, tags: ["Kite Day": few])
            .save(root: root + "/support", merging: false)
        let newer = TrainedHeads.file(slug: "newer_slug")
        let newerBytes = Data(#"{"version":99,"dim":4,"tags":{"Kite Day":{"w":"AAAA","b":0,"n":1}}}"#.utf8)
        try! newerBytes.write(to: URL(fileURLWithPath: newer))
        let touched = TrainedHeads.rename(["Kite Day"], to: "Kites")
        check("every encoder's heads follow the rename",
              TrainedHeads.load(slug: "other_slug").tags.keys.sorted() == ["Kites"])
        check("a file from a newer version is left exactly as it was",
              fm.contents(atPath: newer) == newerBytes && touched[newer] == nil)

        // --- 3. the library tells the stores, and Undo puts them back -------------------------

        let library = Library()
        var told: [(sources: [String], target: String)] = []
        var putBack = 0
        library.tagsRenamed = { sources, target in
            told.append((sources, target))
            return { putBack += 1 }
        }
        library.setTags(["Sea", "Kite"], for: a)
        library.setTags(["Ocean"], for: b)
        library.saveTags()

        library.renameTag("Sea", to: "Seaside")
        check("a rename tells the stores the old name and the new",
              told.count == 1 && told[0].sources == ["Sea"] && told[0].target == "Seaside")
        check("undo of the rename puts the stores back, once",
              library.undoTagChange() && putBack == 1 && library.tagsFor(a) == ["Sea", "Kite"])
        check("...and a second undo has nothing of theirs to put back",
              !library.undoTagChange() && putBack == 1)

        library.mergeTags(["Sea", "Ocean", "Water"], into: "Water")
        check("a merge tells them every name folded away, not the one that survives",
              told.count == 2 && told[1].sources == ["Sea", "Ocean"] && told[1].target == "Water")
        library.deleteTag("Kite")
        check("a later destructive edit takes the undo slot, and the merge's put-back with it",
              library.undoTagChange() && putBack == 1 && library.tagsFor(a) == ["Kite", "Water"],
              "\(putBack) \(library.tagsFor(a))")
        check("merging a tag into itself tells nobody",
              library.mergeTags(["Water"], into: "water") == 0 && told.count == 2)

        // The whole of it, wired as the app wires it.
        let people = SuggestionStore(file: root + "/support/suggestions-people.json")
        library.tagsRenamed = { sources, target in
            let verdicts = people.renameTag(sources, to: target)
            let heads = TrainedHeads.rename(sources, to: target)
            return {
                people.restore(verdicts)
                TrainedHeads.restore(heads)
            }
        }
        try! TrainedHeads(slug: slug, dim: 4, tags: ["Richard Tang": richard])
            .save(root: root + "/support", merging: false)
        library.setTags(["Richard Tang"], for: a)
        library.saveTags()
        people.record(b, suggestions: [sugg("Richard Tang", 0.9, "trained")], model: "test", framesSeen: 3)
        people.decide(c, tag: "Richard Tang", verdict: .rejected)

        library.renameTag("Richard Tang", to: "Richard")
        check("after a rename the tag, the chip, the verdict and the head all carry the new name",
              library.tagsFor(a) == ["Richard"]
                && people.pending(b).map(\.tag) == ["Richard"]
                && people.entry(c)?.verdicts == ["Richard": .rejected]
                && TrainedHeads.load(slug: slug).tags.keys.sorted() == ["Richard"])
        check("...so nothing is left to offer the old name",
              !people.byVideo.values.contains { e in
                  e.suggestions.contains { $0.tag == "Richard Tang" } || e.verdicts["Richard Tang"] != nil
              })
        check("undo puts all four back under the old name",
              library.undoTagChange()
                && library.tagsFor(a) == ["Richard Tang"]
                && people.pending(b).map(\.tag) == ["Richard Tang"]
                && people.entry(c)?.verdicts == ["Richard Tang": .rejected]
                && bits(TrainedHeads.load(slug: slug).tags["Richard Tang"]) == bits(richard))

        // The repair for a name orphaned before this existed: the old tag is
        // back on one video (an accepted stale chip), and is merged away.
        library.setTags(["Richard"], for: a)
        library.setTags(["Richard Tang"], for: d)
        library.saveTags()
        library.mergeTags(["Richard Tang"], into: "Richard")
        check("merging an orphaned name into the tag it became carries its chips, verdicts and head",
              library.tagsFor(d) == ["Richard"]
                && people.pending(b).map(\.tag) == ["Richard"]
                && people.entry(c)?.verdicts == ["Richard": .rejected]
                && bits(TrainedHeads.load(slug: slug).tags["Richard"]) == bits(richard)
                && TrainedHeads.load(slug: slug).tags["Richard Tang"] == nil)

        try? fm.removeItem(atPath: root)
        print(failures == 0 ? "\nall tag rename checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
