#!/usr/bin/env bash
# T6, segmented-HTTP arm — one redundancy drill, start to finish, on loopback.
#
#   t6-segmented-arm.sh <drill> <out-dir>
#
# The media-aware half of T6 asks three questions of the lane: does a receiver
# survive the serving node dying, does an active/active source pair fail over,
# and is a graceful source exit covered. This runs the segmented equivalents so
# the two can be compared on the same clip, the same host and the same clock.
#
# The mapping is exact enough to be worth stating, because the roles are not in
# the same places:
#
#   moq import ts  -> tsp -O hls          the source (writes segments+playlist)
#   moq-relay      -> an HTTP origin      the serving node
#   moq export ts  -> tsp -I hls / ffmpeg the receiver
#
# Drills:
#   baseline          reference: nothing is killed
#   origin-restart    kill the origin mid-stream, restart it on the same port
#   dual-source       two packagers, one URL namespace; kill the active
#   dual-source-align as above, standby continues the media sequence
#   graceful-exit     the active packager reaches EOF and writes ENDLIST
#   determinism       two independent packagers of one source, compared
#
# RECV=tsp|ffmpeg picks the client. That knob is load-bearing rather than a
# convenience: `tsp -I hls` has no retry option at all, so a drill run only
# under it grades TSDuck's error handling and reports it as a property of
# segmented HTTP. ffmpeg with --reconnect is the same protocol with a client
# that retries, and the difference between the two is the actual finding.
#
# Prints one `RESULT ` line of key=value pairs, plus sizes.csv and logs.
set -uo pipefail

DRILL=${1:?drill}
OUT=${2:?output dir}

SRC=${SRC:-$HOME/CNNiEMEA2.ts}
SEGSECS=${SEGSECS:-2}
PORT=${PORT:-18190}
RECV=${RECV:-tsp}
LIVE=${LIVE:-6}          # segments referenced in the playlist
EXTRA=${EXTRA:-3}        # unreferenced segments kept on disk

# Drill timeline, seconds from the receiver starting.
T_EVENT=${T_EVENT:-25}   # kill the origin / kill the active packager
T_DOWN=${T_DOWN:-10}     # how long the origin stays down
T_STANDBY=${T_STANDBY:-12} # when the standby packager joins
T_END=${T_END:-75}

SRC_BPS=${SRC_BPS:-9945951}

sz() { stat -f%z "$1" 2>/dev/null || echo 0; }

rm -rf "$OUT"; mkdir -p "$OUT"
WWW="$OUT/www"; mkdir -p "$WWW"

PIDS=()
ORIGIN_PID=""
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
	[ -n "$ORIGIN_PID" ] && kill "$ORIGIN_PID" 2>/dev/null
	pkill -f "http.server $PORT" 2>/dev/null
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- pieces -------------------------------------------------------------------

# A packager writing into $WWW. $1=name, $2=playlist, rest=extra tsp -O hls args.
pack() {
	local name=$1 pl=$2; shift 2
	tsp --realtime \
		-I file "$SRC" --infinite \
		-P regulate --pcr-synchronous \
		-O hls "$WWW/${name}.ts" \
		--playlist "$WWW/$pl" \
		--duration "$SEGSECS" \
		--live "$LIVE" --live-extra-segments "$EXTRA" \
		--intra-close --align-first-segment \
		"$@" >"$OUT/$name.log" 2>&1 &
	echo $!
}

# The same, but finite: reaches EOF and writes #EXT-X-ENDLIST. $3=seconds.
pack_finite() {
	local name=$1 pl=$2 secs=$3
	tsp --realtime \
		-I file "$SRC" --infinite \
		-P regulate --pcr-synchronous \
		-P until --seconds "$secs" \
		-O hls "$WWW/${name}.ts" \
		--playlist "$WWW/$pl" \
		--duration "$SEGSECS" \
		--live "$LIVE" --live-extra-segments "$EXTRA" \
		--intra-close --align-first-segment \
		>"$OUT/$name.log" 2>&1 &
	echo $!
}

# A unique token per cell, served out of this cell's document root. It is the
# only way to tell "my origin is up" from "somebody else's origin is up on my
# port": a previous cell's server that outlived its own teardown answers on the
# same port, serves a different directory, and the drill then reports a clean,
# plausible result for a condition it never ran. That happened once here, and
# nothing in the delivered numbers gave it away.
CELL_ID="t6-$$-$(date +%s)"

