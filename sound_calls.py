"""Catalogue sound-command call sites: python3 -P -E sound_calls.py <FS.X> <FS.asm>
For every jsr/jmp/bsr to $4ac (sound cmd) or $56c (fade), walk back to the last write of d0 and report it,
plus the enclosing task id (nearest task entry from the $b0e0 table at or below the call)."""
import sys, re, struct, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -P drops the script dir; it is trusted project code
from xload import load_x
x = load_x(sys.argv[1]); img = x['img']
tasks = sorted((struct.unpack('>I', img[0xb0e0+i*4:0xb0e4+i*4])[0], i) for i in range(46))
lines = []
for l in open(sys.argv[2]):
    m = re.match(r'([0-9a-f]{6}): (\S+)\s*(.*?)\s*(;.*)?$', l.rstrip('\n'))
    if m: lines.append((int(m[1], 16), m[2], m[3]))
tab = img[0x4ee:0x52e]
print('routing table $4ee (cmd -> $ff=trap#1 / n=trap#0 with n+$47(a6)):')
print(' '.join(f'{i:02x}:{"T1" if b==0xff else f"{b:02x}"}' for i, b in enumerate(tab)))
def owner(a):
    o = 'main'
    for ta, i in tasks:
        if ta <= a: o = f'task{i:02x}'
    return o
d0w = re.compile(r'(?:^|,\s*)d0$')
for k, (a, op, args) in enumerate(lines):
    if op in ('jsr', 'jmp', 'bsr.w', 'bsr.b') and re.match(r'\$(4ac|56c)(\.l)?$', args):
        tgt = args.split('.')[0]
        src = '?'; path = []
        for j in range(k-1, max(k-12, 0), -1):
            a2, op2, args2 = lines[j]
            path.append(f'{a2:x}:{op2} {args2}')
            if d0w.search(args2) and not op2.startswith(('cmp', 'tst', 'btst')):
                src = f'{op2} {args2}'; break
            if op2.startswith(('bra', 'rts', 'jmp')): src = '(after bra/rts)'; break
        print(f'{a:06x} {owner(a):7s} {tgt}  d0 <- {src}')
