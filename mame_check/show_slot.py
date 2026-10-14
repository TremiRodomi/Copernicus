# show_slot.py <mame trace> <port objlog> <offset> <slot> <from> <to>: one object slot side by side
import sys
F=['st','an','ty','tk','fc','jd','x','y','cm','sl','tr','tm']
a=[l.split() for l in open(sys.argv[1])]; p=[l.split() for l in open(sys.argv[2])]
off=int(sys.argv[3]); j=int(sys.argv[4]); k0,k1=int(sys.argv[5]),int(sys.argv[6])
for k in range(k0,k1):
    b=a[k][5]; ms=b[(0x21+12*j)*2:(0x21+12*j+12)*2]; ps=p[k+off][4][j*24:(j+1)*24]
    f=lambda s:' '.join(s[i:i+2] for i in range(0,24,2))
    print(k, 'P', b[0xa9*2:0xab*2], p[k+off][1]+p[k+off][2], '| mame', f(ms), '| port', f(ps), '<<' if ms!=ps else '')
print('fields:', ' '.join(F))
