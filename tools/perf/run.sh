#!/bin/zsh
# Measures the viewer's decode cost, memory and responsiveness on a synthetic photo set. The tools
# are built from the current Sources/, so run this before and after a change and compare.
# Usage: tools/perf/run.sh [decode|app|all]
# Output and test photos go to $V_PERF_DIR (default $TMPDIR/v-perf); the photos (~230 MB) are made once.
set -euo pipefail
cd "${0:A:h}/../.."

OUT="${V_PERF_DIR:-${TMPDIR:-/tmp}/v-perf}"
DATA="$OUT/data"
WHAT="${1:-all}"
mkdir -p "$OUT"

if [[ ! -d "$DATA/many" ]]; then
  swiftc -O -o "$OUT/gen" tools/perf/gen.swift
  "$OUT/gen" "$DATA"
fi

if [[ $WHAT == (decode|all) ]]; then
  swiftc -O -o "$OUT/bench" tools/perf/bench.swift
  bench() { "$OUT/bench" "$1" "$DATA/$2" "${@:3}" }
  echo "== Decode strategies, one fresh process each (warm disk cache). 'needed' 2000 px ≈ a fitted photo on a laptop screen."
  for f in photos/IMG_0001.jpg photos/IMG_0006.jpg heic/IMG_0001.heic "png/Screenshot 1.png"; do
    bench full "$f"
    bench pow2 "$f" 2000
    bench sub "$f" 2
  done
  bench fit heic/IMG_0001.heic 2016
  echo "== Filmstrip thumbnails: embedded EXIF thumbnail vs decoded, and the QuickLook cache"
  for f in photos/IMG_0001.jpg heic/IMG_0001.heic "png/Screenshot 1.png"; do bench thumb "$f" 160; done
  N=3 bench ql "png/Screenshot 2.png" 56
  echo "== Properties read on the main thread for every photo shown"
  N=9 bench props gif/anim.gif
fi

if [[ $WHAT == (app|all) ]]; then
  srcs=(Sources/*.swift)
  swiftc -O -wmo -swift-version 5 -target "$(uname -m)-apple-macos13.0" -Xlinker -dead_strip -o "$OUT/harness" ${srcs:#*/main.swift} tools/perf/harness/main.swift
  run() { echo "-- $1 ${2:t}"; "$OUT/harness" "$1" "$DATA/$2" }
  "$OUT/harness" open "$DATA/photos/IMG_0002.jpg" >/dev/null  # the first launch of a new binary pays for dyld and signature checks
  echo "== The real viewer code, invisible window"
  run open photos/IMG_0001.jpg
  run open photos/IMG_0006.jpg
  run open heic/IMG_0001.heic
  run open many/IMG_5000.jpg
  run launch photos/IMG_0001.jpg
  run launch heic/IMG_0001.heic
  run pace photos/IMG_0001.jpg
  run burst photos/IMG_0001.jpg
  run burst heic/IMG_0001.heic
  run zoom photos/IMG_0001.jpg
  run zoom photos/IMG_0006.jpg
  run gif gif/anim.gif
fi
