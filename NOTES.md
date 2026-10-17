# Copernicus - technical notes

This is the current state of knowledge about The Fairyland Story, condensed and organised by topic. The full working
history (60 passes, with every measurement, dead end and correction) is in [docs/research-log.md](docs/research-log.md),
and "pass N" below and in source comments points there. The arcade vs X68000 differences are in
[docs/VERSIONS.md](docs/VERSIONS.md).

Conventions:
- `$xxxx` = the FS.X flat image (text then data, from 0; text is $0000-$9bf9).
- `$nnn(a6)`, or just `$nnn` for a variable = the X68000 work area (pointer at $1132c).
- Arcade addresses are main-Z80 unless marked MCU. Work-RAM offsets map mostly as arcade = X68000 + $e082 (+$e084
  around the object slots, and not everywhere: check per variable).
- Game coordinates are rotated 180 degrees from the screen: Y grows upward, X grows leftward. Sprite X is stored
  negated.

---

## 1. Data files

### X68000 disks (pass 1, 4, 5, 7)
- 1.25 MB Human68k FAT12, 1024-byte sectors. `.hdm` = raw image; `.dim` = 256-byte header + the same image.
- Disk 1: `HUMAN.SYS COMMAND.X AUTOEXEC.BAT FS.X MDRV.X PCMDRV.R PCMDATA.DAT FLS_TTL.DAT BGCHR.DAT SPCHR.DAT`.
- Disk 2: `FS.DAT`, 36 bytes (high scores, last round $6ce, best round $6cf; byte 0 = best round, image offset 11264).
- `FS.X`: .X header (base +4, exec +8, text +12, data +16, bss +20, reloc +24, sym +28); text 39,930, data 30,514,
  bss 626,692; 1,110 relocated longs. BSS starts at $1132c.
- `.DAT` container: `u32 ?` | `u32 size` | LZSS (Okumura: 4 KB ring, start $FEE, LZHUF-style pre-fill, flag byte
  LSB-first, 1 = literal, len = (b1&$F)+3).

| file | decoded | content |
|---|---|---|
| FLS_TTL.DAT | 512 KB | 512x512 GVRAM picture, GRB555+I words (the "Now Loading..." title) |
| SPCHR.DAT | 96 KB | 3 sprite banks x 256 16x16 4bpp patterns (128 B each; 8x8 blocks UL, LL, UR, LR) |
| BGCHR.DAT | 128 KB | 1 byte per pixel 8x8 tiles; $00000-$0ffff = rounds 1-100 (4 banks x 256), $10000-$1ffff = round 101 |
| PCMDATA.DAT | | 64 length words + ADPCM samples (OKI 4-bit, 15625 Hz); command i+1 = word i (pass 38) |

### Arcade ROMs (pass 9, 20, 33)
- `cpu-a45.15/.16/.17` = Z80 $0000-$BFFF; `a45-20.mcu` = 68705 (2 KB); `snd.22/.23` = sound Z80 (unused by the port).
- Graphics: MAME-style 8x8 planar tiles, 16 bytes per tile per ROM; the first ROM of a pair = pen bits 0-1, the second
  = bits 2-3. BG tiles 0-1023 = .06/.07, 1024-2047 = .20/.21; sprite banks 0/1/2 = .18/.19, .08/.09, .20/.21.
  The X68000 files are a straight conversion: same numbering, same pens.
- Palettes: palette RAM $dd00-$deff (lo GGGGRRRR / hi ----BBBB). Theme sets at $58fa + 128*s, fixed table $5cfa,
  boot / sprite table $5d7a. The arcade INVERTS pens (15 - pixel within each group of 16).
- Round data: pointer tables $78de (rounds) / $79aa (enemies), 16-bit LE. The record tail and decoration format
  differ from the X68000's (see `GameData#round_record` etc.).

### Palettes (pass 5, 12, 20, 21)
- X68000 words = arcade 4-bit level * 2 with the I bit. Graphic palette: theme set n ($b600 + n*128, 64 words) ->
  entries 0-127 (the vblank copier DOUBLES every word below $e82200); the fixed table $ba00 -> 128-255.
  Sprites / text: $ba80, 16 blocks x 16.
