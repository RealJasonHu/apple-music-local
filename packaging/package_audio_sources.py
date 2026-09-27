#!/usr/bin/env python3
"""Create the exact-source release asset from an explicit file allowlist."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output or root / "vendor-source" / "AppleMusicLocal-AudioSources-7.1-3.100.tar.xz"
    manifest = json.loads((root / "vendor-source/audio-sources.json").read_text())
    paths = [root / "packaging/build_ffmpeg.sh", root / "packaging/package_audio_sources.py",
             root / "vendor-source/audio-sources.json", root / "vendor-source/README.md"]
    for component in manifest["components"]:
        path = root / "vendor-source" / component["archive"]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != component["sha256"]:
            raise SystemExit(f"Checksum mismatch: {component['archive']}")
        paths.append(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        with tarfile.open(temporary, "w:xz", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(paths):
                member = archive.gettarinfo(str(path), "AppleMusicLocal-AudioSources/" + str(path.relative_to(root)))
                member.uid = member.gid = member.mtime = 0
                member.uname = member.gname = ""
                member.pax_headers = {}
                with path.open("rb") as stream:
                    archive.addfile(member, stream)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps({"file": str(output), "bytes": output.stat().st_size,
                      "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
