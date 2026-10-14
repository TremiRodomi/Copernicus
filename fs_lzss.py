"""LZSS decoder used by Fairyland Story (X68000). Matches routine at $3c86/$3cdc in FS.X.
File = u32 (unknown, maybe checksum) | u32 output size | stream: flag byte (LSB first; 1=literal, 0=match) ...
match = 2 bytes b1,b2 -> pos=((b1&0xF0)<<4)|b2 (ring index), len=(b1&0x0F)+3. Ring 4096 bytes, write pos starts 0xFEE.
Ring pre-filled with the LZHUF dictionary (see init_ring)."""
import struct
def init_ring():
    r=bytearray()
    for v in range(256): r+=bytes([v])*13          # 13 copies of each value
    r+=bytes(range(256)); r+=bytes(range(255,-1,-1)); r+=bytes(128); r+=b' '*110
    assert len(r)==0xFEE, hex(len(r))
    return bytearray(r)+bytearray(4096-len(r))
def decode(data):
    unk,size=struct.unpack('>II',data[:8]); ring=init_ring(); w=0xFEE
    out=bytearray(); p=8
    while len(out)<size and p<len(data):
        flags=data[p]; p+=1
        for bit in range(8):
            if len(out)>=size: break
            if flags>>bit&1:
                c=data[p]; p+=1; out.append(c); ring[w]=c; w=(w+1)&0xFFF
            else:
                b1,b2=data[p],data[p+1]; p+=2
                pos=((b1&0xF0)<<4)|b2; n=(b1&0x0F)+3
                for _ in range(n):
                    c=ring[pos]; pos=(pos+1)&0xFFF
                    out.append(c); ring[w]=c; w=(w+1)&0xFFF
    return unk,size,bytes(out[:size]),p
if __name__=='__main__':
    import sys,os
    for f in sys.argv[1:]:
        d=open(f,'rb').read(); unk,size,out,p=decode(d)
        print(os.path.basename(f),"hdr1=%08x size=%d got=%d consumed=%d/%d"%(unk,size,len(out),p,len(d)))
        open(f+'.dec','wb').write(out)
