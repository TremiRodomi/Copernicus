# Diff of the sprite slots $4c-$58 (Horned) logged by play.lua (PLAY_SPR) and the port (--sprlog), aligned like
# trace_diff.py: the first row where slot 0's state is $20 in each objlog, the port shifted by <port frame offset>.
# spr_diff.py <mame trace> <port objlog> <mame spr> <port spr> <port frame offset> [lines to print]
import sys
def anchor(path, mame):
    for i, l in enumerate(open(path)):
        s = l.split()[5] if mame else l.split()[4]
        st = s[0x21 * 2:0x21 * 2 + 2] if mame else s[:2]
        if st == '20': return i
def rows(path):
    return [l.split()[1] for l in open(path)]
da, dp = anchor(sys.argv[1], True), anchor(sys.argv[2], False) + int(sys.argv[5])
a, p = rows(sys.argv[3]), rows(sys.argv[4])
show = int(sys.argv[6]) if len(sys.argv) > 6 else 10
bad = seen = 0
first = None
for i in range(da, len(a)):
    j = i - da + dp
    if j < 0 or j >= len(p): continue
    if a[i] != '0' * 32 or p[j] != '0' * 32: seen += 1
    if first is None and a[i] != '0' * 32: first = i - da
    if a[i] != p[j]:
        bad += 1
        if bad <= show: print(f'+{i - da}: mame {a[i]} port {p[j]}')
print(f'sprites $4c-$58: {bad} differing frames of {min(len(a) - da, len(p) - dp)}; {seen} with a sprite; first MAME sprite at +{first}')
