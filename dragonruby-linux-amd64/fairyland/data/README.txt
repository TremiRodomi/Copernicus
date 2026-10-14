Put your own copy of The Fairyland Story here - either version works:

  Arcade (Taito, 1985) - the ROMs of the "flstory" set, unzipped, loose in this folder:
    cpu-a45.15 cpu-a45.16 cpu-a45.17
    vid-a45.06 vid-a45.07 vid-a45.08 vid-a45.09 vid-a45.18 vid-a45.19 vid-a45.20 vid-a45.21
    a45-20.mcu  (the protection MCU - it was dumped later, so older sets such as Taito Legends 2's lack it:
                 take it from a current MAME "flstory" set)
  The ROMs are recognised by their contents, not their names, so renamed files work, and so does a file that
  holds several ROMs back to back. The older "flstoryo" set works too (only its sound ROMs differ; they are not used).

  Arcade Archives (Hamster, Nintendo Switch) - the game's executable "main" (in the program NCA's ExeFS, unpacked from
  your own dump with nstool or hactool), copied into this folder. It holds the whole ROM set, MCU included: on the first
  start the ROMs are found inside it and saved here under the names above (about a second), then "main" is no longer
  needed.

  X68000 (SPS, 1991):
    - the Disk 1 image (.hdm or .dim), or
    - the files FS.X, BGCHR.DAT and SPCHR.DAT taken from it.

If both are present the arcade files are used (start with --source x68k to use the X68000 disk instead).
The game plays like the arcade either way; GAME OPTIONS > BEHAVIOUR switches to the X68000 version's behaviour.
The game's program and data are not distributed with this port: you supply them. (Release builds do bundle
soundtrack recordings, and the icon is Ptolemy's cake from the game.)
