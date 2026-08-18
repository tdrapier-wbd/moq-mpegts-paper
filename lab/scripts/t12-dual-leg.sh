#!/usr/bin/env bash
# T12 — end-to-end 1+1 dual-path delivery rig.
#
# One source feeds two complete delivery legs (publisher -> relay -> subscriber ->
# RTP/UDP egress). Both legs are captured by a single tcpdump on one interface, so
# the receiver-side merge and the leg skew can be reconstructed offline by
# t12-merge-oracle.py.
#
# Arms differ only in how each leg turns delivered MoQ objects into RTP:
#   a  two chains, no pacer      (tsp -O ip --rtp, framing pinned identically)
#   b  two chains, one pacer each (mpegts-pacer --rtp)
#   c  one chain, groom once, duplicate the datagrams (mpegts-pacer's dual_rtp example)
#   d  two chains, one *stream-clocked* pacer each (mpegts-pacer --rtp --stream-clock)
#
# Arm c has a single upstream chain by construction, so only the path injections
# apply to it; the upstream ones take the whole arm down, which is the result, not
# a rig failure.
#
# Arm d is arm b with the placement decision moved off the pacer's emit clock and
# onto the stream, which is what makes two independently groomed legs a pair. It
# needs an explicit RATE: an auto rate is measured from one process's arrival
# window, so the two legs would lock different grids.
#
# Every machine-specific value comes from the environment:
#   SRC        source clip (a video-only remux if the run loops it)
#   MOQ        moq client binary
#   MOQ_RELAY  moq-relay binary
#   PACER      directory holding the built mpegts-pacer binary and dual_rtp example
#
# Usage: ARM=c INJECT=blackout SECS=60 AT=30 ./t12-dual-leg.sh <label>
set -euo pipefail

LABEL=${1:?usage: [ARM=a|b|c] [INJECT=...] $0 <label>}

ARM=${ARM:-c}
INJECT=${INJECT:-none}
SECS=${SECS:-60}
AT=${AT:-30}
RATE=${RATE:-auto}
SRC=${SRC:?set SRC to the source clip}
MOQ=${MOQ:?set MOQ to the moq client binary}
MOQ_RELAY=${MOQ_RELAY:?set MOQ_RELAY to the moq-relay binary}
PACER=${PACER:?set PACER to the directory holding the pacer binary and dual_rtp}
OUTDIR=${OUTDIR:-./t12-runs}
PORT_A=${PORT_A:-7443}
PORT_B=${PORT_B:-7543}
RTP_A_PORT=${RTP_A_PORT:-5100}
RTP_B_PORT=${RTP_B_PORT:-5200}
RTP_HOST=${RTP_HOST:-127.0.0.1}
SSRC=${SSRC:-538968071}          # 0x20220007
SEQ_SEED=${SEQ_SEED:-0}          # arm d: RTP sequence offset, identical on both legs
BCAST=${BCAST:-t12.$LABEL.hang}   # unique per run: a reused name can leave a stale announce
IDLE=${IDLE:-30s}
KEEPALIVE=${KEEPALIVE:-5s}
LATENCY_MAX=${LATENCY_MAX:-500ms}
PACER_LAT=${PACER_LAT:-1000}     # pacer release latency, ms
PACER_MAXLAT=${PACER_MAXLAT:-8000}  # pacer buffer depth, ms (bursts beyond this drop)
PACER_STALL=${PACER_STALL:-1000} # silence before the pacer calls the source gone, ms (0 disables)
PACER_ONSTALL=${PACER_ONSTALL:-mute}  # mute | continue | fail
IFACE=${IFACE:-lo}
SETTLE=${SETTLE:-8}              # seconds between starting the chains and capturing
DELAY_B=${DELAY_B:-0}            # start leg B's egress this many seconds late (mid-stream standby)
RECOVER=${RECOVER:-15}           # how long a *_recover injection lasts before it is cleared

# The pacer's egress adapter was moq_egress, then ts_egress, and is now the crate's
# binary `mpegts-pacer`. Accept any of the three, so this rig runs against the build it
# was written for and against current heads.
EGRESS="$PACER/moq_egress"
for candidate in mpegts-pacer ts_egress moq_egress; do
	if [[ -x "$PACER/$candidate" ]]; then
		EGRESS="$PACER/$candidate"
		break
	fi
