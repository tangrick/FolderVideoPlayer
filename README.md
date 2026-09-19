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
- **Tag profiles** — several people can share a Mac or a NAS without writing
  over each other's tags.
- **Duplicate finder** — finds identical copies and lets you look before
  anything is moved to the Trash.
- **Hidden videos** — keep some videos out of the playlist behind a password.
- **Optional AI features**, downloaded from inside the app (Settings → AI):

  | Bundle | What it adds | Download |
  |---|---|---|
  | Tag suggestions | tag suggestions from the picture, look-alikes, learning from your own tags | ≈344 MB |
  | Safe / NSFW | a Safe/NSFW verdict that learns from your corrections | ≈159 MB |
  | Face recognition | finding faces, and the people you name | ≈18 MB |
  | Speech transcription | a searchable transcript of what is said (WhisperKit) | ≈646 MB |

  The video you are watching is analysed while it plays; nothing else is
  scanned in the background, and one switch in Settings turns that off.

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
