# Deterministic random input script for mame_check: script_gen.py <seed> <frames> <port script out> <per-frame inputs out>
# deterministic input script: port tokens + per-frame active-low bytes
import random, sys
random.seed(int(sys.argv[1])); n=int(sys.argv[2])
toks=['W240']; frames=[0x0f]*240
while len(frames)<n:
    r=random.random(); k=random.randint(4,60)
    if r<0.3: t,v=('L',0x0b)
    elif r<0.6: t,v=('R',0x07)
    elif r<0.72: t,v=('JL',0x09); k=random.randint(1,4)
    elif r<0.84: t,v=('JR',0x05); k=random.randint(1,4)
    elif r<0.9: t,v=('J',0x0d); k=random.randint(1,3)
    elif r<0.97: t,v=('Z',0x0e); k=random.randint(1,3)
    else: t,v=('W',0x0f)
    toks.append(f'{t}{k}'); frames+= [v]*k
open(sys.argv[3],'w').write(' '.join(toks))
open(sys.argv[4],'w').write('\n'.join('%x'%v for v in frames)+'\n')
