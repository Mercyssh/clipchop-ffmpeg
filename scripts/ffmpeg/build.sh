#!/usr/bin/env bash
# Build ClipChop's minimal LGPL ffmpeg + ffprobe for the platform this runs on.
#
#   Windows : run in an MSYS2 "MINGW64" shell
#   macOS   : Apple Silicon, Xcode Command Line Tools
#   Linux   : x86_64; for a binary that runs on most distros, build inside an
#             old-glibc container (see docs/ffmpeg-build.md)
#
#   bash scripts/ffmpeg/build.sh [--install-deps]
#
# --install-deps installs the build toolchain with the platform's package
# manager first (pacman / brew / apt). Everything else is downloaded at the
# pinned versions in components.env and built into .ffmpeg-build/ (gitignored).
#
# Output (.ffmpeg-build/dist/):
#   ffmpeg-<triple>[.exe], ffprobe-<triple>[.exe]   named for Tauri's externalBin
#   SHA256SUMS
#   source/   the exact ffmpeg source tarball, this script, components.env and
#             the configure line — the LGPL source offer for this build
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=components.env
source "$HERE/components.env"

case "$(uname -s)" in
  MINGW64*|MINGW32*|MSYS*|UCRT64*|CLANG64*)
    PLAT=windows; TRIPLE=x86_64-pc-windows-msvc; EXE=.exe
    if [ "${MSYSTEM:-}" != "MINGW64" ]; then
      echo "Run this from an MSYS2 MINGW64 shell (MSYSTEM=MINGW64)." >&2; exit 1
    fi ;;
  Darwin)
    PLAT=macos; TRIPLE=aarch64-apple-darwin; EXE=
    if [ "$(uname -m)" != "arm64" ]; then
      echo "ClipChop targets Apple Silicon only — build on an arm64 Mac." >&2; exit 1
    fi ;;
  Linux)
    PLAT=linux; TRIPLE=x86_64-unknown-linux-gnu; EXE= ;;
  *) echo "unsupported build OS: $(uname -s)" >&2; exit 1 ;;
esac

WORK="$ROOT/.ffmpeg-build"
SRC="$WORK/src"
PREFIX="$WORK/prefix"      # static dependencies
DIST="$WORK/dist"
JOBS="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4)"
mkdir -p "$SRC" "$PREFIX" "$DIST/source"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"

log() { printf '\n=== %s ===\n' "$*"; }

# ---- toolchain -------------------------------------------------------------
install_deps() {
  log "installing build toolchain ($PLAT)"
  case "$PLAT" in
    windows)
      pacman -S --needed --noconfirm base-devel git make diffutils nasm \
        mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf mingw-w64-x86_64-meson \
        mingw-w64-x86_64-ninja mingw-w64-x86_64-cmake mingw-w64-x86_64-zlib \
        mingw-w64-x86_64-python mingw-w64-x86_64-libvpl ;;
    macos)
      brew install nasm meson ninja pkg-config cmake ;;
    linux)
      local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
      export DEBIAN_FRONTEND=noninteractive
      $SUDO apt-get update
      $SUDO apt-get install -y build-essential git curl xz-utils nasm pkg-config \
        cmake zlib1g-dev python3-pip
      # distro meson/ninja can be too old for libdrm / libva
      $SUDO pip3 install "meson>=1.3" ninja
      # Ubuntu 20.04's nasm (2.14) can't assemble ffmpeg 9's x86 code
      install_nasm ;;
  esac
}

NASM_VERSION="2.16.03"
NASM_SHA256="1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148"
install_nasm() {
  local have; have="$(nasm -v 2>/dev/null | awk '{print $3}')"
  if [ -n "$have" ] && [ "$(printf '%s\n' 2.16 "$have" | sort -V | head -1)" = 2.16 ]; then
    return
  fi
  log "nasm $NASM_VERSION (have: ${have:-none})"
  local tmp; tmp="$(mktemp -d)"
  curl -fL -o "$tmp/nasm.tar.xz" \
    "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/nasm-$NASM_VERSION.tar.xz"
  [ "$(sha256sum "$tmp/nasm.tar.xz" | cut -d' ' -f1)" = "$NASM_SHA256" ] \
    || { echo "nasm tarball checksum mismatch" >&2; exit 1; }
  tar -xJf "$tmp/nasm.tar.xz" -C "$tmp"
  ( cd "$tmp/nasm-$NASM_VERSION" && ./configure --prefix=/usr/local && make -j"$(nproc)" \
    && $SUDO make install )
  rm -rf "$tmp"
  hash -r
}
[ "${1:-}" = "--install-deps" ] && install_deps

