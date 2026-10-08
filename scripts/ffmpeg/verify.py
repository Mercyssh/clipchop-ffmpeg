#!/usr/bin/env python3
"""Check a ClipChop ffmpeg build: LGPL-only, and every component ClipChop needs.

    python scripts/ffmpeg/verify.py <ffmpeg> <ffprobe> [--platform windows|macos|linux]

Fails (exit 1) if the build is GPL / version3 / nonfree, or if any filter,
encoder, decoder, muxer, demuxer, protocol or input device from components.env
is missing. Also runs a tiny functional smoke test. Used by build.sh and
install.py; run it by hand on any ffmpeg you consider bundling.
"""
import argparse, fnmatch, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# configure name -> the name ffmpeg prints at runtime, where they differ
RUNTIME_NAME = {
    ("DEMUXERS", "image_png_pipe"): "png_pipe",
    ("DEMUXERS", "mpegps"): "mpeg",
    ("MUXERS", "pcm_f32le"): "f32le",
    ("MUXERS", "pcm_s16le"): "s16le",
    ("DECODERS", "msmpeg4v3"): "msmpeg4",
}


def components():
    text = open(os.path.join(HERE, "components.env"), encoding="utf-8").read()
    return dict(re.findall(r'^(\w+)="([^"]*)"', text, re.M))


def run(exe, *args):
    r = subprocess.run([exe, "-hide_banner", *args], capture_output=True, text=True)
    return r.stdout + r.stderr


def listed(exe, flag):
    """Names from `ffmpeg -filters / -encoders / …` (second column of each row)."""
    names = set()
    for line in run(exe, flag).splitlines():
        parts = line.split()
        if len(parts) >= 2 and not line.startswith(" ="):
            names.update(p for p in parts[1].split(","))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ffmpeg")
    ap.add_argument("ffprobe")
    default = "windows" if sys.platform == "win32" else "macos" if sys.platform == "darwin" else "linux"
    ap.add_argument("--platform", default=default, choices=["windows", "macos", "linux"])
    a = ap.parse_args()
    a.ffmpeg, a.ffprobe = os.path.abspath(a.ffmpeg), os.path.abspath(a.ffprobe)
    c = components()
    errors = []

    # --- license ---
    lic = " ".join(run(a.ffmpeg, "-L").split())  # the text wraps mid-phrase
    if "GNU Lesser General Public License" not in lic:
        errors.append("ffmpeg -L does not report the LGPL")
    conf = run(a.ffmpeg, "-buildconf")
    for bad in ("--enable-gpl", "--enable-version3", "--enable-nonfree", "libx264", "libx265"):
        if bad in conf:
            errors.append(f"build configuration contains {bad}")
    if "version" not in run(a.ffprobe, "-version"):
        errors.append("ffprobe does not run")

    # --- components ---
    plat = a.platform.upper()
    want = {
        "FILTERS": c["FILTERS"] + ("," + c["FILTERS_LINUX"] if a.platform == "linux" else ""),
        "ENCODERS": c["ENCODERS"] + "," + c[f"ENCODERS_{plat}"],
        "DECODERS": c["DECODERS"],
        "DEMUXERS": c["DEMUXERS"],
        "MUXERS": c["MUXERS"],
        "PROTOCOLS": c["PROTOCOLS"],
        "INDEVS": c["INDEVS"],
    }
    have = {
        "FILTERS": listed(a.ffmpeg, "-filters"),
        "ENCODERS": listed(a.ffmpeg, "-encoders"),
        "DECODERS": listed(a.ffmpeg, "-decoders"),
        "DEMUXERS": listed(a.ffmpeg, "-demuxers"),
        "MUXERS": listed(a.ffmpeg, "-muxers"),
        "INDEVS": listed(a.ffmpeg, "-devices") | listed(a.ffmpeg, "-demuxers"),
    }
    prot = run(a.ffmpeg, "-protocols")
    have["PROTOCOLS"] = {w.strip() for w in prot.split("Input:")[-1].split("Output:")[0].split()}
    # auto-inserted sink/source filters aren't listed by -filters
    have["FILTERS"] |= {"buffer", "buffersink", "abuffer", "abuffersink"}
    for kind, names in want.items():
        for n in filter(None, names.split(",")):
            n = RUNTIME_NAME.get((kind, n), n)
            if not any(fnmatch.fnmatch(h, n) for h in have[kind]):
                errors.append(f"missing {kind[:-1].lower()}: {n}")

    # --- smoke test: lavfi source -> PNG frame, decoded back by ffprobe ---
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "f.png")
        subprocess.run([a.ffmpeg, "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x36",
                        "-frames:v", "1", png], capture_output=True)
        probe = run(a.ffprobe, "-v", "error", "-show_entries", "stream=width", "-of", "csv=p=0", png)
        if "64" not in probe:
            errors.append("smoke test failed (lavfi -> png -> ffprobe)")

    if errors:
        print("FAIL")
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print(f"OK: LGPL build with every component ClipChop needs ({a.platform})")


if __name__ == "__main__":
    main()
