"""Small Z80 disassembler for the arcade main CPU (cpu-a45.15/.16/.17 concatenated = $0000-$BFFF).
Usage: z80dis.py <romdir> <out.asm> [start end ...]   (hex ranges; default: whole ROM, linear)
Decoding follows the standard x/y/z/p/q opcode decomposition. RST $30 is the game's yield (A = frames), RST $08 spawn,
RST $18 kill-others (see NOTES.md); they are annotated."""
import sys, os

R = ['b', 'c', 'd', 'e', 'h', 'l', '(hl)', 'a']
RP = ['bc', 'de', 'hl', 'sp']
RP2 = ['bc', 'de', 'hl', 'af']
CC = ['nz', 'z', 'nc', 'c', 'po', 'pe', 'p', 'm']
ALU = ['add a,', 'adc a,', 'sub ', 'sbc a,', 'and ', 'xor ', 'or ', 'cp ']
ROT = ['rlc', 'rrc', 'rl', 'rr', 'sla', 'sra', 'sll', 'srl']
RST_NOTE = {0x08: 'spawn task A', 0x10: 'kill task A', 0x18: 'kill other tasks', 0x30: 'yield A frames'}


def load(romdir):
    return b''.join(open(os.path.join(romdir, f), 'rb').read() for f in ('cpu-a45.15', 'cpu-a45.16', 'cpu-a45.17'))


