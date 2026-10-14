# Task 0f ($6158): the object-state manager. Every 2 frames it runs each object's non-walking states and the interactions
# between objects, Ptolemy and her spell: appearing, touch death, enemies pushing each other, spell hits, enemies wrapped
# into cakes, cakes pushed by Ptolemy / enemies, cakes running out, dissolving, burning and escaping.
# Object states: 1 walk .. 7 (task-driven), 8/9 special, $10 just hit, $20 appearing, $30 escaping,
# $80-$8f / $90 dissolving / $91 burning / $92 / $e0 carried by a falling cake / $e1 crushed, $f0 cake, $f1+ falling cake.
module ObjectStates
  SPARKLE_FRAMES = :sparkle_frames
  DISSOLVE = :dissolve # $90 frames by countdown
  BURN = :burn    # $91 frames by countdown / 4, plus the enemy type
  ESCAPE = :escape   # $30 frames by countdown ($1b22 table)
  CAKE = 0xeb       # cake sprite ($1ab6 table)
  SND_BURN = 0x26

  # Tasks frozen when Ptolemy is touched ($c87b); the running task (this one) is skipped
  FREEZE = [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x11, 0x12, 0x13, 0x14, 0x24, 0x0f, 0x26]

  def self.run(w, t, gd)
    if t[:pc] == :start
      Scheduler.spawn(w, 0x11) # falling cakes
      Scheduler.spawn(w, 0x17) # dropped items
      t[:pc] = :pass
      return 2
    end
    w[:obj].each { |o| step(w, gd, o) }
    2
  end

  def self.step(w, gd, o)
    st = o[Obj::ST]
    return if st == 0
    if st >= 0x80
      return if st == 0x92
      return dying(w, gd, o) if st < 0xf0
      return unless st == 0xf0
      return unless cake(w, gd, o)
      return spell_check(w, gd, o)
    end
    case st
    when 0x10 then return hit_timer(w, gd, o)
    when 0x20 # $63a6: appear
      o[Obj::ST] = 1
      Scheduler.spawn(w, o[Obj::TASK])
      return
    when 0x30 then return escaping(w, gd, o)
    when 8 then return
    end
    contact(w, o) unless st == 9 || w[:power] >= 0x80
    push(w, o)
    spell_check(w, gd, o)
  end

  # $695a: an enemy within 8 px of Ptolemy horizontally and on her height (-8..+7; only -4..+7 above her when she is shrunk) kills her
  def self.contact(w, o)
    p = w[:player]
    return if (p[:x] - o[Obj::X]).abs >= 8
    dy = p[:y] - o[Obj::Y]
    if dy < 0
      return if (dy & 0xff) < (p[:char] == 0x1c ? 0xfc : 0xf8)
    elsif dy >= 8
      return
    end
    return if w[:no_hit]
    w[:end_code] = 0x40
    w[:killer] = o[Obj::TASK]
    w[:game][:level] -= 1 if o[Obj::TYPE] == 0x57 && w[:game][:level] > 0 # a Wraith drains a level
    me = w[:tasks][w[:running]][:id]
    FREEZE.each { |id| Scheduler.kill(w, id) unless id == me }
  end

  # $61b4: an enemy overlapping another on the same row is pushed away from Ptolemy's side
  def self.push(w, o)
    px = w[:player][:x]
    w[:obj].each do |a|
      next if a[Obj::ST] == 0 || a[Obj::ST] > 0x80
      next if a[Obj::TASK] == o[Obj::TASK]
      next unless World.sbyte(a[Obj::Y] - o[Obj::Y]).abs < 9
      dx = (a[Obj::X] - o[Obj::X]) & 0xff
      if dx >= 0x80
        next if dx < 0xf5 || px >= o[Obj::X]
        unless World.solid?(w, o[Obj::X] + 16, o[Obj::Y])
          o[Obj::X] = (o[Obj::X] + 2) & 0xff
          o[Obj::CMD] |= 0x10 if a[Obj::ST] == 1
        end
      else
        next if dx >= 0x0b || px < o[Obj::X]
        unless World.solid?(w, o[Obj::X] - 1, o[Obj::Y])
          o[Obj::X] = (o[Obj::X] - 2) & 0xff
          o[Obj::CMD] |= 0x10 if a[Obj::ST] == 1
        end
      end
      return
    end
  end

  # $6280: Ptolemy's spell against this object
  def self.spell_check(w, gd, o)
    sh = w[:shot]
    return if sh[:active] == 0
    return if (sh[:x] - o[Obj::X]).abs >= 0x0a
    dy = World.sbyte(sh[:y] - o[Obj::Y])
    return if dy < -12 || dy >= 0x10
    power = w[:power]
    if o[Obj::CMD] & 0x20 != 0 # summoned by a Cleric: gone with one hit
      Score.add(w, 0, 1)
      sh[:active] = 0x80 unless power == 3
      return remove(w, o)
    end
    o[Obj::JDX] = power # remembered for the $10 state
    if power == 3 # $62f4: fire spell burns
      Effects.sparkle(w, 4, o[Obj::X], o[Obj::Y])
      return knock(w, o)
    end
    Effects.sparkle(w, 0, o[Obj::X], o[Obj::Y])
    sh[:active] = 0x80
    if power == 2 # $630a: instant kill
      Scheduler.kill(w, o[Obj::TASK])
      Score.exp(w, 1)
      Score.multi_kill(w, o, 8)
      o[Obj::ST] = 0x90
      o[Obj::ANIM] = 6
      return
    end
    return knock(w, o) if o[Obj::ST] < 0x80
    # $6336: another hit on a cake wraps it tighter; enough hits and it dissolves for points
    Shadow.set_b(w, gd, CAKE, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
    o[Obj::ANIM] = (o[Obj::ANIM] + (o[Obj::TYPE] == 0x3a ? 2 : 4)) & 0xff # Golems unwrap faster
    o[Obj::JDX] = 0x0a
    return if o[Obj::ANIM] < 0x1e
    Score.by_type(w, o, :score_dissolve)
    ItemDropTask.drop(w, o, 0x36, 0x41) if w[:bonus623] # $7d60: at night a dissolved cake leaves a coin
    o[Obj::ST] = 0x90
    o[Obj::ANIM] = 6
  end

  # $638e: stop the enemy and start the hit countdown
  def self.knock(w, o)
    Scheduler.kill(w, o[Obj::TASK])
    o[Obj::ST] = 0x10
    o[Obj::ANIM] = 6
  end

  # $63b8: after the hit countdown the enemy becomes a cake (or burns, for the fire spell)
  def self.hit_timer(w, gd, o)
    o[Obj::ANIM] = (o[Obj::ANIM] - 1) & 0xff
    return unless o[Obj::ANIM] == 0
    if o[Obj::JDX] == 3
      o[Obj::ST] = 0x91
      o[Obj::ANIM] = 0x40
      Score.exp(w, 1)
      Score.multi_kill(w, o, 0x13)
      return
    end
    o[Obj::ST] = 0xf0
    o[Obj::ANIM] = o[Obj::TYPE] == 0x3a ? 6 : 0x0c # cake lifetime in 10-tick units; Golems break out sooner
    o[Obj::JDX] = 0x0a
    o[Obj::Y] &= 0xf8
    Shadow.set_b(w, gd, CAKE, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
    Cake.mark(w, o)
  end

  # $6436: a cake. Returns false when it hatched (the caller then skips the rest). Byte counters: the moon makes cakes
  # without resetting JDX, so it can wrap through $ff (MAME: a night cake's first hatch step then comes 256 ticks later).
  def self.cake(w, gd, o)
    o[Obj::JDX] = (o[Obj::JDX] - 1) & 0xff
    if o[Obj::JDX] == 0
      o[Obj::JDX] = 0x0a
      o[Obj::ANIM] = (o[Obj::ANIM] - 1) & 0xff
      if o[Obj::ANIM] == 0 # the enemy breaks out
        Cake.unmark(w, o)
        o[Obj::ST] = 1
        Scheduler.spawn(w, o[Obj::TASK])
        spell_check(w, gd, o)
        return false
      end
    end
    pushed_by_player(w, gd, o) || pushed_by_enemies(w, gd, o)
    shove_enemies(w, o) if o[Obj::ST] == 0xf0
    if o[Obj::ANIM] < 9 # $66a2: about to hatch: blink
      Shadow.set_palette(w, o[Obj::SLOT] >> 2, (Shadow.palette(w, o[Obj::SLOT] >> 2) & ~1) | (o[Obj::ANIM] & 1))
    end
    true
  end

  # $6460: Ptolemy walking into a cake pushes it 2 px (and $633 makes her stumble a frame)
  def self.pushed_by_player(w, gd, o)
    p = w[:player]
    return false if World.sbyte(p[:y] - o[Obj::Y]).abs >= 9
    d = World.sbyte(p[:x] - o[Obj::X])
    return false if d == 0
    if d < 0
      return false if d < -11
      p[:alt_walk] = d & 0xff
      return false if World.solid?(w, o[Obj::X] + 16, o[Obj::Y])
      move_cake(w, gd, o, 2)
    else
      return false if d >= 0x0c
      p[:alt_walk] = d
      return false if World.solid?(w, o[Obj::X] - 1, o[Obj::Y])
      move_cake(w, gd, o, -2)
    end
    true
  end

  # $64ee: an enemy (or cake) walking into a cake pushes it too; a walking enemy switches to state 6 while it pushes
  def self.pushed_by_enemies(w, gd, o)
    w[:obj].each do |a|
      next unless a[Obj::ST] == 0xf0 || (a[Obj::ST] >= 1 && a[Obj::ST] <= 0x80)
      next if World.sbyte(a[Obj::Y] - o[Obj::Y]).abs >= 9
      d = World.sbyte(a[Obj::X] - o[Obj::X])
      next if d == 0
      if d < 0
        next if d < -11
        a[Obj::ST] = 6 if a[Obj::ST] == 1
        next if World.solid?(w, o[Obj::X] + 16, o[Obj::Y])
        move_cake(w, gd, o, 2)
      else
        next if d >= 0x0c
        a[Obj::ST] = 6 if a[Obj::ST] == 1
        next if World.solid?(w, o[Obj::X] - 1, o[Obj::Y])
        move_cake(w, gd, o, -2)
      end
      return true
    end
    false
  end

  def self.move_cake(w, gd, o, dx)
    Cake.unmark(w, o)
    o[Obj::X] = (o[Obj::X] + dx) & 0xff
    Cake.mark(w, o)
    Shadow.set_b(w, gd, CAKE, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
  end

  # $65a4: a cake Ptolemy is pushing shoves the enemies in front of it (unless she lets go of the direction)
  def self.shove_enemies(w, o)
    p = w[:player]
    w[:obj].each do |a|
      next unless a[Obj::ST] >= 1 && a[Obj::ST] <= 0x80
      next if (o[Obj::Y] - a[Obj::Y]).abs >= 0x18
      d = o[Obj::X] - a[Obj::X]
      next if d == 0
      if d > 0
        next if d >= 0x0e
        next if World.solid?(w, a[Obj::X] - 1, a[Obj::Y])
        next if (p[:y] - a[Obj::Y]).abs >= 0x0c
        next if ((p[:x] - a[Obj::X]) & 0xff) >= 0x1b
        a[Obj::X] = (a[Obj::X] - 2) & 0xff
        a[Obj::JDX] = 0xff
        a[Obj::CMD] |= 0x10 if p[:last_input] & 8 == 0
      else
        next if (d & 0xff) < 0xf3
        next if World.solid?(w, a[Obj::X] + 16, a[Obj::Y])
        next if (p[:y] - a[Obj::Y]).abs >= 0x0c
        next if ((p[:x] - a[Obj::X]) & 0xff) < 0xe6
        a[Obj::X] = (a[Obj::X] + 2) & 0xff
        a[Obj::JDX] = 1
        a[Obj::CMD] |= 0x10 if p[:last_input] & 4 == 0
      end
    end
  end

  # $66d4: states $80-$ef count down; at 0 the object is gone
  def self.dying(w, gd, o)
    o[Obj::ANIM] = (o[Obj::ANIM] - 1) & 0xff
    if o[Obj::ANIM] != 0
      case o[Obj::ST]
      when 0x90 # dissolving
        Shadow.set_b(w, gd, gd.byte(gd.a(DISSOLVE) + o[Obj::ANIM]), o[Obj::Y], o[Obj::X], o[Obj::SLOT])
      when 0x91 # burning
        w[:sounds] << SND_BURN if o[Obj::ANIM] == 0x1c
        f = gd.byte(gd.a(BURN) + (o[Obj::ANIM] >> 2)) + o[Obj::TYPE]
        last = Shadow.set_b(w, gd, f, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        unless o[Obj::JDX] == 3 # tint the last two parts
          pal = o[Obj::TYPE] >= 0x74 ? 8 : 2
          [last - 4, last - 8].each { |s| Shadow.set_palette(w, (s & 0xff) >> 2, pal) }
        end
      end
      return
    end
    Cake.unmark(w, o)
    return remove(w, o) unless o[Obj::TYPE] == 0x74
    # $66ea: when a Cleric dies, every Cleric goes (the others score 200)
    w[:obj].each do |a|
      next if a[Obj::ST] == 0 || a[Obj::TYPE] != 0x74
      a[Obj::ST] = 0
      Score.add(w, 0, 0x20) unless a[Obj::TASK] == o[Obj::TASK]
      Scheduler.kill(w, a[Obj::TASK])
      Shadow.clear(w, a[Obj::SLOT])
      Shadow.clear(w, a[Obj::SLOT] + 4)
      w[:enemies_left] -= 1
    end
  end

  # $6746
  def self.remove(w, o)
    o[Obj::ST] = 0
    Scheduler.kill(w, o[Obj::TASK])
    Scheduler.spawn(w, 0x16) if w[:wizard_id] == o[Obj::TASK] # the Wizard is gone: Ptolemy grows back
    gone(w, o)
  end

  def self.gone(w, o) # $6768
    w[:enemies_left] -= 1
    Shadow.clear(w, o[Obj::SLOT])
    Shadow.clear(w, o[Obj::SLOT] + 4)
  end

  # $6820: escaping (the last enemy leaving when time runs out)
  def self.escaping(w, gd, o)
    o[Obj::ANIM] = (o[Obj::ANIM] - 1) & 0xff
    if o[Obj::ANIM] == 0
      o[Obj::ST] = 0
      return gone(w, o)
    end
    Shadow.set_b(w, gd, gd.byte(gd.a(ESCAPE) + o[Obj::ANIM]), o[Obj::Y], o[Obj::X], o[Obj::SLOT], :meta_poses)
  end
end

# Cake marks in the collision map ($6888 / $689e): bits 1-3 of the 2x2 cells under the cake. Nothing reads them (every
# collision test looks at bit 0), so cakes are not solid; kept for fidelity.
module Cake
  def self.cells(o)
    i = World.cmi(o[Obj::X], o[Obj::Y])
    [i, i + 1, i + 0x20, i + 0x21].select { |k| k >= 0 && k < 0x420 }
  end

  def self.unmark(w, o)
    cells(o).each { |k| w[:cm][k] &= 0xf1 }
  end

  def self.mark(w, o)
    cells(o).each { |k| w[:cm][k] |= 0x0c } # the original ORs (d3 & 6) | 8 with d3 left over from a sprite call: $c in practice
  end
end

Scheduler::IMPL[0x0f] = ObjectStates