origin_start() {
	echo "$CELL_ID" >"$WWW/.cell-id"
	(cd "$WWW" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
		>>"$OUT/origin.log" 2>&1 &
	ORIGIN_PID=$!
	local got
	for _ in $(seq 1 40); do
		got=$(curl -fsS --max-time 1 "http://127.0.0.1:$PORT/.cell-id" 2>/dev/null)
		[ "$got" = "$CELL_ID" ] && return 0
		sleep 0.25
	done
	echo "RESULT drill=$DRILL recv=$RECV status=ORIGIN_NOT_MINE got=\"${got:-none}\" want=$CELL_ID"
	exit 1
}

# Refuse to start on a port somebody else is already holding, rather than
# discovering it later as a confusing result.
port_free_or_die() {
	for _ in $(seq 1 20); do
		lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0
		sleep 0.5
	done
	echo "RESULT drill=$DRILL recv=$RECV status=PORT_BUSY port=$PORT"
	exit 1
}

# Wait until the playlist has a live edge to join. `tsp -I hls` exits on an
# empty playlist rather than waiting for one.
wait_playlist() {
	local pl=$1
	for _ in $(seq 1 90); do
		[ -f "$WWW/$pl" ] &&
			[ "$(grep -c '\.ts$' "$WWW/$pl" 2>/dev/null || echo 0)" -ge 3 ] && return 0
		sleep 1
	done
	return 1
}

CAP="$OUT/receive.ts"

recv_start() {
	local pl=$1
	case $RECV in
	tsp)
		tsp --realtime -I hls "http://127.0.0.1:$PORT/$pl" --live \
			-O file "$CAP" >"$OUT/receive.log" 2>&1 &
		;;
	ffmpeg)
		# Every retry knob ffmpeg offers on this path, so that a failure here is
		# a statement about the demuxer and not about the invocation.
		ffmpeg -nostdin -loglevel warning \
			-reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 \
			-reconnect_delay_max 4 \
			-seg_max_retry 20 -max_reload 1000 -m3u8_hold_counters 1000 \
			-i "http://127.0.0.1:$PORT/$pl" -c copy -f mpegts "$CAP" \
			>"$OUT/receive.log" 2>&1 &
		;;
	pull)
		# The floor: a client whose only feature is that a failed fetch is a
		# retry. Establishes what the protocol permits, against which the two
		# off-the-shelf clients are measured.
		python3 "$(dirname "$0")/t6-hls-pull.py" \
			"http://127.0.0.1:$PORT/$pl" "$CAP" \
			--seconds "$T_END" --retry "${PULL_RETRY:-500}" \
			--log "$OUT/receive.log" >"$OUT/pull.out" 2>&1 &
		;;
	esac
	RECV_PID=$!
	PIDS+=("$RECV_PID")
}

# One row per second, so the outage is visible as stalled growth rather than
# inferred from a total.
sampler_start() {
	(
		echo "t,bytes,event"
		for t in $(seq 0 "$T_END"); do
			printf "%s,%s,%s\n" "$t" "$(sz "$CAP")" "${EVENTS[$t]:-}"
			sleep 1
		done
	) >"$OUT/sizes.csv" &
	SAMP=$!
	PIDS+=("$SAMP")
}

declare -a EVENTS

# One line per second recording which source owns the playlist. On a drill where
# two packagers share a namespace this is the mechanism: the playlist is a single
# mutable file with a last-writer-wins update rule, and the receiver's view of the
# stream is whatever it happened to read.
playlist_watch() {
	local pl=$1
	(
		echo "t,media_seq,n_segs,owners"
		for t in $(seq 0 "$T_END"); do
			if [ -f "$WWW/$pl" ]; then
				seq_no=$(grep -m1 '^#EXT-X-MEDIA-SEQUENCE' "$WWW/$pl" | cut -d: -f2 | tr -d '[:space:]')
				segs=$(grep -c '\.ts$' "$WWW/$pl")
				own=$(grep '\.ts$' "$WWW/$pl" | sed 's/-[0-9]*\.ts$//' | sort -u | tr '\n' '+' | sed 's/+$//')
				printf "%s,%s,%s,%s\n" "$t" "${seq_no:-?}" "$segs" "$own"
			else
				printf "%s,,,\n" "$t"
			fi
			sleep 1
		done
	) >"$OUT/playlist.csv" &
	PIDS+=($!)
}

