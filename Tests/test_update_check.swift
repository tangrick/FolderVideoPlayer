// Verifies UpdateCheck's version comparison and release decoding. No network:
// the reply is a fixture shaped like GitHub's releases/latest.

import Foundation

func check(_ name: String, _ cond: Bool) {
    print(cond ? "ok   \(name)" : "FAIL \(name)")
    if !cond { exit(1) }
}

check("1.1.10 is newer than 1.1.9", UpdateCheck.isNewer("1.1.10", than: "1.1.9"))
check("1.1.9 is not newer than 1.1.10", !UpdateCheck.isNewer("1.1.9", than: "1.1.10"))
check("the same version is not newer", !UpdateCheck.isNewer("v1.1.10", than: "1.1.10"))
check("1.2 equals 1.2.0", !UpdateCheck.isNewer("1.2", than: "1.2.0")
                          && !UpdateCheck.isNewer("1.2.0", than: "1.2"))
check("a leading v is ignored", UpdateCheck.isNewer("v2.0.0", than: "1.9.9"))
check("a malformed tag never reads as newer", !UpdateCheck.isNewer("vnext", than: "1.0.0"))
check("bare strips the v", UpdateCheck.bare("v1.1.10") == "1.1.10")

let reply = """
{"tag_name":"v1.1.11","html_url":"https://github.com/tangrick/FolderVideoPlayer/releases/tag/v1.1.11",
 "assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
           {"name":"FolderVideoPlayer-v1.1.11.dmg","browser_download_url":"https://example.com/a.dmg"}],
 "draft":false}
""".data(using: .utf8)!
let release = try! JSONDecoder().decode(UpdateCheck.Release.self, from: reply)
check("the version comes from the tag", release.version == "1.1.11")
check("the dmg asset is picked", release.dmg?.absoluteString == "https://example.com/a.dmg")
// --- installing -------------------------------------------------------------
let report = "Executable=/Applications/X.app/Contents/MacOS/X\nTeamIdentifier=4DMMS5733P\nSealed Resources version=2"
check("the signing team is read from codesign's report",
      UpdateCheck.teamIdentifier(fromCodesignReport: report) == "4DMMS5733P")
check("an unsigned or ad hoc app has no team",
      UpdateCheck.teamIdentifier(fromCodesignReport: "Signature=adhoc\nTeamIdentifier=not set") == nil)
check("an Xcode build never replaces itself",
      UpdateCheck.cannotInstallInPlace(bundlePath: "/Users/x/Library/Developer/Xcode/DerivedData/F-abc/Build/Products/Debug/FolderVideoPlayer.app") != nil)

let fm = FileManager.default
let scratch = NSTemporaryDirectory() + "fvp-swap-\(UUID().uuidString)"
try! fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: scratch) }
check("a writable folder can take the swap",
      UpdateCheck.cannotInstallInPlace(bundlePath: scratch + "/FolderVideoPlayer.app") == nil)

/// Run the swap script against fake bundles, without its final `open`.
func swap(_ app: String, _ new: String, pid: Int32) -> Int32 {
    let script = UpdateCheck.swapScript(installed: app, staged: new, pid: pid)
        .replacingOccurrences(of: "open \"$APP\"", with: ": no open in a test")
    let file = scratch + "/swap-\(UUID().uuidString).sh"
    try! script.write(toFile: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [file]
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}
func bundle(_ path: String, _ marker: String) {
    try! fm.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
    fm.createFile(atPath: path + "/Contents/marker", contents: Data(marker.utf8))
}
func marker(_ path: String) -> String? {
    fm.contents(atPath: path + "/Contents/marker").map { String(decoding: $0, as: UTF8.self) }
}

// A quote in the path must not break the script.
let app = scratch + "/Quincy's Apps/FolderVideoPlayer.app", new = scratch + "/Quincy's Apps/.FolderVideoPlayer.app.update"
bundle(app, "old"); bundle(new, "new")
// Waits for the app to quit: a process that lives ~1 s stands in for it.
let waiter = Process()
waiter.executableURL = URL(fileURLWithPath: "/bin/sleep"); waiter.arguments = ["1"]
try! waiter.run()
let started = Date()
_ = swap(app, new, pid: waiter.processIdentifier)
check("the swap waits for the app to quit", Date().timeIntervalSince(started) > 0.8)
check("the new app is in place", marker(app) == "new")
check("no staged copy is left", !fm.fileExists(atPath: new))
check("no old copy is left", !fm.fileExists(atPath: app + ".old"))

// A failed swap (nothing staged) puts the old app back instead of leaving none.
bundle(app, "kept")
_ = swap(app, scratch + "/missing.app", pid: 999_999)
check("a failed swap keeps the old app", marker(app) == "kept")

print("update check: all passed")
