# Test 75 — RIST against SRT on the long path

**State: specified, not run.** Rig: [T71](test-71-long-lossy-path.md)'s 116 ms path with
[T73](test-73-long-path-budget-burst.md)'s 2 s budget and [T74](test-74-time-correlated-burst-loss.md)'s
time-based bursts, a RIST lane added beside SRT.

## Objective

[Evidence](evidence.md) §5 row 12: does RIST beat SRT on a real path? Both are retransmitting
packet tunnels that hand on the source's bytes ([T15](test-15-point-to-point-cadence.md)), and on
loopback and a 12.8 ms path nothing has separated them. A 116 ms path is where their recovery
designs (SRT's ARQ with a latency window, RIST's NACK-based retransmission within its buffer) could
differ in programme lost at one budget.

**Falsifies:** the comparison's treatment of SRT and RIST as interchangeable tunnels
([Comparison](../docs/comparison.md) §10.1), in either direction.

## Environment

As [T74](test-74-time-correlated-burst-loss.md#environment), with a RIST lane: on the origin
`tsp -O rist --buffer-size <ms> rist://@0.0.0.0:9712` (TSDuck 3.44-4676, main profile, the sender
listening), on the far host `tsp -I rist --buffer-size <ms> rist://<origin>:9712`, its UDP port among
the impaired flows. The buffer is the lane's budget, as SRT's `--latency`.

## Procedure

Per round, at the 2 s budget: RIST under {clean, 1 % random, T73's `ge:0.05,5`, T74's time bursts
on the round's seed}, SRT under {1 %, `ge:0.05,5`}; T74's SRT cells on the same seeds complete the
clean and time-burst pairs. Then RIST and SRT at 1 % at the 1 s budget, the pair's order alternated.
Three rounds, 24 cells of 120 s.

```bash
# laptop
ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> bash lab/scripts/t74-drive.sh t75 120
# receiver, after the matrix
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane rist|srt
```

## Pass criteria, fixed before running

1. **Path and clock**, as T73's criteria 1–2; each time-burst cell as T74's criterion 1.
2. **Carriage.** Every clean RIST cell byte-identical to the clip over its window and P1/P2-clean,
   as SRT's are; otherwise the lane is fixed before any impaired cell is read.
3. **Delivered programme**, as T73's criterion 5, per cell.
4. **The comparison**, per condition and budget: one tunnel *beats* the other where it is whole in
   all three replicates and the other loses programme in at least one. Both whole in all three, or
   both losing in at least one, is *not separated*. Latency is reported per lane, not ranked: each
   lane's budget is set alike, not matched on measured latency.

*Predicted.* Not separated anywhere: at 2 s both whole under every condition, as SRT is in T73; at
1 s at 1 % both whole, as SRT is in T71, since a 1 s buffer holds about eight round trips.

## Limits, stated in advance

- One path, one clip, 120 s cells, three replicates; TSDuck's RIST plugins only, at their defaults
  beyond the buffer, main profile.
- netem's models, the time bursts included: exogenous loss on a path that is otherwise clean.
- Each tunnel's budget is its own window setting; neither is tuned past it.
