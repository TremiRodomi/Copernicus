#!/bin/bash
# Bonus items, port vs arcade (MAME) frame by frame: mame_check/item_check.sh <round> <frames> <work dir> [item ...]
# For each item N (0-17, default all): at log row ROW (default 400, after the intro) the item spot moves under Ptolemy,
# the walk counter is set to 798 and the roll is forced to N (port --item_test, play.lua PLAY_ITEM); she then walks
# right 4 frames (the item appears on the director's next 6-frame step and is picked up) and casts a spell every 42
# frames. NO HIT. Diffs: trace_diff.py (Ptolemy, divider, the 8 object slots) and the sound command frames.
set -e
R=$1; N=$2; W=$(realpath -m "$3"); shift 3; D=$(cd "$(dirname "$0")" && pwd)
ROW=${ROW:-400}
ITEMS=${@:-$(seq 0 17)}
mkdir -p "$W/cfg" "$W/nvram"
python3 -I - "$ROW" $((N+400)) "$W/item.txt" "$W/item.in" <<'EOF'
import sys
row, n = int(sys.argv[1]), int(sys.argv[2])
toks = [f'W{row + 1}', 'R4']; frames = [0x0f] * (row + 1) + [0x07] * 4
while len(frames) < n:
    toks += ['W40', 'Z2']; frames += [0x0f] * 40 + [0x0e] * 2
open(sys.argv[3], 'w').write(' '.join(toks))
open(sys.argv[4], 'w').write('\n'.join('%x' % v for v in frames) + '\n')
EOF
for I in $ITEMS; do
  cd "$D/../dragonruby-linux-amd64"
  cp "$W/item.txt" fairyland/check_script.txt
  timeout 900 ./dragonruby fairyland --round $R --no_hit 1 --short_hop 0 --music arcade --script_file check_script.txt \
    --objlog $N --item_test $I,$ROW >/dev/null 2>&1
  cp fairyland/objlog.txt "$W/port_i$I.txt"
  awk '/snd=[0-9a-f]/ { for (i = 1; i <= NF; i++) if ($i ~ /^snd=/) print NR - 3, substr($i, 5) }' fairyland/script_log.txt > "$W/psnd_i$I.txt"
  SLOT0=$(head -1 fairyland/objlog.txt | awk '{print substr($5,1,16)}')
  cd "$W" && PLAY_SND="$W/snd_i$I.txt" PLAY_SLOT0=$SLOT0 PLAY_ROUND=$R PLAY_INPUTS="$W/item.in" PLAY_FRAMES=$N \
    PLAY_OUT="$W/mame_i$I.txt" PLAY_SHIFT=-1 PLAY_ITEM="$I,$ROW" timeout 1800 mame flstory -noautosave -cfg_directory cfg \
    -nvram_directory nvram -video none -sound none -nothrottle -skip_gameinfo -autoboot_script "$D/play.lua" >/dev/null 2>&1
  echo "=== item $I"
  env CMPN=$N python3 -I "$D/trace_diff.py" "$W/mame_i$I.txt" "$W/port_i$I.txt" 6 -1 || true
  # sound commands: script_log line 1 is the script, then frame 0; the port's frame k = MAME row k + 1 (PLAY_SHIFT -1),
  # hence NR - 3 above; split commands ("27,2c") are expanded
  python3 -I - "$W/snd_i$I.txt" "$W/psnd_i$I.txt" $N <<'PY'
import sys
n = int(sys.argv[3])
a = [(int(f), c) for f, c in (l.split() for l in open(sys.argv[1])) if 5 <= int(f) < n]
p = [(int(f), c.lstrip('0') or '0') for f, cs in (l.split() for l in open(sys.argv[2])) for c in cs.split(',') if 5 <= int(f) < n]  # (the port's frame 0 is the round start's $07, before MAME's log)
a = [(f, c.lstrip('0') or '0') for f, c in a]
print('sounds: same' if a == p else 'sounds DIFFER:\n  mame ' + str(a) + '\n  port ' + str(p))
PY
done