- BG pixel index = group*32 + 2*pixel (+1 "odd" variant, the same colour). Groups 0-3 = theme, 4-7 = fixed.
  Groups 2/3 = 0/1 brightened by 2 levels (moonlight).
- The port has 2 colour profiles: standard (level x 17) and PCB (measured from the user's board captures:
  255 * ((level - 3) / 12) ^ 1.3).

### Sprites and metasprites (pass 5, 6, 31, 41)
- 32 dynamic sprites: each vblank the PCG patterns of shadow entries 0-31 are streamed from the SPCHR banks
  (attr bits 13-12 = bank, low byte = pattern).
- Shadow entry = 8 bytes (x, y, attr, prio). Sprite Y = ((~y + yoff - 2) & $ff) + $11 ($591 bit 1 is always set).
- Expanders and their tables:

| expander | table | arcade | entry |
|---|---|---|---|
| $1a48 | $10234 | $3353 | slot, y, hi, code, next |
| $1ab6 | $104f5 | $363e | y, hi, code, next |
| $1b22 | $108e9 | $3a5c | y, hi, code, next |
| $1b8e | $10b29 | $3cca | slot, y, hi, code, xoff, next |
| $1c44 | $110db | $873b | y, code, x, next (attr from the caller) |

  `hi` is stored ^ $c0 (b7 V-flip, b6 H-flip, b5-4 bank, b3-0 palette).
- Draw order = priority lists selected by $57e ($b158 + 64n / arcade $0510 + 32n); the FIRST entry is on top.
  List 1 puts Ptolemy behind everything; list 2 (death, potions) puts the bubble's sheen in front of her.
- 8-bit X wrap: on both versions a sprite part at X < 16 also shows at X + 256 (the X68000 copies list entries to a
  second hardware sprite).

### Rounds (pass 10, 10b, 10c, 26)
- Record (X68000 table $cd86 / arcade $78de): theme -> $593; a 100-byte solidity bitmap (32 x 25 cells, MSB-first,
  row 5 + k/32); a teleport-door pair (0, or x1 y1 x2 y2); item spawn x, y; a decoration selector.
- The background is generated: theme fill, bitmap tiles, autotiling ($133e), decoration lists, floor edge, drop
  shadows.
- Enemy list ($cf1e / $79aa): [speed $5fe][count] count x [type, x, y]. Types (metasprite bases):
  Orc $00, Salamander $1d, Golem $3a, Wraith $57, Cleric $74, Wizard $91; $ff = the Worm's door.
- Round 101 is hand-built ($1676): the second BGCHR half, palette set 5, mirrored blocks; the enemy loader starts
  task $21 (the Dracolisk) instead.
- Text and the HUD are name-table writes ($b52). The screen map is 32x32 cells; attr bits 7-6 bank, 5 priority over
  sprites (also the "odd" colour variant), 4 V-normal, 3 H-normal, 2-0 palette group.

---

## 2. Program structure (X68000; the arcade's is the same)

### Boot and frame (pass 2, 7)
- $0000 startup -> $1dbc main state machine -> $12a shutdown. The loader ($f5e) shows FLS_TTL, runs MDRV.X / PCMDRV.R
  as resident drivers, and decodes SPCHR / BGCHR.
- VBlank ($1d4): BG scroll, sprite / PCG update, the queued palette / word copies ($386), input ($41a), frame counter
  $5c.
- Every wait calls $248: vsync wait, then **$18b6 the task scheduler**, $1d4e (glass flicker), $574 (sound upkeep).
- Gameplay loop $2096: wait, keys ($2268), HUD ($7b8), extends ($2976) until $62e == $ff.

### Cooperative task scheduler (pass 2, 7)
- 23 slots x $24 bytes at $234(a6): id, flags (bit 0 allocated, bit 7 runnable), delay, saved d1-d4/a0-a2, resume PC.
- $1820 spawn (kills an existing task with that id first), $186e kill, $187a suspend, $1886 resume, $1890 kill all
  but the running task.
- A task yields with `jsr $18ea`, d0 = frames to sleep (0 = 256). These are stackless coroutines: nothing survives on
  the stack across a yield.
