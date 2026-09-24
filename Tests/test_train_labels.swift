@testable import FVPModel
import Foundation

// Phase D gate tests: the labelled-example shape the train command receives,
// checked the same way the app builds it — suggestion verdicts in, ignored
// verdicts out, and a tag that lacks a class is refused by the gate numbers
// mirrored from the engine (TRAIN heads need both).

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : " — " + detail))
    if !ok { failures += 1 }
}

// Mirrors SuggestionStore.labelledExamples' contract on plain data.
struct Example { let key: String; let tag: String; let accepted: Bool }

func group(_ examples: [Example]) -> [String: [String: Bool]] {
    var labels: [String: [String: Bool]] = [:]
    for e in examples { labels[e.tag, default: [:]][e.key] = e.accepted }
    return labels
}

let examples: [Example] = [
    Example(key: "/v/a.mp4", tag: "beach", accepted: true),
    Example(key: "/v/b.mp4", tag: "beach", accepted: true),
    Example(key: "/v/c.mp4", tag: "beach", accepted: true),
    Example(key: "/v/d.mp4", tag: "beach", accepted: true),
    Example(key: "/v/e.mp4", tag: "beach", accepted: false),
    Example(key: "/v/f.mp4", tag: "beach", accepted: false),
    Example(key: "/v/g.mp4", tag: "beach", accepted: false),
    Example(key: "/v/h.mp4", tag: "beach", accepted: false),
    // a tag with only positives
    Example(key: "/v/a.mp4", tag: "solo", accepted: true),
    Example(key: "/v/b.mp4", tag: "solo", accepted: true),
    Example(key: "/v/c.mp4", tag: "solo", accepted: true),
    Example(key: "/v/d.mp4", tag: "solo", accepted: true),
    // a video that ruled on two tags keeps both lessons
    Example(key: "/v/a.mp4", tag: "outdoor", accepted: false),
]

let labels = group(examples)
check("grouping keeps one row per tag", labels.count == 3, "\(labels.keys.sorted())")
check("positives and negatives both land",
      (labels["beach"]?.values.filter { $0 }.count) == 4
      && (labels["beach"]?.values.filter { !$0 }.count) == 4,
      "\(labels["beach"] ?? [:])")
check("one video can hold labels for several tags",
      labels["beach"]?["/v/a.mp4"] == true && labels["outdoor"]?["/v/a.mp4"] == false,
      "\(labels["outdoor"] ?? [:])")

// The engine's gate (TRAINED_HEADS_MIN_POS/REJ), mirrored: refuse without both.
func fits(_ perVideo: [String: Bool], minPos: Int, minRej: Int) -> Bool {
    let pos = perVideo.values.filter { $0 }.count
    let rej = perVideo.values.filter { !$0 }.count
    return pos >= minPos && rej >= minRej
}
check("beach clears the both-classes gate", fits(labels["beach"] ?? [:], minPos: 4, minRej: 4))
check("solo is refused (no negatives)", !fits(labels["solo"] ?? [:], minPos: 4, minRej: 4))
check("outdoor is refused (not enough examples)",
      !fits(labels["outdoor"] ?? [:], minPos: 4, minRej: 4))

// The app sends frame hashes keyed the same share-relative way; a video the
// store has no frames for must map to an empty list, never a crash.
let storeFrames: [String: [String]] = ["/v/a.mp4": ["h1", "h2"]]
var frameHashes: [String: [String]] = [:]
for key in Set(labels.values.flatMap { $0.keys }) {
    frameHashes[key] = storeFrames[key] ?? []
}
check("hash lookup defaults to empty, not nil", frameHashes["/v/e.mp4"] == []
      && frameHashes["/v/a.mp4"] == ["h1", "h2"])

// TagSuggestion carries its provenance; older payloads decode without it.
struct TagSuggestion: Codable, Equatable {
    let tag: String
    let confidence: Double
    let frames: Int
    var source: String?
}
let decoder = JSONDecoder()
let old = try! decoder.decode(TagSuggestion.self,
    from: Data(#"{"tag":"beach","confidence":0.06,"frames":3}"#.utf8))
check("legacy suggestion decodes, source nil", old.source == nil && old.tag == "beach")
let new = try! decoder.decode(TagSuggestion.self,
    from: Data(#"{"tag":"solo","confidence":0.9,"frames":5,"source":"trained"}"#.utf8))
check("trained suggestion keeps its source", new.source == "trained")

print(failures == 0 ? "ALL PASS" : "\(failures) FAIL")
exit(failures == 0 ? 0 : 1)
