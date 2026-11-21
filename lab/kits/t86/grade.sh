#!/usr/bin/env bash
# Grade one cell of the T86 kit, as run by run.sh; README.md gives each cell's pass rule.
# usage: grade.sh <fixtures-dir> <out-dir> <cell> <A|M>
set -u
FX=$(cd "${1:?usage: grade.sh <fixtures-dir> <out-dir> <cell> <A|M>}" && pwd)
OUT=${2:?} CELL=${3:?} ARM=${4:?}
LAB=$(cd "$(dirname "$0")/../../scripts" && pwd)
dir="$OUT/$CELL-$ARM"
[ -d "$dir" ] || {
	echo "grade.sh: no runs in $dir" >&2
	exit 1
}

# bytes <source> <b/s> <run>...: the output against its source, byte for byte, with the read gaps
bytes() {
	local src=$1 rate=$2
	shift 2
	python3 "$LAB/t86-loss-grade.py" "$src" "$@" --rate "$rate" | sed 1d
}

# verdict <file>: continuity events and the PCR check, as TSDuck reports them
verdict() {
	local cc pv
	cc=$(tsp -I file "$1" -P continuity -O drop 2>&1 | grep -c 'missing\|discontinuity' || true)
	pv=$(tsp -I file "$1" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 | tail -1 | sed 's/.*pcrverify: //')
	echo "cc events $cc; $pv"
}

echo "run | loss % | whole | lost s | gaps | tail s | cc | max gap ms | 1st byte s | joins at s | behind live s"
case $CELL in
r)
	bytes "$FX/base.ts" 9945951 "$dir/base"
	bytes "$FX/live.ts" 25000000 "$dir/live"
	for r in base live; do echo "$r source: $(verdict "$FX/$r.ts")"; echo "$r output: $(verdict "$dir/$r/out.ts")"; done
	;;
s)
	for x in A B C D E F; do bytes "$FX/s-$x.ts" 9945951 "$dir/$x"; done
	for d in back forward; do bytes "$FX/switch-$d.ts" 6000000 "$dir/switch-$d"; done
	;;
t)
	for r in none pub relay recv loop; do
		src=$FX/base.ts
		[ "$r" = loop ] && src=$FX/loop.ts
		python3 "$LAB/ts-passthrough-identity.py" "$src" "$dir/$r/out.ts" --json "$dir/$r/identity.json" >/dev/null
	done
	python3 "$LAB/t86-restart-grade.py" "$dir/none" "$dir/pub" "$dir/relay" "$dir/recv"
	python3 "$LAB/t86-restart-grade.py" --rate 9945951 "$dir/loop"
	;;
u)
	bytes "$dir/cut60.ts" 9945951 "$dir/L0" "$dir/L1" "$dir/L3"
	;;
v)
	for f in mpts3 mpts3-cc; do
		echo "== $f, the multiplex whole (U)"
		python3 "$LAB/ts-passthrough-identity.py" "$FX/$f.ts" "$dir/$f-U/out.ts" --json "$dir/$f-U/identity.json" >/dev/null
		python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('identity:', {k: d.get(k) for k in ('first_source_packet','end_source_packet','source_packets','gaps','foreign')})" \
			"$dir/$f-U/identity.json"
		python3 "$LAB/t10-grade.py" "$FX/$f.ts" "$dir/$f-U/out.ts" | grep -E '^-- programme'
		echo "== $f, per programme (P)"
		for n in 1 2 3; do
			python3 "$LAB/t10-grade.py" "$FX/$f.ts" "$dir/$f-P/egress-$n.ts" --json "$dir/$f-P/t10-$n.json" >/dev/null
			python3 -c "
import json, sys
j = json.load(open(sys.argv[1])); n = int(sys.argv[2])
p = next(x for x in j['programs'] if x['program'] == n)
v = next(e for e in p['es'] if e['pid'] == p['pcr_pid'])
print(f'programme {n}:', p['verdict'], 'PMT bit-identical' if p['pmt_bit_identical'] else 'PMT rebuilt',
      '| cc events', p['cc_events_egr'], f\"| video {100 * v['packets_egr'] / v['packets_src']:.1f} % of the source's packets\")" \
				"$dir/$f-P/t10-$n.json" "$n"
		done
	done
	;;
w)
	bytes "$FX/live.ts" 25000000 "$dir/live"
	bytes "$FX/live-splice.ts" 25000000 "$dir/splice"
	python3 "$LAB/t86-units-grade.py" "$FX/live.ts" "$dir/live/out.ts" | tail -1
	python3 "$LAB/t86-units-grade.py" "$FX/live-splice.ts" "$dir/splice/out.ts" | sed -n '1p;$p'
	;;
*)
	echo "grade.sh: unknown cell $CELL" >&2
	exit 2
	;;
esac
