import Foundation
import CoreML

// Plain script, no framework — the same habit as the PyObjC build's tests.
// Everything here runs against a temporary folder; nothing touches a real
// media library or a real Application Support directory.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : " — " + detail))
    if !ok { failures += 1 }
}

let root = CommandLine.arguments[1]

// -- the scan --------------------------------------------------------------

let found = Scanner.scan(root)
check("scan finds every video", found.count == 4, "\(found.count)")
let names = found.map { ($0 as NSString).lastPathComponent }
check("dot-directories are skipped", !names.contains { $0.hasPrefix(".") })
check("non-video files are skipped", !names.contains("notes.txt"))
check("clip2 sorts before clip10",
      names.firstIndex(of: "clip2.mp4")! < names.firstIndex(of: "clip10.mp4")!,
      names.joined(separator: ","))
check("under() answers about a subfolder",
      Scanner.under(root + "/clips/copy-of-clip1.mp4", [root + "/clips"]))
check("under() is not fooled by a shared prefix",
      !Scanner.under(root + "/clipsx/a.mp4", [root + "/clips"]))

// -- fingerprints and the sets they make -----------------------------------

var index: [String: PrintEntry] = [:]
var sizes: [String: Int64] = [:]
for path in found {
    let attrs = try! FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs[.size] as! NSNumber).int64Value
    sizes[path] = size
    index[path] = PrintEntry(size: size, mtime: 0,
                             fp: Fingerprints.fingerprint(path, size: size)!,
                             full: nil, seen: 0)
}
check("the size sieve keeps only what shares a size",
      Fingerprints.sizeCandidates(sizes).count == 2,
      "\(Fingerprints.sizeCandidates(sizes).count)")

let groups = Fingerprints.duplicateGroups(index)
check("one set of duplicates", groups.count == 1, "\(groups.count)")
check("the set is the copy and its original",
      groups.first?.map { ($0 as NSString).lastPathComponent }.sorted()
        == ["clip1.mp4", "copy-of-clip1.mp4"], "\(groups)")

var split = index
split[groups[0][0]]!.full = "aaaa"
split[groups[0][1]]!.full = "bbbb"
check("full hashes that disagree beat the fingerprint",
      Fingerprints.duplicateGroups(split).isEmpty)

var agreed = index
agreed[groups[0][0]]!.full = "same"
agreed[groups[0][1]]!.full = "same"
check("a verified set survives verifiedOnly",
      Fingerprints.duplicateGroups(agreed, verifiedOnly: true).count == 1)
check("an unread set is withheld from verifiedOnly",
      Fingerprints.duplicateGroups(index, verifiedOnly: true).isEmpty)

// The sort keys the playlist builds once per path must order exactly as
// comparing the strings does — the whole point is that it is only faster.
let messy = ["clip10.mp4", "Clip2.mp4", "a 3.mp4", "a 20.mp4", "B.mp4", "b1.mp4",
             "10.mp4", "2.mp4", "zz.mp4", "clip2.mp4"]
check("key-based sorting matches string sorting",
      messy.sorted { naturalLess($0, $1) }
        == messy.map { (naturalParts($0), $0) }.sorted { naturalLess($0.0, $1.0) }.map(\.1),
      "\(messy.map { (naturalParts($0), $0) }.sorted { naturalLess($0.0, $1.0) }.map(\.1))")

// -- keys ------------------------------------------------------------------

check("a file on a share is keyed share-relative",
      Paths.tagKey("/Volumes/nas/a.mp4") == "nas/a.mp4")
check("a local file keeps its absolute path",
      Paths.tagKey("/Users/x/a.mp4") == "/Users/x/a.mp4")
check("keys round trip",
      Paths.tagPath(Paths.tagKey("/Volumes/nas/a.mp4")) == "/Volumes/nas/a.mp4")
check("the volume is the mount, not the folder",
      Paths.volumeOf("/Volumes/nas/a/b.mp4") == "/Volumes/nas")

// -- the words the UI says -------------------------------------------------

check("clock under an hour", clock(247) == "4:07", clock(247))
check("clock over an hour", clock(3750) == "1:02:30", clock(3750))
check("humanSize rounds like Finder", humanSize(1_400_000_000) == "1.4 GB",
      humanSize(1_400_000_000))
check("humanBytes counts in binary", humanBytes(1024 * 1024) == "1.0 MB",
      humanBytes(1024 * 1024))
check("whenWords for something just done", whenWords(Date().timeIntervalSince1970) == "just now")
check("tags collapse case and whitespace",
      parseTags(" Beach , beach ;  Sun set ") == ["Beach", "Sun set"],
      "\(parseTags(" Beach , beach ;  Sun set "))")
check("a name becomes one slug however it is spelled",
      slug("Anne Marie") == slug("anne-marie"))

// -- publishing never empties what it cannot replace ------------------------
//
// The guard that matters most: a device holding no tags for a share must not
// overwrite that share's copy with nothing. This is the path that runs at every
// launch. (ProfileLock is not exercised here — it writes to the login keychain,
// which a test has no business touching.)

let shareRoot = NSTemporaryDirectory() + "fvp-share-\(UUID().uuidString)"
let volumes = shareRoot + "/Volumes/"
try! FileManager.default.createDirectory(atPath: volumes + "nas",
                                         withIntermediateDirectories: true)
Paths.volumes = volumes
let myFile = ".FolderVideoPlayer/quincy/tags-mac.json"
let published = volumes + "nas/" + myFile

// A real publish writes.
var outcome = Library.write(["nas": ["clips/a.mp4": ["Beach"]]], as: myFile)
check("publishing writes the share's copy", outcome.written.first?.1 == 1, "\(outcome)")
check("...and it is readable back",
      JSONStore.load(published, fallback: [String: [String]]())["clips/a.mp4"] == ["Beach"])

// A publish with nothing in it leaves that copy alone.
outcome = Library.write([:], as: myFile)
check("an empty publish writes nothing", outcome.written.isEmpty, "\(outcome)")
check("...and the share's copy survives",
      JSONStore.load(published, fallback: [String: [String]]())["clips/a.mp4"] == ["Beach"])

// Same when the share is named but its entries are gone.
outcome = Library.write(["nas": [:]], as: myFile)
check("an emptied share is left alone", outcome.written.isEmpty, "\(outcome)")
check("...and its tags are still there",
      JSONStore.load(published, fallback: [String: [String]]()).count == 1)
check("...and the reason says so",
      outcome.skipped.first?.1.contains("left alone") == true, "\(outcome.skipped)")

try? FileManager.default.removeItem(atPath: shareRoot)

// -- sorting needs the stats it sorts on --------------------------------------
//
// Date Added and File Size read only what has already been stat-ed. Sorting
// before those are in had every file tie on zero and fall through to the name,
// so the list sorted by name while saying it sorted by size — and Next, which
// walks the playlist, followed that wrong order.

Paths.support = NSTemporaryDirectory() + "fvp-sort-\(UUID().uuidString)"
let sortLibrary = await Library()
let bySize = [root + "/clip2.mp4",       // 150000 bytes
              root + "/clip10.mp4",      // 170000
              root + "/clip1.mp4"]       // 200000

await MainActor.run {
    sortLibrary.playlistSort = .size
    sortLibrary.sortDescending = false
}
let cold = await MainActor.run { sortLibrary.sorted(bySize) }
check("cold, a size sort cannot know the sizes",
      cold.map { ($0 as NSString).lastPathComponent }
        == ["clip1.mp4", "clip2.mp4", "clip10.mp4"],
      "\(cold.map { ($0 as NSString).lastPathComponent })")

await sortLibrary.warmStats(bySize)
let warm = await MainActor.run { sortLibrary.sorted(bySize) }
check("warmed, it sorts smallest first",
      warm.map { ($0 as NSString).lastPathComponent }
        == ["clip2.mp4", "clip10.mp4", "clip1.mp4"],
      "\(warm.map { ($0 as NSString).lastPathComponent })")

await MainActor.run { sortLibrary.sortDescending = true }
let down = await MainActor.run { sortLibrary.sorted(bySize) }
check("...and largest first the other way",
      down.map { ($0 as NSString).lastPathComponent }
        == ["clip1.mp4", "clip10.mp4", "clip2.mp4"],
      "\(down.map { ($0 as NSString).lastPathComponent })")
try? FileManager.default.removeItem(atPath: Paths.support)

// -- two writes at once ----------------------------------------------------
//
// Seven things can publish, and two landing together is ordinary. When the
// scratch file was named after the process alone they shared one path, wrote
// through each other, and the share answered "Resource busy".

let raceDir = NSTemporaryDirectory() + "fvp-race-\(UUID().uuidString)"
try! FileManager.default.createDirectory(atPath: raceDir, withIntermediateDirectories: true)
let racePath = raceDir + "/tags.json"

let writeFailures = await withTaskGroup(of: String?.self) { group -> [String] in
    for n in 0..<12 {
        group.addTask { JSONStore.write(racePath, ["video\(n).mp4": ["Beach"]]) }
    }
    var out: [String] = []
    for await result in group { if let result { out.append(result) } }
    return out
}
check("twelve writes at once all land", writeFailures.isEmpty,
      writeFailures.joined(separator: "; "))
check("...and the file is left readable",
      JSONStore.load(racePath, fallback: [String: [String]]()).count == 1)
check("...leaving no scratch files behind",
      (try! FileManager.default.contentsOfDirectory(atPath: raceDir))
        .filter { $0.hasSuffix(".tmp") }.isEmpty)
try? FileManager.default.removeItem(atPath: raceDir)

// -- the little JSON files -------------------------------------------------

let tmp = NSTemporaryDirectory() + "fvp-test-\(UUID().uuidString).json"
JSONStore.save(tmp, ["a": [1.0, 2.0]])
check("json round trips", JSONStore.load(tmp, fallback: [String: [Double]]())["a"] == [1.0, 2.0])
check("a missing file falls back", JSONStore.load("/nope/nothing.json", fallback: 7) == 7)
try? FileManager.default.removeItem(atPath: tmp)

let mangled = NSTemporaryDirectory() + "fvp-bad-\(UUID().uuidString).json"
try? "{not json at all".write(toFile: mangled, atomically: true, encoding: .utf8)
check("a mangled file falls back rather than throwing",
      JSONStore.load(mangled, fallback: [String: [String]]()).isEmpty)
try? FileManager.default.removeItem(atPath: mangled)

// -- pinned drag-reorder ----------------------------------------------------

let abcd = ["A", "B", "C", "D"]
check("drag first onto third lands at third",
      Library.reordered(abcd, from: 0, to: 2) == ["B", "C", "A", "D"])
check("drop middle on last row moves it to the end",
      Library.reordered(abcd, from: 1, to: 3) == ["A", "C", "D", "B"])
check("drop last onto first row moves it to the top",
      Library.reordered(abcd, from: 3, to: 0) == ["D", "A", "B", "C"])
check("dropping a row on itself changes nothing",
      Library.reordered(abcd, from: 2, to: 2) == abcd)
check("a source outside the list changes nothing",
      Library.reordered(abcd, from: 7, to: 1) == abcd)
check("a negative destination clamps to the top",
      Library.reordered(abcd, from: 3, to: -2) == ["D", "A", "B", "C"])
check("a single pinned folder stays put",
      Library.reordered(["Z"], from: 0, to: 0) == ["Z"])

// -- auto-tag rules ---------------------------------------------------------

let autoRoot = "/Volumes/media/Quincy/video"
let cruiseClip = autoRoot + "/Cruise/2024/Day2/IMG_0001.MOV"
check("folders between root and file, innermost first",
      AutoTagCore.folders(of: cruiseClip, under: autoRoot) == ["Day2", "2024", "Cruise"])
check("a video directly in the root has no folder of its own",
      AutoTagCore.folders(of: autoRoot + "/x.mp4", under: autoRoot).isEmpty)
check("folder tags cap at two levels",
      AutoTagCore.folderTags(of: cruiseClip, under: autoRoot, depth: 2) == ["Day2", "2024"])
check("folder tags are capped shallow when asked",
      AutoTagCore.folderTags(of: cruiseClip, under: autoRoot, depth: 1) == ["Day2"])
check("a direct child earns the root's own name",
      AutoTagCore.folderTags(of: autoRoot + "/x.mp4", under: autoRoot, depth: 2) == ["video"])

let may2024 = AutoTagCore.dateTags(ISO8601DateFormatter().date(from: "2024-05-04T10:00:00Z")!)
check("date tags carry the year", may2024.contains("2024"))
check("date tags carry the month", may2024.contains("May 2024"))
check("date tags ignore ancient files",
      AutoTagCore.dateTags(ISO8601DateFormatter().date(from: "1850-05-04T10:00:00Z")!).isEmpty)

check("apple's own make is dropped from the camera tag",
      AutoTagCore.cameraTag(make: "Apple", model: "iPhone 15 Pro") == "iPhone 15 Pro")
check("a real maker stays",
      AutoTagCore.cameraTag(make: "Samsung", model: "Galaxy S23") == "Samsung Galaxy S23")
check("no metadata, no camera tag", AutoTagCore.cameraTag(make: nil, model: nil) == nil)

check("4K earns 4K", AutoTagCore.qualityTags(width: 3840, height: 2160, fps: 30) == ["4K"])
check("1080p earns 1080p",
      AutoTagCore.qualityTags(width: 1920, height: 1080, fps: 60) == ["1080p"])
check("a vertical phone clip is still 1080p",
      AutoTagCore.qualityTags(width: 1080, height: 1920, fps: 30) == ["1080p"])
check("720p earns 720p",
      AutoTagCore.qualityTags(width: 1280, height: 720, fps: 30) == ["720p"])
check("480p earns 480p",
      AutoTagCore.qualityTags(width: 640, height: 480, fps: 30) == ["480p"])
check("4K240 earns 4K and slow-mo",
      AutoTagCore.qualityTags(width: 3840, height: 2160, fps: 240) == ["4K", "Slow-mo"])
check("tiny clips earn nothing", AutoTagCore.qualityTags(width: 320, height: 240, fps: 30).isEmpty)

let sg = AutoTagCore.parseISO6709("+01.2897+103.8501/")
check("ISO 6709 parses (Singapore)",
      sg != nil && abs(sg!.lat - 1.2897) < 0.0001 && abs(sg!.lon - 103.8501) < 0.0001)
let syd = AutoTagCore.parseISO6709("-33.86+151.21")
check("ISO 6709 parses southern latitudes",
      syd != nil && abs(syd!.lat + 33.86) < 0.0001)
check("garbage is not a location", AutoTagCore.parseISO6709("not-a-place") == nil)
check("an impossible latitude is refused",
      AutoTagCore.parseISO6709("+95.0+103.0") == nil)

check("auto-tags never overwrite and dedupe case-insensitively",
      AutoTagCore.merged(existing: ["Cruise"], adding: ["cruise", "4K"]) == ["Cruise", "4K"])
check("empty additions change nothing",
      AutoTagCore.merged(existing: ["Cruise"], adding: []) == ["Cruise"])

// -- moved-video scan -------------------------------------------------------

let scanLibrary = await Library()
await MainActor.run {
    scanLibrary.setTags(["Cruise", "4K"], for: "/Volumes/media/old/Beach.mp4")
    scanLibrary.setTags(["Family"], for: "/Volumes/media/misc/Recital.mp4")
}
// Beach.mp4 now lives one folder over; Recital.mp4 was deleted entirely.
let beachOld = Paths.tagKey("/Volumes/media/old/Beach.mp4")

var movedOK = false
var atNew: [String] = []
var atOld: [String] = []
await MainActor.run {
    movedOK = scanLibrary.moveTags(from: beachOld, to: "/Volumes/media/new/Beach.mp4")
    atNew = scanLibrary.tagsFor("/Volumes/media/new/Beach.mp4")
    atOld = scanLibrary.tagsFor("/Volumes/media/old/Beach.mp4")
}
check("moveTags carries the tags and drops the orphan key",
      movedOK && atNew == ["Cruise", "4K"] && atOld.isEmpty,
      "ok=\(movedOK) new=\(atNew) old=\(atOld)")

