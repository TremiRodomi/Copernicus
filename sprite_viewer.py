"""Local sprite viewer: python3 -P -E sprite_viewer.py <FS.X> <SPCHR.DAT.dec> <out.html> [labels.json]
Writes ONE self-contained HTML page (open it in a browser) that draws all 768 SPCHR patterns client-side, each with its best-known palette
block, so palettes can be switched live. Click a pattern to change its palette / name it; "Export" downloads the edits as JSON, which can be
fed back in as labels.json (and becomes the port's palette/label override table).
The page embeds game graphics: keep it local (write it under fl_files/out/), never publish or commit it."""
import os, sys, json, base64
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -P drops the script dir; it is trusted project code
from xload import load_x
from palettes import tables, rgb
from metasprites import usage

# Palette/name knowledge that is NOT in the metasprite tables (from code reading; see NOTES.md)
ITEMS = {  # task 15 drop table: sprite code (bank 1, drawn by $7b52 with attr hi $ed -> palette 13)
    0x5b: 'Silver Scepter', 0x74: 'Moon Tiara', 0x76: 'Magic Staff', 0x5c: 'Scroll of Fire', 0x63: 'Mystical Orb',
    0x62: 'Glass Potion', 0x5e: 'Holy Water', 0x5a: 'Gold Scepter', 0x75: 'Star Tiara', 0x59: 'Crystal Ring',
    0x5d: 'Scroll of Ice', 0x61: 'Change Potion', 0x77: 'Book of Life', 0x60: 'Mystical Feather', 0x78: 'Book of Death'}

def x68_to_linear(p):
    """128-byte X68000 PCG pattern (8x8 blocks UL, LL, UR, LR; 4 bytes/row, hi nibble = left) -> 256 pixel indices, row-major."""
    px = bytearray(256)
    for y in range(16):
        for x in range(16):
            b = p[((x >> 3) * 2 + (y >> 3)) * 32 + (y & 7) * 4 + ((x & 7) >> 1)]
            px[y * 16 + x] = (b >> 4) if not x & 1 else (b & 15)
    return px

def main():
    img = load_x(sys.argv[1])['img']
    sp = open(sys.argv[2], 'rb').read()
    labels = json.load(open(sys.argv[4])) if len(sys.argv) > 4 else {}
    assert len(sp) == 3 * 256 * 128, 'SPCHR.DAT.dec should be 98304 bytes'
    pix = bytearray()
    for n in range(768):
        lin = x68_to_linear(sp[n * 128:(n + 1) * 128])
        pix += bytes((lin[i] << 4) | lin[i + 1] for i in range(0, 256, 2))
    pals = [[list(rgb(w)) for w in blk] for blk in tables(img)['sprite_text_blocks']]
    use = usage(img)
    info = []
    for n in range(768):
        bank, code = divmod(n, 256)
        c = use.get((bank, code))
        if c:
            pal, src = c.most_common(1)[0][0], 'metasprite table' + (' (also %s)' % ','.join(str(k) for k in sorted(c) if k != c.most_common(1)[0][0]) if len(c) > 1 else '')
        elif bank == 1 and code in ITEMS:
            pal, src = 13, 'item draw $7b52 (attr $ed)'
        elif bank == 2 and 0x60 <= code <= 0xd0:
            pal, src = 3, 'Dracolisk guess (pal 3, user-confirmed purple)'
        else:
            pal, src = 0, 'unresolved'
        name = ITEMS.get(code, '') if bank == 1 else ''
        info.append({'pal': pal, 'src': src, 'name': name})
    for k, v in labels.items():  # "bank:code" -> {pal?, name?}
        b, c = (int(t, 16) for t in k.split(':')); e = info[b * 256 + c]
        if 'pal' in v: e['pal'] = v['pal']; e['src'] = 'labels.json'
        if 'name' in v: e['name'] = v['name']
    data = {'pix': base64.b64encode(bytes(pix)).decode(), 'pals': pals, 'info': info}
    html = PAGE.replace('/*DATA*/null', json.dumps(data))
    open(sys.argv[3], 'w').write(html)
    print('wrote', sys.argv[3], '- resolved:', sum(e['src'] != 'unresolved' for e in info), '/ 768')

