# The versions of The Fairyland Story

Copernicus can play from either of two releases of the game. This page covers how they differ, and how the port
handles each difference. Details and addresses for every row are in [research-log.md](research-log.md), under the
pass number given.

## The releases

| | Arcade (Taito, 1985) | Sharp X68000 (SPS / Taito, 1991) |
|---|---|---|
| Hardware | Z80 main CPU, Z80 sound CPU (AY-3-8910 + MSM5232 + DAC, TA7630 volume / tone), **68705 MCU** | 10 MHz 68000, YM2151 FM + MSM6258 ADPCM |
| Program | `cpu-a45.15-.17` (Z80 $0000-$BFFF) + `a45-20.mcu` | `FS.X` (72,728-byte Human68k executable) on Disk 1 |
| Graphics | `vid-a45.06-.09`, `.18-.21` (planar 8x8 tiles) | `BGCHR.DAT` / `SPCHR.DAT` (LZSS-packed), `FLS_TTL.DAT` (title picture) |
| Sound | sound Z80 program (`snd.22` / `.23`) | `MDRV.X` (FM music, 2 soundtracks), `PCMDRV.R` + `PCMDATA.DAT` (effects) |
| Saves | none | Disk 2, `FS.DAT` (36 bytes: high scores, last / best round) |

**How the X68000 version was made.** It is a straight conversion of the arcade program. Almost every data table is
byte-for-byte identical to the arcade ROM: the sprite tables, round layouts, enemy lists, item odds and the EXP system.
The X68000 code reproduces the Z80 routines instruction for instruction (it even keeps arcade addresses inside some
tables). The graphics use the same tile numbers and pen values, and the palettes are the same 4-bit colours re-encoded.
Most differences therefore come from three things: the MCU (the X68000 had to replace what it did), conversion slips,
and a few deliberate changes for the home release (the menu and options, two soundtracks, and saves).

### Dumps and sets the port accepts

- **Arcade:** the MAME `flstory` set. The older `flstoryo` set also works; only its sound-CPU ROMs differ, and the port
  doesn't use those. ROMs are recognised by CRC32 of their contents, so renamed files and merged dumps work. **The MCU
  is required.** It was dumped late, so some collections, such as Taito Legends 2, ship without it. Arcade Archives
  (Switch): the game's ExeFS `main` holds the full set, MCU included, byte-identical to MAME's `flstory`; the loader
  finds the ROMs in it (pass 59). The PS4 release is untested.
- **X68000:** Disk 1 as `.hdm` or `.dim`, or the loose files `FS.X`, `BGCHR.DAT`, `SPCHR.DAT` (plus `FLS_TTL.DAT` for
  the boot picture).
  - The two circulating dumps (`(y) (Taito).hdm` and `(SPS)(Disk A).dim`) hold identical files except for 6 bytes of
    `FS.X`. These bytes are **two different cracks** of the disk copy protection: the HDM stubs the check routine, while
    the DIM skips the call. Neither dump is pristine, and both behave the same. The port ignores the protection
    entirely (pass 7).

## Gameplay and presentation differences

The port defaults to arcade behaviour. GAME OPTIONS > BEHAVIOUR (dev: F5 / `--x68k 1`) switches to the X68000 behaviour.
Each row works whichever version's files you supply (see *How the port stays version-neutral* below).

