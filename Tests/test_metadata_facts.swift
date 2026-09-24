// The facts READ off the files, in a store of their own — and the one-time
// move of them out of the tag store.
//
// The split is a data migration on a live library, so the checks are mostly
// about what must NOT happen: a tag of the user's moved out because it looked
// like a reading, a name lost in the move, a store left half-separated, a
// second run moving something new. `MetadataSplit.separate` is pure, so all of
// it is testable here with no app, no models and no library on disk.
//
// Point `FVP_REAL_TAGS` at a copy of a real tags.json and this also reports
// what the split would do to it — the way the rule was checked against the
// 3,595-video library before the migration ran for real. Nothing is written.
//
// Pure: no FileManager beyond one temp file, no models, no app.

@testable import FVPModel
import Foundation

@main
struct MetadataFactsTest {
    static func main() {
        var failures = 0
        func check(_ what: String, _ ok: Bool, _ detail: String = "") {
            let tail = (ok || detail.isEmpty) ? "" : " — \(detail)"
            print(ok ? "ok   \(what)" : "FAIL \(what)\(tail)")
            if !ok { failures += 1 }
        }

        // --- what counts as a reading ----------------------------------------------
        //
        // The rule that lets the migration act at all. Every one of these was
        // taken out of the live library by it, so the list has to be exactly the
        // names that cannot be anything but a reading.
        do {
            for name in ["2015", "2016", "2026", "May 2016", "December 2022",
                         "1080p", "4K", "HD", "720p", "Slow-mo",
                         "iPhone 16 Plus", "iPhone 7", "canon",
                         "Ray-Ban Meta Smart Glasses"] {
                check("\(name) is a reading", TagKinds.isFileFact(name))
            }
            // The ones that must NOT be: these are the user's own tags, and the
            // live library is full of them. `Iceland` is the important one — it is
            // BOTH a country name and a tag he means, which is why no shape rule
            // may claim a place.
            for name in ["Iceland", "Asian Cruise", "Alaska Cruise", "Beach", "Birthday",
                         "Winter", "Waterfall", "Night", "Dining", "Mahjong",
                         "2015 recap", "1080", "4", "HDMI cable", "Canopus"] {
                check("\(name) is not a reading", !TagKinds.isFileFact(name))
            }
            // Case does not change what a name is.
            check("case does not change a reading", TagKinds.isFileFact("1080P"))
            check("...nor does whitespace", TagKinds.isFileFact("  2016  "))
        }

        // --- which kind of reading ------------------------------------------------
        //
        // The sidebar groups by this, and it deliberately reuses the existing
        // headings rather than inventing a second vocabulary: a quality mark
        // files under Camera & Quality, the same as a camera does.
        do {
            check("a year is a date", TagKinds.kind(ofFact: "2016") == TagKinds.when)
            check("a month and year is a date", TagKinds.kind(ofFact: "May 2016") == TagKinds.when)
            check("a resolution is camera & quality",
                  TagKinds.kind(ofFact: "1080p") == TagKinds.camera)
            check("so is a camera", TagKinds.kind(ofFact: "iPhone 16 Plus") == TagKinds.camera)
            check("and a device named in full",
                  TagKinds.kind(ofFact: "Ray-Ban Meta Smart Glasses") == TagKinds.camera)
            // Everything else in this store came out of the GPS, so it is a place.
            check("what is neither is a place",
                  TagKinds.kind(ofFact: "Singapore") == TagKinds.place)
        }

        // --- reading a year and a month out of a name -----------------------------
        do {
            check("a bare year reads as its year", AutoTagCore.yearIn("2016") == 2016)
            check("a month and year reads as its year", AutoTagCore.yearIn("May 2016") == 2016)
            check("a name with no year reads as none", AutoTagCore.yearIn("Beach") == nil)
            check("a bare year has no month", AutoTagCore.monthIn("2016") == nil)
            check("a month and year reads as its month", AutoTagCore.monthIn("May 2016") == 5)
            check("December is the twelfth", AutoTagCore.monthIn("December 2022") == 12)
            check("a name with no month reads as none", AutoTagCore.monthIn("Beach") == nil)
            // The date shape and the date reading have to agree, because the
            // sidebar sorts what the rule claimed.
            check("everything date-shaped has a year",
                  ["2016", "May 2016", "December 2022"].allSatisfy {
                      TagKinds.isDateLike($0) == (AutoTagCore.yearIn($0) != nil)
                  })
        }

        // --- the split -------------------------------------------------------------
        do {
            let tags = [
                "/v/a.mp4": ["Iceland", "2015", "May 2015", "1080p"],
                "/v/b.mp4": ["Beach", "iPhone 16 Plus"],
                "/v/c.mp4": ["Birthday"],
            ]
            let report = MetadataSplit.separate(tags: tags)
            check("the readings come out",
                  report.facts["/v/a.mp4"] == ["2015", "May 2015", "1080p"],
                  "\(String(describing: report.facts["/v/a.mp4"]))")
            check("...and the tags stay, in their order",
                  report.tags["/v/a.mp4"] == ["Iceland"],
                  "\(String(describing: report.tags["/v/a.mp4"]))")
            check("a video with nothing but readings keeps no tag entry",
                  report.tags["/v/b.mp4"] == ["Beach"])
            check("a video with no readings is untouched",
                  report.tags["/v/c.mp4"] == ["Birthday"] && report.facts["/v/c.mp4"] == nil)
            check("the count is entries, not videos", report.moved == 4, "\(report.moved)")
            check("the video count is videos", report.videos == 2, "\(report.videos)")
            check("the names are the distinct ones, sorted",
                  report.names == ["1080p", "2015", "iPhone 16 Plus", "May 2015"],
                  "\(report.names)")

            // NOTHING MAY BE LOST. This is the invariant the whole migration rests
            // on: every entry that went in is either a tag or a reading coming out.
            let before = tags.values.reduce(0) { $0 + $1.count }
            let after = report.tags.values.reduce(0) { $0 + $1.count }
                + report.facts.values.reduce(0) { $0 + $1.count }
            check("every entry survives the move", before == after, "\(before) → \(after)")

            // Idempotent by construction: there are no readings left to move.
            let again = MetadataSplit.separate(tags: report.tags)
            check("running it a second time moves nothing", again.isEmpty)
            check("...and leaves the tags exactly as they were", again.tags == report.tags)
        }

        // --- a place is a reading only when the scan says so ------------------------
        //
        // `Singapore` is written by GPS on one video and typed by hand on another.
        // The provenance record is the only thing that can tell them apart, and it
        // is per video — so the same name leaves one video and stays on the next.
        do {
            var provenance = TagProvenance()
            provenance.recordMetadata(["Singapore"], on: "/v/d.mp4")
            let tags = ["/v/d.mp4": ["Singapore", "Beach"],
                        "/v/e.mp4": ["Singapore", "Iceland"]]
            let report = MetadataSplit.separate(tags: tags, provenance: provenance)
            check("a GPS place moves off the video the scan wrote it on",
                  report.facts["/v/d.mp4"] == ["Singapore"],
                  "\(String(describing: report.facts["/v/d.mp4"]))")
            check("...and stays a tag on the video it was typed on",
                  report.tags["/v/e.mp4"] == ["Singapore", "Iceland"],
                  "\(String(describing: report.tags["/v/e.mp4"]))")
            check("Iceland is never taken, even though it is a country",
                  report.tags["/v/d.mp4"] == ["Beach"])
            check("the move is counted", report.moved == 1 && report.videos == 1)
        }

        // --- what an Undo may take out --------------------------------------------
        //
        // Narrower than the split on purpose: a name goes only when the fact store
        // already holds it FOR THAT VIDEO. A year the user typed onto a video that
        // holds no such reading is a tag, and stays one.
        do {
            var facts = MetadataFacts()
            facts.set(["2016", "1080p"], for: "/v/a.mp4")
            let snapshot = ["/v/a.mp4": ["Iceland", "2016", "1080p"],
                            "/v/z.mp4": ["2016", "Beach"],
                            "/v/y.mp4": ["1080p"]]
            let restored = MetadataSplit.dropKnownReadings(tags: snapshot, facts: facts)
            check("a reading the store already holds comes out of the snapshot",
                  restored["/v/a.mp4"] == ["Iceland"],
                  "\(String(describing: restored["/v/a.mp4"]))")
            check("a year typed onto a video with no such reading stays a tag",
                  restored["/v/z.mp4"] == ["2016", "Beach"],
                  "\(String(describing: restored["/v/z.mp4"]))")
            check("a resolution is treated the same way", restored["/v/y.mp4"] == ["1080p"])
            check("it never claims a name the store does not hold",
                  MetadataSplit.dropKnownReadings(tags: ["/v/b.mp4": ["Iceland", "Beach"]],
                                                  facts: facts)["/v/b.mp4"] == ["Iceland", "Beach"])
        }

        // --- the store itself ------------------------------------------------------
        do {
            var store = MetadataFacts()
            check("a new store is empty", store.isEmpty && store.vocabulary().isEmpty)

            store.set(["2016", "May 2016"], for: "a.mp4")
            check("setting keeps the order given", store.names(for: "a.mp4") == ["2016", "May 2016"])
            store.add(["1080p", "may 2016"], to: "a.mp4")
            check("adding merges without doubling, case-insensitively",
                  store.names(for: "a.mp4") == ["2016", "May 2016", "1080p"],
                  "\(store.names(for: "a.mp4"))")
            check("adding reads back per video", store.has("May 2016", on: "a.mp4"))
            check("...and only for that video", !store.has("May 2016", on: "b.mp4"))

            store.set([], for: "a.mp4")
            check("setting nothing drops the entry rather than leaving it empty",
                  store.isEmpty)
            store.set(["2016"], for: "b.mp4")
            store.set(["   "], for: "c.mp4")
            check("whitespace is not a name", store.names(for: "c.mp4").isEmpty)

            store.set(["1080p"], for: "d.mp4")
            store.remove("1080p")
            check("removing takes the name off every video",
                  store.names(for: "d.mp4").isEmpty && !store.has("1080p", on: "d.mp4"))

            store.set(["2016", "May 2016"], for: "e.mp4")
            store.rename("May 2016", to: "June 2016")
            check("renaming replaces the name everywhere",
                  store.names(for: "e.mp4") == ["2016", "June 2016"],
                  "\(store.names(for: "e.mp4"))")

            store.set(["iPhone 7"], for: "f.mp4")
            store.move(from: "f.mp4", to: "g.mp4")
            check("a move carries the readings", store.names(for: "g.mp4") == ["iPhone 7"])
            check("...and leaves nothing behind", store.names(for: "f.mp4").isEmpty)
            store.set(["iPhone 8"], for: "g.mp4")
            store.set(["iPhone 7"], for: "h.mp4")
            store.move(from: "h.mp4", to: "g.mp4")
            check("a move onto a video with readings of its own keeps both",
                  store.names(for: "g.mp4") == ["iPhone 8", "iPhone 7"],
                  "\(store.names(for: "g.mp4"))")

            store.forget("g.mp4")
            check("forgetting drops the video", store.names(for: "g.mp4").isEmpty)

            store.set(["2016", "Singapore", "1080p"], for: "i.mp4")
            store.set(["singapore"], for: "j.mp4")
            check("the vocabulary is unique case-insensitively and sorted",
                  store.vocabulary() == ["1080p", "2016", "June 2016", "Singapore"],
                  "\(store.vocabulary())")
            check("carrying finds every video with a name",
                  store.carrying("Singapore") == ["i.mp4", "j.mp4"],
                  "\(store.carrying("Singapore"))")
            // The spelling shown must be settled by the videos, not by the
            // order a dictionary happens to hand them over — otherwise the
            // sidebar reads "Singapore" one launch and "singapore" the next.
            // Built repeatedly from a store filled in varying orders: a
            // dictionary-order bug shows up as a disagreement between runs.
            var spellings = Set<String>()
            for _ in 0..<50 {
                var shuffled = MetadataFacts()
                for key in ["i.mp4", "j.mp4", "k.mp4"].shuffled() {
                    shuffled.set(key == "j.mp4" ? ["singapore"] : ["Singapore"], for: key)
                }
                spellings.insert(shuffled.vocabulary().joined(separator: ","))
            }
            check("the spelling shown does not change from one build to the next",
                  spellings == ["Singapore"], "\(spellings)")
        }

        // --- round trip ------------------------------------------------------------
        do {
            var store = MetadataFacts()
            store.set(["2016", "1080p"], for: "a.mp4")
            store.set(["Singapore"], for: "b.mp4")
            let data = try! JSONEncoder().encode(store)
            let back = try! JSONDecoder().decode(MetadataFacts.self, from: data)
            check("a decoded store keeps its readings", back == store)
            check("...and answers for the right video",
                  back.has("1080p", on: "a.mp4") && !back.has("1080p", on: "b.mp4"))
            check("the file says \"facts\", not \"tags\"",
                  String(data: data, encoding: .utf8)?.contains("\"facts\"") == true)

            // The file is on disk under the support folder, and a library that has
            // never had one must read as empty rather than fail.
            let temp = NSTemporaryDirectory() + "fvp-metadata-\(UUID().uuidString).json"
            store.save(to: temp)
            check("a store written to disk reads back",
                  MetadataFacts.load(at: temp) == store)
            try? FileManager.default.removeItem(atPath: temp)
            check("a missing file is an empty store, not a failure",
                  MetadataFacts.load(at: temp).isEmpty)
            check("a store built from a plain dictionary is cleaned like any other",
                  MetadataFacts(["a.mp4": ["2016", "2016", "  "]]).names(for: "a.mp4") == ["2016"])
        }

        // --- the one line the app says about it -------------------------------------
        do {
            let summary = MetadataSplit.Summary(
                date: Date(timeIntervalSince1970: 0), moved: 3838, videos: 3045,
                names: ["1080p", "2015", "2016", "2017", "May 2016"])
            check("the sentence names the count, the names and the day",
                  summary.sentence.contains("3838 readings")
                    && summary.sentence.contains("1080p, 2015, 2016 and 2 more")
                    && summary.sentence.contains("3045 videos")
                    && summary.sentence.contains("1 Jan 1970"),
                  summary.sentence)
            check("...and says the tags were not touched",
                  summary.sentence.contains("Your tags are unchanged"))
            let data = try! JSONEncoder().encode(summary)
            check("a summary survives a round trip",
                  (try? JSONDecoder().decode(MetadataSplit.Summary.self, from: data)) == summary)
        }

        // --- the live library, when asked -------------------------------------------
        //
        // Nothing here writes: the file named is read, split in memory and
        // reported. It is how the rule met the real 3,595-video store before the
        // migration was allowed to run on it.
        if let path = ProcessInfo.processInfo.environment["FVP_REAL_TAGS"], !path.isEmpty {
            print("\n--- \(path) ---")
            guard let data = FileManager.default.contents(atPath: path),
                  let stored = try? JSONDecoder().decode([String: [String]].self, from: data)
            else {
                check("the file named by FVP_REAL_TAGS decodes", false, path)
                print(failures == 0 ? "\nall metadata fact checks pass" : "\n\(failures) FAILURES")
                exit(failures == 0 ? 0 : 1)
            }
            let report = MetadataSplit.separate(tags: stored)
            let before = stored.values.reduce(0) { $0 + $1.count }
            let after = report.tags.values.reduce(0) { $0 + $1.count }
                + report.facts.values.reduce(0) { $0 + $1.count }
            print("videos            \(stored.count)")
            print("tag entries       \(before)")
            print("readings moved    \(report.moved) entries off \(report.videos) videos")
            print("tags left         \(after - report.moved) entries")
            print("distinct readings \(report.names.count)")
            let counts = Dictionary(grouping: report.facts.values.flatMap { $0 },
                                    by: { $0 }).mapValues { $0.count }
            for name in report.names.prefix(40) {
                print("  \(name.padding(toLength: 28, withPad: " ", startingAt: 0))\(counts[name] ?? 0)")
            }
            if report.names.count > 40 { print("  … and \(report.names.count - 40) more") }
            check("no entry is lost in the real library", before == after, "\(before) → \(after)")
            check("nothing left in the tags is a reading",
                  report.tags.values.flatMap { $0 }.allSatisfy { !TagKinds.isFileFact($0) })
            check("every name moved is a reading the store may hold",
                  report.names.allSatisfy { TagKinds.isFileFact($0) })
        }

        print(failures == 0 ? "\nall metadata fact checks pass" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
