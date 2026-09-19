# Clean-start verification — the full new-user pass (Task 5.4)

> **This is the gate that decides whether a DMG goes out.** Everything before it
> was tested on a machine that has spent two weeks building this app. The one
> question it cannot answer is the only one a stranger asks: *does this work on
> a Mac that has never seen any of this?*

The claim being tested is the whole point of the Core ML migration: **one DMG,
no dependencies, the player works immediately, and AI features are turned on
from inside the app by choosing what to download.** Nothing carried over from
the machine this was built on.

Run `Tests/check_clean_start.sh` first — it covers the part a machine can, and
it is fast. Then do the walk below by hand.

```bash
Tests/check_clean_start.sh                                            # newest built app
Tests/check_clean_start.sh /path/to/FolderVideoPlayer.app /path/to/dist
```

It fails if the bundle or the packed release contains a tag, a trained head, a
suggestion history, a named person, an `analysis.json`, the prompt table, a
model, or an absolute `/Users/…` path. A pass there is necessary, not
sufficient.

---

## Before you start: the release must carry the bundles

The app's download list is fetched from
`releases/latest/download/ai-bundles.json`. **That asset has to exist before the
walk means anything**, or step 3 fails on every account — including this one —
with "could not read the list of downloads" and no Install button to press, which
reads like a broken app rather than a release that was never published.

```bash
gh release view --repo tangrick/FolderVideoPlayerSwift-AI \
    --json tagName,assets -q '.tagName, (.assets[].name)'
# expect: a tag, then ai-bundles.json, the two .mlpackage.zip files,
#         s2_prompts.json and s2_prompts.f32

# and it must be readable with NO token, or the app cannot read it either:
curl -sS -o /dev/null -w '%{http_code}\n' \
    https://github.com/tangrick/FolderVideoPlayerSwift-AI/releases/latest/download/ai-bundles.json
# expect: 200
```

**It is a public repo on purpose, and it is not the app's repo.** The app fetches
the catalogue unauthenticated, and a private repo answers 404 to that — so a
catalogue published to the app's own (private) repo is invisible to every user,
including this machine. `AIBundleManifest.assetsRepo` names the public one, and
`Tests/check_clean_start.sh` fails if a packed catalogue disagrees with it.

To produce them: `FVP_REPO=tangrick/FolderVideoPlayerSwift-AI
docs/coreml-spike/pack_bundles.sh <models-dir> ./dist <new-tag>` and
`gh release create <new-tag> dist/assets/* dist/ai-bundles.json --repo
tangrick/FolderVideoPlayerSwift-AI` — the tag is baked into the catalogue's
URLs, so it must be chosen before packing, a tag that already exists cannot be
reused, and a repo with no commits refuses a release at all. See
`references/signing-and-notarization.md`, section 5.

---

## The account

A **separate macOS user account**, one that has never run this app and has none
of the tools this was developed against. Not a second login on the same account
— the point is a home directory with no history in it.

Before starting, confirm the account is genuinely bare:

```bash
which python3 ffmpeg          # expect: nothing
ls /opt/anaconda3 /opt/homebrew 2>&1   # expect: No such file or directory
ls ~/Library/Application\ Support/FolderVideoPlayerSwift 2>&1
```

If `which python3` finds `/usr/bin/python3`, that is macOS's own stub and is
fine — it is not the Python this app used to need, and under Core ML nothing
reads it. If `/opt/anaconda3` exists, the account is not clean.

## The walk

Every step must pass with **zero** data carried from the development machine.
Step 4 is the one that matters most: the app has to be worth installing before
any model is.

| # | Do this | It passes when |
|---|---|---|
| 1 | Install the DMG, open the app | It launches. No dialog about missing Python, ffmpeg, or models. |
| 2 | Look at the library | It is empty. No tags, no people, no verdicts, nothing. |
| 3 | Settings → AI | All three features are listed with what they add and what they cost, and each installable one offers **Install** with its size (≈67 MB, ≈159 MB, ≈18 MB). Nothing is downloaded yet. A row that cannot work says which model is missing and offers to fetch it. |
| 4 | Open a folder, play a video, tag it by hand, favorite it, run the duplicate finder | All of it works, with no model and no network. This is the promise the DMG makes. |
| 5 | Settings → AI → **Install** on Tag suggestions | A progress bar moves, the row ends **Ready**, and no relaunch is needed. |
| 6 | Open a video and look at the tag panel | Chips appear for what is on screen (or none do, honestly — the bar is deliberately high). |
| 7 | Settings → AI → **Install** on Safe / NSFW, then Classify a video | A Safe/NSFW verdict appears, with the model named in the Info sheet. |
| 8 | Mark a verdict wrong | The correction head is rebuilt from that one mark — `Train` reports a fitted head rather than refusing. |
| 9 | Quit and reopen | The installs survived. The library holds only what this account's own actions put in it. |
| 10 | Settings → AI → **Remove** on a bundle | The model is gone, the row goes back to offering Install, and the rest of the app is unaffected. |
| 11 | Settings → AI → **Install** on Face recognition (≈18 MB), then name a person once | The row ends **Ready**, and that name is offered on the person's other videos. Faces is the newest bundle, so it is also the check that a bundle added after a release installs without an app update. |

### What step 9 is really checking

`analysis.json` and `frames/` on the **development** machine must have stayed
there. Grep the test account for any path, tag, or person name from this
library and find nothing:

```bash
grep -rl "fvp-coreml-test\|$USER" \
    ~/Library/Application\ Support/FolderVideoPlayerSwift 2>/dev/null
# expect: no output
```

Anything that turns up is data that leaked into the shipped artifact, and it is
a stop-the-release finding — not a bug to fix next week.

### What step 6 will probably look like

`TagSuggester.vocabularyMargin` is deliberately high (0.06) after the Cruise
Ship report: on real footage, MobileCLIP-S2 clears it for about 2.8 tags per
video and offers nothing at all on roughly two thirds of them. **No chips is a
pass, not a failure.** The failure this bar prevents was a shipping app that
claimed to see 29 things in a clip that contained none of them.

## When it fails

The two failures worth distinguishing:

- **A step does nothing at all.** That is pitfall 0 — a control that neither
  acts nor explains. Fix it before rerunning anything.
- **A step works on the dev machine and not here.** Something is reading a
  path, an environment variable, or an installed tool that only exists there.
  `AICapability.probe()` is the first place to look.
- **The AI rows name Python or ffmpeg.** That is the one failure with a specific
  cause: the app is not running the shipped engine. Core ML is the default, so a
  row that says "needs Python with PyTorch" means the build is older than
  2026-09-12 or `~/.fvp-engine` on this account carries `mode=python`. Neither
  belongs on a clean account, and a stranger would see the same thing.

## The record

The plan asks for one line per task, kept as the same 240-video set the earlier
phases scored. For this task, record instead:

- the macOS version and machine the pass ran on
- the DMG's size, and the size of each bundle downloaded in step 5 and 7
- every step above, pass or fail, with what the screen said
- anything that needed a second attempt
