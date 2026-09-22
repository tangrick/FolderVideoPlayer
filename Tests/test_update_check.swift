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
print("update check: all passed")