| # | What | Arcade | X68000 | Pass |
|---|------|--------|--------|------|
| 1 | Ghost bubble after a death | sways along the MCU's 75-step table; random 1-in-4 steps (Z80 `LD A,R`) | 1 px every 4th frame: a straight diagonal | 15b |
| 2 | Salamander breath | one more wind-up pose (10 more frames of warning) | cut | 19 |
| 3 | Cleric summon | one more wind-up pose (+10 frames) | cut | 19 |
| 4 | Ptolemy's spell, rightward | 28 steps, like leftward | last step lost (1 frame shorter; the shrunk version starts a pair late) | 19 |
| 5 | Level-9 power-up timer | 230 ticks (reads the byte after its table) | 256 ticks (reads a 0) | 8b, 23 |
| 6 | Round 19 layout | one continuous log (PCB-confirmed) | 1-cell gap (row 16, col 23) | 20 |
| 7 | Cake rounds' green ball (17 rounds) | mirrored | not mirrored | 20 |
| 8 | Randomness (item roll, Star Tiara stars, intermission bob, ghost) | Z80 refresh register: noise | a counter + vblank: very regular | 15b, 23 |
| 9 | Dracolisk fireballs | MCU line stepper: 3 px a frame, exact pixels, sprite flickers between 2 frames | 4 px a frame on a 4-px grid, no animation | 27, 51 |
| 10 | Colour output | 4-bit levels x 17 (full white = 255) | 6-bit DAC, (c5*2+I)/63 (max ~247) | 20 |
| 11 | Ending text | "...IN YOUR HAND." | no full stop; the copy shown with ORIGINAL music says "THANK YOU **FOI** YOUR BRAVE ACT." | 8, 28 |
| 12 | Title logo | the 1985 TAITO tile logo, "INSERT  COIN<S>" (2 spaces) | the modern TAITO bitmap, "@ 1991 SPS", 1 space | 32 |
| 13 | Ending: jumps for joy | jump sound until the screen goes black (the All Clear music sets the gate) | jump sound throughout | 35, 55 |
| 14 | Intermission priority strips | all 16 columns in one frame | 4 strips over 4 frames | 36 |
| 15 | Enemy AI: column search, target above-left | walks to the column *before* the one found (8 px further) | to the column found | 42 |
| 16 | Enemy AI: column scans | `inc l` / `dec l` wrap inside a 256-byte page (from column 0 of rows 4/12/20/28 the scan jumps 7 rows up) | plain address arithmetic | 42, 43 |
| 17 | Moon night | night music `$0a`, then 240+240+40 frames | `$3f`, 240+240+22 frames | 42 |
| 18 | Night / morning wipe | 34 / 35 frames, tasks resume one frame later | 38 / 38 frames inside one game pass, resume at once | 42, 43 |
| 19 | Horned touch | writes $40 to the end code, clears the killer byte | writes $40 to both (no visible effect) | 49 |
| 20 | Continue | not offered on rounds 99-101 | offered up to round 101 | 30 |
| 21 | Boot screen | solid blue while the sound board boots | the "Now Loading..." picture (`FLS_TTL.DAT`) | 35, 52 |
| 22 | Name entry end (`$04`) | stops the music | a (silent) PCM confirm; music goes on | 37c |
| 23 | Copy protection | MCU state vault, ROM checksums; the MCU serves round values, text and the sway table | removed; the values are hard-coded (same numbers) | 15c |
| 24 | Round build (every round start, warp flashes) | tilemap black 2-8 frames, bottom ROUND line 2-3 frames early, sprites stay | everything black 15-25 frames (lag) | 55 |
| 25 | Warp: a skipped round on screen | 5 frames; the cleared round's enemies stay until an intermission | 7 frames; sprites cleared | 55 |
| 26 | Intermission build / warp intermission | 2 black frames / 49 frames | ~16 black frames / 52 frames | 55 |
| 27 | Dracolisk defeat sounds | $36 stops the music; the first $37 cuts it to silence (sound board) | PCM effects play over the FM music | 55 |

