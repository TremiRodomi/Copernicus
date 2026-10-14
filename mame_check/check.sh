#!/bin/bash
# Port vs arcade (MAME) frame-by-frame check of enemies / Ptolemy / speed divider on one round.
#   mame_check/check.sh <round> <seed> <frames> <work dir>
# DRAC=1 (env): round 101 - align on the first row, slots 0-1 = the Dracolisk (trace_diff.py).
# SPR=1 (env): also diff the sprite slots $4c-$58 (Horned) - spr_diff.py.
# Needs mame (flstory ROMs in its rompath) and the port's dev flags. MAME runs isolated (scratch cfg / nvram in <work dir>).
# Alignment: the port runs one frame ahead of the MAME log and MAME reads inputs one frame earlier (PLAY_SHIFT=-1).
set -e
R=$1; SEED=$2; N=$3; W=$(realpath -m "$4"); D=$(cd "$(dirname "$0")" && pwd)
SHIFT=-1; [ -n "$DRAC" ] && SHIFT=0 # (round 101 starts on the matching frame itself)
mkdir -p "$W/cfg" "$W/nvram"
python3 -I "$D/script_gen.py" $SEED $((N+400)) "$W/s$SEED.txt" "$W/s$SEED.in"
cd "$D/../dragonruby-linux-amd64"
cp "$W/s$SEED.txt" fairyland/check_script.txt # (a long --script argument is dropped by DragonRuby)
timeout 900 ./dragonruby fairyland --round $R --no_hit 1 --short_hop 0 --music arcade --script_file check_script.txt --objlog $N ${SPR:+--sprlog 1} >/dev/null 2>&1
cp fairyland/objlog.txt "$W/port_r${R}_s$SEED.txt"
[ -n "$SPR" ] && cp fairyland/sprlog.txt "$W/pspr_r${R}_s$SEED.txt"
SLOT0=$(head -1 fairyland/objlog.txt | awk '{print substr($5,1,16)}')
cd "$W" && PLAY_SND="$W/snd_r${R}_s$SEED.txt" PLAY_SLOT0=$SLOT0 PLAY_ROUND=$R PLAY_INPUTS="$W/s$SEED.in" PLAY_FRAMES=$N \
  PLAY_OUT="$W/mame_r${R}_s$SEED.txt" PLAY_SHIFT=$SHIFT env ${SPR:+PLAY_SPR="$W/mspr_r${R}_s$SEED.txt"} timeout 1800 mame flstory -noautosave -cfg_directory cfg \
  -nvram_directory nvram -snapshot_directory . -video none -sound none -nothrottle -skip_gameinfo \
  -autoboot_script "$D/play.lua" >/dev/null 2>&1
env CMPN=$N ${DRAC:+DRAC=1} python3 -I "$D/trace_diff.py" "$W/mame_r${R}_s$SEED.txt" "$W/port_r${R}_s$SEED.txt" 10 -1
[ -z "$SPR" ] || python3 -I "$D/spr_diff.py" "$W/mame_r${R}_s$SEED.txt" "$W/port_r${R}_s$SEED.txt" "$W/mspr_r${R}_s$SEED.txt" "$W/pspr_r${R}_s$SEED.txt" -1 10
