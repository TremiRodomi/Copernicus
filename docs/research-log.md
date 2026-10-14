# Copernicus research log (passes 1-53)

The complete, chronological working log of the reverse-engineering and the port, kept as it was written. Later
passes CORRECT earlier ones (look for "CORRECTED", "WRONG", "RESOLVED"); the current state of knowledge is
summarised in ../NOTES.md, and the arcade / X68000 differences in VERSIONS.md. Source comments that cite
"NOTES pass N" refer to the pass headings in this file. Addresses: $xxxx = FS.X flat image (text + data from 0)
or a6 work-area offset, as each section says; arcade addresses are main-Z80 unless marked MCU.

# Pass 1: triage (X68000, 1991, SPS/Taito)

## Disk images (all 4 are 1.25MB Human68k FAT12, 1024-byte sectors, 'Hudson soft 2.00' boot sector)
- .hdm = raw image; .dim = 256-byte DIFC header + same raw image
- Disk 1: HUMAN.SYS COMMAND.X AUTOEXEC.BAT (runs FS) FS.X MDRV.X PCMDRV.R PCMDATA.DAT FLS_TTL.DAT BGCHR.DAT SPCHR.DAT
- Disk 2: FS.DAT (36 bytes; looks like a high-score table with 3-letter initials)
- Everything is identical between the HDM and DIM dumps EXCEPT FS.X (6 bytes, below) and FS.DAT (score data).

