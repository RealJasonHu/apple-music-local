#!/bin/bash
# Offline tests use generated audio and temporary synthetic account state only.
set -euo pipefail
IFS=$'\n\t'
APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
/bin/bash "$APP_ROOT/scripts/bootstrap.sh"
PYTHON="$APP_ROOT/.build-support/python/bin/python3.12"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/music-local-model.XXXXXX")"
cleanup() { [[ ! -d "$TEST_ROOT" || -L "$TEST_ROOT" ]] || /bin/rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

/usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 \
    PYTHONPATH="$APP_ROOT/.build-support/site-packages:$APP_ROOT/backend" \
    PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON" "$APP_ROOT/backend/test_worker.py"

FLAGS=(-parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 \
    -file-prefix-map "$APP_ROOT=/AppleMusicLocal" -debug-prefix-map "$APP_ROOT=/AppleMusicLocal" \
    -framework SwiftUI -framework AppKit -framework WebKit -module-cache-path "$TEST_ROOT/module-cache")
/usr/bin/xcrun swiftc "${FLAGS[@]}" "$APP_ROOT/Sources/AppleMusicSession.swift" \
    "$APP_ROOT/tests/AppleMusicSessionTests.swift" -o "$TEST_ROOT/session-tests"
"$TEST_ROOT/session-tests"
/usr/bin/xcrun swiftc "${FLAGS[@]}" "$APP_ROOT/Sources/Model.swift" \
    "$APP_ROOT/Sources/Backend.swift" "$APP_ROOT/Sources/AppleMusicSession.swift" \
    "$APP_ROOT/tests/LinkParsing.swift" -o "$TEST_ROOT/link-tests"
"$TEST_ROOT/link-tests"

# Redirect the storage constructor before running model tests, using the same
# production source seam as tests/run-model-state-tests.sh. Never use app data.
/usr/bin/env -i PATH=/usr/bin:/bin PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON" - "$APP_ROOT/Sources/Model.swift" "$TEST_ROOT/Model.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'supportURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Apple Music Local")'
assert source.count(needle) == 1, "Storage initializer changed: update the isolated test seam"
Path(sys.argv[2]).write_text(source.replace(needle, 'supportURL = ModelTestSandbox.newSupportURL()'))
PY
/usr/bin/xcrun swiftc "${FLAGS[@]}" "$TEST_ROOT/Model.swift" \
    "$APP_ROOT/tests/ModelStateTests.swift" -o "$TEST_ROOT/model-tests"
MUSICLOCAL_TEST_ROOT="$TEST_ROOT" "$TEST_ROOT/model-tests"
printf 'All offline tests passed; real account authentication was not exercised.\n'