- New tasks get delay 1: a task spawned into a LATER slot runs in the same frame, into an earlier slot in the next one.
  Exact slot order matters for frame-exact timing.
- The arcade does the same with RST $08 spawn / $10 kill / $18 kill others / $30 yield.
- **Port:** each task is a plain-data state machine (one resume point per yield) in `app/game/tasks/`, run by
  `app/game/scheduler.rb` with the same slot rules. Main-loop code that the port runs as a task is spawned with
  `main: true`, so it survives `kill_others`.

### Task table ($b0e0, 46 entries) - roles (all confirmed by porting, unless marked)

| id | role | id | role |
|---|---|---|---|
| 00 | round director (deaths, step counter -> items) | 17 | bonus coins (crush combos) |
| 01 | Ptolemy (player) | 18 | score popups |
| 02 | "ENTER YOUR INITIALS !" flyer | 19 | Star Tiara stars |
| 03 | Ptolemy's spell | 1a / 1b | broom flies in / off (round intro) |
| 04 | enemy AI (one object per frame) | 1c | Scroll of Ice blocks |
| 05-0c | enemy bodies (slot = id - 5) | 1d | power-up glow |
| 0d | "BONUS 1000000" banner | 1e | attract-demo input script |
| 0e | background animation + button release | 1f | **unknown** |
| 0f | object-state manager (contact, spell hits, cakes) | 20 | teleport doors |
| 10 | sparkles | 21 | Dracolisk fight director |
| 11 | falling cakes / crushing | 22 / 23 | Dracolisk drawing / body |
| 12 / 13 | Wizard spell / Salamander fireball shots | 24 | Horned (hurry-up chaser) |
| 14 | the Moon | 25 | intermission flyer (Ptolemy + Rodomy) |
| 15 | bonus items (+ 18 handlers) | 26 | the Worm |
| 16 | Wizard gone: Ptolemy grows back | 27 / 28 / 29 | Dracolisk tail / airborne body / head |
| | | 2a / 2b | Dracolisk AI / fireballs |
| | | 2c / 2d | Holy Gem / Ptolemy's finale walk |

Port-only task ids $40-$4c stand in for main-loop code: the intro, round clear, ending, game over, attract, menu and
boot.

### Key work-area variables
| var | meaning | var | meaning |
|---|---|---|---|
| $59d + 12k | 8 object slots (state, anim, type, task, facing, jdx, x, y, AI cmd, sprite slot, trail, timer) | $5fd | enemies left (bit 7 = last-enemy mode) |
| $627 / $628 | Ptolemy x / y | $5fe / $600 | enemy speed / frame divider |
| $62e | round-end code ($40 enemy, $20 burnt, $10 shrink, $80 crushed, $ff done) | $610 | round timer (hurry $41, Horned $46) |
| $57f / $705 / $706 | EXP / level (0-based) / next level-up | $61b | moon countdown ($f0 = moon out) |
| $59b | active power-up | $652 | power-up timer |
| $700-$702 | score (BCD; display appends "0") | $704 | lives (BCD) |
| $703 | round, 0-based ($64 = 101) | $653 | rounds to skip (Mystical Feather) |
| $707 / $708 | step counter (800 px -> bonus item) | $67d | coin pickup streak (survives round clears) |
| $57e | sprite priority list | $47 | music set (0 ORIGINAL / $18 ARRANGE) |
| $578 | option bits (bit 6 clear = NO HIT, 3 continue, 1 ending) | $44 / $45 | sound muted / PCM $21 loop lock |

---

## 3. Game rules (both versions unless noted in VERSIONS.md)

