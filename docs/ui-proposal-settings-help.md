# Settings · Help · first-run · tag panel — proposed (Sep 11 '26)

Mockup: `docs/ui-proposal-settings-help.html` (open in a browser, or the
`::preview` frame in chat). Nothing implemented yet — this file is the spec to
build against once approved.

## 1. Settings window (⌘,)

New `Settings { … }` scene in `FolderVideoPlayerApp.swift`. The window needs
its own `.environmentObject`s (`library`, `app`, `engine`, `analysis`,
`faceStore`) — a Settings scene is a separate scene, so it gets no window's
injected objects. Five tabs, `TabView`:

| Tab | Controls | Wires to |
|---|---|---|
| General | Skip step (5/10/15/30/60s) · default speed · start order · resume on/off · ask profile at startup | `Tuning.skipSeconds` becomes `library.skipSeconds`; `library.speed`, `order`, `askProfileAtStartup` |
| Appearance | Default list/grid · poster frames · panel widths + Reset · click-to-play in grid | `library.playlistStyle`, `showThumbnails`, `playlistWidth`, `librarySidebarWidth` |
| AI & Privacy | Face Recognition · fingerprint while playing · plain-English privacy line · support-folder Open | `library.facesEnabled`, `watchDupes`, `Paths.support` |
| Library | Profile name + list (link to Tag Profiles) · Favorites tag name · recent length · Open support folder · Reset library data (type-to-confirm) | `library.person`, `recentMax`, `Paths.*` |
| Advanced | Engine health (python path, model present, trained heads count) · Check for Updates · Reveal log | `AnalysisEngine`, existing update check |

Rules that already apply in this app and must survive here:
- New persisted fields are **Optional** in `PersistedState` (pitfall 7).
- A control that can do nothing is **disabled with a reason**, never hidden.
- The Face Recognition toggle **moves** to Settings — it must not exist in two
  places driving the same flag; the Tags menu keeps a disabled-with-reason
  link only if the menu item is needed for discoverability.

## 2. Help menu

`CommandGroup(replacing: .help)` with three sheets (plain `View`s, `.sheet`
from a small `HelpWindow` host, or `Window` scenes):

1. **Quick start** — four numbered steps, no jargon.
2. **Keyboard shortcuts** — every shortcut currently only discoverable via a
   tooltip. Source of truth: `Menus.swift` + `TransportBar` + sidebar.
3. **Where my data lives** — support folder, Open button, one line per file,
   plus "tags cross devices, fingerprints do not".

No network calls in any sheet; no `@EnvironmentObject` inside `.sheet` unless
injected at root (pitfall 31).

## 3. First run

`PlayerScreen.stage`'s empty branch (currently one grey line at
`PlayerWindow.swift:222-232`) becomes a real block: title, one sentence, and
three actions — **Open a Folder…** (`chooseFolder`), **Open Recent** (menu of
`library.recent`, hidden when empty), **Take the tour** (opens Quick start).
Shown only while `playback.playlist.isEmpty`.

## 4. Tag panel hierarchy

`TagPanel.swift`:
- People / Suggested / Your-tags section headers become collapsible buttons
  with `@AppStorage` memory (same fold pattern as the sidebar Years group,
  pitfall 49). Force-open whenever a section has content the user must see
  (suggestions pending; a filter in force) — never hide a live filter.
- The reject ✕ on tag chips: **always drawn, full-opacity-safe hit target**
  (≥22 pt `contentShape`) — the existing hover affordance stays as extra
  emphasis, but presence must never change layout (pitfall 58).
- Count line under the "Your tags" header: `N on this video · M rejected`.
- `＋ New tag…` row so comma entry is not the only way in.

## 5. Cleanups in the same pass

- Delete `Views/AnalysisWindow.swift` (645 lines, zero callers —
  `grep -rn AnalysisWindow` returns only its own declaration). Keep
  `LabelChipStyle` if anything else uses it; it is defined there.
- One word for the engine job: **Classify** (kill "Analyse"/"Scan" in
  user-facing copy; internal names may stay).
- AI look-alike candidates render in grid view too (today `aiSection` lives
  inside `listView` only — pitfall 19's known gap).

## Shipped (Sep 11 '26)

All four items above, plus the follow-on pass from the same audit:

| Commit | What |
|---|---|
| `a744f57` | Settings window (⌘,) + Help menu |
| `129e837` | First-run screen |
| `3652f5a` | Tag panel folds + counts |
| `89c6463` | Look-alike candidates in grid view; "Classify" everywhere |
| `55ac47a` | `AnalysisWindow.swift` deleted, `LabelChipStyle` extracted |
| `4da98b1` | Skip buttons follow the Settings step |
| `d0daafd` | Tour offered once |
| `370cceb` | Drag-and-drop: window + app icon, `Info.plist` document types |
| `1289b7c` | Accessibility labels on every icon-only control |
| `3040837` | ⌘A / ⌘⇧A / ⌘R / ⌘⌫ in the Edit menu |
| `3ad7e9a` | Help shortcuts page updated |
| `6de8f10` | Info sheet (⌘I) — file, when, tags, engine, where |
| `7f2031f` | Sidebar sections stop moving (always drawn, fold, empty line) |

Every item from the audit is now shipped.

## Build order

1. Settings window + Help menu (new files only, no regressions possible).
2. First-run block.
3. Tag panel hierarchy.
4. Cleanups (dead file, copy, grid candidates).

Gate at each step: `xcodebuild … build` = BUILD SUCCEEDED **and**
`sh Tests/run.sh` passes, then a split commit with a conventional message.
Never `git checkout/restore`. User drives QA in the app after each step.