var mergedOK = false
var merged: [String] = []
await MainActor.run {
    scanLibrary.setTags(["Cruise", "4K"], for: "/Volumes/media/old/Beach.mp4")
    scanLibrary.setTags(["Trip"], for: "/Volumes/media/new/Beach.mp4")
    mergedOK = scanLibrary.moveTags(from: beachOld, to: "/Volumes/media/new/Beach.mp4")
    merged = scanLibrary.tagsFor("/Volumes/media/new/Beach.mp4")
}
check("moveTags into a tagged file merges instead of overwriting",
      mergedOK && merged == ["Trip", "Cruise", "4K"], "\(merged)")

let pick = [
    MovedCandidate(oldKey: "a/A.mp4", oldName: "A.mp4", oldFolder: "a",
                   newPath: "b/A.mp4", newFolder: "b", tagNames: ["t"]),
    MovedCandidate(oldKey: "a/A.mp4", oldName: "A.mp4", oldFolder: "a",
                   newPath: "c/A.mp4", newFolder: "c", tagNames: ["t"]),
    MovedCandidate(oldKey: "z/Z.mp4", oldName: "Z.mp4", oldFolder: "z",
                   newPath: "w/Z.mp4", newFolder: "w", tagNames: ["u"]),
]
check("select-all ticks one row per moved video, not per match",
      MovedScan.firstPerKey(pick) == [pick[0].id, pick[2].id])

// A lone name match repairs itself only when its size does not contradict
// the size fingerprinted for the missing file.
do {
    let orphans = [
        MovedOrphan(key: "a/same.mp4", name: "same.mp4", folder: "/V/a", tags: ["t"]),
        MovedOrphan(key: "a/other.mp4", name: "other.mp4", folder: "/V/a", tags: ["t"]),
        MovedOrphan(key: "a/unknown.mp4", name: "unknown.mp4", folder: "/V/a", tags: ["t"]),
        MovedOrphan(key: "a/two.mp4", name: "two.mp4", folder: "/V/a", tags: ["t"]),
        MovedOrphan(key: "a/gone.mp4", name: "gone.mp4", folder: "/V/a", tags: ["t"]),
    ]
    let places = [
        "same.mp4": ["/V/b/same.mp4"],
        "other.mp4": ["/V/b/other.mp4"],
        "unknown.mp4": ["/V/b/unknown.mp4"],
        "two.mp4": ["/V/b/two.mp4", "/V/c/two.mp4"],
    ]
    let recorded: [String: Int64] = ["a/same.mp4": 100, "a/other.mp4": 100, "a/two.mp4": 100]
    let sizes: [String: Int64] = ["/V/b/same.mp4": 100, "/V/b/other.mp4": 999,
                                  "/V/b/unknown.mp4": 5, "/V/b/two.mp4": 7, "/V/c/two.mp4": 100]
    let out = MovedScan.split(orphans, places: places, recordedSize: recorded) { path in
        (sizes[path], nil)
    }
    check("same-size lone match is repaired",
          out.fixes.contains { $0.oldKey == "a/same.mp4" && $0.sizeMatches == true })
    check("different-size lone match goes to review, not repaired",
          !out.fixes.contains { $0.oldKey == "a/other.mp4" }
          && out.ambiguous.contains { $0.oldKey == "a/other.mp4" && $0.sizeMatches == false })
    check("lone match with no recorded size is still repaired, marked name-only",
          out.fixes.contains { $0.oldKey == "a/unknown.mp4" && $0.sizeMatches == nil })
    check("several matches go to review with sizes compared",
          out.ambiguous.filter { $0.oldKey == "a/two.mp4" }.map(\.sizeMatches) == [false, true])
    check("no match is reported missing", out.gone.map(\.key) == ["a/gone.mp4"])
    check("the one same-size match is pre-picked",
          MovedScan.sizeMatchPerKey(out.ambiguous)
              == out.ambiguous.filter { $0.newPath == "/V/c/two.mp4" }.map(\.id))
}

// Two same-size matches are copies: neither is pre-picked.
do {
    let copies = [
        MovedCandidate(oldKey: "k", oldName: "A.mp4", oldFolder: "a", newPath: "b/A.mp4",
                       newFolder: "b", tagNames: [], sizeMatches: true),
        MovedCandidate(oldKey: "k", oldName: "A.mp4", oldFolder: "a", newPath: "c/A.mp4",
                       newFolder: "c", tagNames: [], sizeMatches: true),
    ]
    check("two same-size copies are left for the user", MovedScan.sizeMatchPerKey(copies).isEmpty)
}

// -- merging another device's tags must not bring back a moved path --------

do {
    let incoming: [(String, [String])] = [
        ("S/kept.mp4", ["Trip"]),        // already filed here: an ordinary edit
        ("S/old/moved.mp4", ["Trip"]),   // moved away on this Mac; file gone
        ("S/new.mp4", ["Cruise"]),       // new to this Mac, file present
        ("S/gone.mp4", []),              // an empty list for a path this Mac lacks
    ]
    let taken = Library.mergeable(incoming,
                                  known: ["S/kept.mp4", "S/new/moved.mp4"],
                                  present: ["S/new.mp4"]).map(\.0)
    check("merge keeps edits to paths already filed here", taken.contains("S/kept.mp4"))
    check("merge takes in a new path whose file exists", taken.contains("S/new.mp4"))
    check("merge does not resurrect a path whose file is gone",
          !taken.contains("S/old/moved.mp4") && !taken.contains("S/gone.mp4"))
}

// -- name index (cached lookups vs hunt) ------------------------------------

let idx: [String: [String]] = ["beach.mp4": ["old/Beach.mp4", "new/Beach.mp4"],
                               "recital.mp4": ["misc/Recital.mp4"]]
let (foundByName, hunt) = NameIndex.resolve(names: ["beach.mp4", "recital.mp4", "gone.mp4"],
                                            index: idx) { key in
    key != "old/Beach.mp4" && key != "misc/Recital.mp4"   // old spots are dead
}
check("index answers with the live spot only",
      foundByName["beach.mp4"] == ["new/Beach.mp4"])
check("dead entries push the name to the hunt list",
      hunt == ["recital.mp4", "gone.mp4"])
check("empty index hunts everything",
      NameIndex.resolve(names: ["a.mp4"], index: [:], exists: { _ in true }).hunt == ["a.mp4"])

// -- file operations: names, and tags following the file --------------------

let opsDir = NSTemporaryDirectory() + "fvp-ops-\(UUID().uuidString)"
let opsFrom = opsDir + "/from"
let opsTo = opsDir + "/to"
try! FileManager.default.createDirectory(atPath: opsFrom, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: opsTo, withIntermediateDirectories: true)

func makeClip(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: Data("video".utf8))
}

// freeName never overwrites: a taken name gets " (2)", then " (3)".
makeClip(opsTo + "/Beach.mp4")
let free2 = FileOps.freeName(in: opsTo, for: "Beach.mp4")
check("a taken name becomes “ (2)”",
      (free2 as NSString).lastPathComponent == "Beach (2).mp4",
      (free2 as NSString).lastPathComponent)
makeClip(free2)
let free3 = FileOps.freeName(in: opsTo, for: "Beach.mp4")
check("...and then “ (3)”",
      (free3 as NSString).lastPathComponent == "Beach (3).mp4",
      (free3 as NSString).lastPathComponent)
check("a free name is left alone",
      (FileOps.freeName(in: opsTo, for: "Untouched.mp4") as NSString).lastPathComponent
        == "Untouched.mp4")

// A tag becomes a folder name a file system will accept.
check("a slash in a tag cannot make a subfolder",
      FileOps.safeFolderName("Trips/2024") == "Trips-2024")
check("a colon is replaced too", FileOps.safeFolderName("Holiday: Bali") == "Holiday- Bali")
check("an ordinary tag is unchanged", FileOps.safeFolderName("Holiday") == "Holiday")
check("a blank tag still names a folder", FileOps.safeFolderName("   ") == "Tag")

// The AI look-alike scope: only folders the user has tagged in may be offered from.
let tagged = LookAlikes.taggedFolders(["/v/Holiday/a.mp4", "/v/Holiday/b.mp4", "/v/Work/c.mp4"])
check("a folder with a tagged video is offerable", tagged.contains("/v/Holiday"))
check("two tagged videos in one folder are one folder", tagged.count == 2)
check("an untagged neighbour in a tagged folder may be offered",
      LookAlikes.mayOffer("/v/Holiday/new.mp4", taggedFolders: tagged))
check("a video in a folder nothing is tagged in is never offered",
      !LookAlikes.mayOffer("/v/Never/new.mp4", taggedFolders: tagged))
check("a subfolder of a tagged folder is not itself tagged in",
      !LookAlikes.mayOffer("/v/Holiday/2024/new.mp4", taggedFolders: tagged))

// Moving carries the tags, the rating and the resume position with it.
Paths.support = NSTemporaryDirectory() + "fvp-ops-lib-\(UUID().uuidString)"
let opsLibrary = await Library()
let clipA = opsFrom + "/Holiday1.mp4"
makeClip(clipA)
await MainActor.run {
    opsLibrary.setTags(["Holiday"], for: clipA)
    opsLibrary.setRating(5, for: clipA)
    opsLibrary.progress[clipA] = 42.5
}

var movedReport = FileOps.Report()
await MainActor.run { movedReport = FileOps.move([clipA], into: opsTo, library: opsLibrary) }
let landedAt = opsTo + "/Holiday1.mp4"
check("a moved file lands in the destination",
      movedReport.done == [landedAt] && FileManager.default.fileExists(atPath: landedAt),
      "\(movedReport.done)")
check("...and the file has left the source",
      !FileManager.default.fileExists(atPath: clipA))
var tagsAfterMove: [String] = []
var oldTagsAfterMove: [String] = []
var resumeAfterMove: Double = 0
await MainActor.run {
    tagsAfterMove = opsLibrary.tagsFor(landedAt)
    oldTagsAfterMove = opsLibrary.tagsFor(clipA)
    resumeAfterMove = opsLibrary.resumePoint(landedAt)
}
check("moving carries the tags to the new path (5 stars IS the Favorite tag)",
      tagsAfterMove == ["Holiday", favoriteTag], "\(tagsAfterMove)")
check("...and leaves none behind on the old one", oldTagsAfterMove.isEmpty)
check("...and the resume position follows the file", resumeAfterMove == 42.5,
      "\(resumeAfterMove)")
var starsAfterMove = 0
await MainActor.run { starsAfterMove = opsLibrary.rating(landedAt) }
check("...and the star rating follows the file", starsAfterMove == 5,
      "\(starsAfterMove)")

// Moving into the folder it already lives in is refused, not duplicated.
var again = FileOps.Report()
await MainActor.run { again = FileOps.move([landedAt], into: opsTo, library: opsLibrary) }
check("moving a file where it already is changes nothing",
      again.done.isEmpty && again.skipped.count == 1, "\(again.summary)")

// Renaming keeps the extension when the new name omits one.
var renamed = FileOps.Report()
await MainActor.run { renamed = FileOps.rename(landedAt, to: "Bali Day One", library: opsLibrary) }
let renamedPath = opsTo + "/Bali Day One.mp4"
check("renaming without an extension keeps the old one",
      renamed.done == [renamedPath], "\(renamed.done)")
var tagsAfterRename: [String] = []
await MainActor.run { tagsAfterRename = opsLibrary.tagsFor(renamedPath) }
check("...and the tags follow the rename (Favorite rode along — it is the 5-star mark)",
      tagsAfterRename == ["Holiday", favoriteTag], "\(tagsAfterRename)")

// A rename onto a name already taken is refused rather than overwriting.
makeClip(opsTo + "/Taken.mp4")
var clash = FileOps.Report()
await MainActor.run { clash = FileOps.rename(renamedPath, to: "Taken.mp4", library: opsLibrary) }
check("a rename onto an existing name is refused",
      clash.done.isEmpty && clash.failed.count == 1, "\(clash.summary)")
check("...and the original is still there",
      FileManager.default.fileExists(atPath: renamedPath))

// A name with a slash in it is refused: that is a path, not a file name.
var slashed = FileOps.Report()
await MainActor.run { slashed = FileOps.rename(renamedPath, to: "a/b.mp4", library: opsLibrary) }
check("a rename containing “/” is refused",
      slashed.done.isEmpty && slashed.failed.count == 1)

// Gathering a tag: the folder is named after it, and the tag survives.
let scatteredA = opsFrom + "/One.mp4"
let scatteredB = opsFrom + "/Two.mp4"
makeClip(scatteredA)
makeClip(scatteredB)
await MainActor.run {
    opsLibrary.setTags(["Cruise"], for: scatteredA)
    opsLibrary.setTags(["Cruise"], for: scatteredB)
}
var gathered = FileOps.Report()
await MainActor.run { gathered = FileOps.gather(tag: "Cruise", into: opsDir, library: opsLibrary) }
let cruiseFolder = opsDir + "/Cruise"
check("gathering makes a folder named after the tag",
      FileManager.default.fileExists(atPath: cruiseFolder) && gathered.done.count == 2,
      "\(gathered.summary)")
var cruiseAfter: [String] = []
await MainActor.run { cruiseAfter = opsLibrary.taggedWith("Cruise") }
check("...and every gathered video still carries the tag",
      cruiseAfter.count == 2 && cruiseAfter.allSatisfy { $0.hasPrefix(cruiseFolder) },
      "\(cruiseAfter)")
check("gathering a tag nobody uses reports rather than making an empty folder",
      { () -> Bool in
          let empty = FileOps.gatherTarget(tag: "NoSuchTag", into: opsDir)
          return (empty as NSString).lastPathComponent == "NoSuchTag"
      }())

// Where that folder goes: the videos' own folder, and nothing typed or asked.
check("a tag whose videos share a folder gathers into that folder",
      FileOps.gatherParent(for: [opsDir + "/a.mp4", opsDir + "/b.mp4"],
                           fallback: "/elsewhere") == opsDir)
check("a tag spread over folders falls back to the library root",
      FileOps.gatherParent(for: [opsDir + "/a.mp4", opsDir + "/sub/b.mp4"],
                           fallback: "/root") == "/root")
check("with no library root the first video's folder is used",
      FileOps.gatherParent(for: ["/one/a.mp4", "/two/b.mp4"], fallback: nil) == "/one")
check("nothing to gather has nowhere to go",
      FileOps.gatherParent(for: [], fallback: nil) == nil)

try? FileManager.default.removeItem(atPath: opsDir)
try? FileManager.default.removeItem(atPath: Paths.support)

// -- pinned folders belong to the tag profile -------------------------------

Paths.support = NSTemporaryDirectory() + "fvp-pins-\(UUID().uuidString)"
let pinLibrary = await Library()

var pinsAlice: [String] = []
var pinsBob: [String] = []
var pinsBackToAlice: [String] = []
var bobSawAlicesPins = true

await MainActor.run {
    pinLibrary.person = "Alice"
    pinLibrary.pin(folder: "/Volumes/nas/Alice/Trips")
    pinLibrary.pin(folder: "/Volumes/nas/Alice/Family")
    pinsAlice = pinLibrary.pinned

    // Bob starts with none of Alice's folders pinned.
    pinLibrary.switchProfile(to: "Bob")
    bobSawAlicesPins = !pinLibrary.pinned.isEmpty
    pinLibrary.pin(folder: "/Volumes/nas/Bob/Work")
    pinsBob = pinLibrary.pinned

    // Back to Alice: hers are exactly as she left them.
    pinLibrary.switchProfile(to: "Alice")
    pinsBackToAlice = pinLibrary.pinned
}

check("a profile's pinned folders are its own",
      pinsAlice == ["/Volumes/nas/Alice/Family", "/Volumes/nas/Alice/Trips"],
      "\(pinsAlice)")
check("switching profile does not carry the old profile's pins over",
      !bobSawAlicesPins)
check("the new profile keeps its own pins", pinsBob == ["/Volumes/nas/Bob/Work"],
      "\(pinsBob)")
check("switching back restores that profile's pins exactly",
      pinsBackToAlice == pinsAlice, "\(pinsBackToAlice)")

// Renaming a profile keeps its folders to hand.
var pinsAfterRename: [String] = []
await MainActor.run {
    _ = pinLibrary.renameActiveProfile(to: "Alicia")
    pinsAfterRename = pinLibrary.pinned
}
check("renaming a profile keeps its pinned folders",
      pinsAfterRename == pinsAlice, "\(pinsAfterRename)")

