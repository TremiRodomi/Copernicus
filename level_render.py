"""Round background renderer: python3 -P -E level_render.py <FS.X> <BGCHR.DAT.dec> <outdir> [round ...]
A literal port of the round build in FS.X ($1114): screen clear $646, theme builder $1196 (fills $17f2, tile blocks $177e, solidity bitmap $13da,
door pair $142e, autotile $133e, decoration lists $152a), floor edge $14be, shadows $1478, marker/deco $150e; then drawn like $d10 through the
BG tile cache rules ($eb2). Overlays frame 0 of each enemy ($cf1e table), $ff door objects and the item spawn point (white cross).
Writes round_NNN.png (256x256, the full 32x32-cell graphic screen) and rounds.png (contact sheet).
Output embeds game graphics: keep it local (fl_files/out/). Rounds are 1-based on the command line; round 101 uses a different path ($1676)."""
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -P drops the script dir; it is trusted project code
from xload import load_x
from palettes import rgb

class Round:
    """Work area = the a6 block (offsets as in the game). Map: cell i (row-major, 32x32) has tile at $1334-2i, attr at $1335-2i."""
    def __init__(s, img, rnd):
        s.img = img; s.ws = bytearray(0x1400); s.attr = 0
        s.ptr = struct.unpack('>I', img[0xcd86 + 4 * rnd:0xcd8a + 4 * rnd])[0] if rnd < 100 else None
    def b(s, a): return s.img[a]
    def long(s, a): return struct.unpack('>I', s.img[a:a + 4])[0]
    def clear(s):  # $646: 64 x 32-byte copies of the 8 longs at $6e4 into $b36..$1335
        pat = s.img[0x6e4:0x704]
        for k in range(64): s.ws[0xb36 + 32 * k:0xb56 + 32 * k] = pat
    def pos(s, P): return 0xb37 + (P - 0xc000)  # screen position word -> map pointer (used with pre-decrement)
    def block(s, P, a0):  # $177e: h, w, then h*w tile codes; attr = $6a. returns a0 after the block
        h, w = s.b(a0), s.b(a0 + 1); a0 += 2; q = s.pos(P)
        for r in range(h):
            t = q
            for c in range(w):
                t -= 1; s.ws[t] = s.attr; t -= 1; s.ws[t] = s.b(a0); a0 += 1
            q -= 0x40
        return a0
    def mirror(s, P, a0):  # $17b6: like $177e but each row is laid out right-to-left (used with an H-flip attr)
        h, w = s.b(a0), s.b(a0 + 1); a0 += 2; q = s.pos(P)
        for r in range(h):
            t = q
            for c in range(w):
                t -= 1; s.ws[t] = s.attr; t -= 1; s.ws[t] = s.b(a0); a0 += 1; t += 4
            q -= 0x40
        return a0
    def build_final(s):  # $1676: round 101 (Dracolisk), hand-built; uses the SECOND half of BGCHR ($591 |= $18) and palette set 5
        s.clear(); s.theme = 0xff; s.door = None; s.bghalf = 1; s.palset = 5
        def at(attr, P, blk, fn=None): s.attr = attr; (fn or s.block)(P, blk)
        at(0x5a, 0xc67b, 0xaf09); at(0x52, 0xc645, 0xaf09, s.mirror)
        at(0x5a, 0xc37b, 0xaf97); at(0x52, 0xc345, 0xaf97, s.mirror)
        for k in range(14): at(0x5a, 0xc3fb - 4 * k, 0xb033)
        s.bitmap(0xb07b, 0xed); s.autotile(0xb075, 0xff)
        for k in range(15): at(0x1b, 0xc6fd - 4 * k, 0xb039)
        at(0x1b, 0xc6ff, 0xb041); at(0x1b, 0xc67f, 0xb045); at(0x13, 0xc641, 0xb045, s.mirror)
        s.floor_edge(); s.marker = (0, 0, 0, 0)
        return s
    def fill(s, P, rows, cols, tile):  # $17f2
        q = s.pos(P)
        for r in range(rows):
            t = q
            for c in range(cols):
                t -= 1; s.ws[t] = s.attr; t -= 1; s.ws[t] = tile
            q -= 0x40
    def bitmap(s, a0, tile):  # $13da: 100 bytes, MSB first; solid cells get `tile` and collision flag at $a75-k
        s.ws[0x716:0xb36] = bytes(0x420); a2, a3 = 0x11f5, 0xa75
        for k in range(100):
            v = s.b(a0); a0 += 1
            for bit in range(8):
                if (v << bit) & 0x80: s.ws[a2] = s.attr; s.ws[a2 - 1] = tile; s.ws[a3] = 1
                a2 -= 2; a3 -= 1
        return a0
    def pair(s, a0, tab):  # $142e: 0 = none, else x1,y1,x2,y2 (game coords) -> same block drawn at both; task $20 runs it
        if s.b(a0) == 0: return a0 + 1, None
        x1, y1, x2, y2 = s.img[a0:a0 + 4]
        for x, y in ((x1, y1), (x2, y2)):
            s.block(0xc083 + ((y & 0xf8) << 3) + ((x & 0xf8) >> 2), tab)  # $86a4
        return a0 + 4, (x1, y1, x2, y2)
    def autotile(s, tab, theme):  # $133e
        a0, a1 = 0x11f4, 0xa75
        for _ in range(0x340):
            w = s.ws
            if w[a1]:
                m = (1 if w[a1 + 0x20] else 0) | (2 if w[a1 + 1] else 0) | (4 if w[a1 - 0x20] else 0) | (8 if w[a1 - 1] else 0)
                if m:
                    p = tab
                    while s.b(p) and s.b(p) != m: p += 2
                    w[a0] = s.b(p + 1)
                    if theme & 0x80: w[a0 + 1] = 0x5a
                    elif theme == 3 and m in (3, 0xc, 6): w[a0 + 1] = {3: 0x51, 0xc: 0x49, 6: 0x41}[m]
            a0 -= 2; a1 -= 1
    def decos(s, a0):  # $152a: { word attr, long screen pos, long block ptr } until word 0
        while True:
            w = struct.unpack('>H', s.img[a0:a0 + 2])[0]
            if not w: return
            s.attr = w & 0xff; P = s.long(a0 + 2); s.block(P, s.long(a0 + 6)); a0 += 10
    def floor_edge(s):  # $14be
        w = s.ws; a0, a1 = 0xbf6, 0x775
        for _ in range(31):
            if not w[a1] & 1: a0 -= 2
            else:
                if not w[a1 + 1] & 1: hi, lo = 0x14, 0x72
                elif not w[a1 - 1] & 1: hi, lo = 0x1c, 0x72
                else: hi, lo = 0x1c, 0
                a0 -= 1; w[a0] = hi; a0 -= 1; w[a0] = lo
            a1 -= 1
        a0 -= 1; w[a0] = 0x1c; a0 -= 1; w[a0] = 0
    def shadows(s):  # $1478
        w = s.ws; a0, a3 = 0x11f4, 0xa75
        for _ in range(0x320):
            if not w[a3]:
                if w[a3 + 0x21]: w[a0] = (w[a0] + 2) & 0xff
                elif w[a3 + 0x20]: w[a0] = (w[a0] + (2 if w[a3 + 1] else 1)) & 0xff
                elif w[a3 + 1]: w[a0] = (w[a0] + 3) & 0xff
            a0 -= 2; a3 -= 1
    def build(s):
        s.bghalf = 0; s.palset = None
        s.clear(); a0 = s.ptr; theme = s.b(a0); a0 += 1; s.theme = theme
        if theme == 0:
            s.attr = 0x19; s.fill(0xc6bb, 0x19, 0x1c, 0xbe)
            a0 = s.bitmap(a0, 0xc2); s.attr = 0x19; a0, s.door = s.pair(a0, 0xa82b); s.decos(0xa4aa)
        elif theme == 1:
            s.attr = 0x59; P = 0xc6bb
            for r in range(13):
                for c in range(7): s.block(P - 8 * c, 0x12f2)
                P -= 0x80
            a0 = s.bitmap(a0, 0x3b); s.attr = 0x59; a0, s.door = s.pair(a0, 0xa833); s.autotile(0xa87d, theme); s.decos(0xa526)
        elif theme == 2:
            s.attr = 0x59; s.fill(0xc63b, 0x17, 0x1c, 0x8d)
            a0 = s.bitmap(a0, 0x9b); s.attr = 0x59; a0, s.door = s.pair(a0, 0xa83b); s.autotile(0xa867, theme); s.decos(0xa69e)
            s.attr = 0x59; s.fill(0xc639, 1, 0x1b, 0x8f)
        else:
            s.attr = 0x59; P = 0xc6bb
            for r in range(13):
                for c in range(14): s.block(P - 4 * c, 0x121c)
                P -= 0x80
            a0 = s.bitmap(a0, 0xba); s.attr = 0x59; a0, s.door = s.pair(a0, 0xa843); s.autotile(0xa84b, theme); s.decos(0xa778)
        s.floor_edge(); s.shadows()
        s.marker = tuple(s.img[a0:a0 + 4])  # $150e: x, y -> $650/$651; byte 3 = deco list selector ($1544[t-$11])
        if s.marker[3]: s.decos(s.long(0x1544 + 4 * (s.marker[3] - 0x11)))
        s.rest = a0 + 4
        return s

