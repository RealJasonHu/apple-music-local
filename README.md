# Apple Music Local

A native Mac app for searching Apple Music and managing local audio downloads with your own subscription. Built with SwiftUI, WebKit, [Gamdl](https://github.com/glomatico/gamdl), and FFmpeg.

**[Download for Apple Silicon](https://github.com/RealJasonHu/apple-music-local/releases/latest)** · [中文说明](README.zh-CN.md) · [Validation](docs/TESTING.md)

Requires **macOS 14+ on Apple Silicon**. The interface is currently in Simplified Chinese. Downloads require an active Apple Music subscription and access to the selected content.

## What it does

- Sign in through Apple's official page inside the app. Keep the session locally across restarts, with separate online subscription verification.
- Search songs, albums, and playlists using the account's catalog region. Load more results, select several items, and add them to the queue.
- Download directly from a search result, or paste a batch of Apple Music share links.
- Choose **MP3 320 kbps**, **WAV**, or original **AAC/M4A** and a destination folder. Defaults to Downloads.
- Track progress, stop a batch, retry unfinished jobs, restore history, and reveal files in Finder.

The source is **lossy Apple Music web AAC**. WAV conversion does not create a lossless master, and MP3 adds another lossy encoding step. Native lossless, FLAC downloading, videos, Intel Macs, and automatic session renewal beyond Apple's authorization lifetime are not supported.

## Install and use

1. Download the ZIP from [Releases](https://github.com/RealJasonHu/apple-music-local/releases/latest), expand it, and move **Apple Music Local.app** to Applications.
2. Open the app and choose **在 App 内登录** / **账号与登录**. Complete Apple's sign-in and verification on the official page.
3. Choose **搜索音乐**, enter a song or artist, and select the result type. Choose the output format and destination, then download a result or add several results to the queue.
4. For existing share links, use **下载队列** → paste links → **添加到队列** → **开始下载**.

Release builds use a local ad-hoc signature and **are not notarized by Apple**. macOS may require explicit permission to open the downloaded app; see [Apple's instructions](https://support.apple.com/en-us/102445). No global security settings need to be disabled.

An existing valid session can be restored after restarting. Apple may expire or revoke it or require another verification. A compatible Cookie-file import is available in the account menu; select the file, never paste its contents into a link field or an issue.

## Local data

Credentials and history stay on the Mac under `~/Library/Application Support/Apple Music Local/`. The download token file uses permission `0600` in a `0700` directory; WebKit separately manages the app's persistent website data. No developer-operated account server or telemetry service is included. Apple and its media services receive the requests needed for sign-in, search, artwork, and downloads.

Each download attempt uses its own folder under the chosen destination (`Originals`, `MP3`, or `WAV`), preserving previous output. Signing out clears the app's session and disables saved credentials; it keeps music and history.

## Build from source

On an Apple Silicon Mac with Xcode Command Line Tools:

```sh
git clone https://github.com/RealJasonHu/apple-music-local.git
cd apple-music-local
./build.sh
```

The bootstrap downloads a pinned standalone Python and locked dependencies; the generated app contains its runtime and needs no Homebrew or system Python. Build output is `dist/Apple Music Local.app`. See [build and dependency provenance](docs/BUILDING.md) for details.

```sh
./scripts/test.sh
```

Tests use synthetic credentials and audio, not a real Apple account. [Validation notes](docs/TESTING.md) distinguish automated checks, real-media verification, and untested first-time MFA flows.

## Code map

| Location | Purpose |
| --- | --- |
| `Sources/` | Native UI, persistent WebKit session, queue state, subprocess bridge |
| `backend/worker.py` | Subscription checks, catalog search, downloading, conversion |
| `tests/` | Swift session, queue-state, and link-parser checks |
| `backend/test_worker.py` | Python integration tests using mock services and synthetic audio |
| `Assets/` | Original application icon artwork |

## License and acknowledgements

Original app source is [MIT licensed](LICENSE). Bundled third-party components retain their own licenses, including copyleft and noncommercial terms; the complete binary distribution is **not entirely MIT licensed**. See [third-party notices](THIRD_PARTY_NOTICES.md) and the source/license materials attached to the release before redistributing it.

This project is independent of Apple Inc. Apple Music is an Apple trademark. It uses your own authorized subscription; no accounts, credentials, music, or subscription access are supplied with the app. Use it only for content and uses you are permitted to access and copy.