- **Player:** walks 2 px per 3 frames; a jump rises 32 px (one platform tier, one-way platforms). A straight-up jump
  at a cell-aligned y steps onto a ledge (the "short hop"). Input is read only when the task wakes: when standing,
  once every 3 frames (measured in MAME, so the port's timing is arcade-exact; pass 13, 34).
- **Enemies:** the AI targets Ptolemy (or the spot beside a cake), jumps to platforms above, drops through gaps, and
  follows her 10-position trail when close. Enemies move $5fe of every $5fe+1 frames. Species attacks: the Wizard
  shrinks Ptolemy (EXP - 10); the Salamander's fireball burns her; the Cleric summons up to 3 more; the Wraith phases
  out of a spell; the Golem always chases.
- **Spell -> cake:** a hit turns an enemy into a cake that hatches when its timer runs out. Pushed cakes fall and crush
  the enemies below. Combos: 2 = 2000 ... 7 = 64000 points; 3 or more drop a bonus coin. Coins pay their value x the
  pickup streak.
- **EXP / levels:** an EXP bracket picks the odds row of the item table (6 tiers x 3 enemy-count groups = 18 items).
  Levels 1-8 (Holy Water: 9) set the power-up length. A new life sets EXP = round - 1 and the threshold back to $1d
  but keeps the level, so late rounds level up on each gain until it catches up; a Wraith kill costs a level
  (pass 8b, 16, 61).
- **Bonus item:** after 800 px of walking, it appears at the round's item spot for 150 x 6 frames (pass 23 lists all
  18 handlers).
- **Timer:** hurry-up at $41 (enemies full speed). Horned appears at $46 with 2+ enemies left (invincible; follows a
  scripted entrance, then a Bresenham chase). With 1 enemy left, that enemy escapes instead.
