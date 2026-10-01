# FolderVideoPlayer

A native macOS video player for the folders you already have. Point it at a
folder and it plays the lot, back to back, with tags, favorites and a
duplicate finder — and, if you want them, on-device AI features that suggest
tags, recognise the people you name and flag what is not safe for work.

**Everything runs on your Mac.** The AI is Core ML, in the app's own process:
no account, no cloud service, and no video, frame or tag leaves the machine.

## Features

- **Folder playback** — open a folder (or a network share) and play every video
  in it, on loop, with resume positions and a poster-frame or list playlist.
- **Tags and favorites** — kept in their own files beside your videos; the video
  files themselves are never modified.
- **Triage** — *Tags ▸ Start Triage* (⇧⌘T) goes through the videos on screen
  one at a time and takes your answers from the keyboard. Each video shows
  numbered chips — the AI's suggestions, then your usual tags: **1–9** add or
  remove one, **⌥1–9** say a suggestion is wrong, **A** accepts everything
  shown, **Return** moves on, **↓** skips, **⌘Z** takes an answer back. A video
  you leave with no tag is set aside so it does not come round again. Nothing
  you look at is marked watched or given a resume point.
- **Combined playlists** — ⌘-click several tags, star ratings, people or file
  facts in the library panel to play every video carrying **any** of them, or
  only those carrying **all** of them.
- **Watch state and Library Overview** — each video is unwatched, in progress
  or watched (Mark Watched / Unwatched by hand, for a selection too); View ▸
  Library Overview (⌘0) lists Continue Watching, Recently Added, Recently
  Watched, Unwatched, tag suggestions to review, videos that still need tags
  and unfinished analysis, each one click from a playlist — and the last two
  one click from triage.
- **Moments** — mark a point or a stretch of a video (⌘B, or from a transcript
  line or something the AI saw), name it, add a note, jump back from the list or
  the marks on the scrubber, and export a stretch as its own clip.
- **Smart collections** — save a question about the library ("unwatched videos
  of Anna rated 4★ or more", "transcripts that mention *beach*", "files that
  need converting") and it keeps itself up to date: tags, people, file facts
  (date, camera, quality, place), ratings,
  recording date, date added, transcript text, watch state, analysis state,
  Safe/NSFW verdict and file state, matched by all or any of the rules.
- **Tag profiles** — several people can share a Mac or a NAS without writing
  over each other's tags.
- **Duplicate finder** — finds identical copies and lets you look before
  anything is moved to the Trash.
- **Sharing** — share a video through the macOS share menu (AirDrop, Messages,
  Mail…), or *Prepare for Sharing* a new copy: original quality in an MP4,
  1080p, 720p or a smaller file, optionally trimmed, with the transcript as
  `.srt`/`.vtt` beside it or everything in one ZIP. The original is never
  changed. MKV, AVI, WebM and FLV sources need FFmpeg installed.
- **Hidden videos** — keep some videos out of the playlist behind a password.
- **Organize folders** — *File ▸ Organize Folders…* (⌥⌘O): make, rename and
  move folders, drag videos between them, and delete a folder once it holds
  nothing. Tags, stars, resume points and subtitle files go with every move —
  for everyone who tagged the videos, on this Mac, other Macs and the Apple TV.
  A video moved to the Trash keeps its tags out of sight until it is put back.
- **Optional AI features**, downloaded from inside the app (Settings → AI):

  | Bundle | What it adds | Download |
  |---|---|---|
  | Tag suggestions | tag suggestions from the picture, look-alikes, learning from your own tags | ≈344 MB |
  | Safe / NSFW | a Safe/NSFW verdict that learns from your corrections | ≈159 MB |
  | Face recognition | finding faces, and the people you name | ≈18 MB |
  | Speech transcription | a searchable transcript of what is said (WhisperKit) | ≈646 MB |

  The video you are watching is analysed while it plays; nothing else is
  scanned in the background, and one switch in Settings turns that off.

- **Transcript editing and export** — correct a transcript's words and times
  (split, merge, insert, delete, shift a line or the whole transcript, with undo),
  check each line against the video, and export it as `.srt`, `.vtt`, `.txt`,
  `.csv` or `.json`. The machine's original transcription is kept, so
  *Restore Original* is always one click away. Edit right in the transcript
  panel under the video (its Edit button, or View → Edit Transcript).

- **Subtitles and audio tracks** — pick among a file's own subtitle and audio
  tracks without restarting playback, show an `.srt`/`.vtt` file that sits beside
  the video (or any one you choose), or the transcript. Choices are remembered
  per video; a choice a file cannot honour falls back to Automatic and says so.

- **Background upkeep (opt-in)** — tick a pinned folder in Settings →
  Background (or right-click it: *Keep Up to Date in Background*) and new,
  moved and removed videos are noticed on their own; poster frames and dates —
  and, if you choose, the installed AI passes — are done without playing each
  video. Pauses while you watch and on battery by default; hidden videos are
  never looked at.

Playback uses AVFoundation, so `.mp4`, `.m4v` and `.mov` play; `.mkv`, `.avi`,
`.webm` and `.flv` are listed and taggable but not played.

## Requirements

- macOS 14 or later
- Apple silicon recommended for the AI features

## Building from source

```bash
git clone https://github.com/tangrick/FolderVideoPlayer.git
cd FolderVideoPlayer
open FolderVideoPlayer.xcodeproj
```

Built with Xcode 26.5. Before the first build, pick your own team under
*Signing & Capabilities* (or sign to run locally). Swift Package Manager
fetches the one dependency, [WhisperKit](https://github.com/argmaxinc/WhisperKit).

The tests need no Xcode project, only `swiftc`:

```bash
sh Tests/run.sh
```

Some stages check the Swift code against the Python reference engine and need a
Python with numpy (and torch for a few) — point `FVP_PARITY_PY` at it. The
real-model stages need the Core ML models on disk (`FVP_MODELS_DIR`) and a test
video (`FVP_TEST_VIDEO`); each stage says what it needs at the top of its
`Tests/run_*.sh`.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how the app is put together:
  playback, data files, tag profiles, hidden videos, duplicates, the AI bundles
- [`docs/classification-design.md`](docs/classification-design.md) — the
  classification and tag-suggestion pipeline
- [`docs/clean-start-checklist.md`](docs/clean-start-checklist.md) — the
  new-user test a release has to pass
- `AnalysisEngine/` — the Python reference engine the Swift/Core ML code is
  checked against; not needed to run the app

## Status

A personal project, shared as is. Issues and pull requests are welcome, but
there is no promise of support or of a reply.

## License

[MIT](LICENSE).

The AI models are not in this repo. They are Core ML conversions, downloaded
from [FolderVideoPlayerSwift-AI](https://github.com/tangrick/FolderVideoPlayerSwift-AI)
releases, and each keeps its own license:

| Model | Used for | License |
|---|---|---|
| [google/siglip2-base-patch16-224](https://huggingface.co/google/siglip2-base-patch16-224) | tag suggestions | Apache-2.0 |
| [Falconsai/nsfw_image_detection](https://huggingface.co/Falconsai/nsfw_image_detection) | Safe / NSFW | Apache-2.0 |
| [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet) (OpenCV Zoo) | face detection | MIT |
| [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) (OpenCV Zoo) | face recognition | Apache-2.0 |
| [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) | speech transcription | MIT |
