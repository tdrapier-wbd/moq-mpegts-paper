#!/usr/bin/env bash
# Build the isolating pair around upstream #3271, on the EC2 primary.
#
# Why a pair rather than the newest release: the first attempt at this A/B used
# two binaries already on the box (0.9.11-eab96019 against the 0.9.15 release)
# and that comparison is void, because #3006 ("pace the TS stdout export on
# each frame's timestamp") also lands between them. C3's instrument is bytes
# delivered inside a fixed 90 s window, and #3006 changes when bytes leave the
# exporter — so it changes the instrument, not just the subject. The pre arm
# drains on arrival and the post arm paces to media time, which is enough on
# its own to move a windowed byte count.
#
#   pre   8206a35a6  (#3289, the commit immediately before)
#   post  bec7c4b59  (#3271's merge)
#
# The two differ by one file, rs/moq-mux/src/container/consumer.rs, and both
# already carry #3006, #2967 and everything else in the delivery path. So the
# group-delivery gate is the only thing that varies.
#
# Only `moq` is built: #3271 is client-side, and holding one relay binary
# across both arms is what makes the result attributable to the client.
#
# 2 vCPU and no swap after the last reboot, so swap is recreated first (the box
# has needed it for a cargo build before) and cargo is held to two nice'd jobs
# so the standing relay keeps serving.
set -euo pipefail

REPO=${REPO:-$HOME/moq-main}
PRE_SHA=${PRE_SHA:-8206a35a6}
POST_SHA=${POST_SHA:-bec7c4b594927ef4d392168018161dd6b0f287c7}
SWAP=/swap.t12swap

echo "=== $(date -u +%FT%TZ) start ==="

if ! swapon --show | grep -q "$SWAP"; then
	if [ ! -f "$SWAP" ]; then
		sudo fallocate -l 2G "$SWAP"
		sudo chmod 600 "$SWAP"
		sudo mkswap "$SWAP" >/dev/null
	fi
	sudo swapon "$SWAP"
	echo "swap on: $(swapon --show | tail -1)"
fi

cd "$REPO"
echo "=== remote ==="
git remote -v | head -2
git fetch --quiet origin main
for s in "$PRE_SHA" "$POST_SHA"; do
	git cat-file -e "$s^{commit}" || {
		echo "commit not present after fetch: $s" >&2
		exit 1
	}
done

# Assert the pair really is a before/after of one file, on the box, rather than
# on trust from the laptop.
echo "=== isolating diff ==="
git diff --stat "$PRE_SHA" "$POST_SHA" | tail -3

source "$HOME/.cargo/env"
build() {
	local sha=$1 out=$2
	echo "=== $(date -u +%FT%TZ) building $out from $sha ==="
	git checkout --quiet --detach "$sha"
	nice -n 19 cargo build --release --bin moq --jobs 2 2>&1 | tail -3
	mkdir -p "$HOME/$out"
	# Copy out of target/ immediately: the next arm's build overwrites it.
	cp target/release/moq "$HOME/$out/moq"
	echo "$out: $("$HOME/$out/moq" --version 2>&1 | head -1)"
	df -h / | tail -1
}

build "$PRE_SHA" bin-3271pre
build "$POST_SHA" bin-3271post

echo "=== $(date -u +%FT%TZ) done ==="
ls -l "$HOME/bin-3271pre/moq" "$HOME/bin-3271post/moq"
# The two arms must differ; an identical checksum means a checkout or copy
# silently did nothing and the whole A/B would read as a clean null.
md5sum "$HOME/bin-3271pre/moq" "$HOME/bin-3271post/moq"
