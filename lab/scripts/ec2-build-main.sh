#!/usr/bin/env bash
# Build `moq` and `moq-relay` from a pinned upstream commit, on an EC2 host, with the QUIC
# backend stated explicitly rather than inherited.
#
#   ec2-build-main.sh <commit-sha> [jobs]
#
# Why the backend is pinned. Upstream #3757 flipped moq-cli's and moq-relay's default feature
# set from `quinn` to `noq`+`iroh`, so from that commit a plain `cargo build --release` changes
# the QUIC stack underneath every measurement. This campaign's entire history is on quinn, and
# `lab/test-8-srt-vs-moq.md` records that noq's BBRv3 aborts the process under high loss — which
# is exactly the condition the outage ladders create. Taking 72 commits of change and a backend
# swap in one step would leave any regression unattributable, so this builds the quinn pair as
# the primary artefact and a noq pair alongside it, letting the backend become its own A/B
# whenever we choose to grade it rather than a confound we absorbed silently.
#
# Outputs (binaries are copied out of target/, so reclaiming the build tree is safe):
#   ~/bin-<short-sha>/{moq,moq-relay}       quinn  — the build under test
#   ~/bin-<short-sha>-noq/{moq,moq-relay}   noq    — for grading #3757 itself
set -euo pipefail

PIN="${1:?commit sha}"
JOBS="${2:-$(nproc)}"
SRC="$HOME/moq-main"

echo "=== $(date -u) build $PIN with $JOBS jobs ==="

if ! command -v cargo >/dev/null 2>&1; then
	echo "--- installing rustup (minimal) ---"
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
		| sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
cargo --version

if [ ! -d "$SRC/.git" ]; then
	echo "--- cloning ---"
	git clone --filter=blob:none --no-checkout https://github.com/moq-dev/moq "$SRC"
fi
cd "$SRC"
git fetch -q origin main
git checkout -q --detach "$PIN"
SHORT=$(git rev-parse --short "$PIN")
echo "HEAD: $(git log --oneline -1)"

build_pair() {
	local backend="$1" outdir="$2"
	echo "--- building $backend -> $outdir ---"
	nice -n 19 cargo build --release --jobs "$JOBS" -p moq-cli --bin moq \
		--no-default-features --features "$backend,websocket"
	nice -n 19 cargo build --release --jobs "$JOBS" -p moq-relay --bin moq-relay \
		--no-default-features --features "$backend,websocket,uds"
	mkdir -p "$outdir"
	cp target/release/moq target/release/moq-relay "$outdir/"
	"$outdir/moq" --version
	"$outdir/moq-relay" --version
}

build_pair quinn "$HOME/bin-$SHORT"
build_pair noq "$HOME/bin-$SHORT-noq"

echo "$PIN" >"$HOME/bin-$SHORT.sha"
echo "=== $(date -u) done: ~/bin-$SHORT (quinn, under test) and ~/bin-$SHORT-noq ==="
