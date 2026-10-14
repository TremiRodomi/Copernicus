# Diff of a MAME trace (mame_check/*.lua) against the port's --objlog: player x/y, speed divider, the 8 object slots.
# trace_diff.py <mame trace> <port objlog> <lines to print> <port frame offset>; CMPN=frames (default 1400).
import sys
F=['st','an','ty','tk','fc','jd','x','y','cm','sl','tr','tm']
# LAYOUT=arcade (default): MAME flstory $e600-$e6ff; LAYOUT=x68: MAME x68000, FS.X work RAM a6+$500..$7ff
SLOTS, PX, PY, DIV = (0x9d, 0x127, 0x128, 0x100) if __import__('os').environ.get('LAYOUT') == 'x68' else (0x21, 0xa9, 0xaa, 0x84)
def mame(p):
    rows=[]
    for l in open(p):
        f,_,_,_,_,s=l.split()
        b=[s[i:i+2] for i in range(0,len(s),2)]
        rows.append((int(f),b[PX],b[PY],b[DIV],[''.join(b[SLOTS+12*k:SLOTS+12*k+12]) for k in range(8)]))
    return rows
def port(p):
    rows=[]
    for l in open(p):
        f,px,py,div,s=l.split()[:5]
        rows.append((int(f),px,py,div,[s[i*24:(i+1)*24] for i in range(8)]))
    return rows
def starts(rows, key):
    out=[];prev=None
    for i,r in enumerate(rows):
        st=r[4][0][:2]
        if st==key and prev!=key and (not out or i-out[-1]>500): out.append(i)
        prev=st
    return out
a=mame(sys.argv[1]); p=port(sys.argv[2]); key=sys.argv[4] if len(sys.argv)>4 else '01'
ld_a=starts(a,'20'); ld_p=starts(p,'20')
off=int(sys.argv[4]) if len(sys.argv)>4 else 0
da=ld_a; dp=[i+off for i in ld_p]
# DRAC=1 (round 101, no enemy load): both logs start at the same trigger (row 0 = row 0); slots 0-1 hold
# the Dracolisk ($59d-$5b4 = arcade $e621-$e638), named after the port's fields
DRAC=__import__('os').environ.get('DRAC')=='1'
if DRAC: da=[0]; dp=[0]  # (MAME starts on the frame its slots equal the port's row 0)
DF=[['st','head','body','legs','tail','attr','x','y','cmd','legph','bodyph','landed'],
    ['5a9','htarget','hcur','tx','ty','wait','dmg','b0','b1','5b2','5b3','5b4']]
for d,(ia,ip) in enumerate(zip(da,dp)):
    n=0
    for k in range(0,int(__import__('os').environ.get('CMPN','1400'))):
        if ia+k>=len(a) or ip+k>=len(p): break
        ra,rp=a[ia+k],p[ip+k]
        if not DRAC and k>10 and all(x[:2]=='00' for x in ra[4]): break
        diffs=[]
        if (ra[1],ra[2])!=('00','00') and (ra[1],ra[2])!=(rp[1],rp[2]): diffs.append(f'P {ra[1]},{ra[2]}/{rp[1]},{rp[2]}')
        if ra[3]!=rp[3]: diffs.append(f'div {ra[3]}/{rp[3]}')
        for j in range(8):
            if ra[4][j]!=rp[4][j]:
                diffs.append(f's{j}: '+' '.join(f'{(DF[j] if DRAC and j<2 else F)[b]} {ra[4][j][2*b:2*b+2]}/{rp[4][j][2*b:2*b+2]}' for b in range(12) if ra[4][j][2*b:2*b+2]!=rp[4][j][2*b:2*b+2]))
        if diffs:
            n+=1
            if n<=int(sys.argv[3]): print(f'demo{d} +{k}: '+' | '.join(diffs))
    print(f'demo{d}: {n} differing frames of {k}')
