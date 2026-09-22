#!/usr/bin/env bash
# Build `moq` and `moq-relay` from a pinned upstream commit, on an EC2 host, with the QUIC
# backend stated explicitly rather than inherited.
#
#   ec2-build-main.sh <commit-sha> [jobs]
#
# The backend is no longer a choice. Upstream #3757 flipped the default from `quinn` to
# `noq`+`iroh`, and #3811 (`refactor(quic)!: keep only the noq backend`, 2026-09-21) deleted the
# quinn and quiche implementations outright — the `quinn` feature no longer exists, so a build
# asking for it fails with "does not contain this feature". From #3811 onward there is exactly
# one direct QUIC backend.
#
# That matters for attribution rather than for the build. This campaign's entire measurement
# history up to `5d0991b9` is on quinn, and `lab/test-8-srt-vs-moq.md` records that noq's BBRv3
# aborts the process under high loss — precisely the condition the outage ladders create. Every
# figure taken from a post-#3811 build is therefore a noq figure, and any comparison against an
# earlier one carries a backend change as well as the code change. State the backend with the
# build on any result that crosses #3811.
#
# Outputs (binaries are copied out of target/, so reclaiming the build tree is safe):
#   ~/bin-<short-sha>/{moq,moq-relay}   noq — the only backend, and the build under test
set -euo pipefail

PIN="${1:?commit sha}"
JOBS="${2:-$(nproc)}"
SRC="$HOME/moq-main"

echo "=== $(date -u) build $PIN with $JOBS jobs ==="

if ! command -v cargo >/dev/null 2>&1; then
	echo "--- installing rustup (minimal) ---"
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
		sh -s -- -y --profile minimal --no-modify-path
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

# `nvidia` is in moq-cli's default set and pulls CUDA in whenever anything reaches moq-video, so
# the feature list is stated rather than inherited here too — for reproducibility, not because the
# backend is still selectable.
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

build_pair noq "$HOME/bin-$SHORT"

echo "$PIN" >"$HOME/bin-$SHORT.sha"
echo "=== $(date -u) done: ~/bin-$SHORT (noq, under test) ==="
