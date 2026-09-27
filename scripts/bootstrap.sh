#!/bin/bash
# Prepare a pinned, private build runtime; no system Python or Homebrew needed.
set -euo pipefail
IFS=$'\n\t'

APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CACHE="$APP_ROOT/.build-support"
STAGING=""
fail() { printf 'Bootstrap error: %s\n' "$*" >&2; exit 1; }
cleanup() {
    case "$STAGING" in
        "$CACHE"/.python.*) [[ ! -d "$STAGING" || -L "$STAGING" ]] || /bin/rm -rf -- "$STAGING" ;;
    esac
}
trap cleanup EXIT
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "An Apple Silicon Mac is required."
[[ "$(sw_vers -productVersion | cut -d . -f 1)" -ge 14 ]] || fail "macOS 14 or later is required."
/usr/bin/xcrun --find swiftc >/dev/null
/usr/bin/xcrun --find clang >/dev/null
[[ ! -L "$CACHE" ]] || fail "Refusing a symlinked .build-support directory."
/bin/mkdir -p -- "$CACHE/downloads"
[[ ! -L "$CACHE/downloads" && ! -L "$CACHE/python" ]] || fail "Refusing symlinked runtime/cache directories."

# These values also live in dependencies.json. bootstrap.py checks agreement.
PYTHON_ARCHIVE='cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
PYTHON_URL='https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
PYTHON_SHA256='81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b'
ARCHIVE="$CACHE/downloads/$PYTHON_ARCHIVE"
[[ ! -L "$ARCHIVE" ]] || fail "Refusing a symlinked Python archive."
STAGING="$(/usr/bin/mktemp -d "$CACHE/.python.XXXXXX")"
if [[ ! -f "$ARCHIVE" ]]; then
    printf 'Downloading pinned CPython 3.12.14…\n'
    /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        --output "$STAGING/python.tar.gz" "$PYTHON_URL"
    [[ "$(/usr/bin/shasum -a 256 "$STAGING/python.tar.gz" | cut -d ' ' -f 1)" == "$PYTHON_SHA256" ]] || fail "Python download checksum mismatch."
    /bin/mv -- "$STAGING/python.tar.gz" "$ARCHIVE"
fi
[[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" == "$PYTHON_SHA256" ]] || fail "Cached Python archive checksum mismatch; remove that archive and retry."
if [[ ! -x "$CACHE/python/bin/python3.12" || ! -f "$CACHE/python/.archive-sha256" ]] || \
   [[ "$(cat "$CACHE/python/.archive-sha256" 2>/dev/null || true)" != "$PYTHON_SHA256" ]]; then
    /bin/mkdir -- "$STAGING/python"
    /usr/bin/tar -xzf "$ARCHIVE" --strip-components=1 -C "$STAGING/python"
    printf '%s\n' "$PYTHON_SHA256" > "$STAGING/python/.archive-sha256"
    [[ ! -e "$CACHE/python" ]] || /bin/mv -- "$CACHE/python" "$STAGING/previous-python"
    /bin/mv -- "$STAGING/python" "$CACHE/python"
fi
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 \
    PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
    "$CACHE/python/bin/python3.12" "$APP_ROOT/scripts/bootstrap.py" "$PYTHON_SHA256"