ENEMY_TYPES = {0x00: 'Orc', 0x1d: 'Salamander', 0x3a: 'Golem', 0x57: 'Wraith', 0x74: 'Cleric', 0x91: 'Wizard'}  # base index into $104f5 (29 frames each)

def enemies(img, rnd):
    """$253e: table $cf1e[round] -> [byte -> $5fe] [count] count x [type, x, y]; type $ff = door object ($6f5/$6f6, block via $728, task $26)."""
    p = struct.unpack('>I', img[0xcf1e + 4 * rnd:0xcf22 + 4 * rnd])[0]
    return img[p], [tuple(img[p + 2 + 3 * k:p + 5 + 3 * k]) for k in range(img[p + 1])]

def draw_sprites(im, img, sp, r, rnd):
    """Overlay frame 0 of each enemy ($1ab6 table $104f5) and the $ff door blocks; mark the item spawn point ($650/$651)."""
    from sprite_viewer import x68_to_linear
    from palettes import tables
    P = [[rgb(w) for w in b] for b in tables(img)['sprite_text_blocks']]
    px = im.load(); s5fe, objs = enemies(img, rnd)
    def put(sx, sy, hi, code):  # sx, sy = X68000 sprite register coords (16,16 = top-left of the screen)
        hi ^= 0xc0; bank = 0 if not hi & 0x20 else (1 if not hi & 0x10 else 2)
        for i, v in enumerate(x68_to_linear(sp[(bank * 256 + code) * 128:][:128])):
            x, y = i % 16, i // 16
            if hi & 0x40: x = 15 - x
            if hi & 0x80: y = 15 - y
            X, Y = sx - 16 + x, sy - 16 + y
            if v and 0 <= X < 256 and 0 <= Y < 256: px[X, Y] = P[hi & 15][v]
    for t, x, y in objs:
        if t == 0xff: continue  # door block is drawn into the map before render()
        idx = t
        for _ in range(8):  # $1ab6: Y = ((~y + yoff) & $ff) + $11, X = (-x) & $ff
            yo, hi, code, nx = img[0x104f5 + 4 * idx:0x104f9 + 4 * idx]
            put((-x) & 0xff, (((~y) + yo - 2) & 0xff) + 0x11, hi, code)  # - ($591 & 2): bit 1 is always set in play
            if not nx: break
            idx = nx
    ix, iy = r.marker[0], r.marker[1]
    for d in range(-3, 4):  # item spawn point: white cross
        for X, Y in ((((-ix) & 0xff) - 8 + d, (((~iy) & 0xff) + 1) + 8), (((-ix) & 0xff) - 8, (((~iy) & 0xff) + 1) + 8 + d)):
            if 0 <= X < 256 and 0 <= Y < 256: px[X, Y] = (255, 255, 255)
    return s5fe, objs

