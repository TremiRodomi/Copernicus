import re,sys,struct,collections,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from xload import load_x
x=load_x(sys.argv[1]); img=x['img']
ents=[struct.unpack('>I',img[0xb0e0+4*i:0xb0e4+4*i])[0] for i in range(46)]
L=open(sys.argv[2]).read().splitlines()
rows=[(int(l[:6],16),l[8:].split(';')[0].strip()) for l in L]
addrs=[a for a,_ in rows]
import bisect
allstarts=sorted(set(ents))
def body(e):
    # extent: to next task entry (tasks share tails, so this is approximate)
    i=allstarts.index(e); end=allstarts[i+1] if i+1<len(allstarts) else e+0x400
    s=bisect.bisect_left(addrs,e); t=bisect.bisect_left(addrs,end)
    return rows[s:t],end-e
def lastd0(seg,k):
    for j in range(k-1,max(k-6,-1),-1):
        m=re.match(r'(moveq|move\.[bwl])\s+#\$([0-9a-f]+), d0$',seg[j][1])
        if m: return int(m.group(2),16)&0xffff
    return None
res={}
for tid,e in enumerate(ents):
    seg,size=body(e); f=collections.Counter(); snd=[];sp=[];yl=0;sset=[]
    for k,(a,t) in enumerate(seg):
        if re.search(r'\$62\(a6\)|\$66\(a6\)',t): f['reads_input']+=1
        if t.startswith('abcd') or t.startswith('sbcd'): f['bcd']+=1
        if re.search(r'(jsr|bsr\.\w)\s+\$4ac',t): v=lastd0(seg,k); snd.append(v)
        if re.search(r'(jsr|bsr\.\w)\s+\$1820',t): v=lastd0(seg,k); sp.append(v)
        if re.search(r'(jsr|bsr\.\w)\s+\$(18ea|18b4)',t): yl+=1
        if re.search(r'(bsr\.\w|jsr)\s+\$1a48|\$1ab6',t): v=lastd0(seg,k); sset.append(v)
        if re.search(r'\$(e82|eb0|e8e|e00|c00)[0-9a-f]*\.l|#\$(e8|eb|e0)',t): f['hw']+=1
        if re.search(r'move\.\w\s+#\$[0-9a-f]+, \$(70[0-9a-f]|71[0-3])\(a6\)|\$704\(a6\)',t): f['lives/score']+=1
    res[tid]=(e,size,dict(f),snd,sp,yl,sset)
    print("id %02x @%05x size %5d  input:%-2s bcd:%-2s hw:%-3s yield-calls:%-3d snd=%s spawns=%s sprsets=%s"%(
      tid,e,size,f.get('reads_input',0),f.get('bcd',0),f.get('hw',0),yl,
      sorted(set(hex(v) if v is not None else '?' for v in snd))[:8],
      sorted(set(hex(v) if v is not None else '?' for v in sp))[:8],
      sorted(set(hex(v) if v is not None else '?' for v in sset))[:6]))
