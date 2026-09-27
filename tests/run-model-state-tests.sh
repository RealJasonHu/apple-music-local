#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "$TEST_DIR/.." && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/music-local-model.XXXXXX")"
cleanup() { /bin/rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

# Only redirect storage construction; all state-machine methods are the actual
# production source. Fail closed if that initializer changes in a future edit.
/usr/bin/python3 - "$APP_ROOT/Sources/Model.swift" "$TEST_ROOT/Model.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'supportURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Apple Music Local")'
assert source.count(needle) == 1, "Storage initializer changed: update the isolated test seam before running"
Path(sys.argv[2]).write_text(source.replace(needle, 'supportURL = ModelTestSandbox.newSupportURL()'))
PY

/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -O \
    -target arm64-apple-macosx14.0 -framework SwiftUI -framework AppKit \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$TEST_ROOT/Model.swift" "$TEST_DIR/ModelStateTests.swift" \
    -o "$TEST_ROOT/model-state-tests"
MUSICLOCAL_TEST_ROOT="$TEST_ROOT" "$TEST_ROOT/model-state-tests"