PAGE = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SPCHR Sprite Viewer</title><style>
:root{--bg:#f6f6f4;--fg:#1c1c1c;--muted:#666;--card:#fff;--line:#d8d8d4;--acc:#2a6fdb;--checker:#e4e4e0}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--fg:#e8e8e8;--muted:#999;--card:#222;--line:#3a3a3a;--acc:#6aa0ff;--checker:#2c2c2c}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 system-ui,sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
h1{font-size:16px;margin:0 12px 0 0}label{color:var(--muted)}select,input,button{font:inherit;padding:3px 6px;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:4px}
button{cursor:pointer}main{padding:16px;display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap}
.bank h2{font-size:14px;margin:0 0 6px}.grid{display:grid;grid-template-columns:repeat(16,auto);gap:2px;background:var(--checker);padding:2px;border-radius:4px}
canvas.t{width:32px;height:32px;image-rendering:pixelated;cursor:pointer;outline:1px solid transparent}
canvas.t.unres{opacity:.45}canvas.t.named{outline-color:#d9a400}canvas.t.sel{outline:2px solid var(--acc)}
aside{position:sticky;top:64px;background:var(--card);border:1px solid var(--line);border-radius:6px;padding:12px;min-width:260px;max-width:320px}
aside canvas{width:160px;height:160px;image-rendering:pixelated;background:var(--checker);display:block;margin-bottom:8px}
.pals{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;margin:8px 0}.pals canvas{width:100%;height:auto;image-rendering:pixelated;cursor:pointer;border:2px solid transparent}
.pals canvas.on{border-color:var(--acc)}small{color:var(--muted)}
</style></head><body>
<header><h1>SPCHR sprites</h1>
<label>Show <select id="flt"><option value="all">all</option><option value="unres">unresolved only</option><option value="named">named only</option></select></label>
<label>Scale <select id="sc"><option>2</option><option selected>3</option><option>4</option></select></label>
<button id="exp">Export edits (JSON)</button><small id="cnt"></small></header>
<main><div id="banks" style="display:flex;gap:16px;flex-wrap:wrap"></div>
<aside id="side"><canvas id="big" width="16" height="16"></canvas><div id="meta"><small>Click a sprite.</small></div>
<div class="pals" id="pals"></div><label>Name <input id="nm" style="width:100%"></label></aside></main>
<script>
const D=/*DATA*/null;
const raw=Uint8Array.from(atob(D.pix),c=>c.charCodeAt(0));const edits={};let cur=-1;
function draw(cv,n,pal){const ctx=cv.getContext('2d'),im=ctx.createImageData(16,16),P=D.pals[pal];
 for(let i=0;i<256;i++){const b=raw[n*128+(i>>1)],v=(i&1)?b&15:b>>4,o=i*4;if(v){im.data[o]=P[v][0];im.data[o+1]=P[v][1];im.data[o+2]=P[v][2];im.data[o+3]=255}}
 ctx.putImageData(im,0,0)}
const tiles=[];const banks=document.getElementById('banks');
for(let b=0;b<3;b++){const s=document.createElement('section');s.className='bank';s.innerHTML='<h2>Bank '+b+'</h2>';const g=document.createElement('div');g.className='grid';
 for(let c=0;c<256;c++){const n=b*256+c,cv=document.createElement('canvas');cv.width=cv.height=16;cv.className='t';cv.onclick=()=>pick(n);tiles[n]=cv;g.appendChild(cv)}
 s.appendChild(g);banks.appendChild(s)}
function hex(v){return v.toString(16).padStart(2,'0')}
function key(n){return (n>>8)+':'+hex(n&255)}
function refresh(n){const e=D.info[n],cv=tiles[n];draw(cv,n,e.pal);cv.classList.toggle('unres',e.src=='unresolved');cv.classList.toggle('named',!!e.name);
 cv.title='bank '+(n>>8)+' code $'+hex(n&255)+' pal '+e.pal+(e.name?' - '+e.name:'')}
function filter(){const f=document.getElementById('flt').value;for(let n=0;n<768;n++){const e=D.info[n];
 tiles[n].style.visibility=(f=='all'||(f=='unres'&&e.src=='unresolved')||(f=='named'&&e.name))?'visible':'hidden'}}
function pick(n){if(cur>=0)tiles[cur].classList.remove('sel');cur=n;tiles[n].classList.add('sel');const e=D.info[n];
 draw(document.getElementById('big'),n,e.pal);
 document.getElementById('meta').innerHTML='<b>bank '+(n>>8)+' · code $'+hex(n&255)+'</b><br><small>palette '+e.pal+' — '+e.src+'</small>';
 document.getElementById('nm').value=e.name||'';const ps=document.getElementById('pals');ps.innerHTML='';
 for(let p=0;p<16;p++){const cv=document.createElement('canvas');cv.width=cv.height=16;draw(cv,n,p);cv.title='palette '+p;if(p==e.pal)cv.className='on';
  cv.onclick=()=>{e.pal=p;e.src='edited';(edits[key(n)]=edits[key(n)]||{}).pal=p;refresh(n);pick(n);count()};ps.appendChild(cv)}}
document.getElementById('nm').oninput=ev=>{if(cur<0)return;D.info[cur].name=ev.target.value;(edits[key(cur)]=edits[key(cur)]||{}).name=ev.target.value;refresh(cur);count()};
document.getElementById('flt').onchange=filter;
document.getElementById('sc').onchange=ev=>{const s=16*ev.target.value+'px';tiles.forEach(t=>{t.style.width=t.style.height=s})};
function count(){document.getElementById('cnt').textContent=D.info.filter(e=>e.src!='unresolved').length+' / 768 with a palette · '+Object.keys(edits).length+' edited'}
document.getElementById('exp').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(edits,null,1)],{type:'application/json'}));a.download='labels.json';a.click()};
for(let n=0;n<768;n++)refresh(n);document.getElementById('sc').onchange({target:{value:3}});count();
</script></body></html>'''

if __name__ == '__main__':
    main()
