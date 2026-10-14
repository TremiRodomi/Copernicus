# Bonus items. Task 15 ($752c, arcade $47ce) is spawned by the director every 800 px walked: it picks one of 18 items from
# EXP bracket x random roll x enemies left, shows it at the round's item spot for 150 x 6 frames, and on pickup scores
# 1000 and runs the item's handler with the power-up timer $652 = item_timers[level] (ticks of 6 frames unless noted).
# Helpers: task 1d = Ptolemy's power-up glow, 1c = ice-block physics (Scroll of Ice), 19 = falling stars (Star Tiara).
module ItemTask
  # handler index (tier * 3 + enemy group) -> state
  HANDLERS = %i[silver silver moon_tiara staff staff fire_scroll orb orb glass holy gold star ring ice change life
                feather death].freeze
  SND_PICKUP = 0x27
  BGM = ->(w) { w[:round] - 1 < 0x31 ? 0x09 : 0x31 }

  def self.run(w, t, gd)
    g = w[:game]
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        t[:pc] = :check
        return 1
      when :check # $7534: not while the moon is out; the moon's countdown pauses while an item is on screen
        return 1 if g[:moon] == 0xf0
        Scheduler.suspend(w, 0x14)
        idx = pick(w, gd)
        return 1 unless idx # no enemies left: try again next frame
        t[:idx] = idx
        x, y = w[:item_spawn]
        Shadow.single(w, 0, gd.item_sprite(idx), 0xed, (y + 0x0e) & 0xff, x)
        t[:n] = 0x96
        t[:pc] = :shown
        return 6
      when :shown
        x, y = w[:item_spawn]
        if w[:t611] != 0
          t[:pc] = :expire
          next
        end
        if (p[:x] - x).abs < 0x0c && (p[:y] - y).abs < 8
          t[:pc] = :pickup
          next
        end
        t[:n] -= 1
        t[:pc] = :expire if t[:n] == 0
        return 6 unless t[:n] == 0
      when :expire # $760c
        Shadow.clear(w, 0)
        Scheduler.resume(w, 0x14)
        return :killed
      when :pickup # $7624
        Shadow.clear(w, 0)
        w[:power_timer] = gd.byte(gd.a(:item_timers) + g[:level])
        w[:sounds] << SND_PICKUP
        x, y = w[:item_spawn]
        Score.popup(w, 0, 6, 0x54, y, x)
        t[:pc] = HANDLERS[t[:idx]]

      # --- timed spell power-ups: the spell code reads $59b; task 1d makes Ptolemy glow
      when :silver # $765e Silver Scepter: faster spell wave
        w[:power] = 1
        Scheduler.spawn(w, 0x1d)
        t[:pc] = :tick
        return 6
      when :gold # $7686 Gold Scepter: the spell kills outright (multi-kill scoring)
        w[:kills5ff] = 0
        w[:power] = 2
        w[:flag654] = 2
        Scheduler.spawn(w, 0x1d)
        t[:pc] = :tick
        return 6
      when :fire_scroll # $76f2 Scroll of Fire
        w[:power] = 3
        Scheduler.spawn(w, 0x1d)
        t[:pc] = :tick
        return 6
      when :orb # $7a02 Mystical Orb: walking scores (task 00)
        w[:power] = 8
        Scheduler.spawn(w, 0x1d)
        t[:pc] = :tick
        return 6
      when :staff # $79d2 Magic Staff: enemies at half speed
        w[:power] = 7
        t[:speed] = w[:speed]
        w[:speed] = 1
        Scheduler.spawn(w, 0x1d)
        t[:pc] = :tick
        return 6
      when :tick # $766c
        w[:power_timer] = (w[:power_timer] - 1) & 0xff
        return 6 if w[:power_timer] != 0
        if t[:speed] # Magic Staff ($79f8): only puts the speed back
          w[:speed] = t[:speed]
        else
          w[:flag654] = 0
        end
        t[:pc] = :finish

      when :moon_tiara # $76a0: the moon comes out at the next tick
        g[:moon] = 1
        t[:pc] = :finish
      when :ring # $7828 Crystal Ring: +40 EXP
        Score.exp(w, 0x28)
        t[:pc] = :finish
      when :holy # $7834 Holy Water: one level up, to level 9
        g[:level] += 1 if g[:level] < 8
        t[:pc] = :finish
      when :life # $7a24 Book of Life
        g[:lives] = [g[:lives] + 1, 99].min unless g[:endless]
        w[:sounds] << 0x08
        t[:pc] = :finish

      when :star # $76ac Star Tiara: stars rain down (task 19) while the timer runs, then finish their fall
        w[:power] = 5
        w[:flag654] = 5
        w[:kills5ff] = 0
        Scheduler.spawn(w, 0x19)
        t[:pc] = :star_tick
        return 6
      when :star_tick
        w[:power_timer] = (w[:power_timer] - 1) & 0xff
        return 6 if w[:power_timer] != 0
        w[:power] = 0
        t[:pc] = :star_end
        return 0xf0
      when :star_end
        Scheduler.kill(w, 0x19)
        w[:flag654] = 0
        t[:pc] = :finish

      when :glass # $7966 Glass Potion: invincible ($626), Ptolemy turns to glass; blinks in the last 16 ticks
        w[:mode626] = 0x80
        w[:power] = 0x80
        w[:prio] = 2
        PalPatch.apply(w, gd, :glass)
        t[:pc] = :glass_tick
        return 6
      when :glass_tick
        w[:power_timer] = (w[:power_timer] - 1) & 0xff
        if w[:power_timer] == 0
          w[:mode626] = 0
          PalPatch.apply(w, gd, :glass_off)
          t[:pc] = :finish
          next
        end
        PalPatch.apply(w, gd, w[:power_timer].odd? ? :glass : :glass_off) if w[:power_timer] < 0x10
        return 6

      when :change # $7848 Change Potion: Ptolemy transforms and burns every enemy that comes close
        w[:sounds] << 0x0a
        w[:power] = 0x81
        w[:flag654] = 0x81
        w[:wizard_id] = 0
        w[:kills5ff] = 0
        Effects.sparkle(w, 0, p[:x], p[:y])
        t[:pc] = :change2
        return 0x0a
      when :change2
        w[:prio] = 2
        p[:char] = 0x38
        p[:speed] = 1
        p[:step_delay] = 1
        t[:k] = 0
        t[:pc] = :change_obj
      when :change_obj # one object per frame
        if t[:k] == 8
          w[:power_timer] = (w[:power_timer] - 1) & 0xff
          if w[:power_timer] == 0
            t[:pc] = :change_end
            next
          end
          p[:char] = w[:power_timer].odd? ? 0x38 : 0 if w[:power_timer] < 0x10
          t[:k] = 0
          next
        end
        o = w[:obj][t[:k]]
        st = o[Obj::ST]
        if st != 0 && st < 0x10 && (p[:x] - o[Obj::X]).abs < 0x0e && (p[:y] - o[Obj::Y]).abs < 0x0e
          w[:sounds] << 0x2e
          burn(w, o, 0x13)
        end
        t[:k] += 1
        return 1
      when :change_end
        w[:flag654] = 0
        p[:char] = 0
        p[:speed] = 2
        p[:step_delay] = 3
        w[:sounds] << BGM.call(w) if w[:enemies_left] & 0x7f != 0
        t[:pc] = :finish

      when :ice # $7706 Scroll of Ice: every enemy freezes into an ice block (task 1c moves them)
        w[:power] = 6
        w[:kills5ff] = 0
        Scheduler.spawn(w, 0x1c)
        t[:k] = 0
        t[:pc] = :freeze
      when :freeze
        if t[:k] == 8
          t[:pc] = :ice_tick
          return 6
        end
        o = w[:obj][t[:k]]
        if ((o[Obj::ST] - 1) & 0xff) >= 0x80
          t[:k] += 1
          return 1
        end
        Scheduler.kill(w, o[Obj::TASK])
        o[Obj::ST] = 9
        o[Obj::ANIM] = 0
        o[Obj::TIMER] = 0
        o[Obj::Y] &= 0xf8
        Effects.sparkle(w, 0, o[Obj::X], o[Obj::Y])
        t[:pc] = :freeze2
        return 5
      when :freeze2
        o = w[:obj][t[:k]]
        w[:sounds] << 0x18
        Shadow.set_b(w, gd, o[Obj::TYPE] + 0x1a, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        t[:k] += 1
        t[:pc] = :freeze
        return 1
      when :ice_tick # the ice blinks in the last 18 ticks
        w[:power_timer] = (w[:power_timer] - 1) & 0xff
        if w[:power_timer] == 0
          PalPatch.apply(w, gd, :normal)
          t[:k] = 0
          t[:pc] = :thaw
          next
        end
        PalPatch.apply(w, gd, w[:power_timer] & 2 != 0 ? :ice : :normal) if w[:power_timer] < 0x12
        return 6
      when :thaw
        if t[:k] == 8
          t[:pc] = :ice_end
          return 0x3c
        end
        o = w[:obj][t[:k]]
        unless o[Obj::ST] == 9
          t[:k] += 1
          return 1
        end
        o[Obj::ST] = 1
        o[Obj::TIMER] = 0
        Effects.sparkle(w, 0, o[Obj::X], o[Obj::Y])
        t[:pc] = :thaw2
        return 5
      when :thaw2
        Scheduler.spawn(w, w[:obj][t[:k]][Obj::TASK])
        t[:k] += 1
        t[:pc] = :thaw
        return 1
      when :ice_end
        Scheduler.kill(w, 0x1c)
        t[:pc] = :finish

      when :death # $7a3e Book of Death: the screen shakes, then every enemy burns and every cake dissolves
        w[:sounds] << 0x2d
        t[:n] = 8
        t[:pc] = :quake
      when :quake
        w[:shake] = 3
        t[:pc] = :quake2
        return 2
      when :quake2
        w[:shake] = 0
        t[:n] -= 1
        t[:pc] = t[:n] == 0 ? :death2 : :quake
        return 2
      when :death2
        w[:power] = 0x82
        (5..12).each { |id| Scheduler.kill(w, id) }
        w[:kills5ff] = 0
        t[:k] = 0
        t[:pc] = :death_obj
        return 1
      when :death_obj
        if t[:k] == 8
          t[:pc] = :finish
          next
        end
        o = w[:obj][t[:k]]
        st = o[Obj::ST]
        if st != 0 && st < 0x80
          Scheduler.kill(w, o[Obj::TASK])
          o[Obj::ST] = 0x91
          o[Obj::ANIM] = 0x40
          Score.exp(w, 1)
          Score.multi_kill(w, o, 0x13)
        elsif st >= 0xf0
          o[Obj::ST] = 0x90
          o[Obj::ANIM] = 6
          Score.exp(w, 1)
          Score.by_type(w, o, :score_cake_break)
        end
        t[:k] += 1
        return 5

      when :feather # $7af8 Mystical Feather: the round ends and the next ones are skipped (one per enemy left)
        w[:sounds] << 0x2c
        t[:pc] = :feather2
        return 0x14
      when :feather2
        NightWipe::FREEZE.each { |id| Scheduler.suspend(w, id) unless id == 0x15 } # $69ce (same list as $c87b)
        t[:pc] = :feather3
        return 0x28
      when :feather3
        w[:warp] = w[:round] - 1 >= 0x5b ? 0x80 : w[:enemies_left]
        w[:enemies_left] = 0
        w[:sounds] << 0x2b
        t[:pc] = :finish

      when :finish # $7b36
        Scheduler.resume(w, 0x14)
        w[:prio] = 1
        w[:power] = 0
        return :killed
      else
        raise "ItemTask: bad pc #{t[:pc]}"
      end
    end
  end

  # $7546: EXP bracket -> odds row; roll & $7f -> tier; enemies left - 1 -> group (1 / 2-4 / 5+)
  def self.pick(w, gd)
    f = w[:force_item] || (w[:opts] && w[:opts][:force_item]) # dev: --item_test / --item
    return f if f && (w[:enemies_left] & 0x7f) > 0
    n = (w[:enemies_left] & 0x7f) - 1
    exp = w[:game][:exp]
    b = 0
    b += 1 while exp >= gd.byte(gd.a(:item_brackets) + b)
    roll = (World.x68k?(w) ? World.rand(w) : World.r_reg(w)) & 0x7f # arcade: LD A,R; X68000: $58c
    tier = 0
    tier += 1 while roll >= gd.byte(gd.a(:item_odds) + 6 * b + tier)
    return nil if n < 0
    grp = 0
    grp += 1 while n >= gd.byte(gd.a(:item_groups) + grp)
    tier * 3 + grp
  end

  # burn an enemy (state $91) for 1 EXP and a power-up kill score
  def self.burn(w, o, timer)
    Scheduler.kill(w, o[Obj::TASK])
    o[Obj::ST] = 0x91
    o[Obj::ANIM] = 0x40
    Score.exp(w, 1)
    Score.multi_kill(w, o, timer)
  end
end

# Sprite palette patches ($28f6 lists [palette byte offset, colour]; arcade: $6290 queue writes [pen, hi, lo]).
# The patched colours live in w[:pal_patch] (sprite colour index -> X68000 colour word) for SpriteCache to apply.
module PalPatch
  def self.apply(w, gd, name)
    gd.pal_patch(name).each { |idx, word| w[:pal_patch][idx] = word }
  end
end

# Task 1d ($84ca, arcade $62d9): while a power-up timer runs, Ptolemy's outline cycles through the glow colours every 2 frames
module GlowTask
  def self.run(w, t, gd)
    if t[:pc] == :start
      t[:step] = 0
      t[:pc] = :glow
    end
    steps = gd.pal_patch(:glow)
    if w[:power_timer] == 0 && t[:step] > 0
      PalPatch.apply(w, gd, :normal)
      return :killed
    end
    t[:step] = 0 if t[:step] >= steps.size
    steps[t[:step]].each { |idx, word| w[:pal_patch][idx] = word }
    t[:step] += 1
    2
  end
end

# Task 19 ($7e5a, arcade $5512): four stars ([state, phase, y, x, slot] at $6a7) zig-zag down the screen along 8 paths
# (star_paths, [dy, dx] x 8 each), re-entering at a random x and path until the power-up ends; one enemy per frame is
# checked against them (16 px) and burns. Randomness: arcade LD A,R, X68000 $58c (much more regular showers).
module StarTask
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        w[:stars] = Array.new(4) { Array.new(5, 0) }
        t[:k] = 0
        t[:pc] = :init
        return 1
      when :init # $7e70: each star waits 1-128 frames at a random x
        s = w[:stars][t[:k]]
        s[0] = 2
        s[1] = (rnd(w) & 0x7f) + 1
        t[:pc] = :init_x
        return 1
      when :init_x
        w[:stars][t[:k]][3] = (rnd(w) * 2) & 0xff
        t[:pc] = :init_slot
        return 1
      when :init_slot
        w[:stars][t[:k]][4] = 0x74 + 4 * t[:k]
        t[:k] += 1
        if t[:k] < 4
          t[:pc] = :init
          next
        end
        w[:stars][3][4] = 0 # quirk: `move.b #0,-1(a2)` gives the last star sprite slot 0 (the item's)
        w[:sounds] << 0x21
        t[:o] = 0
        t[:pc] = :frame
        return 1
      when :frame
        w[:stars].each { |s| star(w, gd, s) }
        o = w[:obj][t[:o]]
        if ((o[Obj::ST] - 1) & 0xff) < 0x0f
          hit = w[:stars].find { |s| (s[3] - o[Obj::X]).abs < 0x10 && (s[2] - o[Obj::Y]).abs < 0x10 }
          ItemTask.burn(w, o, 0x13) if hit
        end
        t[:o] = (t[:o] + 1) % 8
        return 1
      else
        raise "StarTask: bad pc #{t[:pc]}"
      end
    end
  end

  def self.rnd(w)
    World.x68k?(w) ? World.rand(w) : World.r_reg(w)
  end

  def self.star(w, gd, s)
    return if s[0] & 1 != 0
    if s[0] & 2 != 0
      s[1] -= 1
      s[0] = rnd(w) & 0x70 if s[1] == 0
      return
    end
    a = gd.a(:star_paths) + s[0] + s[1]
    y = s[2] - gd.byte(a)
    s[2] = y & 0xff
    if y < 0 # off the bottom: re-enter, or stop once the power-up is over
      if w[:power] == 0
        w[:sounds] << 0x01
        s[0] = 1
      else
        s[3] = (s[3] + rnd(w) * 2) & 0xff
        s[0] = rnd(w) & 0x70
      end
    end
    dx = gd.byte(a + 1)
    s[3] = (s[3] + dx) & 0xff
    s[1] = (s[1] + 2) & 0x0f
    f = s[1] & 0x0c
    f ^= 0x0c if dx >= 0x80
    Shadow.set_b(w, gd, 0x6c + (f >> 2), s[2], s[3], s[4], :meta_poses)
  end
end

# Task 1c ($80c6, arcade $5f7a): ice blocks (state 9). Each frame, every block: falls 2 px when nothing holds it (crushing
# enemies and cakes below, shattering other ice, squashing Ptolemy), slides when Ptolemy walks into it (and keeps going
# until a wall, where it shatters), shatters after a long fall. Shattered blocks ($92) animate, then go to $e1.
module IceTask
  def self.run(w, t, gd)
    w[:obj].each { |o| block(w, gd, o) }
    1
  end

  def self.block(w, gd, o)
    case o[Obj::ST]
    when 0x92
      n = (o[Obj::ANIM] - 1) & 0xff
      if n == 0
        o[Obj::ST] = 0xe1
      else
        o[Obj::ANIM] = n
        Shadow.set_b(w, gd, 0xf0 + (n >> 2), o[Obj::Y], o[Obj::X], o[Obj::SLOT])
      end
    when 9
      ice(w, gd, o)
    end
  end

  def self.ice(w, gd, o)
    p = w[:player]
    i = World.cmi(o[Obj::X] + 4, o[Obj::Y] - 1) # $8110: always x + 4
    grounded = (World.cm(w, i) | World.cm(w, i + 1)) & 1 != 0
    if !grounded && !(o[Obj::ANIM] < 0x10 && on_ice?(w, o))
      fall(w, gd, o, p)
      return draw(w, gd, o)
    end
    if o[Obj::ANIM] != 0 # $82a8: landed
      landed(w, gd, o)
      return shatter(w, o) if o[Obj::ANIM] >= 0x10
      o[Obj::ANIM] = 0
    end
    push(w, gd, o, p)
  end

  def self.on_ice?(w, o)
    w[:obj].any? do |a|
      a[Obj::ST] == 9 && ((o[Obj::Y] - a[Obj::Y]) & 0xff) == 0x18 && (o[Obj::X] - a[Obj::X]).abs < 0x10
    end
  end

  def self.fall(w, gd, o, p)
    o[Obj::Y] = (o[Obj::Y] - 2) & 0xff
    o[Obj::ANIM] = (o[Obj::ANIM] + 1) & 0xff
    w[:combo] = 1 if o[Obj::ANIM] == 1
    w[:obj].each do |a|
      st = a[Obj::ST]
      next unless st == 0xf0 || st == 0x10 || (((st - 1) & 0xff) < 9 && a[Obj::TASK] != o[Obj::TASK])
      next unless ((o[Obj::Y] - 1 - a[Obj::Y]) & 0xff) < 0x11 && (o[Obj::X] - a[Obj::X]).abs < 0x10
      if st == 9
        a[Obj::ST] = 0x92
        a[Obj::ANIM] = 0x20
        Score.exp(w, 1)
        Score.multi_kill(w, a, 0x0a)
        w[:sounds] << 0x34
      else
        w[:combo] += 1
        a[Obj::ST] = 0xe0
        a[Obj::ANIM] = 0x50
        a[Obj::Y] = (o[Obj::Y] - 6) & 0xff
        Shadow.set_b(w, gd, a[Obj::TYPE] + 0x1c, a[Obj::Y], a[Obj::X], a[Obj::SLOT])
        Scheduler.kill(w, a[Obj::TASK])
      end
    end
    dy = (p[:y] - o[Obj::Y]) & 0xff
    return unless (p[:x] - o[Obj::X]).abs < 0x0c && dy >= 0xf0 && dy < 0xfa && !w[:no_hit]
    Scheduler.kill(w, 1)
    w[:end_code] = 0x80
    p[:y] = (o[Obj::Y] - 8) & 0xff
  end

  def self.landed(w, gd, o)
    o[Obj::TIMER] = 0
    w[:obj].each do |a|
      next unless a[Obj::ST] == 0xe0
      a[Obj::ST] = 0xe1
      a[Obj::ANIM] = 5
      w[:sounds] << 0x28
    end
    n = w[:combo]
    return w[:combo] = 0 if n < 2
    Score.exp(w, ((n - 1) * 2) & 0xff)
    k = EnemyAttack.free_obj(w) # the combo popup borrows a free object slot for its position
    if k
      tmp = w[:obj][k]
      tmp[Obj::Y] = o[Obj::Y]
      tmp[Obj::X] = o[Obj::X]
      tmp[Obj::SLOT] = 0x0c + 8 * k
      Score.combo(w, tmp, 8)
    end
    ItemDropTask.drop(w, o, 0x40, gd.byte(gd.a(:drop_codes) + w[:combo])) if w[:combo] >= 3 # $7d34
    w[:combo] = 0
  end

  # $8348: Ptolemy walking into the block pushes it 2 px (sound $33) and sets it sliding; blocks pushed into blocks chain
  def self.push(w, gd, o, p)
    if ((p[:y] - o[Obj::Y]) & 0xff) < 0x11 && p[:x] != o[Obj::X]
      d = (p[:x] - o[Obj::X]) & 0xff
      if d < 0x80 ? d < 0x0c : d >= 0xf5 # otherwise fall through to the chain check
        p[:alt_walk] = d
        return slide_start(w, gd, o, d < 0x80 ? -1 : 1)
      end
    end
    w[:obj].each do |a|
      st = a[Obj::ST]
      next unless st == 0xf0 || ((st - 1) & 0xff) < 9
      next unless a[Obj::Y] == o[Obj::Y]
      d = (a[Obj::X] - o[Obj::X]) & 0xff
      next if d == 0
      if d >= 0x80 ? d >= 0xf5 : d < 0x0c
        return slide_start(w, gd, o, d >= 0x80 ? 1 : -1) if st == 9
        o[Obj::TIMER] = 0
      end
    end
    slide(w, gd, o)
  end

  def self.slide_start(w, gd, o, dir)
    wx = dir > 0 ? o[Obj::X] + 0x10 : o[Obj::X] - 1
    return shatter(w, o) if World.solid?(w, wx, o[Obj::Y])
    o[Obj::X] = (o[Obj::X] + 2 * dir) & 0xff
    o[Obj::TIMER] = dir & 0xff
    w[:sounds] << 0x33
    slide(w, gd, o)
  end

  # $842e: keep sliding 1 px a frame in the TIMER direction; a wall shatters the block
  def self.slide(w, gd, o)
    d = o[Obj::TIMER]
    if d != 0
      nx = (o[Obj::X] + World.sbyte(d)) & 0xff
      return shatter(w, o) if World.solid?(w, d < 0x80 ? nx + 0x0f : nx, o[Obj::Y])
      o[Obj::X] = nx
    end
    draw(w, gd, o)
  end

  def self.draw(w, gd, o)
    Shadow.set_b(w, gd, o[Obj::TYPE] + 0x1a, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
  end

  def self.shatter(w, o) # $84a8
    o[Obj::ST] = 0x92
    o[Obj::ANIM] = 0x20
    Score.exp(w, 1)
    Score.multi_kill(w, o, 0x0a)
    w[:sounds] << 0x34
  end
end

Scheduler::IMPL[0x15] = ItemTask
Scheduler::IMPL[0x1d] = GlowTask
Scheduler::IMPL[0x19] = StarTask
Scheduler::IMPL[0x1c] = IceTask
