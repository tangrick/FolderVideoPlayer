// The face look-alike search: "which other videos show this person?"
//
// The bug this exists to stop is not a crash — it is a plausible list. Pressing
// Find Look-alikes on a person tag used to rank by the whole CLIP frame, so a
// person filmed at waterfalls was answered with waterfalls, and the answer
// looked like an answer (2026-09-20, the maintainer's own library). Ranking on
// faces has its own set of plausible-but-wrong: a MEAN of a person's vectors
// (which resembles nobody once they have been photographed from two angles), a
// missing vector read as a zero one (a "0% match" is a face nobody looked at,
// not a face that is not theirs), a bar that is not the one the suggestion pass
// uses (so the chips and this list disagree about who is in a video), a
// coverage count that quietly ignores the videos nobody has scanned, and a
// limit that truncates the SEARCH instead of the ranking.
//
// No fixture and no engine parity: engine.py has no command for this — it is
// the app's own question, built out of the face cache the engine does own.
//
// Run: Tests/run_face_look_alikes.sh

import Foundation

@main
struct FaceLookAlikesTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        // Unit vectors in the plane, so a cosine is a rotation and every score
        // below is one the reader can check by hand: cos 0° = 1, cos 60° = 0.5,
        // cos 72.6° ≈ 0.299 (just under the bar), cos 90° = 0.
        func face(_ degrees: Double) -> [Float] {
            let r = degrees * .pi / 180
            return [Float(cos(r)), Float(sin(r))]
        }
        let vectors: [String: [Float]] = [
            "self":      face(0),        // the person's own bound face
            "profile":   face(80),       // ...and them again, side on
            "same":      face(60),       // 0.50 against `self`
            "sideOn":    face(85),       // 0.09 to `self`, 0.996 to `profile`
            "barely":    face(66.38),    // 0.4007 — over the bar
            "justUnder": face(66.5),     // 0.3987 — under it
            "oldBar":    face(72.5),     // 0.3007 — over the ENGINE's bar only
            "stranger":  face(90),       // 0.0
        ]
        var reads: [String: Int] = [:]
        func read(_ hash: String) -> [Float]? {
            reads[hash, default: 0] += 1
            return vectors[hash]        // an unknown hash is a face with no vector
        }
        // What the person has bound. Most of the checks below use ONE face, so
        // a score is a single cosine the reader can see; the two-angle set is
        // used only where having two is the point (it is deliberately wide —
        // 0° and 80° between them cover most of the plane, which is exactly why
        // a second bound face finds people the first cannot).
        let bound = [vectors["self"]!]
        let twoAngles = [vectors["self"]!, vectors["profile"]!]

        // --- the ranking ------------------------------------------------------

        // "same" is in two videos, which is also the read-once check below.
        let index: [String: [String]] = [
            "same":      ["a/one.mov", "a/two.mov"],
            "barely":    ["b/three.mov"],
            "justUnder": ["b/four.mov"],
            "stranger":  ["b/five.mov"],
            "pruned":    ["b/six.mov"],          // a face whose .f32 is gone
        ]
        let analysed = Set(["a/one.mov", "a/two.mov", "b/three.mov", "b/four.mov",
                            "b/five.mov", "b/six.mov", "c/never-scanned.mov"])
        reads = [:]
        let out = FaceLookAlikes.rank(person: "Quincy",
                                      references: bound,
                                      faceVideos: index,
                                      analysed: analysed,
                                      vector: read)

        checkEqual("only the videos over the bar are offered",
                   out.candidates.map(\.key), ["a/one.mov", "a/two.mov", "b/three.mov"])
        checkEqual("...best first", out.candidates.first?.score, 0.5)
        checkEqual("...and the one barely over it is last, at its own score",
                   out.candidates.last?.score, 0.4007)
        check("a face under the bar is not offered",
              !out.candidates.contains { $0.key == "b/four.mov" })
        check("a stranger is not offered",
              !out.candidates.contains { $0.key == "b/five.mov" })
        check("a face with no vector is skipped, not scored zero",
              !out.candidates.contains { $0.key == "b/six.mov" })
        checkEqual("a face seen in two videos is read once, not once per video",
                   reads["same"], 1)
        checkEqual("every video a face pass has looked at is counted as scanned",
                   out.scanned, 6)
        checkEqual("...and the one nobody has scanned is counted, not silently missed",
                   out.unscanned, 1)
        checkEqual("a ranking that found somebody offers no reason", out.reason, nil)

        // The best of the person's faces decides, never their mean. `sideOn` is
        // 0.09 from the face they were added with and 0.996 from their profile
        // — the mean of the two references would put it under the bar.
        let angled = FaceLookAlikes.rank(person: "Quincy",
                                         references: twoAngles,
                                         faceVideos: ["sideOn": ["d/angled.mov"]],
                                         analysed: ["d/angled.mov"],
                                         vector: read)
        checkEqual("a second bound face finds them at an angle the first cannot",
                   angled.candidates.map(\.key), ["d/angled.mov"])
        check("...at the best of their faces, not the mean of them",
              (angled.candidates.first?.score ?? 0) > 0.99)
        checkEqual("one bound face is a search, where a scene prototype needs two",
                   FaceLookAlikes.rank(person: "Quincy",
                                       references: [vectors["self"]!],
                                       faceVideos: ["same": ["a/one.mov"]],
                                       analysed: ["a/one.mov"],
                                       vector: read).candidates.count, 1)

        // --- the bar is the suggestion pass's bar, and it is NOT the engine's -

        // Two thresholds, on purpose. 0.30 is engine.py's, for comparing two
        // crops once, and the face-registry gate asserts it. A video offers
        // every face it has to that comparison, so the per-video question
        // needs its own, measured bar (2026-09-20: at 0.30 a fifth of the
        // library matched anybody with a face bound to them).
        checkEqual("the engine's one-to-one bar is untouched",
                   SFaceEmbedder.matchCosine, 0.30)
        checkEqual("the per-video bar is the measured one",
                   SFaceEmbedder.videoMatchCosine, 0.40)
        check("...and the two are not the same number",
              SFaceEmbedder.videoMatchCosine > SFaceEmbedder.matchCosine)
        let onTheBar = FaceLookAlikes.rank(person: "Quincy",
                                           references: [vectors["self"]!],
                                           faceVideos: ["barely": ["in.mov"],
                                                        "justUnder": ["out.mov"]],
                                           analysed: ["in.mov", "out.mov"],
                                           vector: read)
        checkEqual("0.4007 is in and 0.3987 is out — both were checked",
                   onTheBar.candidates.map(\.key), ["in.mov"])
        // A face that would have been offered under the engine's bar is not
        // offered now — the whole point of the change — but the caller can
        // still ask for that bar explicitly, which is what keeps the port and
        // the app's own judgement separable.
        let underNewBar = FaceLookAlikes.rank(person: "Quincy",
                                              references: [vectors["self"]!],
                                              faceVideos: ["oldBar": ["was-offered.mov"]],
                                              analysed: ["was-offered.mov"],
                                              vector: read)
        checkEqual("a 0.3007 face is no longer a match", underNewBar.candidates.count, 0)
        let atEngineBar = FaceLookAlikes.rank(person: "Quincy",
                                              references: [vectors["self"]!],
                                              faceVideos: ["oldBar": ["was-offered.mov"]],
                                              analysed: ["was-offered.mov"],
                                              vector: read,
                                              threshold: SFaceEmbedder.matchCosine)
        checkEqual("...unless the caller asks for the engine's bar by name",
                   atEngineBar.candidates.map(\.key), ["was-offered.mov"])

        // --- refusals say what to do ------------------------------------------

        let unbound = FaceLookAlikes.rank(person: "Nobody",
                                          references: [],
                                          faceVideos: index,
                                          analysed: analysed,
                                          vector: read)
        checkEqual("a person with no face bound gets no candidates",
                   unbound.candidates.count, 0)
        check("...and is told to add one, rather than shown an empty list",
              unbound.reason?.contains("Add Face") ?? false)

        let nothingScanned = FaceLookAlikes.rank(person: "Quincy",
                                                 references: bound,
                                                 faceVideos: [:],
                                                 analysed: ["a/one.mov"],
                                                 vector: read)
        check("a library nobody has scanned says so, not 'no match'",
              nothingScanned.reason?.contains("scanned for faces yet") ?? false)
        checkEqual("...and counts what is waiting", nothingScanned.unscanned, 1)

        let noMatch = FaceLookAlikes.rank(person: "Quincy",
                                          references: bound,
                                          faceVideos: ["stranger": ["b/five.mov"]],
                                          analysed: ["b/five.mov"],
                                          vector: read)
        check("a real miss says how much was looked at",
              noMatch.reason?.contains("1 scanned for faces") ?? false)

        // --- the limit truncates the ranking, not the search ------------------

        let many = FaceLookAlikes.rank(person: "Quincy",
                                       references: bound,
                                       faceVideos: ["same": ["a/one.mov", "a/two.mov"],
                                                    "barely": ["b/three.mov"]],
                                       analysed: analysed,
                                       vector: read,
                                       limit: 1)
        checkEqual("the limit truncates the list", many.candidates.count, 1)
        checkEqual("...taking the strongest", many.candidates.first?.key, "a/one.mov")
        checkEqual("...and the counts still describe the whole search",
                   many.scanned, 3)
        checkEqual("...including what was never scanned", many.unscanned, 4)

        // Ties: the same library must answer the same way twice.
        let tied = FaceLookAlikes.rank(person: "Quincy",
                                       references: bound,
                                       faceVideos: ["same": ["z/last.mov", "a/first.mov"]],
                                       analysed: ["z/last.mov", "a/first.mov"],
                                       vector: read)
        checkEqual("equal scores are ordered by key, not by dictionary luck",
                   tied.candidates.map(\.key), ["a/first.mov", "z/last.mov"])

        print(failures == 0 ? "ALL PASS face look-alikes" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
