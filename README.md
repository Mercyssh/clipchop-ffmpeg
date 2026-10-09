# clipchop-ffmpeg

Source code and build scripts for the [FFmpeg](https://ffmpeg.org) programs
(`ffmpeg` and `ffprobe`) bundled with **ClipChop**, a desktop video editor.

ClipChop bundles a minimal FFmpeg licensed under the
**GNU Lesser General Public License, version 2.1 or later** (see
[COPYING.LGPLv2.1](COPYING.LGPLv2.1)). This repository provides, for every
version of ClipChop that ships FFmpeg:

- the exact FFmpeg source code it was built from,
- the script and configuration used to build it, and
- a way to build and use your own modified version.

The FFmpeg build contains no GPL or nonfree components (no `--enable-gpl`,
`--enable-version3` or `--enable-nonfree`; no libx264/libx265). ClipChop runs
FFmpeg as separate programs; it does not link to FFmpeg's libraries.

## Releases

Each [GitHub Release](https://github.com/Mercyssh/clipchop-ffmpeg/releases)
contains everything needed to rebuild that version:

| File | What it is |
|---|---|
| `ffmpeg-<version>.tar.xz` | The unmodified FFmpeg source tarball, as published on ffmpeg.org |
| `build.sh`, `components.env` | The build script and the pinned versions + component list it used |
| `configure-<platform>.txt` | The exact `./configure` line for each platform |
| `SHA256SUMS.<platform>` | Checksums of the `ffmpeg` / `ffprobe` programs shipped with ClipChop |

| ClipChop | FFmpeg | Platforms |
|---|---|---|
| 1.0.0 | 9.0.2 | Windows x86_64, Linux x86_64 |

## What's in the build

Only what ClipChop uses (see [`scripts/ffmpeg/components.env`](scripts/ffmpeg/components.env)):

- **Formats:** MP4/MOV, MKV/WebM, AVI, MPEG-PS/TS, ASF/WMV, WAV, MP3, AAC, FLAC, Ogg, PNG
- **Decoders:** H.264, HEVC, VP8/9, AV1 (via dav1d), MPEG-1/2/4, ProRes, MJPEG, WMV/VC-1, AAC, MP3, Opus, Vorbis, FLAC, AC-3/E-AC-3, ALAC, WMA, PCM
- **Encoders:** AAC, PNG, PCM, and each platform's own H.264 encoders:
  - Windows: NVIDIA NVENC, Intel Quick Sync, AMD AMF, Media Foundation
  - macOS: VideoToolbox
  - Linux: NVENC, VA-API
- **Filters:** the trimming, timing, scaling, compositing, fading and audio filters ClipChop's renderer uses

Libraries compiled in, all under permissive licenses: dav1d (BSD-2-Clause),
zlib, NVIDIA nv-codec-headers (MIT), AMD AMF headers (MIT), Intel libvpl
(MIT), and on Linux libva / libdrm (MIT).

## Building

The script builds FFmpeg and its dependencies statically for the platform it
runs on. Everything is downloaded at the pinned versions; the FFmpeg tarball
is checked against its SHA-256. Output goes to `.ffmpeg-build/dist/`.

**Windows (x86_64):** install [MSYS2](https://www.msys2.org/), open the
**MINGW64** shell, then:

```bash
bash scripts/ffmpeg/build.sh --install-deps
```

**macOS (Apple Silicon):** with Xcode Command Line Tools and
[Homebrew](https://brew.sh):

```bash
bash scripts/ffmpeg/build.sh --install-deps
```

**Linux (x86_64):** build in an old-glibc container, so the result runs on
most distributions:

```bash
docker run --rm -v "$PWD:/src" -w /src ubuntu:20.04 \
  bash -c "apt-get update && apt-get install -y sudo && bash scripts/ffmpeg/build.sh --install-deps"
```

`--install-deps` installs the build tools with the platform's package manager
(pacman, brew or apt). Leave it off once they're installed.

To rebuild exactly what a ClipChop release shipped, use the `build.sh` and
`components.env` attached to that release (they pin the FFmpeg version and its
checksum).

### Checking a build

```bash
python3 scripts/ffmpeg/verify.py path/to/ffmpeg path/to/ffprobe
```

`verify.py` fails unless the build reports the LGPL, contains no GPL or
nonfree parts, and includes every component ClipChop needs. It also runs a short
smoke test.

## Using your own FFmpeg with ClipChop

The LGPL lets you modify FFmpeg and use your modified version with ClipChop.
Either:

- **Point ClipChop at your build** with environment variables, set before
  starting ClipChop:

  | Variable | Value |
  |---|---|
  | `CLIPCHOP_FFMPEG` | full path to your `ffmpeg` |
  | `CLIPCHOP_FFPROBE` | full path to your `ffprobe` |

- **Or replace the bundled programs** in ClipChop's install folder:
  - **Windows:** `ffmpeg.exe` and `ffprobe.exe` next to `ClipChop.exe`
  - **macOS:** `ClipChop.app/Contents/MacOS/`
  - **Linux:** next to the ClipChop executable

Your build needs at least the components listed in
[`components.env`](scripts/ffmpeg/components.env); run `verify.py` on it to
check. On Linux, ClipChop automatically prefers a system FFmpeg (version 7 or
newer, with the filters it needs) over the bundled one.

## License

FFmpeg is licensed under the LGPL 2.1 or later; see
[COPYING.LGPLv2.1](COPYING.LGPLv2.1) and the license files inside the source
tarball. The build scripts in this repository are provided under the same
license.

ClipChop itself is proprietary software and is **not** part of this repository.
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
This repository is not affiliated with or endorsed by the FFmpeg project.