# --- drills -------------------------------------------------------------------

STATUS=ok
NOTE=""

port_free_or_die

case $DRILL in

baseline | origin-restart)
	P1=$(pack segA index.m3u8); PIDS+=("$P1")
	origin_start
	wait_playlist index.m3u8 || { echo "RESULT drill=$DRILL status=no_playlist"; exit 1; }
	EVENTS[T_EVENT]="KILL_origin"
	EVENTS[T_EVENT + T_DOWN]="RESTART_origin"
	[ "$DRILL" = baseline ] && EVENTS=()
	recv_start index.m3u8
	sampler_start
	if [ "$DRILL" = origin-restart ]; then
		sleep "$T_EVENT"
		echo ">> t=$T_EVENT kill origin ($ORIGIN_PID)"
		kill "$ORIGIN_PID" 2>/dev/null; ORIGIN_PID=""
		sleep "$T_DOWN"
		echo ">> t=$((T_EVENT + T_DOWN)) restart origin"
		origin_start
		sleep $((T_END - T_EVENT - T_DOWN))
	else
		sleep "$T_END"
	fi
	;;

dual-source | dual-source-align)
	# Two packagers, one URL namespace: the segmented analogue of two publishers
	# announcing the same broadcast. They share a playlist name and a directory,
	# which is the only way a client pointed at one URL can be served by either.
	P1=$(pack segA index.m3u8); PIDS+=("$P1")
	origin_start
	wait_playlist index.m3u8 || { echo "RESULT drill=$DRILL status=no_playlist"; exit 1; }
	EVENTS[T_STANDBY]="standby_join"
	EVENTS[T_EVENT]="KILL_active"
	recv_start index.m3u8
	sampler_start
	playlist_watch index.m3u8

	sleep "$T_STANDBY"
	if [ "$DRILL" = dual-source-align ]; then
		# Continue the active's media sequence instead of restarting at 0 — the
		# segmented analogue of T6's aligned-vs-offset group numbering question.
		SEQ=$(grep -m1 '^#EXT-X-MEDIA-SEQUENCE' "$WWW/index.m3u8" | cut -d: -f2 | tr -d '[:space:]')
		: "${SEQ:=0}"
		NEXT=$((SEQ + LIVE + 8))
		echo ">> t=$T_STANDBY standby joins, --start-media-sequence $NEXT"
		P2=$(pack segB index.m3u8 --start-media-sequence "$NEXT")
	else
		echo ">> t=$T_STANDBY standby joins (own numbering)"
		P2=$(pack segB index.m3u8)
	fi
	PIDS+=("$P2")

	sleep $((T_EVENT - T_STANDBY))
	echo ">> t=$T_EVENT kill active packager ($P1)"
	kill "$P1" 2>/dev/null
	sleep $((T_END - T_EVENT))
	;;