## FS.X (the game, 72,728 bytes)
Header (offsets from file start): base +4, exec +8, text +12, data +16, bss +20, reloc +24, sym +28
- base=0 entry=0 text=39,930 (0x9bfa) data=30,514 bss=626,692 reloc=2,220 bytes -> 1,110 absolute pointers
- Flat image = text then data at address 0. Relocation targets all fall inside text/data/bss.
- Startup: shrinks its memory block, enters supervisor (IOCS $81), allocates a work area (0x1336 bytes, pointer saved at $1132c),
  hooks vectors $7c (level-7 autovector), $ac/$b0/$b4 (TRAP #11-13), then initialises hardware.
- Only ~12k instructions of code: small enough to fully annotate.

## Two builds of FS.X differ in 6 bytes = two DIFFERENT CRACKS of a disk copy-protection check (resolved in pass 7)
1. text 0x3cd8: HDM `4e92 jsr (a2)` vs DIM `7000 moveq #0,d0`
2. 0xc01f-0xc022 (literal bytes inside the LZSS-compressed protection blob at $c016): HDM `7000 4e75` (moveq #0,d0 / rts) vs DIM `48e7 7ffe` (movem.l)
Neither dump is pristine: original = `jsr (a2)` + intact blob. HDM stubs the check routine, DIM skips the call. See pass 7.

## Decompressor at text 0x3cc2-0x3d40
LZSS, Okumura-style: 4096-byte ring buffer at $89330 (BSS), initial write pos 0xFEE, match len = (b&0xF)+3 (code does +2 then dbra).
Header is 2 longs: first is IGNORED (loaded into d1 then overwritten), second = output size. Full details in pass 4.

## IOCS calls (corrected in pass 7): $02 B_SFTSNS, $04 BITSNS (11x), $0e TGUSEMD, $10 CRTMOD, $11 CONTRAST (fades, NOT a palette call),
$3b JOYGET, $6c VDISPST, $7d SKEY_MOD, $81 B_SUPER, $90 G_CLR_ON, $ae/$af OS_CURON/OS_CUROF (cursor, NOT sound), $c0 SP_INIT, $c1 SP_ON.
DOS line-F calls: $ff23 CONCTRL, $ff48 malloc, $ff4a setblock, $ff4c exit etc.

## Next steps
1. Trace from the startup into the main loop; find the V-sync wait and per-frame update.
2. Map sprite table writes (sprite regs $EB0000+) and BG (pattern/ tilemap $EBC000+/$EB8000+).
3. Work out BGCHR.DAT / SPCHR.DAT / FLS_TTL.DAT formats (they start with palette-like words).
4. Find level data tables (relocated pointers in data seg 0x9bfa+ are the best index).
5. MDRV.X + PCMDRV.R + PCMDATA.DAT = the sound side (music driver + ADPCM samples).

---
# Main loop / architecture (pass 2)

a6 = global game-state block (0x1336 bytes, pointer stored at $1132c). All offsets below are (a6)+off.

## Boot / top level
- $0000 startup -> $1dbc = game main (title / attract / gameplay state machine; returns only on quit) -> $12a shutdown
  (removes vblank hook, `jsr $4ac` with d0=0 stops sound, restores vectors, DOS exit).
- Gameplay loop ~ $2096-$20c2: { $2d8 wait 1 frame; $2268 key check; $7b8; $2976 extra-life check } until $62e==$ff (round over)
  ($5fd&$7f == 0 exits to the round-clear path at $20c4)
- $2d8 = wait 1 frame; $2b2(d1=n, d0=m) = wait n*(m+1) frames. They call $248 each frame.

## Frame structure
- VBlank IRQ (IOCS _VDISPST, handler $1d4): $2e0 BG scroll regs ($e80018..) from shadow ($7e/$82) ; $310 BG/ sprite page update ;
  $386 queued word-copy list at $92(a6) (10-byte entries: count-1, src, dst, terminator $ffff; dst<$e82200 = palette-doubling mode) ;
  $41a input poll ; then frame counter $5c(a6)++.
- $248 = per-frame function called from every wait: (copies scroll shadow $54/$58 -> $7e/$82, sets sprite-flip flag $8a),
  spins until $5c changes (vsync wait), then runs $60c, **$18b6 (task scheduler)**, $1d4e, $574, $60c,
  then ESC-key pause (BITSNS group 0 bit 1: press to pause, press again to resume).
- Input ($41a): joystick (IOCS $3b JOYGET, masked $6f) OR'd with keyboard matrix groups $e,$5,$8,$9 into one byte:
  $62(a6)=held, $88=previous, $66=newly pressed. then calls $2fe8 (probably demo-record/replay hook - unconfirmed).

## COOPERATIVE TASK SCHEDULER  <- the key to the whole game
23 slots x 0x24 bytes at $234(a6) (to $570). Slot layout:
  +0 task id | +1 flags (bit0=allocated, bit7=runnable) | +2 delay counter | +4..+0x1f saved d1-d4/a0-a2 (28 bytes) | +0x20 resume PC
- $1820(d0=id): kill any existing task with this id, find a free slot, set flags=$ff, delay=1, resume PC = table[$b0e0 + id*4].
- $186e(d0=id) KILL (flags=0) | $187a SUSPEND (flags=1: allocated, not runnable) | $1886 RESUME (flags=$ff). Common code $190e acts on the
  FIRST slot with that id only. If a task kills/suspends ITSELF (id == $574 running id) the call does not return: it yields (d0=1).
- $1890 kills every task except the id in $574(a6) ($ff = kill all).
- $18b6 runs once per frame: for each runnable slot whose delay hits 0, restores regs and RTS-jumps to the saved PC.
  A task yields by `bsr/jsr` into $18ea with d0 = frames to sleep: that pops the return address into the slot as the new resume PC,
  saves d1-d4/a0-a2, and moves on to the next slot. => STACKLESS coroutines; nothing may sit on the stack across a yield.
- Consequence for the port: do NOT try to translate to C one-to-one. Re-express each task as a small state machine (or use
  C++20 coroutines / a tiny fiber layer) that keeps the same per-frame timing.

## Task entry table @ $b0e0 (46 entries, id -> code address)
00:03ee0 01:04366 02:04904 03:049d0 04:04bde 05:05586 06:0558c 07:05592 08:05598 09:0559e 0a:055a4 0b:055aa 0c:055b0
0d:05ff2 0e:0605c 0f:06158 10:06a9a 11:06b0c 12:06d94 13:06da0 14:070fa 15:0752c 16:07b6c 17:07bf0 18:07d98 19:07e5a
1a:0801a 1b:0803a 1c:080c6 1d:084ca 1e:08504 1f:08528 20:08556 21:09016 22:092a8 23:092ea 24:086be 25:0896e 26:08b76
27:0947a 28:094b2 29:094fa 2a:09620 2b:0980a 2c:099b6 2d:09a36
- ids 05..0c are 6-byte stubs (probably 8 variants of one enemy type feeding shared code at ~$55b6) - unconfirmed.
- Roles are NOT identified yet; this is the list of every game-object behaviour. Spawn sites are the xrefs to $1820.
  Initial spawns at game start ($2068-$2088): ids 0,4,$10,$14,$e (likely player, HUD, background effects etc.).

## Sprite pipeline
- $1952 = table of pointers to double-buffered sprite shadow lists (select = $60(a6)); each sprite = 8 bytes = X68000 sprite regs: +0 X, +2 Y, +4 attr, +6 prio (3).
  (exact X/Y transform in pass 7: X = (-baseX)&$ff with no +16, Y gets +$11)
- $1a2e clears the 448-long shadow; $1a48/$1ab6 expand sprite-set definitions (rom tables at $10234 / $104f5) into the shadow.
- VBlank copies shadow -> sprite regs at $eb0000+ (see $32c).

## Game state seen so far
- $704 lives (BCD) | $700/$701 score (BCD bytes, compared against extend thresholds $709/$70a; $58c/$58d = increment) -> $2976
  (pass 14: $62e round-end codes: $40 = killed by an enemy (set by $695a), $20 / $10 = other end paths in task 00 - NOT the quit key)
- $62e round-end flag ($ff = done, $40 = quit key) | $5fd round-active counter | $580/$581 mode flags | $591 misc flag bits
- $598 area: PRNG at $598-$5d6 (shift-register style on $4f/$50/$51) -- RNG seed state is at $4f..$53 -- confirm before relying
- Sound: `jsr $4ac` with d0=command (0 stop all, $ee mute, $ef unmute); table at $4ee routes each command to MDRV.X (trap #0) or PCMDRV.R (trap #1).
  (CORRECTED pass 8: $fd is a driver STATUS query, not a fade - see pass 8.)

## Build diff note
- Patch site 1 (text $3cd8, `jsr (a2)` vs `moveq #0,d0`) sits in the LZSS routine's tail; the decompressed code at the caller's buffer is
  executed only in the HDM build. Haven't identified what that blob is.

---
# Task roles (pass 3) - evidence-based, with confidence. Tool: trace_tasks.py <FS.X> <FS_hdm.asm>
Method: per task body (address range to next task entry; tasks share tails so this is approximate) we looked at: input reads, BCD ops,
sound-command calls ($4ac), spawn calls ($1820), yield count, hardware refs, and uses of shared state ($627/$628 etc.).
Spawn graph:  00 -> 01,03,15 | 04 -> 0f,24 | 0c -> 0d | 0f -> 11,16,17 | 11 -> 18 | 13 -> 01 | 15 -> 05,19,1c,1d | 21 -> 0d,22,23,27,29,2a,2b,2c,2d | 23 -> 28 | 26 -> 16
Spawned directly by the state machine (main): 00 01 02 04 0e 10 14 1a 1b 1e 1f 20 21 25 26

| id | role (hypothesis) | conf | evidence |
|----|-------------------|------|----------|
| 01 | PLAYER | high | only task that calls the input decoder $48ca ($62 held-bits -> 4-bit dir/button mask); owns $627/$628 (likely player X/Y); respawned by 13; sound $16 |
| 00 | round/stage director | med | spawned first by main; spawns player(01), 03 and 15; 23 yields; sound cmds 0,$b,$f,$1a,$20,$2a; reads $62e round-end |
| 0c (+05..0b stubs) | enemy family: 8 variants | med | 05..0b are 6-byte stubs that fall into one 2626-byte body at $55b0 (32 yields, chases/tests player pos, spawns 0d); 05 is spawned by task 15 |
| 04 | big gameplay manager (enemy/wave spawner?) | low-med | 2472 B, spawned at game start, spawns 0f and 24, 25 refs to player X/Y, tracks $5fd |
| 0f | large sequence/boss-like object | low | 2370 B, spawned by 04, spawns 11,16,17, sprite set $eb |
| 15 | BONUS ITEM spawner + item effects (pass 8: HIGH) | high | only task with BCD + lives ($704) refs; spawns 19,1c,1d and enemy 05; sound 8 (extra-life jingle) |
| 26 | WORM (invincible door enemy, eats enemies for 7000 or Ptolemy) - confirmed by user + code | high | 3 BCD ops, spawned from main, sound $32 |
| 21 | many-actor scene (ending / intermission / boss death?) | low | spawns 8 different tasks (22,23,27,29-2d) + 0d; sounds $35-$37 |
| 0e,10,14,02,1a,1b,1e,1f,20,25 | init-time / HUD / background / effect tasks | low | spawned from main at game start or state change; small |
| 12,1a,1d,1e,1f,22,27,28 | tiny helper/effect stubs (<=72 B) | low | 1 yield each |

Confirmed vs guessed: only 01 (player) and the 05..0c enemy-family structure are solid. Everything else is a hypothesis to test.
BEST WAY TO FIRM IT UP: run the game in an X68000 emulator with a debugger (e.g. MAME's x68000 driver; needs a BIOS you supply)
and watch the task table: read the pointer at RAM $1132c (low-RAM address of the state block after relocation) then dump 23x36 bytes at
block+$234 each frame. The id bytes alive during play (enemies on screen, boss, bonus screen) label every task directly. Also set a
write watchpoint on the sprite shadow to see which task draws which sprite code.

---
# Graphics data formats (pass 4)
Tools: fs_lzss.py (decoder), render_gfx.py (title), sheets.py (tile/sprite sheets). All three *.DAT files use the SAME container:
  u32 (unknown; maybe checksum) | u32 decompressed size | LZSS stream
Decoder = routine at $3c86/$3cdc in FS.X. Verified: each file consumed 100% of input and hit the exact declared size.
LZSS details: ring 4096 B, write pos starts $FEE, pre-filled with the LZHUF dictionary (13 copies of each byte 0..255, then 0..255, then 255..0,
128 zeros, 110 spaces = 4078 = $FEE bytes); flag byte LSB-first, 1 = literal; match = b1,b2 -> pos = ((b1&$F0)<<4)|b2, len = (b1&$F)+3.
Callers of the loader (for finding destinations): $fa2, $1002, $1020. File names are at data $a3b0..; MDRV.X/PCMDRV.R names at $a3d0/$a3d7.

| file | decompressed | format | status |
|------|--------------|--------|--------|
| FLS_TTL.DAT | 524,288 | 512x512 GVRAM, 16-bit words GGGGG RRRRR BBBBB I (GRB555+I), big-endian | CONFIRMED - renders the title/"Now Loading..." splash perfectly |
| SPCHR.DAT | 98,304 | 4bpp sprite patterns, 16x16 = 128 B = four 8x8 blocks in order UL, LL, UR, LR; each block 8 rows x 4 bytes (hi nibble = left pixel) | CONFIRMED - 768 recognisable sprites/font/"BONUS" text |
| BGCHR.DAT | 131,072 | one byte per pixel, values 0-15 (16 colours). First 0x2000 bytes = 8x8 tiles (64 B/tile): ASCII font. Later regions look like 16x16 tiles (256 B, same UL/LL/UR/LR block order) | PARTIAL - exact section boundaries unknown |
- Palettes are NOT in these files (the scripts use placeholder colours). They're probably in FS.X's data segment; the early
  values seen in the raw files' prefix are LZSS, not palette. Look near the loader call sites ($fa2/$1002/$1020) for GPALET/TPALET setup
  (NOTE pass 7: IOCS $11 is CONTRAST, not a palette call - palettes are written directly, see pass 5).
- Note: SPCHR at 96 KB is larger than the 32 KB X68000 PCG area, so the game must bank/copy parts of it at runtime; the sprite-set tables at
  $10234 / $104f5 (see $1a48/$1ab6) are the index into it.

Next steps: read the loader at $f5e-$1050 to learn which byte ranges of each file are copied where (that settles the BGCHR sections and the sprite banking),
and find the palette tables.

---
# Loader + memory map + palettes (pass 5)   (BSS base = text+data = $1132c; $1132c itself holds the a6 pointer)
## Load sequence ($f5e-$1050)
1. Title: FLS_TTL.DAT read to $29330 (temp), LZSS -> GVRAM $c00000 (512x512 GRB555+I). Shows "Now Loading..." while the rest loads.
   (video reg $e82600 bits masked off during the write, restored after; IOCS CRTMOD $10c = 512x512 mode.)
2. MDRV.X and PCMDRV.R are EXECUTED with DOS exec ($ff4b, mode 0, empty cmdline at $a3e0) -> they are resident (TSR) sound drivers.
3. SPCHR.DAT -> read at $69330 -> LZSS -> $11330 (96 KB = 3 banks x 32 KB; banks at $11330, $19330, $21330).
4. BGCHR.DAT -> read at $69330 -> LZSS -> $29330 (128 KB). Then $eb2 is run on $29330 and $39330 (two 64 KB halves).
- File reader $103e: DOS open ($ff3d) / read up to $80000 bytes ($ff3f) / close ($ff3e); a0 = filename, a1 = buffer.
## BSS map
$11330-$29330 SPCHR (3 banks) | $29330-$a9330 BG tile cache, 4 planes x 128 KB (see below) | $69330 load buffer (reused) | $89330 LZSS ring (4 KB, reused)
BSS ends at $aa330 ($1132c + 626,692).
## $eb2 = BG tile cache builder (8-bit tile pixels -> 4 variants, each 0x20000 apart)
 for every source byte b (0-15):  plane0 = b<<1 (normal order)  plane1 = b<<1 (reversed within each 8-pixel row = H-flip)
                                  plane2 = (b<<1)|(b!=0) normal  plane3 = same, reversed.
 CORRECTED (pass 7): gameplay runs the graphic screen in a 256-COLOUR mode (CRTMOD $10b-$48(a6)); movep writes only the low byte of each GVRAM
 word = a palette INDEX. So BG pixel index = 2*b (even entries) or 2*b+1 for nonzero b (odd entries): two 16-colour variants interleaved in the
 64-entry set loaded by $28ae. It is NOT a GRB555 intensity bit (that format only applies to the 65536-colour title screen).
 Rows are 8 pixels wide, so the BG unit is an 8x8 tile even in the 16x16 sections; BG is drawn into the GRAPHIC screen (GVRAM), not the PCG BG plane.
 BG tile blit helper: $eee (uses movep.l into $c00000+; 24 rows x 4 words), tile table at $9c30. Other BG users of the cache: $b8a, $d14.
## Sprites: PCG streaming ($1cc0, called each vblank from $310 when $8a(a6) is set)
 For the first 32 entries of the current shadow list ($1952[ $60(a6) ], 8-byte entries): word at +4 = attribute.
   attr & $30ff is cached at $134(a6) (change detection); if changed, copy a 128-byte pattern into PCG RAM $eb8000 + n*128.
   bank = attr bits 13..12:  (bit13=0) -> $11330 (bank 0) | 10 -> $19330 (bank 1) | 11 -> $21330 (bank 2); pattern = attr & $ff (256 per bank) -> *128.
   Other attr bits are standard X68000 sprite bits: 15 = V-flip, 14 = H-flip, 11..8 = palette block.
 => The game has 32 "dynamic" sprites whose patterns are streamed from the 3 SPCHR banks each frame.
## PALETTES (all words GRB555+I; table offsets are flat-image/data-segment addresses; tool: palettes.py)
 $ba80  sprite/text palette, 16 blocks x 16 colours (512 B) -> $e82200      loader: $2876
 $ba00  64 words                                          -> $e82080      loader: $288e
 $b600 + n*128 (n = 0..7)  graphics palette sets, 64 words each -> $e82000  loader: $28ae(d0=n), current set kept in $6c(a6) (n=4 at boot)
 $b5ea  list of (offset,value) palette-entry patches ($28d6); $28f6 same for a caller-supplied base.
 Palette writes are queued via $3e6 and applied in the vblank handler ($386) so they never tear.
 Palette blocks verified visually: SPCHR rendered with block 0 gives correct-looking red-hat fairies, enemies, a grey dragon, items.
## Sprite-set (metasprite) table - next target
 $1a48 expands "sprite sets": entries of 5 bytes at $10234 + idx*5 (a second table at $104f5 for $1ab6): [slot?, y offset, attr_hi ^ $c0, pattern code, next-index (0 = end)],
 written into the shadow list with prio 3. This is how multi-part characters/bosses are composed - decode it to get the full list of characters with their real palettes.

---
# Metasprite tables + true sprite palettes (pass 6)   tool: metasprites.py
Five sprite-set expanders write 8-byte shadow entries (x, y, attr, prio=3); table formats (hi = byte ^ $c0 -> V-flip b7, H-flip b6, bank b5-4, palette b3-0):
| expander | table | entry | count | layout |
| $1a48 | $10234 | 5 B | 141 | slot, y, hi, code, next |
| $1ab6 | $104f5 | 4 B | 253 | y, hi, code, next (x = caller's) |
| $1b22 | $108e9 | 4 B | 144 | y, hi, code, next |
| $1b8e | $10b29 | 6 B | 243 | slot, y, hi, code, xoff, next |
| $1c44 | $110db | 4 B | 253? | y, code, x, next - attr hi comes from CALLER register d7 (so palette is set in task code) |
 $1bfe = write one sprite with attr hi in d3 (task code supplies the palette). "next" = index of the next entry in the chain, 0 ends it.
 Caller passes d1 = base Y, d2 = base X, d0 = set index. ($1a48: the per-entry 'slot' byte is a shadow offset/2, i.e. slot*4.)
 Shadow X = (-d2)&$ff (no per-entry X in $1a48), Y = ((~d1 + yoff - ($591&2)) & $ff) + $11. $591 bit1 shifts Y by 2 px, it is NOT a mirror flag.
Palette coverage: tables A-D give a palette block for 501 of 768 patterns (blocks seen: 0,1,2,3,4,5,6,7,8,12,13,14); 13 patterns appear with 2+ blocks.
Remaining patterns (e.g. the big dragon, some enemies) get their palette from caller code ($1c44's d7, $1bfe's d3, or direct attr writes in tasks).
With the table palettes applied, lizards (bank 0) and the worm/caterpillar (bank 2) come out GREEN as they should; stone statues/gargoyles are grey as expected.
Unresolved patterns render dim grey in banks_true.png - their palettes need to be traced from the task code.

## Dracolisk palette (confirmed by user: "purple")
Dracolisk's patterns are in SPCHR bank 2 (roughly pattern rows 6-13 of the 16x16 grid, codes ~$60-$d0). They are not in the 4 self-describing metasprite tables,
so the palette comes from task code. Their dominant colour index is 11, which is palette block 3 idx 11 = $07bd (R30 B30, bright magenta/purple); block 3 also gives
yellow spikes (idx 3 = $f781) and red mouth (idx 8). Blocks 14/15/1/13 render it dark red / black-pink / red / orange - wrong.  => Dracolisk = sprite palette block 3 (bank 2).
Code hints for the boss draw call to confirm later: callers that set attr hi with bank 2: d3=#$f1 ($6006,$611c,$6898 - pal 1), #$fe ($46f0,$5a56,$914c/$9198/$91d0 - pal 14), #$ff ($87d6 - pal 15).
(attr hi byte is stored ^$c0, so pal 3 / bank 2 would appear as #$f3 or be built arithmetically). Palette-block overrides for unresolved patterns should be kept in a table in the port.

---
# Audit (pass 7, 2026-10-10) - everything above re-checked against the binaries
Re-extracted all 4 images (file list/sizes match), regenerated both .asm files (byte-identical to FS_hdm.asm/FS_dim.asm), re-decoded the 3 .DAT
files (exact sizes, 100% of input consumed), and re-read the code for every claim. Wrong claims were corrected in place above.
Verified OK: .X header/relocs (1,110 long relocs, no word relocs, no long escapes), LZSS + ring dictionary, loader/memory map, scheduler layout,
task table (exactly 46 relocated longs at $b0e0), palette loaders/addresses, PCG streaming, $eb2 cache layout, metasprite table sizes, Dracolisk colours.

## Copy protection (the 6-byte build diff)
- $3cc2 = "load with check": if $72(a6)==0, first LZSS-decode the 220-byte blob at $c016 INTO THE CALLER'S DESTINATION (e.g. GVRAM for the title),
  `jsr` it, `move.b d0,(a5)+`, then decode the real file over it. Called from $fa2/$1002/$1020; only the first caller sets a5 = a6+$72 ($f98),
  so the three results land in $72/$73/$74 and `tst.l $72(a6)` sees a failure from any of them.
- Blob (DIM build has it intact): IOCS $40 B_SEEK / $4c read on drive $90 expecting status $0400004d (a deliberately bad sector), then $46 B_READ
  of a 1024-byte sector expecting status $4420204c, then a rolling checksum over it that must equal $4a7d3e7a / $a2a062a2. Pass -> d0=0, fail -> d0=$ff.
- Penalty: once $72 != 0 the check is skipped, and at $3024 `addq.b #1,$57c(a6)` is skipped (role of $57c still unknown: covert sabotage).
- HDM crack: blob starts `moveq #0,d0; rts`. DIM crack: `jsr (a2)` -> `moveq #0,d0`. Both behave identically (always pass).
- PORT: ignore entirely; behave as if $72(a6) == 0 forever.

## Scheduler details that matter for exact timing
- A yield with d0=0 means 256 frames (delay byte is decremented before the test). $18b4 is an alternate yield entry (bra $18ea).
- New tasks get delay=1: a task spawned into a slot AFTER the current one runs the same frame; into an earlier slot, next frame.
- $1820 fails silently if all 23 slots are busy. $46(a6) != 0 freezes the whole scheduler.
- On resume a task gets d1-d4/a0-a2 back; also a5 = its slot, d2 = its id. d0, d5-d7, a3, a4 are NOT preserved across a yield.
- A task must never spawn its own id ($1820 kills the old instance first, which would yield from inside $1820 with its stack frame still pushed).

## Screen modes
- Title: CRTMOD $10c (512x512, 65536 colours) -> GRB555+I words. Gameplay: CRTMOD $10b - $48(a6) ($48 cleared at boot; likely 15/31 kHz choice):
  256x256, 256 colours. Mode numbers are from memory of the IOCS table, not from a reference here, but they fit the code.
- Graphic palette entries 0-63 = set n ($b600+n*128, $28ae), 64-127 = fixed table $ba00. $b5ea patches are offsets into the SPRITE/TEXT palette ($e82200).
  CORRECTED pass 12: WRONG - the vblank copier ($386) DOUBLES every write below $e82200 (word j -> entries 2j and 2j+1 at offset*2), so set n
  fills entries 0-127 and $ba00 fills 128-255. See pass 12.
- Sprite X coordinates are stored negated (X = (-x)&$ff): the game's internal X axis runs right-to-left (probably inherited from the arcade's flipped screen).
  Confirm before relying on it.

## Disassembly caveat
- `bsr $930` is followed by an INLINE string (print routine). FIXED in pass 8: disasm.py now emits these as `dc.b` (see pass 8).

## Tooling notes
- Extracted files now live in fl_files/{hdm1,hdm2,dim1,dim2}/ (gitignored); decoded data in fl_files/dec/.
- capstone is in user site-packages, which `python3 -I` hides. Use `python3 -P -E` (cwd/script dir still kept off sys.path) for disasm.py.
- render_gfx.py / sheets.py now take paths as arguments (they used to hard-code /home/claude/fl_dec).
- The project directory is NOT a git repository yet.

---
# Sound command catalogue, options menu, disasm fixes (pass 8, 2026-10-10)
Full table: **sound_commands.csv** (cmd, driver, MDRV song # for ORIGINAL and ARRANGE, call sites, trigger, confidence). Tool: sound_calls.py.
69 call sites (68 `jsr $4ac` + 1 that was hidden by disassembly desync at $7a40) + 5 `jsr $56c`. Cross-checked against the relocation table (69 relocs -> $4ac).

## Dispatcher $4ac (d0 = command)
- $44(a6) set = MUTED: every command is ignored except $ef. $ee = stop FM + stop PCM + set mute. $ef = clear mute (does NOT restart music).
- 0 = stop both drivers (trap #0 d0=0, trap #1 d0=0) and clear $45. Commands >= $40 are ignored.
- table $4ee[cmd]: $ff -> PCMDRV.R (trap #1, d0 = cmd unchanged = ADPCM sample number);
  otherwise -> MDRV.X (trap #0, d0 = table value + $47(a6)) = FM song number.
- PCMDRV.R installs trap #1 itself (DOS INTVCS, vector $21); so by elimination MDRV.X = trap #0 (FM music + FM jingles).
- $45(a6) = "PCM $21 locked": cmd $21 sets it; while set, every PCM command except $01 is dropped; $01 clears it and plays.
  $574 (called each frame from the main loop at $26e) re-sends $21 whenever PCMDRV's status query ($fd) says something else is playing => $21 is a
  looping sample. Started by task 19 ($7ec2), cancelled by task 19 ($7f34).
- $56c = send $fd to MDRV, return d0 != 0 while the FM song is still playing. All 5 callers loop on it = "wait for jingle to end".
  (Earlier note "$fd fade" was WRONG.)
- FM routing: cmds $06-$15 -> songs $02-$11 except $07 -> $17; $30 -> $18, $31 -> $13, $38 -> $14, $3f -> $15.
  PCM ids: $01-$05, $16-$2f, $32-$37, $39-$3e. Ids with no call site (e.g. FM $0e) are left out of the CSV.
- PORT: the engine keeps the command numbers as event ids; a data file maps cmd -> {arcade track | X68 ORIGINAL | X68 ARRANGE} for FM ids and cmd -> WAV for PCM ids.
  Reproduce mute ($ee/$ef), the $21 loop lock, and "wait until jingle finished" ($56c) as audio-engine queries.

## Music selection = GAME OPTIONS menu (strings now visible in the asm, $348e..$3642)
  LEFT (lives) / ENDLESS | MUSIC ORIGINAL / ARANGE ($47(a6): 0 / $18, toggled by `eori.b #$18` at $36f6 -> FM song + $18 = arranged set)
  CONTINUE OFF/ON ($578 bit 3) | DISPLAY 15KHZ/31KHZ ($48(a6), the CRTMOD $10b-$48 choice) | ENDING ARCADE/X68000 ($578 bit 1)
  So MDRV holds two song sets: ORIGINAL = $02-$18, ARRANGE = $1a-$30. The user will supply both X68 OSTs + the arcade OST as selectable canned audio.

## Round music + flow facts that fell out of this
- Round BGM ($262a): round $703 < $31 -> cmd $07; $31..$63 -> $30; >= $64 -> $12. ($703 is binary, 0-based: $64 = round 101 = final.)
  Restart variants after an interruption: $09 (rounds < $31) / $31 (later), task14 $736c and item handler $795a.
- Round clear ($20c4..): cmd $0c unless warping; at round >= $64 goes to the ending ($3722, cmd $13). Next round = $703 + ($653 & $7f) + 1.
- $653 = rounds to skip (warp). Set only by the warp item (task 15 handler, sprite $60): $653 = remaining enemy count $5fd, or $80 if round >= $5b (91),
  then $5fd = 0 ends the round. Sound $2c on pickup, $2b on warp.
- Intermission ($2818): after rounds 7, 14, 21, ... ((round-7) % 7 == 0), index (round-7)/7 -> $1554 draws it and task $25 runs it; FM cmd $0d.
  Also shown in attract mode when $578 bit 4 is set ($27c4, index $e).
- Coin ($30ee): unmute, wait for FM idle, cmd $06, wait. Attract mode is silent ($ee at $1e78) until a coin or game start ($ef at $1f90).
- Boot: cmd $14 then wait for it to finish ($1e24/$1e32), then stop + mute for attract.
- Ending text ($37b6): two copies at data $be2d / $bd7a. With MUSIC = ORIGINAL the game shows the copy that says "THANK YOU FOI YOUR BRAVE ACT."
  The user confirms the ARCADE text says "FOR" -> this is an X68000-only typo. PORT: always use "FOR".

## Task 15 = bonus items (confidence HIGH)
 $7534: picks an item. Index = f(round group via $c8d8 thresholds on $57f, RNG $58c via table $c8de, enemies-left $5fd via $c902), then
 pointer table $c90e (18 handlers). Each handler starts with dc.w <item sprite code> followed by code. The item is drawn at ($650,$651) and waits
 up to $95 x 6 frames; picked up if |player X $627 - x| < 12 and |player Y $628 - y| < 8 -> cmd $27, $652 = $c905[$705], jump to handler.
 Handlers (sprite code -> address): $5b $765c | $74 $769e | $76 $79d0 | $5c $76f0 | $63 $7a00 | $62 $7964 | $5e $7832 | $5a $7684 | $75 $76aa |
 $59 $7826 | $5d $7704 | $61 $7846 | $77 $7a22 | $60 $7af6 | $78 $7a3c. Known: $77 = +1 life (cmd $08), $60 = warp, $5e = $705++ (capped at 8),
 $61 plays FM cmd $0a (timed effect music?), $62 restarts the round BGM. Item names: SOLVED below (pass 8b).

## disasm.py improvements (both .asm files regenerated; builds still differ only at $3cd8)
- inline strings after `bsr $930` -> `dc.b "...",0` (79 strings: HIGH SCORE, GAME OPTIONS, staff names, enemy names PTOLEMY/ORC/CLERIC/GOLEM/
  WIZARD/SALAMANDER/WRAITH ...).
- `move.w T(pc,dN.w),dN / jmp T(pc,dN.w)` word jump tables decoded (2 found).
- Every relocated pointer into text is treated as an instruction start (resync), and the $c90e item handlers get their leading word as data.

---
# Hidden EXP/level system + item drops (pass 8b) - CONFIRMED identical to the arcade
Source: user-supplied arcade notes (TCRF "Notes:The Fairyland Story (Arcade)", pasted by the user - DO NOT fetch TCRF ourselves).
Every X68000 table below matches the arcade values byte for byte, so the X68000 port reuses the arcade logic/data.
| state | meaning |
| $57f(a6) | EXP (0..239). Set to 0 at game start ($1fdc) and ... at $2434 (respawn/continue: check against "EXP = round-1 after death") |
| $706(a6) | EXP needed for the next level (+30 per level-up) |
| $705(a6) | LEVEL, 0-based (0 = level 1). Normal cap 7 (= level 8); Holy Water cap 8 (= level 9) |
| $707/$708 | step counter (lo/hi), task 00 $3f60: += |player dX| per frame while $59b == 0; at >= 800 subtract 800 and spawn task 15 (item) |
| $59b(a6) | active power-up state (0 = none; Silver Scepter sets 1; 8 = moon? - check) |
| $652(a6) | power-up timer = $c905[level]; long items tick every 6 frames, short ones every frame |
- $6854 add-EXP (d1 = amount): new = EXP+d1; if >= $f0 return (no overflow check on the add itself, as in the arcade). If new > $706: $706 += 30
  (stop if it carries), and if level < 7, level++.  Crystal Ring handler = `moveq #40,d1; bsr $6854`.
- Item choice ($7534): bracket = first i with EXP < $c8d8[i] (21,41,71,111,161,255); odds table $c8de + 6*bracket (cumulative /128):
  [102,115,120,124,127,128] [1,103,116,121,125,128] [1,4,106,119,124,128] [1,4,8,110,123,128] [1,4,8,13,115,128] [1,4,8,13,26,128];
  roll = RNG ($58c) & $7f -> tier; group = (enemies $5fd - 1) vs $c902 [1,4,255] -> 1 / 2-4 / 5+; handler = $c90e[tier*3 + group].
| idx | tier/group | sprite | handler | item | sound |
| 0,1 | T1 1 / 2-4 | $5b | $765c | Silver Scepter | |
| 2   | T1 5+      | $74 | $769e | Moon Tiara | |
| 3,4 | T2 1 / 2-4 | $76 | $79d0 | Magic Staff | |
| 5   | T2 5+      | $5c | $76f0 | Scroll of Fire | |
| 6,7 | T3 1 / 2-4 | $63 | $7a00 | Mystical Orb | |
| 8   | T3 5+      | $62 | $7964 | Glass Potion | restarts round BGM ($09/$31) when it ends |
| 9   | T4 1       | $5e | $7832 | Holy Water (level+1, cap 9) | |
| 10  | T4 2-4     | $5a | $7684 | Gold Scepter | |
| 11  | T4 5+      | $75 | $76aa | Star Tiara | |
| 12  | T5 1       | $59 | $7826 | Crystal Ring (+40 EXP) | |
| 13  | T5 2-4     | $5d | $7704 | Scroll of Ice | |
| 14  | T5 5+      | $61 | $7846 | Change Potion | FM $0a |
| 15  | T6 1       | $77 | $7a22 | Book of Life (+1 life) | FM $08 |
| 16  | T6 2-4     | $60 | $7af6 | Mystical Feather (warp: skip $5fd rounds, or $80 flag at round >= 91) | PCM $2c, then $2b |
| 17  | T6 5+      | $78 | $7a3c | Book of Death | PCM $2d |
- Timer table $c905 = [60,80,100,120,140,160,180,200, 0]. ARCADE DIFFERENCE (port tweak candidate): at level 9 the arcade reads past its 8-entry
  table and gets $E6 = 230; the X68000 reads the 0 that sits after its table, and since the countdown is `subq; bne` that means 256 ticks
  (long items 1536 frames vs arcade 1380; short items 256 vs 230). For arcade accuracy use 230 at level 9.
- Step counter remainder: X68000 subtracts 800 (keeps the overshoot); check the arcade (TCRF says "after walking 800 pixels"); minor.
- Confirmed in X68000 code:
  * game start / continue ($1fc6-$1fe4): level $705 = 0 (level 1), EXP = $703 (0-based round = "round - 1"), $706 = 29 (level-up when EXP > 29 = 30).
  * killed by object type $57 (= Wraith) at $69b4: level - 1, floor level 1.
  * Wizard shrink at $6e86: EXP - 10, CLAMPED at 0 (arcade: check whether it clamps).
  * enemy kills: 12 callers of $6854 with d1 = 1; crush path $82ee doubles d1 (= 2 EXP); $6d38 passes a variable amount (check).
  * $2434 sets EXP = 0 (path not identified yet - attract/demo start?).
- STILL OPEN: the arcade "EXP = round-1 after dying" reset - no write of $703 -> $57f found outside game start/continue. Either the death path
  re-enters $1fd8-like code via another route, or the X68000 differs. Check in an emulator or trace the respawn path in task 00.

---
# Arcade ROM (MAME set flstory.zip, user-supplied, pass 9)
Extracted to fl_files/arcade/ (gitignored). Files: cpu-a45.15/.16/.17 = main Z80 program, 3 x 16 KB, concatenated = Z80 $0000-$BFFF;
a45-20.mcu = 68705 MCU (2 KB); snd.22/.23 = sound Z80 (2 x 8 KB); vid-a45.06-.09, .18-.21 = graphics (8 x 16 KB);
bootstrap.bin (115 B) = 6805 code, the MCU-dump bootstrap some MAME sets carry - not part of the game.
Verified: TCRF arcade addresses are main-Z80 addresses in that concatenation. $488d EXP brackets, $4893 odds tables, $48b7 enemy groups and
$48ba timers are byte-identical to the X68000 tables ($c8d8/$c8de/$c902/$c905); the arcade byte after its timer table is 230 (= its level-9 timer).
Use the ROM to settle arcade-vs-X68000 questions directly (open: EXP reset on death, Wizard-shrink clamp, step-counter remainder).
- a45-20.mcu = Taito's 68705 PROTECTION MCU, which also runs part of the GAME LOGIC on the arcade (user). So some X68000 routines will have
  no Z80 counterpart: the matching arcade logic lives in the MCU program. When comparing, check both the Z80 ROM and the MCU.

## Sprite viewer (pass 9)   tool: sprite_viewer.py <FS.X> <SPCHR.DAT.dec> <out.html> [labels.json]
- Writes one local HTML page (fl_files/out/sprites.html - embeds game graphics, keep local) drawing all 768 patterns client-side with switchable
  palettes. Click a pattern -> pick its palette / type a name; "Export" saves labels.json, which the script reads back and which becomes the
  port's palette/name override table.
- Palette sources: metasprite tables (pass 6), items (bank 1, attr hi $ed -> palette 13, drawn by $7b52 via $1bfe), Dracolisk guess (bank 2
  $60-$d0, pal 3). 629/768 resolved; the rest render dimmed.
- Items VERIFIED visually: bank 1 codes $59-$5e,$60-$63,$74-$78 in palette 13 are exactly the 15 named items of the drop table (pass 8b).

---
# Round data + background renderer (pass 10)   tool: level_render.py <FS.X> <BGCHR.DAT.dec> <outdir> [round ...]
- $1114 round setup: round $703 (0-based) -> pointer table $cd86 (100 longs); round 101 ($703 == $64) takes a separate path $1676.
- Record: [theme byte -> $593] [100-byte solidity bitmap: 800 bits MSB-first = 32 x 25 cells, bit k -> screen row 5 + k/32, col k%32]
  [door pair: 0, or 4 bytes x1,y1,x2,y2 (game coords) -> same block drawn at both, task $20 runs it]
  [item X, item Y -> $650/$651 = BONUS ITEM SPAWN POINT, 1 unused byte, deco selector ($1544[t-$11], = theme)]. Records are back to back.  Themes: 0 x41, 1 x23, 2 x17, 3 x19 (bit 7 = special attr $5a variant).
- Background = generated, not stored: per-theme fill (theme 0/2 one tile, 1/3 a repeated 2x4/2x2 block), bitmap cells get one tile,
  autotile $133e (4-neighbour mask -> tile via (mask,tile) pair tables $a87d/$a867/$a84b, 0-terminated + default; theme 0 has none),
  decoration lists $152a (word attr, long screen pos, long block ptr), floor edge $14be, drop shadows $1478 (+1/+2/+3 on empty cells next to solid).
- Screen map: 32x32 cells, cell i tile at $1334-2i(a6), attr at $1335-2i. attr: bits 7-6 BGCHR bank (256 tiles x 64 B), bit 5 odd colour variant,
  bit 4 set = normal rows (clear = V-flip), bit 3 set = normal (clear = H-flip), bits 2-0 palette group (x32). Colour = group*32 + 2*pix (+1 odd).
  Rounds use the first 64 KB half of BGCHR ($591 bit 4 selects the second half elsewhere). Screen position words $cXXX: map ptr = $b37 + (P-$c000).
- Game coords are rotated 180 degrees from the screen ($86a4: pos = $c083 + (y&$f8)*8 + (x&$f8)/4): Y grows upward, X grows leftward.
- VERIFIED: rendered rounds 1-10 look right (round 1 = the inverted pyramid in the sandstone castle; theme 1 dark/orange; theme 2 pink/green).
  Remaining artefact: the $646 clear pattern copies 8 longs from $6e4, which starts with an `rts` opcode ($4e75) -> tile $4e attr $75 every 16 cells;
  it uses palette group 5 (never loaded) but only survives in HUD/border rows the text layer covers. Port: clear to tile 0 instead.

---
# Dev notes / hidden text (pass 10)
- MDRV.X $b038 (Shift-JIS, never printed): "Since there's no staff roll, here are messages from the authors":
  * Tonpo (music program): "The ZX-11 Ninja's great, but so is the FZR-1000..." (motorbikes)
  * Bonkura (music arrangement): "I wonder how many people noticed the QY10 patterns? Mikiyo Ohno is great too, uhyohyohyo"
    (QY10 = Yamaha's pocket sequencer: the ARRANGE soundtrack apparently uses its preset patterns)
  * Kasairyuu "Pyroclastic Flow" (main program): "Me? Nothing in particular..."
- FS.X data starts with "Fairyland Story for X68k v1.00". MDRV.X = "X68k Music driver Ver 1.03", PCMDRV.R = "X68k PCM Driver Ver 1.05",
  "PCM driver for Fairyland Story" (/m keep data in memory, /r unload).
- The X68000 staff names (K.ISHIDA ... YOUGA) and enemy cast names are the ARCADE's credits verbatim (same strings in cpu-a45.16 $23bc-$25ea).
- 14 intermission messages ("WELCOME TO THE FAIRYLAND !", "BE CAREFUL FOR "WORM" !", "WHAT IS "DRACOLISK" ?" ...) at FS.X data $ad02+; the arcade
  has them in the Z80 ROM ($7533+). Arcade ending + continue text live in the 68705 MCU ($20b-$31f) - confirms the MCU holds game data/logic.
- Arcade Z80 self-test strings: BAD ROM / BAD HW / BAD SOUND PCB / BAD IO (cpu-a45.17 $3dfd).

## Enemy placement (pass 10b) - table $cf1e (100 pointers; loader $253e; round 101 instead spawns task $21 with $5fd = 1)
 Entry: [speed byte -> $5fe] [count] count x [type, x, y] (game coords). Entries overlap/share bytes between rounds.
 Each enemy -> 12-byte object slot at $59d(a6)+12k: +0 state $20, +2 type, +3 task id (5,6,7..), +6 x, +7 y, +9 sprite shadow slot ($c+8k).
 $5fd += 1 per enemy (enemies remaining). If $612 is set, the first Wizard's task id is stored there (shrink-spell bookkeeping).
 Types = base index into the $1ab6 metasprite table ($104f5), 29 frames each (walk/attack 0-17, petrify+crumble 18-26, ice block, alt pose, cake):
   Task roles now known: $26 = WORM (was "results/bonus?" in pass 3), $15 = bonus items, $20 = round-record block pair (role TBD).
   $00 Orc (from round 1) | $1d Salamander (6) | $3a Golem (9) | $57 Wraith (12) | $74 Cleric (13) | $91 Wizard (4)   - verified from sprites.
   $ff = ARCHED DOOR object (12 rounds: 15 22 29 30 31 51 56 59 64 73 79 88): pos -> $6f5/$6f6, 3x2 block $b532 (theme 2: $b53a) drawn via $728,
   task $26 runs it.  ROLE (user): this is the WORM's lair. The Worm is invincible and only emerges when Ptolemy is in front of the door;
   it eats enemies (7000-point bonus) and can also eat Ptolemy. Code: $6f8(a6) = what it ate (4 = Ptolemy -> $8d5c stop sound, kill tasks,
   eaten sprites $74/$70); otherwise $8ec6 awards score-table entry $a = 7000 at the door ($6f5/$6f6).
 Speed byte $5fe reloads frame divider $600 (decremented every frame in $2b2); enemy code stalls one frame whenever $600 == 0,
 so enemies move $5fe out of every $5fe+1 frames. Values: 3 (round 1) .. 10 .. 255 (most rounds from 79). Magic Staff ($79d0) sets 1 for its
 duration (half speed); hurry-up ($4e4e) sets $ff.
 Door pairs from the round record (task $20): e.g. round 11 (224,152)/(16,152) at the two side walls, round 27 (16,24)/(224,24). ROLE: ask user.
 level_render.py now overlays enemies (frame 0), $ff doors and the item spawn point; all 100 rounds render (fl_files/out/rounds.png, rounds.txt).

## Score routines
 $8fe4 add score: d4 = low BCD byte, d3 = middle, (d2 ignored); score = 3 BCD bytes $700-$702, saturates at 999999; the display appends a fixed "0".
 $6a44(d0 = idx, d2/d1 = popup x/y): table $c800, 3 bytes/entry [lo, mid, popup sprite]: idx 0 = 0100 (1000 pts), 1-9 = 10..90 (100-900 pts),
 $a = 0700 (7000 pts, Worm). $6a04: table $c7f4 = words 0200/0400/0800/1600/3200/6400 (2000..64000: doubling chain bonus - check).

## Round 101 (pass 10c) - $1676, rendered by level_render.py (build_final)
 Hand-built, no round record: sets $591 |= $18 (bit 4 -> BG cache from the SECOND 64 KB half of BGCHR = the final room's tile set), theme $ff,
 palette set 5. Blocks: $af09 / $af97 drawn normally (attr $5a) and mirrored ($17b6 lays a row right-to-left, attr $52 = H-flip) to make a
 symmetric room; 14 x $b033; solidity bitmap $b07b (tile $ed) + autotile $b075; 15 x $b039 + $b041 + $b045 (attr $1b, mirror $13); floor edge.
 No shadows pass. Result: the pharaoh-statue throne room with jackal guardians, arch and stairs. Enemy setup: $253e spawns task $21
 (Dracolisk fight) with $5fd = 1 instead of reading $cf1e.
 BGCHR layout therefore: bytes $00000-$0ffff = rounds 1-100 tile set (4 banks x 256 8x8 tiles), $10000-$1ffff = final round set.

---
# Port: DragonRuby milestone 1 (pass 11)
- Engine: DragonRuby 7.23 (user's SDK in dragonruby-linux-amd64/, not committed); game in dragonruby-linux-amd64/fairyland/.
- Loader reads the player's Disk 1 image (.hdm/.dim, FAT12 root dir) or loose FS.X/BGCHR.DAT/SPCHR.DAT from fairyland/data/; LZSS-decodes
  at every launch (0.03 s for BGCHR in mruby). read_file is binary-safe.
- RoundBuilder (Ruby) = level_render.py logic on a clean 32x32 cell grid + padded collision array; screen pos words -> cell via
  (0x7ff - (pos - 0xc000)) / 2, game coords -> cell 958 - 32*(y>>3) - (x>>3). Port deviation: map cleared to tile 0 (original copies an
  rts opcode pattern from $6e4; only hidden rows show it).
- Screen = one 256x256 pixel array (ABGR, rows top-down); sprites = 16x16 pixel arrays per (bank, code, palette), flips by the renderer.
  View: rows 0-29 visible at 3x (768x720), rows 30-31 fall off the bottom.
- Verified: rounds 1, 15, 101 screenshots match the Python renders (incl. colours) after fixing the Integer#/ -> Float pitfall.

---
# Palette fix (pass 12) - verified against the user's arcade PCB captures (fl_files/pcb/, local only)
- $386 (vblank queue): for destinations below $e82200 the offset is doubled and each source word is written twice. So the 64-word set
  ($b600 + theme*128) occupies graphic palette 0-127 and the fixed table $ba00 (queued to $e82080) occupies 128-255.
- With the tile cache's index = group*32 + 2*pixel (+1 odd), colour = word[group*16 + pixel]: groups 0-3 come from the theme set,
  4-7 from the fixed table, and the "odd" variant is the same colour (the duplicate entries exist only because of the 8-bit index layout).
- After the fix, rounds 1/3/9/20 match the PCB: blue brick + ice blocks, dark wood + orange logs, mauve cake walls, teal stone; drop shadows
  dark and offset lower-right like the PCB. Fixed in level_render.py and fairyland/app/gfx/palette.rb (the two renderers are pixel-identical
  apart from the item marker).
- Candidate arcade tweak: icing/stone platforms (rounds 9, 20) are cream/pink on X68000 vs near-white on the PCB captures (captures are
  over-exposed, so confirm before changing).

---
# Player task 01 ported (pass 13) - fairyland/app/game/tasks/player.rb
Structure of $4366 (one resume point per state in the port):
- walk $4398: ground check $47fe (cell under x+4/x+3 at y-1 solid and the cell above it free, either column) or standing on an object
  ($4836: object state 1..$0f, player 17..24 px above, |dx| < 13 -> $632 = its task id); else fall. Jump needs a fresh press ($62f latch).
  Left/right: wall test at x+16 / x-1 (foot level), move $62d px, 8-frame walk cycle $c508; draw $1a48(frame + facing + $62c); yield $634.
  Defaults: $634 = 3 frames per step, $62d = 2 px (set at game start/round clear/continue). Shrunk by Wizard ($6ed2): $62c = $1c,
  $634 = 1, $62d = 1, and every other step is an animation-only step (shrunk walks slower overall).
- jump $45fc: sound $16; jdx = +1/-1/0 locked at take-off; table $c542/$c58f of (frame, dy): +4 x6, +2, +1 ... then -1/-2 and $f7
  ("fall 2, no x"); rises exactly 32 px = one platform tier, passing up through platforms (one-way). First 18 frames: a straight-up jump
  at a cell-aligned y steps onto a ledge in the pushed direction (the "short hop"); diagonal jumps lose jdx on hitting a wall.
  Descending at aligned y: land on a solid top or an object.
- fall $44ec: optional 3-step slide table ($c528/$c535) aligning x, then 2 px/frame; facing can change, x cannot. Objects only count after
  4 frames. y is a byte, so falling off the bottom wraps to the top. Land: wait 2 frames, round x to even.
- Collision index $48b0 = 32*(y>>3) + (x>>3) into $716; floor (level row 24, screen row 29) is at y = 24, platform tiers every 32 px.
- Player spawn (round start $2648): x = $a0, y = $24, drawn with set $62c; then main spawns tasks 0, 4, $10, $14, $e; task 00 spawns 01.
- Sprite shadow ($1952 -> one list, $60 never changes): single-buffered and persistent; $1a0e clears a slot; slot byte / 4 = entry.
- Input $48ca: active-low nibble, bit2 left(+x) bit3 right(-x) bit1 jump (button A) bit0 spell (button B); read only when the task wakes.
Verified by scripted runs (--script): walk 2 px / 3 frames, wall stop, vertical jump to the next tier, diagonal jump, walk off an edge.
QOL option short_hop (F2, default off): a directional jump whose button was tapped (released) while the direction is held gets the same
ledge step as a vertical jump. Off = original code path.

## Arcade cross-check of the player task (pass 13b) - arcade Z80 player code at $42aa-$46a8 (tables $43c6.., $44aa, $46a8)
- The X68000 task 01 is an instruction-for-instruction translation of the arcade Z80 routine (same variables: $e6a9 x/y, $e6ac anim,
  $e6ad facing, $e6ae sprite set, $e6af speed, $e6b6 step delay; RST $30 / CALL $00fa = yield A frames). Jump/slide/walk tables are
  byte-identical. Landing waits 2 frames (LD A,2 / RST $30) on both. Step delay 3 / speed 2 (shrunk: 1/1; set $38: 1/1) on both.
  => the port's movement timing is arcade-exact. Z80 disassembly: z80dis 1.0.6 (pure Python, audited) unpacked in the session
  scratchpad; consider a project-local copy if we keep using it.
- Sprite Y fix: $591 = $22 at boot ($1dce) and bit 1 is never cleared, so every sprite is drawn 2 px higher ((~y + yoff - 2)).
  Fixed in world.rb (flags591 $2a), the enemy preview, and level_render.py. Ptolemy's feet now sit on platform tops.
- QOL responsive_jump (F3, default off): the original only reads input when the task wakes, so a jump pressed while landing (2-frame
  pause) or mid walk step (3 frames) is late, and a press released before landing is lost. Option: buffer a fresh press for 8 frames and
  wake the task early from :walk_after/:land2. Verified: a press during the last frames of a jump re-jumps on the landing frame.
- OPEN (pass 13b): user says F3 responsive_jump feels like the arcade -> check whether the arcade yield (RST $30 -> $00fa) waits one frame less than X68 $18ea, or polls input differently.

---
# Enemies, layer A (pass 14) - fairyland/app/game/tasks/enemy.rb
Object slots $59d + 12k (8 slots): 0 state, 1 anim/counter, 2 type, 3 task id, 4 facing (0/9), 5 jump dx, 6 x, 7 y, 8 AI command bits
(0 jump, 1 attack, 2 move +x, 3 move -x, 4 bumped, 5 Cleric-spawned, 6 follow trail, 7 chase), 9 shadow slot, 10 trail index, 11 AI timer.
States: 0 empty, 1 walk, 2 fall, 5 jump, 6/7 attack, 8/9 special, $10 dying, $20 appearing, $30 escaping, $80+/$f0 spell/cake states.
- Task 04 = ENEMY AI (pass 3 guessed "gameplay manager"): one object per frame. Species triggers: Salamander attacks when level and
  16..49 px away; Wizard when level and < 49 px in front; Cleric on the round timer; Golem always chases. Otherwise: target = Ptolemy (or the
  spot 24 px beside a cake, $60d/$60e): above -> jump to a platform found by $5540 (3 rows up, 2 columns) or walk to a column found by
  $5566; same row -> walk toward her; below -> walk to a gap and drop. Within 48 px / 9 px: chase mode (bit 7), then follow her trail ($63a,
  10 positions recorded by the player task) - that is what the player's trail is for. Shrunk Ptolemy is ignored by Wizards.
  Round timer: $610 += 1 every 6 passes (48 frames): >= $41 enemies full speed (hurry up), $46 spawns task $24 (Horned); when only one enemy
  is left ($5fd |= $80) the timer restarts at $40 and when it runs out that enemy escapes (state $30, sound $25).
  Quirk kept: $5124 tests (a1) (object state) where the parallel branch tests the collision cell.
- Tasks 05..0c = shared ENEMY BODY ($55b4), slot = id - 5. Obeys the command bits; walk 2 px per step (carries Ptolemy if she rides it),
  same fall slide / jump tables format as the player (tables $c702 walk, $c70a/$c717 slide, $c724/$c771 jump). Every acting frame waits
  for the speed divider: yield 1, repeat while $600 == 0. A walk step = draw + 3 such waits. Wraiths vanish when the spell approaches.
- Task 0f = OBJECT-STATE MANAGER (pass 3 guessed "boss-like"): every 2 frames over all objects: $20 -> walking + start the enemy task (all
  enemies start in the same frame); walking enemies push each other apart; $695a contact with Ptolemy (|dx| < 8, dy -8..+8 or -4..+8 when
  shrunk) -> $62e = $40 if $578 bit 6, records the killer ($596), Wraith kill = level - 1, freezes the task list $c87b; spell hits; cakes.
- $600 speed divider: decremented after the scheduler each frame ($2b2), reloaded from $5fe when it wraps (bit 7).
- Enemy tasks are started by task 0f, objects are filled by $253e (Worm door entries are always listed last, so slot k = task 5 + k holds).
Ported now: appear, AI, walk/fall/jump/chase/trail-follow, pushing, speed divider, hurry-up timer. Not yet: contact death (layer B),
species attacks, spell/cakes/crush/score (layer C), Horned (task $24), escape (state $30).

## Death and restart (pass 15)
- $695a (task 0f, per object in any state except 0/8/9/$10/$20/$30/$80+, skipped while $59b bit 7): |px-ox| < 8 and
  py-oy in -8..+7 (-4..+7 when shrunk, $62c = $1c) -> if $578 bit 6 ($578 bit 6 CLEAR = the "NO HIT" debug switch, $2a00):
  $62e = $40, $596 = killer task id, Wraith ($57) kill: $705 (level) -= 1 if > 0; kills every task in $c87b
  (01 03 04 05-0e 11-14 24 0f 26) except the running one.
- Task 00 ($3ee0): spawns 01 and 03, then every 6 frames: step counter $707/$708 += |dx| while $611 == 0 and $59b == 0
  (>= 800 -> -800, spawn 15); $59b == 8 scores the distance instead. On $62e != 0: $626 = 0, sound 0, kill $1d and $15, then
  $40 -> $409a (enemy touch), $20 -> $41ae (burnt by a Salamander), $10 -> $42aa (Wizard: shrinking death), anything
  else -> $3fde (eaten by the Worm - user confirmed the three death kinds; exact code-to-kind mapping to verify when porting).
- $409a death: kill all others ($1890), $57e = 2, pose $1b8e(char: 0, or 9 if shrunk), sound $2a, 40f, $1b8e($2b) 5f,
  $1b8e($2f) 5f, $4328 hides every enemy except the killer + shadow slots $5c-$7c, pose char+1, 40f, sound $0b (miss jingle);
  ghost: frames char + $c4e8[] (7 frames each), y += 1 per frame up to $f7, x drifts 1 px towards the screen centre when
  ($58c rand & 3) == 0 - with $58c's +$5a and the vblank +1 that is exactly every 4th frame, a straight diagonal (X68000 only;
  the arcade sways, see below); then waits for the sound driver to go idle ($56c), $62e = $ff, kills itself.
- $1b8e: shadow writer, table $10b29, 6-byte entries [slot, yoff, hi, code, xoff, next], x = -(x + xoff).
- $58c "random": returns word $5c then adds $5a; $5c also += 1 every vblank ($1ee).
- Main loop ($20b0): $62e == $ff -> $21ba: quit key -> game over; else if lives are on ($576 & $18) $704 -= 1 (BCD),
  0 -> GAME OVER; otherwise $1fd8: the whole round is rebuilt ($1114) and restarted with the intro ($2612). Steps $707
  and level $705 survive (only reset at $1f9c, new game). Lives = (($576 >> 3) & 3) + 2.
- $2268 keys: one key sets $62e = $40 with killer $ff (suicide), another also sets $4a (quit to game over).
- $2612 round intro: music 7 (rounds < $31), $30 (< $64), $12 (>= $64); spawns $1a and waits for $6b6; Ptolemy at ($a0,$24);
  pose $4e at ($94,$1b); spawns 01, "READY !", spawns $1b, waits $6b6 again. Then $2066 spawns 00, 04, $10, $14, $0e, $21.
- $488c trail push writes (y, x) AND zeroes the next entry's y; on the wrap the zero goes to $64e and to the first entry.
  The AI's trail scans stop on that terminator (port bug fixed: it had no terminator).

## Arcade ghost sway + MCU command protocol (pass 15b)
- Arcade death ghost loop = Z80 $179c-$17dc, otherwise identical to $4140: at $17b9 `LD A,R / AND 3 / JR NZ` (Z80 refresh register
  = effectively random 1-in-4), then MCU command $32 -> H, x += H (jdx $E6AB == 0) or x -= H, then MCU command 3. The death path
  also sends command 3 once at its start ($1733). (User remembered the bubble's "randomized float pattern" - confirmed.)
- 68705 MCU (a45-20.mcu, capstone CS_ARCH_M680X / M680X_6805 disassembles it): receive IRQ $0618. Byte with bit 7 set = "write
  next byte to RAM[cmd & $7f]" (cmd XOR ROM $781 = 0); commands 0-15 run handlers via ROM jump table $740 (RAM $18-$1a holds a
  JMP); others: bitmask table $760 marks readable RAM ($28-$3f) -> returns RAM[cmd], unmarked commands return 0.
- Commands 2/3 = a byte-sequence server: RAM $30 = sequence number (Z80 writes it at round start $d62 from $E617, the theme),
  cmd 2: $31 = ROM[$80 + n] (sequences at $84/$8a/$90/$96, 5 bytes + $80: castle-frame tile values the round builder fetches via
  $110d, part of the protection); cmd 3: $32 = next byte; after the $80 terminator it loops forever over the default sequence at
  ROM $9c-$e6 (75 steps of 0/+1/-1, sum 0: hold 12, ease +15, hold 13, ease -15). The round start consumes the 5-byte sequence,
  so a death sways from the default sequence's first step. Port: Director::SWAY (verified equal to the ROM), random 1-in-4 from
  World.r_reg (xorshift stand-in for R).
- Other arcade LD A,R sites (probably where the X68000 calls $58c): $47f5, $552d, $5538, $5578, $55a1, $55aa, $7795, $8ac5 - compare
  when porting those routines; the X68000's $58c counter is far less random than R.

## The protection MCU (68705, a45-20.mcu) - what it does (pass 15c)
Tools: `z80dis.py fl_files/arcade <out>` (own Z80 disassembler; RST $08 spawn, $10 kill, $18 kill others, $30 yield);
MCU via capstone M680X_6805. Z80 side: $bf89 send byte to $d000 (waits $d805 bit 1), $bf7b receive (waits bit 0),
$bf69 = read MCU RAM[A & $7f], $bf72 = run command A & $0f, $bf5d = write RAM[B] = A (sends B|$80, then A).
1. Boot handshake: $bf4c expects $f9 back, else "BAD HW" ($be07). The Z80 also sums its own ROM at boot ($bfed, "BAD ROM")
   and keeps a rolling ROM checksum at runtime ($bfb2, called from $192a / $53ff) that sets $e60b = $ff on a mismatch.
2. STATE VAULT (the real protection): at every "READY !" ($57c2 -> $bfd3) the Z80 packs round ($e781), $e6ae (char) and
   $e6af (speed) into a 20-bit key, sums the matching 8-byte constants from its table $beac (one per set bit) into a 64-bit
   number, writes it to MCU RAM $40-$47 and runs command 14: 64-bit multiply/divide against the MCU's own constants
   (ROM $348+). At the round (re)start ($38c) the Z80 reads 3 bytes back from RAM $40 and USES THEM as round / char / speed;
   round >= $67 or speed & $0f == 0 -> `jr nc,$` deliberate hang. A board without the right MCU breaks on the first restart.
3. Castle frame: commands 2/3 serve a 5-byte sequence per round theme (RAM $30 = theme, set at $d62) that the round builder
   draws the frame with ($110d). Afterwards the same server loops the 75-step sway table (ghost bubble, pass 15b).
4. Text: command 7 serves the ENDING and CONTINUE texts from MCU ROM $20a-$33c ("CONGRATULATIONS !!", "YOU HAVE SUCCESSFULLY
   COMPLETED .. QUESTS", "...THE DIAMOND IS IN YOUR HAND", "TO CONTINUE GAME INSERT COIN AND HOLD JUMP OR SPELL BUTTON...").
5. Line stepper: commands 4 (clear 2 slots RAM $39-$48), 5 (set up a Bresenham line from ($35,$36) to ($37,$38), +/-3 px
   steps), 6 (advance both slots). Used by Z80 $8662/$869f (sound $39 = X68000 task $29 at $9614: identify when ported).
6. Command 1 ($100) = RAM $30 / 7 (quotient + remainder): no Z80 caller found. Commands 8-13 = rts.
The X68000 port re-implements 2-5 in plain 68000 code (no vault), and replaced the sway with a constant.

## Version differences (arcade vs X68000) - port setting `behaviour` (:arcade default / :x68000, F5)
| what | arcade | X68000 | port |
| ghost bubble float | random 1-in-4 (LD A,R) + MCU sway table | counter: 1 px every 4th frame | DONE (Director :ghost_move) |
| level-9 item timer | 230 / 1380 frames (byte after its table) | 256 / 1536 | TODO with task 15 |
| typo (user) | - | present in X68000 text | TODO with text |
| other LD A,R sites | $47f5 $552d $5538 $5578 $55a1 $55aa $7795 $8ac5 | (check what FS.X uses) | check per routine |
| open | EXP reset on death, Wizard-shrink clamp, step remainder, yield timing (RST $30) | | check per routine |
Method: when porting a routine, find its Z80 twin (same tables; work RAM maps 1:1, Z80 address = X68 offset + $e082, e.g. $62e -> $e6b0, $629 -> $e6ab) and diff it.

## Spell, cakes, crushing, scoring (pass 16) - ported: tasks 03, 0e, 0f (full), 10, 11, 16, 17, 18
- Task 03 spell ($49d0): $597 recast delay counts down only while the button is held; task 0E ($605c) zeroes it (and the jump
  latch $62f) when it sees the button released - 0E runs every 7 frames ($593 = 0; 4/3/6 in other modes, it also animates
  background tiles), so release detection is that coarse. Holding = a cast every 61 frames; tapping casts at once.
  Wave: x = px +/- $a, step +/-1 px per frame (+/-3 with $59b = 1), sprites from [code, xoff] tables $c64e (+x) / $c6a0
  (-x), +$39 when shrunk; ends at the table's 0, when a hit sets $598 = $80, or at a wall two cells high (cell AND cell+$20).
  $59b = 3 fire spell ($4b04): x +/- $e, y + 2, looping table $c6f0/$c6f9 [code, dx], flies to a wall or the screen edge.
- Task 0F ($6158): spawns 11 + 17, then every 2 frames per object: $20 -> 1 + spawn; contact ($695a); push ($61b4);
  spell check ($6280: |dx| < $a, dy -12..+15): Cleric-summoned (cmd bit 5) die at once (10 pts); fire ($59b 3): sparkle 4,
  -> $10; else sparkle 0, $598 = $80; $59b 2 kills outright (EXP+1, multi-kill score, -> $90); a cake hit again: +4 to its
  timer (+2 Golem), at >= $1e it dissolves for the $c821 score. $10 (6 ticks) -> $f0 cake (timer $c, Golem 6, x10 ticks,
  y snapped to 8) or $91 burning (fire). $f0: Ptolemy (or an enemy) walking into it pushes it 2 px; an enemy pushing it
  goes to state 6; a cake Ptolemy pushes shoves enemies ahead of it; blinks when timer < 9; hatches at 0 (state 1 + task).
  $80-$ef count down; at 0 removed ($5fd--, Wizard -> task 16 restores Ptolemy). A dying Cleric takes ALL Clerics with it.
  $30 escape: frames $c845, then gone.
- Cake marks: $689e ORs (d3 & 6) | 8 into the 2x2 cells (d3 = leftover sprite slot), $6888 clears with $f1. Nothing ever
  reads bits 1-3: cakes are NOT solid and Ptolemy cannot stand on them (user confirmed). $4836: she can stand on live
  enemies (state 1-$f), 17-24 px above, within 12 px (user: "unless they jump" - a jumping enemy rises out of the window).
- Task 11 ($6b0c) falling cakes: $f0 with no ground -> $f1 (counts to $ff), 2 px/frame; objects in state $f0 or 1-$10 within
  16 px under it are crushed ($e0, carried 6 px below, task killed), crush count in $b(a1) starting at 1 (its own enemy).
  Landing: fell >= 9 frames or count >= 2 -> breaks ($6d04): EXP+1, EXP += (n-1)*2, n = 1 -> $c833 score + sound $2f,
  n >= 2 -> combo $c7f4 (n=2 2000, 3 4000, 4 8000 ... 7 64000 displayed), n >= 3 -> bonus item; short drop -> cake again.
  Ptolemy 7-16 px under a falling cake -> $62e = $80 (crushed; director $3fde: squashed pose $1b drops 4 px/frame, sound $1a).
- Task 17 ($7bf0) bonus items ($655, 8 x [timer, code, slot, y, x]): code $c97a[n]: n=3 $41, 4-5 $49, 6+ $51 (1000/2000/4000
  displayed, tables $c974/$c977/$c97a); hidden while timer >= $32, every 6 frames; pickup scores value x streak $67d
  (max 8, reset when an item expires). User: "the more you collect the more points you get".
- Task 10 ($6a9a) sparkles $601 x3 (7-frame steps, slots $5c/$64/$6c); task 18 ($7d98) popups $67f x8 (every 10 frames,
  shown at timer 5, cleared at 0); task 16 ($7b6c) Wizard gone (+ a second sparkle after it kills itself - quirk kept).
- Scores: $8fe4 adds BCD d4 (low pair) and d3 into $700-$702, cap 999999, HUD appends a 0. $6854 EXP: += n unless >= $f0;
  over $706 -> $706 += 30 (no carry), level $705 + 1 up to 7. RESOLVED: EXP = $703 (round - 1) at $1fd8, i.e. on every new
  life (death -> $225a -> $1fd8); a round clear goes to $200e and keeps EXP.
- Still unknown: $623 (task 14 sets it: drops $41/$49/$51 items on other kills), $626 (blocks contact checks; item $796a).
- Wraith ($5f64, attack dispatch $5b3a): when the spell is within its window (wraith_dodge?: shot y -16..+23 of it, shot x
  0..39 px ahead of it in the shot's flight direction) and $654 == 0: sound $1b, state 8 (task 0f skips it: no touch, no
  hits), flicker 10 x (draw, clear) 1 frame each, 20 frames gone, flicker back, walk on (cmd set to move away, $b = $20).
  Only checked when its body task runs a walk step on the ground, so point-blank casts (the wave starts 10 px out, already
  past it) and catching it mid-jump/fall should land. User: "phases out when you attack it; spam it or from behind?".
  PORT BUG FIXED: the stubbed attack state looped back to :main without yielding -> frozen game in Wraith rounds.
  Scheduler.guard now raises after 1000 non-yielding steps.
- Task 0E background animation = the theme's little animations (user: waving flag, flickering candles on the cake
  stages): $593 mode 0 / 2 / 3 / other at 7 / 4 / 3 / 6 frames, tiles written with $b52. Not ported yet.

## Round flow, text, HUD (pass 17)
- $2612 intro (port: task 0x40): music 7/$30/$12, task 1a (Ptolemy flies in on the broom; scripts $ca50 / shrunk $ca6d,
  paths $ca04 [dx,dy], $80+word = arcade address - $5702), then Ptolemy at ($a0,$24) + pose $4e, $592 = $ff (no input until
  the director clears it), "READY !" at $c3a5 over the saved name-table cells, task 1b (the broom flies off, $ca8a), $270e
  shows the enemies facing Ptolemy, then $2066 spawns 00 04 10 14 0e 21. Tasks 1a/1b kill themselves and fall into $80c6
  (one pass of a power-up object loop; harmless at round start). $2750 = the MCU vault's 64-bit packing, vestigial on X68000.
- $20c4 round clear (port: task 0x41): kill $1d $15 $14 00 (+ $26 unless $6f4), sound $0c, 44 x 6 frames with Ptolemy still
  movable, shrink carries over, EXP kept ($200e); every 7th round the intermission ($2818 -> task $25, not ported); after
  round 101 ($703 >= $64) the ending $3722 (not ported).
- Text = name-table writes ($b52: attr at the address, code below it, cell = ($7ff - (a & $7ff)) >> 1, next char a - 2), same
  tile rules as the background. HUD $7b8 (every frame): HIGH SCORE $c769, hi $c727, 1UP $c777, score $c73b (6 digits, leading
  blanks, + "0"); ROUND: $c093 (+3 digits); lives $29f4 at $c0bb ('[' per spare life, "[[..n" from 5, NO HIT / ENDLESS).
- Task 0E animation: $593 = theme byte; theme 0 swaps $bc/$bd at $c4ff/$c4c1 (the tower flags, row 12 edges) every 7 frames;
  theme 2 pairs $5b/$5c <-> $8a/$8b at $c77f/$c743 (4 frames); theme 3 $f1/$f3 <-> $20/$21 at $c77d/$c741 (3 frames).

## Species attacks, enemy shots, burnt / shrink deaths (pass 18) - fairyland/app/game/tasks/attacks.rb, director.rb
- $5b3a attack dispatch (AI cmd bit 1): $91 Wizard $5b60, $1d Salamander $5c6c, $74 Cleric $5e00, $57 -> Wraith vanish $5f64.
  Attack frames are PLAIN yields ($18b4), not speed-divider waits. Poses come from the $1b22 table ($108e9); $5da2 = draw pose +
  drop 2 px if no ground under the feet. Tables [pose, frames]..[pose, 0]: Wizard $c7be/$c7c8, Salamander $c7d2/$c7dc, Cleric
  $c7e6/$c7ed (..0). $19fc + add.b to +4/+$c = palette shift of both sprites (+1/+2/+3 "flash").
- Wizard: state 7, poses (abort when bumped, cmd bit 4), then if $654 == 0 and a shot slot is free: $613/$617 = [own task id, y, x,
  facing], spawn task $12/$13, sound $19, 3 flash steps x 2 frames, 20 x 2 frames hold; always ends with cmd ^= $c, timer $64.
- Salamander: state 7, $5(a1) = $80 (flame palette counter, $5dd8 cycles the 2nd sprite's palette 2..5 every other frame), sound
  $1c on poses $17/$1b, then slot = [$ff, y, x, facing] + sound $1e (skipped if $654 or no slot - same 40-frame hold either way).
- Cleric: yield 1; only if $5fd < 5 (byte compare, so never with the last-enemy flag) and a free object slot ($5f36: state 0 AND
  sprite slot clear) - else it just walks. Then up to 3 summons: new object state 1 (no appear phase), type $74, same x/y,
  task 5+k, cmd = Cleric's reversed cmd | $20, $5fd + 1, sound $24, 8 frames apart. Stale fields of the slot are kept.
- Tasks $12/$13 ($6d94/$6da0), sprite slot $74/$78:
  Wizard spell: x +/- 12, table $7070/$70a1 [pose, dx] 24 steps at 1 px/frame; ends at a wall (cell AND cell+$20; quirk: the
  d0 "+1 for rightward" is computed and never used, always x+7). Hit: |dx| < 14 (signed), dy -14..+11 -> EXP $57f -= 10 (clamped),
  task 01 killed, y &= $f8, sparkle 0, 20 frames, $612 = Wizard id; normal -> $62c=$1c, $634=1, $62d=1, respawn 01; already
  small -> (hits on) kill the Wizard's task, $62e = $10; NO HIT mode still shrinks.
  Fireball: x +/- 12, y + 8, looping table $70d2/$70e3 (2 px/frame), ends at a wall / x >= $f0 / past 0; hit $701c: |dx| < 6,
  Ptolemy 0..6 above or < 14 (small: < 8) below -> $62e = $20 (only with hits on). Burst poses $70f4/$70f7 x 6 frames, then the
  slot stays busy 50 frames. If byte $6fc != 0 it kills task 04 ($6fc is never written by name - unknown).
- $612 corrected: 0 = normal size; the shot stores the Wizard's id; at round load ($2530) a non-zero $612 becomes $ff and EVERY
  Wizard in the table overwrites it (= the round's last Wizard, not the first). New life ($1fd8) clears it. Port fixed.
- Director $41ae burnt: $57e = 1, kill 01/03, sparkle 4 (sound $1e), 15f, charred pose $1a48($7f, small $83) dropping 2 px/frame
  to the ground, 20f, kill others, 40f, clear 29 slots, 30f, then offsets $c4f1 added to $7f/$83 every 3 frames (sound $20 on
  offset 2) until the sum carries past $ff (the next table's $86), 60f, done.
- Director $42aa shrinking death: kill 03, 7f, sound $f, 8f, kill others, hide all but the Wizard ($612), $1a48 poses $86-$88
  (7f each), y += 5, $1b22 poses $66-$6b in sprite slot 8 (4f each), clear slot 8, 50f, done.
Verified by scripts: round 4 Wizard shot shrinks Ptolemy (no_hit), round 7 Salamander fireball burns her (other slots injected
empty), round 13 Cleric summons 3 at 8-frame spacing. NOT yet verified: the shrinking death (needs a shot already in flight
when she is small - Wizards ignore a small Ptolemy). TODO: diff these routines against their Z80 twins.

## Data layer + arcade table map (pass 19) - fairyland/app/fs/tables.rb
- The engine reads no raw addresses any more: GameData#a(name) -> address in the loaded image. Tables::ADDR holds every
  table as [X68000 FS.X address, arcade Z80 address]. Canonical FORMAT = the X68000's; the future arcade loader converts
  where layouts differ (arcade nil): round_records/enemy_tables/deco_lists + deco0-3 (32-bit pointers in FS.X), palettes.
- PROBE RESULT: almost every FS.X table is byte-identical in the arcade main ROM (cpu-a45.15-17 = Z80 $0000-$bfff), incl. all
  four metasprite tables ($10234->$3353, $104f5->$363e, $108e9->$3a5c, $10b29->$3cca), round records ($d9db->$961a), enemy
  lists, round-101 blocks. So the X68000 kept the arcade's sprite codes - the X68000 SPCHR should be the arcade art in the
  arcade numbering (check when writing the gfx converter). The broom paths in FS.X even keep arcade addresses (ptr - $5702).
- Arcade attack routines (Z80 Wizard $4d47, Salamander $4e13, Cleric $4f38, helpers $4eda/$4f06/$5005) are instruction-for-
  instruction the X68000 ones (pass 18); only their DATA differs:
  * Salamander $4f20/$4f2c: one extra leading pose ($1f / $21, 5 steps x 2 frames) -> attacks 10 frames later.
  * Cleric $5026/$502f: extra leading pose $37 / $3c for 10 frames -> summons 10 frames later.
  * Spell wave rightward $1af3: 28 steps like the leftward one; FS.X $c6a0 lost the last pair (7a 07), so on the X68000
    the rightward wave is a frame shorter and the shrunk half (+$39) starts one pair late (X68000 conversion slip).
  Both copies live in Tables::VARIANTS (user decision: arcade data embedded so arcade mode works from either source);
  GameData appends the non-native copy and verifies the native copy against the player's file at load.
- The arcade flag at $e6d3 sits where the X68000 uses $654 (the +$e082 rule would give $e6d6): the work-RAM map is NOT 1:1
  everywhere - check per variable.
- Verified: --x68k reproduces the pass-18 frame numbers exactly (Wizard 445/468/488, Salamander 264/282, Cleric 986/994/1002);
  arcade mode: Salamander 274/292, Cleric 996/1004/1012. Round 4 render pixel-identical; round 101 renders.
Version-difference table additions: Salamander/Cleric wind-up (DONE), rightward spell wave (DONE) - all via VARIANTS.

## Arcade loader (pass 20) - the port runs from EITHER the X68000 disk OR the arcade ROM set (fs/game_data.rb)
- data/ may hold the X68000 Disk 1 / loose files and/or the arcade ROMs (cpu-a45.15-17, vid-a45.06-09/.18-21, loose, 16 KB
  each; zip not supported yet - DragonRuby has no inflate). Both present: arcade by default, `--source x68k` for the disk.
- Pointer tables: rounds $78de, enemies $79aa (16-bit LE). Round record = same theme/bitmap/pair bytes; tail differs:
  arcade [item x, item y, word deco-list ptr] vs X68000 [x, y, unused, selector $11+n -> $1544 table]. Deco entries:
  arcade 5 bytes [attr, word pos, word block] (0 attr ends) vs X68000 10 bytes. Theme lists $1117/$11ed/$1349/$1421;
  $734c is another list (intermission/ending?). GameData#round_record/#round_tail/#deco_entries/#enemy_list parse both.
- Arcade round builder $0d41: same as $1114 but attr/rows/fill tile/bitmap tile and the PALETTE SET come from the MCU
  (call $110d = MCU cmd 3). MCU ROM sequences $84/$8a/$90/$96 = themes 3/2/1/0: 59 0d ba 59 03 | 59 8d 9b 59 02 |
  59 0d 3b 59 01 | 19 be c2 19 00 - exactly the X68000's hard-coded values; 5th byte = palette set = theme.
- GRAPHICS (exact, verified pixel-for-pixel vs the X68000's decoded files): MAME-style 8x8, 16 bytes/tile/ROM, row = 2 bytes,
  pixel x in each byte = bits x and x+4 (MAME bit order: offset 0 = MSB); first ROM = pen bits 0-1, second = 2-3.
  BG tiles 0-1023 = .06/.07, 1024-2047 = .20/.21; sprite banks 0/1/2 = .18/.19 / .08/.09 / .20/.21 (16x16 = 4 tiles TL TR BL BR).
  The X68000 BGCHR/SPCHR are a straight conversion: same numbering, same pen values.
- PALETTES (exact): palette RAM $dd00-$deff (lo GGGGRRRR at $dd00+i, hi ----BBBB at $de00+i). Loader $5870/$58c5 (vblank,
  set number in $e73b from the MCU): theme sets $58fa + 128*s (64 lo bytes, 64 hi) -> entries 0-63 and 128-191; fixed $5cfa
  -> 64-127 and 192-255; boot table $5d7a (512 bytes) holds the sprite palettes (= X68000 $ba80 blocks 0-15).
  The arcade INVERTS its graphics: pen = 15 - pixel within each group of 16. X68000 word = (level*2) per channel + I bit,
  pixel order reversed (all 704 words; one $0000 black). The X68000 did NOT retune any colour. Port: arcade behaviour uses
  level*17 (full white 255), X68000 behaviour its 6-bit DAC ((c5*2+I)/63; old port code used c5*255/31 and ignored I).
- Remaining data differences (Tables::PATCHES, applied per behaviour to either source): deco list $13 entries 5/6 attr $58
  (X68000) vs $50 (arcade, H-flipped: the green ball beside the right strawberry on cake rounds, 17 rounds); round 19
  bitmap byte 66 $fe vs $ff - CONFIRMED on the user's PCB (round 19 has one continuous log, the X68000 a gap at row 16
  col 23). The theme-0 list draws the $c4c1 flag twice on the X68000 ($10 then $18 = the arcade's single $18): no change.
- User PCB captures (fl_files/pcb/, local): 1280x720 ones = 3.04x horizontally, 3x vertically, active picture = game lines
  16-239 (224 lines: the arcade's visible area; the port currently shows 240). Capture levels are shifted (not usable for DAC).

## Visible area + colour profile (pass 21)
- Port view = game lines 16-239 (224 lines, arcade and X68000 alike - user confirmed), composed at 1x in a 256x256 render
  target (:frame) and shown at 3x (768x672) with 24 px borders. Sprites crop at the visible edges like the hardware.
  Verified against the user's 1280x720 PCB captures: identical framing (HUD rows, castle, platforms line up).
- Colour transfer curve measured from the user's PCB captures (medians over flat background pixels of rounds 1 and 19,
  three captures; R/G reliable, B noisy from chroma subsampling): level 0-3 -> 0, 4 -> ~10, 5 -> ~33, 6 -> ~50, 8 -> ~95,
  10 -> ~125, 13 -> ~197, 14 -> ~216, 15 -> ~253. Fit: 255 * ((level - 3) / 12) ^ 1.3. Cannot separate board DAC/monitor
  from the capture chain, so it is an OPTION: Palette.profile :pcb (F6, --colours pcb), default = standard linear level*17.
  With it the port matches the captures closely (navy brick, golden castle).

## Bug fixed (pass 21b): arcade-data coin glitch (user report)
- Bonus coin code = byte[$c97a + crush count] on the X68000, i.e. it reads PAST drop_value_51's 3 bytes into the code table
  41 49 49 51 51 51 at $c97d. The arcade keeps that table at $51f3 (indexed from $51f0, Z80 `ld hl,$51f0; add hl,bc`),
  NOT after its value table ($5199). New table :drop_codes [$c97a, $51f0]. Verified: cake crushing 3 Orcs -> 8000 popup +
  coin, frame identical from both data sources.
- Audit of every table (matched length X68000 vs arcade vs how far the engine reads): no other overrun. burnt_death ends
  at index 12 on both (arcade has an explicit $ff where FS.X relies on the next table's $86); combo_scores would overrun
  at 8 crushes but the count is clamped to 7 ($69ec). RULE: when adding a table, map it by how the code INDEXES it.

## Task 14 = THE MOON (pass 22) - fairyland/app/game/tasks/moon.rb (MoonTask + NightWipe); arcade twin $3030 / $3246
- $61b countdown in game state: 120 at every new life ($1fd2), $f0 after each event; survives round changes. Ticks every
  120 frames (60 while shrunk); task 14 is (re)spawned each round and its first decrement is immediate. Moon Tiara item
  ($769e) sets it to 1. Task 15 (items) suspends task 14 while an item is out and waits while $61b == $f0; Horned ($86e2)
  kills task 14 unless $61b == $f0 (both TODO with those tasks).
- Event: moon frames $c890 (arcade $31fe, 8 x 3x3 tiles, attr $1c) at $c74f (2UP: $c775, column $19) every 10 frames,
  sound $14, $61d = 1, task suspends itself. Main loop $73c6: suspends $c87b tasks, 45 rings r=1..45 of a Minsky circle
  (x -= y/r; y += x/r in 8.8, from (r,0) until x < 0; mirrored at column $622 = 6 i.e. screen col 25; 2 cells per point)
  SET attr bit 1 = palette group +2; resumes ($7516 list), $61d = 0. Both versions draw all rings without yielding (CPU
  speed); port: 2 rings/frame (estimate - check against footage).
- PALETTE GROUPS 2/3 = groups 0/1 with every channel +2 levels (all theme sets): the moon BRIGHTENS the screen (moonlight).
  CONFIRMED by the user on the PCB.
- Then $623 = $ff and every enemy becomes a cake (state $f0, timer $c8, y &= $f8, sprite $eb; sparkle unless already a
  cake; Cleric-summoned ones vanish, $5fd - 1); a Wizard's shrink is lifted (saved in $61c); wait for the sound driver;
  music $3f; 240+240+22 frames; moon frames backwards; $79c blanks the 3x3 (tile 0, attr $6a = $38); sound $15; $61d = $ff
  -> morning wipe (rings 45..1 CLEAR bit 1); $623 = 0; cakes hatch one per 22 frames (sparkle, unmark, respawn task;
  the shrinking Wizard re-shrinks Ptolemy, $61c == $ff = carried shrink); round music $09 / $31.
- $623 set: one-enemy cake break drops coin $49 ($7d6c), combos drop $51 ($7d78) instead of the crush-count coin, a
  dissolved cake drops $41 ($7d60) - user: "zap the cakes to get coins to build up your combo score".
- Dev flag: --moon N sets the countdown (e.g. --moon 2 -> event ~4 s into the round).

## Bonus items (pass 23) - fairyland/app/game/tasks/items.rb: tasks 15 (+18 handlers), 1d glow, 19 stars, 1c ice
- Task 15 ($752c, arcade $47ce): waits while the moon is out ($61b == $f0), SUSPENDS task 14 (moon countdown) while an item
  is out; pick: EXP bracket ($c8d8) -> odds row ($c8de) -> roll & $7f (arcade LD A,R / X68000 $58c) -> tier; group by
  enemies left - 1 ($c902); no enemies = retry next frame. Item sprite = first word (X68000) / byte (arcade, table $48c2 of
  16-bit pointers) of the handler. Shown at ($650,$651) in sprite slot 0 (hi $ed, y + $e) for 150 x 6 frames; $611 set =
  gone. Pickup |dx| < 12, |dy| < 8: 1000 points + popup ($6a44 entry 0, timer 6, slot $54), sound $27,
  $652 = item_timers[level] (arcade level 9 = 230, X68000 0 = 256: Tables::VARIANTS item_timers). End ($7b36): resume
  task 14, $57e = 1, $59b = 0.
- Handlers (6-frame ticks unless noted): Silver Scepter $59b=1 / Gold $59b=2 + $654=2 / Scroll of Fire 3 / Mystical Orb 8
  (task 00 then adds the walked distance as a BCD byte to the score 3 times per 6 frames) - all spawn task 1d (glow);
  Magic Staff $59b=7, $5fe=1 for the duration (half-speed enemies); Moon Tiara $61b=1; Crystal Ring +40 EXP; Holy Water
  level+1 (cap index 8); Book of Life lives+1 (BCD) + sound 8; Star Tiara $59b=$654=5, task 19, at the end $59b=0, 240
  frames for the stars to land, kill 19; Glass Potion $626=$59b=$80 + palette :glass, blinking (glass/glass_off) in the
  last 16 ticks; Change Potion sound $0a, $59b=$654=$81, loses a shrink, Ptolemy set $38 speed 1/1, one object per frame:
  state 1..$f within 14 px -> sound $2e, burn ($91/$40, 1 EXP, $691e d1=$13); timer per 8-object pass, flicker set
  $38/0 in the last 16, then round BGM again if enemies remain; Scroll of Ice $59b=6, task 1c, freezes states 1..$80 (kill
  task, state 9, y &= $f8, sparkle, 5 frames, sound $18, sprite type+$1a), ice blinks (palette :ice / :normal every 2
  ticks) in the last 18 ticks, thaw (state 1, sparkle, 5 frames, respawn), 60 frames, kill 1c; Book of Death sound $2d,
  8 x (scroll +3 px 2 frames, 0 2 frames) = SCREEN SHAKE (X68000 $56 = BG scroll; arcade writes 3 into column-scroll RAM
  $dca0-$dcbf), $59b=$82, kill tasks 5-12, every object (5 frames each): 1..$7f burn, cakes $f0+ dissolve ($90/6, 1 EXP,
  $68fc score); Mystical Feather sound $2c, 20 frames, suspend $c87b, 40 frames, $653 = $5fd (or $80 from round 92),
  $5fd = 0, sound $2b. Round clear with $653 != 0: no jingle, no ending check; each skipped round is BUILT for one frame
  and its intermission check runs (port: jumps straight to round + ($653 & $7f) + 1; the flashes are not reproduced).
- Palette patches (Tables::PAL_PATCH; GameData#pal_patch converts both formats; SpriteCache applies w[:pal_patch]):
  glow = Ptolemy's outline (sprite colour 13) black/red/blue/yellow every 2 frames (task 1d, arcade $62d9 table $6302
  [pen, hi, lo]); glass = her reds (3, 4) -> white/grey; ice = block 13 colours 3/15 dimmer; normal = all restored
  (arcade $62c9 [pen, lo, hi]). Arcade ice/glass colours are immediate operands (`ld c,pen; ld de,hilo`) - identical values.
- Task 19 (stars, arcade $5512 identical but LD A,R x5): 4 stars [state, phase, y, x, slot] (slots $74 $78 $7c and - quirk -
  0); paths $c984 (arcade $563e) 8 x 8 [dy, dx]; frames $6c-$6f by phase, mirrored for dx < 0; re-enter at x += rand*2 with
  a random path; after the power-up a star that leaves the bottom stops (sound 1). One enemy per frame (states 1..$f)
  burns within 16 px of any star.
- Task 1c (ice physics, every block every frame): ground = x+4 cells; resting on ice exactly 24 px below; falling 2 px:
  crushes enemies/cakes below (state $e0, carried 6 px below, combo + 1), shatters ice below, squashes Ptolemy 7-16 px
  under ($62e = $80); landing: carried enemies -> $e1, combo >= 2 scores EXP (n-1)*2 + combo popup (via a borrowed free
  object slot), >= 3 drops a coin; fell 16+ frames -> shatter ($92, $20 frames, sound $34, 1 EXP, $691e d1=$a). Push:
  Ptolemy 1-11 px beside it at the same level (or an ice block overlapping it - chains) moves it 2 px (sound $33, $633 =
  her alt-walk flag), then it slides 1 px/frame until a wall shatters it.
- $57e = sprite priority table select (vblank $310 -> $1da0: $b158 + 64*n): 1 normal, 2 potions/death, 3 (Worm?). Port
  draws in shadow order - TODO if overlaps look wrong.
- Dev: --item N (0-17) spawns item N at Ptolemy's landing spot when the round starts.

## Horned (pass 24) - fairyland/app/game/tasks/horned.rb, task 24 ($86be, arcade $6c0c - same code)
- Spawned by the AI when $610 reaches $46 with 2+ enemies left (1 enemy left = that enemy escapes instead, sound $25).
- Waits (1 frame at a time) while $6f4 (Worm active, arcade $e772), $59b == $81 (Change Potion) or the moon is out; with
  $59b == 8 sets $652 = 1 (cuts the Mystical Orb short). Then kills task 14 (the moon), exits if no enemies left, music $12,
  229 frames, entrance script $6cd = 1..4 in turn (persists in game state) from table $cb7e (arcade words $6e0c):
  entries [steps, frame base ($7c/$78 + wing frame), step-table offset, frames per step], 0 ends; step table $caf6
  (arcade $6d83) of [dx, dy] with $80 = jump to a little-endian ARCADE address (FS.X keeps them; rebase - $6d83).
  Start position (x $ff, y $f4); script 1 lasts ~900 frames.
- Chase $87c0: Bresenham at 1 px/frame towards where Ptolemy was when it aimed; re-aims on reaching that x (x-major) or y.
  Frames: wing frame ($cc2e: 0 1 2 3 2 1, next every 7 frames) + $78 (moving +x) / $7c, drawn with $1b8e (meta_c).
- Touch $8920: |dx| < 8, Ptolemy 0-7 above / up to 8 (shrunk 4) below -> $62e = $596 = $40 (no enemy has id $40, so the
  death hides all enemies and Horned stays visible), suspends $c87b. Invincible.
- Last enemy gone: clear slots $4c-$58, sound $25 if y < $e8, vanish = 32 frames read BACKWARDS from $caf5 (arcade: the
  escape table end $208e - FS.X has a copy at $cad6) every 2 frames in slot $4c.
- Dev: --hurry 44 starts the round timer near the Horned time (hex).

## Worm (pass 25) - fairyland/app/game/tasks/worm.rb, task 26 ($8b76, arcade $7b08 - same code and timings)
- Spawned by the enemy loader ($2594) for the $ff entry (door $6f5/$6f6, closed door $b532/$b53a drawn via $728).
- $6fb body-length index (0-6 into $cca6 = 16 16 8 2 2 8 2; +1 each time it comes out without eating: it pokes out LESS each
  time - user: "making it angry, until it only throws out its tongue"; wraps after 7). Loop: $6f4 = 0,
  $6f8 = 0, 90 frames, then every 7 frames: $611 == 0, enemies left, |py - door y| < 8, 0 <= px - door x < $4d.
  (If a task-20 pair sits on the same spot it suspends task 20 - not ported.) $6f4 = $ff; open door block $cc6a (theme
  2 $cc72, attr $19); PRIORITY bit (attr $20) on 4 rows x 5 cells starting one cell screen-right of the door ($b20; $a6a
  clears it) so the body hides behind the frame.
- Extend: length x (body frame $cc7a[++$6f7 & 3] via $1b8e, 6 frames, x += 2); 15 frames; x -= 2; mouth $e8, sound $32;
  wind-up [dx, frame] pairs from $cc7e (relative to the head x) 4 frames each until 0; lunge pairs 2 frames each until
  dx < 0: the first enemy in state 1-8 with 0 <= oy - y < 10 and -16 <= ox - hx < 0 is swallowed (task killed, state 0,
  $6f9 = sprite by type from $cc99 pairs: Orc $76 Golem $7a Salamander $7e Wizard $82 Cleric $86 Wraith $8a, $6f8 = its
  sprite slot), else Ptolemy (not with $626 / NO HIT): kill all other tasks, sound 0, sprite $70 (shrunk $74), $57e = 3,
  $6f8 = 4. Every frame of all this, $8f48 pushes Ptolemy (0 <= py - y < 16, -24 <= px - x < 0) and enemies (0-23 px)
  2 px further (+x). Eaten: clear mouth slots $40-$48; Ptolemy -> sound $f, kill task 1d, restore palette; chew 6 x 10
  frames (sprite + n&1 at x - 8). Retract length x (9 frames, x -= 2), clear body slots $34-$4c.
- Close: clear the priority bit, closed door ($25ec). Nothing eaten -> again. Ptolemy -> 50 frames, $62e = $ff (the life
  just ends - no death scene). Enemy -> popup score entry $a (7000) at the door, 1 EXP, $5fd - 1; eaten task == $612
  (the shrinking Wizard) -> task 16 (Ptolemy grows back).
- RENDERER: attr bit 5 = background priority over sprites (MAME flstory tile category; X68000 special priority via odd
  colour codes): non-zero pixels of such cells now go to a second layer (:bg_front) drawn after the sprites. The HUD
  text attrs ($38/$39) have it too, so the HUD now covers sprites (e.g. the broom flying in), as on the hardware.
- Verified: round 15, Ptolemy 6 px into range -> tongue, caught, life lost; a Golem in front -> eaten, 7000, EXP + 1.

## Teleport doors (pass 26) - fairyland/app/game/tasks/doors.rb, task 20 ($8556, arcade $6b36 - same code)
- ROLE SOLVED: the round record's block pair ($6c2-$6c5 = x1,y1,x2,y2; 19 rounds) is a pair of TELEPORT DOORS. Spawned by
  the round builder ($146c) after drawing both blocks. Each frame one door is checked (sides alternate): Ptolemy (unless
  $62e is set) at exactly the door's y and |x - door x| < 2 -> moved to the other door (also $594/$595, so the jump does not
  count as walking); else the first enemy (states 1..$80) likewise. Latch per side (d1/d2: 1 = Ptolemy, else the enemy's
  task id) until they step off. The destination door shows tile codes + $f (open) for one frame ($8660, 3 x 2), with the
  Worm suspended for that frame ($6c6).
- Most doors hang on the side walls in mid-air: you go through by jumping/falling past the exact height (y moves 2 px a
  frame from even values) and come out of the other door still falling.
- Six rounds put a teleport door on the Worm's door (30 31 56 64 73 88): the Worm suspends task 20 while it is out
  ($8bc6), and arriving there puts Ptolemy inside its trigger window - it pops out at once (user: "the worm just pops out
  when you go through it"). Verified in round 73 (arrival frame 211, pushed from 218, lunge at 323).
- Dev: --pos XX,YY (hex) puts Ptolemy there when the round starts.

## Fix (pass 26b, user report): coin pickup streak $67d survives round clears
- $67d is reset only at $1ffa (new life / new game, the $1fd8 path), $7c1e (a coin expired uncollected) and $2440 (attract
  demo setup) - NOT on a round clear ($200e). Port: moved from the per-round world into the game state (g[:streak]).

## Round 101: the Dracolisk fight (pass 27) - fairyland/app/game/tasks/dracolisk.rb (tasks 21 22 23 27 28 29 2a 2b)
- Task 21 spawned by the enemy loader at round 101 ($5fd = 1); sets up (x $68, y $a8, facing $f3), spawns 29 23 27 22,
  suspends itself until the round start resumes it ($208e), kills 04 0f 11 14, spawns 2a 2b, $611 = $ff, sparkle slots
  1-2 kept busy. Every 6 frames: a spell inside the box (0 <= x-8-sx < $30, -24 <= y-sy < 9) is spent, sparkles, damage
  $5af += 30 - a carry past 255 = defeated; otherwise damage drains 1. Touching the box = crushed ($62e = $80).
- Defeat (user: "turns into a giant version of the Ptolemy cake, crumbles, and you get the Holy Gem that flashes"): suspend
  $ccae (22 23 27 28 29 2a), clear 19 slots, sound $35, giant cake frames $ccb5 [code, dy, code] (slots $18 / $0c, attr
  $fe / $c2) every 4 frames, drop 2 px a frame to y < $19 ($51), 20 frames, sound $36, crumble $ccce [dy, code] (dy 0 =
  sound $37) every 5, $5fd = 0, spawn 2c (Holy Gem: sprite $f2 + a cycling palette whose table $cd22 is ARCADE 12-bit
  colours converted at runtime by $99f0), 2d (Ptolemy walks there, input override), 0d (banner $8d/$93 + palette), end
  frames $cce0 every 10. Round clear at 101 -> ending $3722. (2c/2d/0d/ending NOT ported yet.)
- $1c44 = big multi-sprite chains, table $110db (arcade $873b): [y off, code, x off, next], attr hi for all parts, x offsets
  mirrored ($c0 - off) unless hi bit 6. Task 22 draws head $59e, body $59f, tail $5a1, legs $5a0 (leg frame $32 = bank 0).
- 23 body: ground = any of 5 cells to the -x side; walk 2 px / 7 frames within x $60-$d0 (legs $cce6 by phase, forwards
  or backwards by facing); fall 1 px a frame, settle 4 px (3 frames each); jump: crouch 30, up 4 (5 frames each), then
  cmd bit 4 -> down 12 (drop through the platform) else up 8 and on up to the next platform. 28 = airborne body frames
  ($94f6) until landed. 27 tail ($ccea) every 9 frames while walking. 29 head: towards target pose 1 per 10 frames ($cced;
  arcade $84f8 whose entry 0 is a jump operand - pose 0 is never used); pose 5 + cmd bit 7 = turn round; cmd bit 1 =
  breath script by pose ($ccf3 / $ccfb / $cd03: [wait, head] x 4, wait $19 = fire, twice if $5ae < $28).
- 2a AI (6 frames): Ptolemy 40+ px above -> jump if the column over its head is clear, else walk towards the edge/turn;
  128+ below -> cmd |= $11 (drop through); else keep 56-72 px away facing her (turn when behind). Fire when she is not
  above its mouth and in front: target = her position, pose by slope (v<<8)/h (< $ab 1, < $200 4, else 5), wait for the
  breath, then (v + h) / 2 frames.
- FIREBALLS = the MCU line stepper (user: "the mcu also controls the fireballs"). ARCADE (a45-20.mcu): cmd 4 $155 clears
  slots $39/$41; cmd 5 $15f: flag 1 (x major) / $ff, x/y = start, steps +-3, major/minor = |d|, acc = minor; cmd 6 $1c2:
  acc += minor (8 bit), >= major -> acc -= major, both axes move 3, else only the major axis. Z80 task 2b ($869e): read,
  draw $8e + (x & 1) (so it flickers between 2 frames), bounds (x $10-$df, y >= $18), burn check, THEN cmd 6.
  X68000 rebuild ($98d8/$997c): 4 px units, 8.8 slope, positions & $fc, stepped when the flag is read -> 33% faster, on a
  4 px grid, never animates. Port: per behaviour setting.

## ALL KNOWN ARCADE vs X68000 DIFFERENCES (consolidated, pass 27, updated pass 43) - port: F5 / --x68k (arcade is the default)
| # | what | arcade | X68000 | port mechanism |
| 1 | ghost bubble after a death | random 1-in-4 steps (LD A,R) along the MCU's sway table | 1 px every 4th frame, a straight diagonal | Director :ghost_move |
| 2 | Salamander breath | one more wind-up pose (+10 frames warning) | cut | Tables::VARIANTS |
| 3 | Cleric summon | one more wind-up pose (+10 frames) | cut | VARIANTS |
| 4 | Ptolemy's spell, rightward | 28 steps like leftward | last step lost: 1 frame shorter, shrunk version starts a pair late | VARIANTS |
| 5 | level-9 power-up timer | 230 ticks (byte after the table) | 256 (reads a 0) | VARIANTS item_timers |
| 6 | round 19 layout | continuous log (PCB confirmed) | 1-cell gap (row 16 col 23) | Tables::PATCHES |
| 7 | cake rounds' green ball (deco list $13, 17 rounds) | mirrored | not mirrored | PATCHES |
| 8 | randomness (items, Star Tiara stars, ghost) | Z80 refresh register: noise | $58c counter + vblank: very regular | World.r_reg vs World.rand |
| 9 | Dracolisk fireballs | MCU stepper: 3 px/frame, exact pixels, sprite flickers | 4 px/frame on a 4 px grid, no animation | Drac.mcu_* vs line_* |
| 10 | colour output | 4-bit levels x 17 (full 255) | DAC (c5*2+I)/63 (max ~247) | Palette.abgr |
| 11 | ending text | "THANK YOU FOR YOUR BRAVE ACT. ... IN YOUR HAND." | no full stop after HAND; the ORIGINAL-music copy says "FOI" | Tables::VARIANTS ending_text (pass 28) |
| 12 | protection | MCU state vault, ROM checksums, MCU-served round values/text/sway | removed; values hard-coded (same numbers) | n/a |
| 13 | sound | arcade sound board | MDRV.X FM + PCMDRV.R, ORIGINAL / ARRANGE soundtracks | MUSIC option, not BEHAVIOUR (pass 35-39) |
| 14 | title | 1985 TAITO tile logo, "INSERT  COIN<S>" | modern TAITO bitmap, "@ 1991 SPS", one space | attract.rb (pass 32) |
| 15 | continue | not offered on rounds 99-101 (< $62) | up to round 101 (< $65) | tied to MODE: ARCADE / CASUAL (pass 31) |
| 16 | ending jumps for joy | silent | jump sound $16 each jump | ending.rb (pass 35) |
| 17 | intermission priority strips | all 16 columns in one frame | 4 strips on 4 frames | intermission.rb (pass 36) |
| 18 | AI column search, target above-left ($4f9c) | walks to the column before the one found (+8 px) | to the column found | EnemyAI.l4f9c (pass 42, MAME both) |
| 19 | AI column scans | inc l / dec l: wrap inside a 256-byte page (rows 4/12/20/28 jump 7 rows up) | addq.l / subq.l | EnemyAI.step_cell (pass 42/43) |
| 20 | moon night | music $0a, then 240+240+40 frames | $3f, 240+240+22 | MoonTask (pass 42/43) |
| 21 | night / morning wipe | 34 / 35 frames, tasks resume the frame after | 38 / 38 frames inside one pass, no divider count, resume at once | NightWipe (pass 42/43, MAME both) |
Not differences (checked identical): player movement and tables, enemy AI/body (except 18 / 19 - "identical" was a
reading of the X68000 code; pass 42's MAME traces found them), Wizard/Cleric/Salamander code, shots,
spell, cakes/crush/combos, items and odds, moon/night, Horned, Worm, teleport doors, Dracolisk code, graphics (byte for
byte), palettes, round data otherwise, scores, EXP/levels, visible area (224 lines). Still to check: yield timing
(responsive-jump feel, pass 13b), Wizard-shrink EXP clamp, step-counter remainder, ending/intermission/continue code.

## Holy Gem + ending (pass 28) - fairyland/app/game/tasks/ending.rb (tasks 2c 2d 0d + port task 42 = $3722)
- Same sequence on both versions (arcade gem $898b, finale $8a1e, banner $8b4b, ending $8b8b; MCU command 7 serves the text).
- 2c: 20 frames, sound $38, Holy Gem sprite $f2 (set_c) where the Dracolisk was, colours: 10 steps x 5 every 7 frames
  (X68000: offsets $cd0c + ARCADE-format 0BGR words $cd22, byte-identical to arcade $89ba; arcade pens $cb..$c7).
- 2d: input override $ff, $5b0 = $ff; when she stands on ground: task 01 suspended, 4 jumps ($9bb0 [dy, pose] until a
  negative dy, poses $89-$8b via $1a48, sound $16 if $5b1 == 0, 15 frames after each); walks off ledges (input $fb if
  x < $80 else $f7) until y < $19, then to the Dracolisk x - 12; kills task 01, $5b0 = 0, celebrates for ever (4 jumps,
  40 frames, 1-4 random jumps, 30 frames).
- 0d = the "BONUS 1000000" banner (user's PCB frame): 120 frames, set_d $8d + 6 x $93 at y $a8 from x $98 (attr $f1, slot
  $28), colour cycling every 2 frames (X68000 lists $6042; arcade pen $13 [hi, lo] $8b82).
- $3722 (main loop; port task 42): wait for $5b0 == 0; 30 x 6 frames; $706 CLEARS name-table offsets $000-$6ff = screen
  rows 4-31 (arcade $0b9b writes zeros; X68000 also blanks its graphic screen) - only the HUD's top rows stay; kill 0d,
  clear 12 slots from $28, suspend 2c, palette SET 4 (colour 0 black) + graphic colour 63 = cyan (X68000 list $381a,
  arcade pen $b0 $fff0), resume 2c; score + $10 in the top BCD byte (+1,000,000 shown); $7ee = "1UP" + score only (the
  main-loop HUD does not run); 10 x 6 frames; $706 again; music $13; text typed 1 byte per 6 frames: block at $c5f1,
  wait 10, block at $c4f3, "101" ($982), rest, wait 10, block at $c17b, wait 60 (all x 6 frames); kill all, clear
  sprites, $592 = 0, round + 1; the caller sets lives = 0 -> game over / name entry (port: GAME OVER, new game).
- Text: control bytes 0 = end of block, $f0 n = cursor back n, $f1 n = attribute. ARCADE (MCU $20a): "IN YOUR HAND."
  (full stop, then <f0><a0>); X68000 $bd7a: no full stop (<f0><a2>); X68000 $be2d (default when $47 == 0): "FOI".
  Port: Tables::VARIANTS ending_text (arcade by default). Arcade loader now needs a45-20.mcu (image $10000+).
- BUG FIXED: the fight writes $ff into sparkle timers 1-2 = "disabled" (subq.b / bpl treats $fe as negative); the port's
  sparkle task counted them down and read past its frame table -> an endless sprite chain froze the game during the
  ending text (user saw it at "IN YOUR HAND. IT W"). Sprite chain walkers now raise after 64 parts instead of hanging;
  boot errors are written to error.txt and quit in --shot/--script modes; script logs are flushed every 60 frames.
- Verified against the user's PCB frames (fl_files/pcb/pcb_end_*): BONUS 1000000 banner over the room; black text screen
  with only 1UP/HIGH SCORE/scores, the text, Ptolemy and the gem. Dev: --drac_dead 1 skips to the defeat.
- TODO: name entry / game over / continue; $3862 is a second scripted scene (round 101 room rebuilt, Ptolemy driven by
  input script $bee0) - identify (attract mode?). tables.rb is at 135 of mruby's 256 symbols per module: split it soon.

## Intermission (pass 29) - RoundBuilder#build_intermission + fairyland/app/game/tasks/intermission.rb (task 25)
- User: Ptolemy rides her dragon RODOMY to the next castle; the picture is the castle of the coming round's theme.
- $2818 (arcade $7256) runs for every 0-based round index passed ($703 after the increment): index >= 7 and
  (index - 7) % 7 == 0 -> intermission q = (index - 7) / 7, i.e. before rounds 8, 15, 22 ... (q 0-12; entry 14 = attract).
- $1554 (arcade $727e) builds it: clear, attr $d8 fills ($c77f 14x32 tile $f1, $c3f3 1x$15 $f2, $c3bf 1x$1b $f3, $c373 8x$15
  $f4), mirrored frame block $abd8 (arcade $7434) attr $d0 at $c331, deco list $aaae (arcade $734c, 5-byte format),
  entry table $ac8e (X68000 8 bytes [w picture, w palette, l message] / arcade $74ea 4 bytes [picture, palette, w
  message]): castle picture 0-4 (blocks $ac57 + 11k, arcade $74b3; attr $99 for 0-2, $d9 for 3-4) at $c4fb, palette set
  5-7, HUD; speed $71f = 1 + music $0d, or 8 and no music after a warp ($653). Message at $c5fb, attr $19, $0d = next
  line ($c5fb - $80): 13 messages ("WELCOME TO THE FAIRYLAND !" ... "COME ON NOW ! YOU ARE GETTING NEAR THE END.").
- Palette sets 6/7: arcade = the next 128-byte chunks after set 5 (overlapping the fixed / boot tables), equal to the
  X68000's sets 6-7 (verified 64/64) - the arcade palette rebuild now makes 8 sets.
- Task 25: priority on $c5bf 12x16 (left half rows 9-20); flyer at y $70, x from $80 += speed each frame with a random bob
  ($58c / arcade LD A,R at $7795; curve $cc46 by a 0-$8f counter >> 2) and two channels (Ptolemy $cc34 5 x [time, frame],
  Rodomy $cc3e 4 x) via $1b8e; x wraps to 0 -> priority cleared on strips $c5a7/$c5af/$c5b7/$c5bf (12 rows x 4 cols) on 4
  consecutive frames; at x $80 priority set on $c547/$c54f/$c557/$c55f (15 x 4); at x 0 again: clear sprites, $71e = 0.
  So the flyer is hidden on its first leg (centre to the left edge), enters at the right edge, crosses the sea and goes
  behind the left cliff. While crossing the screen edge the chain's parts split between both edges (sprite x wraps at
  256; same placement as the X68000) - user saw it as "a little glitchy when they come in": compare with PCB footage.
- mruby: Array#fill(nil) raises (nil counts as no argument) - use map! { nil }.

## Game over / continue / name entry - analysed (pass 30, not ported yet)
- Both versions: lives - 1 (BCD) unless endless; 0 -> sound $10, "PLAYER< > GAME OVER" at $c4b3 attr $39 + player
  number at $c4a5 attr $38, 38 x 6 frames; then high-score table / name entry (X68000 $2d84, arcade $6f18: "SCORE  ROUND
  NAME", letters ".ABCDEFGHIJKLMNOPQRSTUVWXYZ!? " then END), two-player swap ($70f / $e78d), then the continue screen.
- Continue screen (X68000 $2cc0, arcade $8c7c): records last/best round ($6ce/$6cf, saved to the FS.DAT disk on the
  X68000); only if continues are enabled (X68000 option, arcade DSW $d802 bit 3), not in the demo, 0-based round > 6 and
  round < $65 (X68000) / < $62 (ARCADE: no continue on rounds 99-101 - see the consolidated table); palette set 4, the MCU /
  $bcb9 text "TO CONTINUE GAME / INSERT COIN AND / HOLD JUMP OR SPELL BUTTON / THEN PUSH START BUTTON / BEFORE / TIME COUNT
  ENTERS 0. / TIME" at $c62f, countdown 10..1 at $c1e1 (attr $38, 10 x 6 frames each). Arcade: credit > 0 + JUMP or SPELL
  held + START -> continue; X68000: SPELL ($62 bit 5). Continue ($02e9 / $1f86): a credit, lives from the setting, SCORE
  AND LEVEL RESET TO 0, steps 0, Horned path 0, moon $78, same round ($1fd8).
- X68000 GAME OPTIONS ($348e-$3642): LEFT n / ENDLESS, MUSIC ORIGINAL/ARANGE, CONTINUE OFF/ON, DISPLAY 15/31KHZ, ENDING
  ARCADE/X68000 ($578 bit 1) - so $3862 (round 101 room rebuilt, Ptolemy driven by input script $bee0, tasks 1e) is
  probably the X68000-ONLY extra ending scene, not attract mode: check.
- Intermission CONFIRMED against the user's PCB frame (pcb_inter_0-2-32) and MAME: the split flyer at the screen edge is
  original behaviour.

## Game over, name entry, continue, save file (pass 31) - tasks/gameover.rb (43 44 45 + 02), game/save.rb
- Modes (user design): ARCADE (default, --mode arcade) = continues allowed (arcade rules: rounds 8-98), progress NOT saved,
  the ONLY mode that records high scores; CASUAL (--mode casual) = progress saved like the X68000's FS.DAT (last / best
  round for ROUND SELECT), continues on rounds 8-101, high scores not recorded (fixes the Sharp port's flaw of saving a
  high score from a round-select game). Arcade mode will get a pre-game setup screen (behaviour, OST, QOL) - TODO.
- save.txt in the game folder: last_round, best_round, 5 x score=<6-digit value>,<0-based round>,<name>. Defaults from the
  game data (X68000 $bc96 / arcade $7233: KBT 50220 r7, MAD 47310, ONJ 46260, KMJ 46130, ISD 45710). HIGH SCORE = table top.
- Flow: lives 0 -> task 43 "PLAYER< > GAME OVER" (+ "1" at $c4a5), sound $10, 38 x 6 frames -> ARCADE and score > 5th:
  name entry (task 44: sound $11, table $2bf0 with the new slot blank, task 02 "ENTER YOUR INITIALS !" flyer ($4904: sign
  block tile $5c attr $3b at $c687 then $c6bf, sprite $40 at y $b8 writing one letter per 8 px at $c633 attr $1a), 42
  frames, "SCORE  ROUND  NAME" + score + round, wheel ".A-Z!? " (L/R move every 2 polls while held, JUMP/SPELL confirms on
  an edge, polled every 6 frames, 100-poll timeout per letter), "SEX" -> "H !", sound 4, 60 frames, "BEST 5" + table, 240
  frames, save) -> continue screen (task 45: text at $c62f, 10..1 at $c1e1, 60 frames each; JUMP/SPELL = continue in the
  port's free play) -> continue: new game state (score/level/steps/Horned path/moon reset, lives from the setting, high
  score kept), the same round; else a new game at round 1 (title screen TODO). After the ending: lives 0 -> the same path
  with round 102 ("ALL").
- RENDER FIX: the background could come out white (DragonRuby's placeholder for a missing texture) after a scene change.
  Now Screen uploads both layers EVERY tick, once, just before drawing (Screen.flush), into buffers allocated once.
- SPRITE PRIORITY ($57e, user-reported missing bubble sheen): 32-entry lists, FIRST entry drawn on top (MAME flstory draws
  the arcade list $dc80-$dc9f from its end; X68000 entry k -> hardware sprite k). Lists 1/2/3 = X68000 $b158 + 64n idx
  bytes = arcade $0510 + 32n (& $1f; flags $a0 everywhere; list 2 swaps Ptolemy's two halves, invisible). List 1: Ptolemy
  (indices 1-2) is drawn BEHIND everything; list 2 (death $409a, potions): bubble parts 1c-1f (slots $70-$7c) in front of
  her = the white sheen, 18-1b behind; list 3 = eaten by the Worm; burnt death and item end -> 1. Port: GameData#sprite_order,
  w[:prio], draw_shadow follows it (indices 32+ drawn underneath).
- DragonRuby: an unset args.state attribute reads as nil here, but `new_game` ran twice at boot - dev values go in boot.
  Dev flags: --lives N, --start_score N (internal value = displayed / 10), --mode casual|arcade.

## Title + attract mode (pass 32) - fairyland/app/game/tasks/attract.rb (port tasks 46-4a + task 1e), main.rb start_title...
- Sequence (X68000 $22a4, arcade $6733 - same code; every wait is a 6-frame tick, interruptible by a coin):
  title ($22d8): palette set 4, 1 tick, logo colours blacked out ($b2d8 / arcade `ld c,pen; ld de,$f000` x4 at $676d),
  1 tick, logo block $a3e2 / $0c5b at $c62f attr $bb + TAITO + "@ 1985 TAITO CORPORATION" at $c177 (X68000 also
  "@ 1991 SPS" at $c137) + top line, fade 1 ($b3a6 / $699e, 4 steps), 5 ticks, fade 2 ($b3e0 / $69b7, 5 steps: the
  logo flashes white then turns pink), sparkle block list ($b414 / $69d6, 15 groups of 1-2 blocks, attr $bb), 50 ticks
  -> attract intermission ($27c4: picture $e, "INSERT  COIN<S>" at $c5ad instead of the message, X68000 one space;
  DSW $d802 bit 4 / $578 bit 4, the default; off = the arcade shows coinage text, the X68000 stubs it) then 10 ticks
  -> demo -> BEST 5 ($2bd4, 50 ticks) -> title. Timings checked against MAME: title 468 frames, intermission 446-448.
- Fade lists patch the GRAPHIC palette: X68000 byte offset / 2 = colour word; arcade pen $80-$bf -> word (arcade_pen & 63).
  The X68000 lists also fade word 22 (blue) - the modern TAITO logo's colour.
- TAITO logo = BEHAVIOUR difference (user): arcade = the 1985 logo, a 2x10 tile block $0d0d at $c229 attr $b9; X68000 =
  the modern logo (blue triangle + dot), an 80x24 256-colour bitmap $9c30 written into GVRAM at cell (11,22) by $eee.
  The X68000 BGCHR (half 0, bank $80) still holds the old logo's tiles, so the port keeps their 20 codes in code and both
  logos work from the disk; ROM data only has the old logo (X68000 behaviour falls back to it). Screen.overlay draws the
  bitmap.
- Demo ($23b8): demos cycle via $6b9 (+1 first): table $b2ee / $68f6 = 0-based rounds 61, 0, 1 -> shown in the order
  round 1, 2, 62. Lives 3, EXP 0 ($57f), no intro / READY / moon / HUD refresh ($7b8 not called: no ROUND / lives),
  2 ticks after the build the enemies load, Ptolemy at ($a0, $18), tasks 0 4 10 0e 1e. Scoring is off ($592 != 0).
- Task 1e ($8504): input script = [active-low input, ticks] pairs into $592, 0 ends (the last input stays). Scripts are
  identical in both versions. Demo end: polled each tick, $62e != 0 (death) or $5fd & $7f == 0 -> 6 more ticks of play,
  $1890 kills every task, 5 ticks frozen, BEST 5. The port's round-1 demo matches MAME almost frame for frame (only RNG-
  dependent enemy drift; the arcade uses LD A,R).
- The attract is silent ($ee at $1e78; w[:muted] in the port for the future audio layer). Arcade boot: DSW $d800 bit 2
  = free play (credits = $14), else the attract ($6733); $07a3 is the credit / PUSH START screen (X68000: $32fc menu
  "1PLAYER START / 2PLAYER START / GAME OPTION", $3206 ROUND SELECT).
- X68000 $591 bit 5 mirrors the arcade's $df03 bit 5 = palette BANK for writes (MAME flstory); title clears it, the demo
  and games set it. The port does not need it.
- Port: boots into the title (dev flags --round/--shot/--script/--inject/--pos go straight to a round). Enter starts a
  game for now (coin-up menu = next step). Continue timeout -> title. Dev: --shots t1,t2 saves shot_t<N>.png and quits,
  scenes.txt logs each attract scene's start tick.

## Coin-up menu + ROM identification (pass 33) - tasks/menu.rb (port task 4b), game/settings.rb, fs/game_data.rb
- Enter during the attract = a credit -> the menu (coin jingle $06). X68000 front end as the model: start menu under the
  logo ($10a4 / $32fc: items attr $38 on consecutive rows from $c32b, cursor glyph $5b attr $3c at $c32f, the column
  cleared with $20 attr $38 - a blank with attr $3c shows group 4's colour 0, an orange square), GAME OPTIONS ($346a:
  selected row attr $3a, others $39, up / down row (wraps), left / right value), ROUND SELECT ($3206: starts at $6ce =
  last round, 1..$6cf = best, no wrap), key repeat $3296 (new press at once; held: after 16 frames, 4 x every 16, then
  16 x every 4, then every frame).
- Port pages: main = ARCADE START (high scores recorded) / CASUAL START (progress saved, ROUND SELECT) / GAME OPTIONS;
  setup per mode = [ROUND (casual)] LIVES 3/4/5/ENDLESS, BEHAVIOUR, MUSIC ARCADE/ORIGINAL/ARRANGE (stored only - audio
  not ported), SHORT HOP, RESPONSIVE JUMP, START GAME; options = COLOURS STANDARD/PCB, EXIT. Esc / Backspace = back
  (main menu -> title). Choices persist in settings.txt (key=value); command-line flags override them for the run.
  Behaviour / colours apply at once. Dev: --keys "tick:coin|up|down|left|right|ok|back,..." injects presses.
- OPEN (user): is the cursor's orange backing authentic X68000 look? ENDLESS lives in ARCADE mode still records high
  scores (the arcade DSW allowed it). The QOL set in the setup page = the two existing options for now.
- ROMs are identified by CRC32 of their contents, not names (whole files, or 16 KB / 2 KB blocks of a merged file up to
  1 MB). MAME "flstoryo" (older set, user-supplied) = "flstory" except the sound CPU ROMs a45_12.8 / a45_13.9 (instead of
  snd.22 / snd.23), which the port does not use. Taito Legends 2 (Xbox / PC) carries the old MAME set without the MCU;
  a45-20.mcu is REQUIRED (continue text at image $102be, arcade ending text) - the error message says where to get it.
  Arcade Archives (PS4 / Switch) extracted files: not seen yet - the block scan should catch renamed / merged dumps if
  the contents match; a different revision would need its own CRCs (and maybe table addresses).
- Tested: renamed + merged flstoryo files render pixel-identical to the flstory files; missing MCU -> clear error.

## Arcade rules, extends, pause, widgets, jump timing (pass 34)
- SCORE EXTENDS were missing in the port (only the Book of Life gave lives). $2976 (every frame of the gameplay loop):
  threshold in the score's top 4 BCD digits ($70a:$709 vs $700:$701); bit 0 of $709 = repeating stage. First pass:
  threshold = the step ($58d:$58c), whose own bit 0 sets the flag; repeating: threshold += step (BCD), overflow = no
  more. Lives + 1 BCD (99 + 1 wraps -> skipped), sound 8, $29f4 redraws lives. DIP table X68000 $920 ([$58d $58c $70a
  $709] x4, entry = $576 & 3), arcade $09d8 ([step lo, hi, first lo, hi] x4, entry = DSW $d800 & 3): 0 = 30,000 / every
  100,000 (FACTORY, MAME default, X68000 $576 = $ec), 1 = 30k / 150k, 2 = 50k / 150k, 3 = 70k / 150k. Port:
  Score.extend_check (entry 0); ENDLESS stays endless. Verified: 29,990 none, 30,000 one, 100,000 two, 199,990 two.
- MAME DIP defaults: Bonus Life 0, Lives 3, Allow Continue on, Attract Animation on (= the port's ARCADE mode).
- X68000 keys: ESC = pause ($27c in the vblank handler: press, release, press, release; no text; not in the options
  screen $46). F1 ($63, group $c bit 3) = lose the current life ($62e = $40, $596 = $ff no killer); F6 ($68) = the same
  + $4a (quit). Port: Esc / P pause menu - CONTINUE / LOSE A LIFE (CASUAL, only while the director runs) / QUIT TO MENU
  (CASUAL records the round reached). Drawn on its own overlay layer (Screen.overlay_cells, colour 0 = black).
- MODES (user, decided): ARCADE = strictly the arcade (factory DIPs: 3 lives, 30k/100k extends; no QOL); only BEHAVIOUR
  can be chosen. CASUAL = ROUND SELECT, LIVES, BEHAVIOUR, SHORT HOP. GAME OPTIONS = MUSIC, COLOURS, WIDGETS.
  s.prefs = settings.txt (the menu edits it), s.settings = the game's own (derived at START GAME; dev flags on top).
- JUMP TIMING MEASURED IN MAME (Lua: 1-frame taps of P1 Button 2 = jump, logging $e6a9 x / $e6aa y / $e6ce = the input
  the player task stored, $42e1): standing still, the arcade reads the input once every 3 frames (the walk step yield
  $634), so exactly every third 1-frame tap jumps; take-off 2 frames after the tap. The port's default does the same
  (same 2-frame take-off, same pattern) => the default IS arcade-exact. The old responsive_jump QOL (8-frame buffer +
  early wake) was REMOVED (user decision, pass 34b): option, F3 key, --responsive_jump, w[:jump_buffer] all gone; the
  tap test gives the identical arcade pattern afterwards. If the port feels slower than hardware, look at input-to-display latency (window /
  vsync / render target), not the game logic.
- Widgets (gfx/widgets.rb, left border, game screens only): LEVEL + EXP / next, BONUS ITEM (walk counter to 800 px + the
  items possible now with their odds: group by enemies left, tier odds by EXP bracket), TIMER ($610 -> hurry $41 /
  Horned $46; last-enemy escape), MOON (ticks x 2 s, x 1 s shrunk; "risen" after $f0). Item icons = sprite bank 1,
  palette 13 (attr $ed). Dev: --widgets 1. F12 now toggles the old dev text (right border, off by default).
- Power-on score (user, confirmed on a MAME cold boot): 1UP = 13,090 - arcade $01d7 `ld hl,$0913 / ld ($e77f),hl`,
  X68000 $1df4 ($701 = $13, $702 = $09); HIGH SCORE = the best-5 top (50,220 by default). After a game the attract shows
  the last score (the original never clears it there). Port: boot sets score 1309; back_to_title keeps the score.
- MAME GOTCHA: the user's MAME has `autosave 1`, so plain runs RESUME from ~/.local/state/mame/sta/flstory/auto.sta and
  overwrite it on exit (pass 33-34 runs did that: not cold boots, and the user's old flstory autosave was replaced).
  Always run MAME with -noautosave.

## Audio layer (pass 35) - fairyland/app/audio/audio.rb, fairyland/audio/ (gitignored, release builds only)
- Files: audio/<set>/<cmd hex> <any name>.ogg|.wav, sets arcade (OST music + effects) / original / arrange (X68000
  OSTs). Music = FM commands ($06-$15, $30, $31, $38, $3f per $4ee) on one channel from the MUSIC set (fallback arcade);
  PCM commands one channel each (a repeat restarts). $00 stop all, $ee stop + mute, $ef unmute; attract worlds are muted.
  Played right after the tasks run (same frame as the original's $4ac call); sounds queued during a scene change play
  at the start of the next frame. Script logs list "audio: <file> xN".
- First file from the user: "ptolemy jump.ogg" = $16 (CONFIRMS sound_commands.csv $16 = the jump, task 01 $4604 at take-off)
  -> audio/arcade/16 ptolemy jump.ogg (mono 44.1 kHz, 0.25 s).
- TODO: loop points (<file>.loop "start end" samples), the $21 loop lock, "wait for jingle end" ($56c) queries,
  pausing audio with the pause menu, volume options.
- DragonRuby: no Regexp in mruby (a regex raised inside a rescue -> silently empty index).
- ARCADE OST (user's PCB recording, 13 FLACs, pass 35b) -> audio/arcade/music/ via ost_loops.py. Command map (tracks.txt):
  $06 Credit, $07 Stage Start > First Half BGM, $09 First Half BGM, $30 Stage Start > Second Half BGM, $31 Second Half,
  $08 Extend, $0b Miss, $0c Stage Clear, $0d Intermission, $0a + $3f Moon - Invincibility (Change Potion / night),
  $10 Game Over, $11 Name Entry, $12 Hurry Up! - Dracolisk (Horned, round 101), $13 All Clear. Inferred: $07/$30 chain the
  start jingle into the BGM (the intro sends only $07; $09/$31 restart the BGM alone). Not in the OST: $0f (Worm death),
  $14 / $15 (moon rise / morning), $38 (Holy Gem) - probably in the user's SFX set ("boot up and sun", "holy gem").
- Loops found by self-similarity of 48-band log spectra + waveform cross-correlation, all exact repeats (corr 1.0000):
  First Half start 40390 period 1881236 (42.658 s); Second Half 14655 / 1389750 (31.514 s); Hurry Up 229735 / 3523510
  (79.898 s); Moon 19755 / 451552 (10.239 s); Name Entry does not repeat (one-shot). Loop starts moved to whole frames
  after the first note so the intro -> loop switch is frame-exact (Audio.tick counts lengths.txt / 735). Seam check on
  the decoded OGGs: loop lengths sample-exact, wrap jump 0.001-0.05 vs p99 step 0.15-0.20. Short intros decode up to 77
  extra samples (Vorbis end padding, the note tail, <= 1.7 ms overlap). Jingles trimmed to last note + 0.25 s; Stage
  Start cut right after its last note (3.583 s) so the BGM follows at once - the real gap is unverified.
- Engine: Audio.update starts music sequences, Audio.tick advances them, Audio.pause holds all channels for the pause
  menu, stop_all on the title / menu.
- Effects added (user's M1 rips, hand-edited and low-passed - NOT PCB recordings; replaced by MAME in pass 36): $1c "salamander" (wind-up, poses $17/$1b), $1e "salamander
  fire" (fireball launch; the same command is Ptolemy's Scroll of Fire shot and the fire sparkle of the burnt death),
  $20 "ptolemy blink" (user: the sound after she is burnt = $427a in the burnt animation; plays for each table byte 2),
  $28 "enemy crushed" (cake lands on an enemy), $39 "dracolisk fire". "ptolemy burned" is NOT installed: the burnt hit
  is $1e on both versions (arcade $1e has the same 3 call sites), so one file per command - user to choose; the two
  recordings share a spectrum (0.99) but differ in envelope (0.65), i.e. the same noise voice.
- $56c "music busy" implemented (Audio.busy?): the death now waits for the Miss jingle (verified: restart 311 frames
  after $0b, Miss.ogg = 310 frames); a looping song counts as busy (MDRV); an FM command without a file silences the
  music channel (so the moon's waits after $14 / $15 cannot hang under the BGM).
- PCB difference (user): no Salamander wind-up once Ptolemy is dying, yet both versions' code keep sending $1c until
  $423c kills every task (no $62e check in the enemy code; the arcade writes $d400 directly). Likely the sound board's
  effect priorities (snd.22 / snd.23 unanalysed). Port: Audio drops $1c while end_code != 0 (verified round 7).
- Dev: --freeze 00,1d (hex enemy types) stops those enemies' tasks (e.g. the Orc, to let a Salamander burn Ptolemy).
- Burnt death plays no Miss jingle - as in the code ($41ae path goes straight to the end).
- Round-start timing MEASURED in MAME (-noautosave -wavwrite, coin at frame 600, start at 800): coin -> one sound
  (= "01 Credit", envelope / spectrum match 0.95) = $06; Stage Start onset 13.735 s, BGM onset 17.550 s => the BGM begins
  3.815 s after the jingle's first note (the jingle itself is audible ~2-3.6 s, then a pause). Port: "02 Stage Start.ogg"
  cut to 229 frames (CHAIN_FRAMES in ost_loops.py), was 3.583 s = 0.23 s early (user: "cuts out a little early").
- More effects: $2a "ptolemy hit" (death by an enemy, $40b0), $1a "ptolemy crushed" (squashed body lands, $3fe6),
  $1b "wraith" (Wraith vanishes from the spell, $5f64), $2f "cake land" (a cake with one enemy breaks on landing).
  $1e keeps "salamander fire" (user OK). "coin.ogg" = $1d, the combo / night bonus coin PICKUP (task 17 $7c62; user).
- EXTEND JINGLE ($08) MEASURED in MAME (extend forced by writing 0 to the threshold $e787/$e788 at a known point of the
  round BGM, invulnerability DIP on): the BGM goes silent at the command, the jingle plays, and the BGM is heard again
  2.58 s (155 frames) later at the point it would have reached anyway (4.48 s into the BGM before, 10.06 s after; matched
  against the user's FLAC at 0.83-0.84). => the BGM keeps running muted underneath. Port: Audio::OVERLAY {$08 => 155}:
  the jingle goes to its own channel, the music channel is muted for 155 frames while its sequence keeps advancing.
  (User report: "music doesn't resume after an extra life" - fixed. Their Extend recording has the BGM bleeding in,
  which fits: on the board the BGM is still playing; a clean re-record is planned.)
- Levels: the music OGGs decoded up to +2 dBFS (Vorbis overshoot on ~0 dBFS masters) -> ost_loops.py GAIN -3 dB, peaks now
  ~-4 dBFS; effects peak -3..-15 dBFS. GAME OPTIONS: MUSIC VOLUME (default 8) / SFX VOLUME (default 10), 0-10.
- More effects: $17 "ptolemy attack" (her spell, $4a12), $19 "wizard" (the Wizard's shrinking spell, $5bbc).
- VERSION DIFFERENCE (user, confirmed in code): the ending's jumps for joy make the jump sound only on the X68000 (task 2d
  $9ba8 sends $16); the arcade has a single $16 site, the player task ($44c9) - its ending is silent. Port: behaviour-gated.
- Menu rework (user): BEHAVIOUR moved to GAME OPTIONS (a preference for both modes - it also covers the presentation
  differences: TAITO logo, ending text, the ending jump sound). ARCADE START now goes straight into the game (factory
  settings, nothing to choose); CASUAL START -> ROUND / LIVES / SHORT HOP / START GAME. GAME OPTIONS: BEHAVIOUR, MUSIC,
  MUSIC VOLUME, SFX VOLUME, COLOURS, WIDGETS, EXIT.
- Cursor = glyph $5b (Ptolemy's red hat) attr $3c, as on the X68000. Its background is graphic colour 64 (group 4 colour 0):
  the X68000 menu $3348 patches it to black ($3364: offset $80 -> $0001) and only $336a (confirming a start) turns it
  orange ($8681) - the orange square seen earlier was the port missing that patch. Port: the menu world applies {64 => $0001}
  (matches the user's Sharp screenshot); the pause overlay draws colour 0 black anyway.
- Pause fix (user: "no give up option on casual"): LOSE A LIFE required the director running and no death in progress,
  so it was hidden during the broom entrance / READY / a death - exactly when players look for it. Now shown in every
  CASUAL round world (w[:round_world]); main.rb applies w[:give_up] as soon as the director runs and end_code is 0
  (verified: chosen during the entrance -> READY plays -> death at the start of play). Dev runs (--round) are ARCADE mode.
- Main menu: QUIT GAME (exits the port; settings saved first).
- More effects: $35 / $36 / $37 "dracolisk defeated 1/2/3" (turns into the giant cake $911c / the cake lands, crumbling
  starts / each crumble step), $38 "holy gem" (FM command, the 15 s gem sequence, music channel), $14 "boot up and sun"
  (user: the same sound at power-on and at the moon event's sun; from a raw MAME WAV: trimmed to 2.43 s, mono, PROVISIONAL
  2-pole 8 kHz low-pass, peak -4 dBFS - the user low-passes each effect by ear to match the PCB, so their own version
  should replace it). Measured -50 dB rolloff of the user's processed effects: ~4-8 kHz for noise-type sounds, up to
  20 kHz for tonal ones; raw MAME output is full band (24 kHz).
- Power-on now plays $14 on a black screen and waits for it (at most 50 ticks, as $1e22 / arcade $0204) before the title:
  port task 4c (BootTask). Measured: title at tick 147 = the 2.43 s sound.
  The boot screen is BLUE (user; MAME cold boot: solid RGB 0,0,170 = blue level 10 from the first frames to ~frame 170,
  then black, title ~frame 200). Port: drawn through Palette.abgr (PCB profile -> 127). Optional: GAME OPTIONS >
  BOOT SCREEN (default ON). DragonRuby: solids draw UNDER sprites in a render target - use path :pixel sprites.

## Attract fixes (pass 36)
- Demo hang (user: round-2 demo, Ptolemy's ghost bubble then a freeze): the demo watcher ($248c) is MAIN-LOOP code in the
  original, but the port ran it as task 49, so the death sequence's $1890 (kill every other task) killed it. Tasks spawned
  with `main: true` now survive Scheduler.kill_others. A demo death is then cut 6 ticks in (during the hit pose): no
  bubble, then BEST 5, as on the arcade.
- Intermission flyer (user: Rodomy "doesn't fly in cleanly"): CORRECTS pass 29's "split flyer = original". The arcade's
  8-bit sprite x WRAPS (MAME flstory draws sx and sx - 256), so a part straddling the left edge (shadow x < 16) also
  shows at the right edge; the port drew it only on the left, under the priority cells, so his head seemed to pop out of
  the cliff. draw_shadow now draws the wrapped copy. ("Arcade only" here was WRONG - see pass 41.)
  Arcade task 25 ($772b) also clears the $c5bf 12x16 priority area in ONE frame ($7844) and sets $c55f 15x16 in one frame
  ($782f, rows go up and columns left in name-table bytes); the X68000 spreads both over 4 frames as 4-column strips.
- Effects added (pass 36): $14 "boot up and sun" (boot jingle + moon rise; FM, played on the music channel, waited on via
  Audio.busy? until DragonRuby drops it), $35-$37 "dracolisk defeated 1-3", $38 "holy gem" (FM, music channel),
  $22 "enemy caked" (sparkle type 0 = the spell hit, also item / moon sparkles), $24 "cleric" (summon), $25 "enemy erased
  from existence" (time up: the last enemy escapes / Horned leaves), $2d "earthquake" (Book of Death),
  $21 "star tiara": the user's recording holds the sample twice (envelope ramps up again 8.009 s in; repeat not
  sample-exact - noise voice, xcorr peak 0.23 at 384447 samples). Installed as ONE cycle (48 kHz samples 10928 + 384447,
  from the onset) and LOOPED by Audio (LOOP_SFX), i.e. the driver's restart-at-end ($574); $01 deletes it (verified:
  $21 at the pickup, $01 when the first star leaves after the power-up ends).
- EFFECTS RE-RECORDED FROM MAME 0.289 (pass 36, mame_sfx.py): the user's set were old M1 rips; current MAME models the
  board (YM2149 + MSM5232 + DAC, the TA7630 volume / tone the sound program drives). Method: boot flstory, after 900 frames
  park the main CPU (`jr $` at $e7f0, PC forced there with IFF off every frame), then per command write $d400: $00, $ef,
  cmd, window, $00 ($01 first for $21). The board REPLIES through $d400 after $14 (the boot jingle handshake, $d401 bit 1
  = reply pending) and stalls until the main CPU reads it: the script reads $d400 every frame. Output has a wandering
  DC level (idle DAC): pieces are found on the sample-to-sample difference, DC removed, 2 ms fades. MAME's mix is quiet:
  ONE gain for all (x4.80 = MAME's $06 credit jingle matched to the OST's "01 Credit"), so effects keep the board's
  balance against the music. Checks: $06 2.42 s vs OST 2.50 s; spectra vs the M1 rips 0.94 ($2a), 0.98 ($28), 0.31
  ($16 - same peak band). $04 (name-entry beep, arcade $7006 / $70dd) is SILENT on the board - user confirms no beep on the real hardware (the X68000 does play one: PCMDRV). $21 one cycle = 7.873 s in
  MAME (M1: 8.009 s), noisy so not sample-exact. $38 Holy Gem LOOPS (2.0084 s phrase, never exact: xcorr 0.80); it must,
  since she walks to the gem under player control - now a music entry (121-frame intro + one cycle looped, tracks.txt).
  Installed: every effect + FM $0f (Worm eats her) / $14 / $15 (morning) / $38; music commands stay the OST. New: $15,
  $18 bonus item appears, $26 enemy burns, $27 item collected, $2b feather warp, $2c feather collected, $2e Change
  Potion burn, $32 worm, $33 ice slide, $34 ice shatter, $0f. M1 files kept in audio/arcade_m1/ (not scanned).

## Sound board TA7630 tone controls (pass 37) - mame_sfx.py, audio/arcade{,/jotego,/flat}
- MAME flstory ignores the TA7630's tone controls (driver TODO "TA7630 emulation needs filter support"; AY port B =
  "bass / treble for AY?" unused) and reads $ce00 as MSM group-2 VOLUME. Jotego's FPGA core (jtcores/cores/flstory,
  built from a redrawn PCB schematic; README: "a lot of analog audio features that the sound CPU can control, such as
  balance, treble, bass") decodes: $cc00 = MSM {vol, balance between the MSM's two output groups}, $ce00 = MSM {treble,
  bass}, AY port A = AY {vol, balance}, AY port B = AY {treble, bass} (high nibble first). Idle value $88 everywhere.
- Per command (logged writes during each sound; t/b = treble/bass nibbles): AY $0F (treble 0, bass 15) on $16 $17 $26
  $2d $35; $1F on $32; $2F on $36; $2D on $37; $4F on $24; $60/$68 on $25; a treble SWEEP $0F -> $7F.. on $1e and $39
  (the filter opening); treble 15 ($FF/$F8/$F0) on $18 $20 $27 $28 $2b $2c $2f $34; $E6 on $1c; $81 on $1d $21. The
  music uses the MSM side ($06 $88/$98, $0b $b8, $0d $a5, $13 $a5/$a8, $14 / $38 treble 15 ...).
- mame_sfx.py records 4 deterministic MAME passes with a write tap forcing the volume bytes (MSM group 1 / group 2 /
  AY at full, the rest 0) -> stems by difference (exact: MSM stems are 0.0 during AY-only effects; the all-off run
  leaks MAME's volume-0 gain, -35.6 dB) + the DAC; the real writes are logged with emulated time and the stems mixed
  again: Jotego's jt7630_bal (normalised to unity at the centre) and jt7630_vol, then a tone stage:
  * BOARD (default, audio/arcade/): first-order shelves, 8 = flat, -16 + 2n dB (Jotego's own comment "0=-16dB,
    15=14dB, 2dB step"), bass 100 Hz, treble 2.5 kHz. $88 effects come out within ~1 dB of raw MAME; treble-0 ones 8-12
    dB darker above 4 kHz (as the user's hand low-pass on the old M1 rips); treble 15 ones 9-13 dB brighter.
  * FPGA (audio/arcade/jotego/): jt7630_equ as built - (bass*lp0 + treble*hp1 + hp0 + lp1) / 2 with coefficients
    designed for 192 kHz (filter/hi100.m) but clocked at 48 kHz (cen48k): hp1 turns at ~2.5 kHz, lp0 ~13 Hz. Setting 8
    already lifts the highs ~6.5 dB and 0 is flat, so treble-0 effects end only ~6.5 dB darker than the rest.
  * OFF (audio/arcade/flat/): volume / balance only.
  Sources' idle DC is removed BEFORE the volume stage (the program changes volumes after a sound ends: a click on DC;
  Jotego's core removes DC after the volume). Trim: detection above 80 Hz, stops at the first gap > 0.5 s unless a real
  sound (>= 50 ms) follows (the board resets channels ~2.3 s after $16: a lone pop). One gain for all (BOARD x3.14 =
  MAME $06 matched to the OST's 01 Credit); pieces that would clip are scaled alone ($14 -8.8 dB, $08 / $0c (OST
  anyway), $18 -1.4, $38 -1.6).
- GAME OPTIONS > SFX FILTER BOARD / OFF (settings.txt sfx_filter board|off): Audio swaps any file it plays for its
  namesake in <set>/flat/ when one exists (effects and the $38 intro / loop). An FPGA choice (Jotego's equaliser) was
  tried and DROPPED: user heard it as identical to OFF (as expected: his treble 0 = flat) and BOARD as the real thing.
- The user's old M1 rips are deleted (user request); the effects are all MAME now.
- Dracolisk defeat: $36 comes 20 frames after the giant cake lands, in BOTH versions (X68000 $91ba, arcade $8214:
  `ld a,$14 / rst $30`, then $36); the port matches; the files have no lead-in. (User: "starts way too late" - open.)

## Glass Potion translucency (pass 37b)
- User: on PCB, MAME and X68000 glass Ptolemy is white AND semi-transparent. Not a blend: $1d4e (X68000, called by
  the main loop right after the scheduler $18b6, before sound $574): while $626 != 0 flip its bit 0; odd -> save and
  zero the display byte (+5 / +$d) of her two shadow sprites at $e004 (slots 4 and 8), even -> restore them unless a
  task rewrote them. The next frame's shadow copy shows her on alternate frames only (30 Hz flicker). The palette
  patch stays colour-only (arcade pens $0b/$0c = sprite palette, $df03 bit 5; priority bit 12 unchanged; every
  draw-order entry is $a0-$bf = sprite priority class 5 in all lists). Port: main.rb toggles w[:mode626] after
  Scheduler.run, draw_shadow skips shadow indices 1-2 on odd values (verified: frames 300 / 302 hidden, 301 drawn).
- Hardware note (Jotego's colmix): sprite-vs-tile priority is a per-pixel lookup {sprite class (draw-order bits 7-5),
  tile priority (2 bits), tile pen (4 bits)} into bit 12 of palette RAM. MAME (and the port) use tile categories
  instead. No visible difference found so far; revisit if a layering bug turns up.

## Lives / ENDLESS and the name-entry music (pass 37c)
- ENDLESS comes from the SETTING only (X68000 $2a18: $576 & $18 = 0; arcade $0dcc: DSW $d800 & $18 = 0), never from the
  counter. The port had used lives == 0 for endless, so the last death (lives -> 0) redrew the HUD as "ENDLESS" just
  before GAME OVER (user report, ARCADE mode). Now g[:endless] (setting 0) skips the life loss ($21c0 -> $225a) and
  extends; lives == 0 only means game over; the HUD prints nothing with no spare life ($2a3c).
- Lives display checked against both versions ($29f4 / arcade $0db2): spare = lives - 1 (BCD, daa); < 5 -> one '['
  each; >= 5 -> "[[" + ".." (attr $3d) + the spare count, e.g. 8 lives = "[[..7". The port draws exactly this.
- $04 after the name entry (arcade $7006 after the last letter, $70dd when coin / start cuts the waits): on the ARCADE
  board it STOPS THE MUSIC (MAME: $11 then $04 3 s later -> silent within 0.5 s; this is why $04 recorded as silent).
  X68000: a PCM confirm beep, music goes on. Audio: $04 stops music when the music set is ARCADE, else plays its file.
- Dev: --start_score is the internal value (displayed / 10); a big one gives every extend at once (30,000, then every
  100,000) - not a bug. Name-entry tests write save.txt: back it up.
- Side fix: widgets.rb used deprecated `outputs.solids` (DragonRuby's notification banner covered the HUD's bottom
  line in screenshots) -> sprites with path :solid.
- SFX FILTER values renamed (user): BOARD -> PCB (matches COLOURS STANDARD / PCB); settings.txt sfx_filter=pcb|off.
- $08 Extra Life now the MAME render (PCB filter; flat/ for OFF): music/"08 Extra Life.ogg", tracks.txt 08, lengths
  116424 (2.64 s; the piece was scaled -2.7 dB to avoid clipping). Still an OVERLAY (BGM muted 155 frames). The OST's
  "04 Extend.ogg" stays on disk unused.
- X68000 FM jingles missing from the OST rips (user: Wizard / Worm jingles are FM, not in the VGM rip) - to record per
  set (MDRV song ORIGINAL / ARRANGE): $0f Worm-eaten + shrink death $0b / $23, $14 boot + moon rise $10 / $28,
  $15 morning $11 / $29, $38 Holy Gem $14 / $2c (loops), and optionally $08 Extra Life $04 / $1c. Until then the X68000
  sets fall back to the arcade files. X68000 effects = PCMDRV ADPCM samples in PCMDATA.DAT (decode, don't record).

## X68000 sound effects decoded (pass 38) - x68_pcm.py, audio/x68000/
- PCMDATA.DAT: 64 big-endian words = byte lengths, word i = command i + 1 (1 = a 1-byte placeholder: unused); zeros to
  $200; then every sample back to back in command order (the lengths, placeholders included, sum EXACTLY to size - $200).
- PCMDRV.R (bra to init at $99e): play = 8-byte table entries [l addr, w len, w ...] -> DMA channel 3 array-chained
  ($e840c5 = $3a, MAR $e840dc, count $e840da), PPI port C $e9a005 = $08 (divider /512, both outputs on), ADPCM command
  $e92001 = 2. 8 MHz / 512 = 15625 Hz (jump: 1920 bytes = 0.246 s vs the arcade's 0.245 s). OKI 4-bit ADPCM, low nibble
  first, 12-bit; samples are mastered hot (many reach full scale).
- Check: spectra vs the arcade MAME (flat) recordings 0.85-0.99 for most ($1a .97, $28 .99, $35 .99, $36 .99, $2d .98);
  low = really different sounds: $17 attack .21, $32 worm .29, $19 .59, $22 .57, $24 .64. No sample for $04 (placeholder):
  the X68000 name-entry "beep" is silent too. Unused samples in the file: $1f, $23, $29.
- 30 effects installed in audio/x68000/ (48 kHz OGG). Audio: the ORIGINAL / ARRANGE music sets look up effects in their
  own folder, then x68000/, then arcade/. $21 loops whole (= PCMDRV's restart via $574).
- Possible later: decode PCMDATA.DAT from the player's own disk at load instead of bundling (fits the disk-or-ROM rule).
- DECIDED (user): the X68000 effects are NOT used - lower-quality PCM copies of the arcade sounds. audio/x68000/ and its
  lookup were removed; every set uses the arcade effects. The X68000 MUSIC stays. x68_pcm.py kept for reference.

## X68000 music sets from the VGM rip (pass 39) - vgm_sets.py, audio/original/ + audio/arrange/
- Source: the user's vgm.mdscene.net package (Sonic of 8!, 2012), 24 .vgz, YM2151 4 MHz, VGM 1.50; headers give exact
  total / loop sample counts. MAME's `vgmplay` refuses to run without unrelated ROMs (ym2608_adpcm_rom.bin, QSound
  dl-1425.bin), so: libvgm's vgm2wav (git clone github.com/ValleyBell/libvgm; cmake -DBUILD_PLAYER=OFF
  -DBUILD_VGM2WAV=ON -DBUILD_LIBAUDIO=OFF -DBUILD_TESTS=OFF; make vgm2wav - built in scratch at commit a6eed94).
  Renders are sample-exact (Main Theme 1: 257445 + 2 x 1888971 = 4035387).
- FM loop passes are NOT sample-identical (operator phases / LFO run on: rms diff 5-40 % of the signal) -> loop =
  [intro rounded up to whole frames, + loop samples) with the last 10 ms blended into the intro's end.
- Map (both sets; Arrange has no Wake Up / Coin / Extend -> the Original ones): Wake Up $14, Coin $06, Main Theme 1
  $07 + loop alone $09 ("X*" in tracks.txt, new), Main Theme 2 $30 + $31*, Extend $08, Power-Up $0a $3f, Miss $0b,
  Round Clear $0c, Round Demo $0d (intermission - user confirmed), Hurry Up $12, Ending $13, Game Over $10, Name
  Entry $11. One-shots keep the VGM length (= MDRV song length, what $56c waits see). Not in the rip: $0f $15 $38 ->
  arcade fallback. "24 Unused" (3.65 s): user - an unused sound, also unused in the arcade game; not mapped.
- $08 stays an OVERLAY with the arcade's 155-frame BGM mute for the X68000 sets too (X68000 Extend 3.39 s); user: sounds
  fine. MDRV's own behaviour not checked.
- LEVEL (user: X68000 music far too loud vs the effects): libvgm renders hot. vgm_sets.py --ref <arcade round BGM loop>:
  one gain per set so its Main Theme 1 loop has the arcade OST loop's loudness: Original x0.322 (-9.8 dB), Arrange
  x0.238 (-12.5 dB). Rebuilt with --ref "audio/arcade/music/03 First Half BGM (Round 1-49) loop.ogg".
- ROUND CLEAR CUT (user: Arrange's clear jingle cuts out when the next round starts): both versions send $0c, wait 44
  ticks (X68000 $2154 / arcade $0436; tick = 6 frames: $2b2 `moveq #5` + dbra, arcade $04f1 hl=6) = 264 frames = 4.4 s,
  then $1890, round++, $2818, $200e: $646 $1a2e $1da0 $1114 (build) $2d8 x2 $2876 $251c, $2612 sends $07/$30 at once.
  The port matches. Audible lengths: arcade OST Stage Clear 4.63 s, Original 5.67 s, Arrange 5.19 s - but arcade and
  Original are only DECAYING from ~4.0 s (-13 dB at the cut), Arrange has a final accent at 4.3-4.8 s (-2 dB) -> an
  audible cut. Open: does a real X68000 cut it too, or does its round build take long enough? (No X68000 BIOS for MAME
  here.) Ask the user / footage before changing timing.
- RESOLVED (user: on a real X68000 the clear jingle finishes before the next round): RoundClearTask :wait_music - with
  an X68000 soundtrack (music original / arrange) the 44-tick wait is a minimum, then it waits for "music busy" (= the
  VGM song length). Measured $0c -> next $07: ARCADE 267 frames (unchanged), Arrange 359 (5.95 s jingle), Original 398
  (6.61 s). Assumption: the real gap is the song length (its round build must take at least that long); no footage.
- Menu label: the ORIGINAL soundtrack shows as "X68 OG" (user; settings.txt value / folder stay `original`).

## Memory / stutter pass (pass 40)
- MEASURED (RSS every 10 s; `--soak N` = dev flag, next round every N ticks): attract 4 min 128.3 -> 128.9 MB; idle
  gameplay (no_hit) one +10 MB step when the hurry/next track first loads, then flat; 101-round cycling (--soak 120)
  steps +5 MB / +1.5 MB as new sprite textures and music files are first used, flat in between. No per-frame leak
  found: the growth is DragonRuby's texture/audio caches warming up (each sprite pattern x palette = one 16x16
  texture, kept for the session; each new OGG). After the changes below: +5 MB in the first 100 s, then flat to 7 min.
- STUTTER: 72 OGGs (all MAME SFX recordings in audio/arcade + flat/, and music/08 Extra Life, 38 Holy Gem intro/loop)
  were 48 kHz MONO; DragonRuby wants 44.1 kHz stereo (docs; dragonruby-publish warns), so it resampled at load.
  Re-encoded in place: ffmpeg -ar 44100 -ac 2 -c:a libvorbis -q:a 6 (durations unchanged, so lengths.txt still holds).
  48 kHz originals: fl_files/out/sfx_ogg_48k_backup/ (the music/ copies of 08 / 38 were not backed up). mame_sfx.py
  still writes 48 kHz mono WAV masters: whatever encodes them for audio/ must output 44.1 kHz stereo.
- GC churn: SpriteCache#path built a name string + patch arrays for EVERY sprite EVERY frame while w[:pal_patch] was
  set (glow / potions / ice / ending). Now begin_frame(patch) works the per-palette overrides out once per frame (only
  when the patch changed) and names are memoised; draw_shadow's 128-entry draw order is cached per priority list.

## Intermission fixes (pass 41)
- X68000 Rodomy edge (user: X68 mode still had the head popping out of the cliff): CORRECTS pass 36 "the X68000's 10-bit
  x does not wrap". $1b8e stores X = -(x + xoff) & $ff, and the VBlank copy $32c writes each of the 32 priority-list
  sprites to TWO hardware sprites ($eb0100+, 16 bytes per entry): the sprite, then a copy at X + $100 when X < $10 (else
  an empty one) - the arcade's 8-bit wrap reproduced in software. draw_shadow wraps list entries (shadow 0-31) in both
  behaviours; entries 32+ only on the arcade. ($1cc0 = PCG pattern streaming for the same 32, not a second copy.)
- Lives in the intermission (user: shouldn't show): $1554 calls $7b8 (top line: HIGH SCORE / 1UP) only; the main loop's
  $29f4 lives refresh does not run while $2818 waits for task 25. start_intermission: hud_off + Hud.top (also skips the
  extend check, likewise main-loop only). Verified: bottom line empty; X68 entry at the right edge clean.
- Dev: a round-7 clear straight into the first intermission: --round 7 --inject "0:0:0:0,...,7:0:0:0" (8 slots, 0-7).
- Hot reload gotcha: editing a class with new ivars set in initialize breaks a RUNNING game (the live object never re-ran
  initialize) - initialise caches lazily (||=) in the methods that use them.

## Audio timing + MAME frame-by-frame AI check (pass 42) - mame_check/, vgm_sets.py
- X68000 jingle tails (user: Arrange's round end lasts a little too long; Round Demo cut too soon): the VGM one-shots
  carry up to 0.9 s of silence after the audible end, and with an X68000 soundtrack the round clear waits for "music
  busy". vgm_sets.py TRIM ($0c, $0d): cut at the last 10 ms block within 60 dB of the peak (frame-rounded, 10 ms fade):
  Round Clear 6.61 -> 5.75 s (Original), 5.95 -> 5.20 s (Arrange); Round Demo 7.48 -> 6.77, 7.74 -> 6.83 s.
  Intermission (task 25 $done): with an X68000 soundtrack it now also waits for the Round Demo music before the next
  round ($2818 does not wait; same assumption as the round clear). Measured scene lengths: clear -> next 346 / 313 frames,
  intermission 407 / 411 (Original / Arrange); arcade unchanged (266 / 385). Other one-shots keep the VGM length
  (Miss etc.: their busy time is what $56c waits see).
- $15 (the moon's morning, $72c6) on the X68000 sets = the Coin jingle (user, by ear; $4ee maps $15 to MDRV song 17).
- MOON TIMING (MAME, arcade $3074-$3160): $14, ($e696 un-shrink: sparkle + 20 frames), then it polls the sound board's
  REPLY ($d401 bit 1 - the $14 handshake, as at boot), reads it, yields 1, sends $0a, waits 240 + 240 + 40 frames, 8 moon
  frames x 10, $15. VERSION DIFFERENCE: the X68000 ($7272) sends $3f and waits 240 + 240 + 22. Port had $3f / 22 for both
  and waited for DragonRuby to drop the $14 file (47 frames late). Audio::BOARD_BUSY {$14 => 140} frames (arcade files);
  measured $14 -> $0a 141 frames, $0a -> $15 600 frames - the port now sends both on the arcade's frames.
  The night music is meant to end as it loops (user); arcade OST loop = 0.40 + 10.24 s vs 10.0 s of night.
- NIGHT WIPE PACE MEASURED (MAME name table each frame): cost model 8 units per $741c loop iteration + 1 per plotted cell,
  367 units a frame, first frame 70 % (night) / 40 % (morning). Night 34 frames (cells visible for 28, then the off-screen
  outer rings), morning 35; tasks resume the frame AFTER the last ring. Port NightWipe is now a resumable per-iteration
  loop on that budget (was 2 rings a frame = 23 frames).
- TOOL: mame_check/ - MAME Lua logs $e600-$e6ff every frame (attract.lua from power-on; play.lua: coin, round set by
  writing $e781 at frame 700 (the MAME cheat file's "Select Current Round"; coin-up clears it at frame 601, the build reads
  it ~840), NO HIT DIP, scripted inputs from the frame the round's first slot appears, sound commands from $d400 writes).
  Port side: --objlog N (objlog.txt, same format), --music arcade, --short_hop 0 (new: off even when settings.txt has it).
  check.sh <round> <seed> <frames> <work dir> runs both and diffs. Arcade RAM: object slots $e621 (12 x 8), player
  x/y $e6a9/$e6aa, speed divider $e684, round $e781, walk counter $e785/6 (800 -> item), moon flag $e6a1 (X68 $61d),
  collision map $e080 (32 x 33). The +$e082 rule fails here: this area is +$e084 (X68 $59d -> $e621, $600 -> $e684).
  Enemy AI uses no LD A,R: given the same inputs it is deterministic, so any drift is a port bug or a version difference.
- RESULTS: the 3 attract demos (rounds 1, 2, 62) and 60 s of scripted play on rounds 12 (Wizard/Golem/Wraith + Moon
  Tiara night), 43 (all six species) and 87 (Wraiths, speed $ff) now match the arcade on EVERY frame (all 96 slot bytes,
  Ptolemy, divider, sound command frames). Only diff left: one frame during READY where a slot's facing is set a frame later.
  Fixed on the way:
  * Demo start: enemies were loaded at the build; $240a loads them ($251c) 2 ticks later with Ptolemy's start, and the
    tasks are main-loop spawns (Scheduler.spawn_main: first run next pass); DemoStartTask frees its slot first, else the
    director's task 01 landed in it and ran a frame late. Short hop leaked into the attract demos (now off there).
  * VERSION DIFFERENCE: $4f9c column search (target above-left): arcade $296c measures to the column BEFORE the one found
    (`dec a`) - 8 px further; X68000 $4fba to the column itself.
  * $515a (walking, timer set): the 3 ledge probes are at 2, 3, 4 columns ahead (first step 2, then dbra / jr back past
    one add); the port probed 2, 4, 6.
  * VERSION DIFFERENCE: the arcade's column scans ($2927 / $295f / $2999 / $29a9, $2aa6 / $2ad8) step with inc l / dec l:
    the cell address wraps within its 256-byte page, so from column 0 of rows 4/12/20/28 the scan jumps to column 31 of a
    row 7 rows up (round 87: a Wraith set off on a $44 walk). X68000: addq.l / subq.l. Port: EnemyAI.step_cell.
  * Shrunk walk ($44a0 even anim -> $4448) runs on through $4456: the alternate walk table check and its extra 1-frame
    yield were skipped.
  * Cake counters are bytes: the moon makes cakes without resetting JDX, which wraps 0 -> $ff (first hatch step 256 ticks
    later); the port went negative and the cake never hatched. Object ANIM / JDX / TIMER arithmetic now & $ff.
- X68000 BIOS (user, 2026-10-12): x68000.zip in the project root (MAME 0.289 set, verifies good on its own with
  -rompath <project root>; local only, like the disks). Next: X68000 behaviour traces with the same method
  (FS.X work RAM at a6 = $59d slots etc.) - the X68000-only paths are still disassembly-based.

## X68000 frame-by-frame check against MAME's x68000 driver (pass 43) - mame_check/check_x68.sh, play_x68.lua
- MAME 0.289 `x68000` (x68000.zip, project root) boots the user's Disk 1 (.hdm) straight into FS.X; Disk 2 in drive 1 is
  the save disk (copies are used: MAME may write). FS.X allocates its work area with DOS MALLOC ($5a): a6 = $0dc730
  in every run so far (attract.lua-style trace reads it from A6 while PC is in FS.X, $20000-$40000).
- Controls: $41a reads IOCS JOYGET + keyboard rows into $62 (bit 2 left, 3 right, 5 trigger A = jump, 6 trigger B =
  spell, 4 = OPT.2, 7 = OPT.1); MAME's pad is a Towns pad (:joy1:townspad:PAD, "P1 A" / "P1 B"). $48ca uses $592 instead
  when it is non-zero (the demo; it also switches scoring off - so the check drives the pad, not $592).
  OPT.2 = coin -> the menu; A on 1PLAYER START -> ROUND SELECT ($3206: $703 re-read every pass, capped by $6cf from disk 2,
  confirmed by a fresh A in $66). play_x68.lua holds $703 and pulses A every 60 frames until the round's slots appear
  (floppy loading moves the menus by dozens of frames between runs). NO HIT = clear $578 bit 6.
- LAG: the 10 MHz X68000 misses vblanks now and then (MAME reproduces it: e.g. round 12, one frame at pass 247), and
  catches up later, so video frames are not game passes. The check logs ONE ROW PER PASS from a write tap on $600:
  $2b2 does subq.b #1,$600 every pass and move.b $5fe,$600 after it when it went negative. A write is a subq when it
  stores old - 1 (taps run before the write lands); a non-subq write counts only right after a negative subq (the
  reload); $4c00's (AI init) is ignored. (Counting that one as a pass shifted everything by one and briefly looked like
  an X68000 round-start difference - it was not: both versions start the round's tasks on the same pass.)
  16-bit bus: the tap range must be the whole word ($600-$601) and the byte is the high byte of the data.
- NIGHT WIPE on the X68000 (moon_x68.lua: forced moon, $61d per video frame): night 38 frames, morning 38 (arcade 34 /
  35). It runs inside the pass that started it ($209e after that pass's $2b2), so: that pass is normal, the frames the
  wipe takes are not passes (no tasks, no $600 count), and the next pass runs the tasks again (no extra frozen frame -
  the arcade has one). Port: NightWipe BUDGET_X68 = 328 (same cost model -> 38 frames each way), w[:in_wipe].
  Dev: --objlog and --script skip those frames under --x68k (the MAME log has no rows for them).
- RESULTS (X68000 behaviour vs MAME x68000): the 3 attract demos, and 60 s of scripted play on rounds 12, 43 (all six
  species), 87 (speed $ff) and 12 with a forced moon (night + morning) match on EVERY pass: all 96 slot bytes, Ptolemy,
  the divider. Both AI version differences of pass 42 (column measure, inc l / dec l scans) are thereby confirmed from
  the X68000 side too.

## Graphics options + widgets 2 (pass 44) - gfx/display.rb, gfx/widgets.rb, GAME OPTIONS > GRAPHICS / WIDGETS
- User: MUSIC VOLUME default 4 (SFX 10 is the right balance); QUIT TO MENU no longer plays the coin jingle ($06 only
  for a real credit: MenuTask local coin: false).
- DragonRuby 7.23 Standard tier: HD mode IS available on every tier (changelog "HD mode is now available at all license
  tiers"; the bundled docs still say Pro) - hd=true is active here (Grid.render_scale = screen px per logical px).
  Still Indie/Pro: highdpi, shaders (dragonruby-shadersim, beta) -> filters are overlays (no curvature / bloom); Pro:
  hd_letterbox=false (edge to edge). DR.set_window_size is documented as debug-only (not guaranteed cross-platform).
- Display: playfield rect from render_scale - INTEGER (largest whole multiple of 224 lines that fits) or FIT; SQUARE or
  4:3 (pixel aspect 7:6); snapped to whole screen pixels. Verified: 1920x1080 window -> k = 4 (1024 x 896 screen px);
  a 2560x1440 window larger than the 1080p desktop was shrunk by the WM and the scaler fell back to k = 2.
  SMOOTH = nearest x2 into :frame_up, then linear. SCANLINES: 224 bands, 3/8 of a line (>= 1 screen px), alpha 22/level.
  MASK: GRILLE / DOT (slot) RGB pattern built on screen pixels in render targets (:crt_mask_strip 4 rows, :crt_mask),
  multiplied (blendmode 8), cached per [type, level, size]. VIGNETTE: 64x48 alpha pixel array, linear.
  BORDER: BLACK / BLUE / GREY, TILES (the round's visible left wall column, 16 px, dimmed, repeated at the playfield's
  pixel size), BEZEL (original procedural frame; frame_pad 30 keeps widgets clear), IMAGE (fairyland/borders/*.png,
  scaled to cover; gitignored - the user's flstory_bg.png is Taito flyer art: local only).
  WINDOW 720p / 900p / 1080p / 1440p (windowed), FULLSCREEN (desktop resolution). Dev: --gfx "key=value,..." (this run).
- Widgets restyled: the game's own 8x8 font ($20-$5f of the player's BG characters, white + tinted; no "/" - that tile
  is a division sign), HUD colours, framed panels, item sprites as icons. A panel is 23 characters; its font pixel is a
  whole number of screen pixels (1 at 720p, 2 at 1080p ...), shrunk down to 0.6 only when a narrow border (4:3 at
  720p: 192 px) cannot fit one. Layout: widget_level / _item / _timer / _moon = OFF / LEFT 1-4 / RIGHT 1-4 (stacked in
  slot order), WIDGETS > SHOW is the old on/off.

## HD render targets + window changes (pass 45) - gfx/display.rb (Display.target / texels / src), main.rb --winseq
- User bug: after a window / fullscreen change the picture went jagged. Cause: in HD mode DragonRuby scales RENDER
  TARGETS by Grid.render_scale too (texture = w * rs texels, sprites inside at x * rs, source rects on a target * rs).
  :frame (256 x 256) became 361 texels at rs 1.41 and the pixel art was resampled unevenly inside it. At 720p rs = 1,
  so it only showed after a change. The "1080p" window preset on a 1080p monitor does not fit with the title bar and
  panel: KWin shrank it to 1920 x 1019 -> rs 1.415, DR letterboxes 16:9 inside (1812 px wide, 54 px side bars).
- Engine facts (measured with a probe app, 1-px checkerboard): a target's w / h is truncated to a whole logical
  unit (256.25 / 1.328 -> 192 -> 255 texels), and so are source rects on it. Exact recipe: target size
  ceil(texels / rs) logical, every rect inside and every source rect on it given as texels / rs. Pixel-identical to
  drawing straight to the screen at 1600x900, 1700x1000, 1920x1019, 1920x1080. All four targets (:frame, :frame_up,
  :crt_mask_strip, :crt_mask) go through Display.target / texels / src. Checked in the game: INTEGER, filters off,
  every run of identical pixels is a multiple of k at 720p, 900p, 1080p, 1440p, 1700x1000 and 1920x1019.
- The grid values (render_scale, w_px, allscreen_*_pt = the real window) follow every resize at once.
- Scanlines: each band now starts on a whole screen-pixel row, (i * k).round from the playfield's bottom, and is
  the same whole number of rows thick. Under FIT (k = 4.55) fractional bands came out 1 or 2 rows thick by turns.
- DragonRuby 7.23 segfaults (draw_iteration, signal 11) in about 1 run in 4 when args.outputs.screenshots fires
  shortly after a window resize, with or without this fix. Screenshots taken after a resize also come out scrambled
  (wrong stride). This only affects dev runs: normal play never takes screenshots.
- Renderer: on Linux the log says "SDL Renderer Backend: opengl". DR 7.23 = SDL3 3.4.4; Windows tries DX12, DX11,
  then OpenGL (changelog).
- 4:3 monitors: DR canvases are 16:9 (aspect_mode 0) or 1:1 only, chosen in the metadata at build time. Drawing
  outside the 16:9 safe area (hd_letterbox=false / allscreen) needs Pro. On Standard, a 1024x768 screen gets a
  1024x576 canvas -> the playfield is at most 576 px tall (FIT) or 448 (INTEGER), with black above and below.

## Widgets 3: corners, MUSIC panel, always on in a game (pass 46) - gfx/widgets.rb, audio/audio.rb, settings.rb, menu.rb
- User: each panel is OFF / TOP LEFT / BOTTOM LEFT / TOP RIGHT / BOTTOM RIGHT. The panels in one corner stack in
  menu order (LEVEL, BONUS ITEM, TIMER, MOON, MUSIC), each below the one before. A bottom corner's stack is measured
  first (Widgets.stack dry run), then drawn so it sits on the bottom edge (12 px margin). Old settings.txt values are
  mapped by Widgets::LEGACY (left1/2 -> top_left, left3/4 -> bottom_left, same for right). If a top and a bottom
  stack are too tall together they overlap (not handled). The menu prints the corner names from column 18.
- MUSIC panel (user idea): Audio.now_playing = the track heard now (the jingle while an OVERLAY jingle like $08
  Extra Life covers the BGM), its set (ARCADE PCB / X68000 ORIGINAL / X68000 ARRANGE) and the time since that track
  started. The time restarts when a command's steps move on to a different track (Stage Start -> First Half BGM),
  not between an intro and its loop. Names are the arcade PCB recording's official titles for EVERY set (user): an
  X68000 track is named after the arcade track that the same command plays (the last one in its sequence: $07 =
  Stage Start > First Half BGM -> the BGM title. The X68000 intros are loop offsets, not a separate fanfare file, so
  "Main Theme 1" is "First Half BGM (Round 1-49)" throughout). $14 / $15 are not on the arcade OST: titles from the
  user, Audio::TITLES - $14 "Wake Up / Moon Out", $15 "Credit / Morning" (every set). The game font's "/" tile is a
  division sign: Widgets.text draws a slash itself. From a file name, the leading track number and " intro" / " loop" are dropped. Names wrap to up to 3 lines of 23
  characters. "NO MUSIC" after a $00 (e.g. Ptolemy's death). DragonRuby's mruby has NO Regexp: use string methods.
- NARROW layout (19 columns instead of 23): the odds go under the item name, and the texts are shorter (NEXT, NO ITEMS:
  HORNED, X68 for X68000). It is picked when it gets a larger font pixel than the wide one (a tie keeps wide). Seen at
  1080p with a 4:3 picture + bezel: wide would need 0.87 screen px, narrow gets a whole 1. With FIT + square or 4:3 and
  no bezel, both get 1 px and wide is kept. mruby gotcha: Array has no <=> / >, so max_by { [a, b] } raises.
- Widgets now show for the whole game from START GAME (round intro, clear, intermission, game over), not only
  while task 00 runs; never in the attract or the menu.

## X68000 FM jingles recorded from MAME (pass 47) - mame_check/fm_x68.lua, mame_fm.py
- User: the Wizard (shrink) and Worm death fanfares were missing from the X68000 sets. Both deaths send the same
  command, $0f (director $42bc shrink death, task 26 $8dd8 eaten), = MDRV song $0b (ORIGINAL) / $23 (ARRANGE). User: the
  same fanfare in both modes. Measured: same shape and length (1.6 s), but ARRANGE's notes start ~30 ms earlier and
  the waveforms correlate only 0.66, so MDRV holds two written versions. Each set gets its own recording.
- Trigger (fm_x68.lua, MAME x68000 + the user's disks, copies): coin, A pulses into round 1, NO HIT, $47(a6) forced;
  FS.X found in RAM by $4ac's code (loaded at $303e0 here); the $4ac table byte for the jump command ($4ee + $16) is
  patched to the song for 4 frames around one press of A, so the game's own FM path plays it (add $47(a6), trap #0).
  A READ TAP DOES NOT WORK: MAME's 68000 fetches the pc-relative table read without going through taps. emu.time() is
  a plain number in 0.289: use manager.machine.time:as_double(). MAME's x68000 -wavwrite is 48 kHz, 6 channels (sound
  on 0/1), with a DC offset of ~900 and a noise floor 54 dB below these jingles.
- SWEEP (FM_SONG=01 FM_LAST=31: one song every 600 frames, from silence when the previous one is a one-shot):
  audible lengths (s): 01 1.9, 03 3.0, 04 2.1, 07 4.5 (Miss), 08 5.0, 09 6.3, 0a 1.0, 0b 1.6, 0c 3.8, 10 2.2, 11 2.1,
  16 0.1, 19 1.9, 1a 2.1, 1b 2.8, 1c 2.1, 1f 3.0, 20 5.1, 21 6.8, 22 0.9, 23 1.5, 24 3.6, 28 2.2, 29 2.0, 2e 0.1,
  31 0.1, 2a silent; 02 05 06 0d-0f 12-15 17 18 1d 1e 25-27 2b-2d 2f 30 run past 9.5 s (BGMs). Still missing from the sets,
  recordable the same way: $15 = songs $11 / $29 (Credit / Morning), $38 = songs $14 / $2c (Holy Gem: loops, needs
  a loop point).
- LEVEL: MAME render -> set level, from the 11 jingles in both the sweep and the sets (envelope-aligned, 0-40 ms):
  ORIGINAL 1.26-1.54 (median 1.334), ARRANGE 0.96-0.99 (0.973). The ratio, 1.37, matches the VGM sets' own (0.322 / 0.238).
- mame_fm.py cuts a song from the trigger to its tail (DC removed, end = -60 dB or 12 dB over the floor, 20 ms fade),
  44.1 kHz stereo Vorbis q6 like vgm_sets.py, and upserts tracks.txt / lengths.txt. Installed: "Worm & Shrink Death" (user's title, also Audio::TITLES for every set)
  (ORIGINAL) and "Worm & Shrink Death (Arrange)", 70560 samples each, as 0f. vgm_sets.py rewrites those two files: run
  mame_fm.py after it.
- Checked in the port (dev flag --sound "300:0f", round 3): ORIGINAL plays "Worm & Shrink Death.ogg", ARRANGE
  "Worm & Shrink Death (Arrange).ogg", arcade its "0f worm eats ptolemy.ogg"; the MUSIC widget shows
  WORM & SHRINK DEATH in all three (the game font has the "&").

## X68000 Holy Gem ($38) recorded from MAME, loop found from the YM2151 writes (pass 48) - fm_x68.lua, mame_fm.py --loop
- User: $15 (Credit / Morning) on the X68000 sets is already the Coin jingle (pass 42); only $38 Holy Gem was missing.
- fm_x68.lua new env: FM_HOLD (frames per song; 600 default), FM_FREEZE=1 (holds the round timer $610 = 1 and the moon
  countdown $61b = 100 while armed: in the first 60 s take the game's own music cut Holy Gem off 13 s in), FM_OPM=<file>
  (every write to the YM2151, $e90001 address / $e90003 data, with its emulated time). A write tap installed when the
  script loads never fires (MAME rebuilds the map at boot): install it at arm time.
- The audio alone could not find the loop: the piece is a dense, even groove (0.4878 s beat), every lag correlates
  0.8-0.9 (envelope, spectrogram, waveform) and FM phases drift between passes. The OPM writes do: key-on ($08) +
  KC/KF ($28-$37) events repeat EXACTLY with a period of 9897 events = 20.000 s (both sets, same note data), from
  0.362 s (ORIGINAL, song $14) / 0.377 s (ARRANGE, $2c) after the trigger. The arcade OST's Holy Gem is 2.0 s + a 2.0 s
  loop - a different arrangement, not a guide.
- mame_fm.py --loop <start s> <length s>: whole-frame intro (16170 / 16905 samples) + 882000-sample loop whose last 10 ms
  blend into what precedes its start (as vgm_sets.py); seams checked (jumps within the usual sample-to-sample range).
  Gains as pass 47 (1.334 / 0.973). Installed "Holy Gem" / "Holy Gem (Arrange)" as 38. Port check: --sound "250:38"
  --music original|arrange, round 3, NO HIT: plays past the loop wrap, the MUSIC widget shows HOLY GEM.

## Horned + Dracolisk checked frame by frame against MAME; widgets scale with the window (pass 49)
- TOOLING: DragonRuby silently drops a long CLI argument (a 947-char --script) AND every argument after it: the
  pass-42-style check ran with no script and no --objlog (it never ended). New --script_file F (fairyland/F);
  check.sh / check_x68.sh copy the script to fairyland/check_script.txt. New port flags (with --objlog):
  --sprlog 1 (sprite slots $4c-$58 rebuilt in the arcade's bytes [~y + dy, code, attr, x + dx] -> sprlog.txt),
  --tasklog 1 (task slot ids -> tasklog.txt). play.lua: PLAY_SPR (arcade $e04c-$e05b), PLAY_TASKS (23 slots x 15 bytes
  from $e4a9: id, status bit 0 = active). check.sh: SPR=1 (spr_diff.py), DRAC=1 (round 101: align on row 0,
  input shift 0, slots 0-1 = the Dracolisk named after the port's fields in trace_diff.py).
- HORNED (round 12, 5000 frames, SPR=1): sprite slots $4c-$58 identical on all 5000 frames (1240 with a sprite: music $12
  at +3580, entrance script, chase). Arcade code $6c0c-$6f15 read side by side: same as the port, x / y live in Z80
  registers c / b (not RAM). VERSION DIFFERENCE: on contact the arcade ($6f0e) writes $40 to $e6b0 (end code) but
  clears $e61a (killer, = X68 $596) where the X68000 ($8960) writes $40 to both. Invisible (enemy task ids are 5-12,
  so neither value spares an enemy); port now writes 0 in arcade mode.
- DRACOLISK (round 101, 3000 frames, DRAC=1): now identical on every frame (body, head, tail, legs, AI cmd, fire target,
  breath wait, damage, Ptolemy). Two port bugs fixed:
  * One frame late from the round start: the intro is main-loop code in the original but a stand-in task (40) in the
    port. It sees task 1b end one pass late; that is harmless for its spawns (they land in later slots and run in the
    same pass = the original's next one) but task 21 (slot 0, BEFORE the stand-in) was resumed too late, and the AI
    (2a) it spawns ran a frame late. Scheduler.resume_main runs a resumed task in an earlier slot at once.
  * Head turning ($94fa, arcade the same): direction and step count are taken ONCE, then all steps run (one per 10
    frames); a new target set meanwhile waits. The port re-aimed every step (diverged at +975: a turn-round request
    right after a turn).
  Speed divider: the arcade shows $e682 / $e684 = 0 on round 101, the port $ff. The loader ($253e) returns before
  writing $5fe on round 101, so it keeps round 100's value (0 here: round selected from game start). Only enemies use
  the divider: invisible on round 101, left as is.
  Not covered yet: the fireballs (MCU line stepper; arcade MCU RAM, not logged) and the defeat sequence (needs hits).
- WIDGETS (user): sized in whole LOGICAL (720p) pixels, so they keep their share of the screen at any resolution (they
  shrank at 1080p when sized in whole screen pixels); drawn sharp (nearest) - at 1.5x some font pixels are 1 screen px,
  some 2 (user's choice over smoothing). Round 101 (user): TIMER "NO TIMER" (no bar), BONUS ITEM "NO ITEMS" (one line),
  MOON "NO MOON" ($611 = $ff and task 14 killed by the Dracolisk's setup).
- HORNED TIMER (user): the timer panel is now titled HORNED TIMER (menu too): a bar, full when Horned comes, mark at
  hurry-up. Text only as a warning (the panel grows to 3 lines): HURRY UP! from $41 until Horned shows (then a full
  bar, no text), LAST ENEMY REMAINING (narrow: LAST ENEMY LEFT) while the last enemy's escape timer runs. Round 101:
  one line, NO TIMER.

## Release builds (pass 50) - dragonruby-linux-amd64/copernicus (staging), builds/, make_icon.py
- Release behaviour = DR.production? (true in dragonruby-publish builds; simulate with an empty
  metadata/dragonruby_production_build): no dev keys (PgUp/PgDn round select, Tab, F2 F4 F5 F6 F12 - all their settings
  are in GAME OPTIONS), NO HIT forced off, and of the command-line flags only --source x68k (data/README.txt) is read
  (main.rb cli_args). Checked: with the marker, --round 12 --objlog 10 was ignored (no objlog, no quit).
- Icon (user): Ptolemy's cake, metasprite $eb, the game's own sprite (user's choice: it ships in the binaries; the
  data/README line now says so). Dev flag --dump_meta EB writes the chain at 1x (meta_dump.txt); make_icon.py makes
  icon.png 72 (x4), icon_ios.png 1024, icon_large.png 1800 on navy (24, 24, 72), RGB without alpha.
- Metadata (user): devid=copernicus, devtitle=Copernicus Port (Windows saves: %APPDATA%\Copernicus Port\Copernicus),
  icon=metadata/icon.png - dragonruby-publish refuses to package without devid / devtitle / icon. version still 0.1.
- Packaging from a CLEAN STAGING COPY dragonruby-linux-amd64/copernicus/ (app, metadata, audio sets, data/README.txt,
  borders/README.txt): the dev folder holds the player's disk, save.txt, settings.txt and border picture, and
  ignore_directories only works on whole folders. ./dragonruby-publish --platforms=windows-amd64,linux-amd64,macos
  --package copernicus -> builds/: copernicus-<platform>.zip = ONE executable with the game embedded (~24 MB);
  copernicus-<platform>-0.1/ = the binary with the game folders loose (data/ with its README beside the binary).
  Production file lookup (DR docs): the per-user data dir first (~/.local/share/Copernicus, %APPDATA%\Copernicus
  Port\Copernicus, ~/Library/Application Support/Copernicus), then the game folder. HTML5 not built (it cannot read a
  player's ROM / disk).

## Dracolisk checked against MAME x68000; THEME border; missing-data screen (pass 51)
- DRACOLISK vs the real X68000 (check_x68.sh 101, DRAC=1 XSHIFT=1, 3000 passes, disk 2 copy with FS.DAT byte 0 = $64
  so ROUND SELECT reaches 101 - FS.DAT byte 0 = $6cf best round, at image offset 11264 on the HDM disk 2): the X68000
  log is one row behind the port's at round 101 (port row k+1 = MAME row k) and needs inputs shifted by 1. Then
  Ptolemy, the Dracolisk ($59d-$5b2) and both fireballs match on EVERY pass (672 with a fireball out).
  * X68000 fireball RAM: line k at $5b7 + 8k: flag ($ff = flying), x, y, x 8.8, y 8.8; slopes at $5c6 + 8k. $9886 reads
    an "MCU" byte at $5b3 - $35 + n; reading flag $39 / $41 steps that line ($997c) - the port's line_step.
  * PORT BUG FIXED (both behaviours): task 2b ($980a, arcade $869e the same) waits 60 frames, then its loop yields 1
    BEFORE the first read: the port stepped straight after the 60, every fireball one step (4 / 3 px) early. Arcade
    round-101 check re-run: still only the known divider difference.
  * Tools: check_x68.sh DRAC=1 (Dracolisk field names), XSHIFT=n (input shift), TASKS=1 (play_x68.lua PLAY_TASKS: the
    23 slot ids at a6+$234 -> xtasks_*.txt). --objlog on round 101 appends f=<$5b7-$5d1 in the X68000 layout>.
    X68000 task slots on round 101: 21 01 29 23 27 22 00 2a 10 2b 0e 03 28 (29 before 2b, as in the port).
  * User: Horned behaves differently when summoned again after killing Ptolemy on the same round - already handled.
- BORDER: TILES replaced by THEME (user): both side borders shade from the round's wall colour (Screen.wall_rgb,
  computed on each full redraw from the left wall area of the live palette) at the playfield to near black at the edge;
  a new colour fades in over ~1 s. settings.txt border=tiles loads as theme. Colour pick still under review (the most
  common colour finds theme 0's navy sky / theme 3's dark teal rather than the walls; count x saturation proposed).
- Missing data: GameData::Missing -> a short centred message (GAME DATA NOT FOUND / ARCADE ROMS INCOMPLETE + missing
  files + the MCU hint, "See data/README.txt - Esc quits.") instead of the class + backtrace line.

## SMOOTH modes, widget layer, menu value fix (pass 52) - gfx/display.rb, gfx/widgets.rb, settings.rb, menu.rb
- Menu bug (user): GRAPHICS values were padded to 8 characters; 1920X1080 / 2560X1440 are 9, so going back to
  1280X720 left the last digit behind. Values now pad to 11 (to the screen edge).
- SMOOTH (user: the old nearest-x2-then-linear looked smeary / uneven at 4x) is now OFF / SHARP / SOFT (settings.txt
  smooth=off|sharp|soft; old false -> off, true -> sharp). SHARP = nearest to the largest whole multiple per axis
  (floor of screen px per game px), then linear for the rest: the same as OFF under INTEGER, even pixels with soft
  seams under FIT. SOFT = linear straight from the game's pixels (a soft monitor look). Both copy into :frame_up 1
  texel in from its edges with the picture smeared into that rim, so the edge texels blend with themselves (the old
  one blended with the empty texels past the target's edge and the hidden lines: a dark seam). Checked at 1080p FIT.
- WIDGET SCALING (user chose option 3 "for now"; the four options, kept to revisit):
  1. whole SCREEN pixels per font pixel: always crisp, but the panels change share of the screen between resolutions
     (rejected pass 49: they shrank at 1080p).
  2. whole LOGICAL (720p) pixels, nearest: same share at every resolution, but at 1.5x font pixels are 1 or 2 screen
     px by turns (uneven). Pass 49 to 51.
  3. whole logical pixels, LINEAR: same share, even at 1.5x, soft edges. CURRENT: panels are drawn sharp into a
     1280 x 720 texel target (:widget_layer, Display.target / texels), then the layer is drawn linear to the window
     (pixel-identical to 2 at 720p, except the 1 px shadow edge: a little lighter through the layer's alpha).
  4. (proposed, not tried) font pixel = the largest whole fraction of the PLAYFIELD's pixel size that fits the
     border: always on the same pixel grid as the game art beside it; size changes only with the playfield's scale.
- Mode lines (user): ARCADE START "JUST LIKE ARCADE, HISCORES SAVED" (32 chars: the whole line), CASUAL START
  "YOUR RULES, PROGRESS SAVED". The game font has a comma.
- VSYNC (user wants a setting): DragonRuby 7.23 has an undocumented cvar renderer.vsync (default true, not locked).
  Set in metadata/cvars.txt it works at boot (log: "setting cvar 'renderer.vsync' to 'false'"; fps then wobbled
  53-57); changing args.cvars['renderer.vsync'].value at runtime does nothing measurable; a cvars.txt in the per-user
  data dir (~/.local/share/Copernicus/metadata/) is NOT read by a release build. So no in-game toggle on 7.23: only the
  loose release folder's metadata/cvars.txt. The game loop is 60 Hz whatever the vsync.
- Pixel misalignment under FIT (user's settings: 1080p fullscreen FIT, SHARP, scanlines 4, grille 10, vignette 6):
  4.82 screen px per game px, so game pixels are 4 or 5 px wide by turns; scanlines follow the game lines, but the
  grille (3 px RGB stripes on screen pixels) beats against the 4.82 px grid -> moire across the art.
- Mode lines changed again (user): ARCADE START "HISCORE & PROGRESS SAVED", CASUAL START "ONLY PROGRESS SAVED".
- SAVES (user): ARCADE now records progress too (last / best round for CASUAL's ROUND SELECT: an arcade run opens rounds
  to practise in CASUAL); high scores stay ARCADE only. continue_or_title and quit_to_menu save in both modes.
- ENDING -> GAME OVER fixed (user: the arcade blanks the screen but the score, GAME OVER, no jingle): $3722 ends with
  $1a2e (sprites) + $706 (rows 4-31 cleared), and its caller ($2148) jumps to $21ea, past the $21de jingle ($10).
  Port: EndingTask :done calls clear_screen; game_over(args, silent: true) -> task 43 t[:silent]. Checked: --round 101
  --drac_dead 1 -> blank screen, PLAYER<1>GAME OVER, no sound, then name entry.
- Round 101 "loops back" (user: arcade, Page Down to 101, beat the Dracolisk, after the ending the fight restarted
  with a pile of extra lives): a DEV-KEY bug. handle_meta_keys clamped the round to 1-101 on every tick; after the
  ending s.round = 102 ("ALL") -> clamped to 101 -> start_round(101) - a fresh world with a 1,000,000+ score paid
  out every extend at once. Now the clamp applies only on a PgUp / PgDn press. Scripted runs skip the dev keys, which
  is why --script tests never showed it. Also: lives = 0 after the ending ($2142), as the original.
  (Side notes: $4a(a6), the $21ba straight-to-game-over flag, is only set by a keyboard key - $229c, IOCS group $d
  bit 0. The fireballs (2b) are not frozen by the defeat ($911c) and the falling cake still crushes, both as the
  original: a death there costs a life.)
- save.txt: dev runs started by flags (--round, --script, --shot, --inject, --pos, --soak) no longer write it
  (Save.readonly). Before that, three test endings put 1,013,090 / ALL rows into the user's best 5; restored by hand
  to LPA, "...", then the factory KBT / MAD / ONJ (the likely pre-test table); progress was left at 100 / 100.
- DRACOLISK HEALTH (user): on round 101 the HORNED TIMER panel shows DRACOLISK - a bar of 256 less the damage meter
  (spell hit +30, drains 1 every 6 frames, defeated past 255), "DEFEATED!" + empty bar from $911c (d[:defeated], port
  only). Checked with the meter at $80 (half bar) and --drac_dead.
- BOOT (user): no credit while booting (w[:booting] on the boot world; the coin check skips it) - the arcade ignores
  the coin until the title. Checked: --keys "60:coin" during the blue screen does nothing, a coin at the title opens
  the menu.
- X68000 BOOT SPLASH (user): with BEHAVIOUR X68000 and a disk image (or a loose FLS_TTL.DAT) in data/, the boot shows
  the "Now Loading..." picture (FLS_TTL.DAT, 512 x 512 GRB555+I, X68000 colour scale) instead of the blue screen: held
  90 frames (stand-in for the disk load), then $14 over it, then the title. Order from FS.X: the jingle is sent and
  waited on at $1e22-$1e3e, and the picture's CRTMOD $10c is only replaced by the game mode at $1e4c ($61c: $10b), so
  the picture is up during the jingle. The file is kept even when the ROMs are played (GameData#splash_raw), decoded
  once (Display.splash, ~0.1 s), drawn full height on black: 960 wide with ASPECT 4:3, 720 with SQUARE; linear unless
  SMOOTH is OFF. Without the disk, X68000 behaviour keeps the blue screen. BOOT SCREEN OFF skips both.

## Controls: keyboard + pad, rebinding (pass 53) - game/controls.rb, menu.rb CONTROLS page, settings.rb kb_* / pad_*
- User: player 1 only (no 2-player mode), 2-way lever (up / down are no game input), the arcade's two buttons only.
- DragonRuby 7.23 input (docs/api/inputs.md): 4 pads (args.inputs.controllers, .connected, SDL game-controller layout,
  buttons a b x y l1 r1 l2 r2 l3 r3 start select; .left / .right = d-pad OR left stick, analog_dead_zone 3600);
  keyboard by name (key_down_or_held?(name) - an unknown name RAISES, so bindings are checked against Controls::KEYS /
  BUTTONS); no rebinding system of its own. Its built-in controller-mapping wizard (for pads SDL does not know) is left on.
  accept / cancel exist as properties but not through key_down_or_held? - not used.
- Controls.game_input: keyboard and every connected pad at once -> the $48ca byte (left wins over right, as before).
  The old reader used kb.left / kb.right, which also took WASD (A moved left): now only the bindings.
- Bindings (settings.txt, two per action, "-" = none): kb_left/right/jump/spell/start, pad_jump/spell/start (pad
  movement fixed: d-pad + left stick). START = COIN and PAUSE merged (user): a coin in the attract, the pause menu in a
  game (and it closes the pause menu). Defaults: arrows, X / Space jump, Z spell, Enter / Esc start; pad A jump,
  X spell, Start / Select start. A new binding leaves the device's other actions. (kb_coin / kb_pause / pad_coin /
  pad_pause from the first version are ignored when settings.txt is read.)
- Fallbacks so rebinding can't lock anyone out: menus always take arrows / Enter / Esc / Backspace and the pad's d-pad /
  A (OK) / B (back); Enter always inserts a coin; Esc always pauses unless it was made a game key.
- CONTROLS page (GAME OPTIONS): rows LEFT RIGHT JUMP SPELL START, PAD JUMP / SPELL / START, RESET DEFAULTS, EXIT; left / right picks
  the slot, OK waits for the key / button (main.rb: w[:capture] -> Controls.capture -> w[:captured]; the menu gets no
  input meanwhile), 4 s with none clears the slot; saved on EXIT / back. Checked: page + capture + timeout in
  screenshots, Controls logic in a DragonRuby probe (bind / unbind / parse / every KEYS + BUTTONS name), settings.txt
  round trip (kb_jump=x after clearing slot 2), a live round without errors. NOT checked: a real pad (none here).

## Docs cleanup + publishing audit (pass 54, 2026-10-13)
- Docs split: README.md (overview, how it works, what is published), NOTES.md (condensed current knowledge),
  docs/VERSIONS.md (all arcade vs X68000 differences), docs/research-log.md (this log, unchanged above).
- Publishing audit (throwaway git dir, `add -A --dry-run`): the X68000 VGM rip folder and flstory.xml (MAME cheat
  file) were not ignored - added to .gitignore with *.vgz / *.vgm / *.m3u, fairyland/errors/ and .claude/.
- The arcade AND X68000 ending texts were embedded verbatim in Tables::VARIANTS. Replaced by Tables::VARIANT_EDITS:
  ending_text { at: 102, size arcade 180 / x68000 179, arcade [2e f0 a0] (". " + cursor back $a0), x68000 [f0 a2] };
  GameData#setup_tables reads the player's own copy, checks the bytes at the edit, and builds the other version's copy
  from it. Checked all four combinations (disk / ROMs x ARCADE / X68000 behaviour) at the ending text (tick 2300 of
  --round 101 --drac_dead 1 --no_hit 1): disk = ROMs pixel-identical per behaviour; "IN YOUR HAND." vs "IN YOUR HAND".
  Kept in code (small functional data, user OK): VARIANTS pose / timer / spell tables, Director::SWAY, OLD_TAITO codes.

## Dracolisk sounds, ending jumps, warp flashes, round builds, items, rewind (pass 55, 2026-10-13)
- DRACOLISK DEFEAT SOUND (user: crumbles too quick / no pause before the gem). Code and frames already matched MAME
  (mame_check/drac_end.lua: patches the fight loop $819b -> jp $81ae = instant defeat; snapshots, sound log with emulated
  time for -wavwrite). The audio did not: in MAME $36 STOPS the Dracolisk BGM and plays a 25-frame drone; the first $37
  (25 frames later) stops the drone and is itself silent -> 14 frames of silence; the second $37 plays the crumble;
  $38 20 frames later. Port: Audio::CUT {$37 => $36} (a command arriving while that effect plays stops it and is
  dropped) and Audio::STOPS_MUSIC [$36], with the ARCADE music set only (board behaviour; sound CPU not analysed).
- ENDING JUMPS (user): CORRECTS pass 35 "arcade ending silent". Arcade $8af7 sends $16 per jump unless $e635 (X68000
  $5b1) != 0; the defeat clears it, and the ending writes $13 to it with the All Clear music ($8bff) -> jumps silent
  once the screen is black. X68000 never sets it -> sound throughout. Also each jump is 36 table steps + 15 = 51
  frames (the table end is tested AFTER the 1-frame wait, $9a88 / $8a4c); the port tested first (50). Both fixed.
- MYSTICAL FEATHER WARP: the skipped rounds FLASH (user). $2184 / arcade $044c: per round passed: round + 1, the
  intermission check, then (rounds left) clear + build + one 6-frame tick. Measured (mame_check/warp.lua, warp_x68.lua:
  $653 / $e6d2 = n with enemies left 0; X68000 needs $5fd = $80):
  * arcade: tilemap black while the round builds (sprites STAY: the cleared round's enemies remain until an
    intermission clears them), the bottom ROUND line 2-3 frames before the rest, then 5 frames shown (6 on two
    rounds); intermission: 2 black frames, then 49 frames at speed 8.
  * X68000: everything black 15-22 frames (sprites cleared, $2198 -> $1a2e), 7 frames shown; ~16 black before an
    intermission, then 52 frames (3 more than the port's flyer: lag, added at its end).
  Port: FlashTask ($4d), BuildTimes (app/game/build_times.rb, 98-round forced warps per version + targeted runs).
- ROUND BUILDS everywhere: a normal round start shows the same black build (MAME: $0c, 264 frames of the old round,
  black 5-8 frames, round + $07 on the same frame = $0c + 270). Sweeps of every round clear (mame_check/builds.lua,
  builds_x68.lua): arcade start = flash time (86 rounds) or +1 (13); X68000 start 17-25 frames, no fixed relation to
  its flash time (lag). Port: start_round(build: true) for game start / round clear / new life / continue ->
  BuildWaitTask ($4e): black, bottom line, then on frame B the round + its music; the intro proper starts frame B+1
  (MAME: enemies load and the intro run the frame after $07) in BuildWait's own slot 0 (slot order decides who runs
  first; the intro in slot 1 put the AI's divider reset a frame early). No $2b2 divider count during a build.
  Round clear: one tick of 5 frames before $0c / the warp ($03f9), then 44 ticks + 1 frame.
- INTERMISSION HANG (user): with an X68000 soundtrack the intermission waited for "music busy"; after a warp no Round
  Demo music starts and the round's looping BGM kept it busy for ever. Wait only at speed 1.
- ITEMS VERIFIED (mame_check/item_check.sh; port --item_test N,ROW, play.lua PLAY_ITEM: item spot under Ptolemy, walk
  counter 798, arcade handler table $48c2 patched to item N; spells every 42 frames): all 18 entries match the arcade
  on every frame (Ptolemy, divider, 8 slots) and every sound command over 1500 frames, except Star Tiara (stars use
  LD A,R) and the intro window after the feather's warp (old-round RAM, not visible). Scroll of Ice: the arcade DOES
  cake a frozen enemy (MAME: state 9 -> $10 -> $f0), X68000 code too ($61a4 skips only the contact test).
- REWIND (CASUAL only): app/game/rewind.rb. Snapshot = deep copy of the round world every 2 frames (0.37 ms, round 43),
  20 s; hold REWIND (R / pad LB, CONTROLS page) to step back; music held, re-synced on release. Dev: --rewind T0-T1.

## The moon, checked (pass 56, 2026-10-13) - mame_check/moon_check.sh
- CORRECTS pass 22 "120 at every new life": $1fd2 ($61b = $78) is in the NEW-GAME set-up $1f9c (also run by a
  continue, $1f86); a death re-enters at $1fd8 (arcade: $0321, after $031c's $78 / $e69f). The countdown runs through
  the whole game. Port reset it on every life - fixed (World.new_game sets $78; dev --moon applied after it, as the
  boot runs twice).
- All moon conditions in FS.X: $1fd2 set 120 (new game / continue); $2036 night flag cleared at a round start;
  $2080 / $20dc task 14 spawned at a round start / killed at a round clear (its first decrement is immediate: each
  restart takes a tick); $7534/$7540 item waits while $61b == $f0 and suspends 14, $7616 / $7b38 resume; $76a0 Moon
  Tiara = 1; $86e2/$86ee Horned waits while $f0, then kills 14 (rest of the round); $9090 the Dracolisk kills 14;
  $c87b = $7516 suspend / resume lists of the wipe ($574 = $ff after every pass, so nothing escapes). Tick = 60 + 60
  frames (60 shrunk). After a moon $f0 (240 ticks), decremented at once.
- MAME checks (round 1 idle with hits: deaths; NO HIT 6500 frames with the moon then Horned; countdown 60: Horned
  first; round 12 forced moon) - countdown, night flag, slots, sounds identical on every frame after three fixes:
  * Miss jingle $0b: the arcade board is busy 298 frames (port used the recording, 310): restart $07 12 frames late.
  * Morning jingle $15: busy 130 frames (port: until the 2.42 s file ended): $09 + the countdown 17 frames late.
    (Audio::BOARD_BUSY, arcade music set.)
  * Morning wipe 35 frames (port 34): first-frame share 147 -> 60. At its end the resumed tasks run in the same pass
    except the moon task and 0f (measured: the AI's cake rescans, the first hatch, the cake timers; the code resumes
    them together - not explained). Night unchanged.
- MOON widget: reads task 14: RISES IN (exact frames to the next tick + ticks), PAUSED: BONUS ITEM (suspended),
  STOPPED: HORNED (killed with $611 set), frozen between rounds (minus the tick a restart takes), MOON IS OUT, NO MOON
  (round 101). "RISEN THIS LIFE" removed.

## Widget preview + fades (pass 57, 2026-10-14)
User ideas. GAME OPTIONS > WIDGETS now previews the panels live in the side borders while the page is open (SHOW ON):
a made-up mid-round state (Widgets::SAMPLE_GAME; the timer and walk bars run), the real track if music plays.
In a game the panels fade (port only, alphas kept in Widgets, not in the game state - a rewind out of a death fades
them back in): in over 30 frames at the start of a game, down to 30 % while a death plays (w[:end_code] 10/20/40/80/ff)
until the round restarts, out over 45 frames for the ending / game over / name entry / continue (tasks 42-45).
MUSIC fades on its own (user): deaths and the ending leave it; it stays through the game over (and ARCADE's name
entry) and goes after it (continue screen / title). Two render layers (widget_layer, widget_music_layer); each lays out every
panel so the stacks keep their places. Checked with --shots: preview, the death dim, the game over in both modes.

## X68000 "Now Loading..." fade-in (pass 58, 2026-10-14)
User: on the X68000 the loading picture fades in; the port cut it in. FS.X $f5e: IOCS _CONTRAST 0 ($11, d1 = 0),
CRTMOD $10c, G_CLR_ON, the picture decoded into GVRAM ($3cc2), then _CONTRAST 15 ($fae) - one step in software, so
the fade is the hardware's contrast output settling. MAME 0.289's x68000 steps it (mean brightness 0 -> full in one
frame, then 1158 frames shown, cut out in one frame; per-frame pixel means with a throwaway lua). The port's curve is an
estimate: alpha over black = 1 - exp(-frame / 20) from the picture's first frame (Display::SPLASH_TAU) - to tune
against a real-hardware recording. Fade-out: none seen in FS.X (CRTMOD $61c after the jingle); left as a cut.

## Arcade Archives (Switch) as an arcade source (pass 59, 2026-10-14)
The user's Switch release (base v0 and update v1.0.2), unpacked with nstool 1.9.2: the RomFS holds only Hamster's
front end (fonts, menu CSVs, art, shaders, UI sounds). The ROMs are in the ExeFS `main` (NSO, LZ4 segments): all 14
files of MAME `flstory` - main CPU, graphics, sound CPU and the MCU a45-20.mcu - stored whole, back to back but not
aligned, in .rodata (base: vid-a45.18 at image $430cc0, cpu-a45.15 at $450da7, the MCU at $45cdbb; v1.0.2 the same
layout $1050 bytes later). Byte-identical to the user's MAME set. GameData.extract_embedded: when the set is incomplete,
any data/ file of 1-64 MB is scanned (an NSO first decoded: .rodata + .data only) with a rolling two-sum checksum per
ROM size (16 KB, 2 KB; GameData::ROLL holds the sums - numbers, like the CRCs), hits confirmed by CRC32, then written to
data/ under the MAME names so later starts load them directly. Tested in a copy of the game folder (data/ = `main`
only): ~1 s for the scan, all 12 ROMs the port uses byte-identical to the MAME set, the arcade title screen runs. PS4:
the same scan applies to any uncompressed file holding the ROMs (to check when the user has the files).

## 1.0 release prep (pass 60, 2026-10-14)
- Defaults: MUSIC VOLUME 4 -> 3 (SFX stays 10), the user's new balance; the mix may still need per-set gain work.
- New icon from the user (a 15x16 pixel-art cake at x25, transparent): make_icon.py now also takes a PNG, recovers the
  pixel grid (gcd of the colour-run starts) and builds icon / icon_ios / icon_large on the navy background as before.
- metadata version 0.1 -> 1.0. Dev outputs removed from the game folder (shot_*.png, script_end.png, objlog / tasklog /
  scenes / winseq / check_script, errors/) and the __pycache__ folders.
- NOTES section 8 split into research questions and the user's post-1.0 to-dos (PS4 Arcade Archives, audio balance,
  graphics review + features, input latency, licence).
