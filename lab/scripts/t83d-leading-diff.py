#!/usr/bin/env python3
"""Which video PES a build drops against a good build, and whether each is an open-GOP leading
picture (presents before the random-access picture that precedes it in decode order).

usage: t83d-leading-diff.py <good out.ts> <bad out.ts>   (video PID 0x6f, T34's capture)
"""
import sys
def pes(path, pid=0x6f):
    d=open(path,'rb').read(); out=[]
    for i in range(0,len(d)-187,188):
        p=d[i:i+188]
        if p[0]!=0x47 or not p[1]&0x40 or ((p[1]&0x1f)<<8|p[2])!=pid: continue
        af=p[3]&0x20; rai=af and p[4]>0 and bool(p[5]&0x40)
        s=4+(1+p[4] if af else 0); h=p[s:]
        if h[:3]!=b'\0\0\1': continue
        f=h[7]
        ts=lambda b:((b[0]>>1)&7)<<30|b[1]<<22|(b[2]>>1)<<15|b[3]<<7|b[4]>>1
        pts=ts(h[9:14]) if f&0x80 else None
        dts=ts(h[14:19]) if f&0x40 else pts
        out.append((dts,pts,rai))
    return out
g=pes(sys.argv[1]); m=pes(sys.argv[2])
mp={x[1] for x in m}
common=[x for x in g if x[1] in mp]
lo,hi=common[0][0],common[-1][0]
gw=[x for x in g if lo<=x[0]<=hi]
miss=[x for x in gw if x[1] not in mp]
print(f"good {len(g)} main {len(m)}; in common span good {len(gw)}, missing {len(miss)}; extra in main {len([x for x in m if x[1] not in {y[1] for y in g}])}")
rais=[x for x in gw if x[2]]
lead=0; rows=[]
for x in miss:
    prev=[r for r in rais if r[0]<x[0]]
    r=prev[-1] if prev else None
    if r and x[1]<r[1]: lead+=1
    rows.append((x, r))
print(f"missing that display before the preceding RAP (leading pictures): {lead}/{len(miss)}")
for x,r in rows[:14]:
    print(f"miss dts {x[0]/90:.0f} pts {x[1]/90:.0f} ms | rap dts {r[0]/90:.0f} pts {r[1]/90:.0f}" if r else x)
# per-RAP: how many leading pictures exist in good, and how many missing
import collections
tot=collections.Counter(); ms=collections.Counter()
for x in gw:
    prev=[r for r in rais if r[0]<=x[0]]
    if prev and x is not prev[-1] and x[1]<prev[-1][1]: tot[prev[-1][0]]+=1
for x,r in rows:
    if r and x[1]<r[1]: ms[r[0]]+=1
print("raps", len(rais), "leading pics per rap (good)", sorted(collections.Counter(tot.values()).items()), "missing per rap", sorted(collections.Counter(ms.values()).items()))