- **Moon:** one countdown for the whole game (deaths don't reset it): 120 ticks at a new game / continue, 240 after
  each moon; a tick is 120 frames (60 shrunk). It counts only while task 14 runs: an item on screen pauses it, Horned
  stops it for the round, each round start / new life takes a tick at once, round 101 has none; the Moon Tiara sets
  1. Night wipe; every enemy becomes a cake; cake breaks pay coins (pass 22, 56).
- **Worm:** an invincible lair at the arched door. It pokes out (shorter each time) when Ptolemy stands in front, and
  eats enemies (7000 points) or her (pass 25).
- **Teleport doors:** a pair per round in 19 rounds; you go through at the exact height (pass 26).
- **Round 101:** the Dracolisk. Spell hits add 30 to a damage meter, which drains 1 every 6 frames; a carry past 255
  wins. It turns into a giant cake and crumbles, then the Holy Gem, then the ending (+1,000,000), then game over /
  name entry (pass 27, 28).
- **Intermission:** before rounds 8, 15, 22 ... (13 messages); Ptolemy rides Rodomy (pass 29).
- **Extends:** factory DIPs: 30,000, then every 100,000 (pass 34).
- **Continue:** arcade, rounds 8-98; X68000, 8-101. Score and level reset; same round (pass 30).
- **Power-on:** the arcade shows 1UP = 13,090 (pass 34). The default best 5 starts with KBT 50220.

---

## 4. Sound

- `jsr $4ac` with d0 = command: 0 stops all, $ee mutes + stops, $ef unmutes, >= $40 ignored. Table $4ee routes each
  command to MDRV.X (FM song = value + $47) or PCMDRV.R (sample = command). $56c = "FM still playing" (callers loop on
  it to wait for a jingle). $21 is a looping PCM sample with a lock; $01 cancels it.
- The full catalogue is in `sound_commands.csv` (69 call sites, owning task, trigger, confidence).
- **Port** (`app/audio/audio.rb`, `audio/<set>/`): `<cmd hex> <name>.ogg` effects; `music/tracks.txt` maps commands to
  tracks (intro + loop files, `lengths.txt` in samples). The set's music is pre-decoded silently at boot / on a set
  change (Audio.warm: DragonRuby decodes a file in full on its first play - a 60 ms hitch; pass 61). Behaviours reproduced:
  - mute / unmute;
  - the $21 loop;
  - "music busy" waits;
  - the Extend jingle as an OVERLAY: the BGM keeps running muted for 155 frames;
  - the arcade sound board's $14 reply delay (140 frames).

  Audio files must be 44.1 kHz stereo. The build tools are in section 6.

---

## 5. The arcade MCU (68705, a45-20.mcu; pass 15b, 15c, 27)

Commands: bit 7 set = write to MCU RAM; 0-15 = handlers via the jump table at ROM $740; others read the marked RAM.
1. The boot handshake ($f9).
2. **State vault:** at every READY the Z80 packs the round, Ptolemy's sprite set and her speed into a 64-bit number;
   the MCU multiplies and divides it, and the Z80 reads it back at the restart. A board without the MCU hangs on the
   first restart.
3. Commands 2/3: a 5-byte castle-frame sequence per theme (attr, tiles, palette set), then the 75-step ghost-sway
   table.
4. Command 7: the ending and continue texts.
5. Commands 4/5/6: the Bresenham line stepper for the Dracolisk's fireballs (3 px steps).

The X68000 replaces 2-5 with plain 68000 code (no vault) and hard-codes the same values.

---

## 6. Port architecture (`dragonruby-linux-amd64/fairyland/`)

- `app/fs/`: `disk.rb` (FAT12), `lzss.rb`, `game_data.rb` (loads either source, identifies ROMs by CRC32, converts
  arcade data to the X68000 layout, builds the version variants), `tables.rb` (every table by name: ADDR, VARIANTS,
  VARIANT_EDITS, PATCHES, PAL_PATCH).
- `app/game/`: `world.rb` (one round's state, named after the original variables), `scheduler.rb`, `round_builder.rb`,
  `tasks/*.rb` (one file per original task family), `score.rb`, `text.rb`, `save.rb` (save.txt), `settings.rb`
  (settings.txt), `controls.rb` (keyboard + pads, rebinding), `pause.rb`.
- `app/gfx/`: `palette.rb`, `screen.rb` (BG pixel array + priority layer, decoded cells cached per setup), `sprites.rb` (texture cache per pattern x
  palette), `display.rb` (scaling, aspect, smoothing, scanlines / mask / vignette, borders, HD render targets),
  `widgets.rb` (corner info panels; preview on the WIDGETS page, fades: pass 57; whole-texel font: pass 61).
- `app/main.rb`: the tick loop, scenes, CLI flags (dev only; release builds read only `--source`).
- Rules:
  - game logic is separate from rendering;
  - tasks are plain data (rewind-friendly);
  - no raw data addresses in engine code;
  - version differences check `w[:behaviour]`.
- **DragonRuby 7.23 gotchas:**
  - `Integer / Integer` is a Float (use `idiv`);
  - no Regexp in mruby;
  - `Array#fill(nil)` raises;
  - no `<=>` on arrays;
  - an argument longer than ~900 characters drops it and every argument after it (use `--script_file`);
  - render targets are scaled by `render_scale` in HD mode (use `Display.target / texels / src`);
  - screenshots right after a window resize may segfault;
  - hot reload doesn't re-run `initialize` (initialise caches lazily);
  - audio must be 44.1 kHz stereo.

## 7. Verification

- `mame_check/check.sh` (arcade) and `check_x68.sh` (MAME `x68000` + the user's disks) run scripted inputs in MAME and
  in the port and diff the object slots, Ptolemy, the divider and sound commands **every frame / game pass**. Enemy AI
  has no randomness, so any diff is a bug or a version difference.
- Passing on both versions:
  - the 3 attract demos;
  - 60 s of play on rounds 12, 43 and 87;
  - a forced moon;
  - Horned (round 12, 5000 frames);
  - the Dracolisk fight including its fireballs (round 101, 3000 frames);
  - all 18 bonus items (mame_check/item_check.sh; Star Tiara's random stars excepted);
  - the Mystical Feather warp and round builds/starts, timed per round on both versions (app/game/build_times.rb).
- Not yet covered frame by frame: the ending, game over / continue (the Dracolisk defeat: sounds and frames checked).

## 8. Open items

Research questions (none block the release):
- Task $1f.
- $3862 (the X68000 extra ending scene?).
- $57c (the protection's penalty byte).
- The arcade's step-counter remainder and Wizard-shrink EXP clamp.
- The Dracolisk defeat sound timing.

To do after 1.0 (user):
- **Arcade Archives on PS4:** accept the PS4 release as an arcade source (the owned files are the proof of ownership;
  find and extract the ROMs, as for the Switch in pass 59). Needs the files from the user's PS4.
- **Audio balance:** defaults are MUSIC 3 / SFX 10 (since 2026-10-14). The mix between the music sets and the effects
  may still need per-set gain tweaks; PCB audio files as they come (loop points, jingle waits).
- **Graphics:** review the scaling and filter options, and maybe add more graphics features.
- An input latency check.
