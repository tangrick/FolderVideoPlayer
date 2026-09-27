# Releasing

A release is a Developer ID–signed, notarized DMG built from a clean commit:

```bash
# 1. bump MARKETING_VERSION (both configurations) in FolderVideoPlayer.xcodeproj, commit
# 2. build, sign, notarize, staple, verify — about ten minutes plus Apple's queue
scripts/release.sh
```

The image lands at `dist/FolderVideoPlayer-v<version>.dmg` (`dist/` is ignored
by git) with its SHA-256 printed. Publishing — a GitHub release on this repo,
and the website — is a separate, deliberate step.

## What the script needs on the Mac

- A **Developer ID Application** certificate for the team in
  `scripts/exportOptions.plist`, in the login Keychain. The script finds it by
  team; no name or key is stored in the repo.
- A **notarytool Keychain profile** (default name `FolderVideoPlayer`, override
  with `FVP_NOTARY_PROFILE`). Create one once per Mac with an app-specific
  password: `xcrun notarytool store-credentials FolderVideoPlayer --team-id <TEAM>`
  (it prompts for the password, so it stays out of shell history).

## What it checks, so a bad image never reaches `dist/`

- the tree is clean and the DMG name is not already taken;
- the full test suite (skip with `--skip-tests` only when it has just passed);
- the exported app's version matches the project, it is signed with a
  Developer ID with the hardened runtime, and carries no `get-task-allow`;
- `Tests/check_clean_start.sh` — no library data baked into the bundle;
- notarization is **Accepted**, the ticket is stapled, and Gatekeeper accepts
  the image.

The AI models are not in the DMG; they are downloads described in
`docs/clean-start-checklist.md`.