// And they survive a relaunch, per profile.
var reloadedAlicia: [String] = []
var reloadedBob: [String] = []
await MainActor.run { pinLibrary.save() }
let pinReload = await Library()
await MainActor.run {
    reloadedAlicia = pinReload.pinned
    pinReload.switchProfile(to: "Bob")
    reloadedBob = pinReload.pinned
}
check("pins come back after a relaunch", reloadedAlicia == pinsAlice, "\(reloadedAlicia)")
check("...and the other profile's are still separate",
      reloadedBob == ["/Volumes/nas/Bob/Work"], "\(reloadedBob)")

try? FileManager.default.removeItem(atPath: Paths.support)

// -- filtering a playlist by the tags its videos carry ----------------------
//
// The filter is pure set logic over what the library holds, so it is checked
// here rather than through a controller that needs a player and a window.

func tagsPresent(_ paths: [String], _ tagsOf: (String) -> [String])
    -> [(name: String, count: Int)] {
    var counts: [String: Int] = [:]
    var display: [String: String] = [:]
    for path in paths {
        for name in tagsOf(path) {
            let key = name.lowercased()
            counts[key, default: 0] += 1
            if display[key] == nil { display[key] = name }
        }
    }
    return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        .compactMap { key, count in display[key].map { ($0, count) } }
}

func visibleUnder(_ paths: [String], ticked: Set<String>, needle: String,
                  banned: Set<String> = [], anyOf: Bool = false,
                  _ tagsOf: (String) -> [String]) -> [String] {
    paths.filter { path in
        if !needle.isEmpty,
           !(path as NSString).lastPathComponent.lowercased().contains(needle.lowercased()) {
            return false
        }
        let carried = tagsOf(path)
        let carries: (String) -> Bool = { want in
            carried.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
        }
        // A ruled-out tag wins over a wanted one: "not this" is the stronger
        // wish, and it is the only way to carve a hole in a broad pick.
        if banned.contains(where: carries) { return false }
        guard !ticked.isEmpty else { return true }
        return anyOf ? ticked.contains(where: carries) : ticked.allSatisfy(carries)
    }
}

let fPaths = ["/v/Beach Day.mp4", "/v/Beach Sunset.mp4", "/v/Ski Trip.mp4", "/v/Untagged.mp4"]
let fTags: [String: [String]] = [
    "/v/Beach Day.mp4":    ["Holiday", "Beach", "4K"],
    "/v/Beach Sunset.mp4": ["Holiday", "Beach"],
    "/v/Ski Trip.mp4":     ["Holiday", "Winter"],
    "/v/Untagged.mp4":     [],
]
let tagsOf: (String) -> [String] = { fTags[$0] ?? [] }

let offered = tagsPresent(fPaths, tagsOf)
check("the strip offers only tags the playlist's videos carry",
      Set(offered.map(\.name)) == ["Holiday", "Beach", "4K", "Winter"],
      "\(offered.map(\.name))")
check("the most-used tag leads", offered.first?.name == "Holiday", "\(offered.first?.name ?? "-")")
check("each chip carries its count",
      offered.first(where: { $0.name == "Beach" })?.count == 2,
      "\(offered)")
check("a playlist with no tagged videos offers no chips",
      tagsPresent(["/v/Untagged.mp4"], tagsOf).isEmpty)

check("ticking one tag shows only videos carrying it",
      visibleUnder(fPaths, ticked: ["Beach"], needle: "", tagsOf).count == 2)
check("ticking two narrows to videos carrying both",
      visibleUnder(fPaths, ticked: ["Holiday", "Beach"], needle: "", tagsOf).count == 2)
check("...and a pair nothing carries together shows nothing",
      visibleUnder(fPaths, ticked: ["Beach", "Winter"], needle: "", tagsOf).isEmpty)
check("a tag chip matches however it is capitalised",
      visibleUnder(fPaths, ticked: ["hOLiDaY"], needle: "", tagsOf).count == 3)
check("no chips ticked shows everything",
      visibleUnder(fPaths, ticked: [], needle: "", tagsOf).count == 4)

// -- OR and NOT ------------------------------------------------------------
//
// AND could not ask "Beach or Winter", nor "Holiday but not Beach" — the two
// questions that come up once a library is big enough to need a filter.
check("Any of: two tags widen instead of narrowing",
      visibleUnder(fPaths, ticked: ["Beach", "Winter"], needle: "", anyOf: true, tagsOf).count == 3,
      "\(visibleUnder(fPaths, ticked: ["Beach", "Winter"], needle: "", anyOf: true, tagsOf))")
check("Any of: one tag behaves the same as All of",
      visibleUnder(fPaths, ticked: ["Beach"], needle: "", anyOf: true, tagsOf)
        == visibleUnder(fPaths, ticked: ["Beach"], needle: "", tagsOf))
check("a ruled-out tag hides the videos carrying it",
      visibleUnder(fPaths, ticked: ["Holiday"], needle: "", banned: ["Beach"], tagsOf)
        == ["/v/Ski Trip.mp4"],
      "\(visibleUnder(fPaths, ticked: ["Holiday"], needle: "", banned: ["Beach"], tagsOf))")
check("ruling out alone still shows everything else",
      visibleUnder(fPaths, ticked: [], needle: "", banned: ["Beach"], tagsOf).count == 2)
check("ruling out beats wanting when a video carries both",
      visibleUnder(fPaths, ticked: ["Beach"], needle: "", banned: ["4K"], tagsOf)
        == ["/v/Beach Sunset.mp4"])
check("ruling out matches however it is capitalised",
      visibleUnder(fPaths, ticked: [], needle: "", banned: ["bEaCh"], tagsOf).count == 2)
check("the typed name and the chips both apply",
      visibleUnder(fPaths, ticked: ["Beach"], needle: "sunset", tagsOf)
        == ["/v/Beach Sunset.mp4"],
      "\(visibleUnder(fPaths, ticked: ["Beach"], needle: "sunset", tagsOf))")

// A ticked tag that has left the list is dropped rather than emptying it.
let stillPresent = Set(tagsPresent(fPaths, tagsOf).map { $0.name.lowercased() })
let prunedFilter = Set(["Beach", "GoneTag"]).filter { stillPresent.contains($0.lowercased()) }
check("a ticked tag no longer in the playlist is dropped",
      prunedFilter == ["Beach"], "\(prunedFilter)")

// -- tag chips under an icon tile ------------------------------------------
//
// A tile is 132pt wide. Tags used to be laid on one line and clipped, which
// put three tags on top of each other; they wrap now, and what will not fit
// in two lines is counted instead.

check("a couple of short tags all fit",
      chipsThatFit(["4K", "Beach"], width: 132) == 2)
check("a long list is cut down to what two lines hold",
      chipsThatFit(["Holiday", "Beach", "Sunset", "Family", "Cruise", "2024"],
                   width: 132) < 6,
      "\(chipsThatFit(["Holiday", "Beach", "Sunset", "Family", "Cruise", "2024"], width: 132))")
check("one very long tag is still shown rather than replaced by a count",
      chipsThatFit(["An Extremely Long Tag Name That Runs On"], width: 132) == 1)
check("no tags, nothing to draw", chipsThatFit([], width: 132) == 0)
check("a wider tile fits more",
      chipsThatFit(["Holiday", "Beach", "Sunset", "Family"], width: 264)
        >= chipsThatFit(["Holiday", "Beach", "Sunset", "Family"], width: 132))
check("one line fits fewer than two",
      chipsThatFit(["Holiday", "Beach", "Sunset", "Family"], width: 132, lines: 1)
        <= chipsThatFit(["Holiday", "Beach", "Sunset", "Family"], width: 132, lines: 2))

// -- auto-tag: which rules cost a file read ---------------------------------
//
// The folder and date rules cost one stat a video; camera, quality and places
// mean opening every file. Which is which decides whether a folder of ten
// thousand videos is instant or minutes, so it is pinned down here.

check("folder names need no file read", !MetadataTagger.Rule.folder.needsDetails)
check("year needs no file read", !MetadataTagger.Rule.year.needsDetails)
check("month needs no file read", !MetadataTagger.Rule.month.needsDetails)
check("camera needs the file read", MetadataTagger.Rule.camera.needsDetails)
check("quality needs the file read", MetadataTagger.Rule.quality.needsDetails)
check("city needs the file read", MetadataTagger.Rule.city.needsDetails)
check("country needs the file read", MetadataTagger.Rule.country.needsDetails)
check("a scan starts with only the cheap rules ticked",
      MetadataTagger.Rule.defaultOn.allSatisfy { !$0.needsDetails },
      "\(MetadataTagger.Rule.defaultOn)")
check("...and those cheap rules are folder and year",
      MetadataTagger.Rule.defaultOn == [.folder, .year],
      "\(MetadataTagger.Rule.defaultOn)")

// Only the two GPS rules cost a network round trip; the rest are local.
check("only city and country need the network",
      Set(MetadataTagger.Rule.allCases.filter(\.needsNetwork)) == [.city, .country],
      "\(MetadataTagger.Rule.allCases.filter(\.needsNetwork))")

// Every category is offered, and country leads city — the cheap, small one
// first, so the obvious tick is the one that does not flood the library.
check("every rule is offered in the list",
      Set(MetadataTagger.Rule.displayOrder) == Set(MetadataTagger.Rule.allCases))
check("country is offered before city",
      MetadataTagger.Rule.displayOrder.firstIndex(of: .country)!
        < MetadataTagger.Rule.displayOrder.firstIndex(of: .city)!)

// -- year and month are separate categories ---------------------------------
//
// One tag a year against twelve a year: the whole reason they are split.

let mayFourth = ISO8601DateFormatter().date(from: "2024-05-04T10:00:00Z")!
check("the year rule earns just the year",
      AutoTagCore.yearTag(mayFourth) == "2024", "\(AutoTagCore.yearTag(mayFourth) ?? "-")")
check("the month rule earns just the month",
      AutoTagCore.monthTag(mayFourth) == ["May 2024"], "\(AutoTagCore.monthTag(mayFourth))")
check("an ancient file earns no year", AutoTagCore.yearTag(
        ISO8601DateFormatter().date(from: "1850-05-04T10:00:00Z")!) == nil)
check("an ancient file earns no month", AutoTagCore.monthTag(
        ISO8601DateFormatter().date(from: "1850-05-04T10:00:00Z")!).isEmpty)

// A decade of clips: ten year tags, a hundred and twenty month tags. This is
// the arithmetic the sheet now shows before anything is applied.
var yearNames = Set<String>()
var monthNames = Set<String>()
for year in 2015...2024 {
    for month in 1...12 {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = 15
        let date = Calendar.current.date(from: parts)!
        if let y = AutoTagCore.yearTag(date) { yearNames.insert(y) }
        monthNames.formUnion(AutoTagCore.monthTag(date))
    }
}
check("ten years of clips make ten year tags", yearNames.count == 10, "\(yearNames.count)")
check("...and a hundred and twenty month tags", monthNames.count == 120,
      "\(monthNames.count)")

// -- place lookups: country on a coarse grid --------------------------------
//
// Country is the half worth having on a big folder: it comes from a ~55 km
// grid, so a fortnight of holiday clips shares one lookup instead of asking
// per video and being refused. The keys are checked against real places.

let sgKey = PlaceNames.coarseKey((lat: 1.2897, lon: 103.8501))     // Singapore
let sgEast = PlaceNames.coarseKey((lat: 1.3521, lon: 103.9198))    // Changi, ~10 km
check("clips from across one city share a country lookup",
      sgKey == sgEast, "\(sgKey) vs \(sgEast)")

let jbKey = PlaceNames.coarseKey((lat: 1.4927, lon: 103.7414))     // Johor Bahru
check("a place across the border does not share it",
      sgKey != jbKey, "\(sgKey) vs \(jbKey)")

let sydney = PlaceNames.coarseKey((lat: -33.8688, lon: 151.2093))
let melbourne = PlaceNames.coarseKey((lat: -37.8136, lon: 144.9631))
check("far-apart cities key differently", sydney != melbourne)
check("southern latitudes key cleanly", sydney == PlaceNames.coarseKey((lat: -33.87, lon: 151.21)),
      "\(sydney) vs \(PlaceNames.coarseKey((lat: -33.87, lon: 151.21)))")

check("the grid is stable for the same fix",
      PlaceNames.coarseKey((lat: 1.2897, lon: 103.8501))
        == PlaceNames.coarseKey((lat: 1.2897, lon: 103.8501)))

// -- the analysis store ----------------------------------------------------
//
// The store is pure model code: the queue, the verdicts, and the human
// corrections, persisted to analysis.json. Everything runs against a throwaway
// support folder and share-relative path keys (nas/Home/…) the way a real
// mounted library keys them.

let anaSupport = NSTemporaryDirectory() + "fvp-analysis-\(UUID().uuidString)"
Paths.support = anaSupport
// Pin the profile: a mark is filed under it, so the marks file's path should
// not depend on whichever account happens to be running the tests.
Paths.activeProfile = "analysis-tests"
let anaStore = AnalysisStore()
let anaBeach = Paths.volumes + "nas/Home/beach.mp4"
let anaParty = Paths.volumes + "nas/Home/party.mp4"
let anaTrip = Paths.volumes + "nas/Home/trip.mp4"
let anaKey = { (path: String) in Paths.tagKey(path) }

check("enqueue queues unseen videos as share-relative keys",
      anaKey(anaBeach) == "nas/Home/beach.mp4", anaKey(anaBeach))
anaStore.enqueue([anaBeach, anaParty])
check("enqueue adds both", anaStore.records.count == 2, "\(anaStore.records.count)")
check("…as queued", anaStore.records.values.allSatisfy { $0.phase == .queued })
anaStore.enqueue([anaBeach, anaParty])
check("enqueue is idempotent", anaStore.records.count == 2, "\(anaStore.records.count)")
anaStore.enqueue([anaTrip])
check("enqueue adds the new one", anaStore.records.count == 3)

check("dequeue removes a queued row", anaStore.dequeue(anaTrip),
      "\(anaStore.records)")
check("dequeue of what is gone is refused", !anaStore.dequeue(anaTrip))
anaStore.clearQueue()
check("clearQueue drops every queued row", anaStore.records.isEmpty,
      "\(anaStore.records.count)")

// The engine cycle on a fresh queue.
anaStore.enqueue([anaBeach, anaParty])
anaStore.begin(anaBeach)
check("begin moves queued to analyzing",
      anaStore.analysis(for: anaBeach)?.phase == .analyzing)
anaStore.begin(anaParty)
let anaP = NsfwPrediction(score: 0.94, maxFrame: 0.97, meanFrame: 0.21,
                          frames: 143, framesAbove: 119, threshold: 0.6,
                          aggregation: "weighted_max_frac", modelID: "clip-vit-l14",
                          classifier: "zeroshot-nsfw-v1", classifiedAt: 1234)
anaStore.finish(anaBeach, prediction: anaP,
                frames: [FrameScore(at: 0, score: 0.94, hash: "aa"),
                         FrameScore(at: 300, score: 0.91, hash: "bb")])
check("finish stores the verdict", anaStore.analysis(for: anaBeach)?.phase == .done)
check("…and the raw frame scores",
      anaStore.analysis(for: anaBeach)?.frameScores.count == 2,
      "\(anaStore.analysis(for: anaBeach)?.frameScores.count ?? -1)")
check("a finished video is not reviewed yet",
      anaStore.analysis(for: anaBeach)?.reviewed == false)
anaStore.fail(anaParty)
check("fail marks the row failed",
      anaStore.analysis(for: anaParty)?.phase == .failed)
anaStore.enqueue([anaParty])
check("enqueue retries a failed video",
      anaStore.analysis(for: anaParty)?.phase == .queued)

// Human review: corrections outrank the machine and are logged, not lost.
anaStore.mark(.nsfw, on: [anaBeach])
let anaBeachRecord = anaStore.analysis(for: anaBeach)!
check("mark records the correction",
      anaBeachRecord.history.count == 1, "\(anaBeachRecord.history.count)")
check("…saying what it overruled",
      anaBeachRecord.history.first?.previous == "automatic 0.940",
      anaBeachRecord.history.first?.previous ?? "nil")