for tool in curl git nasm meson ninja pkg-config make; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool (try --install-deps)" >&2; exit 1; }
done

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ---- sources ---------------------------------------------------------------
fetch_git() { # name url tag
  if [ ! -d "$SRC/$1" ]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "$3" "$2" "$SRC/$1"
  fi
}

log "ffmpeg $FFMPEG_VERSION source"
TARBALL="$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz"
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
got="$(sha256 "$TARBALL")"
if [ "$got" != "$FFMPEG_SHA256" ]; then
  echo "ffmpeg tarball checksum mismatch: $got" >&2; exit 1
fi
rm -rf "$SRC/ffmpeg-$FFMPEG_VERSION"
tar -xJf "$TARBALL" -C "$SRC"

# ---- static dependencies ---------------------------------------------------
meson_static() { # dir [meson options…]
  local dir="$1"; shift
  meson setup "$dir/_build" "$dir" --prefix="$PREFIX" --libdir=lib --buildtype=release \
    --default-library=static "$@" --wipe 2>/dev/null \
  || meson setup "$dir/_build" "$dir" --prefix="$PREFIX" --libdir=lib --buildtype=release \
    --default-library=static "$@"
  ninja -C "$dir/_build" install
}

log "dav1d $DAV1D_VERSION (AV1 decoding, BSD-2)"
fetch_git dav1d https://code.videolan.org/videolan/dav1d.git "$DAV1D_VERSION"
meson_static "$SRC/dav1d" -Denable_tools=false -Denable_tests=false

if [ "$PLAT" != macos ]; then
  log "nv-codec-headers $NVCODEC_VERSION (NVENC, MIT headers)"
  fetch_git nv-codec-headers https://github.com/FFmpeg/nv-codec-headers.git "$NVCODEC_VERSION"
  make -C "$SRC/nv-codec-headers" PREFIX="$PREFIX" install
fi

if [ "$PLAT" = windows ]; then
  log "AMF $AMF_VERSION headers (AMD, MIT)"
  fetch_git AMF https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$AMF_VERSION"
  mkdir -p "$PREFIX/include/AMF"
  cp -r "$SRC/AMF/amf/public/include/." "$PREFIX/include/AMF/"

  # libvpl's source doesn't compile against MinGW's headers, so use MSYS2's
  # package (it ships the static libvpl.a) — and insist on the pinned version.
  log "libvpl $LIBVPL_VERSION (Intel Quick Sync, MIT) from MSYS2"
  have_vpl="$(pacman -Q mingw-w64-x86_64-libvpl 2>/dev/null | awk '{print $2}')"
  case "$have_vpl" in
    "${LIBVPL_VERSION#v}"-*) ;;
    *) echo "need mingw-w64-x86_64-libvpl ${LIBVPL_VERSION#v} (have: ${have_vpl:-none}); run with --install-deps or update components.env" >&2; exit 1 ;;
  esac
fi

