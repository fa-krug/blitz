#!/bin/bash
# Palette main-thread cost per keystroke, arrow, summon and close. See docs/testing.md.
#
#   run.sh build <name>                       optimized dev build of this checkout, kept as <name>
#   run.sh compare <scenario> <runs> <name>…  interleaved runs; launcher, modes, scroll or extension
#
# BLITZ_BENCH_ARGS is passed to the app, so `-compactMode NO -popToRootTimeout 0` overrides the
# dev channel's own preferences for the run without writing them.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
HERE=Scripts/palette-benchmark
OUT="$PWD/.build/palette-benchmark"
mkdir -p "$OUT"

driver() {
    clang -dynamiclib -fobjc-arc -framework AppKit -framework QuartzCore \
        -o "$OUT/driver.dylib" "$HERE/driver.m" || exit 1
}

case "${1:-}" in
build)
    name=${2:?name}
    # Hardened runtime off, so dyld honours DYLD_INSERT_LIBRARIES; the dev bundle id keeps prefs apart.
    xcodebuild -project Blitz.xcodeproj -scheme Blitz -configuration Debug -skipPackagePluginValidation \
        -derivedDataPath build/PaletteBenchmark SWIFT_OPTIMIZATION_LEVEL=-O \
        SWIFT_COMPILATION_MODE=wholemodule ENABLE_HARDENED_RUNTIME=NO build > "$OUT/build-$name.log" 2>&1 \
        || { grep -E "error:" "$OUT/build-$name.log" | head; exit 1; }
    rm -rf "${OUT:?}/$name"
    mkdir -p "$OUT/$name"
    cp -R "build/PaletteBenchmark/Build/Products/Debug/Blitz Dev.app" "$OUT/$name/"
    echo "built $OUT/$name"
    ;;
compare)
    scenario=${2:?scenario} runs=${3:?runs}
    shift 3
    driver
    # Each command's bundle is the shared rows plus its own body: a bundle carries no relative require.
    if [ "$scenario" = extension ]; then
        bench="$HOME/Library/Application Support/de.fa-krug.blitz.dev/extensions/blitz-bench"
        rm -rf "$bench" && mkdir -p "$bench"
        cp "$HERE/extension/package.json" "$bench/"
        for command in search-list filter-list; do
            cat "$HERE/extension/rows.js" "$HERE/extension/$command.js" > "$bench/$command.js"
        done
    fi
    for run in $(seq 1 "$runs"); do
        for name in "$@"; do
            # Never by name: `xctrace --launch` and `open` resolve the bundle id to another copy.
            BLITZ_BENCH_SCENARIO=$scenario BLITZ_BENCH_OUT="$OUT/$name-$scenario-$run.json" \
                DYLD_INSERT_LIBRARIES="$OUT/driver.dylib" \
                "$OUT/$name/Blitz Dev.app/Contents/MacOS/Blitz Dev" ${BLITZ_BENCH_ARGS:-} \
                > "$OUT/$name-$scenario-$run.log" 2>&1
        done
    done
    node - "$OUT" "$scenario" "$runs" "$@" <<'JS'
const fs = require("fs");
const [out, scenario, runs, ...names] = process.argv.slice(2);
const median = (xs) => {
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor(sorted.length / 2)] : NaN;
};
const samples = {};
for (const name of names) {
  samples[name] = {};
  for (let run = 1; run <= Number(runs); run++) {
    const file = `${out}/${name}-${scenario}-${run}.json`;
    if (!fs.existsSync(file)) continue;
    for (const [action, values] of Object.entries(JSON.parse(fs.readFileSync(file)))) {
      (samples[name][action] ??= []).push(...values);
    }
  }
}
const actions = [...new Set(names.flatMap((name) => Object.keys(samples[name])))].sort();
console.log("main-thread busy, median ms".padEnd(28) + names.map((n) => n.padStart(12)).join(""));
for (const action of actions) {
  const cells = names.map((name) => {
    const value = median(samples[name][action] ?? []);
    return (Number.isNaN(value) ? "-" : value.toFixed(1)).padStart(12);
  });
  console.log(action.padEnd(28) + cells.join(""));
}
JS
    ;;
*)
    sed -n 2,9p "$0"
    exit 1
    ;;
esac