check("…with the human's label and source",
      anaBeachRecord.userLabel == .nsfw && anaBeachRecord.history.first?.source == "user_correction")
check("marking is review", anaBeachRecord.reviewed)
anaStore.mark(.nsfw, on: [anaBeach])
check("marking the same label again is a no-op",
      anaStore.analysis(for: anaBeach)?.history.count == 1,
      "\(anaStore.analysis(for: anaBeach)?.history.count ?? -1)")
anaStore.mark(.safe, on: [anaBeach])
check("changing the label appends, not overwrites",
      anaStore.analysis(for: anaBeach)?.history.count == 2)
check("…naming the human it overturned",
      anaStore.analysis(for: anaBeach)?.history.last?.previous == "user:nsfw")
anaStore.mark(.safe, on: [anaTrip])
check("marking an unseen video creates the record",
      anaStore.analysis(for: anaTrip)?.userLabel == .safe)
check("…with nothing before it",
      anaStore.analysis(for: anaTrip)?.history.first?.previous == "none")
anaStore.enqueue([anaTrip])
let anaTripAfterEnqueue = anaStore.analysis(for: anaTrip)
check("a reviewed video is never re-queued",
      anaTripAfterEnqueue?.userLabel == .safe
        && anaTripAfterEnqueue?.history.count == 1)
anaStore.finish(anaTrip, prediction: anaP, frames: [])
check("a later machine verdict does not unreview a human's word",
      anaStore.analysis(for: anaTrip)?.reviewed == true
        && anaStore.analysis(for: anaTrip)?.userLabel == .safe)
check("…but the verdict is kept beside it",
      anaStore.analysis(for: anaTrip)?.prediction?.score == 0.94)

// A human's word settles a video for good — even one the machine failed on.
let anaCliff = Paths.volumes + "nas/Home/cliff.mp4"
anaStore.enqueue([anaCliff])
anaStore.begin(anaCliff)
anaStore.fail(anaCliff)
anaStore.mark(.nsfw, on: [anaCliff])
let anaCliffSettled = anaStore.analysis(for: anaCliff)
check("marking settles a failed video too",
      anaCliffSettled?.phase == .done
        && AnalysisStore.bucket(record: anaCliffSettled) == .nsfw)
check("…recording there was nothing to overrule",
      anaCliffSettled?.history.first?.previous == "none")
anaStore.enqueue([anaCliff])
check("a retry scan leaves a settled video alone",
      anaStore.analysis(for: anaCliff)?.userLabel == .nsfw
        && anaStore.analysis(for: anaCliff)?.history.count == 1
        && anaStore.analysis(for: anaCliff)?.phase == .done)
// And a machine failure landing after the human spoke cannot reopen it.
anaStore.fail(anaBeach)
check("a failure cannot unsettle a human's word",
      anaStore.analysis(for: anaBeach)?.phase == .done
        && anaStore.analysis(for: anaBeach)?.userLabel == .safe
        && anaStore.analysis(for: anaBeach)?.history.count == 2)

// The buckets the review window groups rows into.
check("no record is unseen",
      AnalysisStore.bucket(record: nil) == .unseen)
let anaQueued = VideoAnalysis()
check("a queued record is queued",
      AnalysisStore.bucket(record: anaQueued) == .queued)
var anaBusy = VideoAnalysis(); anaBusy.phase = .analyzing
check("an analyzing record is working",
      AnalysisStore.bucket(record: anaBusy) == .working)
var anaStuck = VideoAnalysis(); anaStuck.phase = .failed
check("a failed record is failed",
      AnalysisStore.bucket(record: anaStuck) == .failed)
var anaFresh = VideoAnalysis(); anaFresh.phase = .done
check("a done verdict with no score needs review",
      AnalysisStore.bucket(record: anaFresh) == .needsReview)
var anaHuman = VideoAnalysis(); anaHuman.userLabel = .safe
check("a human label wins the bucket",
      AnalysisStore.bucket(record: anaHuman) == .safe)

// The confidence band: only the uncertain middle is handed to a human. A
// confident machine call files itself, so a library the machine is sure about
// does not have to be marked by hand one video at a time.
func anaScored(_ score: Double) -> VideoAnalysis {
    var record = VideoAnalysis()
    record.phase = .done
    record.prediction = NsfwPrediction(score: score, maxFrame: score, meanFrame: score,
                                       frames: 4, framesAbove: 0, threshold: 0.5,
                                       aggregation: "max-margin-v1", modelID: "clip-vit-l14",
                                       classifier: "zeroshot-margin-v1", classifiedAt: 1234)
    return record
}
check("a confidently safe verdict files itself as Safe",
      AnalysisStore.bucket(record: anaScored(0.08)) == .safe)
check("a confidently NSFW verdict files itself as NSFW",
      AnalysisStore.bucket(record: anaScored(0.93)) == .nsfw)
// Band collapsed to the engine's own 0.5 cut (2026-09-09): every verdict
// files itself; the human corrects mis-files rather than working a queue.
check("a verdict at the cut files itself as NSFW",
      AnalysisStore.bucket(record: anaScored(0.51)) == .nsfw)
check("the safe edge of the band files itself as Safe",
      AnalysisStore.bucket(record: anaScored(AnalysisStore.confidentSafeBelow - 0.001)) == .safe)
check("just under the safe edge files itself",
      AnalysisStore.bucket(record: anaScored(AnalysisStore.confidentSafeBelow - 0.001)) == .safe)
check("the NSFW edge of the band files itself",
      AnalysisStore.bucket(record: anaScored(AnalysisStore.confidentNsfwAbove)) == .nsfw)
check("just under the NSFW edge still files as safe",
      AnalysisStore.bucket(record: anaScored(AnalysisStore.confidentNsfwAbove - 0.001)) == .safe)
var anaOverrule = anaScored(0.93); anaOverrule.userLabel = .safe
check("a human overrules a confident machine filing",
      AnalysisStore.bucket(record: anaOverrule) == .safe)
var anaFailedScored = anaScored(0.05); anaFailedScored.phase = .failed
check("a failed row is failed even with a confident score",
      AnalysisStore.bucket(record: anaFailedScored) == .failed)
check("machineVerdict files the 0.51 cut as NSFW",
      AnalysisStore.machineVerdict(anaScored(0.51)) == .nsfw)
check("machineVerdict says nothing without a score",
      AnalysisStore.machineVerdict(anaFresh) == nil)

// The review order: with the band collapsed to 0.5 (2026-09-09) nothing
// queues for review any more — every verdict files itself — so reviewOrder
// over freshly scored videos is empty by construction. Kept as a regression
// guard: if the band ever reopens, the fence-sitter must lead again.
let anaLake = Paths.volumes + "nas/Home/lake.mp4"
let anaDusk = Paths.volumes + "nas/Home/dusk.mp4"
anaStore.enqueue([anaParty, anaLake, anaDusk])
anaStore.begin(anaParty)
anaStore.finish(anaParty, prediction: anaP, frames: [])     // score 0.94 — confident
anaStore.begin(anaLake)
let anaSwing = NsfwPrediction(score: 0.51, maxFrame: 0.9, meanFrame: 0.2,
                              frames: 100, framesAbove: 40, threshold: 0.6,
                              aggregation: "weighted_max_frac", modelID: "clip-vit-l14",
                              classifier: "zeroshot-nsfw-v1", classifiedAt: 1234)
anaStore.finish(anaLake, prediction: anaSwing, frames: [])  // score 0.51 — auto-files NSFW at the 0.5 cut
anaStore.begin(anaDusk)
anaStore.finish(anaDusk, prediction: NsfwPrediction(score: 0.08, maxFrame: 0.09, meanFrame: 0.02,
                                                    frames: 90, framesAbove: 0, threshold: 0.6,
                                                    aggregation: "weighted_max_frac", modelID: "clip-vit-l14",
                                                    classifier: "zeroshot-nsfw-v1", classifiedAt: 1234),
               frames: [])                                  // score 0.08 — confident
let anaOrdered = AnalysisStore.reviewOrder([anaParty, anaLake, anaDusk]
    .map { (anaKey($0), anaStore.analysis(for: $0)!) })
check("nothing queues for review — every verdict filed itself",
      anaOrdered == [], "\(anaOrdered)")
let anaSettled: [(key: String, record: VideoAnalysis)] = [anaBeach, anaTrip]
    .map { (anaKey($0), anaStore.analysis(for: $0)!) }
check("reviewOrder ignores rows a human settled",
      AnalysisStore.reviewOrder(anaSettled).count == 0)

// Labels read the way they spell.
check("the NSFW label spells itself out", NsfwLabel.nsfw.title == "NSFW")
check("the Safe label does too", NsfwLabel.safe.title == "Safe")

// The engine wire contract: a canned result payload (as the engine emits it,
// snake_case and all) must decode into the mapping the store consumes.
let anaEngineJSON = """
{"video_path": "/Volumes/nas/Home/party.mp4", "nsfw_score": 0.87,
 "classification": "NSFW", "frames_analyzed": 12, "frames_above_threshold": 9,
 "dominant_label": "an nsfw phrase", "frames": [{"at": 5, "score": 0.9}],
 "provenance": {"embedding_model": "openai/clip-vit-large-patch14",
  "classifier_model": "zeroshot-margin-v1", "classifier_version": "1.0",
  "sampling_strategy": "uniform-fps-1/5s-cap250",
  "aggregation_strategy": "max-margin-v1", "sample_interval_s": 5,
  "embedding_dim": 768, "threshold": 0.5, "margin_bias": 0.04,
  "temperature": 40.0}}
"""
let anaEngineDecoder = JSONDecoder()
anaEngineDecoder.keyDecodingStrategy = .convertFromSnakeCase
let anaEngineResult = try? anaEngineDecoder.decode(EngineResult.self,
                                                   from: Data(anaEngineJSON.utf8))
check("an engine result payload decodes", anaEngineResult != nil)
let anaMapped = anaEngineResult.map { AnalysisEngine.prediction(from: $0) }
check("the mapping carries the engine's numbers",
      anaMapped?.score == 0.87 && anaMapped?.frames == 12
          && anaMapped?.modelID == "openai/clip-vit-large-patch14"
          && anaMapped?.threshold == 0.5,
      "\\(String(describing: anaMapped))")
let anaFrames = anaEngineResult.map { AnalysisEngine.frames(from: $0) }
check("frame scores map with their video seconds",
      anaFrames?.first?.at == 5 && anaFrames?.first?.score == 0.9,
      "\\(String(describing: anaFrames))")

// A run that dies mid-video (app quit, stop pressed, NAS sleep) leaves the
// row marked analysing forever unless the next run rescues it back to queued.
let anaRescueStore = AnalysisStore()
let anaRescueVid = Paths.volumes + "nas/Home/queue/stuck.mp4"
anaRescueStore.enqueue([anaRescueVid])
anaRescueStore.begin(anaRescueVid)
check("the abandoned row really was analysing",
      anaRescueStore.analysis(for: anaRescueVid)?.phase == .analyzing)
anaRescueStore.rescueStaleAnalyses()
check("rescue returns an abandoned analysing row to the queue",
      anaRescueStore.analysis(for: anaRescueVid)?.phase == .queued,
      "\\(String(describing: anaRescueStore.analysis(for: anaRescueVid)?.phase))")
// Undo the rescue store's file writes so the persistence checks below see
// exactly the records the main store last saved.
anaRescueStore.clearQueue()

// --- the play-time gate: which videos still want the machine's verdict? ---
//
// `autoWorkWhilePlaying` (stored as `classifyWhilePlaying`) asks this before it
// does anything, so this predicate
// is the difference between watching a folder filling the library in and
// playback quietly doing nothing. It has to answer for a video no scan has
// ever queued, which is the case that used to be skipped entirely.
//
// Its own support folder: these records must not reach the shared file the
// persistence checks below read.
let anaPlaySupport = NSTemporaryDirectory() + "fvp-play-\(UUID().uuidString)"
let anaPlaySavedSupport = Paths.support
Paths.support = anaPlaySupport
let anaPlayStore = AnalysisStore()
let anaPlayUnseen = Paths.volumes + "nas/Home/never-scanned.mp4"
let anaPlayQueued = Paths.volumes + "nas/Home/waiting.mp4"
let anaPlayFailed = Paths.volumes + "nas/Home/broke.mp4"
let anaPlayDone = Paths.volumes + "nas/Home/answered.mp4"
let anaPlayHuman = Paths.volumes + "nas/Home/judged.mp4"
let anaPlayStale = Paths.volumes + "nas/Home/left-in-flight.mp4"

check("a video nothing has ever seen wants a verdict",
      anaPlayStore.needsClassification(anaPlayUnseen))

anaPlayStore.enqueue([anaPlayQueued, anaPlayFailed, anaPlayDone, anaPlayHuman, anaPlayStale])
anaPlayStore.begin(anaPlayFailed)
anaPlayStore.fail(anaPlayFailed)
anaPlayStore.begin(anaPlayDone)
anaPlayStore.finish(anaPlayDone, prediction: anaP, frames: [])
anaPlayStore.begin(anaPlayHuman)
anaPlayStore.mark(.safe, on: [anaPlayHuman])
// A quit mid-video leaves the row analysing with no engine working on it.
anaPlayStore.begin(anaPlayStale)

check("a queued video wants one", anaPlayStore.needsClassification(anaPlayQueued))
check("a failed video is worth retrying when it is played",
      anaPlayStore.needsClassification(anaPlayFailed))
check("a video with a filed verdict is left alone",
      !anaPlayStore.needsClassification(anaPlayDone))
check("a human's word is the answer, not a question",
      !anaPlayStore.needsClassification(anaPlayHuman))
check("a row left in flight wants one, so the run's rescue picks it up",
      anaPlayStore.needsClassification(anaPlayStale))

// The gate and the run have to agree, or the gate is a lie: `run` filters its
// work with `phase == .queued`, so what the gate accepts must BE queued by the
// `enqueue` the play-time path does next — a newly seen row and a retry of a
// failed one both are.
anaPlayStore.enqueue([anaPlayUnseen, anaPlayFailed])
check("a video the gate accepts is queued for the run",
      anaPlayStore.analysis(for: anaPlayUnseen)?.phase == .queued,
      "\(String(describing: anaPlayStore.analysis(for: anaPlayUnseen)?.phase))")
check("a retried failure is queued too",
      anaPlayStore.analysis(for: anaPlayFailed)?.phase == .queued)
// The one case enqueue deliberately does not touch: a stale analysing row is
// left for the run's own `rescueStaleAnalyses()`, which happens BEFORE it
// builds its todo list — which is why accepting the row above is enough.
check("a stale in-flight row is the run's to rescue, not enqueue's",
      anaPlayStore.analysis(for: anaPlayStale)?.phase == .analyzing,
      "\(String(describing: anaPlayStore.analysis(for: anaPlayStale)?.phase))")
anaPlayStore.rescueStaleAnalyses()
check("and after that rescue it is queued for the run",
      anaPlayStore.analysis(for: anaPlayStale)?.phase == .queued,
      "\(String(describing: anaPlayStore.analysis(for: anaPlayStale)?.phase))")

// Playing a video classifies it too (maintainer's decision, 2026-09-17), so
// the gate above gains one automation rule: one attempt per video per launch.
// Without it a video the engine cannot get through is re-run every time
// playback returns to it, which on a machine with no models is every video.
var anaTried = Set<String>()
check("playing a video the gate wants starts an automatic classification",
      anaPlayStore.wantsAutoClassification(anaPlayUnseen, attempted: anaTried))
anaTried.insert(Paths.tagKey(anaPlayUnseen))
check("...and it is not started a second time this launch",
      !anaPlayStore.wantsAutoClassification(anaPlayUnseen, attempted: anaTried))
// The attempt set never overrides the gate's own refusals: a filed verdict and
// a human's word stay answers, not questions, attempted or not.
check("a video with a filed verdict is still left alone",
      !anaPlayStore.wantsAutoClassification(anaPlayDone, attempted: []))
check("a human's word is still not a question",
      !anaPlayStore.wantsAutoClassification(anaPlayHuman, attempted: []))

Paths.support = anaPlaySavedSupport
try? FileManager.default.removeItem(atPath: anaPlaySupport)

