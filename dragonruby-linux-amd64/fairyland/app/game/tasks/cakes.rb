# Task 11 ($6b0c): cakes falling. A cake ($f0) with nothing under it starts falling ($f1, counting up to $ff while it
# falls 2 px a frame); everything it lands on is crushed ($e0, carried down, then $e1). A cake that falls for 9+ frames, or
# that crushed something, breaks on landing: the wrapped enemy dies and the crush combo scores (3+ drops a bonus item).
# Ptolemy under a falling cake is crushed too (round-end code $80).
module CakeFallTask
  CAKE = 0xeb
  SND_CRUSHED = 0x28
  SND_CRUSH_ONE = 0x2f
  DROPS = :drop_codes # bonus item code by crush count (base + count)

  def self.run(w, t, gd)
    if t[:pc] == :start
      w[:combo] = 0
      Scheduler.spawn(w, 0x18) # score popups
      t[:pc] = :pass
      return 1
    end
    w[:obj].each { |o| step(w, gd, o) }
    1
  end

  def self.step(w, gd, o)
    st = o[Obj::ST]
    return if st < 0x93 || st == 0xe1
    i = World.cmi(o[Obj::X] + (o[Obj::FACE] == 0 ? 4 : 3), o[Obj::Y] - 1)
    ground = (World.cm(w, i) | World.cm(w, i + 1)) & 1 == 1
    if st >= 0xf1
      o[Obj::ST] = st + 1 unless st == 0xff
    elsif st != 0xe0
      return if ground
      o[Obj::TIMER] = 1 # crush count, the cake's own enemy included
      o[Obj::ST] = 0xf1
      Cake.unmark(w, o)
      return
    end
    st = o[Obj::ST]
    if ground
      return land(w, gd, o) if st >= 0xfa
      if st == 0xe0
        o[Obj::ST] = 0xe1
        o[Obj::ANIM] = 5
        w[:sounds] << SND_CRUSHED
        return
      end
      return land(w, gd, o) if o[Obj::TIMER] >= 2
      o[Obj::ST] = 0xf0 # a short drop: still a cake
      Cake.mark(w, o)
      return
    end
    Cake.unmark(w, o)
    o[Obj::Y] = (o[Obj::Y] - 2) & 0xff
    Cake.mark(w, o)
    Shadow.set_b(w, gd, st == 0xe0 ? o[Obj::TYPE] + 0x1c : CAKE, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
    return if st < 0xf1
    w[:obj].each do |a|
      next unless a[Obj::ST] == 0xf0 || (a[Obj::ST] >= 1 && a[Obj::ST] <= 0x10)
      next if ((o[Obj::Y] + 1 - a[Obj::Y]) & 0xff) >= 0x11
      next if (o[Obj::X] - a[Obj::X]).abs >= 0x10
      o[Obj::TIMER] = (o[Obj::TIMER] + 1) & 0xff
      a[Obj::ST] = 0xe0
      a[Obj::ANIM] = 0x50
      a[Obj::Y] = (o[Obj::Y] - 6) & 0xff
      Shadow.set_b(w, gd, a[Obj::TYPE] + 0x1c, a[Obj::Y], a[Obj::X], a[Obj::SLOT])
      Scheduler.kill(w, a[Obj::TASK])
    end
    crush_player(w, o)
  end

  # $6c90
  def self.crush_player(w, o)
    p = w[:player]
    return if (p[:x] - o[Obj::X]).abs >= 0x0c
    d = (p[:y] - o[Obj::Y]) & 0xff
    return if d < 0xf0 || d >= 0xfa
    return if w[:no_hit] || w[:mode626] != 0
    Scheduler.kill(w, 1)
    w[:end_code] = 0x80
    p[:y] = (o[Obj::Y] - 8) & 0xff
  end

  # $6d04: the cake breaks
  def self.land(w, gd, o)
    w[:obj].each do |a|
      next unless a[Obj::ST] == 0xe0
      a[Obj::ST] = 0xe1
      a[Obj::ANIM] = 5
    end
    Score.exp(w, 1)
    n = o[Obj::TIMER]
    w[:combo] = n
    Score.exp(w, ((n - 1) * 2) & 0xff)
    if n == 1
      Score.by_type(w, o, :score_cake_break)
      w[:sounds] << SND_CRUSH_ONE
      ItemDropTask.drop(w, o, 0x36, 0x49) if w[:bonus623] # $7d6c
    else
      Score.combo(w, o, 8)
      if w[:bonus623]
        ItemDropTask.drop(w, o, 0x40, 0x51) # $7d78
      elsif w[:combo] >= 3 # $7d34
        ItemDropTask.drop(w, o, 0x40, gd.byte(gd.a(DROPS) + w[:combo]))
        w[:combo] = 0
      end
    end
    o[Obj::ST] = 0x90
    o[Obj::ANIM] = 6
  end
end

# Task 17 ($7bf0): bonus items dropped by crush combos ($655: 8 x [timer, code, slot, y, x]). Hidden until the timer is
# below $32, animated every 6 frames, gone at 0. Picking one up scores its value times the pickup streak $67d.
module ItemDropTask
  VALUES = { 0x41 => :drop_value_41, 0x49 => :drop_value_49 } # [popup sprite, d4, d3]; anything else uses $c97a

  # $7d84 + caller: no free slot = no item
  def self.drop(w, o, timer, code)
    e = w[:drops].find { |d| d[0] == 0 }
    e&.replace([timer, code, o[Obj::SLOT], (o[Obj::Y] - 1) & 0xff, o[Obj::X]])
  end

  def self.run(w, t, gd)
    if t[:pc] == :start
      w[:drops].each { |d| d.fill(0) }
      t[:pc] = :loop
      return 1
    end
    p = w[:player]
    w[:drops].each do |d|
      next if d[0] == 0
      d[0] -= 1
      if d[0] == 0
        w[:game][:streak] = 0
        Shadow.clear(w, d[2])
        next
      end
      next if d[0] >= 0x32
      if (p[:y] - d[3]).abs < 0x0d && (p[:x] - d[4]).abs < 0x0b
        pick_up(w, gd, d)
      else
        Shadow.set_b(w, gd, (d[0] & 7) + d[1], d[3], d[4], d[2], :meta_poses)
      end
    end
    6
  end

  def self.pick_up(w, gd, d)
    w[:sounds] << 0x1d
    a = gd.a(VALUES[d[1]] || :drop_value_51)
    i = d[2] >> 2
    Shadow.single(w, i, gd.byte(a), 0xe0, (d[3] - 0xf2) & 0xff, d[4])
    n = w[:game][:streak] + 1
    w[:game][:streak] = n if n < 9
    Shadow.single(w, i + 1, 0x65 + n, 0xe0, (d[3] - 0xf2 - 4) & 0xff, d[4]) # the multiplier digit
    pop = w[:popups].find { |q| q[0] == 0 } # only to erase the two sprites after 5 popup ticks
    if pop
      pop[0] = 5
      pop[2] = d[2]
    end
    w[:game][:streak].times { Score.add(w, gd.byte(a + 2), gd.byte(a + 1)) } # the stored streak (it stops at 8)
    d[0] = 0
  end
end

Scheduler::IMPL[0x11] = CakeFallTask
Scheduler::IMPL[0x17] = ItemDropTask
