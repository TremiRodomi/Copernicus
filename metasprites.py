"""Collect (bank, pattern) -> palette-block usage from the sprite-set tables in FS.X (flat image offsets).
Tables (expander routine -> entry layout):
  $10234 (+idx*5, $1a48): slot, y, hi^$c0, code, next      141 entries
  $104f5 (+idx*4, $1ab6): y, hi^$c0, code, next            253 entries
  $108e9 (+idx*4, $1b22): y, hi^$c0, code, next            144 entries
  $10b29 (+idx*6, $1b8e): slot, y, hi^$c0, code, xoff, next 243 entries
  $110db (+idx*4, $1c44): y, code, x, next   (palette/hi comes from caller register d7 - not in table)
hi (after ^$c0): bit7 V-flip, bit6 H-flip, bits5-4 bank (bit5 clear -> bank0; 10 -> bank1; 11 -> bank2), bits3-0 palette block."""
import sys,os,collections
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from xload import load_x
def usage(img):
    use=collections.defaultdict(collections.Counter)
    def add(hi,code):
        hi^=0xc0; bank=0 if not hi&0x20 else (1 if not hi&0x10 else 2); use[(bank,code)][hi&15]+=1
    for i in range((0x104f5-0x10234)//5): e=img[0x10234+5*i:0x10234+5*i+5]; add(e[2],e[3])
    for base,end in ((0x104f5,0x108e9),(0x108e9,0x10b29)):
        for i in range((end-base)//4): e=img[base+4*i:base+4*i+4]; add(e[1],e[2])
    for i in range((0x110db-0x10b29)//6): e=img[0x10b29+6*i:0x10b29+6*i+6]; add(e[2],e[3])
    return use
if __name__=='__main__':
    use=usage(load_x(sys.argv[1])['img'])
    print("patterns with a known palette:",len(use),"of 768")
    multi={k:dict(v) for k,v in use.items() if len(v)>1}; print("patterns used with >1 palette block:",len(multi))
    pc=collections.Counter(p for v in use.values() for p in v); print("palette blocks seen:",sorted(pc.items()))
