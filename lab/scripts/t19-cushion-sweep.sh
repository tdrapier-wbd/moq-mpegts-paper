#!/usr/bin/env bash
#
# T19: how deep does the downstream groomer have to buffer before the
# media-aware export grooms into a conformant CBR wire?
#
#   t19-cushion-sweep.sh <pacer> <export.ts> <out-dir> <rate_bps> [cushion_ms ...]
#
# `export.ts` is a capture of `moq export ts` — the media-aware representation,
# with the source's original CBR byte schedule already gone. It is replayed at
# its own PCR rate (`tsp -P regulate --pcr-synchronous`) so the groomer sees the
# arrival pattern rather than a file, then groomed at `rate_bps` at each cushion
# in turn. One line of TSV per arm on stdout; the graded wire of each arm is kept
# so a failing one can be re-examined without re-running the sweep.
#
# The pacer is a parameter rather than a path because the point of the sweep is
# to compare two of them: run it once per binary into the same directory with
# different labels via OUT_PREFIX.
set -u

PACER=$1
IN=$2
DIR=$3
RATE=${4:-11000000}
shift 4 || shift $#
CUSHIONS=${*:-250 500 800 1000 1500 2000}
PREFIX=${OUT_PREFIX:-arm}

mkdir -p "$DIR"

# TSV header. `placed` is what reached the slot map, so conservation is measured
# against what the groomer was actually offered rather than against the file: a
# leg that joins a replay already running is behind it by construction, and
# counting that join backlog as programme loss would grade the rig.
printf 'cushion_ms\tin_placed\tout_content\tconserved_pct\tlate_drops\tover_drops\tcc_errors\t'
printf 'stuffing_pct\tbitrate\tpcr_n\tpcr_over40_pct\tpcr_worst_ms\tpcr_jitter_fail\t'
printf 'underruns\tresyncs\tbuf_high_water\tpcr_inserted\n'

for cushion in $CUSHIONS; do
	out="$DIR/${PREFIX}${cushion}.ts"
	err="${out%.ts}.err"
	tsp -I file "$IN" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		"$PACER" - "$RATE" --stream-clock --max-latency-ms "$cushion" >"$out" 2>"$err"

	stats=$(grep -E 'done\.' "$err")
	field() { echo "$stats" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
	content=$(field content)
	late=$(field late_drops)
	over=$(field dropped)
	underruns=$(field underruns)
	resyncs=$(field resyncs)
	inserted=$(field pcr_inserted)
	# buffer_high_water is on the periodic report line, not the summary.
	high=$(sed -n 's/.*buffer_high_water=\([0-9]*\).*/\1/p' "$err" | sort -n | tail -1)
	nulls=$(field null)
	outp=$(field output_packets)
	placed=$((content + late + over))

	cc=$(tsp -I file "$out" -P continuity -O drop 2>&1 | grep -c 'TS:')
	tsp -I file "$out" -P pcrextract --pcr --csv -o "${out%.ts}.csv" -O drop >/dev/null 2>&1
	pcr=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;n++;if(d>m)m=d;if(d>40)o++}p=c}
		END{if(n)printf "%d\t%.2f\t%.1f",n,o/n*100,m; else printf "0\t0.00\t0.0"}' "${out%.ts}.csv")
	rate_out=$(tsp -I file "$out" -P analyze --normalized -O drop 2>/dev/null |
		grep '^ts:' | tr ':' '\n' | sed -n 's/^bitrate=//p' | head -1)
	# TR 101 290 PCR accuracy: +/-500 ns is 13 27 MHz ticks. The rate is stated
	# rather than left to TSDuck's estimate, which is itself derived from the PCRs
	# under test: on an arm that has shed most of its content the estimate lands
	# tens of kb/s off nominal and every PCR then fails against it, which reads as
	# a PCR defect and is a bitrate-estimate artefact.
	jit=$(tsp -I file "$out" -P pcrverify --absolute --jitter-max 13 --bitrate "$RATE" -O drop 2>&1 |
		sed -n 's/.*OK, \([0-9,]*\) with jitter.*/\1/p' | tr -d ,)

	printf '%s\t%s\t%s\t%.2f\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$cushion" "$placed" "$content" \
		"$(awk -v c="$content" -v p="$placed" 'BEGIN{print p?c/p*100:0}')" \
		"$late" "$over" "$cc" \
		"$(awk -v n="$nulls" -v o="$outp" 'BEGIN{print o?n/o*100:0}')" \
		"$rate_out" "$pcr" "${jit:-0}" "$underruns" "$resyncs" "${high:-0}" "$inserted"
done