Rows 20-23 aren't controlled by the BEHAVIOUR switch (row 27 follows the MUSIC set: ARCADE). Row 20 follows the port's play MODE (ARCADE / CASUAL). Row 21
follows BEHAVIOUR plus whether a disk is present, and row 22 follows the MUSIC set. Row 23 has nothing for the port to
reproduce. The X68000 always runs at the same game speed as the arcade, but it sometimes misses a vblank and catches
up afterwards (it's lag, not a rule difference; pass 43).

### Checked and identical

These were found identical in both programs, or match frame by frame in MAME for both versions:

- player movement and its tables;
- enemy AI and bodies (apart from rows 15-16);
- Wizard, Cleric and Salamander code and their shots;
- the spell, cakes, crushing and combos;
- items and odds;
- the moon logic (apart from rows 17-18);
- Horned, the Worm, teleport doors, and the Dracolisk's movement;
- graphics (byte for byte) and palettes (same colours);
- round data (apart from rows 6-7);
- scores, extends, EXP and levels;
- the visible area (224 lines, game lines 16-239).

## Sound

| | Arcade | X68000 |
|---|---|---|
| Music | sound board; the port plays the PCB OST recording (13 tracks) | MDRV.X FM, **two soundtracks**: ORIGINAL (songs $02-$18) and ARRANGE ($1a-$30, the X68000 GAME OPTIONS "ARANGE"), with several pieces rewritten (pass 39, 47) |
| Effects | sound board (AY + MSM5232 + DAC, TA7630 tone controls) | ADPCM samples in `PCMDATA.DAT`, lower-quality copies of the arcade sounds |
| Commands | the same command numbers on both: the X68000's table at `$4ee` routes each one to FM or PCM | |

The port plays recorded audio (it doesn't emulate the sound hardware). MUSIC = ARCADE / X68 OG / ARRANGE picks the
music set. Every set uses the arcade effects (MAME 0.289 recordings run through the TA7630 tone model, pass 36-37);
this was the user's decision, since the X68000 samples are lower-quality copies (pass 38). With an X68000 soundtrack,
the round clear and the intermission wait for their jingle to finish, as a real X68000 does (pass 39, 42).

## X68000-only features (not in the arcade)

- A **GAME OPTIONS** menu: lives / ENDLESS, MUSIC ORIGINAL / ARANGE, CONTINUE OFF / ON, DISPLAY 15 / 31 kHz, and
  ENDING ARCADE / X68000. `$3862` is probably the X68000-only ending scene; it hasn't been confirmed or ported.
- **ROUND SELECT** up to the best round reached, saved to Disk 2.
- Keyboard keys: ESC pauses, F1 loses a life, F6 quits.
- Hidden developer messages in MDRV.X (pass 10).

The port's front end is modelled on this menu. CASUAL mode has ROUND SELECT and saves progress; ARCADE mode follows the
arcade's factory DIP settings and is the only mode that records high scores.

## How the port stays version-neutral

The port has to run fully from **either** data source and still offer **both** behaviours. Four mechanisms make that
work:

- **`app/fs/tables.rb` `Tables::ADDR`.** Every table is listed by name as `[X68000 address, arcade address]`, and the
  engine never uses raw addresses. Where the layouts differ (pointer widths, round-record tails, decoration lists,
  palettes, and the arcade's inverted pens), `GameData` converts the arcade data into the X68000 layout at load.
- **`Tables::VARIANTS`.** Small numeric tables that differ (rows 2-5) are carried in both versions' copies. The
  player's own copy is checked against the native one at load, and the other is appended to the image.
- **`Tables::VARIANT_EDITS`.** Tables that differ only by a small edit (the ending text, row 11). The other version's
  copy is **built from the player's own data** by applying the edit, so the game's text isn't copied into the
  source. Checked in all four combinations (disk or ROMs, arcade or X68000 behaviour); each pair renders
  pixel-identically.
- **`Tables::PATCHES`.** Single bytes inside round data (rows 6-7), written per behaviour.

Behaviour code (rows 1, 8, 9, 13-19) checks `w[:behaviour]` in the task that owns it. Small arcade-only constants live
in the code: the MCU's ghost sway steps (`Director::SWAY`), the tile codes of the old TAITO logo, and palette patches.
These are short functional tables, so arcade behaviour works from the X68000 disk too.

**Port bug fixes apply to both versions.** Every fix in the log is in the shared engine code, not tied to a data
source or to one behaviour (e.g. the fireball timing fix of pass 51 was checked on both). Only the 23 rows above
branch on the version.

## Still open

- the step-counter remainder (X68000 keeps the overshoot past 800; check the arcade);
- the Wizard-shrink EXP clamp on the arcade;
- task `$1f`'s role;
- the X68000 `$3862` scene (ENDING = X68000 option?);
- the Dracolisk defeat sound timing (the user hears `$36` "too late"; the code matches);
- Arcade Archives on PS4 (Switch: done, pass 59).
