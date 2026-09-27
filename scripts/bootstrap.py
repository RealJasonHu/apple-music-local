#!/usr/bin/env python3
"""Install exact, checksum-locked artifacts into the checkout's build cache."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build-support"
MANIFEST = json.loads((ROOT / "scripts/dependencies.json").read_text())


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_directory(path):
    if path.is_symlink():
        raise RuntimeError(f"Refusing a symlinked build directory: {path.name}")
    path.mkdir(parents=True, exist_ok=True)


def download(artifact):
    path = CACHE / "downloads" / artifact["filename"]
    if path.name != artifact["filename"] or path.is_symlink():
        raise RuntimeError("Invalid or symlinked artifact filename")
    if path.exists():
        if digest(path) != artifact["sha256"]:
            raise RuntimeError(f"Cached artifact checksum mismatch: {path.name}")
        return path
    request = urllib.request.Request(artifact["url"], headers={"User-Agent": "AppleMusicLocal-bootstrap/1"})
    descriptor, partial = tempfile.mkstemp(prefix=".download-", dir=CACHE / "downloads")
    partial = Path(partial)
    try:
        with os.fdopen(descriptor, "wb") as target, urllib.request.urlopen(request, timeout=120) as response:
            shutil.copyfileobj(response, target)
        if digest(partial) != artifact["sha256"]:
            raise RuntimeError(f"Downloaded artifact checksum mismatch: {path.name}")
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    return path


def fingerprint():
    # Include build inputs so edits invalidate the dependency cache.
    inputs = [ROOT / "requirements.lock.txt", *sorted((ROOT / "scripts").glob("*")),
              *sorted((ROOT / "packaging").rglob("*")), *sorted((ROOT / "vendor-source").rglob("*"))]
    combined = hashlib.sha256()
    for path in inputs:
        if path.is_file() and not path.name.endswith((".pyc", ".tar.gz", ".tar.xz", ".tar.zst")) and "__pycache__" not in path.parts:
            combined.update(str(path.relative_to(ROOT)).encode() + b"\0")
            combined.update(digest(path).encode() + b"\n")
    return combined.hexdigest()


def clean_environment():
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"}


def verify(packages):
    environment = clean_environment()
    environment["PYTHONPATH"] = str(packages)
    subprocess.run([sys.executable, "-c", """
import importlib.metadata, json, pathlib, subprocess, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in manifest['runtime_packages']:
    assert importlib.metadata.version(item['name']) == item['version'], item['name']
import gamdl._ammuxer, imageio_ffmpeg
from gamdl.cli.cli import main
executable = pathlib.Path(imageio_ffmpeg.get_ffmpeg_exe()).resolve()
assert executable.is_relative_to(pathlib.Path(sys.argv[2]).resolve())
subprocess.run([str(executable), '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
               '-i', 'anullsrc=r=44100:cl=stereo', '-t', '0.05', '-f', 'null', '-'],
               check=True, capture_output=True)