def palette(img, theme):
    """Graphic palette (256 entries). Writes below $e82200 go through the doubling copier ($386): source word j -> entries 2j and 2j+1.
    So set n ($b600+n*128, 64 words, loaded by $28a4 with n = theme) fills 0-127 and the fixed table $ba00 (sent to $e82080) fills 128-255."""
    w = lambda o: struct.unpack('>H', img[o:o + 2])[0]
    words = [w(0xb600 + 128 * theme + 2 * i) for i in range(64)] + [w(0xba00 + 2 * i) for i in range(64)]
    return [rgb(words[i >> 1]) for i in range(256)]

def render(r, bg, pal):
    from PIL import Image
    im = Image.new('RGB', (256, 256)); px = im.load()
    for i in range(1024):
        tile, attr = r.ws[0x1334 - 2 * i], r.ws[0x1335 - 2 * i]
        src = r.bghalf * 0x10000 + ((attr & 0xc0) << 8) + tile * 64       # bank (attr bits 7-6) within the first 64 KB half of BGCHR
        hflip, odd, vnorm, base = not attr & 8, attr & 0x20, attr & 0x10, (attr & 7) * 32
        cx, cy = (i % 32) * 8, (i // 32) * 8
        for y in range(8):
            row = bg[src + 8 * (y if vnorm else 7 - y):][:8]
            for x in range(8):
                v = row[7 - x if hflip else x]
                idx = base | (v << 1) | (1 if odd and v else 0)
                px[cx + x, cy + y] = pal[idx]
    return im

def main():
    from PIL import Image
    img = load_x(sys.argv[1])['img']; bg = open(sys.argv[2], 'rb').read(); out = sys.argv[3]
    sp = open(os.path.join(os.path.dirname(sys.argv[2]), 'SPCHR.DAT.dec'), 'rb').read()
    rounds = [int(a) for a in sys.argv[4:]] or list(range(1, 102))
    sheet = Image.new('RGB', (10 * 258, ((len(rounds) + 9) // 10) * 258), (40, 40, 40))
    for n, rn in enumerate(rounds):
        r = Round(img, rn - 1)
        if rn == 101:
            r.build_final(); im = render(r, bg, palette(img, r.palset)); im.save(os.path.join(out, 'round_101.png'))
            sheet.paste(im, ((n % 10) * 258, (n // 10) * 258)); print('round 101 (final, boss task $21)'); continue
        r.build()
        objs = enemies(img, rn - 1)[1]
        for t, x, y in objs:
            if t == 0xff: r.attr = 0x59 if r.theme == 2 else 0x19; r.block(0xc083 + ((y & 0xf8) << 3) + ((x & 0xf8) >> 2), 0xb53a if r.theme == 2 else 0xb532)
        im = render(r, bg, palette(img, r.theme))
        s5fe, objs = draw_sprites(im, img, sp, r, rn - 1); im.save(os.path.join(out, 'round_%03d.png' % rn))
        sheet.paste(im, ((n % 10) * 258, (n // 10) * 258))
        print('round %3d theme %d door %s item@%02x,%02x $5fe=%d enemies %s' % (rn, r.theme, r.door, r.marker[0], r.marker[1], s5fe,
              ' '.join(ENEMY_TYPES.get(t, 'DOOR') + '@%02x,%02x' % (x, y) for t, x, y in objs)))
    sheet.save(os.path.join(out, 'rounds.png'))

if __name__ == '__main__':
    main()
