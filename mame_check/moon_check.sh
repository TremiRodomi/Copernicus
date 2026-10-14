#!/bin/bash
# The moon, port vs arcade (MAME) frame by frame: mame_check/moon_check.sh <round> <frames> <moon ticks> <work dir> [script]
# The moon countdown is preset (port --moon, play.lua PLAY_MOON) and HITS ARE ON (PLAY_HITS; the port without --no_hit;
# NOHIT=1 (env): NO HIT on both, for long runs - Horned, the event),
# so deaths, round restarts, the moon event and the night all happen within the run. Default script: idle (Ptolemy
# stands still and gets caught). Compares the countdown ($e69f / X68000 $61b) and night flag ($e6a1 / $61d) per row,
# then trace_diff.py (Ptolemy, divider, the 8 object slots).
set -e
R=$1; N=$2; M=$3; W=$(realpath -m "$4"); SCRIPT=${5:-W$((N+400))}; D=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/cfg" "$W/nvram"
python3 -I - "$SCRIPT" "$W/moon.in" <<'EOF'
import sys
codes = {'W': 0x0f, 'L': 0x0b, 'R': 0x07, 'J': 0x0d, 'JL': 0x09, 'JR': 0x05, 'Z': 0x0e}
frames = []
for tok in sys.argv[1].split():
    k = tok.rstrip('0123456789'); frames += [codes[k]] * int(tok[len(k):])
open(sys.argv[2], 'w').write('\n'.join('%x' % v for v in frames) + '\n')
EOF
cd "$D/../dragonruby-linux-amd64"
echo "$SCRIPT" > fairyland/check_script.txt
timeout 1800 ./dragonruby fairyland --round $R --short_hop 0 --music arcade --script_file check_script.txt \
  --lives ${LIVES:-3} --objlog $N --moon $M ${NOHIT:+--no_hit 1} >/dev/null 2>&1
cp fairyland/objlog.txt "$W/port.txt"
SLOT0=$(head -1 fairyland/objlog.txt | awk '{print substr($5,1,16)}')
HITS=PLAY_HITS=1; [ -n "$NOHIT" ] && HITS=PLAY_NOHIT=1
cd "$W" && env $HITS PLAY_MOON=$M PLAY_SND="$W/snd.txt" PLAY_SLOT0=$SLOT0 PLAY_ROUND=$R PLAY_INPUTS="$W/moon.in" \
  PLAY_FRAMES=$N PLAY_OUT="$W/mame.txt" PLAY_SHIFT=-1 timeout 3600 mame flstory -noautosave -cfg_directory cfg \
  -nvram_directory nvram -video none -sound none -nothrottle -skip_gameinfo -autoboot_script "$D/play.lua" >/dev/null 2>&1
python3 -I - "$W/mame.txt" "$W/port.txt" <<'EOF'
import sys
a = []
for l in open(sys.argv[1]):
    s = l.split()[5]; a.append((s[0x9f * 2:0x9f * 2 + 2], s[0xa1 * 2:0xa1 * 2 + 2]))
p = []
for l in open(sys.argv[2]):
    m = [t for t in l.split() if t.startswith('m=')][0][2:].split(',')
    p.append((m[0], m[1]))
best = None
for off in range(-3, 4):
    n = [k for k in range(len(a)) if 0 <= k + off < len(p) and a[k] != p[k + off]]
    if best is None or len(n) < len(best[1]): best = (off, n)
off, bad = best
print(f'moon countdown / night flag: port row = mame row {off:+d}: {len(bad)} differing rows of {len(a)}')
for k in bad[:12]: print('  row', k, 'mame', a[k], 'port', p[k + off] if 0 <= k + off < len(p) else None)
# the countdown's changes, to see the ticks, the death and the event
ch = [(k, a[k][0]) for k in range(1, len(a)) if a[k][0] != a[k - 1][0]]
print('mame countdown changes (row, value):', ch[:40])
EOF
env CMPN=$N python3 -I "$D/trace_diff.py" "$W/mame.txt" "$W/port.txt" 4 -1 | tail -6 || true
