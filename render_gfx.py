import sys,struct,os
from PIL import Image
def grb555(w):  # X68000 GVRAM word: GGGGG RRRRR BBBBB I
    g=(w>>11)&31; r=(w>>6)&31; b=(w>>1)&31
    return (r*255//31,g*255//31,b*255//31)
def title(path,out):
    d=open(path,'rb').read(); im=Image.new('RGB',(512,512))
    px=im.load()
    for y in range(512):
        for x in range(512):
            px[x,y]=grb555(struct.unpack_from('>H',d,(y*512+x)*2)[0])
    im.save(out)
def pal256():
    import colorsys
    p=[]
    for i in range(256):
        r,g,b=colorsys.hsv_to_rgb((i*37%256)/256.0,0.8 if i else 0,0.35+0.65*((i*53)%7)/7) if i else (0,0,0)
        p.append((int(r*255),int(g*255),int(b*255)))
    return p
def bg8(path,out,w=512):
    d=open(path,'rb').read(); h=len(d)//w
    im=Image.frombytes('P',(w,h),d); pp=[]; 
    for c in pal256(): pp+=list(c)
    im.putpalette(pp); im.convert('RGB').save(out)
if __name__=='__main__':
    # usage: render_gfx.py <dir with FLS_TTL.DAT.dec and BGCHR.DAT.dec> <outdir>
    src,dst=sys.argv[1],sys.argv[2]
    title(os.path.join(src,'FLS_TTL.DAT.dec'),os.path.join(dst,'title.png'))
    bg8(os.path.join(src,'BGCHR.DAT.dec'),os.path.join(dst,'bgchr.png'),512)
    print("ok")
