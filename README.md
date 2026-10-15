# Copernicus

  *A native PC port of The Fairyland Story (Taito, 1985 arcade / SPS–Taito X68000, 1991).*

  ## What is this?
   This is a clean reimplementation of The Fairyland Story by Taito using DragonRuby.
   This is neither a decompilation nor an emulator, but rather a full port of the original
   game logic to a modern royalty-free game engine that suits the features best, achieved
   with disassembly and frame-by-frame comparisons. Its main goal is to port the game to
   PC, alongside adding a litany of extra features.

  **Features**
  - Arcade and X68000 behaviour, from either data source
  - CASUAL mode (progress save, rewind) and ARCADE mode (hiscores and progress saving)
  - Widescreen borders, display filters, etc.
  - Pause
  - M2-styled widgets that show you under-the-hood mechanics of the game
  - Controller support and control rebinding
  - Possibly more to come

  ## Why I made it

  The Fairyland Story has always been one of my favorite games from Taito. Me and a few
  others have more recently helped lift it from its reputation of "Bubble Bobble's not
  very good ancestor" to a game that is worthy of standing in Taito's excellent
  platformer pedigree, and it's thanks to more measured reappraisals combined with
  the game getting some accessible modern ports. However, as someone that has been referred to as
  one of the world's leading experts on the game, I always felt most ways to play the game
  don't stack up to the real PCB of the game (which I own). In short, it has some rather
  esoteric hardware for the time that's hard to emulate, specifically its hybrid
  analog and digital sound hardware (that the game directly controls) to add depth to
  its sound.

  Some ports make up for this with additional options (like saving in the Sharp X68000
  port, more on that in a bit), but ultimately none are 1:1 to the real PCB, even
  unofficial emulation. Officially, the best version of the game accuracy-wise is
  the version on the Taito Egret II Mini, but the sound effects being at the wrong pitch
  stop it from being a fairly accurate representation of how the game is in the arcade.
  However, with me getting a PCB, I have helped unofficial emulation get better. The sound
  emulation of the game in MAME got better thanks to this, and me loaning my PCB out to
  Jotego is why we got an FPGA core of the game. However, even with these developments, it
  still doesn't quite stack up to the original PCB, but it's no fault of theirs due to how
  the hardware works.

  Seeing the rise of decomps, I didn't feel the need to jump in the ring at first. I thought
  they were cool, but a fad. Then I got bored one day and started feeding random game data to
  Claude, to see what it could find, including TFLS. For both the arcade and Sharp ports,
  it found that they were nearly 1:1 logic-wise and that it could be easy to drop the logic
  from them into a modern game engine. I started thinking, what if I could make what I deem
  to be the "perfect" port of the game, with the best of each version? Besides watching
  videos and reading up on the subject, RE has never been my strong suit, but I'd heard Claude
  was scary good at it. I decided to humor it just this once. Got surprised with the results, and
  instead of dumping it in the bin, I decided to let it cook. And now you have the result of my
  experiment right here.

  ## How and why AI was used

  Before you ask, yes this was heavily vibecoded. Claude disassembled both ports of the game, and by my
  request, plopped a clean-room-ish reimplementation of the game's logic into DragonRuby, which was
  mostly its job. Claude also helped through a lot of the tedious processes like editing the
  music/sound effects (for the release builds) and frame-by-frame comparisons of the game. It also
  added a bunch of features into the port like the rewind and widgets, also by my request.

  Despite how easy all this might sound, it also involved a lot of prompting and extra passes to make it
  behave well. While it was super scary how close it got the game logic just like that, I also had to
  tell it dumb things like that Ptolemy and the enemies aren't in their right positions. So even
  still, a lot of once-overs with the OG game by my side were needed to make this port any good.
  I also put it in a game engine specifically to make the logic port easier, and to make the release
  binaries almost trivially easy to make.

  It was also scary good at finding differences between the versions of the game. I used the Sharp
  port of the game as a basis for the port, but it quickly shifted to a hybrid approach when it
  became clear that both versions of the game are different, especially the Sharp version, which
  had to account for the logic that the arcade version's copy protection chip provided. (More info on
  that in the docs, and yes, you can play it with either set of behaviours.)

  I realize people are tired of AI-generated content, specifically AI-driven decomps. Before you
  (understandably) write this off, please do note that I know the game by heart to
  the point there have been no inaccuracies that I could spot on hand in the release build.
  All of the behaviours of the game have been verified frame-by-frame, to MAME and the PCB of
  the game, both by AI and by hand. I would hate to release a broken version of the game when
  the game never got that much love in the first place. To me this is mostly an experiment
  of how well it can figure out an obscure arcade game from 1985, and how well I can make
  a polished port out of it. I want to prove that not all AI decomps are bad in that sense and
  that they can be quality, even if this isn't really a decomp in the traditional sense.

  Despite how much I want this to be a good, feature-packed version of the game in spite of the
  vibecoding, I don't want this to replace any other versions of the game, either. If you're not keen
  on the AI-driven code, the Arcade Archives port and Jotego's excellent FPGA core of the game
  are right there if you prefer those instead. I will not blame you. But looking at the writing on
  the wall, AI is here to stay. Most of the developers, if not all of the ones I've talked to,
  are using AI bots to generate code now and it'd be silly to not think of ways to accelerate that
  admittedly mundane process, even if they know it by heart. I also won't pretend that I made this by
  hand fully, especially with how little I program otherwise. It's also made RE much more bearable,
  and indeed even MAME has embraced that, with them figuring out a litany of long-standing inaccuracies
  and unbroken copy protection systems thanks to it.

  I am also a great believer that it shouldn't replace actual creative processes, and indeed
  none of the game content in here has been modified in that sense. I wanted it to be a
  match with the arcade PCB, even. I also had to source a lot of info myself on how the game
  works over to Claude in order to make it figure it out better. This was also a way to finally
  teach myself coding and more RE. I won't lie, it's still confusing, but AI was the reason this
  got finished instead of yet another abandoned file on my hard drive.

  Anyways, I'm rambling a bit now. If you've gotten this far, thank you for reading this. Even if
  nothing else, I want to show the world my experiment, even if it's not entirely a useful one
  at the end of the day.

  ## Getting started

  ### Supply your own game data
  Copernicus does **not** include any game data. You need ONE of the sources below, copied into
  the `data/` folder next to the game (`data/README.txt` has the same list). Whichever you use,
  the game plays like the arcade by default, and GAME OPTIONS > BEHAVIOUR switches to the X68000
  version's behaviour. If both arcade and X68000 files are present, the arcade files are used;
  start with `--source x68k` to use the X68000 disk instead.

  #### Arcade ROM set
  - MAME's `flstory` set, unzipped, with the files loose in `data/`. The older `flstoryo` set works
    too (only its sound CPU ROMs differ, and Copernicus doesn't use those).
  - The files used are `cpu-a45.15`–`.17` (main CPU), `vid-a45.06`–`.09` and `vid-a45.18`–`.21`
    (graphics) and `a45-20.mcu` (the protection MCU).
  - ROMs are recognised by their contents (CRC32), not their names, so renamed files work, and so
    does a single file holding several ROMs back to back.
  - **The MCU dump is required.** It was dumped late, so some older collections (Taito Legends 2,
    for example) ship without it. Take it from a current MAME `flstory` set.

  #### Arcade Archives (Nintendo Switch)
  Hamster's Arcade Archives release contains the complete `flstory` ROM set, MCU included and
  byte-identical to MAME's, so it works as an arcade source. The ROMs aren't stored as separate
  files, though: the RomFS only holds Hamster's front end (menus, fonts, art, shaders), and the
  ROMs themselves are embedded in the game's executable. Copernicus finds and extracts them for you:

  1. Dump your own copy of the game from your Switch. The base release and the v1.0.2 update both work.
  2. Unpack the program NCA's ExeFS with [nstool](https://github.com/jakcron/nstool) or hactool
     (using your own console's keys), and take the file named `main`.
  3. Copy `main` into `data/`.
  4. Start Copernicus. On the first start it decompresses `main` (a Switch NSO executable), scans it
     for each ROM with a rolling checksum, confirms every hit by its CRC32, and saves the ROMs into
     `data/` under their MAME names. This takes about a second.
  5. From then on the extracted ROMs load directly, and `main` can be deleted.

  The PlayStation 4 release hasn't been tested yet. The same scan should work on any uncompressed
  file that holds the ROMs, and official support is planned.

  #### X68000 Disk 1
  - The Disk 1 image as `.hdm` or `.dim`, or the files `FS.X`, `BGCHR.DAT` and `SPCHR.DAT` taken
    from it (plus `FLS_TTL.DAT` for the boot picture).
  - Both circulating dumps work. They differ by only 6 bytes of `FS.X`, which are two different
    cracks of the disk's copy protection. Copernicus ignores the protection entirely.
  - Disk 2 (the save disk) isn't needed: Copernicus keeps its own saves and settings.

  ## Building from source
  [Short version: DragonRuby 7.23, put `fairyland/` in the SDK folder, run `./dragonruby fairyland`.
  Link to docs/ for the research notes if you want people to read them.]

  ## Legal
  The Fairyland Story is © Taito Corporation / Square Enix. Copernicus is an unofficial fan project,
  not affiliated with or endorsed by Taito, Square Enix, or SPS. No copyrighted game data is distributed
  with this repo; you must own the original game. Release builds do contain the game audio, but this is
  necessary for it to run. It still needs the game data otherwise for it to work.

  Code licence: MIT (see LICENSE).

  ## Thanks
  - Taito
  - MAME
  - Jotego
  - DragonRuby
  - TCRF
