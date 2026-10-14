import sys, struct, os, hashlib
def load(p):
    d=open(p,'rb').read()
    if p.lower().endswith('.dim'): d=d[256:]
    return d
def fat12(d,n):
    out=[]
    for i in range(n):
        o=i*3//2
        v=d[o]|(d[o+1]<<8)
        out.append((v>>4) if i&1 else (v&0xfff))
    return out
def walk(d, bps, spc, fat, start_dir_bytes, data0, path, out, outdir):
    for i in range(0,len(start_dir_bytes),32):
        e=start_dir_bytes[i:i+32]
        if e[0]==0: break
        if e[0]==0xE5: continue
        base=(e[0:8]+e[12:22]).rstrip(b' \0')
        ext=e[8:11].rstrip(b' ')
        attr=e[11]
        cl=struct.unpack('<H',e[26:28])[0]
        size=struct.unpack('<I',e[28:32])[0]
        try: nm=base.decode('shift_jis')+('.'+ext.decode('shift_jis') if ext else '')
        except: nm=base.hex()
        if attr&0x08: print("  label",nm); continue
        chain=[]; c=cl
        while 2<=c<0xff0 and len(chain)<5000:
            chain.append(c); c=fat[c]
        if attr&0x10:
            if nm in('.','..'): continue
            sub=b''.join(d[data0+(c-2)*bps*spc:data0+(c-2)*bps*spc+bps*spc] for c in chain)
            os.makedirs(os.path.join(outdir,path,nm),exist_ok=True)
            walk(d,bps,spc,fat,sub,data0,path+'/'+nm,out,outdir)
        else:
            data=b''.join(d[data0+(c-2)*bps*spc:data0+(c-2)*bps*spc+bps*spc] for c in chain)[:size]
            fp=os.path.join(outdir,path.lstrip('/'),nm)
            os.makedirs(os.path.dirname(fp),exist_ok=True)
            open(fp,'wb').write(data)
            out.append((path+'/'+nm,size,hashlib.md5(data).hexdigest()[:8], attr))
if __name__=='__main__':
    p,outdir=sys.argv[1],sys.argv[2]
    d=load(p)
    # Observed bytes after 'Hudson soft 2.00' at 0x12: 04 00 01 02 00 01 00 c0 04 d0 fe 02
    bps=0x0400; spc=1; nf=2; res=1; nroot=0xc0; spf=2
    assert d[0x12:0x1e]==bytes.fromhex('040001020001 00c004d0fe02'.replace(' ','')), 'unexpected boot sector geometry'
    fat=fat12(d[res*bps:(res+spf)*bps],spf*bps*2//3)
    rootstart=(res+nf*spf)*bps
    root=d[rootstart:rootstart+nroot*32]
    data0=rootstart+nroot*32
    out=[]
    os.makedirs(outdir,exist_ok=True)
    walk(d,bps,spc,fat,root,data0,'',out,outdir)
    for r in out: print("%-40s %8d %s attr=%02x"%r)
