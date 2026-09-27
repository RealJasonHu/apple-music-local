#!/usr/bin/env python3
"""Extract only licensing metadata from the checksum-verified full CPython build."""
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import zstandard

archive, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=False)
with archive.open("rb") as source, zstandard.ZstdDecompressor().stream_reader(source) as stream:
    with tarfile.open(fileobj=stream, mode="r|") as members:
        for member in members:
            parts = PurePosixPath(member.name).parts
            selected = parts == ("python", "PYTHON.json") or (len(parts) == 3 and parts[:2] == ("python", "licenses"))
            if not selected or not member.isfile() or member.size > 2_000_000:
                continue
            name = parts[-1]
            if name in (".", "..") or "/" in name:
                raise RuntimeError("Invalid license member name")
            with members.extractfile(member) as input_file, (destination / name).open("wb") as output_file:
                shutil.copyfileobj(input_file, output_file)
metadata = json.loads((destination / "PYTHON.json").read_text())
required = {metadata["license_path"]}
for variants in metadata["build_info"]["extensions"].values():
    for variant in variants:
        required.update(variant.get("license_paths", []))
missing = sorted(relative for relative in required if not (destination / PurePosixPath(relative).name).is_file())
if missing:
    # This exact macOS release lists both zlib alternatives, but links Apple's
    # system libz and ships no zlib-ng. Preserve the upstream metadata unchanged.
    assert missing == ["licenses/LICENSE.zlib-ng.txt"], f"Unexpected missing upstream licenses: {missing}"
    affected = []
    for name, variants in metadata["build_info"]["extensions"].items():
        for variant in variants:
            if missing[0] in variant.get("license_paths", []):
                links = variant.get("links", [])
                assert {"name": "z", "system": True} in links
                assert all("zlib" not in str(link.get("path_static", "")) for link in links)
                affected.append(name)
    note = {"upstream_metadata_missing_license": missing[0], "affected_extensions": affected,
            "explanation": "The pinned macOS archive references both zlib variants but links system libz; zlib-ng is not bundled. All license texts present in the upstream full archive are retained."}
    (destination / "license-metadata-note.json").write_text(json.dumps(note, indent=2) + "\n")
print(f"Retained Python metadata and {len(list(destination.glob('LICENSE*')))} upstream license texts.")