// Persistence: the store survives a reload, and tolerates a mangled file.
//
// The machine half is written on a clock, not on every change (2026-09-20:
// writing it per video meant 7.2 MB per verdict, 2.1 GB in a ten-minute run),
// so durability is what `flush` promises rather than what the last mutation
// did. The app flushes when it terminates and when the profile changes; here
// the gate stands in for that. Reading the file without flushing first is the
// one thing that changed, and it is the reason this line exists.
anaStore.flush()
let anaReload = AnalysisStore()
check("records survive a reload",
      anaReload.records == anaStore.records,
      "\(anaReload.records.count) vs \(anaStore.records.count)")
// A profile's marks are its own: the same machine record, read under another
// profile, carries no human word at all — but the machine's verdict is still
// there, because that half is shared.
let anaOtherProfile = AnalysisStore(profile: "someone-else")
check("another profile does not inherit this profile's marks",
      anaOtherProfile.analysis(for: anaBeach)?.userLabel == nil,
      "\(String(describing: anaOtherProfile.analysis(for: anaBeach)?.userLabel))")
check("...while the machine's verdict is shared with it",
      anaOtherProfile.analysis(for: anaBeach)?.phase == .done,
      "\(String(describing: anaOtherProfile.analysis(for: anaBeach)?.phase))")

// The human's half lives in the profile's own file, so these two cases are
// about the machine file alone — clearing the marks is what makes them so.
let anaMarks = Paths.marksFile(in: Paths.activeProfile)
let anaEmptyKey: [String: VideoAnalysis] = ["": VideoAnalysis(),
                                            "nas/Home/beach.mp4": VideoAnalysis()]
try? FileManager.default.removeItem(atPath: anaMarks)
JSONStore.save(anaSupport + "/analysis.json", anaEmptyKey)
let anaSanitized = AnalysisStore()
check("an empty key is dropped at load",
      anaSanitized.records.count == 1 && anaSanitized.records["nas/Home/beach.mp4"] != nil,
      "\(anaSanitized.records.keys)")
try? "not json".write(toFile: anaSupport + "/analysis.json", atomically: true, encoding: .utf8)
let anaMangled = AnalysisStore()
check("a mangled analysis file loads as empty", anaMangled.records.isEmpty,
      "\(anaMangled.records.keys)")
try? FileManager.default.removeItem(atPath: anaSupport)

// ---------------------------------------------------------------------------
// SuggestionStore — machine tag suggestions and the user's verdicts.
//
// The invariant under test throughout: a suggestion is an OPINION until the
// user accepts it, and the difference between "rejected" and "ignored" must
// survive, because only one of them is a training negative.
// ---------------------------------------------------------------------------

let sugSupport = NSTemporaryDirectory() + "fvp-sug-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: sugSupport,
                                         withIntermediateDirectories: true)
Paths.support = sugSupport

let sugFile = sugSupport + "/suggestions.json"
let sugStore = SuggestionStore(file: sugFile)
// Build the share path from the harness's own volumes root: an earlier test
// repoints Paths.volumes at a temp dir, so a literal "/Volumes/..." would not
// be recognised as share-relative and would be stored under its full path.
let sugVid = Paths.volumes + "nas/Home/party.mp4"

check("no suggestions for an unseen video", sugStore.pending(sugVid).isEmpty)
check("an unseen video has not been suggested",
      !sugStore.hasSuggestions(sugVid, model: "clip-L14"))

sugStore.record(sugVid,
                suggestions: [TagSuggestion(tag: "Birthday", confidence: 0.061, frames: 4),
                              TagSuggestion(tag: "Party", confidence: 0.034, frames: 3),
                              TagSuggestion(tag: "Dining", confidence: 0.022, frames: 2)],
                model: "clip-L14", framesSeen: 9, facesDetected: 0)

check("suggestions are recorded", sugStore.pending(sugVid).count == 3)
check("pending comes back strongest first",
      sugStore.pending(sugVid).map(\.tag) == ["Birthday", "Party", "Dining"],
      "\(sugStore.pending(sugVid).map(\.tag))")
check("a suggested video is known", sugStore.hasSuggestions(sugVid, model: "clip-L14"))
check("a different model invalidates old advice",
      !sugStore.hasSuggestions(sugVid, model: "siglip-so400m"))

// Accepting one tag must not silently settle the others.
sugStore.decide(sugVid, tag: "Birthday", verdict: .accepted)
check("an accepted tag leaves pending", sugStore.pending(sugVid).count == 2)
check("the accepted tag is gone from pending",
      !sugStore.pending(sugVid).contains { $0.tag == "Birthday" })

sugStore.decide(sugVid, tag: "Dining", verdict: .rejected)
check("a rejected tag leaves pending too", sugStore.pending(sugVid).count == 1)

// Walking away is not the same as saying no.
sugStore.dismissRest(sugVid)
check("dismiss settles the remainder", sugStore.pending(sugVid).isEmpty)
check("dismiss records ignored, not rejected",
      sugStore.entry(sugVid)?.verdicts["Party"] == .ignored,
      "\(String(describing: sugStore.entry(sugVid)?.verdicts["Party"]))")

// A suggestion recorded before face recognition shipped has facesDetected nil
// and must be re-suggested once so the face pass runs — otherwise old videos
// never get their faces looked at.
sugStore.record(sugVid,
                suggestions: [TagSuggestion(tag: "Birthday", confidence: 0.061, frames: 4)],
                model: "clip-L14", framesSeen: 9)   // no facesDetected
check("a face-unchecked video re-suggests (migration)",
      !sugStore.hasSuggestions(sugVid, model: "clip-L14"))
sugStore.record(sugVid,
                suggestions: [TagSuggestion(tag: "Birthday", confidence: 0.061, frames: 4)],
                model: "clip-L14", framesSeen: 9, facesDetected: 1)
check("a face-checked video is known again",
      sugStore.hasSuggestions(sugVid, model: "clip-L14"))

// A suggestion recorded before the app kept WHEN each tag was seen has no
// `evidenceCovered` field at all, and must be re-suggested once — the pass that
// answers is also the pass that records the moments, so asking again is what
// fills in the times beside the chips. Without this rule every video already in
// the library would show advice with nothing to show beside it, for good.
let legacyFile = sugSupport + "/legacy.json"
let legacyVid = Paths.volumes + "nas/Home/legacy.mp4"
var legacyEntry = VideoSuggestions()
legacyEntry.suggestions = [TagSuggestion(tag: "Birthday", confidence: 0.061, frames: 4)]
legacyEntry.suggestedAt = Date()
legacyEntry.model = "clip-L14"
legacyEntry.framesSeen = 9
legacyEntry.pairedCovered = false
legacyEntry.facesDetected = 1
// `evidenceCovered` deliberately left nil — this is what an older file holds.
_ = JSONStore.saveCompact(legacyFile, [Paths.tagKey(legacyVid): legacyEntry])

// The fixture is only honest if the field really is absent from the bytes, so
// check the file rather than trusting the encoder to omit it.
let legacyText = (try? String(contentsOfFile: legacyFile, encoding: .utf8)) ?? ""
check("a file written before moments were kept really has no such field",
      !legacyText.contains("evidenceCovered"), legacyText)

let legacyStore = SuggestionStore(file: legacyFile)
check("a video suggested before moments were kept is asked again once",
      !legacyStore.hasSuggestions(legacyVid, model: "clip-L14"))
legacyStore.record(legacyVid, suggestions: legacyEntry.suggestions, model: "clip-L14",
                   framesSeen: 9, facesDetected: 1)
check("...and is known again once the pass that records moments has run",
      legacyStore.hasSuggestions(legacyVid, model: "clip-L14"))
check("...so it is asked exactly once, not on every open",
      legacyStore.hasSuggestions(legacyVid, model: "clip-L14"))

// --- opening a video asks for suggestions by itself -------------------------
// The maintainer's rule (2026-09-17): suggestions appear on the video being
// played, without pressing anything, whether or not that video has ever been
// classified. The view's `onChange` cannot be tested, so the decision it makes
// lives in the store and is tested here.
let autoVid = Paths.volumes + "nas/Home/auto-suggest.mp4"
var autoTried = Set<String>()

// The plain case: a video nobody has suggested for, opened for the first time.
check("a never-suggested video wants an automatic pass",
      sugStore.wantsAutoSuggestion(autoVid, model: "clip-L14",
                                   paired: false, attempted: autoTried))
// CLASSIFICATION IS NOT A PRECONDITION. Nothing about this decision consults
// the analysis store: a video with no verdict at all is asked about exactly
// like one that has been classified.
check("...and it is not waiting on a classification to exist",
      AnalysisStore(profile: "auto-suggest-probe").analysis(for: autoVid) == nil
        && sugStore.wantsAutoSuggestion(autoVid, model: "clip-L14",
                                        paired: false, attempted: autoTried))

// Once tried, not tried again this launch — a pass that produced nothing (no
// models installed, engine missing) must not respin on every completion.
autoTried.insert(Paths.tagKey(autoVid))
check("a video already attempted this launch is not asked again",
      !sugStore.wantsAutoSuggestion(autoVid, model: "clip-L14",
                                    paired: false, attempted: autoTried))

// A video that HAS current suggestions is skipped even on a fresh launch, so
// reopening it costs nothing.
autoTried.removeAll()
sugStore.record(autoVid,
                suggestions: [TagSuggestion(tag: "Beach", confidence: 0.05, frames: 3)],
                model: "clip-L14", framesSeen: 9, facesDetected: 0)
check("a video with current suggestions is not re-run on open",
      !sugStore.wantsAutoSuggestion(autoVid, model: "clip-L14",
                                    paired: false, attempted: autoTried))
// ...but staleness still wins: the automatic pass uses the same test as the
// rest of the app, so a model change or a paired-tags change earns a re-run.
check("a model change earns an automatic re-run",
      sugStore.wantsAutoSuggestion(autoVid, model: "siglip2_base",
                                   paired: false, attempted: autoTried))
check("a paired-tags change earns one too",
      sugStore.wantsAutoSuggestion(autoVid, model: "clip-L14",
                                   paired: true, attempted: autoTried))
// The attempt set outranks staleness: one automatic pass per video per launch,
// or a video that keeps failing would be retried forever.
autoTried.insert(Paths.tagKey(autoVid))
check("one automatic attempt per video per launch, even when stale",
      !sugStore.wantsAutoSuggestion(autoVid, model: "siglip2_base",
                                    paired: false, attempted: autoTried))

// Training data: ignored must never be handed over as a label.
let sugLabels = sugStore.labelledExamples
check("only decided tags become examples", sugLabels.count == 2,
      "\(sugLabels.map { "\($0.tag)=\($0.accepted)" })")
check("accept is a positive example",
      sugLabels.contains { $0.tag == "Birthday" && $0.accepted })
check("reject is a negative example",
      sugLabels.contains { $0.tag == "Dining" && !$0.accepted })
check("ignored is not an example", !sugLabels.contains { $0.tag == "Party" })

let sugCounts = sugStore.exampleCounts()
check("counts split accepted from rejected",
      sugCounts.first(where: { $0.tag == "Birthday" })?.accepted == 1
      && sugCounts.first(where: { $0.tag == "Dining" })?.rejected == 1)

// A fresh batch must not erase what the user already decided.
sugStore.record(sugVid,
                suggestions: [TagSuggestion(tag: "Birthday", confidence: 0.070, frames: 5),
                              TagSuggestion(tag: "Dining", confidence: 0.030, frames: 3),
                              TagSuggestion(tag: "Cake", confidence: 0.025, frames: 2)],
                model: "clip-L14", framesSeen: 10)
check("re-suggesting keeps old verdicts",
      sugStore.entry(sugVid)?.verdicts["Dining"] == .rejected)
check("a settled tag is not offered again",
      !sugStore.pending(sugVid).contains { $0.tag == "Dining" })
check("a genuinely new tag IS offered",
      sugStore.pending(sugVid).contains { $0.tag == "Cake" },
      "\(sugStore.pending(sugVid).map(\.tag))")

// Path keys: a /Volumes path and its share-relative key are the same video.
check("suggestions are keyed share-relative like tags",
      sugStore.pending("nas/Home/party.mp4").map(\.tag)
      == sugStore.pending(sugVid).map(\.tag),
      "rel=\(sugStore.pending("nas/Home/party.mp4").map(\.tag)) abs=\(sugStore.pending(sugVid).map(\.tag))")
check("the stored key is share-relative, matching tags.json",
      sugStore.byVideo.keys.contains("nas/Home/party.mp4"),
      "\(sugStore.byVideo.keys)")

// Persistence.
sugStore.flush()
let sugReload = SuggestionStore(file: sugFile)
check("suggestions survive a reload",
      sugReload.pending(sugVid).map(\.tag) == sugStore.pending(sugVid).map(\.tag),
      "\(sugReload.pending(sugVid).map(\.tag))")
check("verdicts survive a reload",
      sugReload.entry(sugVid)?.verdicts["Birthday"] == .accepted)

try? "not json".write(toFile: sugFile, atomically: true, encoding: .utf8)
let sugMangled = SuggestionStore(file: sugFile)
check("a mangled suggestions file loads as empty", sugMangled.byVideo.isEmpty)

sugStore.forget(sugVid)
check("forget clears a video", sugStore.entry(sugVid) == nil)
try? FileManager.default.removeItem(atPath: sugSupport)

// TrainingSetBuilder — one builder, two scopes.
//
// The invariant under test: typed tags are positives, chip rejections are
// negatives, exclusive pairs (Dawn/Dusk) supply each other's negatives,
// and everything keys on the same share-relative paths the stores use.
// ---------------------------------------------------------------------------

let tsbSupport = NSTemporaryDirectory() + "fvp-tsb-\\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: tsbSupport,
                                         withIntermediateDirectories: true)
Paths.support = tsbSupport
let tsbLibrary = await Library()
let tsbAnalysis = AnalysisStore()
let tsbSuggest = SuggestionStore(file: tsbSupport + "/suggestions.json")
let tsbVidA = Paths.volumes + "nas/Home/a.mp4"    // tagged Dusk
let tsbVidB = Paths.volumes + "nas/Home/b.mp4"    // tagged Dawn
let tsbVidC = Paths.volumes + "nas/Home/c.mp4"    // tagged Beach, chip-rejected Dusk
let tsbVidD = Paths.volumes + "nas/Home/d.mp4"    // tagged, but never analysed
let tsbVidE = Paths.volumes + "nas/Home/e.mp4"    // tagged Dusk AND chip-rejected Dusk

await MainActor.run {
    tsbLibrary.setTags(["Dusk"], for: tsbVidA)
    tsbLibrary.setTags(["Dawn"], for: tsbVidB)
    tsbLibrary.setTags(["Beach"], for: tsbVidC)
    tsbLibrary.setTags(["Confetti"], for: tsbVidD)
    tsbLibrary.setTags(["Dusk"], for: tsbVidE)
    // A plain rejection on a video that does NOT carry the tag: the ordinary
    // negative example.
    tsbSuggest.decide(tsbVidC, tag: "Dusk", verdict: .rejected)
    // A rejection on a video that DOES carry the tag: a contradiction. The
    // typed tag is the user's own word and must win, or rejecting a tag's own
    // playlist deletes every positive it has and training dies with nothing
    // to learn from.
    tsbSuggest.decide(tsbVidE, tag: "Dusk", verdict: .rejected)
    // Analysed videos bring frame hashes; d.mp4 is parked (no embeddings).
    let recA = VideoAnalysis()
    tsbAnalysis.finish(tsbVidA, prediction: NsfwPrediction(score: 0.1, maxFrame: 0.1, meanFrame: 0.1, frames: 4, framesAbove: 0, threshold: 0.5, aggregation: "max", modelID: "clip", classifier: "z", classifiedAt: 0), frames: [FrameScore(at: 0, score: 0.1, hash: "h1"), FrameScore(at: 1, score: 0.1, hash: "h2")])
    tsbAnalysis.finish(tsbVidB, prediction: NsfwPrediction(score: 0.9, maxFrame: 0.9, meanFrame: 0.9, frames: 4, framesAbove: 4, threshold: 0.5, aggregation: "max", modelID: "clip", classifier: "z", classifiedAt: 0), frames: [FrameScore(at: 0, score: 0.9, hash: "h3")])
}

