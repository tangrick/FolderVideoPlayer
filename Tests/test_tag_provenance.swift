// Where a tag came from: read off the file, or guessed from the picture.
//
// The store is the whole point — a metadata tag is a FACT (the date in the
// file's header, the folder it sits in) and a suggested tag is a probability.
// Every check here is about not overclaiming: an empty store must say "I don't
// know" rather than "not metadata", and a hand-typed tag must never be
// promoted to a fact because a later scan proposed the same word.
//
// Pure: no FileManager, no models, no app.

import Foundation

@main
struct TagProvenanceTest {
    static func main() {
        var failures = 0
        func check(_ what: String, _ ok: Bool) {
            print(ok ? "ok   \(what)" : "FAIL \(what)")
            if !ok { failures += 1 }
        }

        // --- empty ------------------------------------------------------------------
        //
        // Every existing library starts here, and so does every device that has never
        // run a metadata scan. Nothing may be claimed.
        do {
            let p = TagProvenance()
            check("an empty store claims nothing", !p.isFromMetadata("2016", on: "a.mov"))
            check("...and knows it is empty", p.isEmpty)
            check("...and its vocabulary is empty", !p.isMetadataTagAnywhere("2016"))
            check("...and it lists no metadata tags for a video",
                  p.metadataTags(on: "a.mov", from: ["2016", "Beach"]).isEmpty)
        }

        // --- recording --------------------------------------------------------------
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016", "May 2016", "iPhone 7"], on: "a.mov")
            check("a recorded tag is from metadata", p.isFromMetadata("2016", on: "a.mov"))
            check("...so is another on the same video", p.isFromMetadata("iPhone 7", on: "a.mov"))
            check("a tag nobody recorded is not", !p.isFromMetadata("Beach", on: "a.mov"))

            // The same tag on a DIFFERENT video is a different claim. `Singapore`
            // written by GPS on one clip says nothing about a clip the user typed it on.
            check("the claim is per video, not per tag",
                  !p.isFromMetadata("2016", on: "b.mov"))

            // Order is the caller's, so the panel can draw them in the order it holds.
            check("metadataTags filters and keeps the caller's order",
                  p.metadataTags(on: "a.mov", from: ["Beach", "2016", "Cat", "iPhone 7"])
                    == ["2016", "iPhone 7"])
        }

        // --- additive ---------------------------------------------------------------
        //
        // A second scan of the same folder must not erase what the first one knew, and
        // re-recording the same tag must not double anything.
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016"], on: "a.mov")
            p.recordMetadata(["May 2016"], on: "a.mov")
            check("a second scan keeps the first scan's facts", p.isFromMetadata("2016", on: "a.mov"))
            check("...and adds its own", p.isFromMetadata("May 2016", on: "a.mov"))
            p.recordMetadata(["2016"], on: "a.mov")
            check("recording the same tag twice is idempotent",
                  p.metadataTags(on: "a.mov", from: ["2016", "May 2016"]) == ["2016", "May 2016"])

            // Empty input is a no-op, not an entry with nothing in it.
            var q = TagProvenance()
            q.recordMetadata([], on: "a.mov")
            check("recording nothing records nothing", q.isEmpty)
        }

        // --- the vocabulary ---------------------------------------------------------
        //
        // The tag list has no single video to ask about. "Ever written by the scan"
        // is the right question there, and it is deliberately looser than the per-video
        // one.
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016"], on: "a.mov")
            check("a tag the scan ever wrote is in the vocabulary", p.isMetadataTagAnywhere("2016"))
            check("a tag it never wrote is not", !p.isMetadataTagAnywhere("Beach"))
            // Looser on purpose: typing `Singapore` by hand on one video does not stop
            // the GPS-written `Singapore` on two hundred others from being a fact.
            check("the vocabulary is library-wide, not per video",
                  p.isMetadataTagAnywhere("2016") && !p.isFromMetadata("2016", on: "b.mov"))
        }

        // --- moving and forgetting --------------------------------------------------
        //
        // A repaired or renamed file must not silently lose the fact that its date tag
        // is a fact — that would quietly downgrade a fact to a guess.
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016"], on: "old.mov")
            p.move(from: "old.mov", to: "new.mov")
            check("provenance follows a rename", p.isFromMetadata("2016", on: "new.mov"))
            check("...and does not stay behind", !p.isFromMetadata("2016", on: "old.mov"))

            p.forget("new.mov")
            check("forgetting a video drops its provenance", !p.isFromMetadata("2016", on: "new.mov"))

            // Moving a video nobody recorded is not an error and invents nothing.
            var q = TagProvenance()
            q.move(from: "ghost.mov", to: "other.mov")
            check("moving an unknown video invents nothing", q.isEmpty)
        }

        // --- round trip -------------------------------------------------------------
        //
        // The file is written to disk, so it must survive a decode — including the
        // vocabulary, which is derived rather than stored and so is the part most
        // likely to come back wrong.
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016", "Singapore"], on: "a.mov")
            p.recordMetadata(["4K"], on: "b.mov")
            let data = try! JSONEncoder().encode(p)
            var back = try! JSONDecoder().decode(TagProvenance.self, from: data)
            check("a decoded store keeps its per-video facts",
                  back.isFromMetadata("Singapore", on: "a.mov"))
            check("...and the other video's", back.isFromMetadata("4K", on: "b.mov"))
            check("...and claims nothing extra", !back.isFromMetadata("Beach", on: "a.mov"))

            // The vocabulary is rebuilt, not trusted from the file: a hand-edited or
            // partial JSON must not leave it disagreeing with the entries.
            back.recordMetadata([], on: "c.mov")
            let rebuilt = TagProvenance.rebuilt(back)
            check("the vocabulary is rebuilt from the entries",
                  rebuilt.isMetadataTagAnywhere("Singapore")
                    && rebuilt.isMetadataTagAnywhere("4K")
                    && !rebuilt.isMetadataTagAnywhere("Beach"))
        }

        // --- what a person may apply by hand --------------------------------
        //
        // The rule: a metadata tag is READ off the file, so a human sticking
        // one on by hand would be stating something false about the file. The
        // tag itself is untouched — it stays on its videos, stays searchable,
        // stays in the sidebar. Only the OFFER is withdrawn.
        do {
            var p = TagProvenance()
            p.recordMetadata(["2016", "iPhone 7"], on: "a.mov")
            let all = ["2016", "Beach", "iPhone 7", "Bob Meyer"]
            let offered = all.filter { !p.isMetadataTagAnywhere($0) }
            check("a date tag is not offered for hand-tagging",
                  !offered.contains("2016"))
            check("nor is a camera tag", !offered.contains("iPhone 7"))
            check("an ordinary tag still is", offered.contains("Beach"))
            check("...and so does a person", offered.contains("Bob Meyer"))
            check("exactly two survive", offered.count == 2)

            // The withdrawal is from the OFFER list only. Nothing is deleted:
            // the tag is still on the video and still readable.
            check("the metadata tag is still ON its video",
                  p.isFromMetadata("2016", on: "a.mov"))
            check("...and still listed as a fact about it",
                  p.metadataTags(on: "a.mov", from: all) == ["2016", "iPhone 7"])
        }

        print(failures == 0 ? "\nall tag provenance checks pass" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)

    }
}
