#!/usr/bin/env bash
# T10 bisect step: which commit turns the media-aware lane's handling of a multiplex from a loud
# refusal (`ffa5b81b`) into silent loss (`2b689c24`). One `git bisect run` step: build HEAD's `moq`
# and `moq-relay`, run t10-moq.sh on the common-clock multiplex and on the independent-clock one,
# grade the first with t10-grade.py, and exit with the verdict.
#
#   cd <worktree> && git bisect start --first-parent --term-old=old --term-new=new 2b689c24 ffa5b81b
#   git bisect run bash <scripts>/t10-bisect-step.sh <root>
#   BIN_ONLY=~/bin-<sha> bash t10-bisect-step.sh <root>     # grade prebuilt binaries, no build
#
# Verdict, from the common-clock input only, fixed from the two endpoints' grades before the bisect:
#   old (exit 0)   SCTE-35 over PIDs 141-143 >= 150 packets and PID 121 audio >= 8,000 packets
#                  (ffa5b81b: 171 and 173 SCTE-35; 9,546 and 9,548 audio)
#   new (exit 1)   SCTE-35 over PIDs 141-143 <= 30 packets (2b689c24: 4 and 18)
#   skip (125)     anything between, a failed build, or a void capture
# The independent-clock input is recorded (publisher exit status, programme 1 and 3 video packets),
# not judged, so a commit that moves one property and not the other shows in verdicts.txt.
#
# JUDGE=ic judges the independent-clock input instead, and runs only that one:
#   old (exit 0)   the publisher refuses the multiplex, a non-zero exit (ffa5b81b: 1)
#   new (exit 1)   the publisher exits 0 (2b689c24, and already 66440a6c)
#
# Env: CC_SRC, IC_SRC (~/t10/fixture/mpts3-cc.ts, ~/t10/fixture/mpts3.ts), JUDGE (cc), JOBS (6),
# KEEP_TS (0).
# Builds with the default feature set into CARGO_TARGET_DIR (default ~/moq-main/target), and
# cleans it when under 6 GB is free.
set -uo pipefail
ROOT=${1:?output root}
CC_SRC=${CC_SRC:-$HOME/t10/fixture/mpts3-cc.ts}
IC_SRC=${IC_SRC:-$HOME/t10/fixture/mpts3.ts}
JUDGE=${JUDGE:-cc}
JOBS=${JOBS:-6}
KEEP_TS=${KEEP_TS:-0}
case $JUDGE in cc | ic) ;; *) echo "JUDGE must be cc or ic" >&2; exit 255 ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$HOME/moq-main/target}
# shellcheck source=/dev/null
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
mkdir -p "$ROOT"

if [ -n "${BIN_ONLY:-}" ]; then
	BIN=$BIN_ONLY
	sha=$(basename "$BIN")
else
	sha=$(git rev-parse --short=8 HEAD)
	BIN=$ROOT/bin-$sha
	echo "--- $(date -u +%FT%TZ) $sha $(git log -1 --format=%s | cut -c1-90)" >>"$ROOT/build.log"
	if (($(df --output=avail -k "$CARGO_TARGET_DIR" | tail -1) < 6000000)); then cargo clean -q; fi
	if ! nice -n 19 cargo build --release -q --jobs "$JOBS" -p moq-cli --bin moq >>"$ROOT/build.log" 2>&1 ||
		! nice -n 19 cargo build --release -q --jobs "$JOBS" -p moq-relay --bin moq-relay >>"$ROOT/build.log" 2>&1; then
		echo "$sha skip: build failed" >>"$ROOT/verdicts.txt"
		exit 125
	fi
	mkdir -p "$BIN"
	cp "$CARGO_TARGET_DIR/release/moq" "$CARGO_TARGET_DIR/release/moq-relay" "$BIN/"
	git rev-parse HEAD >"$BIN.sha"
fi

run() { # <label> <src>
	BIN=$BIN bash "$HERE/t10-moq.sh" "$2" "$ROOT/$sha-$1" "$sha-$1" >"$ROOT/$sha-$1.out" 2>&1
}
[ "$JUDGE" = cc ] && run cc "$CC_SRC"
run ic "$IC_SRC"

grade() { # <label> <src>
	[ -s "$ROOT/$sha-$1/egress.ts" ] || return 1
	python3 "$HERE/t10-grade.py" "$2" "$ROOT/$sha-$1/egress.ts" --label "$sha-$1" \
		--json "$ROOT/$sha-$1.json" >"$ROOT/$sha-$1.grade" 2>&1
}
es() { # <label> <pid>... -> packets at egress, summed over the PIDs
	python3 - "$ROOT/$sha-$1.json" "${@:2}" <<'EOF'
import json, sys
g = json.load(open(sys.argv[1]))
pids = {int(p) for p in sys.argv[2:]}
print(sum(e["packets_egr"] for p in g["programs"] for e in p["es"] if e["pid"] in pids))
EOF
}
pub() { sed -n 's/^pub_exit=//p' "$ROOT/$sha-$1/run.env" 2>/dev/null || echo unknown; }

ic="ic pub_exit=$(pub ic)"
if grade ic "$IC_SRC"; then ic="$ic video111=$(es ic 111) video785=$(es ic 785)"; else ic="$ic void"; fi
if [ "$JUDGE" = ic ]; then
	case $(pub ic) in
	0) verdict=new code=1 ;;
	unknown | '') verdict=skip code=125 ;;
	*) verdict=old code=0 ;;
	esac
	if [ "$KEEP_TS" != 1 ]; then rm -f "$ROOT/$sha-ic/egress.ts"; fi
	echo "$sha $verdict (ic): $ic" >>"$ROOT/verdicts.txt"
	exit "$code"
fi
if ! grade cc "$CC_SRC"; then
	echo "$sha skip: common-clock capture void, cc pub_exit=$(pub cc); $ic" >>"$ROOT/verdicts.txt"
	exit 125
fi
scte=$(es cc 141 142 143)
audio=$(es cc 121)
if [ "$KEEP_TS" != 1 ]; then rm -f "$ROOT/$sha-cc/egress.ts" "$ROOT/$sha-ic/egress.ts"; fi

if [ "$scte" -ge 150 ] && [ "$audio" -ge 8000 ]; then
	verdict=old code=0
elif [ "$scte" -le 30 ]; then
	verdict=new code=1
else
	verdict=skip code=125
fi
echo "$sha $verdict: cc pub_exit=$(pub cc) scte35=$scte audio121=$audio; $ic" >>"$ROOT/verdicts.txt"
exit "$code"
