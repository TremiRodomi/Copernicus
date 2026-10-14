"""Linear M68K disassembly of a Human68k .X: python3 -P -E disasm.py <FS.X> <out.asm>
Knows two kinds of inline data so the linear sweep doesn't desync:
  - `bsr/jsr $930` (print routine) is followed by a NUL-terminated string padded to even -> `dc.b "...",0`
  - `move.w T(pc,dN.w),dN ; jmp T(pc,dN.w)` -> table of word offsets at T, ending at the lowest target -> `dc.w ... ; jtab -> $addr`
"""
import os, sys, struct, re, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -P drops the script dir; it is trusted project code
from capstone import *
from xload import load_x

PRINT_INLINE = 0x930
# pointer tables (data addr, count) whose targets are `dc.w <sprite code>` followed by code (task 15 bonus-item effect handlers)
WORD_PREFIXED_TABLES = [(0xc90e, 18)]

x = load_x(sys.argv[1]); img = x['img']; text = x['text']
md = Cs(CS_ARCH_M68K, CS_MODE_BIG_ENDIAN | CS_MODE_M68K_000)
out = []; pc = 0
relset = set(x['relocs'])
# every relocated pointer into text is an instruction start: never let an instruction straddle one
starts = {struct.unpack('>I', img[r:r+4])[0] for r in x['relocs']}
starts = {t for t in starts if t < text}
dataword = set()
for tab, n in WORD_PREFIXED_TABLES:
    for k in range(n):
        t = struct.unpack('>I', img[tab + 4*k:tab + 4*k + 4])[0]
        dataword.add(t); starts.discard(t); starts.add(t + 2)
prev = None
def strlit(b):
    s = ''.join(chr(c) if 32 <= c < 127 and c != 34 else '\\x%02x' % c for c in b)
    return '"%s",0' % s
while pc < text:
    g = list(md.disasm(img[pc:pc+10], pc, 1))
    if g and any(pc < b < pc + g[0].size for b in starts): g = []
    if not g or pc & 1 or pc in dataword:
        w = struct.unpack('>H', img[pc:pc+2])[0]
        out.append((pc, 2, 'dc.w', '$%04x' % w)); pc += 2; prev = None
        continue
    i = g[0]; out.append((pc, i.size, i.mnemonic, i.op_str)); pc += i.size
    if i.mnemonic in ('bsr.w', 'bsr.b', 'jsr') and re.fullmatch(r'\$%x(\.l)?' % PRINT_INLINE, i.op_str):
        end = img.index(0, pc, text)
        out.append((pc, end + 1 - pc, 'dc.b', strlit(img[pc:end])))
        pc = (end + 2) & ~1
    m = re.fullmatch(r'\$([0-9a-f]+)\(pc, (d\d)\.w\)', i.op_str)
    if i.mnemonic == 'jmp' and m and prev and prev.mnemonic == 'move.w' and prev.op_str.startswith(m[0]):
        t = int(m[1], 16)
        if t == pc:
            offs = []; lo = None
            while lo is None or t + 2 * len(offs) < lo:
                o = struct.unpack('>h', img[t + 2*len(offs):t + 2*len(offs) + 2])[0]
                offs.append(o); lo = min(lo or 1 << 30, t + o)
                if t + o <= t or len(offs) > 256: break
            for k, o in enumerate(offs):
                out.append((t + 2*k, 2, 'dc.w', '$%04x  ; jtab[%d] -> $%x' % (o & 0xffff, k, t + o)))
            pc = t + 2 * len(offs)
    prev = i
with open(sys.argv[2], 'w') as f:
    for pc, sz, m, o in out:
        f.write("%06x: %-12s %s%s\n" % (pc, m, o, "   ; reloc" if any((pc+k) in relset for k in range(sz)) else ""))
print(len(out), "insns; dc.w:", sum(1 for o in out if o[2] == 'dc.w'), "strings:", sum(1 for o in out if o[2] == 'dc.b'))
c = collections.Counter()
for pc, sz, m, o in out:
    if m == 'dc.w' and o.startswith('$ff'): c['DOS ' + o]+=1
    if m == 'trap': c['trap ' + o] += 1
print(c.most_common(40))
