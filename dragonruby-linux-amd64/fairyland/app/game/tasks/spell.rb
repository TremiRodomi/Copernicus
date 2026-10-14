# Task 03 ($49d0): Ptolemy's spell. Press to cast; holding the button recasts every 61 frames ($597 counts down only while
# the button is held; task 0e zeroes it on release, so tapping casts at once). The spell is a short wave that moves 1 px a
# frame (3 with the Silver Scepter, $59b = 1) and stops at a wall two cells high, at the end of its table, or on a hit.
# With $59b = 3 it is the fire spell instead: a looping flame that flies until a wall or the screen edge.
module SpellTask
  WAVE_L = :spell_wave_l # facing left (+x): [sprite, x offset] pairs, 0-terminated; +$39 = the shrunk version
  WAVE_R = :spell_wave_r
  FIRE_L = :fire_spell_l # [sprite, dx] pairs, looping
  FIRE_R = :fire_spell_r
  SND_SPELL = 0x17
  SND_FIRE = 0x1e
  SLOT = 0x7c

  def self.run(w, t, gd)
    p = w[:player]
    sh = w[:shot]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        w[:spell_delay] = 0
        t[:pc] = :check
        return 1
      when :check # $49e2
        return 1 if World.input(w) & 1 != 0
        if w[:spell_delay] != 0
          w[:spell_delay] -= 1
          return 1
        end
        w[:spell_delay] = 0x3c
        t[:left] = p[:facing] == 0
        if w[:power] == 3
          w[:sounds] << SND_FIRE
          sh[:x] = (p[:x] + (t[:left] ? 0x0e : -0x0e)) & 0xff
          sh[:y] = (p[:y] + 2) & 0xff
          t[:table] = gd.a(t[:left] ? FIRE_L : FIRE_R)
          t[:k] = 0
          t[:pc] = :fire_first
          return 1
        end
        w[:sounds] << SND_SPELL
        fast = w[:power] == 1
        sh[:x] = (p[:x] + (t[:left] ? 0x0a : -0x0a)) & 0xff
        sh[:y] = p[:y]
        sh[:step] = t[:left] ? (fast ? 3 : 1) : (fast ? -3 : -1)
        t[:table] = gd.a(t[:left] ? WAVE_L : WAVE_R) + (p[:char] == 0x1c ? 0x39 : 0)
        t[:k] = 0
        p[:cast] = 0x0c
        sh[:active] = 0xff
        t[:pc] = :wave_first
        return 1
      when :wave_first # $4a80
        return finish(w, t) if wall?(w, sh[:x] + (t[:left] ? 0 : 3) + 6, sh[:y])
        t[:pc] = :wave_draw
        return 1
      when :wave_draw # $4aa4
        idx = gd.byte(t[:table] + t[:k])
        x = sh[:x] + gd.sbyte(t[:table] + t[:k] + 1)
        t[:k] += 2
        Shadow.set_a(w, gd, idx, sh[:y], x & 0xff)
        t[:pc] = :wave_move
        return 1
      when :wave_move # $4ac0
        sh[:x] = (sh[:x] + sh[:step]) & 0xff
        return finish(w, t) if sh[:active] & gd.byte(t[:table] + t[:k]) == 0 # table end, or a hit set it to $80
        return finish(w, t) if wall?(w, sh[:x] + 8, sh[:y])
        t[:pc] = :wave_draw
      when :fire_first # $4b3e
        return finish(w, t) if wall?(w, sh[:x] + 6, sh[:y])
        w[:kills5ff] = 0
        p[:cast] = 0x0c
        sh[:active] = 0xff
        t[:pc] = :fire_draw
        return 1
      when :fire_draw # $4b6c
        idx = gd.byte(t[:table] + t[:k])
        if idx == 0
          t[:k] = 0
          next
        end
        t[:k] += 1
        Shadow.set_a(w, gd, idx, sh[:y], sh[:x])
        t[:pc] = :fire_move
        return 1
      when :fire_move # $4ba0
        d = gd.sbyte(t[:table] + t[:k])
        t[:k] += 1
        nx = sh[:x] + d
        if d < 0
          return finish(w, t) if nx < 0
          sh[:x] = nx
          probe = nx + 7
        else
          return finish(w, t) if nx >= 0xf0
          sh[:x] = nx
          probe = nx + 8
        end
        return finish(w, t) if wall?(w, probe, sh[:y])
        t[:pc] = :fire_draw
      end
    end
  end

  # blocked only where the cell and the one above it are both solid
  def self.wall?(w, x, y)
    i = World.cmi(x & 0xff, y)
    World.cm(w, i) & World.cm(w, i + 0x20) & 1 == 1
  end

  def self.finish(w, t) # $4af2
    Shadow.clear(w, SLOT)
    w[:shot][:active] = 0
    t[:pc] = :check
    1
  end
end

Scheduler::IMPL[0x03] = SpellTask
