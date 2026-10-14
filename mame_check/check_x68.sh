#!/bin/bash
# Port (--x68k 1) vs MAME's X68000 running the user's FS disks, one row per game pass (lag-proof).
#   mame_check/check_x68.sh <round> <seed> <frames> <work dir> <disk 1> <disk 2>
# The disks are COPIED into <work dir> (MAME may write to them; disk 2 is the save disk). x68000.zip in the project root.
# TASKS=1 (env): also log the task slot ids (xtasks_*.txt). XSHIFT=n: input shift (round 101: 1).
# DRAC=1 (env): round 101 - slots 0-1 = the Dracolisk (trace_diff.py).
# ROUND SELECT needs progress on disk 2 ($6cf >= round - 1). MOON=N (env): the moon countdown at the round start.
set -e
R=$1; SEED=$2; N=$3; W=$(realpath -m "$4"); D=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/cfg" "$W/nvram" "$W/disks"
cp "$5" "$W/disks/d1.hdm"; cp "$6" "$W/disks/d2.hdm"
python3 -I "$D/script_gen.py" $SEED $((N+400)) "$W/s$SEED.txt" "$W/s$SEED.in"
cd "$D/../dragonruby-linux-amd64"
cp "$W/s$SEED.txt" fairyland/check_script.txt # (a long --script argument is dropped by DragonRuby)
timeout 900 ./dragonruby fairyland --x68k 1 --round $R --no_hit 1 --short_hop 0 --music arcade --script_file check_script.txt --objlog $N ${MOON:+--moon $MOON} >/dev/null 2>&1
cp fairyland/objlog.txt "$W/xport_r${R}_s$SEED.txt"
SLOT0=$(head -1 fairyland/objlog.txt | awk '{print substr($5,1,16)}')
cd "$W" && PLAY_SLOT0=$SLOT0 PLAY_ROUND=$R PLAY_INPUTS="$W/s$SEED.in" PLAY_FRAMES=$N PLAY_OUT="$W/x68_r${R}_s$SEED.txt" PLAY_SHIFT=${XSHIFT:-0} PLAY_MOON=$MOON PLAY_TASKS=${TASKS:+$W/xtasks_r${R}_s$SEED.txt} \
  timeout 2400 mame x68000 -rompath "$D/.." -flop1 disks/d1.hdm -flop2 disks/d2.hdm -noautosave -cfg_directory cfg \
  -nvram_directory nvram -video none -sound none -nothrottle -skip_gameinfo -autoboot_script "$D/play_x68.lua" >/dev/null 2>&1
env LAYOUT=x68 CMPN=$N ${DRAC:+DRAC=1} python3 -I "$D/trace_diff.py" "$W/x68_r${R}_s$SEED.txt" "$W/xport_r${R}_s$SEED.txt" 10 0