def dis(m, pc):
    """Return (length, text) for the instruction at pc."""
    start = pc
    b = lambda: m[pc] if pc < len(m) else 0
    def n():
        nonlocal pc
        v = m[pc] if pc < len(m) else 0
        pc += 1
        return v
    def nn():
        lo = n(); hi = n()
        return lo | hi << 8
    def d8():
        v = n()
        return v - 256 if v > 127 else v

    idx = None
    op = n()
    if op in (0xdd, 0xfd):
        idx = 'ix' if op == 0xdd else 'iy'
        op = n()
        if op in (0xdd, 0xfd, 0xed):
            return 1, 'db $%02x' % m[start]
    disp = None

    def r(i):
        nonlocal disp
        if idx is None:
            return R[i]
        if i == 6:
            if disp is None:
                disp = d8()
            return '(%s%+d)' % (idx, disp)
        return {4: idx + 'h', 5: idx + 'l'}.get(i, R[i])

    def rp(i, t=RP):
        return idx if (idx and i == 2) else t[i]

    if op == 0xcb:
        if idx:
            disp = d8()
            op2 = n()
            x, y, z = op2 >> 6, (op2 >> 3) & 7, op2 & 7
            tgt = '(%s%+d)' % (idx, disp)
            if x == 0: t = '%s %s' % (ROT[y], tgt)
            elif x == 1: t = 'bit %d,%s' % (y, tgt)
            elif x == 2: t = 'res %d,%s' % (y, tgt)
            else: t = 'set %d,%s' % (y, tgt)
            return pc - start, t
        op2 = n()
        x, y, z = op2 >> 6, (op2 >> 3) & 7, op2 & 7
        t = ['%s %s' % (ROT[y], R[z]), 'bit %d,%s' % (y, R[z]), 'res %d,%s' % (y, R[z]), 'set %d,%s' % (y, R[z])][x]
        return pc - start, t

    if op == 0xed:
        op2 = n()
        x, y, z = op2 >> 6, (op2 >> 3) & 7, op2 & 7
        p, q = y >> 1, y & 1
        t = None
        if x == 1:
            if z == 0: t = 'in %s,(c)' % R[y] if y != 6 else 'in (c)'
            elif z == 1: t = 'out (c),%s' % (R[y] if y != 6 else '0')
            elif z == 2: t = '%s hl,%s' % ('sbc' if q == 0 else 'adc', RP[p])
            elif z == 3: t = ('ld ($%04x),%s' if q == 0 else 'ld %s,($%04x)') % ((nn(), RP[p]) if q == 0 else (RP[p], nn()))
            elif z == 4: t = 'neg'
            elif z == 5: t = 'reti' if y == 1 else 'retn'
            elif z == 6: t = 'im %s' % ['0', '0/1', '1', '2'][y & 3]
            else: t = ['ld i,a', 'ld r,a', 'ld a,i', 'ld a,r', 'rrd', 'rld', 'nop', 'nop'][y]
        elif x == 2 and z <= 3 and y >= 4:
            t = [['ldi', 'cpi', 'ini', 'outi'], ['ldd', 'cpd', 'ind', 'outd'], ['ldir', 'cpir', 'inir', 'otir'],
                 ['lddr', 'cpdr', 'indr', 'otdr']][y - 4][z]
        return pc - start, t or 'db $ed,$%02x' % op2

    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1
    t = None
    if x == 0:
        if z == 0:
            if y == 0: t = 'nop'
            elif y == 1: t = "ex af,af'"
            elif y == 2: e = d8(); t = 'djnz $%04x' % (pc + e)
            elif y == 3: e = d8(); t = 'jr $%04x' % (pc + e)
            else: e = d8(); t = 'jr %s,$%04x' % (CC[y - 4], pc + e)
        elif z == 1:
            t = 'ld %s,$%04x' % (rp(p), nn()) if q == 0 else 'add %s,%s' % (rp(2), rp(p))
        elif z == 2:
            if p == 0: t = 'ld (bc),a' if q == 0 else 'ld a,(bc)'
            elif p == 1: t = 'ld (de),a' if q == 0 else 'ld a,(de)'
            elif p == 2: a = nn(); t = 'ld ($%04x),%s' % (a, rp(2)) if q == 0 else 'ld %s,($%04x)' % (rp(2), a)
            else: a = nn(); t = 'ld ($%04x),a' % a if q == 0 else 'ld a,($%04x)' % a
        elif z == 3: t = '%s %s' % ('inc' if q == 0 else 'dec', rp(p))
        elif z == 4: t = 'inc %s' % r(y)
        elif z == 5: t = 'dec %s' % r(y)
        elif z == 6: tgt = r(y); t = 'ld %s,$%02x' % (tgt, n())
        else: t = ['rlca', 'rrca', 'rla', 'rra', 'daa', 'cpl', 'scf', 'ccf'][y]
    elif x == 1:
        if y == 6 and z == 6: t = 'halt'
        else:
            # with an index prefix, (ix+d) replaces (hl) and then the other operand stays a plain h/l
            if idx and (y == 6 or z == 6):
                a = r(y) if y == 6 else R[y]
                bb = r(z) if z == 6 else R[z]
                t = 'ld %s,%s' % (a, bb)
            else:
                t = 'ld %s,%s' % (r(y), r(z))
    elif x == 2:
        t = '%s%s' % (ALU[y], r(z))
    else:
        if z == 0: t = 'ret %s' % CC[y]
        elif z == 1:
            t = 'pop %s' % rp(p, RP2) if q == 0 else ['ret', 'exx', 'jp (%s)' % (idx or 'hl'), 'ld sp,%s' % (idx or 'hl')][p]
        elif z == 2: t = 'jp %s,$%04x' % (CC[y], nn())
        elif z == 3:
            if y == 0: t = 'jp $%04x' % nn()
            elif y == 2: t = 'out ($%02x),a' % n()
            elif y == 3: t = 'in a,($%02x)' % n()
            elif y == 4: t = 'ex (sp),%s' % (idx or 'hl')
            elif y == 5: t = 'ex de,hl'
            elif y == 6: t = 'di'
            else: t = 'ei'
        elif z == 4: t = 'call %s,$%04x' % (CC[y], nn())
        elif z == 5:
            if q == 0: t = 'push %s' % rp(p, RP2)
            elif p == 0: t = 'call $%04x' % nn()
        elif z == 6: t = '%s$%02x' % (ALU[y], n())
        else:
            t = 'rst $%02x' % (y * 8)
            if y * 8 in RST_NOTE:
                t += '        ; ' + RST_NOTE[y * 8]
    return pc - start, t or 'db $%02x' % op


def main():
    m = load(sys.argv[1])
    ranges = [(int(a, 16), int(b, 16)) for a, b in zip(sys.argv[3::2], sys.argv[4::2])] or [(0, len(m))]
    with open(sys.argv[2], 'w') as f:
        for a, e in ranges:
            pc = a
            while pc < e:
                ln, t = dis(m, pc)
                f.write('%04x: %-12s %s\n' % (pc, ' '.join('%02x' % v for v in m[pc:pc + ln]), t))
                pc += ln


if __name__ == '__main__':
    main()
