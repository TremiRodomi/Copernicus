# All mutable game state as plain data (Hashes, Arrays, Integers) so a frame can be snapshotted for rewind / save states.
# Field names follow the original's work-area variables; the $offset is noted where it helps cross-checking with NOTES.md.
module World
  # Per-game state that survives deaths and round changes (reset by $1f9c at game start)
  def self.new_game(lives)
    {
      lives: lives == 0 ? 1 : lives, # $704 BCD; 0 = game over
      endless: lives == 0,         # the lives setting 0 = ENDLESS ($576 & $18 / arcade DSW $d800 & $18 = 0): no life lost
      steps: 0,                    # $707/$708 distance walked; every 800 px spawns a bonus item (task 15)
      level: 0,                    # $705 Ptolemy's level (a Wraith's touch takes one away)
      hiscore: 0,                  # $6d0-$6d2 (FS.DAT's table is not loaded yet)
      score: 0,                    # $700-$702 as a number (6 BCD digits; the HUD adds a fixed trailing 0)
      exp: 0,                      # $57f hidden EXP (set to round - 1 at every round start / life, see main.rb)
      exp_next: 0x1d,              # $706 next level-up threshold
      rng: 0,                      # $5c: +1 every vblank, +$5a per $58c call
      horned_path: 0,              # $6cd Horned's last entrance script (1-4, taken in turn)
      streak: 0,                   # $67d coin pickup streak: kept across rounds, reset by a new life ($1fd8) or a missed coin
      moon: 0x78,                  # $61b moon countdown (task 14), 2 s ticks; reset to 120 on every new life
      r_reg: 0xace1                # stand-in for the arcade's Z80 refresh register (LD A,R), see World.r_reg
    }
  end

  def self.new_round(gd, rb, number, game = new_game(3))
    {
      round: number,
      game: game,
      end_code: 0,                 # $62e: 0 playing, $40 killed by an enemy, $20 / $10 other endings, $ff round over
      killer: 0,                   # $596 task id of the enemy that touched Ptolemy ($ff = none)
      power: 0,                    # $59b active power-up (0 none; bit 7 = no contact damage)
      no_hit: false,               # $578 bit 6 clear: the original's NO HIT debug switch
      frame: 0,
      cm: rb.collision_map,        # collision memory $716 (see RoundBuilder#collision_map)
      shadow: Array.new(128),      # sprite shadow list (single-buffered, persistent): [x_reg, y_reg, attr] or nil
      flags591: 0x2a,              # $591: boot sets $22 ($1dce), round setup sets bit 3; bit 1 (never cleared) lifts every sprite 2 px
      input: 0x0f,                 # $48ca result: active-low  bit0 spell, bit1 jump, bit2 left, bit3 right
      sounds: [],                  # sound commands issued this frame ($4ac ids, see sound_commands.csv)
      obj: Array.new(8) { Array.new(12, 0) }, # object slots $59d (see Obj in tasks/enemy.rb)
      enemies_left: 0,             # $5fd (bit 7: last-enemy flag)
      speed: rb.enemy_speed || 0xff, # $5fe enemy speed byte
      div600: 0,                   # $600 speed divider: enemies stall a frame whenever it is 0
      wizard_id: 0,                # $612 task id of the Wizard whose spell shrank Ptolemy (0 = normal size)
      mode626: 0,                  # $626: Glass Potion invincibility ($80); bit 0 flips every frame = Ptolemy hidden ($1d4e)
      cake_x: 0, cake_y: 0,        # $60d / $60e AI target beside a cake
      t60f: 6, t610: 1, t611: 0,   # task 04 round timer
      shot: { active: 0, x: 0, y: 0, step: 0 }, # $598-$59a, $59c Ptolemy's spell ($598: $ff flying, $80 spent on a hit)
      spell_delay: 0,              # $597 recast delay while the button is held
      mode593: 0,                  # $593 background animation mode (also task 0e's rate)
      kills5ff: 0,                 # $5ff kills by the current power-up
      combo: 0,                    # $67e crush / kill count being scored
      bonus623: false,             # $623 night: cake breaks / dissolves drop bonus coins (task 14)
      night: 0,                    # $61d 1 = night wipe pending, $ff = morning wipe pending (NightWipe, main loop)
      wipe: nil,                   # NightWipe progress (ring radius)
      moon_pos: 0xc74f, moon_col: 6, # $61e / $622
      flag654: 0,                  # $654 (non-zero: Wraiths stop vanishing; not identified yet)
      input_override: nil,         # $592: when set, $48ca returns it instead of the controls (intro, attract demo)
      flag6b6: 0,                  # $6b6 handshake with the scripted-animation tasks 1a / 1b
      flag6f4: 0,                  # $6f4 (round clear keeps the Worm's task when set)
      anim6f3: 0,                  # $6f3 background animation phase
      bg: { tiles: rb.tiles.dup, attrs: rb.attrs.dup }, # the name table ($b36 work copy): text and animations write here
      bg_dirty: [],                # cells to redraw
      sparkles: Array.new(3) { Array.new(4, 0) },  # $601 [timer, type, x, y]
      popups: Array.new(8) { Array.new(5, 0) },    # $67f [timer, kind, slot, y, x]
      drops: Array.new(8) { Array.new(5, 0) },     # $655 [timer, item code, slot, y, x]
      power_timer: 0,              # $652 power-up timer (ticks)
      pal_patch: {},               # sprite palette patches: colour index -> X68000 word (PalPatch, task 1d)
      shake: 0,                    # $56 / arcade scroll RAM: Book of Death screen shake (px)
      warp: 0,                     # $653 rounds to skip (Mystical Feather)
      stars: [],                   # $6a7 Star Tiara stars
      item_spawn: rb.item_spawn || [0, 0], # $650 / $651
      prio: 1,                     # $57e sprite priority list (1 normal, 2 death / potions, 3 eaten by the Worm)
      door: nil,                   # $6f5 / $6f6 the Worm's door (task 26)
      door_pair: rb.door_pair,     # $6c2-$6c5 teleport doors (task 20)
      door_open: 0,                # $6c6 a teleport door is showing its open tiles
      eshots: Array.new(2) { Array.new(4, 0) }, # $613 / $617 enemy shots [owner id or $ff, y, x, facing]
      pending: [],                 # events for tasks that are not ported yet (e.g. :horned)
      player: {
        x: 0xa0, y: 0x24,          # $627 / $628 (game coords: x grows leftward, y grows upward)
        anim: 0,                   # $62a
        facing: 0,                 # $62b: 0 = facing left (+x), $0d = facing right
        char: 0,                   # $62c: sprite-set base: 0 normal, $1c shrunk (Wizard), $38 (half-rate anim)
        speed: 2,                  # $62d px per walk step
        step_delay: 3,             # $634 frames per walk step
        jdx: 0,                    # $629 horizontal jump speed (1 / $ff / 0)
        latch: 0,                  # $62f jump button must be released before the next jump
        cast: 0,                   # $630 casting-pose timer
        fall_count: 0,             # $631
        riding: 0,                 # $632 task id of the object stood on
        alt_walk: 0,               # $633 one-shot: use the alternate walk table ($c510) and pause a frame
        last_input: 0x0f,          # $64f
        trail: Array.new(21, 0),   # $63a..$64e: last 10 (y, x) positions, ring buffer + the $64e terminator
        trail_pos: 0               # $636
      },
      tasks: Array.new(Scheduler::SLOTS), # task slots $234
      running: nil                 # $574 slot index of the task being run
    }
  end

  # Behaviour set: :arcade (default) or :x68000. Every known difference between the versions checks this (NOTES.md
  # "Version differences"); the X68000 branch reproduces FS.X exactly.
  def self.x68k?(w)
    w[:opts] && w[:opts][:behaviour] == :x68000
  end

  # $48ca
  def self.input(w)
    w[:input_override] || w[:input]
  end

  # $58c
  def self.rand(w)
    g = w[:game]
    v = g[:rng]
    g[:rng] = (v + 0x5a) & 0xffff
    v
  end

  # The arcade reads the Z80 refresh register (LD A,R) where the X68000 calls $58c; R depends on the exact instruction
  # count, so it behaves like noise. A 16-bit xorshift stands in (kept in the game state, so rewind stays deterministic).
  def self.r_reg(w)
    g = w[:game]
    v = g[:r_reg]
    v ^= (v << 7) & 0xffff
    v ^= v >> 9
    v ^= (v << 8) & 0xffff
    g[:r_reg] = v
    v & 0x7f
  end

  # Read-only game data for code that has no gd argument (kept out of the world so snapshots stay plain data)
  class << self
    attr_accessor :gd
  end

  def self.byte(v)
    v & 0xff
  end

  def self.sbyte(v)
    v &= 0xff
    v >= 0x80 ? v - 0x100 : v
  end

  # $48b0: collision index for game coords
  def self.cmi(x, y)
    ((y & 0xf8) << 2) + ((x & 0xf8) >> 3)
  end

  # Out-of-range reads hit other work-area variables in the original; the port treats them as empty.
  def self.cm(w, i)
    i >= 0 && i < 0x420 ? w[:cm][i] : 0
  end

  def self.solid?(w, x, y)
    cm(w, cmi(x, y)) & 1 == 1
  end
end