if [ "$PLAT" = linux ]; then
  log "$LIBDRM_VERSION (MIT)"
  fetch_git drm https://gitlab.freedesktop.org/mesa/drm.git "$LIBDRM_VERSION"
  meson_static "$SRC/drm" -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled \
    -Dnouveau=disabled -Dvmwgfx=disabled -Dvalgrind=disabled -Dtests=false \
    -Dman-pages=disabled -Dcairo-tests=disabled
  log "libva $LIBVA_VERSION (VA-API, MIT)"
  fetch_git libva https://github.com/intel/libva.git "$LIBVA_VERSION"
  # Drivers live in the user's system, not under our build prefix.
  meson_static "$SRC/libva" -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no \
    -Denable_docs=false \
    -Ddriverdir=/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri:/usr/local/lib/dri
  # libva's meson only builds shared libraries. Archive its objects instead, so
  # ffmpeg doesn't depend on the user's libva version (or on libva at all).
  for lib in va va-drm; do
    ar rcs "$PREFIX/lib/lib$lib.a" "$SRC/libva/_build/va/lib$lib.so."*.p/*.o
  done
  rm -f "$PREFIX"/lib/libva*.so*
  echo "Libs.private: -ldl" >> "$PREFIX/lib/pkgconfig/libva.pc"
  echo "Requires.private: libdrm" >> "$PREFIX/lib/pkgconfig/libva-drm.pc"
fi

# ---- ffmpeg ----------------------------------------------------------------
ENC="$ENCODERS"; FLT="$FILTERS"
CONF=(
  --prefix="$WORK/install"
  --pkg-config-flags=--static
  --extra-cflags="-I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib"
  --disable-everything --disable-autodetect
  --enable-static --disable-shared
  --disable-network --disable-doc --disable-debug --disable-ffplay
  --enable-ffmpeg --enable-ffprobe
  --enable-avdevice --enable-avfilter --enable-swscale --enable-swresample
  --enable-zlib --enable-libdav1d
)
case "$PLAT" in
  windows)
    ENC="$ENC,$ENCODERS_WINDOWS"
    CONF+=(--enable-w32threads --enable-ffnvcodec --enable-nvenc --enable-amf
           --enable-libvpl --enable-mediafoundation --enable-d3d11va --enable-dxva2
           --extra-ldflags=-static --extra-libs=-lstdc++) ;;
  macos)
    ENC="$ENC,$ENCODERS_MACOS"
    CONF+=(--enable-pthreads --enable-videotoolbox) ;;
  linux)
    ENC="$ENC,$ENCODERS_LINUX"; FLT="$FLT,$FILTERS_LINUX"
    CONF+=(--enable-pthreads --enable-ffnvcodec --enable-nvenc --enable-vaapi
           --enable-libdrm --extra-libs="-ldl -lpthread") ;;
esac
CONF+=(
  --enable-protocol="$PROTOCOLS"
  --enable-demuxer="$DEMUXERS"
  --enable-muxer="$MUXERS"
  --enable-decoder="$DECODERS"
  --enable-encoder="$ENC"
  --enable-parser="$PARSERS"
  --enable-bsf="$BSFS"
  --enable-filter="$FLT"
  --enable-indev="$INDEVS"
)
# LGPL 2.1 only: never --enable-gpl / --enable-version3 / --enable-nonfree.

log "configure ffmpeg"
cd "$SRC/ffmpeg-$FFMPEG_VERSION"
./configure "${CONF[@]}" || { tail -40 ffbuild/config.log; exit 1; }
log "build ffmpeg"
make -j"$JOBS"
make install

# ---- collect ---------------------------------------------------------------
log "collect to $DIST"
for b in ffmpeg ffprobe; do
  cp "$WORK/install/bin/$b$EXE" "$DIST/$b-$TRIPLE$EXE"
  strip "$DIST/$b-$TRIPLE$EXE" 2>/dev/null || true
done
cp "$TARBALL" "$HERE/build.sh" "$HERE/components.env" "$DIST/source/"
printf '%q ' ./configure "${CONF[@]}" > "$DIST/source/configure-$TRIPLE.txt"
( cd "$DIST" && for f in ffmpeg-"$TRIPLE"* ffprobe-"$TRIPLE"*; do echo "$(sha256 "$f")  $f"; done ) > "$DIST/SHA256SUMS.$TRIPLE"

log "verify"
PY="$(command -v python3 || command -v python)"
"$PY" "$HERE/verify.py" "$DIST/ffmpeg-$TRIPLE$EXE" "$DIST/ffprobe-$TRIPLE$EXE" --platform "$PLAT"
ls -la "$DIST"
