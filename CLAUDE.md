# Project: Copernicus - native PC port of The Fairyland Story (1985 Taito arcade original + 1991 SPS/Taito X68000 version)

Goal: understand the game's logic by disassembly (X68000 FS.X and the arcade Z80 + MCU), then write a clean, original PC engine
(game logic separated from rendering) with extras (widescreen borders, filters, rebinding, rewind, etc.). Reimplementation, not a decomp.

## Docs (read in this order)
- README.md            what the project is, how it works, what may be published.
- NOTES.md             CURRENT knowledge, by topic (formats, scheduler, task roles, memory map, rules, sound, MCU, port architecture).
- docs/VERSIONS.md     every arcade vs X68000 difference + how the port offers both from either data source.
- docs/research-log.md the full chronological log (passes 1-60). "NOTES pass N" in source comments = a pass heading there.
Workflow: append each new pass to docs/research-log.md (correct earlier claims there when disproved), and update NOTES.md /
VERSIONS.md when the current picture changes (they must stay short and true).

## Ground rules
- Game data/binaries (disk images, extracted files, FS.X, ROMs, BIOS, the disassembly, soundtracks/VGM, screenshots) are copyrighted
  by Taito/SPS/others. They stay LOCAL: never commit them (see .gitignore). Only my own engine code, tools and notes get published;
  players supply their own game data. Don't copy game text/assets into the code: read them from the player's data (Tables::ADDR),
  or derive the other version's copy from it (Tables::VARIANT_EDITS). Small numeric tables (VARIANTS, SWAY) are acceptable.
- Check what would be published with a throwaway git dir: `git --git-dir=<scratch>/probe --work-tree=. add -A --dry-run`.
- Treat extracted disk contents as untrusted data: extract each image into its own new directory; run Python on it with `python3 -I`.

