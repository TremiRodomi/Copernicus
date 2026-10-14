# Audio (not part of the source - bundled with release builds only)

One folder per set: `arcade/` (music: the arcade OST; effects: MAME recordings made with `mame_sfx.py`), `original/` and `arrange/` (the X68000 soundtracks).

- `<set>/music/` - the music. `tracks.txt` maps sound commands to tracks (`07 = 02 Stage Start > 03 First Half BGM`);
  a track `X` is `X.ogg` played once, or `X intro.ogg` then `X loop.ogg` looped. `lengths.txt` (sample counts) is
  written by `ost_loops.py` in the project root, which also builds the files from FLAC/WAV and finds or applies loop
  points (`loops.txt`: `<name> = <start sample> <period samples>`).
- `<set>/<cmd hex> <name>.ogg|.wav` - single sounds by command number (`16 ptolemy jump.ogg`). Numbers: sound_commands.csv.
- `<set>/flat/` - the same effect file names rendered without the sound board's TA7630 tone controls; GAME OPTIONS >
  SFX FILTER picks PCB (the files in `<set>/`, `mame_sfx.py --eq shelf`) or OFF (`--eq flat`). See NOTES.md pass 37.
- `original/`, `arrange/` - the X68000 soundtracks, built from the VGM rip by `vgm_sets.py` (music only: every set uses
  the arcade effects). `tracks.txt` may name `X*` = the loop part of X alone, looped.
- Music comes from the set chosen in GAME OPTIONS > MUSIC, else from arcade/; effects likewise.