print('Pinned Python packages, Gamdl native extension, and local FFmpeg: verified.')
""", str(ROOT / "scripts/dependencies.json"), str(packages)], check=True, env=environment)


def main():
    assert sys.version_info[:3] == (3, 12, 14), "Wrong bootstrap Python version"
    assert len(sys.argv) == 2 and sys.argv[1] == MANIFEST["python"]["sha256"], "Python lock mismatch"
    assert MANIFEST["schema"] == 1
    safe_directory(CACHE)
    safe_directory(CACHE / "downloads")
    packages = CACHE / "site-packages"
    if packages.is_symlink():
        raise RuntimeError("Refusing symlinked site-packages")
    ffmpeg_script = ROOT / "packaging/build_ffmpeg.sh"
    if not ffmpeg_script.is_file():
        raise RuntimeError("packaging/build_ffmpeg.sh is required to build the bundled FFmpeg")
    # A source release may ship these archives; a Git clone needs to fetch them.
    audio = json.loads((ROOT / "vendor-source/audio-sources.json").read_text())
    for item in audio["components"]:
        target = ROOT / "vendor-source" / item["archive"]
        if target.is_symlink() or target.name != item["archive"]:
            raise RuntimeError("Invalid or symlinked audio source archive")
        if target.exists():
            if digest(target) != item["sha256"]:
                raise RuntimeError(f"Audio source checksum mismatch: {target.name}")
        else:
            shutil.copy2(download({**item, "filename": item["archive"]}), target)
    wanted = fingerprint()
    stamp = CACHE / "bootstrap.json"
    if stamp.is_file() and not stamp.is_symlink() and json.loads(stamp.read_text()).get("fingerprint") == wanted and packages.is_dir():
        verify(packages)
        return

    artifacts = MANIFEST["runtime_packages"] + MANIFEST["build_packages"] + [MANIFEST["python_licenses"]]
    print(f"Fetching {len(artifacts)} pinned Python artifacts (checksummed cache reused)…", flush=True)
    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(download, artifacts))

    with tempfile.TemporaryDirectory(prefix=".packages-", dir=CACHE) as temporary:
        staging = Path(temporary)
        environment = clean_environment()
        build_environment = staging / "build-venv"
        subprocess.run([sys.executable, "-m", "venv", "--copies", str(build_environment)], check=True, env=environment)
        installer = [str(build_environment / "bin/python3.12"), "-m", "pip", "--isolated", "install",
                     "--no-cache-dir", "--no-index", "--find-links", str(CACHE / "downloads"), "--require-hashes", "--no-deps"]
        subprocess.run([*installer, "--only-binary=:all:", "-r", str(ROOT / "scripts/build-requirements.lock.txt")], check=True, env=environment)
        python_licenses = staging / "python-licenses"
        subprocess.run([str(build_environment / "bin/python3.12"), str(ROOT / "scripts/extract-python-licenses.py"),
                        str(CACHE / "downloads" / MANIFEST["python_licenses"]["filename"]), str(python_licenses)],
                       check=True, env=environment)
        staged_packages = staging / "site-packages"
        subprocess.run([*installer, "--no-build-isolation", "--ignore-installed", "--target", str(staged_packages),
                        "-r", str(ROOT / "requirements.lock.txt")], check=True, env=environment)

        # Replace the upstream FFmpeg executable with the source-built LGPL version.
        subprocess.run(["/bin/bash", str(ffmpeg_script), str(CACHE / "ffmpeg")], check=True, env=environment)
        ffmpeg = CACHE / "ffmpeg/bin/ffmpeg"
        if not ffmpeg.is_file() or ffmpeg.is_symlink():
            raise RuntimeError("The source FFmpeg build did not produce the expected executable")
        bundled_binary = staged_packages / "imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1"
        if not bundled_binary.is_file() or bundled_binary.is_symlink():
            raise RuntimeError("Unexpected imageio-ffmpeg wheel layout")
        shutil.copy2(ffmpeg, bundled_binary)
        # The replaced executable intentionally differs from its upstream wheel RECORD.
        provenance = {"upstream_wheel": "imageio-ffmpeg==0.6.0", "replacement": str(bundled_binary.relative_to(staged_packages)),
                      "sha256": digest(ffmpeg), "build_script": "packaging/build_ffmpeg.sh"}
        (staged_packages / "ffmpeg-replacement.json").write_text(json.dumps(provenance, indent=2) + "\n")
        verify(staged_packages)
        if packages.exists():
            packages.rename(staging / "previous-site-packages")
        staged_packages.rename(packages)
        license_target = CACHE / "python-licenses"
        if license_target.is_symlink():
            raise RuntimeError("Refusing symlinked Python licenses directory")
        if license_target.exists():
            license_target.rename(staging / "previous-python-licenses")
        python_licenses.rename(license_target)
        (staging / "bootstrap.json").write_text(json.dumps({"fingerprint": wanted, "python": MANIFEST["python"],
                                                          "runtime_package_count": len(MANIFEST["runtime_packages"]),
                                                          "ffmpeg_sha256": digest(ffmpeg)}, indent=2) + "\n")
        (staging / "bootstrap.json").replace(stamp)
    print("Build runtime ready in .build-support/ (no account data used).")


if __name__ == "__main__":
    main()
