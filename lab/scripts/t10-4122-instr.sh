#!/usr/bin/env bash
# T10 #4122 mechanism: build A (re-anchor logging) and B (A + per-PID section-clock lanes) from
# 2b689c24, then run b7, b3, b5, mpts3-cc and a single-programme cut on both.
set -uo pipefail
S=$HOME/t10-bisect/scripts
FX=$HOME/t10-bisect/fx
OUT=$HOME/t10-bisect/instr
TREE=$HOME/tree-2b689c24
export CARGO_TARGET_DIR=$HOME/moq-main/target
. "$HOME/.cargo/env"
mkdir -p "$OUT"
[ -f "$FX/spts1-cc.ts" ] || tsp -I file "$FX/mpts3-cc.ts" -P zap 1 --stuffing --eit -O file "$FX/spts1-cc.ts" >"$OUT/zap.log" 2>&1
for v in A B; do
	if [ ! -x "$OUT/bin-$v/moq" ]; then
		(cd "$TREE" && git checkout -q -- . && python3 "$OUT/patch.py" "$v" "$TREE") >>"$OUT/build.log" 2>&1 || { echo "patch $v failed" >>"$OUT/summary.txt"; exit 1; }
		(cd "$TREE" && nice -n 19 cargo build --release -q -p moq-cli --bin moq) >>"$OUT/build.log" 2>&1 || { echo "build $v failed" >>"$OUT/summary.txt"; (cd "$TREE" && git checkout -q -- .); exit 1; }
		mkdir -p "$OUT/bin-$v"
		cp "$CARGO_TARGET_DIR/release/moq" "$OUT/bin-$v/"
		cp "$HOME/bin-2b689c24/moq-relay" "$OUT/bin-$v/"
		(cd "$TREE" && git diff --stat) >"$OUT/bin-$v/patch.stat"
		(cd "$TREE" && git checkout -q -- .)
	fi
done
echo "built $(date -u +%T)" >>"$OUT/summary.txt"
for f in cc2-b7 cc2-b3 cc2-b5 mpts3-cc spts1-cc; do
	for v in A B; do
		d="$OUT/$f-$v"
		BIN=$OUT/bin-$v bash "$S/t10-moq.sh" "$FX/$f.ts" "$d" "$f-$v" >"$d.out" 2>&1
		python3 "$S/t10-grade.py" "$FX/$f.ts" "$d/egress.ts" --label "$f-$v" --json "$d.json" >"$d.grade" 2>&1
		r=$(python3 - "$d.json" <<'EOF'
import json, sys
g = json.load(open(sys.argv[1]))
d = {e["pid"]: e["packets_egr"] for p in g["programs"] for e in p["es"]}
g = lambda p: d.get(p, "-")
s = sum(d.get(p, 0) for p in (141, 142, 143))
print(f"scte35={s} audio121={g(121)} ac3_123={g(123)} video111={g(111)}")
EOF
)
		ra=$(grep -c "t10: anchor re-anchored" "$d/pub.log")
		rs=$(grep -c "t10: section-clock lane re-anchored" "$d/pub.log")
		echo "$f $v $(grep pub_exit "$d/run.env") reanchors=$ra from_section_lane=$rs $r" | tee -a "$OUT/summary.txt"
		rm -f "$d/egress.ts"
	done
done
echo done >>"$OUT/summary.txt"
