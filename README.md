# Copernicus

A native PC reimplementation of **The Fairyland Story**: Taito's 1985 arcade game, and the 1991 Sharp X68000 version by
SPS. It's written from scratch in Ruby on [DragonRuby](https://dragonruby.org), based on a full reading of both
original programs. It plays like the arcade by default, and can switch to the X68000 version's behaviour. It adds
modern extras: scaling and CRT-style filters, borders, info widgets, rebinding, a pause menu and a casual mode.

**No game data is included.** You need your own copy of the game: the arcade ROM set *or* the X68000 Disk 1 image.
See `dragonruby-linux-amd64/fairyland/data/README.txt`.

## Status

**Version 1.0.** The whole game is playable from either data source:
- all 101 rounds, every enemy, item and power-up, the Moon, Horned, the Worm, the teleport doors, and the Dracolisk;
- the intermissions, ending, game over, name entry and continue;
- the title, attract mode and demos.

The port has been checked frame by frame against MAME for both the arcade and the X68000 (see
[NOTES.md](NOTES.md) section 7). Planned after 1.0: the PS4 Arcade Archives release as a data source, audio balancing,
and more graphics options (NOTES.md section 8).

## How the project works

The project ran in three stages, which repeat for every feature.

1. **Read the original.**
   - `extract_disk.py` pulls the files off the X68000 disk.
   - `xload.py` / `disasm.py` load and disassemble `FS.X` (the 68000 game program).
   - `z80dis.py` disassembles the arcade's Z80 program; the 68705 MCU is disassembled with capstone.
   - `fs_lzss.py`, `sheets.py`, `palettes.py`, `metasprites.py`, `sprite_viewer.py` and `level_render.py` decode and
     view the graphics, palettes and rounds.

   Each routine is annotated, and then compared with its twin in the other version.
2. **Rewrite it.** The original is a set of up to 23 cooperative "tasks" (coroutines) run once per frame. The port
   keeps the same task ids, slot order and per-frame timing, but rewrites each one as a small plain-data state machine
   (`app/game/tasks/`). The engine reads the game's data tables by name from whichever version the player supplied
   (`app/fs/tables.rb`), so no data is ever copied into the code.
3. **Check it.** `mame_check/` runs the same scripted inputs in MAME and in the port, logs the game state every frame,
   and diffs it. Since the enemy AI has no randomness, any difference is a port bug or a real version difference. The
   differences found this way are listed in [docs/VERSIONS.md](docs/VERSIONS.md).

Where to read more:
- [NOTES.md](NOTES.md): how the original works (file formats, task scheduler, task roles, memory map, game rules,
  sound, MCU) and how the port is organised.
- [docs/VERSIONS.md](docs/VERSIONS.md): every difference between the arcade and the X68000, and how the port offers
  both.
- [docs/research-log.md](docs/research-log.md): the complete chronological log (60 passes) behind all of it.

## Running

You need the DragonRuby SDK (not included). The game folder is `dragonruby-linux-amd64/fairyland/`.

```
cd dragonruby-linux-amd64 && ./dragonruby fairyland
```

Default controls: arrows move, X / Space jump, Z spell, Enter = coin / start, and Esc = pause. Pads work, and both
keys and pads can be rebound in GAME OPTIONS > CONTROLS.

- **Dev flags:** see CLAUDE.md, for example `--round N`, `--shot N`, `--script "W20 JL3"`, `--x68k 1`, `--objlog N`.
- **Release builds:** `./make_release.sh` stages a clean copy (code, metadata and audio only, never `data/` or the saves)
  and runs `dragonruby-publish` for Windows, Linux and macOS.

## Repository contents and copyright

The repository holds **only original work**: the port's code, the analysis tools, and these notes. Everything owned by
Taito / SPS or other third parties stays local and is excluded by `.gitignore`:

| never published | why |
|---|---|
| disk images, extracted files, decoded data (`fl_files/`), `*.asm` disassemblies | the game itself |
| arcade ROMs, the X68000 BIOS (`x68000.zip`) | Taito / Sharp |
| soundtracks (FLAC, OGG, WAV, the VGM rip), `audio/` | music and sound recordings |
| screenshots, PCB captures, flyer art (`*.png`), border pictures | game graphics / third-party art |
| `flstory.xml` | a MAME cheat file by its own authors |
| the DragonRuby SDK | DragonRuby's licence; only the game folder is ours |
| `save.txt`, `settings.txt`, logs | local player data |

Some things in the source *are* derived from the game, but they are small facts rather than copied assets:
- memory addresses;
- a few short numeric tables that differ between versions, so that both behaviours work from either data source;
- the ghost-sway steps;
- tile codes;
- quoted strings in comments and notes.

The ending text, which differs between the versions, is built at load time from the player's own data rather than
stored in the code.

**Release binaries are different.** They bundle the soundtrack recordings (the arcade OST, the X68000 soundtracks,
MAME-recorded effects) and a cake icon based on the game's cake sprite. Those are copyrighted, so the binaries can't be
shared as freely as the source. To ship one publicly, you'd need either permission, or a build without `audio/` (the audio code skips
missing files, so it should run silent; not yet tested) and with an original icon.

## Licence

The code, tools and notes are released under the [MIT licence](LICENSE). It covers only that original work, not the
game, its data, the soundtrack recordings, the icon, or the DragonRuby SDK (see above).

## Thanks

- Taito and SPS for the game.
- MAME (the flstory and x68000 drivers, and the debugger and Lua scripting that made the frame checks possible).
- Jotego's flstory FPGA core (the sound board's tone controls).
- libvgm (vgm2wav).
- The Cutting Room Floor's arcade notes.
- The VGM rip's author.