let tsbWhole = await MainActor.run {
    TrainingSetBuilder.build(scopeKeys: nil,
                             library: tsbLibrary,
                             suggestions: tsbSuggest,
                             analysis: tsbAnalysis,
                             exclusivePairs: [("Dawn", "Dusk")])
}
check("whole-library scope harvests typed tags as positives",
      tsbWhole.labels["Dusk"]?[Paths.tagKey(tsbVidA)] == true)
check("Dawn-tagged video is a negative for Dusk (pair rule)",
      tsbWhole.labels["Dusk"]?[Paths.tagKey(tsbVidB)] == false,
      "\\(String(describing: tsbWhole.labels[\"Dusk\"]))")
check("Dusk-tagged video is a negative for Dawn (pair rule)",
      tsbWhole.labels["Dawn"]?[Paths.tagKey(tsbVidA)] == false)
check("a rejection on a video that carries the tag never erases the positive",
      tsbWhole.labels["Dusk"]?[Paths.tagKey(tsbVidE)] == true,
      "\(String(describing: tsbWhole.labels["Dusk"]))")
check("a rejection on an untagged video is a clean negative",
      tsbWhole.labels["Dusk"]?[Paths.tagKey(tsbVidC)] == false,
      "\(String(describing: tsbWhole.labels["Dusk"]))")
check("analysed videos bring frame hashes",
      tsbWhole.frameHashes[Paths.tagKey(tsbVidA)]?.count == 2)
check("unanalysed tagged videos are reported as parked",
      tsbWhole.unanalysed.contains(Paths.tagKey(tsbVidD)),
      "\\(tsbWhole.unanalysed)")

let tsbPlaylist = await MainActor.run {
    TrainingSetBuilder.build(scopeKeys: [Paths.tagKey(tsbVidA), Paths.tagKey(tsbVidB)],
                             library: tsbLibrary,
                             suggestions: tsbSuggest,
                             analysis: tsbAnalysis,
                             exclusivePairs: [("Dawn", "Dusk")])
}
check("playlist scope only sees its own videos",
      tsbPlaylist.labels["Confetti"] == nil,
      "\(tsbPlaylist.labels.keys)")
check("playlist scope still applies the pair rule within it",
      tsbPlaylist.labels["Dusk"]?[Paths.tagKey(tsbVidB)] == false)
check("playlist scope reports its parked count",
      tsbPlaylist.unanalysed.sorted() == [Paths.tagKey(tsbVidC), Paths.tagKey(tsbVidE)].sorted(),
      "\(tsbPlaylist.unanalysed)")
// Negatives are tag-global: vidC's Dusk rejection lives OUTSIDE the
// playlist (it was refused the tag, so it can never sit inside the tag's
// scope) yet must still count — this was the '0 rejected' bug.
check("a rejection outside the playlist still counts for a trained tag",
      tsbPlaylist.labels["Dusk"]?[Paths.tagKey(tsbVidC)] == false,
      "\(String(describing: tsbPlaylist.labels["Dusk"]))")
// ...while a tag nobody trained in this scope (Confetti, only on out-of-scope d)
// still stays out of the report.
check("an untrained tag does not leak from outside the playlist",
      tsbPlaylist.labels["Confetti"] == nil)
try? FileManager.default.removeItem(atPath: tsbSupport)

// MARK: - merging tags
//
// Merge is not rename: the target may already be on some of the same videos,
// and a video must not come out holding the name twice.
let mergeLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Iceland", "2015"], to: ["/a.mp4"])
    lib.applyTags(["iceland trip"], to: ["/b.mp4"])
    lib.applyTags(["Iceland", "iceland trip"], to: ["/c.mp4"])
    lib.applyTags(["2015"], to: ["/d.mp4"])
    return lib
}
let mergeTouched = await MainActor.run {
    mergeLib.mergeTags(["iceland trip"], into: "Iceland")
}
let mergedTags = await MainActor.run { mergeLib.tags }
check("merge moves videos onto the surviving name",
      mergedTags[Paths.tagKey("/b.mp4")] == ["Iceland"],
      "\(String(describing: mergedTags[Paths.tagKey("/b.mp4")]))")
check("a video holding both ends up with one copy, not two",
      mergedTags[Paths.tagKey("/c.mp4")]?.filter { $0 == "Iceland" }.count == 1,
      "\(String(describing: mergedTags[Paths.tagKey("/c.mp4")]))")
check("merge leaves untouched videos alone",
      mergedTags[Paths.tagKey("/d.mp4")] == ["2015"])
check("merge reports how many videos it changed",
      mergeTouched == 2, "\(mergeTouched)")
check("the folded-away name is gone from the vocabulary",
      await MainActor.run { !mergeLib.knownTags().contains("iceland trip") })

// MARK: - tag headings
let groupLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Iceland", "Birthday", "2015"], to: ["/a.mp4"])
    lib.setGroup("Place", for: ["Iceland"])
    return lib
}
let sections = await MainActor.run { groupLib.tagsByGroup() }
check("a filed tag sits under its heading",
      sections.first { $0.group == "Place" }?.tags == ["Iceland"],
      "\(sections)")
check("unfiled tags collect under no heading",
      sections.first { $0.group == nil }?.tags.sorted() == ["2015", "Birthday"],
      "\(sections)")
check("headings list only what is in use",
      await MainActor.run { groupLib.knownGroups() } == ["Place"])
// The sidebar splits tags by asking group(of:) per tag, so the lookup has to
// survive the case the user typed. It stores lowercased and reads lowercased;
// this pins that down, because a miss here would mean a tag showing twice —
// once under its heading and once in the loose run.
check("a heading is found whatever case the tag is asked in",
      await MainActor.run { groupLib.group(of: "ICELAND") } == "Place")
check("a tag with no heading reports none",
      await MainActor.run { groupLib.group(of: "Birthday") } == nil)
// Unfiling has to leave the tag itself alone: the sidebar's loose run is
// "everything with no heading", so an over-eager removal would look like the
// tag had vanished.
let unfiled = await MainActor.run { () -> (String?, Bool) in
    groupLib.setGroup(nil, for: ["Iceland"])
    return (groupLib.group(of: "Iceland"), groupLib.knownTags().contains("Iceland"))
}
check("taking a tag out of its heading leaves the tag", unfiled.1)
check("taking a tag out of its heading clears the heading", unfiled.0 == nil)
check("a heading with nothing left in it stops being listed",
      await MainActor.run { groupLib.knownGroups() }.isEmpty,
      "\(await MainActor.run { groupLib.knownGroups() })")

// MARK: - the ✕ means the same thing on every chip
//
// It used to mean "take the tag off" on an applied chip and "this is NOT the
// tag" on an offered one — one glyph, two jobs. Now it always records the no,
// and where the tag was on, it comes off first. Rejecting while the tag is
// still applied is what erased positives before, so the order matters.
let xLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Iceland"], to: ["/x/a.mp4"])
    return lib
}
let xSug = SuggestionStore(file: NSTemporaryDirectory() + "fvp-x-\(UUID().uuidString).json")

/// The panel's @State for the chips it removed, so the mirror below can be as
/// faithful as the suite allows: Views/ is not compiled here, and a rejection
/// that takes a tag off has to remember what it took off to undo it.
@MainActor
final class RejectionTakeOff { var byTag: [String: [String]] = [:] }

// What TagPanel.reject does, in the same order.
@MainActor
func rejectLikePanel(_ name: String, on paths: [String],
                     _ lib: Library, _ sug: SuggestionStore, _ state: RejectionTakeOff) {
    let carriers = paths.filter { path in
        lib.tagsFor(path).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    if !carriers.isEmpty {
        lib.removeTag(name, from: carriers)
        state.byTag[name.lowercased()] = carriers
    }
    for path in paths { sug.decide(path, tag: name, verdict: .rejected) }
}

// What TagPanel.undoReject does.
@MainActor
func undoRejectLikePanel(_ name: String, on paths: [String],
                         _ lib: Library, _ sug: SuggestionStore, _ state: RejectionTakeOff) {
    for path in paths { sug.undecide(path, tag: name) }
    if let takenOff = state.byTag.removeValue(forKey: name.lowercased()) {
        lib.addTag(name, to: takenOff)
    }
}

let xState = await MainActor.run { RejectionTakeOff() }
await MainActor.run { rejectLikePanel("Iceland", on: ["/x/a.mp4"], xLib, xSug, xState) }
check("✕ on an applied tag takes the tag off",
      await MainActor.run { xLib.tagsFor("/x/a.mp4").isEmpty },
      "\(await MainActor.run { xLib.tagsFor("/x/a.mp4") })")
check("✕ on an applied tag records the no",
      xSug.entry("/x/a.mp4")?.verdicts["Iceland"] == .rejected)
check("the tag is not left applied and rejected at once",
      await MainActor.run {
          !xLib.tagsFor("/x/a.mp4").contains { $0.caseInsensitiveCompare("Iceland") == .orderedSame }
      })
check("✕ records what it took off, so ↺ has something to put back",
      await MainActor.run { xState.byTag["iceland"] == ["/x/a.mp4"] },
      "\(await MainActor.run { xState.byTag })")

// ↺ has to undo BOTH halves. Restoring only the verdict left the tag gone
// while the chip stopped saying "rejected", so the undo looked like it worked.
await MainActor.run { undoRejectLikePanel("Iceland", on: ["/x/a.mp4"], xLib, xSug, xState) }
check("↺ puts the tag the ✕ took off back on",
      await MainActor.run { xLib.hasTag("/x/a.mp4", "Iceland") },
      "\(await MainActor.run { xLib.tagsFor("/x/a.mp4") })")
check("↺ takes the no back too",
      xSug.entry("/x/a.mp4")?.verdicts["Iceland"] != .rejected)

// And on a tag that was never applied, the ✕ still just records the no.
await MainActor.run { rejectLikePanel("Winter", on: ["/x/b.mp4"], xLib, xSug, xState) }
check("✕ on an offered tag records the no",
      xSug.entry("/x/b.mp4")?.verdicts["Winter"] == .rejected)
check("✕ on an offered tag adds no tag",
      await MainActor.run { xLib.tagsFor("/x/b.mp4").isEmpty })
check("✕ on an offered tag records nothing to put back",
      await MainActor.run { xState.byTag["winter"] == nil })

// Undoing one tag must not resurrect another's removal.
await MainActor.run { rejectLikePanel("Iceland", on: ["/x/a.mp4"], xLib, xSug, xState) }
await MainActor.run { undoRejectLikePanel("Winter", on: ["/x/b.mp4"], xLib, xSug, xState) }
check("↺ for one tag does not put another tag's removal back",
      await MainActor.run { !xLib.hasTag("/x/a.mp4", "Iceland") },
      "\(await MainActor.run { xLib.tagsFor("/x/a.mp4") })")
await MainActor.run { undoRejectLikePanel("Iceland", on: ["/x/a.mp4"], xLib, xSug, xState) }
check("...and its own ↺ still does",
      await MainActor.run { xLib.hasTag("/x/a.mp4", "Iceland") })

// MARK: - taking a tag off a chip is undoable
//
// Clicking a ticked chip takes the tag off, and that used to leave no undo
// record at all (a plain toggle mutates and saves). The accident the user cannot
// recover from is the one worth a test: the removal has to land on the same
// undo slot the Undo button in Tag Profiles reads.
let chipLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Iceland", "2015"], to: ["/c/a.mp4"])
    lib.applyTags(["Iceland"], to: ["/c/b.mp4"])
    lib.applyTags(["2015"], to: ["/c/c.mp4"])
    return lib
}

let chipRemoved = await MainActor.run { chipLib.removeTag("Iceland", from: ["/c/a.mp4", "/c/b.mp4", "/c/c.mp4"]) }
check("taking a tag off reports what it changed", chipRemoved == 2, "\(chipRemoved)")
check("taking a tag off leaves the videos' other tags alone",
      await MainActor.run { chipLib.tagsFor("/c/a.mp4") } == ["2015"],
      "\(await MainActor.run { chipLib.tagsFor("/c/a.mp4") })")
check("taking a tag off records an undo, and names it",
      await MainActor.run { chipLib.undoable?.label ?? "" }.contains("Iceland"),
      await MainActor.run { chipLib.undoable?.label ?? "nil" })
// Asked of the two paths rather than `count(of:)`: the suite shares one
// support directory across sections, so a global count is every video any
// earlier section tagged "Iceland" as well as these two.
check("undo puts the tag back on every video it came off",
      await MainActor.run {
          chipLib.undoTagChange()
              && chipLib.hasTag("/c/a.mp4", "Iceland")
              && chipLib.hasTag("/c/b.mp4", "Iceland")
      },
      "\(await MainActor.run { chipLib.tagsFor("/c/a.mp4") + chipLib.tagsFor("/c/b.mp4") })")
check("...and the videos that never carried it are still untouched",
      await MainActor.run { chipLib.tagsFor("/c/c.mp4") } == ["2015"])

// Case is not a reason to lose a tag.
let caseRemoved = await MainActor.run { chipLib.removeTag("iceland", from: ["/c/a.mp4"]) }
check("the case of the tag you click does not matter", caseRemoved == 1, "\(caseRemoved)")
await MainActor.run { chipLib.undoTagChange() }

// A click that removes nothing must not spend the undo slot: otherwise the
// Undo button offers to undo a change that never happened and the real last
// edit is unreachable behind it.
let slotLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Iceland"], to: ["/s/a.mp4"])
    return lib
}
let spent = await MainActor.run { slotLib.removeTag("Nowhere", from: ["/s/a.mp4"]) }
check("taking off a tag the video does not carry changes nothing", spent == 0, "\(spent)")
check("taking off a tag the video does not carry records no undo",
      await MainActor.run { slotLib.undoable == nil })
let realRemoval = await MainActor.run { slotLib.removeTag("Iceland", from: ["/s/a.mp4"]) }
await MainActor.run { _ = slotLib.removeTag("Nowhere", from: ["/s/a.mp4"]) }
check("a no-op removal leaves the real edit undoable",
      await MainActor.run { slotLib.undoTagChange() && slotLib.hasTag("/s/a.mp4", "Iceland") },
      "\(realRemoval) removed, \(await MainActor.run { slotLib.tagsFor("/s/a.mp4") })")

// MARK: - taking a tag off every video
//
// "Remove Tag from Videos" is not "delete the file" and not "delete the other
// tags" — the fear that stops people using it. It is also undoable, which is
// what makes it safe to offer from a right-click.
let rmLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.applyTags(["Reykjavik", "2015"], to: ["/r/a.mp4"])
    lib.applyTags(["Reykjavik"], to: ["/r/b.mp4"])
    lib.applyTags(["2015"], to: ["/r/c.mp4"])
    return lib
}
await MainActor.run { rmLib.deleteTag("Reykjavik") }
check("the tag is off every video that carried it",
      await MainActor.run { rmLib.count(of: "Reykjavik") } == 0)
check("the other tags on those videos survive",
      await MainActor.run { rmLib.tagsFor("/r/a.mp4") } == ["2015"],
      "\(await MainActor.run { rmLib.tagsFor("/r/a.mp4") })")
check("a video left with no tags is dropped, not left empty",
      await MainActor.run { rmLib.tagsFor("/r/b.mp4").isEmpty })
check("videos that never carried it are untouched",
      await MainActor.run { rmLib.tagsFor("/r/c.mp4") } == ["2015"])
check("taking a tag off is undoable",
      await MainActor.run { rmLib.undoable != nil })
check("undo puts the tag back on every video",
      await MainActor.run { rmLib.undoTagChange() && rmLib.count(of: "Reykjavik") == 2 },
      "\(await MainActor.run { rmLib.count(of: "Reykjavik") })")

// MARK: - the AI never offers a tag the video already carries
//
// Mirrors TagPanel.pendingSuggestions. The engine legitimately recognises a
// tag that is already applied — it is right, but saying so is an echo, and it
// was filling the one row the user reads (56 such chips across 40 videos in
// the real library before this filter).
func offered(carried: [String], suggested: [String]) -> [String] {
    let have = Set(carried.map { $0.lowercased() })
    return suggested.filter { !have.contains($0.lowercased()) }
}
check("a suggestion the video already carries is dropped",
      offered(carried: ["Waterfall"], suggested: ["Waterfall", "Iceland"]) == ["Iceland"])