dual-source-common)
	# The same two-packagers-one-namespace shape, but fed from ONE source rather
	# than from two independent reads of the clip. This distinction is the whole
	# drill: two packagers each opening the file for themselves sit at different
	# points in the media timeline by exactly their start skew, so a drill built
	# that way measures its own clock offset and reports it as a protocol result.
	# T6's media-aware half learned this the hard way and the rule is in
	# method-notes; this is the arm that obeys it.
	#
	# `gtee` fans one regulated stream into two FIFOs. Both packagers are started
	# first so the FIFOs have readers before the source flows, which also means
	# both see byte 0 — the segmented analogue of T6's E1. When the active is
	# killed its FIFO reader closes and `gtee` takes EPIPE on that output only;
	# --output-error=warn keeps the survivor fed.
	# With DUAL_NAMES=shared both packagers write the *same* segment filenames.
	# That is the configuration a working hot pair needs: identical content under
	# identical names, so a client keyed on URI cannot tell which of the two served
	# it and fetches each second of media once. Distinct names make the pair's
	# output correct and still unusable, because the client fetches both copies.
	NA=segA; NB=segB
	[ "${DUAL_NAMES:-distinct}" = shared ] && { NA=seg; NB=seg; }
	mkfifo "$OUT/fA" "$OUT/fB"
	tsp --realtime -I file "$OUT/fA" \
		-O hls "$WWW/$NA.ts" --playlist "$WWW/index.m3u8" \
		--duration "$SEGSECS" --live "$LIVE" --live-extra-segments "$EXTRA" \
		--intra-close --align-first-segment >"$OUT/segA.log" 2>&1 &
	P1=$!; PIDS+=("$P1")
	tsp --realtime -I file "$OUT/fB" \
		-O hls "$WWW/$NB.ts" --playlist "$WWW/index.m3u8" \
		--duration "$SEGSECS" --live "$LIVE" --live-extra-segments "$EXTRA" \
		--intra-close --align-first-segment >"$OUT/segB.log" 2>&1 &
	P2=$!; PIDS+=("$P2")
	(tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - |
		gtee --output-error=warn "$OUT/fA" "$OUT/fB" >/dev/null) 2>"$OUT/source.log" &
	SRCPID=$!; PIDS+=("$SRCPID")

	origin_start
	wait_playlist index.m3u8 || { echo "RESULT drill=$DRILL status=no_playlist"; exit 1; }
	EVENTS[T_EVENT]="KILL_active"
	recv_start index.m3u8
	sampler_start
	playlist_watch index.m3u8
	sleep "$T_EVENT"
	# T6's media-aware half separates these two and gets opposite answers: a hard
	# kill is recovered in ~30 s, a graceful exit is not recovered at all. Keep
	# them separable here rather than taking whatever `kill` defaults to.
	echo ">> t=$T_EVENT SIG${KILL_SIG:-KILL} active packager ($P1)"
	kill "-${KILL_SIG:-KILL}" "$P1" 2>/dev/null
	sleep $((T_END - T_EVENT))
	;;

graceful-exit)
	# The active reaches EOF and writes #EXT-X-ENDLIST while a standby is live in
	# the same namespace. On the media-aware lane this case fails outright: the
	# relay propagates completion instead of reselecting and the exporter dies.
	P1=$(pack_finite segA index.m3u8 $((T_EVENT + 20))); PIDS+=("$P1")
	origin_start
	wait_playlist index.m3u8 || { echo "RESULT drill=$DRILL status=no_playlist"; exit 1; }
	EVENTS[T_STANDBY]="standby_join"
	EVENTS[T_EVENT]="active_EOF"
	recv_start index.m3u8
	sampler_start
	playlist_watch index.m3u8
	sleep "$T_STANDBY"
	echo ">> t=$T_STANDBY standby joins"
	P2=$(pack segB index.m3u8); PIDS+=("$P2")
	sleep $((T_END - T_STANDBY))
	;;

endlist-race)
	# A hot-standby pair sharing one playlist has one hazard the hard-kill case
	# does not: a departing packager announces the end of the *stream*, not the end
	# of itself. `tsp -O hls` writes #EXT-X-ENDLIST on both a clean EOF and a
	# SIGTERM, into the file its partner is still updating. Any conformant client
	# reading the playlist in that window is entitled to stop. This measures the
	# window: poll at 50 ms and record how long ENDLIST is visible before the
	# survivor's next rewrite removes it.
	mkfifo "$OUT/fA" "$OUT/fB"
	for leg in A B; do
		# shellcheck disable=SC2154 # assigned by the eval above
		eval "f=\$OUT/f$leg"
		# shellcheck disable=SC2154 # $f is set by the eval above
		tsp --realtime -I file "$f" -O hls "$WWW/seg.ts" \
			--playlist "$WWW/index.m3u8" --duration "$SEGSECS" \
			--live "$LIVE" --live-extra-segments "$EXTRA" \
			--intra-close --align-first-segment >"$OUT/seg$leg.log" 2>&1 &
		eval "P$leg=\$!"
		PIDS+=($!)
	done
	(tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - |
		gtee --output-error=warn "$OUT/fA" "$OUT/fB" >/dev/null) 2>"$OUT/source.log" &
	PIDS+=($!)
	wait_playlist index.m3u8 || { echo "RESULT drill=$DRILL status=no_playlist"; exit 1; }
	python3 - "$WWW/index.m3u8" "$OUT/endlist.csv" "${ENDLIST_WATCH:-25}" <<-'PY' &
		import sys, time
		pl, out, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
		end = time.time() + secs
		with open(out, "w", buffering=1) as f:
		    f.write("t,endlist\n")
		    t0 = time.time()
		    while time.time() < end:
		        try:
		            present = "#EXT-X-ENDLIST" in open(pl).read()
		        except OSError:
		            present = False
		        f.write(f"{time.time() - t0:.3f},{int(present)}\n")
		        time.sleep(0.05)
	PY
	WATCH=$!
	sleep 5
	echo ">> SIGTERM leg A ($PA)"
	kill -TERM "$PA" 2>/dev/null
	wait "$WATCH" 2>/dev/null
	cleanup
	python3 - "$OUT/endlist.csv" <<-'PY'
		import csv, sys
		rows = list(csv.DictReader(open(sys.argv[1])))
		on = [r for r in rows if r["endlist"] == "1"]
		runs, cur = [], 0.0
		for r in rows:
		    if r["endlist"] == "1":
		        cur += 0.05
		    elif cur:
		        runs.append(cur); cur = 0.0
		if cur: runs.append(cur)
		print(f"RESULT drill=endlist-race samples={len(rows)} endlist_samples={len(on)} "
		      f"windows={len(runs)} longest_window_s={max(runs, default=0):.2f} "
		      f"total_visible_s={sum(runs):.2f}")
	PY
	exit 0
	;;