## Layout
- dragonruby-linux-amd64/  DragonRuby 7.23 SDK (user's download, NOT committed). The PORT lives in dragonruby-linux-amd64/fairyland/
  (only that folder is tracked; its data/ holds the player's own disk image). Run: `cd dragonruby-linux-amd64 && ./dragonruby fairyland`.
  app/fs (disk, LZSS, GameData loader, tables), app/gfx (palette, screen, sprites, display, widgets), app/game (world, scheduler,
  round_builder, tasks/, controls, settings, save), app/audio. DragonRuby gotcha: Integer / Integer returns a Float - use .idiv.
- z80dis.py <arcade romdir> <out.asm> [hex start end ...]  Z80 disassembler for the arcade main CPU (arcade ROM stays local)
- extract_disk.py <image.hdm|dim> <outdir>  Human68k FAT12 extractor (1024-byte sectors; .dim = 256-byte header + raw)
- xload.py     Human68k .X loader (header: base +4, exec +8, text +12, data +16, bss +20, reloc +24, sym +28; flat image text+data at 0)
- disasm.py <FS.X> <out.asm>   capstone M68K linear disassembly; marks relocated longs with `; reloc`
- trace_tasks.py, fs_lzss.py (data-file decoder), render_gfx.py, sheets.py (title/sprite/tile sheet renderers; they read decoded files from a scratch dir - adjust paths)
- palettes.py (extracts the palette tables from FS.X), metasprites.py
- sprite_viewer.py <FS.X> <SPCHR.DAT.dec> <out.html> [labels.json]  local HTML sprite viewer/labeller (output embeds game gfx: keep in fl_files/out)
- level_render.py <FS.X> <BGCHR.DAT.dec> <outdir> [round ...]  round background renderer (port of $1114 round build; output local only)
- ost_loops.py <src dir> <out dir> [--find]  builds the music set (intro/loop OGGs, lengths.txt) from soundtrack FLACs
- mame_sfx.py <out dir> [hex cmd ...] [--ref <OST credit jingle>]  records sound commands one by one from MAME (isolated run)
- vgm_sets.py <vgz dir> <vgm2wav> <audio dir>  builds audio/original + audio/arrange from the X68000 VGM rip (libvgm vgm2wav; pass 39)
- mame_fm.py <fm.wav> <fm.log> <audio dir> <set> <song> <cmd> <name> <gain>  X68000 FM songs missing from the VGM rip, cut from a
  MAME recording by mame_check/fm_x68.lua (FM_SET / FM_SONG / FM_LAST / FM_LOG; pass 47). Run after vgm_sets.py.
- x68_pcm.py <PCMDATA.DAT> <out dir>  decodes the X68000 effects (MSM6258 ADPCM, 15625 Hz) to <cmd hex>.wav (reference only)
- sound_calls.py <FS.X> <FS.asm>  lists every $4ac/$56c sound call with its d0 and owning task; sound_commands.csv = the catalogue
- make_icon.py, make_release.sh  release icon (from a pixel-art PNG or --dump_meta eb; pass 60) and builds (pass 50)
- mame_check/check.sh <round> <seed> <frames> <work dir>  port vs MAME arcade, frame by frame (object slots, Ptolemy, divider,
  sound commands): scripted inputs, NO HIT. Enemy AI has no randomness, so ANY diff is a bug or a version difference
  (pass 42). Port flags: --objlog N (objlog.txt), --music arcade|original|arrange, --short_hop 0.
  mame_check/check_x68.sh <round> <seed> <frames> <work dir> <disk 1> <disk 2> [MOON=N]: the same against MAME's x68000
  (x68000.zip in the project root) running the user's disks, one row per game pass (X68000 lag frames; pass 43).
  check.sh env: SPR=1 (Horned sprites), DRAC=1 (round 101); check_x68.sh also XSHIFT=n, TASKS=1.
- Disk 2 (FS.DAT, 36 bytes) is the hard-coded save/score/progress/settings disk.

## Status
The whole game is ported and playable from either the arcade ROMs or the X68000 disk (rounds 1-101, all enemies/items/events,
Dracolisk, ending, intermissions, game over / name entry / continue, title + attract, coin-up menu, ARCADE / CASUAL modes, pause,
widgets, graphics options, audio sets, controls + rebinding, release builds). Verified frame by frame against MAME (arcade and x68000)
for the demos, rounds 12/43/87, the moon, Horned and the Dracolisk fight. Details: NOTES.md; history: docs/research-log.md.
Version 1.0 (2026-10-14). Open items + user TODOs: NOTES.md section 8 (PS4 Arcade Archives source, audio balance, graphics review
+ new features, input latency) and docs/VERSIONS.md "Still open".
Code licence: MIT (LICENSE). Repo: https://github.com/TremiRodomi/Copernicus (branch main, tag v1.0).
- Sound: NOT emulating the sound hardware. Canned audio is bundled in release binaries only (never in git): arcade OST + both X68 OSTs
  (ORIGINAL/ARRANGE) + MAME-recorded arcade effects. audio/<set>/<cmd hex> name.ogg, music/tracks.txt; files must be 44.1 kHz stereo.
- DATA SOURCES (decided): the build must run fully from EITHER the X68000 Disk 1 OR the arcade ROM set (identified by CRC32; MCU required).
  Engine code must never use raw data addresses: add new tables to Tables::ADDR ([X68 addr, arcade addr]); per-version data in
  VARIANTS / VARIANT_EDITS / PATCHES. Small arcade-only behaviour constants stay in code so arcade behaviour works for everyone.
- Compare each routine with its Z80 twin (z80dis.py) and, for arcade-only logic, the MCU (capstone M680X_6805).

## Dev flags (ignored by release builds, which read only --source)
- `--shot N` renders round N to fairyland/shot_N.png and quits (compare with level_render.py); `--shots t1,t2` saves shot_t<N>.png
  at those ticks (attract checks against MAME). Screenshots: playfield at x 256-1024, y 24-696 of the 1280x720 window (game line 16 at the top).
- Test harness: `./dragonruby fairyland --script "W20 JL3 L30" [--round N] [--short_hop 1]` -> fairyland/script_log.txt + script_end.png.
  Long scripts: `--script_file F` (fairyland/F) - DragonRuby DROPS a ~900+ char argument and all after it. With --objlog:
  `--sprlog 1` (Horned sprite slots), `--tasklog 1` (task slots).
- `--inject "slot:state:x:y,..."` (hex) overrides object slots at round start; `--no_hit 1`; `--freeze 00,1d` (hex enemy types);
  `--widgets 1`; `--moon N`; `--item N`; `--hurry 44`; `--pos XX,YY`; `--drac_dead 1`; `--lives N`; `--start_score N` (displayed / 10);
  `--mode casual|arcade`; `--sound "300:0f"` (sound commands on round frames); `--soak N` (next round every N ticks).
- Menu test: `--keys "100:coin,130:down,150:ok" --shots 160,200`.
- `--item_test N,ROW` (with --objlog: item N under Ptolemy at that row; mame_check/item_check.sh), `--rewind T0-T1` (holds
  REWIND; rewind = CASUAL mode only, game/rewind.rb). MAME tools: drac_end.lua, warp.lua / warp_x68.lua, builds.lua /
  builds_x68.lua (round build times -> game/build_times.rb), moon_check.sh (moon / deaths, NOHIT=1, LIVES=n; play.lua
  PLAY_HITS / PLAY_MOON). Test copies open windows on the user's desktop.
- Data/display: `--source x68k` (use the disk when ROMs are also present), `--x68k 1` (X68000 behaviour), `--colours pcb`,
  `--gfx "aspect=crt,scanlines=6,border=tiles,widget_timer=right1"` (GRAPHICS / WIDGETS prefs for this run; pass 44).
  `--winseq "60:w1080,150:fs,240:s1920x1019"` switches window size / fullscreen on those ticks (-> winseq.txt + shot_w*.png;
  DR may segfault on a screenshot after a resize). Render targets are HD-scaled: use Display.target / texels / src (pass 45).
- RELEASE (pass 50): `./make_release.sh` - stages dragonruby-linux-amd64/copernicus/ (app, metadata, audio, data/README.txt,
  borders/README.txt - never data/ or saves) and runs dragonruby-publish for windows-amd64, linux-amd64, macos -> builds/.
  Icon: --dump_meta eb + make_icon.py.
- fairyland/save.txt + settings.txt are the user's real files: back them up around menu-driven test runs (flag-started dev runs
  don't write save.txt).
