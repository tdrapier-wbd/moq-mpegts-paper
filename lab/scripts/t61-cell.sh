#!/usr/bin/env bash
# One T61 cell from the workstation (lab/test-61-origin-group-failover.md): t59-cell.sh with both
# legs on the origin group, aligned, then the receivers' logs and both origins' access logs for the
# cell's span, and t61-report.py over them.
#
#   t61-cell.sh CELL [SECONDS]     CELL: clean seg-kill seg-freeze origin-down ngx-hang block

set -uo pipefail
CELL=${1:?usage: t61-cell.sh CELL [SECONDS]}
SECS=${2:-300}
H=$(cd "$(dirname "$0")" && pwd)
P59_HOME=${P59_HOME:-$HOME/p59-local}
t0=$(date +%s)
LEG_PATH=g ALIGN_MS=30000 SETTLE=60 PACER=${PACER:-/home/ubuntu/pacer-2eea651/mpegts-pacer} \
	bash "$H/t59-cell.sh" "$CELL" "$SECS" | tee /tmp/t61-cell.out
run=$(sed -n 's/^cell .* run //p' /tmp/t61-cell.out)
local_dir=$P59_HOME/runs/$(basename "$run")
t1=$(date +%s)
scp -q "moq-tertiary:$run/b8-a.jsonl" "moq-tertiary:$run/b8-b.jsonl" "$local_dir/"
for o in a b; do
	h=moq-primary
	[ $o = b ] && h=moq-secondary
	ssh -o BatchMode=yes "$h" "awk -v a=$t0 -v b=$t1 '\$1 >= a && \$1 <= b' ~/p59/ngx/access.log" >"$local_dir/access-$o.log"
done
python3 "$H/t61-report.py" "$local_dir" | tee "$local_dir/report.json"