determinism-live)
	# The precondition that actually matters. `determinism` compares two packagers
	# each reading the same file, which is deterministic almost by construction;
	# a real pair reads one live feed. This fans a single regulated stream into
	# two packagers and asks whether they cut it in the same places, which is the
	# segmented analogue of the ST 2022-7 output-determinism study. No rotation,
	# so every segment survives to be compared.
	mkdir -p "$WWW/a" "$WWW/b"
	mkfifo "$OUT/fA" "$OUT/fB"
	tsp --realtime -I file "$OUT/fA" -O hls "$WWW/a/seg.ts" \
		--playlist "$WWW/a/index.m3u8" --duration "$SEGSECS" \
		--intra-close --align-first-segment >"$OUT/detA.log" 2>&1 &
	PIDS+=($!)
	tsp --realtime -I file "$OUT/fB" -O hls "$WWW/b/seg.ts" \
		--playlist "$WWW/b/index.m3u8" --duration "$SEGSECS" \
		--intra-close --align-first-segment >"$OUT/detB.log" 2>&1 &
	PIDS+=($!)
	(tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-P until --seconds "${DET_SECS:-40}" -O file - |
		gtee --output-error=warn "$OUT/fA" "$OUT/fB" >/dev/null) 2>"$OUT/source.log" &
	wait $! 2>/dev/null
	sleep 3
	;;

determinism)
	# Two independent packagers of one source, each in its own namespace. The
	# question is the segmented analogue of the ST 2022-7 precondition: are the
	# two outputs interchangeable at the segment level, so a receiver (or a
	# dedup relay) could merge or switch between them without re-anchoring?
	mkdir -p "$WWW/a" "$WWW/b"
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-P until --seconds 40 \
		-O hls "$WWW/a/seg.ts" --playlist "$WWW/a/index.m3u8" \
		--duration "$SEGSECS" --intra-close --align-first-segment \
		>"$OUT/detA.log" 2>&1 &
	DA=$!
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-P until --seconds 40 \
		-O hls "$WWW/b/seg.ts" --playlist "$WWW/b/index.m3u8" \
		--duration "$SEGSECS" --intra-close --align-first-segment \
		>"$OUT/detB.log" 2>&1 &
	DB=$!
	wait "$DA" "$DB" 2>/dev/null
	;;

*) echo "unknown drill: $DRILL" >&2; exit 2 ;;
esac

# Whether the client gave up has to be read before teardown kills it, and it is
# the single most important bit on this arm: a receiver that exits has not
# "recovered slowly", it has stopped being a receiver.
RECV_ALIVE=no
kill -0 "${RECV_PID:-0}" 2>/dev/null && RECV_ALIVE=yes

cleanup
sleep 1

# --- grading ------------------------------------------------------------------