check("matching ignores capitals, as tags do everywhere else",
      offered(carried: ["waterfall"], suggested: ["Waterfall"]).isEmpty)
check("genuinely new suggestions still come through",
      offered(carried: ["2015"], suggested: ["Waterfall", "Iceland"]) == ["Waterfall", "Iceland"])
check("an untagged video loses nothing",
      offered(carried: [], suggested: ["Waterfall"]) == ["Waterfall"])

// MARK: - guessing what kind of thing a tag names
//
// The rules are only worth having if they are right about a real library, so
// these cases are taken from the user's own tags — including the ones that
// must NOT be guessed, which matter more than the ones that must.
check("a country is a place", TagKinds.isCountry("Singapore") && TagKinds.isCountry("Iceland")
      && TagKinds.isCountry("Switzerland") && TagKinds.isCountry("Malaysia"))
check("short forms people actually type are countries too",
      TagKinds.isCountry("USA") && TagKinds.isCountry("UK"))
check("a city is not mistaken for a country",
      !TagKinds.isCountry("Toronto") && !TagKinds.isCountry("Rome"))
check("a bare year is a date", TagKinds.isDateLike("2015") && TagKinds.isDateLike("2026"))
check("a month and year is a date", TagKinds.isDateLike("November 2023"))
check("a resolution is not a date", !TagKinds.isDateLike("1080p") && !TagKinds.isDateLike("4K"))
check("a plain word is not a date", !TagKinds.isDateLike("Iceland"))

let kinPeople: Set<String> = ["quincy hale", "mia ong", "bob meyer"]
let kinPlaces: Set<String> = ["toronto", "rome", "bkk"]
func kind(_ t: String) -> String? {
    TagKinds.guess(t, knownPeople: kinPeople, knownPlaces: kinPlaces)
}
check("a named face is a person", kind("Quincy Hale") == TagKinds.person)
check("a country is filed under Place", kind("Iceland") == TagKinds.place)
check("a city the tagger wrote is filed under Place", kind("Toronto") == TagKinds.place)
check("a year is filed under Date", kind("2015") == TagKinds.when)
check("a resolution is filed under Camera & Quality", kind("1080p") == TagKinds.camera)
check("an occasion is filed under Event", kind("Birthday") == TagKinds.event)
check("a place word at the end makes it a place", kind("Gardens By the Bay") == TagKinds.place)
// The important half: a wrong heading is worse than none, so anything the
// rules do not actually recognise must come back unfiled.
check("an unknown tag is left alone, not guessed at", kind("Asian Cruise") == nil)
check("a person with no face on file is left alone", kind("Xavier Song") == nil)
check("a made-up word is left alone", kind("Mahjongg Palace") == nil)
check("Beach Party is an event, not a beach", kind("Beach Party") == TagKinds.event)

check("a camera model is filed under Camera & Quality",
      kind("iPhone 16 Plus") == TagKinds.camera && kind("canon") == TagKinds.camera)
check("a hyphenated maker survives the split",
      kind("Ray-Ban Meta Smart Glasses") == TagKinds.camera)
check("a major city is a place without being told",
      kind("Kuala Lumpur") == TagKinds.place && kind("Rome") == TagKinds.place)

check("every country in the real library is recognised",
      ["Singapore", "Iceland", "United States", "Switzerland", "Malaysia",
       "Thailand", "France", "Spain", "Germany", "Japan", "Italy",
       "United Kingdom"].allSatisfy(TagKinds.isCountry))
check("cities and regions stay out of Countries",
      !["Toronto", "Rome", "Kuala Lumpur", "BKK", "Gardens By the Bay",
        "Asian Cruise", "Alaska Cruise"].contains(where: TagKinds.isCountry))

// Vision outputs must be decoded by their declared precision and strides.
for precision: MLMultiArrayDataType in [.float16, .float32, .double] {
    for stride in [1, 2] {
        // Padded allocation makes the former invalid Float read deterministic.
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        let values = try MLMultiArray(dataPointer: storage, shape: [2],
            dataType: precision, strides: [NSNumber(value: stride)],
            deallocator: { $0.deallocate() })
        values[0] = 3; values[1] = 4
        let vector = VisionEmbedder.l2(values)
        check("vision decoding precision \(precision.rawValue), stride \(stride)",
              abs(vector[0] - 0.6) < 0.0001 && abs(vector[1] - 0.8) < 0.0001)
    }
}

// MARK: - the facts read off the files live apart from the tags
//
// A library tagged by a build from before the split: years, a quality mark and
// a camera sitting among the tags. The readings have to come out — once, with a
// full copy of what changed left behind, and without taking a single tag the
// user meant. This is the one edit in the app that removes names from the tag
// store unasked, so it is the one edit that gets an end-to-end check.

let splitSupport = NSTemporaryDirectory() + "fvp-metadata-split-\(UUID().uuidString)"
Paths.support = splitSupport
try? FileManager.default.createDirectory(atPath: splitSupport, withIntermediateDirectories: true)
JSONStore.save(Paths.tagsFile, ["/m/a.mp4": ["Iceland", "2015", "May 2015", "1080p"],
                                "/m/b.mp4": ["Beach", "iPhone 16 Plus"],
                                "/m/c.mp4": ["Birthday"]])
// A profile nobody has opened this session still holds its own year tags, and
// the migration has to reach it: leaving it would resurrect them the moment it
// was switched to, with the flag already saying the job was done.
JSONStore.save(Paths.profileFile("Guest"), ["/m/d.mp4": ["Winter", "2016"]])

/// Read several things off the library in ONE hop to the main actor.
///
/// `check`'s argument is an autoclosure and Swift will not accept an `await`
/// inside one, so any comparison of two awaited values has to be read into
/// locals first. This keeps that to one hop per check rather than one per value.
func reading<T>(_ body: @escaping @MainActor () -> T) async -> T {
    await MainActor.run { body() }
}

let splitLib = await MainActor.run { Library() }
let afterSplitA = await reading { (splitLib.tagsFor("/m/a.mp4"), splitLib.factsFor("/m/a.mp4")) }
check("a reading leaves the tags", afterSplitA.0 == ["Iceland"], "\(afterSplitA.0)")
check("...and arrives in the facts store",
      afterSplitA.1 == ["2015", "May 2015", "1080p"], "\(afterSplitA.1)")
let afterSplitB = await reading { (splitLib.tagsFor("/m/b.mp4"), splitLib.factsFor("/m/b.mp4")) }
check("a camera is a reading too",
      afterSplitB.0 == ["Beach"] && afterSplitB.1 == ["iPhone 16 Plus"],
      "\(afterSplitB)")
check("a tag the user meant is untouched",
      (await reading { splitLib.tagsFor("/m/c.mp4") }) == ["Birthday"])
let guestStored: [String: [String]] = JSONStore.load(Paths.profileFile("Guest"), fallback: [:])
// The Guest profile's readings go to GUEST's own facts file, not into the
// store in hand — they came out of Guest's tags, so they are Guest's. Read
// off disk, because Guest is not the profile in force.
let guestFacts = MetadataFacts.load(at: Paths.profileFactsFile("Guest")).names(for: "/m/d.mp4")
check("a profile's own store is separated as well",
      guestStored == ["/m/d.mp4": ["Winter"]] && guestFacts == ["2016"],
      "\(guestStored) \(guestFacts)")
check("...and its readings do not land in the profile in force",
      (await reading { splitLib.factsFor("/m/d.mp4") }).isEmpty,
      "\(await reading { splitLib.factsFor("/m/d.mp4") })")
// Each store's backup now sits BESIDE it, and every profile's tags live in
// that profile's own bundle — so this asks each bundle rather than the support
// root and the `profiles/` directory, which is where they used to be.
let splitBackups = (try? FileManager.default.contentsOfDirectory(
    atPath: Paths.profileDir(Paths.activeProfile))) ?? []
let guestBackups = (try? FileManager.default.contentsOfDirectory(
    atPath: Paths.profileDir("Guest"))) ?? []
check("a full copy of what it changed is left behind",
      splitBackups.contains { $0.hasPrefix("tags.json.bak.") }
        && guestBackups.contains { $0.hasPrefix("tags.json.bak.") },
      "\(splitBackups) / \(guestBackups)")
let splitReport = await reading { splitLib.separationReport?.moved }
let splitVocabulary = await reading { splitLib.factsInUse() }
check("the app can say what it did", splitReport == 5, "\(String(describing: splitReport))")
// The SUMMARY counts every profile's move (5 readings), but the vocabulary in
// hand is only this profile's — "2016" came out of Guest's tags and is in
// Guest's store. What the app reports and what this profile sees differ on
// purpose.
check("...and the readings it moved are this profile's vocabulary",
      splitVocabulary.sorted()
        == ["1080p", "2015", "iPhone 16 Plus", "May 2015"].sorted(),
      "\(splitVocabulary)")
check("...with another profile's reading nowhere in it",
      !splitVocabulary.contains("2016"), "\(splitVocabulary)")
// Once, not on every launch: a year the user types afterwards is their tag, and
// a migration that ran again would take it.
let splitAgain = await MainActor.run { Library() }
let againFacts = await reading { splitAgain.factsFor("/m/a.mp4") }
let againReport = await reading { splitAgain.separationReport?.moved }
check("a second launch moves nothing further",
      againFacts == ["2015", "May 2015", "1080p"] && againReport == 5,
      "\(againFacts) \(String(describing: againReport))")
try? FileManager.default.removeItem(atPath: splitSupport)

// MARK: - a reading is findable without being a tag
//
// The split is only worth having if finding a video by its date still works.
// The filter, the sidebar's Play All and a row's chips all answer through
// `carries`, so a reading matches exactly as a tag does — while training, the
// hand-tag chips and the tag counts see none of it.

let factSupport = NSTemporaryDirectory() + "fvp-metadata-facts-\(UUID().uuidString)"
Paths.support = factSupport
try? FileManager.default.createDirectory(atPath: factSupport, withIntermediateDirectories: true)
let factLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.setTags(["Beach", "2016"], for: "/f/a.mp4")
    lib.setFacts(["2016", "1080p"], for: "/f/a.mp4")
    lib.addFacts(["Singapore"], for: "/f/b.mp4")
    lib.saveTags()
    lib.saveFacts()
    return lib
}
check("a library with no readings is left alone",
      (await reading { factLib.separationReport }) == nil)
check("a video carries its tags and its readings",
      (await reading { factLib.carries("/f/a.mp4") }) == ["Beach", "2016", "1080p"],
      "\(await reading { factLib.carries("/f/a.mp4") })")
check("a name that is both a tag and a reading is listed once",
      (await reading { factLib.carries("/f/a.mp4").filter { $0 == "2016" }.count }) == 1)
let carrying = await reading { (factLib.pathsCarrying("1080p"), factLib.pathsCarrying("Beach")) }
check("a reading still finds its videos",
      carrying.0 == ["/f/a.mp4"] && carrying.1 == ["/f/a.mp4"], "\(carrying)")
check("a name that is both finds the video once, not twice",
      (await reading { factLib.pathsCarrying("2016") }) == ["/f/a.mp4"])
let counts = await reading { (factLib.count(anyName: "1080p"), factLib.count(anyName: "Beach")) }
check("a sidebar row counts a reading the way it counts a tag",
      counts.0 == 1 && counts.1 == 1, "\(counts)")
check("a reading is in no tag count",
      (await reading { factLib.count(of: "1080p") }) == 0)
check("...and a tag is in no fact count",
      (await reading { factLib.factCount(of: "Beach") }) == 0)
let tagOffer = await reading { (factLib.assignableTags(), factLib.handTaggableTags()) }
check("no reading reaches the tags the AI or the chips offer",
      !tagOffer.0.contains("1080p") && !tagOffer.1.contains("1080p"), "\(tagOffer)")
check("the sidebar's kinds carry the readings, date first",
      (await reading { factLib.factsByKind().map { $0.kind } })
        == [TagKinds.when, TagKinds.camera, TagKinds.place],
      "\(await reading { factLib.factsByKind().map { $0.kind } })")
check("...with the newest year on top",
      (await reading { factLib.factsByKind().first?.names }) == ["2016"])

await MainActor.run { factLib.renameFact("2016", to: "2015") }
let afterRename = await reading { (factLib.factsFor("/f/a.mp4"),
                                   factLib.tagsFor("/f/a.mp4").contains("2016")) }
check("renaming a reading leaves a tag of the same name alone",
      afterRename.0 == ["2015", "1080p"] && afterRename.1,
      "\(afterRename)")
check("...and keeps its place in the list",
      (await reading { factLib.factsFor("/f/a.mp4").first }) == "2015")
await MainActor.run { factLib.rememberForUndo("test: taking a reading off") }
await MainActor.run { factLib.deleteFact("2015") }
let afterDelete = await reading { (factLib.factsFor("/f/a.mp4"),
                                   factLib.tagsFor("/f/a.mp4").contains("2016")) }
check("removing a reading takes it off every video and leaves the tags",
      afterDelete.0 == ["1080p"] && afterDelete.1, "\(afterDelete)")
let undone = await reading { (factLib.undoTagChange(), factLib.factsFor("/f/a.mp4"),
                              factLib.tagsFor("/f/a.mp4").contains("2016")) }
check("an undo brings a removed reading back",
      undone.0 && undone.1 == ["2015", "1080p"], "\(undone)")
check("...without turning the tag of the same shape into a reading", undone.2)

_ = await MainActor.run { factLib.moveTags(from: "/f/b.mp4", to: "/f/c.mp4") }
let afterMove = await reading { (factLib.factsFor("/f/c.mp4"), factLib.factsFor("/f/b.mp4")) }
check("a reading follows a moved file",
      afterMove.0 == ["Singapore"] && afterMove.1.isEmpty, "\(afterMove)")
_ = await MainActor.run { factLib.forgetPath("/f/c.mp4") }
let afterForget = await reading { (factLib.factsFor("/f/c.mp4"), factLib.factCount(of: "Singapore")) }
check("a file gone for good takes its readings with it",
      afterForget.0.isEmpty && afterForget.1 == 0, "\(afterForget)")
let factReload = await MainActor.run { Library() }
check("the readings survive a relaunch",
      (await reading { factReload.factsFor("/f/a.mp4") }) == ["2015", "1080p"],
      "\(await reading { factReload.factsFor("/f/a.mp4") })")
try? FileManager.default.removeItem(atPath: factSupport)

// MARK: - what the sidebar and the playlists do with a reading
//
// Slice 2 wires the readings into the rows, the counts and the playlists. The
// checks below are the behaviour a person sees: a reading row plays, it counts
// like a tag row, and a hidden video stays hidden however it is reached.

let rowSupport = NSTemporaryDirectory() + "fvp-fact-rows-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: rowSupport, withIntermediateDirectories: true)
Paths.support = rowSupport
let rowLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.setTags(["Beach"], for: "/r/one.mp4")
    lib.setTags(["Beach"], for: "/r/two.mp4")
    lib.setFacts(["2016", "1080p"], for: "/r/one.mp4")
    lib.setFacts(["2016"], for: "/r/three.mp4")
    lib.saveTags()
    lib.saveFacts()
    return lib
}
let playlistFor2016 = await reading { rowLib.pathsCarrying("2016") }
check("a reading row plays every video carrying it, tagged or not",
      playlistFor2016 == ["/r/one.mp4", "/r/three.mp4"], "\(playlistFor2016)")
check("...as real paths, not store keys",
      playlistFor2016.allSatisfy { $0.hasPrefix("/") }, "\(playlistFor2016)")
let mixedCounts = await reading { (rowLib.count(anyName: "2016"), rowLib.count(anyName: "Beach")) }
check("a reading row and a tag row count the same way",
      mixedCounts.0 == 2 && mixedCounts.1 == 2, "\(mixedCounts)")

// Hiding a video must take it out of BOTH kinds of row. A reading was the one
// route that could have smuggled a hidden video back into a playlist.
_ = await MainActor.run { rowLib.hide(["/r/three.mp4"]) }
let afterHiding = await reading {
    (rowLib.pathsCarrying("2016"), rowLib.count(anyName: "2016"), rowLib.factsInUse())
}
check("hiding a video takes it out of a reading's playlist",
      afterHiding.0 == ["/r/one.mp4"], "\(afterHiding.0)")
