# Source for the bundled audio converter

The application replaces imageio-ffmpeg's general-purpose binary with a locally
built FFmpeg 7.1 executable. This directory contains the exact, unmodified
FFmpeg 7.1 and LAME 3.100 source archives used by that build. URLs and SHA-256
digests are recorded in `audio-sources.json` and checked before compilation.

On a macOS 14 or newer Apple Silicon Mac with Xcode Command Line Tools installed:

```sh
bash packaging/build_ffmpeg.sh "$PWD/audio-build"
audio-build/bin/ffmpeg -version
```

Run those commands from the source bundle's top directory. Compilation is
offline and does not require Homebrew, Python, pkg-config, NASM or an account.
`AUDIO_BUILD_JOBS=4` is the default parallel build setting. Source files are not
patched. The recipe enables local AAC/ALAC/FLAC/MP3/PCM audio handling, JPEG/PNG
cover handling and the synthetic audio sources used by tests. Networking,
autodetection of optional libraries, GPL features and nonfree features are
disabled. The only non-system library linked into FFmpeg is LAME; the macOS SDK
provides system libraries including zlib. This build is not a general-purpose
video downloader or the original binary shipped by imageio-ffmpeg.

The resulting FFmpeg reports LGPL version 2.1 or later. LAME is licensed under
LGPL version 2 or later. Full license texts are included in the original source
archives and are also copied to `audio-build/licenses/` by the recipe. The
script records the compiler configuration, dynamic library list, source
manifest and pre-signing binary SHA-256 in the output directory. Different
Xcode versions and code signing can change binary bytes; this is a documented
source-matched build, not a claim of byte-for-byte reproducibility.

To modify or relink these libraries, unpack and edit their source archives,
update the corresponding manifest and source checksums in the recipe, and
rebuild. The app uses `imageio_ffmpeg.get_ffmpeg_exe()`: replace the generated
app's `Contents/Resources/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1`
with the rebuilt executable and re-sign the app using the repository's build
instructions. No private signing key or upstream account is needed for an
ad-hoc local build.

`AppleMusicLocal-AudioSources-7.1-3.100.tar.xz` contains this directory's inputs
and `packaging/build_ffmpeg.sh`; it should be offered alongside the app ZIP.
Other Python dependencies and their licenses are handled separately and are
not covered by these audio-component license terms.