done

RUN="$OUTDIR/$LABEL"
rm -rf "$RUN"; mkdir -p "$RUN"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RUN/run.log"; }

# ---------------------------------------------------------------- teardown ----
# Every pid is tracked in the parent shell: a `track` inside a command
# substitution appends to a subshell's copy of the array and leaks the process.
# A leaked relay is not a harmless leak — the next run's relay fails to bind, its
# publisher lands on the old relay, and the subscriber joins a stale announce and
# receives nothing.
PIDS=()
track() { PIDS+=("$1"); }

tc_clear() { sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true; }

cleanup() {
	set +e
	tc_clear
	for p in "${PIDS[@]:-}"; do
		[ -n "$p" ] && kill -KILL -"$p" 2>/dev/null
		[ -n "$p" ] && kill -KILL "$p" 2>/dev/null
	done
	sudo pkill -f "tcpdump.*$LABEL" 2>/dev/null
	pkill -f "server-bind 127\.0\.0\.1:$PORT_A" 2>/dev/null
	pkill -f "server-bind 127\.0\.0\.1:$PORT_B" 2>/dev/null
	pkill -f "${BCAST//./\\.}" 2>/dev/null
	rm -f "$RUN"/fifo_*
}
trap cleanup EXIT

port_free() { # abort rather than run on someone else's relay
	local port=$1
	if ss -lun 2>/dev/null | grep -q "127.0.0.1:$port "; then
		echo "port $port is already bound — refusing to start (stale relay?)" >&2
		exit 3
	fi
}

# ------------------------------------------------------------------ helpers ---
start_relay() { # port logfile
	local port=$1 logf=$2
	setsid "$MOQ_RELAY" --server-bind "127.0.0.1:$port" --tls-generate localhost \
		--auth-public "" --server-quic-idle-timeout "$IDLE" \
		--server-quic-keep-alive "$KEEPALIVE" \
		>"$logf" 2>&1 </dev/null &
	echo $!
}

relay_bound() { # logfile
	if grep -qi 'failed to bind\|Address already in use' "$1"; then
		echo "relay failed to bind (see $1)" >&2
		exit 3
	fi
}

start_importer() { # fifo port logfile -> pid of the setsid group
	local fifo=$1 port=$2 logf=$3
	setsid bash -c "cat '$fifo' | '$MOQ' --client-tls-disable-verify \
		--client-connect 'https://localhost:$port/anon' --broadcast '$BCAST' import ts" \
		>"$logf" 2>&1 </dev/null &
	echo $!
}

start_leg_egress() { # port rtp_port logfile -> pid (exporter + egress pipeline)
	local port=$1 rtp_port=$2 logf=$3 egress
	case "$ARM" in
	# tsp pre-fills its input buffer before the plugin chain emits anything, and the
	# default 8 MB is ~32 s at 2 Mb/s — a live leg looks dead. Bound it.
	a) egress="tsp --buffer-size-mb 1 -O ip $RTP_HOST:$rtp_port --rtp --enforce-burst \
			--packet-burst 7 --start-sequence-number 0 --ssrc-identifier $SSRC" ;;
	b) egress="'$EGRESS' $RTP_HOST:$rtp_port $RATE --rtp --ssrc $SSRC \
			--latency-ms $PACER_LAT --max-latency-ms $PACER_MAXLAT \
			--stall-ms $PACER_STALL --on-stall $PACER_ONSTALL" ;;
	# Both legs take the same seed: the offset is a property of the pair, and the
	# numbering within it stays a function of stream position.
	d) egress="'$EGRESS' $RTP_HOST:$rtp_port $RATE --rtp --ssrc $SSRC \
			--latency-ms $PACER_LAT --max-latency-ms $PACER_MAXLAT \
			--stall-ms $PACER_STALL --on-stall $PACER_ONSTALL \
			--stream-clock --sequence-seed $SEQ_SEED" ;;
	*) return 1 ;;
	esac
	setsid bash -c "'$MOQ' --client-tls-disable-verify \
		--client-connect 'https://localhost:$port/anon' --broadcast '$BCAST' \
		export ts --latency-max $LATENCY_MAX | $egress" \
		>"$logf" 2>&1 </dev/null &
	echo $!
}

