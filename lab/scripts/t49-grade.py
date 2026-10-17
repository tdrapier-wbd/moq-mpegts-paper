#!/usr/bin/env python3
"""Grade a t49-closed-origin-edge.sh run: t49-grade.py <run dir> [path to ts-pair-diff.py].

Prints one line per criterion's measurement; the verdicts are read against the criteria in
lab/test-49-closed-origin-edge.md.
"""
import os
import subprocess
import sys

run = sys.argv[1]
pair_diff = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), 'ts-pair-diff.py')

events, exits = {}, {}
for line in open(os.path.join(run, 'events.txt')):
    t, name, *rest = line.split()
    if name.startswith('exit-'):
        exits[name[5:]] = (float(t), rest[0] if rest else '?')
    else:
        events[name] = float(t)
t0 = events['start']

cols = ['origin', 'r1', 'r2', 'r3']
sizes = []
for line in open(os.path.join(run, 'sizes.txt')):
    f = line.split()
    if len(f) == 5:
        sizes.append((float(f[0]), *map(int, f[1:])))


def last_growth(col, before=None):
    i = cols.index(col) + 1
    last = None
    for a, b in zip(sizes, sizes[1:]):
        if before is not None and b[0] > before:
            break
        if b[i] > a[i]:
            last = b[0]
    return last


def grows_between(col, lo, hi):
    i = cols.index(col) + 1
    inside = [s[i] for s in sizes if lo <= s[0] <= hi]
    return len(inside) > 1 and inside[-1] > inside[0]


def size(name):
    p = os.path.join(run, 'cap', name + '.ts')
    return os.path.getsize(p) if os.path.exists(p) else 0


def cc_errors(name):
    p = os.path.join(run, 'cap', name + '.ts')
    out = subprocess.run(['tsp', '-I', 'file', p, '-P', 'continuity', '-O', 'drop'],
                         capture_output=True, text=True)
    return len([ln for ln in (out.stdout + out.stderr).splitlines() if 'continuity' in ln.lower()])


def rel(t):
    return f'{t - t0:6.2f} s' if t is not None else '   never'


print('exits (relative to start):')
for k, (t, rc) in sorted(exits.items(), key=lambda kv: kv[1][0]):
    print(f'  {k:<10} rc={rc:<4} at {rel(t)}')
print()
print('arm 1  anonymous publisher:', exits.get('anonpub', 'still connected'),
      '| authorised probe of its broadcast, bytes:', size('o_probe_x'),
      '| anonymous subscriber, bytes:', size('o_anon'))
print('arm 2  wrong-path publisher:', exits.get('wrongpub', 'still connected'),
      '| authorised probe of the broadcast it tried, bytes:', size('o_probe_a'),
      '| wrong-token subscriber, bytes:', size('o_wrong'))
print('arm 3  bytes origin', size('origin'), 'r1', size('r1'), '| CC errors origin', cc_errors('origin'),
      'r1', cc_errors('r1'))
diff = subprocess.run([sys.executable, pair_diff, os.path.join(run, 'cap/origin.ts'), os.path.join(run, 'cap/r1.ts'),
                       '--window=100000000'], capture_output=True, text=True).stdout
for ln in diff.splitlines():
    if any(k in ln for k in ('aligned', 'compared', 'identical:', 'differing', '    ', 'VERDICT')):
        print('       ', ln.strip())
pes = subprocess.run([sys.executable, os.path.join(os.path.dirname(pair_diff), 'ts-pes-compare.py'),
                      os.path.join(run, 'cap/origin.ts'), os.path.join(run, 'cap/r1.ts')], capture_output=True, text=True)
print('       ', pes.stdout.strip())
print('arm 4  edge anon bytes:', size('e_anon'), '| edge wrong-broadcast bytes:', size('e_wrong'))
d5 = events['arm5-r2-key-deleted']
l5 = last_growth('r2')
print(f'arm 5  r2 last byte {l5 - d5:+.2f} s after its key was deleted' if l5 else 'arm 5  r2 never grew',
      '| r1 grows after:', grows_between('r1', d5 + 7, d5 + 14))
a6, b6 = events['arm6-origin-auth-stopped'], events['arm6-origin-auth-restarted']
print('arm 6  publisher exit:', exits.get('publisher', 'none (alive at end)'),
      '| r1 grows through the outage:', grows_between('r1', a6, b6), '| origin grows:', grows_between('origin', a6, b6))
d7, r7 = events['arm7-edge-key-deleted'], events['arm7-edge-key-restored']
l7 = last_growth('r1', before=r7)
print(f'arm 7  r1 last byte {l7 - d7:+.2f} s after the edge key was deleted' if l7 else 'arm 7  r1 never grew',
      '| origin grows after:', grows_between('origin', d7 + 7, r7), '| r3 (after restore) bytes:', size('r3'))