case "$DRILL" in determinism | determinism-live)
	python3 - "$WWW/a" "$WWW/b" "$DRILL" <<-'PY'
		import hashlib, pathlib, sys
		a, b = (sorted(pathlib.Path(d).glob('seg*.ts')) for d in sys.argv[1:3])
		def h(p): return hashlib.sha256(p.read_bytes()).hexdigest()
		n = min(len(a), len(b))
		ident = sum(1 for i in range(n) if h(a[i]) == h(b[i]))
		samesize = sum(1 for i in range(n) if a[i].stat().st_size == b[i].stat().st_size)
		sizes_a = [p.stat().st_size for p in a[:n]]
		sizes_b = [p.stat().st_size for p in b[:n]]
		print(f"RESULT drill={sys.argv[3]} segs_a={len(a)} segs_b={len(b)} compared={n} "
		      f"identical={ident} same_size={samesize} "
		      f"bytes_a={sum(sizes_a)} bytes_b={sum(sizes_b)}")
	PY
	exit 0
	;;
esac

BYTES=$(sz "$CAP")
RATIO=$(awk -v b="$BYTES" -v s="$T_END" -v r="$SRC_BPS" 'BEGIN{printf "%.3f",(b*8/s)/r}')

# The outage, straight off the sampler: the longest run of seconds in which the
# receiver's output did not grow, and where it started.
GAP=$(python3 - "$OUT/sizes.csv" <<-'PY'
	import csv, sys
	rows = list(csv.DictReader(open(sys.argv[1])))
	best = cur = 0; start = bstart = None; prev = None
	for r in rows:
	    t, b = int(r['t']), int(r['bytes'])
	    if prev is not None:
	        if b == prev:
	            cur += 1
	            if start is None: start = t - 1
	        else:
	            if cur > best: best, bstart = cur, start
	            cur = 0; start = None
	    prev = b
	if cur > best: best, bstart = cur, start
	# trailing stall means it never came back
	tail = 0
	for r in reversed(rows):
	    if int(r['bytes']) == int(rows[-1]['bytes']): tail += 1
	    else: break
	print(f"max_stall_s={best} stall_at={bstart if bstart is not None else -1} tail_stall_s={tail-1}")
PY
)

CCERR=0
CLOCK="pcr_fwd_leaps=0 pcr_rewinds=0 rewind_max_s=0"
if [ "$BYTES" -gt 100000 ]; then
	CCERR=$(tsp -I file "$CAP" -P continuity -O drop 2>&1 | grep -c 'discontinuity' || true)
	tsp -I file "$CAP" -P pcrextract --pcr --csv -o "$OUT/pcr.csv" -O drop >/dev/null 2>&1 || true
	# A lane that can be served by two sources at once fails by *repeating* time,
	# not by losing it, and neither a continuity-counter check nor a PCR-interval
	# check can see that: both only look at whether the clock moved, not at which
	# way. The rewind count is the metric that catches it.
	# Column 6 is the PCR itself. Column 7 ("Value offset in PID") differences to
	# the same thing only while the clock advances: it is an unsigned quantity, so
	# the one event this metric exists to catch is exactly the one that wraps it
	# into a meaningless positive number.
	[ -s "$OUT/pcr.csv" ] && CLOCK=$(awk -F, 'NR>1 && $6!=""{c=$6+0;
		if(p!=""){d=(c-p)/27000000;
			if(d>1){f++}
			else if(d<0){r++; if(-d>mx)mx=-d}}
		p=c}
		END{printf "pcr_fwd_leaps=%d pcr_rewinds=%d rewind_max_s=%.1f",f,r,mx}' "$OUT/pcr.csv")
fi

HTTP_GETS=$(grep -c '"GET' "$OUT/origin.log" 2>/dev/null || true)
HTTP_NON200=$(grep '"GET' "$OUT/origin.log" 2>/dev/null | grep -vc ' 200 -$' || true)
RECV_ERR=$(grep -ciE 'error|cannot|failed|refused|reconnect' "$OUT/receive.log" 2>/dev/null || true)
: "${HTTP_GETS:=0}" "${HTTP_NON200:=0}" "${RECV_ERR:=0}"

echo "RESULT drill=$DRILL recv=$RECV bytes=$BYTES rate_ratio=$RATIO $GAP" \
	"cc_disc=$CCERR $CLOCK http_gets=$HTTP_GETS http_non200=$HTTP_NON200" \
	"recv_log_errs=$RECV_ERR recv_alive_at_end=$RECV_ALIVE status=$STATUS$NOTE"