start_dual_egress() { # port logfile -> pid (arm c: one exporter, two destinations)
	local port=$1 logf=$2
	setsid bash -c "'$MOQ' --client-tls-disable-verify \
		--client-connect 'https://localhost:$port/anon' --broadcast '$BCAST' \
		export ts --latency-max $LATENCY_MAX \
		| '$PACER/dual_rtp' $RTP_HOST:$RTP_A_PORT $RTP_HOST:$RTP_B_PORT $RATE \
			--ssrc $SSRC --seq 0 --latency-ms $PACER_LAT --max-latency-ms $PACER_MAXLAT \
			--stall-ms $PACER_STALL --on-stall $PACER_ONSTALL" \
		>"$logf" 2>&1 </dev/null &
	echo $!
}

netem_lane() { # match-port spec  (impairs UDP traffic to that destination port)
	local port=$1 spec=$2
	sudo tc qdisc add dev "$IFACE" root handle 1: prio bands 4 \
		priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2>/dev/null || true
	sudo tc qdisc replace dev "$IFACE" parent 1:4 handle 40: netem $spec
	sudo tc filter replace dev "$IFACE" parent 1:0 protocol ip prio 1 u32 \
		match ip protocol 17 0xff match ip dport "$port" 0xffff flowid 1:4
	# never leave a lane behind, even if this shell dies
	sudo bash -c "nohup sh -c 'sleep 900; tc qdisc del dev $IFACE root' >/dev/null 2>&1 &"
}

kill_group() { # pid — SIGKILL the whole process group in one pass (T6: atomicity)
	kill -KILL -"$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null || true
}

# -------------------------------------------------------------------- start ---
log "arm=$ARM inject=$INJECT secs=$SECS at=$AT rate=$RATE src=$(basename "$SRC")"

if [ "$ARM" = d ] && [ "$RATE" = auto ]; then
	echo "arm d needs an explicit RATE: an auto rate is measured per process, so the legs would lock different grids" >&2
	exit 2
fi

port_free "$PORT_A"
[ "$ARM" = c ] || port_free "$PORT_B"

RELAY_A=$(start_relay "$PORT_A" "$RUN/relayA.log"); track "$RELAY_A"
if [ "$ARM" != c ]; then
	RELAY_B=$(start_relay "$PORT_B" "$RUN/relayB.log"); track "$RELAY_B"
fi
sleep 2
relay_bound "$RUN/relayA.log"
[ "$ARM" = c ] || relay_bound "$RUN/relayB.log"

FIFO_A="$RUN/fifo_a"; mkfifo "$FIFO_A"
PUB_A=$(start_importer "$FIFO_A" "$PORT_A" "$RUN/pubA.log"); track "$PUB_A"
if [ "$ARM" != c ]; then
	FIFO_B="$RUN/fifo_b"; mkfifo "$FIFO_B"
	PUB_B=$(start_importer "$FIFO_B" "$PORT_B" "$RUN/pubB.log"); track "$PUB_B"
fi
sleep 1

# One source, fanned to both importers. Both readers are already attached, so both
# see byte 0; --output-error=warn keeps the survivor fed when one reader dies.
if [ "$ARM" = c ]; then
	setsid bash -c "tsp -I file '$SRC' --infinite -P regulate --pcr-synchronous -O file - \
		> '$FIFO_A'" >"$RUN/source.log" 2>&1 </dev/null &
else
	setsid bash -c "tsp -I file '$SRC' --infinite -P regulate --pcr-synchronous -O file - \
		| tee --output-error=warn '$FIFO_A' > '$FIFO_B'" >"$RUN/source.log" 2>&1 </dev/null &
fi
SOURCE=$!; track $SOURCE
sleep 1

if [ "$ARM" = c ]; then
	EG_A=$(start_dual_egress "$PORT_A" "$RUN/egressA.log"); track "$EG_A"
