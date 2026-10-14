"""Palette tables inside FS.X data segment (flat image offsets). Words are X68000 GRB555+I, big-endian."""
import sys,struct,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from xload import load_x
def rgb(w): return (((w>>6)&31)*255//31, ((w>>11)&31)*255//31, ((w>>1)&31)*255//31)
def tables(img):
    w=lambda o,n:[struct.unpack_from('>H',img,o+2*i)[0] for i in range(n)]
    return dict(sprite_text_blocks=[w(0xba80+32*b,16) for b in range(16)],     # -> $e82200
                gfx_sets=[w(0xb600+128*s,64) for s in range(8)],              # -> $e82000 (select with $28ae)
                gfx_fixed=w(0xba00,64))                                        # -> $e82080
if __name__=='__main__':
    from PIL import Image
    x=load_x(sys.argv[1]); t=tables(x['img'])
    sw=12; im=Image.new('RGB',(64*sw,(16+8+1+3)*sw),(40,40,40)); px=im.load()
    def row(y,ws):
        for i,v in enumerate(ws):
            for dy in range(sw-2):
                for dx in range(sw-2): px[i*sw+dx,y*sw+dy]=rgb(v)
    for b,ws in enumerate(t['sprite_text_blocks']): row(b,ws)
    for s,ws in enumerate(t['gfx_sets']): row(17+s,ws)
    row(26,t['gfx_fixed'])
    im.save(sys.argv[2]); print("palette swatch written")
    for b,ws in enumerate(t['sprite_text_blocks']): print("blk %2d:"%b,' '.join('%04x'%v for v in ws))
