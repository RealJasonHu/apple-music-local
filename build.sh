#!/bin/bash
# Assemble an arm64 macOS application from explicit runtime/source inputs only.
set -euo pipefail
IFS=$'\n\t'

APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHON_SOURCE="$APP_ROOT/.build-support/python"
PACKAGES_SOURCE="$APP_ROOT/.build-support/site-packages"
DIST="$APP_ROOT/dist"
APP_NAME="Apple Music Local.app"
OUTPUT="$DIST/$APP_NAME"
STAGING=""

fail() { printf 'Build error: %s\n' "$*" >&2; exit 1; }
cleanup() {
    case "$STAGING" in
        "$DIST"/.build.*) if [[ -d "$STAGING" && ! -L "$STAGING" ]]; then /bin/rm -rf -- "$STAGING"; fi ;;
    esac
}
trap cleanup EXIT

[[ "$(uname -m)" == arm64 ]] || fail "Run this build on an Apple Silicon Mac."
/bin/bash "$APP_ROOT/scripts/bootstrap.sh"
[[ -x "$PYTHON_SOURCE/bin/python3.12" ]] || fail "Standalone Python runtime is missing."
[[ -d "$PACKAGES_SOURCE/gamdl" ]] || fail "Gamdl site-packages are missing."
[[ -f "$APP_ROOT/backend/worker.py" ]] || fail "backend/worker.py is missing."
[[ -f "$APP_ROOT/Info.plist" ]] || fail "Info.plist is missing."
[[ -f "$APP_ROOT/Assets/DrawIcon.swift" ]] || fail "Icon drawing source is missing."
shopt -s nullglob
SWIFT_SOURCES=("$APP_ROOT"/Sources/*.swift)
BACKEND_SOURCES=("$APP_ROOT/backend/worker.py")
[[ ${#SWIFT_SOURCES[@]} -gt 0 ]] || fail "No Swift sources in Sources/."
[[ ! -L "$DIST" ]] || fail "Refusing a symlinked dist directory."
[[ ! -L "$OUTPUT" ]] || fail "Refusing to replace a symlinked app bundle."
/usr/bin/xcrun --find swiftc >/dev/null
/usr/bin/plutil -lint "$APP_ROOT/Info.plist"
/bin/mkdir -p -- "$DIST"
STAGING="$(/usr/bin/mktemp -d "$DIST/.build.XXXXXX")"
APP="$STAGING/$APP_NAME"
RESOURCES="$APP/Contents/Resources"
/bin/mkdir -p -- "$APP/Contents/MacOS" "$RESOURCES/backend" "$RESOURCES/licenses"

printf 'Compiling native arm64 application…\n'
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -O \
    -file-prefix-map "$APP_ROOT=/AppleMusicLocal" -debug-prefix-map "$APP_ROOT=/AppleMusicLocal" \
    -target arm64-apple-macosx14.0 -framework SwiftUI -framework AppKit -framework WebKit \
    "${SWIFT_SOURCES[@]}" -o "$APP/Contents/MacOS/AppleMusicLocal"
/bin/cp -- "$APP_ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

printf 'Rendering application icon…\n'
/usr/bin/xcrun swiftc -swift-version 5 -O -framework AppKit \
    -file-prefix-map "$APP_ROOT=/AppleMusicLocal" -debug-prefix-map "$APP_ROOT=/AppleMusicLocal" \
    "$APP_ROOT/Assets/DrawIcon.swift" -o "$STAGING/draw-icon"
"$STAGING/draw-icon" "$STAGING/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"

printf 'Bundling isolated Python, dependencies, and backend…\n'
# These two allowlisted directories contain runtime code, never user state.
/usr/bin/rsync -a --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' \
    "$PYTHON_SOURCE/" "$RESOURCES/python/"
/usr/bin/rsync -a --exclude='__pycache__/' --exclude='*.pyc' --exclude='.DS_Store' \
    --exclude='_virtualenv.pth' --exclude='_virtualenv.py' --exclude='/bin/' \
    "$PACKAGES_SOURCE/" "$RESOURCES/site-packages/"
/bin/cp -- "${BACKEND_SOURCES[@]}" "$RESOURCES/backend/"
/bin/cp -- "$APP_ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
/bin/cp -- "$APP_ROOT/LICENSE" "$RESOURCES/licenses/AppleMusicLocal-MIT.txt"
/bin/cp -- "$APP_ROOT/requirements.lock.txt" "$RESOURCES/requirements.lock.txt"
/bin/cp -- "$APP_ROOT/scripts/dependencies.json" "$RESOURCES/dependencies.json"
/usr/bin/rsync -a "$APP_ROOT/.build-support/python-licenses/" "$RESOURCES/licenses/python-runtime/"
/usr/bin/rsync -a "$APP_ROOT/.build-support/ffmpeg/licenses/" "$RESOURCES/licenses/audio/"
/bin/cp -- "$APP_ROOT/vendor-source/audio-sources.json" "$RESOURCES/licenses/audio-sources.json"

printf 'Checking relocated runtime and recording licenses…\n'
/usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 \
    PYTHONHOME="$RESOURCES/python" \
    PYTHONPATH="$RESOURCES/site-packages:$RESOURCES/backend" \
    PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
    "$RESOURCES/python/bin/python3.12" - "$RESOURCES" <<'PY'
import contextlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
import gamdl
import gamdl._ammuxer
import imageio_ffmpeg
from gamdl.cli.cli import main
import certifi

assert Path(sys.prefix).resolve() == root / "python", sys.prefix
assert Path(gamdl.__file__).resolve().is_relative_to(root), gamdl.__file__
ffmpeg = Path(imageio_ffmpeg.get_ffmpeg_exe()).resolve()
assert ffmpeg.is_relative_to(root), str(ffmpeg)
ssl.create_default_context(cafile=certifi.where())
subprocess.run([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.05", "-f", "null", "-"],
               check=True, stdin=subprocess.DEVNULL, capture_output=True)
licenses = root / "licenses"
text = io.StringIO()
with contextlib.redirect_stdout(text):
    license._Printer__setup()
    print("\n".join(license._Printer__lines))
(licenses / "CPython-LICENSE.txt").write_text(text.getvalue())
for option, filename in [("-L", "FFmpeg-LICENSE.txt"), ("-version", "FFmpeg-BUILD.txt")]:
    result = subprocess.run([str(ffmpeg), option], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (licenses / filename).write_text(result.stdout)
record = {
    "python": sys.version.split()[0],
    "gamdl": importlib.metadata.version("gamdl"),
    "imageio_ffmpeg": importlib.metadata.version("imageio-ffmpeg"),
    "gamdl_native_extension": "imported",
    "ffmpeg_smoke": "passed",
    "architecture": "arm64",
    "authentication": "not_tested_by_packaging",
    "source_user_data_included": False,
}
(root / "runtime-verification.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, ensure_ascii=False))
PY

printf 'Ad-hoc signing embedded Mach-O files and application…\n'
# Only staged copies are altered; original runtimes and signatures are untouched.
/usr/bin/xattr -cr "$APP"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON_SOURCE/bin/python3.12" - "$APP" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
         b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
         b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
count = 0
for path in sorted(root.rglob("*")):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as handle:
        is_macho = handle.read(4) in magic
    if is_macho:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        count += 1
print(f"Signed {count} embedded Mach-O files.")
PY
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

# Swap only the fixed output bundle after all compilation and validation succeed.
PREVIOUS="$STAGING/previous.app"
if [[ -e "$OUTPUT" ]]; then
    [[ -d "$OUTPUT/Contents" ]] || fail "Existing output is not an app bundle."
    /bin/mv -- "$OUTPUT" "$PREVIOUS"
fi
if ! /bin/mv -- "$APP" "$OUTPUT"; then
    if [[ -d "$PREVIOUS" ]]; then /bin/mv -- "$PREVIOUS" "$OUTPUT"; fi
    fail "Could not publish app bundle."
fi
printf 'Built and verified: %s\n' "$OUTPUT"
