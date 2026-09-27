#!/bin/bash
# Offline source build for macOS arm64. Requires only Xcode command-line tools.
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCES="$ROOT/vendor-source"
OUTPUT="${1:-$ROOT/.build-support/ffmpeg}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This recipe targets macOS arm64.' >&2; exit 1; }
[[ "$OUTPUT" == /* ]] || OUTPUT="$PWD/$OUTPUT"
mkdir -p -- "$OUTPUT"
OUTPUT="$(cd -- "$OUTPUT" && pwd -P)"
[[ ! -L "$OUTPUT/bin" ]] || { echo 'Refusing a symlinked output bin directory.' >&2; exit 1; }

check_hash() {
    local expected="$1" file="$2" actual
    [[ -f "$file" ]] || { echo "Missing source archive: $file" >&2; exit 1; }
    actual="$(/usr/bin/shasum -a 256 "$file")"
    [[ "${actual%% *}" == "$expected" ]] || { echo "Source checksum mismatch: $file" >&2; exit 1; }
}
check_hash 40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6 "$SOURCES/ffmpeg-7.1.tar.xz"
check_hash ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e "$SOURCES/lame-3.100.tar.gz"
FINGERPRINT="$(cat "$SCRIPT_DIR/build_ffmpeg.sh" "$SOURCES/audio-sources.json" | /usr/bin/shasum -a 256)"
FINGERPRINT="${FINGERPRINT%% *}"
if [[ -x "$OUTPUT/bin/ffmpeg" && -f "$OUTPUT/source-fingerprint.txt" && "$(cat "$OUTPUT/source-fingerprint.txt")" == "$FINGERPRINT" ]]; then
    printf 'Verified cached source build: %s\n' "$OUTPUT/bin/ffmpeg"
    exit 0
fi

WORK="$(/usr/bin/mktemp -d "$OUTPUT/.work.XXXXXX")"
cleanup() { case "$WORK" in "$OUTPUT"/.work.*) /bin/rm -rf -- "$WORK" ;; esac; }
trap cleanup EXIT
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC=/usr/bin/clang CXX=/usr/bin/clang++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib
export CFLAGS='-O2 -fno-common' CXXFLAGS='-O2'
JOBS="${AUDIO_BUILD_JOBS:-4}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'AUDIO_BUILD_JOBS must be a positive integer.' >&2; exit 1; }
/usr/bin/tar -xJf "$SOURCES/ffmpeg-7.1.tar.xz" -C "$WORK"
/usr/bin/tar -xzf "$SOURCES/lame-3.100.tar.gz" -C "$WORK"
printf 'Building LAME 3.100 and audio-only FFmpeg 7.1; log: %s\n' "$OUTPUT/build.log"
(
    cd -- "$WORK/lame-3.100"
    ./configure --prefix=/ --libdir=/lib --includedir=/include \
        --disable-shared --enable-static --disable-frontend --disable-decoder --disable-nasm
    /usr/bin/make -j "$JOBS"
    /usr/bin/make DESTDIR="$WORK/lame-prefix" install
    cd -- "$WORK/ffmpeg-7.1"
    ./configure --prefix=/ --arch=arm64 --cc=/usr/bin/clang \
        --disable-autodetect --disable-network --disable-doc --disable-debug \
        --disable-programs --enable-ffmpeg --disable-shared --enable-static \
        --disable-everything --enable-swresample --enable-avfilter \
        --enable-libmp3lame --enable-zlib \
        --extra-cflags=-I../lame-prefix/include --extra-ldflags=-L../lame-prefix/lib \
        --enable-protocol=file,pipe \
        --enable-demuxer=mov,aac,mp3,wav,aiff,flac,ogg,image2 \
        --enable-muxer=ipod,mp4,mov,mp3,wav,flac,null,adts,aiff,image2 \
        --enable-decoder=aac,alac,mp3,flac,pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be,mjpeg,png \
        --enable-encoder=aac,alac,flac,libmp3lame,pcm_s16le,pcm_s24le,pcm_s32le,mjpeg,png \
        --enable-parser=aac,aac_latm,mpegaudio,flac,mjpeg,png \
        --enable-filter=aresample,aformat,anull,anullsrc,sine,abuffer,abuffersink \
        --enable-indev=lavfi
    /usr/bin/make -j "$JOBS"
    /usr/bin/make DESTDIR="$OUTPUT" install
) > "$OUTPUT/build.log" 2>&1 || { tail -60 "$OUTPUT/build.log" >&2; exit 1; }
mkdir -p -- "$OUTPUT/licenses"
cp -- "$WORK/ffmpeg-7.1/COPYING.LGPLv2.1" "$OUTPUT/licenses/FFmpeg-LGPL-2.1.txt"
cp -- "$WORK/ffmpeg-7.1/LICENSE.md" "$OUTPUT/licenses/FFmpeg-LICENSE.md"
cp -- "$WORK/lame-3.100/COPYING" "$OUTPUT/licenses/LAME-LGPL-2.0.txt"
cp -- "$WORK/ffmpeg-7.1/ffbuild/config.log" "$OUTPUT/ffmpeg-config.log"
cp -- "$WORK/ffmpeg-7.1/config.h" "$OUTPUT/ffmpeg-config.h"
cp -- "$WORK/ffmpeg-7.1/ffbuild/config.mak" "$OUTPUT/ffmpeg-config.mak"
cp -- "$WORK/lame-3.100/config.log" "$OUTPUT/lame-config.log"
cp -- "$SOURCES/audio-sources.json" "$OUTPUT/audio-sources.json"
"$OUTPUT/bin/ffmpeg" -version > "$OUTPUT/FFmpeg-BUILD.txt" 2>&1
"$OUTPUT/bin/ffmpeg" -L > "$OUTPUT/FFmpeg-LICENSE.txt" 2>&1
"$OUTPUT/bin/ffmpeg" -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.05 -f null -
/usr/bin/otool -L "$OUTPUT/bin/ffmpeg" > "$OUTPUT/dynamic-libraries.txt"
/usr/bin/shasum -a 256 "$OUTPUT/bin/ffmpeg" > "$OUTPUT/ffmpeg.sha256"
printf '%s\n' "$FINGERPRINT" > "$OUTPUT/source-fingerprint.txt"
printf 'Built source-matched audio FFmpeg: %s\n' "$OUTPUT/bin/ffmpeg"
