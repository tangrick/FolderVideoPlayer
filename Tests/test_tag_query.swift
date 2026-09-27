// Several library names combined into one playlist — the ⌘-click query in the
// library panel.
//
// What is proved:
//
//   1. Any is the union, All the intersection, an empty query picks nothing;
//   2. names compare case-insensitively, and a name is held once;
//   3. the query's members come from the library the way a row's do — tags,
//      star ratings, named people (tags) and readings off the file alike —
//      and hidden videos never appear;
//   4. a renamed or deleted tag is pruned rather than left as an invisible
//      constraint that empties an All query;
//   5. the label reads the way the playlist is titled.
//
// Scratch root only: `Paths.support` is redirected before any store is built.
//
// Run: Tests/run_tag_query.sh

@testable import FVPModel
import Foundation

@main
struct TagQueryTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- 1 & 2. the rule, without a library -----------------------------------

        let a: Set = ["1", "2", "3"], b: Set = ["2", "3", "4"], c: Set = ["3", "5"]
        check("Any is the union", TagQuery.combine([a, b, c], .any) == ["1", "2", "3", "4", "5"])
        check("All is the intersection", TagQuery.combine([a, b, c], .all) == ["3"])
        check("no names pick nothing", TagQuery.combine([], .any).isEmpty && TagQuery.combine([], .all).isEmpty)
        check("one name is just that name", TagQuery.combine([a], .all) == a)

        var query = TagQuery()
        check("a new query matches Any", query.match == .any)
        query.toggle("Iceland")
        query.toggle("iceland")
        check("toggling the same name in another case takes it out", query.isEmpty)
        query.add("Iceland")
        query.add("ICELAND")
        query.add("  ")
        check("a name is held once, and a blank one not at all", query.names == ["Iceland"])
        check("contains ignores case", query.contains("iCeLaNd"))
        query.add("Singapore")
        check("names keep the order they were picked in", query.names == ["Iceland", "Singapore"])

        // --- 5. the label ---------------------------------------------------------

        check("Any reads as or", query.label == "Iceland or Singapore", query.label)
        query.match = .all
        check("All reads as and", query.label == "Iceland and Singapore", query.label)
        query.add("2016")
        check("three names read as a list", query.label == "Iceland, Singapore and 2016", query.label)
        check("one name is its own label", TagQuery(names: ["Beach"]).label == "Beach")

        // --- 3. against a library ---------------------------------------------------

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-tag-query-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch + "/media", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        Paths.support = scratch
        for name in ["a", "b", "c", "d", "e"] {
            try? Data(count: 10).write(to: URL(fileURLWithPath: "\(scratch)/media/\(name).mp4"))
        }
        let all = Scanner.scan(scratch + "/media")
        guard all.count == 5 else {
            print("FAIL the fixture did not scan to five videos — \(all)")
            exit(1)
        }
        let (pa, pb, pc, pd, pe) = (all[0], all[1], all[2], all[3], all[4])

        let library = Library()
        library.addTag("Iceland", to: [pa, pb])
        library.addTag("beach", to: [pb, pc])
        library.setRating(5, for: [pb, pd])
        library.addTag("Anna", to: [pc, pd])   // a named person IS a tag
        library.setFacts(["2016"], for: pb)
        library.setFacts(["2016"], for: pe)

        func members(_ names: [String], _ match: TagQuery.Match) -> [String] {
            library.paths(matching: TagQuery(names: names, match: match))
        }
        check("Any over two tags is their union",
              members(["Iceland", "beach"], .any) == [pa, pb, pc], "\(members(["Iceland", "beach"], .any))")
        check("All over two tags is their intersection", members(["Iceland", "beach"], .all) == [pb])
        check("names match tags case-insensitively", members(["ICELAND", "Beach"], .all) == [pb])
        let favorite = starTag(5)
        check("a star rating combines like a tag",
              members([favorite, "Iceland"], .all) == [pb], "\(members([favorite, "Iceland"], .all))")
        check("a person combines like a tag", members(["Anna", favorite], .all) == [pd])
        check("a reading off the file combines like a tag",
              members(["2016", "beach"], .any) == [pb, pc, pe], "\(members(["2016", "beach"], .any))")
        check("a reading and a tag intersect", members(["2016", "Iceland"], .all) == [pb])
        check("a name nothing carries empties an All query", members(["Iceland", "Nowhere"], .all).isEmpty)
        check("...and adds nothing to an Any query", members(["Iceland", "Nowhere"], .any) == [pa, pb])

        _ = library.hide([pb])
        check("a hidden video never appears through Any",
              !members(["Iceland", "beach", "2016"], .any).contains(pb))
        check("...nor through All", members(["Iceland", "beach"], .all).isEmpty)
        _ = library.unhide([pb])
        check("unhiding brings it back", members(["Iceland", "beach"], .all) == [pb])

        // --- 4. rename and delete ---------------------------------------------------

        var live = TagQuery(names: ["Iceland", "beach", "2016"], match: .all)
        library.renameTag("beach", to: "Seaside")
        live.prune { library.count(anyName: $0) > 0 || !library.pathsCarrying($0).isEmpty }
        check("a renamed tag is pruned from the query", live.names == ["Iceland", "2016"], "\(live.names)")
        check("...so the query still answers", library.paths(matching: live) == [pb])
        library.deleteTag("Iceland")
        live.prune { !library.pathsCarrying($0).isEmpty }
        check("a deleted tag is pruned from the query", live.names == ["2016"], "\(live.names)")

        print(failures == 0 ? "\nall tag query checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
