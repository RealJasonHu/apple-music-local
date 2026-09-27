# Third-party notices

Apple Music Local is an independent macOS interface to open-source and other publicly distributed tools. Apple Music is an Apple trademark; this project is not affiliated with or endorsed by Apple Inc. The waveform application icon is original AppKit artwork in `Assets/DrawIcon.swift`.

The repository's MIT license covers its original application source. It does **not** replace the licenses of bundled components or grant unrestricted rights to the complete application distribution.

## Runtime and audio components

| Component | Version | Upstream | Applicable license |
| --- | --- | --- | --- |
| CPython, standalone arm64 build | 3.12.14 / build 20260901 | [CPython](https://www.python.org/), [python-build-standalone](https://github.com/astral-sh/python-build-standalone) | PSF and bundled-component licenses |
| Gamdl | 3.9.1 | [glomatico/gamdl](https://github.com/glomatico/gamdl) | MIT |
| imageio-ffmpeg Python wrapper | 0.6.0 | [imageio/imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg) | BSD-2-Clause |
| FFmpeg, source-built audio configuration | 7.1 | [FFmpeg](https://ffmpeg.org/) | LGPL-2.1-or-later; no GPL/nonfree configuration options |
| LAME, statically linked to the FFmpeg executable | 3.100 | [LAME](https://lame.sourceforge.io/) | LGPL-2.0-or-later |

The release uses a separately built FFmpeg executable in place of the imageio wheel's original bundled binary. No FFmpeg or LAME source changes are applied. `packaging/build_ffmpeg.sh` records the build configuration. Exact upstream archives and checksums are recorded in `vendor-source/audio-sources.json`; the **AppleMusicLocal-AudioSources-7.1-3.100.tar.xz** release asset includes those archives and an offline rebuild recipe. Modified libraries can be rebuilt through that same recipe. The application launches FFmpeg as a subprocess; it does not link the Swift executable to these libraries.

Each binary release page supplies a corresponding source download alongside the app. Full FFmpeg/LAME license texts and configuration output are included under `Contents/Resources/licenses/`. The pinned Python runtime includes its component license files; the generated `CPython-LICENSE.txt` is also included there.

## Python dependencies with additional terms

These are separate dependency distributions; they are not relabeled as MIT:

| Component | Version | Upstream | License / terms |
| --- | --- | --- | --- |
| Certifi | 2026.7.22 | [certifi](https://github.com/certifi/python-certifi) | MPL-2.0 |
| pywidevine | 1.9.0 | [pywidevine](https://github.com/devine-dl/pywidevine) | GPL-3.0-only |
| Mutagen | 1.48.1 | [mutagen](https://github.com/quodlibet/mutagen) | GPL-2.0-or-later |
| Unidecode | 1.4.0 | [Unidecode](https://github.com/avian2/unidecode) | GPL-2.0-or-later |
| pyplayready | 0.8.5 | [pyplayready](https://git.gay/ready-dl/pyplayready) | Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International |

pyplayready is supplied as an **unmodified dependency** with its original license and attribution. Its noncommercial and no-derivatives conditions continue to apply; the app's source license does not grant commercial redistribution rights to that dependency. No endorsement by these projects is implied.

The **Apple-Music-Local-2.0.0-Python-Dependency-Sources.tar.gz** release asset provides the exact upstream source distributions of these five packages. `packaging/python-sources.json` records original download locations and SHA-256 hashes. Their original source/build files, copyright notices and licenses remain in those archives.

`requirements.lock.txt` and `scripts/dependencies.json` list the complete pinned Python dependency set and artifact hashes. The application retains installed package metadata and license documents under `Contents/Resources/site-packages/*.dist-info/` and the standalone interpreter's `lib/python3.12/site-packages/`. Those individual license texts govern their respective components.

## Data exclusion

The source repository and release archives include no Apple account, browser cookies, passwords, subscription tokens, personal preferences, downloaded music, or local queue history. Users provide their own authorized account at runtime.