else
	EG_A=$(start_leg_egress "$PORT_A" "$RTP_A_PORT" "$RUN/egressA.log"); track "$EG_A"
	# A standby that joins mid-stream is the production shape: its egress numbers RTP
	# from its own start, so the pair can be content-identical yet sequence-shifted.
	[ "$DELAY_B" = 0 ] || { log "leg B egress joins ${DELAY_B}s late"; sleep "$DELAY_B"; }
	EG_B=$(start_leg_egress "$PORT_B" "$RTP_B_PORT" "$RUN/egressB.log"); track "$EG_B"
fi

log "settling ${SETTLE}s"
sleep "$SETTLE"

# ------------------------------------------------------------------ capture ---
CAP="$RUN/$LABEL.pcap"
sudo tcpdump -i "$IFACE" -n -s 0 -B 8192 -w "$CAP" \
	"udp and (dst port $RTP_A_PORT or dst port $RTP_B_PORT)" \
	>"$RUN/tcpdump.log" 2>&1 &
TCPDUMP=$!; track $TCPDUMP
sleep 1
CAP_T0=$(date +%s.%N)
log "capture started ($SECS s)"

# ---------------------------------------------------------------- injection ---
INJECT_T=""
HELD=0   # seconds the injection itself consumed, so the window still totals SECS
if [ "$INJECT" != none ]; then
	sleep "$AT"
	INJECT_T=$(date +%s.%N)
	log "injecting: $INJECT"
	case "$INJECT" in
	blackout)   netem_lane "$RTP_A_PORT" "loss 100%" ;;
	loss1)      netem_lane "$RTP_A_PORT" "loss 1%" ;;
	loss3)      netem_lane "$RTP_A_PORT" "loss 3%" ;;
	delay10)    netem_lane "$RTP_A_PORT" "delay 10ms" ;;
	delay50)    netem_lane "$RTP_A_PORT" "delay 50ms" ;;
	delay200)   netem_lane "$RTP_A_PORT" "delay 200ms" ;;
	quicloss)   netem_lane "$PORT_A" "loss 100%" ;;
	# Leg A's delivery stops and then comes back, with every process left alive:
	# the one shape that exercises a groomer muting and resuming, and the only way
	# to see whether a resumed leg re-enters the pair's RTP numbering or a new one.
	quicloss_recover)
		netem_lane "$PORT_A" "loss 100%"
		sleep "$RECOVER"
		tc_clear
		HELD=$RECOVER
		log "leg A delivery restored after ${RECOVER}s" ;;
	killpub)    kill_group "$PUB_A" ;;
	termpub)    kill -TERM -"$PUB_A" 2>/dev/null || kill -TERM "$PUB_A" ;;
	killrelay)  kill_group "$RELAY_A" ;;
	killegress) kill_group "$EG_A" ;;
	*) log "unknown injection $INJECT"; exit 2 ;;
	esac
	sleep $((SECS - AT - HELD))
else
	sleep "$SECS"
fi

# --------------------------------------------------------------------- stop ---
sudo kill -INT $TCPDUMP 2>/dev/null || true
sleep 1
tc_clear

# Stop the source first so the pipelines see EOF and the pacer prints its stats
# (dropped / underruns are how we tell a rig artefact from a real result).
kill_group "$SOURCE"
sleep 3

cat >"$RUN/meta.json" <<META
{
  "label": "$LABEL", "arm": "$ARM", "inject": "$INJECT",
  "secs": $SECS, "at": $AT, "rate": "$RATE", "ssrc": $SSRC,
  "leg_a_port": $RTP_A_PORT, "leg_b_port": $RTP_B_PORT,
  "capture_t0": ${CAP_T0:-0}, "inject_t": ${INJECT_T:-0}, "delay_b": $DELAY_B,
  "recover_after": $HELD, "seq_seed": $SEQ_SEED,
  "pacer_stall_ms": $PACER_STALL, "pacer_on_stall": "$PACER_ONSTALL",
  "source": "$(basename "$SRC")", "latency_max": "$LATENCY_MAX", "idle": "$IDLE"
}
META

log "capture: $(du -h "$CAP" | cut -f1)"
log "done -> $RUN"