check("...and out of the reading's count",
      afterHiding.1 == 1, "\(afterHiding.1)")
check("a reading carried only by hidden videos still has a name",
      afterHiding.2.contains("2016"), "\(afterHiding.2)")

// The sidebar draws whatever `factsByKind` hands it, so a kind with nothing in
// it must be absent rather than an empty group with a (0) beside it.
let drawnKinds = await reading { rowLib.factsByKind() }
check("the sidebar is given no empty groups to draw",
      drawnKinds.allSatisfy { !$0.names.isEmpty }, "\(drawnKinds)")
check("Date and Camera & Quality are the only kinds here",
      drawnKinds.map { $0.kind } == [TagKinds.when, TagKinds.camera],
      "\(drawnKinds.map { $0.kind })")
try? FileManager.default.removeItem(atPath: rowSupport)

// MARK: - the metadata scan writes readings, never tags
//
// The whole point of the split: what MetadataTagger produces must land in the
// facts store and leave the tag vocabulary untouched.

let scanSupport = NSTemporaryDirectory() + "fvp-fact-scan-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: scanSupport, withIntermediateDirectories: true)
Paths.support = scanSupport
let scanLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.setTags(["Iceland"], for: "/s/a.mp4")
    lib.setFacts(["2016", "1080p"], for: "/s/a.mp4")   // what a scan would write
    lib.saveTags()
    lib.saveFacts()
    return lib
}
let scanVocabulary = await reading { (scanLib.knownTags(), scanLib.factsInUse()) }
check("a scan's readings stay out of the tag vocabulary",
      scanVocabulary.0 == ["Iceland"], "\(scanVocabulary.0)")
check("...and are the fact vocabulary instead",
      scanVocabulary.1 == ["1080p", "2016"], "\(scanVocabulary.1)")
let scanOffers = await reading { (scanLib.handTaggableTags(), scanLib.assignableTags()) }
check("no reading is offered as a chip to stick on by hand",
      !scanOffers.0.contains("1080p") && !scanOffers.0.contains("2016"), "\(scanOffers.0)")
check("...and none reaches the tags a model would train on",
      !scanOffers.1.contains("1080p") && !scanOffers.1.contains("2016"), "\(scanOffers.1)")
check("a video's own tags are untouched by its readings",
      (await reading { scanLib.tagsFor("/s/a.mp4") }) == ["Iceland"])
try? FileManager.default.removeItem(atPath: scanSupport)

// MARK: - a profile's readings are its own
//
// A profile is a fresh start. Somebody who has just made one has scanned
// nothing, so they must see no readings — handing them another profile's scan
// would mean a brand new profile was not new.

let profSupport = NSTemporaryDirectory() + "fvp-fact-profiles-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: profSupport, withIntermediateDirectories: true)
Paths.support = profSupport
let profLib = await MainActor.run { () -> Library in
    let lib = Library()
    lib.setTags(["Iceland"], for: "/p/a.mp4")
    lib.setFacts(["2016", "1080p"], for: "/p/a.mp4")
    lib.saveTags()
    lib.saveFacts()
    return lib
}
// The first profile is named after the account, so its name is read rather
// than assumed — switching to a name that does not exist would quietly make a
// THIRD profile and prove nothing.
let firstProfile = await reading { profLib.activeProfile }
let beforeNew = await reading { (profLib.factsInUse(), profLib.knownTags()) }
check("the first profile has its readings",
      beforeNew.0 == ["1080p", "2016"] && beforeNew.1 == ["Iceland"], "\(beforeNew)")

await MainActor.run { profLib.createProfile("Guest") }
let inNew = await reading {
    (profLib.factsInUse(), profLib.knownTags(), profLib.factsFor("/p/a.mp4"),
     profLib.carries("/p/a.mp4"), profLib.factsByKind().count)
}
check("a brand new profile has NO readings",
      inNew.0.isEmpty, "\(inNew.0)")
check("...and no tags either",
      inNew.1.isEmpty, "\(inNew.1)")
check("...so a video in it carries nothing",
      inNew.2.isEmpty && inNew.3.isEmpty, "\(inNew.2) \(inNew.3)")
check("...and the sidebar draws no reading groups at all",
      inNew.4 == 0, "\(inNew.4)")

// The readings a new profile makes are its own, and must not leak back.
await MainActor.run {
    profLib.setFacts(["2024"], for: "/p/b.mp4")
    profLib.saveFacts()
}
await MainActor.run { profLib.switchProfile(to: firstProfile) }
let backHome = await reading { (profLib.factsInUse(), profLib.factsFor("/p/a.mp4")) }
check("switching back restores the original profile's readings",
      backHome.0 == ["1080p", "2016"], "\(backHome.0)")
check("...exactly as they were",
      backHome.1 == ["2016", "1080p"], "\(backHome.1)")
check("...and the other profile's reading did not leak in",
      !backHome.0.contains("2024"), "\(backHome.0)")

await MainActor.run { profLib.switchProfile(to: "Guest") }
let backGuest = await reading { (profLib.factsInUse(), profLib.factsFor("/p/b.mp4")) }
check("a profile's own readings survive the round trip",
      backGuest.0 == ["2024"] && backGuest.1 == ["2024"], "\(backGuest)")

// A duplicate is for carrying on where the original left off, so unlike a new
// profile it DOES inherit the readings.
await MainActor.run { profLib.switchProfile(to: firstProfile) }
let duplicated = await profLib.duplicateProfile(firstProfile, as: "Copy")
check("a profile can be duplicated", duplicated)
let inCopy = await reading { (profLib.factsInUse(), profLib.knownTags()) }
check("a duplicate inherits the readings, unlike a new profile",
      inCopy.0 == ["1080p", "2016"] && inCopy.1 == ["Iceland"], "\(inCopy)")

// A relaunch must read the profile in force, not the shared file.
let profReload = await MainActor.run { Library() }
let reloaded = await reading { (profReload.activeProfile, profReload.factsInUse()) }
check("a relaunch comes back to the profile in force with its readings",
      reloaded.0 == "Copy" && reloaded.1 == ["1080p", "2016"], "\(reloaded)")
// --- Recent belongs to the profile, the way Pinned already did -------------
// Maintainer's request (2026-09-17): a new profile has been nowhere, so its
// Recent starts empty; switching shows only the folders THAT profile visited.
let recentHome = "/p/home-folder"
let recentGuest = "/p/guest-folder"
await MainActor.run { profLib.switchProfile(to: firstProfile) }
await MainActor.run { profLib.remember(folder: recentHome) }
check("a folder opened under the first profile is in its Recent",
      await reading { profLib.recent }.contains(recentHome))

await MainActor.run { profLib.createProfile("Stranger") }
check("a brand new profile has been nowhere, so Recent is empty",
      await reading { profLib.recent }.isEmpty,
      "\(await reading { profLib.recent })")
await MainActor.run { profLib.remember(folder: recentGuest) }
let strangerRecent = await reading { profLib.recent }
check("...and what it visits is its own",
      strangerRecent == [recentGuest], "\(strangerRecent)")
check("...without inheriting the other profile's folders",
      !strangerRecent.contains(recentHome))

await MainActor.run { profLib.switchProfile(to: firstProfile) }
let backRecent = await reading { profLib.recent }
check("switching back shows the first profile's folders again",
      backRecent.contains(recentHome), "\(backRecent)")
check("...and not the other profile's",
      !backRecent.contains(recentGuest), "\(backRecent)")

// A duplicate carries on where the original left off, so it inherits Recent —
// unlike a new profile. This is the rule pinned folders already follow.
_ = await profLib.duplicateProfile(firstProfile, as: "Carbon")
let copyRecent = await reading { profLib.recent }
check("a duplicated profile inherits the original's Recent",
      copyRecent.contains(recentHome), "\(copyRecent)")

// Across a relaunch the split has to survive, or it was only ever in memory.
await MainActor.run { profLib.switchProfile(to: firstProfile) }
await MainActor.run { profLib.save() }
let recentReload = await MainActor.run { Library() }
let reloadedRecent = await reading { (recentReload.activeProfile, recentReload.recent) }
check("a relaunch comes back to that profile's own Recent",
      reloadedRecent.0 == firstProfile
        && reloadedRecent.1.contains(recentHome)
        && !reloadedRecent.1.contains(recentGuest),
      "\(reloadedRecent)")

// --- headings belong to the profile too ------------------------------------
// Maintainer's decision (2026-09-17), after asking where headings are used:
// they file one person's tags, so they follow the profile the way the tags,
// the pins and the Recents do.
await MainActor.run { profLib.switchProfile(to: firstProfile) }
await MainActor.run { profLib.setTags(["Iceland"], for: "/p/head.mp4") }
await MainActor.run { profLib.setGroup("Place", for: ["Iceland"]) }
check("a tag filed under a heading reports it",
      await reading { profLib.group(of: "Iceland") } == "Place")

await MainActor.run { profLib.createProfile("Filing") }
check("a brand new profile has filed nothing",
      await reading { profLib.knownGroups() }.isEmpty,
      "\(await reading { profLib.knownGroups() })")
await MainActor.run { profLib.setTags(["Beach"], for: "/p/head2.mp4") }
await MainActor.run { profLib.setGroup("Where", for: ["Beach"]) }
check("...and what it files is its own",
      await reading { profLib.knownGroups() } == ["Where"],
      "\(await reading { profLib.knownGroups() })")
check("...without the other profile's headings",
      await reading { profLib.group(of: "Iceland") } == nil)

await MainActor.run { profLib.switchProfile(to: firstProfile) }
check("switching back restores the first profile's filing",
      await reading { profLib.group(of: "Iceland") } == "Place")
check("...and not the other profile's",
      await reading { profLib.knownGroups() } == ["Place"],
      "\(await reading { profLib.knownGroups() })")

// --- File ▸ Open Recent Profile ---------------------------------------------
// A profile is a document now, so the way back to the one you were working in
// is part of the file menu. It has to name profiles the way a person writes
// them, move rather than duplicate when one is renamed, and survive a quit.
check("switching is what fills the recent list",
      await reading { profLib.recentProfiles.first } == firstProfile,
      "\(await reading { profLib.recentProfiles })")

await MainActor.run { profLib.createProfile("Recent One") }
check("making a profile puts it at the front",
      await reading { profLib.recentProfiles.first } == "Recent One",
      "\(await reading { profLib.recentProfiles })")
await MainActor.run { profLib.noteProfileOpened(firstProfile) }
check("...and choosing another moves that one to the front instead",
      await reading { profLib.recentProfiles.first } == firstProfile,
      "\(await reading { profLib.recentProfiles })")
check("...without listing the same profile twice",
      await reading { profLib.recentProfiles.filter { $0 == firstProfile }.count } == 1,
      "\(await reading { profLib.recentProfiles })")

// A rename is the same profile under a new name: one entry, under the new one —
// two entries would offer to reopen a profile that no longer exists.
await MainActor.run { profLib.switchProfile(to: "Recent One") }
await MainActor.run { profLib.renameActiveProfile(to: "Renamed One") }
check("a rename moves the recent entry to the new name",
      await reading { profLib.recentProfiles }.contains("Renamed One"),
      "\(await reading { profLib.recentProfiles })")
check("...and leaves nothing under the old one",
      !(await reading { profLib.recentProfiles }).contains("Recent One"),
      "\(await reading { profLib.recentProfiles })")

let reopenLib = await MainActor.run { Library() }
check("the recent list is there after a relaunch",
      await reading { reopenLib.recentProfiles }.first == "Renamed One",
      "\(await reading { reopenLib.recentProfiles })")

// Left as it was found. The next section duplicates `firstProfile` and asks
// whether the copy inherited ITS headings, so those have to be the ones in hand
// — the headings in memory belong to whichever profile is in force.
await MainActor.run { profLib.switchProfile(to: firstProfile) }

// Same rule the pins and Recents follow: a duplicate carries on where the
// original left off, so it inherits the filing.
_ = await profLib.duplicateProfile(firstProfile, as: "Filed Copy")
check("a duplicated profile inherits the headings",
      await reading { profLib.group(of: "Iceland") } == "Place")

// And it has to survive a relaunch, or it was only ever in memory.
await MainActor.run { profLib.switchProfile(to: firstProfile) }
await MainActor.run { profLib.save() }
let headReload = await MainActor.run { Library() }
check("a relaunch comes back to that profile's own filing",
      await reading { headReload.group(of: "Iceland") } == "Place",
      "\(await reading { headReload.knownGroups() })")

try? FileManager.default.removeItem(atPath: profSupport)

// ---------------------------------------------------------------------------
// What a half-installed Mac can do — against the REAL probe
// ---------------------------------------------------------------------------
// `test_ai_capability.swift` mirrors the probe's shape by hand, which is why it
// could not catch this: face recognition is YuNet plus SFace and reads neither
// the image tower nor the prompt table, but `probeCoreML` listed both as
// blockers on EVERY feature. Someone who downloaded only the face pack was told
// face recognition was not ready, for a reason naming a model it does not use,
// that installing the face pack could never clear (reported 2026-09-17).
let capSupport = NSTemporaryDirectory() + "fvp-capability-\(UUID().uuidString)"
let capSaved = Paths.support
Paths.support = capSupport
try? FileManager.default.createDirectory(
    atPath: (capSupport as NSString).appendingPathComponent("tags"),
    withIntermediateDirectories: true)

func capInstallFaceModels() {
    for url in [FaceDetector.modelURL(root: capSupport), SFaceEmbedder.modelURL(root: capSupport)] {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
func capInstallVisual() {
    try? FileManager.default.createDirectory(at: VisionEmbedder.modelURL(root: capSupport),
                                             withIntermediateDirectories: true)
    try? Data("{}".utf8).write(to: PromptTable.jsonURL(root: capSupport))
    try? Data([0, 1, 2, 3]).write(to: PromptTable.binURL(root: capSupport))
}

// Nothing installed: every feature is off, and faces say so in their own words.
let capBare = AICapability.probeCoreML()
check("with nothing installed no feature works",
      !capBare.works(.faces) && !capBare.works(.tags) && !capBare.works(.classify))
check("...and faces name the face models as what is missing",
      (capBare.blockers[.faces] ?? []).contains(.modelMissing("face recognition")))

// The reported case: ONLY the face pack.
capInstallFaceModels()
let capFacesOnly = AICapability.probeCoreML()
check("the face pack alone is enough for face recognition",
      capFacesOnly.works(.faces), "\(capFacesOnly.blockers[.faces] ?? [])")
check("...and face recognition is never blocked on the image tower",
      !(capFacesOnly.blockers[.faces] ?? []).contains(.modelMissing("vision")))
check("...nor on the prompt table",
      !(capFacesOnly.blockers[.faces] ?? []).contains(.modelMissing("prompt table")))
check("...while the visual features still say what THEY are missing",
      !capFacesOnly.works(.tags)
        && (capFacesOnly.blockers[.tags] ?? []).contains(.modelMissing("vision")))

// The mirror image: the visual models without the face pack. Faces must go back
// to being blocked, or the scoping has simply stopped checking.
try? FileManager.default.removeItem(at: SFaceEmbedder.modelURL(root: capSupport))
capInstallVisual()
let capVisualOnly = AICapability.probeCoreML()
check("tag suggestions work on the tower and the prompt table alone",
      capVisualOnly.works(.tags), "\(capVisualOnly.blockers[.tags] ?? [])")
check("...and half a face pack is still not face recognition",
      !capVisualOnly.works(.faces)
        && (capVisualOnly.blockers[.faces] ?? []).contains(.modelMissing("face recognition")))
check("...and classify still waits for the Safe/NSFW model by name",
      !capVisualOnly.works(.classify)
        && (capVisualOnly.blockers[.classify] ?? [])
            .contains(.modelMissing("Safe / NSFW classifier")))

// Both packs: everything the Core ML engine offers is available at once.
capInstallFaceModels()
try? FileManager.default.createDirectory(at: NSFWClassifier.modelURL(root: capSupport),
                                         withIntermediateDirectories: true)
let capAll = AICapability.probeCoreML()
check("with every model installed no feature is blocked",
      capAll.works(.faces) && capAll.works(.tags) && capAll.works(.classify))
try? FileManager.default.removeItem(atPath: capSupport)
Paths.support = capSaved

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
