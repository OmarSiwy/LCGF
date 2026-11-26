import sys,statistics as st,collections
d=collections.defaultdict(lambda: collections.defaultdict(list))
for l in open(sys.argv[1]):
    p=l.split(); ui,impl=p[1],p[2]
    for kv in p[3:]:
        k,v=kv.split('='); d[(ui,impl)][k].append(float(v))
print(f"{'ui':9}{'impl':8}{'ns med':>8}{'ns min':>8}{'ns max':>8}{'ins':>8}{'cyc':>8}{'br':>7}{'miss':>6}{'IPC':>6}")
for (ui,impl),m in d.items():
    md=lambda k: st.median(m[k])
    print(f"{ui:9}{impl:8}{md('ns'):8.0f}{min(m['ns']):8.0f}{max(m['ns']):8.0f}{md('ins'):8.0f}{md('cyc'):8.0f}{md('br'):7.0f}{md('miss'):6.1f}{md('ins')/md('cyc'):6.2f}")
