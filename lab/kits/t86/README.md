# T86 kit: an MPEG-TS publisher and receiver through a MoQ relay

This kit reruns [T86](../../test-86-moq2ts-evaluation.md) on any build of OpenMOQ's `moq2ts`, and on `moq-dev`'s passthrough pair beside it, from synthetic inputs only. T86 ran most of its cells on recorded feeds, which cannot be shared, so the kit's inputs reproduce each recording's shape, not its bytes, and its figures are not T86's. Everything runs on one machine, over loopback.

## Requirements

ffmpeg with libx264, TSDuck (3.45 or later) and Python 3; `moq2ts-cli` and `moq2ts-receiver` built headless; `moq-relay` and `moq` from `moq-dev` (the relay serves both arms). About 2.5 GB for the inputs and 1.5 GB a cell for the outputs. macOS or Linux.

Build these as the kit was run:

- **`moq-relay` and `moq`** at `moq-dev` `b45179d39b` (`moq-relay` 0.17.2): `cargo build --release --bin moq --bin moq-relay`. An older relay, such as 0.17.1, ends every draft-22 session of `moq2ts-receiver` with `trailing bytes` and rejects `--quic-congestion-control bbr`.
- **`moq2ts-cli`** on the `moqxr` release SDK that `moq2ts` pins (`MOQXR_VERSION` in its `.github/workflows/build.yml`), passed as `-DMOQXR_SDK_DIR`.
- **`moq2ts-receiver`** on an installed moq5 `main`, built with its pinned and patched picoquic and the threaded picoquic adapter. Without that adapter `moq_endpoint_connect` returns "not supported by this build".

```bash
cd moq5 && eval "$(scripts/setup_picoquic_deps.sh)"   # clones picoquic and picotls, applies moq5's patches
cmake -S . -B build/svc -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=<moq5-install> \
  -DMOQ_BUILD_SERVICE=ON -DMOQ_BUILD_MSF=ON -DMOQ_BUILD_MPEG2TS=ON -DMOQ_BUILD_ADAPTER_PICOQUIC=ON \
  -DMOQ_BUILD_PQ_THREADED=ON -DMOQ_PICOQUIC_SOURCE_DIR="$MOQ_PICOQUIC_SOURCE_DIR" -DMOQ_PICOTLS_PREFIX="$MOQ_PICOTLS_PREFIX"
cmake --build build/svc --parallel && cmake --install build/svc
cd ../moq2ts && cmake -S src/receive -B build-receiver -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<moq5-install> \
  -DMOQ_PICOQUIC_SOURCE_DIR="$MOQ_PICOQUIC_SOURCE_DIR" -DMOQ_PICOTLS_PREFIX="$MOQ_PICOTLS_PREFIX"
cmake --build build-receiver --parallel --target moq2ts-receiver
```

On macOS, set `OPENSSL_ROOT_DIR` (Homebrew's `openssl@3`) before `setup_picoquic_deps.sh`.

## Running

```bash
bash lab/kits/t86/make-fixtures.sh fx          # once, about five minutes
export MOQ=<dir with moq and moq-relay> CLI=<moq2ts-cli> RECV=<moq2ts-receiver>
bash lab/kits/t86/run.sh fx out <cell> A       # A: moq2ts, draft 22; M: moq-dev, moq-lite-07
bash lab/kits/t86/grade.sh fx out <cell> A
```

`make-fixtures.sh` lists each input, prints its continuity events and PCR check, and writes their hashes. A cell takes 4–15 minutes; all six about 45 per arm. Two arms may run at once with `PORT` set apart by 200.

## Cells and pass rules

Each rule is T86's for that cell, shortened; the section linked holds the full criteria and what was found.

| Cell | Inputs | Passes when |
| --- | --- | --- |
| `r`, conformance ([P2-r](../../test-86-moq2ts-evaluation.md#p2-r--output-conformance)) | `base.ts` (10 Mb/s), `live.ts` (25 Mb/s) | each output is its input's bytes from the join to the end (`whole`), with the input's continuity and PCR verdict |
| `s`, PCR events ([P2-s](../../test-86-moq2ts-evaluation.md#p2-s--pcr-discontinuities)) | `s-A` … `s-F`, `switch-back`, `switch-forward` | each output is whole; its longest read gap is no longer than the control's (`s-F`) by more than one object |
| `t`, restarts ([P2-t](../../test-86-moq2ts-evaluation.md#p2-t--restarts-and-loop-wraps)) | `base.ts` with the publisher, relay or receiver killed 60 s in; `loop.ts` | the control and the loop cell have no gap (`to_end` stays false: each output stops short by the partial object its publisher holds when the input ends); after a kill the pair resumes by itself and the programme lost is reported |
| `u`, loss ([P2-u](../../test-86-moq2ts-evaluation.md#p2-u--loss-on-the-path-and-a-late-join)) | `base.ts`'s first 60 s at 0, 1 and 3 % loss | 0 and 1 % are whole; at 3 % the programme lost is reported, against the other arm's |
| `v`, three programmes ([P2-v](../../test-86-moq2ts-evaluation.md#p2-v--multi-programme-streams)) | `mpts3.ts` (independent clocks), `mpts3-cc.ts` (one clock) | U: whole, every programme CARRIED with its PMT bit-identical; P: every programme CARRIED, its video at least 95 % of the input's packets (a 3 s join) |
| `w`, the live feed's shape ([P2-w](../../test-86-moq2ts-evaluation.md#p2-w--the-live-feed)) | `live.ts`; `live-splice.ts`, an unflagged splice to a clock 16,844.5 s behind | both whole; no unit missing, altered or added, the splice included |

In `grade.sh`'s table, `whole` requires no continuity error in the output, and `max gap ms` leaves out the final read, which only delivers the publisher's held last object; `last read ms` reports that read's wait. The inputs of `s`, `t`'s loop and `w`'s splice carry their own continuity breaks, so judge those rows on `lost s` and `gaps`, which compare bytes with the input.

## What the scripts are

`run.sh` and `grade.sh` dispatch each cell to T86's rigs and graders in [`../../scripts`](../../scripts): [`t86-loss.sh`](../../scripts/t86-loss.sh) (one live pair, with a UDP proxy on the receiver's hop that adds loss and delay), [`t86-restart.sh`](../../scripts/t86-restart.sh), [`t86-mpts.sh`](../../scripts/t86-mpts.sh); [`t86-loss-grade.py`](../../scripts/t86-loss-grade.py), [`t86-units-grade.py`](../../scripts/t86-units-grade.py), [`t86-restart-grade.py`](../../scripts/t86-restart-grade.py), [`ts-passthrough-identity.py`](../../scripts/ts-passthrough-identity.py) and [`t10-grade.py`](../../scripts/t10-grade.py). The inputs come from [`t23-pcr-stimuli.py`](../../scripts/t23-pcr-stimuli.py), [`t64-switch.py`](../../scripts/t64-switch.py), [`make-real-mpts.sh`](../../scripts/make-real-mpts.sh) and [`ts-add-tdt.py`](ts-add-tdt.py), which gives programme 1 the TDT its EIT is scheduled from; [`ts-dts-lead.py`](ts-dts-lead.py) checks that no programme's timestamps fall behind its PCR, which a receiver that follows the clock would rightly refuse.
