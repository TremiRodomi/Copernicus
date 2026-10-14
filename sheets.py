import sys
from PIL import Image
import colorsys
# placeholder 16-colour palette (real palettes live in FS.X data - not found yet)
PAL=[(0,0,0)]+[tuple(int(c*255) for c in colorsys.hsv_to_rgb(((i-1)*0.0667)%1,0.75,0.95)) for i in range(1,16)]
def bg_sheet(d,out,cols=64,n=2048):
    rows=(n+cols-1)//cols; im=Image.new('RGB',(cols*8,rows*8)); px=im.load()
    for t in range(n):
        ox,oy=(t%cols)*8,(t//cols)*8
        for y in range(8):
            for x in range(8): px[ox+x,oy+y]=PAL[d[t*64+y*8+x]&15]
    im.save(out)
def nib(d,i): b=d[i>>1]; return (b>>4) if not i&1 else (b&15)
def sp_sheet(d,out,layout,cols=32):
    n=len(d)//128; rows=(n+cols-1)//cols; im=Image.new('RGB',(cols*16,rows*16)); px=im.load()
    for s in range(n):
        base=s*128; ox,oy=(s%cols)*16,(s//cols)*16
        for y in range(16):
            for x in range(16):
                if layout=='x68':   # 4 blocks of 8x8: UL, LL, UR, LR ; each block 8 rows * 4 bytes
                    blk=(x//8)*2+(y//8); o=base+blk*32+(y%8)*4+(x%8)//2; b=d[o]; v=(b>>4) if (x%8)%2==0 else (b&15)
                else:               # linear 16 rows * 8 bytes
                    o=base+y*8+x//2; b=d[o]; v=(b>>4) if x%2==0 else (b&15)
                px[ox+x,oy+y]=PAL[v]
    im.save(out)
if __name__=='__main__':
    # usage: sheets.py <dir with BGCHR.DAT.dec and SPCHR.DAT.dec> <outdir>
    import os
    src,dst=sys.argv[1],sys.argv[2]
    bg=open(os.path.join(src,'BGCHR.DAT.dec'),'rb').read(); sp=open(os.path.join(src,'SPCHR.DAT.dec'),'rb').read()
    bg_sheet(bg,os.path.join(dst,'bg_sheet.png'))
    sp_sheet(sp,os.path.join(dst,'sp_x68.png'),'x68'); sp_sheet(sp,os.path.join(dst,'sp_lin.png'),'lin')
