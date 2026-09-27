# Building on an Apple Silicon Mac

Requires macOS 14+, the Xcode Command Line Tools (`xcode-select --install`), and internet access for the first bootstrap. The build does not install Homebrew or modify system Python.

```sh
git clone https://github.com/RealJasonHu/apple-music-local.git
cd apple-music-local
./scripts/test.sh
./build.sh
```

Output: `dist/Apple Music Local.app`. The app is self-contained, arm64, ad-hoc signed, and not notarized. Building locally does not install it into Applications or touch account state. Runtime session data is created only when the application is used.

## Pinned inputs

- `scripts/bootstrap.sh` checks the SHA-256 of the standalone CPython 3.12.14, build 20260901, arm64 install-only archive before extracting it.
- `scripts/dependencies.json` identifies exact Python artifacts and their hashes. `requirements.lock.txt` pins the application dependencies. Build-only tools are separately locked.
- Most dependencies install from wheels. Construct 2.8.8 is built from its exact source distribution with the pinned build tools.
- `vendor-source/audio-sources.json` pins FFmpeg 7.1 and LAME 3.100 source archives. Bootstrap fetches missing archives, verifies checksums, and runs `packaging/build_ffmpeg.sh`.
- FFmpeg is built for local audio processing with GPL, nonfree, network, and automatic external-library detection disabled. The app's HTTP transfers are handled separately by its backend. The resulting executable replaces the imageio wheel's original executable; `ffmpeg-replacement.json` records that replacement.
- The matching full Python build archive supplies standalone-runtime component license files. Its checksum and URL are pinned too.

Build caches live under `.build-support/`, and downloaded audio source archives live under `vendor-source/`. They are ignored by Git. Deleting those build caches forces preparation again; neither contains Apple account data.

Swift source/debug path mapping removes the checkout path from the app executable. Packaging copies an explicit set of program inputs, not the developer's Application Support, browser profile, queue, or music library.

## Tests

`./scripts/test.sh` bootstraps dependencies if needed, runs backend integration tests, then compiles and runs Swift session, link-parser, and queue-state tests. Synthetic audio and temporary state are isolated from the real application data directory.

The GitHub Actions workflow uses a standard Apple Silicon `macos-15` runner and runs the same tests, build, and signature check. It receives no Apple account credentials. See [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) for architecture labels.

## Rebuilding the audio component offline

Download **AppleMusicLocal-AudioSources-7.1-3.100.tar.xz** from the same release as the application and extract it. Its README describes the offline recipe; it contains the exact original FFmpeg/LAME archives and the build script, with no source patches. A rebuilt executable can be substituted for `imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1` before re-signing your own app.

The separate Python dependency-source asset includes exact source distributions for the GPL, MPL, and CC BY-NC-ND dependencies identified in [third-party notices](../THIRD_PARTY_NOTICES.md). Their upstream build files and licenses remain intact.

## Updating dependency locks

The checked-in lockfiles are the release inputs. `scripts/update-dependency-lock.py` is a maintainer tool; inspect its output, compare upstream license/version changes, and rerun tests and the build before distributing an updated bundle. Never substitute an unverified cached archive after a hash failure.
