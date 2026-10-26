import json,collections
d=json.load(open('rows.json'))
def cmp(a,b,label):
    tot=0;out=[]
    for t in sorted(set(d[a])|set(d[b])):
        x=collections.Counter(d[a].get(t,[]));y=collections.Counter(d[b].get(t,[]))
        gone=list((x-y).elements());new=list((y-x).elements())
        if gone or new: out.append((t,gone,new));tot+=1
    print(f'== {label}: {len(set(d[a])|set(d[b]))} tables, {tot} differ')
    for t,g,n in out:
        print(f'  {t}: only-in-{a} {len(g)} · only-in-{b} {len(n)}  (cols: {d["cols"].get(t,"")[:120]})')
        for r in g[:6]: print(f'     - {r[:260]}')
        for r in n[:6]: print(f'     + {r[:260]}')
cmp('B1','L','backup 2026-10-26 14:53 vs live now')
cmp('B0','B1','backup 2026-10-23 15:20 vs backup 2026-10-26 14:53')
