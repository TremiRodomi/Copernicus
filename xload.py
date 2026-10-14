"""Human68k .X loader: parses header, returns flat image (text+data), reloc list."""
import struct, sys
def load_x(path):
    d=open(path,'rb').read()
    assert d[:2]==b'HU'
    base,entry,text,data,bss,rsz,ssz=struct.unpack('>7I',d[4:32])
    img=d[0x40:0x40+text+data]
    rel=[]; p=0x40+text+data; end=p+rsz; cur=0
    while p<end:
        v=struct.unpack('>H',d[p:p+2])[0]; p+=2
        if v==1:
            v=struct.unpack('>I',d[p:p+4])[0]; p+=4
        cur+=v; rel.append(cur)
    return dict(base=base,entry=entry,text=text,data=data,bss=bss,img=img,relocs=rel)
if __name__=='__main__':
    x=load_x(sys.argv[1])
    print({k:(v if not isinstance(v,(bytes,list)) else len(v)) for k,v in x.items()})
    print("first relocs",[hex(r) for r in x['relocs'][:10]], "last",hex(x['relocs'][-1]))
    bad=[r for r in x['relocs'] if r+4>len(x['img'])]; print("out-of-range:",len(bad))
    # relocated targets distribution
    import collections
    tg=[struct.unpack('>I',x['img'][r:r+4])[0] for r in x['relocs']]
    print("targets in text:",sum(t<x['text'] for t in tg),"in data:",sum(x['text']<=t<x['text']+x['data'] for t in tg),"in bss:",sum(t>=x['text']+x['data'] for t in tg))
