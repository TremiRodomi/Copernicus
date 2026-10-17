# Enemies: object slots, the shared enemy body (tasks 05-0c), the AI (task 04) and the object-state manager (task 0f).
# Object slot = 12 bytes ($59d + 12k), kept as an Array of 12 integers so every `$n(a1)` in the original ports 1:1:
#   0 state (0 empty, 1 walking, 2 falling, 5 jumping, 6/7 attacking, 8/9 special, $10 dying, $20 appearing, $30 escaping, $80+ spell states)
#   1 anim / counter   2 type ($00 Orc $1d Salamander $3a Golem $57 Wraith $74 Cleric $91 Wizard)   3 task id (5..12)
#   4 facing (0 = +x, 9 = -x)   5 jump dx (1 / $ff / 0)   6 x   7 y
#   8 command bits from the AI: 0 jump, 1 attack, 2 move +x, 3 move -x, 4 bumped, 5 (Cleric spawn), 6 follow trail, 7 chase
#   9 sprite shadow slot   10 trail index   11 AI timer / distance
module Obj
  ST, ANIM, TYPE, TASK, FACE, JDX, X, Y, CMD, SLOT, TRAIL, TIMER = (0..11).to_a

  # $253e: fill the slots from the round's enemy table ($cf1e); returns the speed byte ($5fe)
  def self.load(w, rb)
    load_list(w, rb.enemies)
  end

  def self.load_list(w, enemies)
    w[:obj] = Array.new(8) { Array.new(12, 0) }
    w[:enemies_left] = 0
    id = 5
    slot = 0x0c
    enemies.each_with_index do |(t, x, y), k|
      if t == 0xff # $2594: the Worm's door (drawn by the round builder); always listed last
        w[:door] = [x, y]
        Scheduler.spawn(w, 0x26)
        next
      end
      o = w[:obj][k]
      o[TYPE] = t
      o[TASK] = id
      o[X] = x
      o[Y] = y
      o[SLOT] = slot
      o[ST] = 0x20
      w[:wizard_id] = id if w[:wizard_id] != 0 && t == 0x91 # still shrunk: the round's LAST Wizard holds the spell
      id += 1
      slot += 8
      w[:enemies_left] += 1
    end
  end

  def self.for_task(w, id)
    w[:obj][id - 5]
  end

  # $47fe-style "something solid under the feet" test used by enemies (no top-surface check)
  def self.ground?(w, o, x, y)
    i = World.cmi(x + (o[FACE] == 0 ? 4 : 3), y - 1)
    (World.cm(w, i) | World.cm(w, i + 1)) & 1 == 1
  end
end

# Tasks 05..0c: the shared enemy body ($55b4). Obeys the AI's command bits; every frame it acts waits for the speed divider $600.
module EnemyBody
  WALK = :enemy_walk
  SLIDE_L = :enemy_slide_l
  SLIDE_R = :enemy_slide_r
  JUMP_L = :enemy_jump_l
  JUMP_R = :enemy_jump_r

  def self.run(w, t, gd)
    o = Obj.for_task(w, t[:id])
    return 1 if w[:opts] && w[:opts][:freeze] && w[:opts][:freeze].include?(o[Obj::TYPE]) # dev: --freeze 00,1d
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $55b4
        o[Obj::ANIM] = 0
        t[:pc] = :reset
      when :reset # $55ba
        o[Obj::ST] = 1
        o[Obj::CMD] &= ~0x10
        t[:pc] = :main
      when :main # $55c6
        unless Obj.ground?(w, o, o[Obj::X], o[Obj::Y])
          t[:pc] = :fall
          next
        end
        cmd = o[Obj::CMD] # d2: the original keeps this copy and uses it for the rest of the step
        t[:cmd] = cmd
        if cmd & 1 != 0
          t[:pc] = :jump
          next
        end
        if o[Obj::TYPE] == 0x57 ? wraith_dodge?(w, o) && w[:flag654] == 0 : (cmd & 2 != 0)
          o[Obj::CMD] &= ~2 unless o[Obj::TYPE] == 0x57
          t[:pc] = o[Obj::TYPE] == 0x57 ? :vanish : :attack
          next
        end
        walk(w, o, cmd) # $566a
        r = after_walk(t, o)
        return r if r
      when :walk_draw # $5768
        f = t[:frame] || gd.byte(gd.a(WALK) + o[Obj::ANIM])
        Shadow.set_b(w, gd, f + o[Obj::FACE] + o[Obj::TYPE], o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        return wait_div(t, 3, :main)
      when :wait # speed-divider wait: yield 1 frame at a time until $600 != 0, `:wait_n` times
        if w[:div600] == 0
          return 1
        end
        t[:wait_n] -= 1
        return 1 if t[:wait_n] > 0
        t[:pc] = t[:then]
      when :fall # $57b8
        o[Obj::ST] = 2
        t[:a] = gd.a(o[Obj::FACE] == 0 ? SLIDE_L : SLIDE_R)
        t[:y] = o[Obj::Y]
        t[:x] = o[Obj::X]
        return wait_div(t, 1, o[Obj::CMD] & 0x10 != 0 ? :fall_store : :fall_slide)
      when :fall_slide # $57f0
        dx = gd.byte(t[:a])
        if dx == 0
          return wait_div(t, 1, :fall_store)
        end
        t[:x] = (t[:x] + dx) & 0xff if t[:x] & 7 != 0
        t[:y] = (t[:y] + gd.byte(t[:a] + 1)) & 0xff
        Shadow.set_b(w, gd, gd.byte(t[:a] + 2) + o[Obj::TYPE], t[:y], t[:x], o[Obj::SLOT])
        t[:a] += 3
        return wait_div(t, 1, :fall_slide)
      when :fall_store # $5824
        o[Obj::Y] = t[:y]
        o[Obj::X] = t[:x]
        if Obj.ground?(w, o, t[:x], t[:y])
          t[:pc] = :land
          return 6
        end
        t[:y] = o[Obj::Y] = (o[Obj::Y] - 2) & 0xff
        t[:x] = o[Obj::X]
        Shadow.set_b(w, gd, o[Obj::TYPE] + 0x1b, t[:y], t[:x], o[Obj::SLOT])
        return wait_div(t, 1, :fall_store)
      when :land # $5872
        x = o[Obj::X]
        o[Obj::X] = (x + (o[Obj::FACE] == 0 ? 1 : -1)) & 0xff if x.odd?
        t[:pc] = :start
      when :jump # $5898
        o[Obj::CMD] &= ~1
        cmd = t[:cmd]
        if o[Obj::TYPE] == 0x1d && salamander_backoff?(w, o)
          walk(w, o, cmd)
          r = after_walk(t, o)
          return r if r
          next
        end
        o[Obj::ST] = 5
        o[Obj::TIMER] = [o[Obj::TIMER] - 0x20, 0].max
        o[Obj::ANIM] = 0x11
        if cmd & 4 != 0
          o[Obj::FACE] = 0
          o[Obj::JDX] = 1
        elsif cmd & 8 != 0
          o[Obj::FACE] = 9
          o[Obj::JDX] = 0xff
        else
          o[Obj::JDX] = 0
        end
        t[:a] = gd.a(o[Obj::FACE] == 0 ? JUMP_L : JUMP_R)
        t[:crouch] = 8
        t[:pc] = :crouch
      when :crouch # $5958: 8 crouch frames, each 2 speed frames; falls if the ground vanishes
        Shadow.set_b(w, gd, gd.byte(t[:a]) + o[Obj::TYPE] + 2, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        unless Obj.ground?(w, o, o[Obj::X], o[Obj::Y])
          t[:y] = o[Obj::Y]
          t[:x] = o[Obj::X]
          return wait_div(t, 1, :fall_store)
        end
        t[:crouch] -= 1
        return wait_div(t, 2, t[:crouch] > 0 ? :crouch : :jump_wait)
      when :jump_wait
        return wait_div(t, 1, :jump_body)
      when :jump_body # $59d0
        r = jump_step(w, gd, t, o)
        return r if r
      when :vanish # $5f64: a Wraith dodges the spell: flicker out (10 x draw/clear), 20 frames gone, flicker back
        w[:sounds] << 0x1b
        o[Obj::ST] = 8 # untouchable: task 0f skips state 8
        o[Obj::TIMER] = 8
        t[:n] = 20
        t[:pc] = :vanish_out
      when :vanish_out
        t[:n] -= 1
        if t[:n] < 0
          t[:n] = 20
          t[:pc] = :vanish_in
          return 0x14
        end
        t[:n].odd? ? Shadow.set_b(w, gd, o[Obj::FACE] + 0x57, o[Obj::Y], o[Obj::X], o[Obj::SLOT]) : hide(w, o)
        return 1
      when :vanish_in
        t[:n] -= 1
        if t[:n] < 0
          t[:pc] = :reset
          next
        end
        t[:n].odd? ? hide(w, o) : Shadow.set_b(w, gd, o[Obj::FACE] + 0x57, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        return 1
      else
        raise "EnemyBody: bad pc #{t[:pc]}" unless EnemyAttack::LABELS.include?(t[:pc])
        r = EnemyAttack.step(w, t, gd, o) # Wizard / Salamander / Cleric attacks (tasks/attacks.rb)
        return r if r
      end
    end
  end

  # $5724: after a walk step - a bumped enemy shows frame 8; an enemy back from an attack pose (state 6) waits a frame
  def self.after_walk(t, o)
    if o[Obj::CMD] & 0x10 != 0
      o[Obj::CMD] &= ~0x10
      t[:frame] = 8
      return wait_div(t, 1, :walk_draw)
    end
    t[:frame] = nil
    if o[Obj::ST] == 6
      o[Obj::ST] = 1
      return wait_div(t, 1, :walk_draw)
    end
    t[:pc] = :walk_draw
    nil
  end

  # Yield 1 frame, then keep yielding while the speed divider is 0, n times; then continue at `label`.
  def self.wait_div(t, n, label)
    t[:wait_n] = n
    t[:then] = label
    t[:pc] = :wait
    1
  end

  # $566a: walk 2 px per the command bits, carrying Ptolemy if she rides this enemy
  def self.walk(w, o, cmd)
    o[Obj::TIMER] = [o[Obj::TIMER] - 2, 0].max
    p = w[:player]
    if cmd & 4 != 0
      o[Obj::FACE] = 0
      unless World.solid?(w, o[Obj::X] + 16, o[Obj::Y])
        o[Obj::X] = (o[Obj::X] + 2) & 0xff
        p[:x] = (p[:x] + 2) & 0xff if p[:riding] == o[Obj::TASK] && !World.solid?(w, p[:x] + 16, p[:y])
      end
    elsif cmd & 8 != 0
      o[Obj::FACE] = 9
      unless World.solid?(w, o[Obj::X] - 1, o[Obj::Y])
        o[Obj::X] = (o[Obj::X] - 2) & 0xff
        p[:x] = (p[:x] - 2) & 0xff if p[:riding] == o[Obj::TASK] && !World.solid?(w, p[:x] - 1, p[:y])
      end
    else
      return
    end
    o[Obj::ANIM] = (o[Obj::ANIM] + 1) >= 8 ? 0 : o[Obj::ANIM] + 1 # $5712 (also when blocked)
  end

  # $5600: a Wraith vanishes when Ptolemy's spell comes close (shot y within -16..+23, approaching from the side she faces)
  def self.hide(w, o)
    Shadow.clear(w, o[Obj::SLOT])
    Shadow.clear(w, o[Obj::SLOT] + 4)
  end

  def self.wraith_dodge?(w, o)
    return false if w[:shot][:active] == 0
    dy = (w[:shot][:y] - o[Obj::Y]) & 0xff
    return false unless dy < 0x18 || dy >= 0xf0
    d1 = (w[:shot][:x] - o[Obj::X]) & 0xff
    o[Obj::CMD] = w[:shot][:x] >= o[Obj::X] ? 8 : 4
    o[Obj::TIMER] = 0x20
    w[:player][:facing] != 0 ? d1 < 0x28 : d1 >= 0xd8
  end

  # $58a2: a Salamander with Ptolemy just above it steps away instead of jumping
  def self.salamander_backoff?(w, o)
    p = w[:player]
    return false unless ((p[:y] - o[Obj::Y]) & 0xff) < 0x28
    dx = (p[:x] - o[Obj::X]) & 0xff
    if p[:x] < o[Obj::X]
      return false unless dx >= 0xe8
      o[Obj::CMD] = (o[Obj::CMD] & ~8) | 4
    else
      return false unless dx < 0x18
      o[Obj::CMD] = (o[Obj::CMD] & ~4) | 8
    end
    o[Obj::TIMER] = 0x20
    true
  end

  # $59d0: one frame of an enemy jump (same table format and tests as Ptolemy's)
  def self.jump_step(w, gd, t, o)
    y = o[Obj::Y]
    x = o[Obj::X]
    d3 = (o[Obj::ANIM] - 1) & 0xff
    o[Obj::ANIM] = d3
    f = gd.byte(t[:a])
    if f == 0
      t[:y] = y
      t[:x] = x
      t[:pc] = :fall_store
      return nil
    end
    t[:a] += 1
    early = World.sbyte(d3 + 1) >= 0
    if !early
      if o[Obj::JDX] != 0 && World.solid?(w, World.sbyte(o[Obj::JDX]) >= 0 ? x + 16 : x - 1, y - 1)
        o[Obj::JDX] = 0
      end
    elsif o[Obj::JDX] == 0
      if y & 7 == 0
        cmd = o[Obj::CMD]
        step = nil
        if cmd & 4 != 0
          step = 2
          o[Obj::FACE] = 0
          wx = x + 16
        elsif cmd & 8 != 0
          step = 0xfe
          o[Obj::FACE] = 9
          wx = x - 1
        end
        if step
          i = World.cmi(wx, y)
          if World.cm(w, i) & 1 == 0 && World.cm(w, i - 0x20) & 1 == 1
            o[Obj::X] = (x + step) & 0xff
            o[Obj::Y] = y
            t[:pc] = :start
            return nil
          end
        end
      end
    else
      wx = World.sbyte(o[Obj::JDX]) >= 0 ? x + 16 : x - 1
      wy = gd.byte(t[:a]) >= 4 ? y + 8 : y - 8
      i = World.cmi(wx, wy)
      o[Obj::JDX] = 0 if (World.cm(w, i) & World.cm(w, i + 0x20) & 1) == 1
    end
    dy = gd.byte(t[:a])
    if dy >= 0x80 && y & 7 == 0
      i = World.cmi(x + (o[Obj::FACE] == 0 ? 4 : 3), y)
      here = ~(World.cm(w, i) | World.cm(w, i + 1))
      below = World.cm(w, i - 0x1f) | World.cm(w, i - 0x20)
      if (below & here & 1) == 1
        t[:pc] = :start
        return nil
      end
    end
    t[:a] += 1
    if dy == 0xf7
      y = (y - 2) & 0xff
    else
      y = (y + dy) & 0xff
      x = (x + o[Obj::JDX]) & 0xff
    end
    o[Obj::Y] = y
    o[Obj::X] = x
    Shadow.set_b(w, gd, f + o[Obj::TYPE], y, x, o[Obj::SLOT])
    wait_div(t, 1, :jump_body)
  end
end

(5..12).each { |id| Scheduler::IMPL[id] = EnemyBody }

# Task 04: enemy AI ($4bde). Each pass looks at one object per frame and sets its command bits; after 8 objects it runs the
# round timer ($60f/$610: hurry-up speed at 65, Horned at 70; the last enemy escapes if Horned's time runs out).
# Methods are named after the original labels so they can be checked against the disassembly.
module EnemyAI
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $4bde
        t[:pc] = :init
        return 1
      when :init
        Scheduler.spawn(w, 0x0f)
        w[:t60f] = 6
        w[:t610] = (w[:opts] && w[:opts][:hurry]) || 1 # dev: --hurry N starts the round timer at N ($46 = Horned)
        w[:t611] = 0
        w[:div600] = w[:speed]
        t[:pc] = :scan
        return 1
      when :scan # $4c0e: target beside the first cake (state $f0), if any
        cake = w[:obj].find { |o| o[Obj::ST] == 0xf0 }
        if cake
          w[:cake_x] = (cake[Obj::X] + (w[:player][:facing] != 0 ? -0x18 : 0x18)) & 0xff
          w[:cake_y] = cake[Obj::Y]
        else
          w[:cake_y] = 0
        end
        t[:k] = 0
        t[:pc] = :obj
      when :obj # $4c50: one object, then yield a frame
        decide(w, w[:obj][t[:k]])
        t[:k] += 1
        t[:pc] = t[:k] < 8 ? :obj : :timers
        return 1
      when :timers # $4e0c
        return :killed if timers(w) == :killed
        t[:pc] = :scan
      else
        raise "EnemyAI: bad pc #{t[:pc]}"
      end
    end
  end

  def self.timers(w)
    w[:t60f] -= 1
    return if w[:t60f] != 0
    w[:t60f] = 6
    if w[:enemies_left] == 1
      w[:enemies_left] |= 0x80
      w[:t610] = w[:wizard_id] != 0 ? 0x40 : 0x32
      return
    end
    w[:t610] = (w[:t610] + 1) & 0xff
    if w[:t610] < 0x46
      w[:speed] = 0xff if w[:t610] >= 0x41 # hurry up
      return
    end
    if w[:enemies_left] & 0x80 == 0
      if w[:t611] == 0
        w[:t611] = 0xff
        Scheduler.spawn(w, 0x24) # Horned (tasks/horned.rb)
      end
      return
    end
    w[:timer_end] ||= w[:t610] # (port: the HORNED TIMER widget stops here)
    w[:obj].each do |o| # $4e7c: time is up with one enemy left: it escapes
      st = o[Obj::ST]
      next if st == 0 || (st >= 0x80 && st != 0xf0) || st == 0x30
      Scheduler.kill(w, o[Obj::TASK])
      o[Obj::ST] = 0x30
      o[Obj::ANIM] = 0x20
      w[:sounds] << 0x25
    end
    :killed
  end

  # ---- helpers ----
  def self.adx(a, b)
    (a - b).abs
  end

  def self.cm(w, i)
    World.cm(w, i)
  end

  # $5540: from cell i, up to 3 rows upward: a solid cell (either of 2 columns) with free space above. Returns [carry, i].
  def self.s5540(w, i)
    3.times do
      d0 = cm(w, i) | cm(w, i + 1)
      i += 0x20
      return [false, i] if d0 & 1 == 1 && (cm(w, i) | cm(w, i + 1)) & 1 == 0
    end
    [true, i]
  end

  # $5566: same, single column
  def self.s5566(w, i)
    3.times do
      d0 = cm(w, i)
      i += 0x20
      return false if d0 & 1 == 1 && cm(w, i) & 1 == 0
    end
    true
  end

  def self.col(i)
    i & 0x1f
  end

  # ---- $4c50 decision tree ----
  def self.decide(w, o)
    return unless o[Obj::ST] == 1 && o[Obj::CMD] & 1 == 0
    d1 = o[Obj::CMD]
    p = w[:player]
    px = p[:x]
    py = p[:y]
    ox = o[Obj::X]
    oy = o[Obj::Y]
    if w[:mode626] == 0
      case o[Obj::TYPE]
      when 0x1d # Salamander: breathe fire when level with Ptolemy, 16..49 px away
        dx = adx(px, ox)
        return attack(o) if adx(py, oy) < 9 && dx < 0x32 && dx >= 0x10
      when 0x91 # Wizard: cast when level and within 48 px in front
        if adx(py, oy) < 9
          d0 = (px - ox) & 0xff
          return attack(o) if o[Obj::FACE] == 0 ? d0 < 0x31 : d0 >= 0xd0
        end
      when 0x74 # Cleric: summon on a timer
        if w[:t60f] == 2 && w[:t610] & 0x0f == 0
          w[:t60f] -= 1
          o[Obj::CMD] |= 2
          return
        end
      when 0x3a # Golem
        return l515a(w, o) if o[Obj::TIMER] != 0
        return l4d66(w, o) if w[:cake_y] != 0
        o[Obj::CMD] |= 0x80
        return l527c(w, o, d1)
      end
    end
    return l527c(w, o, d1) if d1 & 0x80 != 0
    l4d48(w, o)
  end

  def self.attack(o)
    o[Obj::CMD] = (o[Obj::CMD] & 0x3e) | 2
  end

  def self.l4d48(w, o)
    return l515a(w, o) if o[Obj::TIMER] != 0
    return l4d66(w, o) if w[:cake_y] != 0 && o[Obj::TYPE] != 0x57 && o[Obj::TYPE] != 0x1d
    p = w[:player]
    if w[:mode626] != 0 # $4d86
      dy = (p[:y] - o[Obj::Y]) & 0xff
      return l4dc8(w, o) if p[:y] >= o[Obj::Y] && dy >= 0x40
      o[Obj::CMD] = p[:x] < o[Obj::X] ? 8 : 4
      o[Obj::TIMER] = 0x32
      return
    end
    l4dbc(w, o, p[:y])
  end

  def self.l4d66(w, o)
    return l521e(w, o, w[:cake_x]) if adx(w[:cake_x], o[Obj::X]) >= 0x10
    l4dbc(w, o, w[:cake_y])
  end

  def self.l4dbc(w, o, ty)
    return l5036(w, o, o[Obj::Y] - ty) if o[Obj::Y] >= ty
    l4dc8(w, o)
  end

  # target is above: jump up if there is a reachable platform, else look sideways for one
  def self.l4dc8(w, o)
    i = World.cmi(o[Obj::X] + (o[Obj::FACE] == 0 ? 4 : 3), o[Obj::Y] + 8)
    carry, = s5540(w, i)
    return l4ec4(w, o) if carry
    o[Obj::CMD] = (o[Obj::CMD] & 0xf3) | 1
  end

  def self.l4ec4(w, o)
    y1 = o[Obj::Y] + 8
    if w[:player][:x] >= o[Obj::X]
      i = World.cmi(o[Obj::X] + 0x20, y1)
      carry, = s5540(w, i)
      return o[Obj::CMD] = (o[Obj::CMD] & 0xf7) | 5 unless carry
      return l4f44(w, o, i) if o[Obj::TYPE] != 0
      carry, = s5540(w, i - 7)
      return o[Obj::CMD] = (o[Obj::CMD] & 0xfb) | 9 unless carry
      l4f44(w, o, i)
    else
      i = World.cmi(o[Obj::X] - 0x18, y1)
      carry, = s5540(w, i)
      return o[Obj::CMD] = (o[Obj::CMD] & 0xfb) | 9 unless carry
      return l4f9c(w, o, i) if o[Obj::TYPE] != 0
      carry, = s5540(w, i + 7)
      return o[Obj::CMD] = (o[Obj::CMD] & 0xf7) | 5 unless carry
      l4f9c(w, o, i)
    end
  end

  def self.l4f44(w, o, i)
    loop do
      i = step_cell(w, i, 1) # arcade $2927 inc l
      return l4ff8(w, o, i) if col(i) == 0
      next if s5566(w, i)
      d0 = (((col(i) << 3) & 0xff) - o[Obj::X]) & 0xff
      d0 -= 0x10
      o[Obj::TIMER] = d0 < 0 ? 1 : d0
      return l5224(w, o)
    end
  end

  def self.l4f7c(w, o, i)
    d0 = (col(i) << 3) & 0xff
    o[Obj::TIMER] = d0 - o[Obj::X] if d0 >= o[Obj::X]
    l5224(w, o)
  end

  def self.l4f9c(w, o, i)
    loop do
      i = step_cell(w, i, -1) # arcade $295f dec l
      return l5016(w, o, i) if col(i) == 0
      next if s5566(w, i)
      # VERSION DIFFERENCE (MAME-verified): the arcade ($296c `ld a,l / dec a`) measures to the column BEFORE the one
      # found - 8 px further; the X68000 ($4fba) to the column itself
      c = World.x68k?(w) ? col(i) : col(i - 1)
      d0 = (o[Obj::X] - ((c << 3) & 0xff)) & 0xff
      d0 -= 0x10
      o[Obj::TIMER] = d0 < 0 ? 1 : d0
      return l5232(w, o)
    end
  end

  def self.l4fd4(w, o, i)
    d6 = (col(i - 1) << 3) & 0xff
    o[Obj::TIMER] = o[Obj::X] - d6 if o[Obj::X] >= d6
    l5232(w, o)
  end

  def self.l4ff8(w, o, i)
    loop do
      i = step_cell(w, i, -1) # arcade $2999 dec l
      return l521a(w, o) if col(i) == 0
      return l4fd4(w, o, i) unless s5566(w, i)
    end
  end

  def self.l5016(w, o, i)
    loop do
      i = step_cell(w, i, 1) # arcade $29a9 inc l
      return l521a(w, o) if col(i) == 0
      return l4f7c(w, o, i) unless s5566(w, i)
    end
  end

  # target at or below: walk toward it on the same row, or find a gap to drop through
  def self.l5036(w, o, d)
    p = w[:player]
    return l5090(w, o) if d >= 8
    if o[Obj::TYPE] == 0x74 && o[Obj::CMD] & 0x20 == 0
      o[Obj::TIMER] = 0x40
      return p[:x] >= o[Obj::X] ? l5232(w, o) : l5224(w, o)
    end
    if p[:x] < o[Obj::X]
      d0 = o[Obj::X] - p[:x] - 0x20
      o[Obj::TIMER] = d0 < 0 ? 8 : d0
      l5232(w, o)
    else
      d0 = p[:x] - o[Obj::X] - 0x20
      o[Obj::TIMER] = d0 < 0 ? 8 : d0
      l5224(w, o)
    end
  end

  def self.l5090(w, o)
    y1 = o[Obj::Y] - 8
    if w[:player][:x] >= o[Obj::X]
      start = i = World.cmi(o[Obj::X] + 0x10, y1)
      loop do
        return l4f7c(w, o, i) if cm(w, i) & 1 == 0
        i += 1
        break if col(i) == 0
      end
      i = start - 1
      loop do
        return l4fd4(w, o, i) if cm(w, i) & 1 == 0
        i -= 1
        break if col(i) == 0
      end
      o[Obj::CMD] = (o[Obj::CMD] & ~8) | 4
      l51ec(w, o, World.cmi(o[Obj::X] + 16, o[Obj::Y]))
    else
      start = i = World.cmi(o[Obj::X] - 8, y1)
      loop do
        return l4fd4(w, o, i) if cm(w, i) & 1 == 0
        i -= 1
        break if col(i) == 0
      end
      i = start + 2
      loop do
        return l4f7c(w, o, i) if o[Obj::ST] & 1 == 0 # original tests (a1) - the object's state - not the cell (quirk kept)
        i += 1
        break if col(i) == 0
      end
      o[Obj::CMD] = (o[Obj::CMD] & ~4) | 8
      l51ec(w, o, World.cmi(o[Obj::X] - 8, o[Obj::Y]))
    end
  end

  # AI timer running: keep walking; jump if a platform appears within reach ahead
  def self.l515a(w, o)
    step = o[Obj::CMD] & 4 != 0 ? 2 : -2
    i = World.cmi(step > 0 ? o[Obj::X] + 16 : o[Obj::X] - 1, o[Obj::Y])
    d0 = cm(w, i) | cm(w, i - 0x20)
    i -= 0x20
    return l51ec(w, o, i + 0x20) if d0 & 1 == 1 || w[:player][:y] < o[Obj::Y]
    i -= 0x20
    # 3 cells ahead at 2, 3 and 4 columns: the first step is 2, the loop then steps 1 ($5190 / arcade $2aa6 - dbra / jr
    # back past the first add)
    d = step > 0 ? 1 : -1
    i = step_cell(w, i, d)
    3.times do
      i = step_cell(w, i, d)
      return o[Obj::CMD] |= 1 unless s5566(w, i)
    end
    l523e(w, o)
  end

  # One cell sideways. VERSION DIFFERENCE (MAME-verified, round 87): the arcade's column scans step with inc l / dec l,
  # so the address ($e080 + i) wraps inside its 256-byte page - from column 0 of rows 4/12/20/28 (low byte $00) dec l
  # goes to column 31 of the row 7 ABOVE instead of the row below; the X68000 uses addq.l / subq.l.
  def self.step_cell(w, i, d)
    return i + d if World.x68k?(w)
    a = 0xe080 + i
    ((a & 0xff00) | ((a + d) & 0xff)) - 0xe080
  end

  def self.l51ec(w, o, i)
    return l523e(w, o) if cm(w, i) & 1 == 0
    i += 0x20
    d0 = cm(w, i) & cm(w, i + 0x20) & cm(w, i + 0x40) & cm(w, i + 0x60) & 1
    return o[Obj::CMD] |= 1 if d0 == 0
    carry, = s5540(w, i)
    return o[Obj::CMD] |= 1 unless carry
    o[Obj::CMD] ^= 0x0c
  end

  def self.l521a(w, o)
    l521e(w, o, w[:player][:x])
  end

  def self.l521e(w, o, tx)
    tx < o[Obj::X] ? l5232(w, o) : l5224(w, o)
  end

  def self.l5224(w, o)
    o[Obj::CMD] = (o[Obj::CMD] & ~8) | 4
    l523e(w, o)
  end

  def self.l5232(w, o)
    o[Obj::CMD] = (o[Obj::CMD] & ~4) | 8
    l523e(w, o)
  end

  # close to Ptolemy: switch to chase mode
  def self.l523e(w, o)
    return if o[Obj::TYPE] == 0x57
    p = w[:player]
    o[Obj::CMD] |= 0x80 if adx(p[:x], o[Obj::X]) < 0x30 && adx(p[:y], o[Obj::Y]) < 9
  end

  # chase mode
  def self.l527c(w, o, d1)
    p = w[:player]
    if w[:mode626] != 0
      o[Obj::CMD] &= 0x3f
      return
    end
    if o[Obj::TYPE] == 0x91
      if p[:char] == 0x1c # a shrunk Ptolemy is left alone by Wizards
        o[Obj::CMD] = p[:x] >= o[Obj::X] ? 8 : 4
        o[Obj::TIMER] = 0x64
        return
      end
    elsif o[Obj::TYPE] != 0x3a
      d = adx(p[:x], o[Obj::X]) + adx(p[:y], o[Obj::Y])
      if d > 0xff || d >= 0x50 # lost her
        o[Obj::TIMER] = 0
        o[Obj::CMD] &= 0x3f
        return
      end
    end
    return l54bc(w, o) if d1 & 0x40 == 0
    l52f2(w, o)
  end

  def self.trail_at(w, idx)
    tr = w[:player][:trail]
    ty = tr[2 * idx]
    return [false, w[:player][:x], w[:player][:y]] if ty == 0
    [true, tr[2 * idx + 1], ty]
  end

  # following Ptolemy's footsteps ($63a trail)
  def self.l52f2(w, o)
    d3, tx, ty = trail_at(w, o[Obj::TRAIL])
    oy = o[Obj::Y]
    return l5370(w, o, d3, tx, ty) if oy == ty
    return l534e(w, o) if oy < ty
    return unless Obj.ground?(w, o, o[Obj::X], oy)
    l534e(w, o)
  end

  def self.l534e(w, o)
    o[Obj::CMD] &= ~0x40
    return unless o[Obj::TYPE] == 0x3a
    o[Obj::CMD] = 0
    o[Obj::TIMER] = 0x3c
  end

  def self.l5370(w, o, d3, tx, ty)
    ox = o[Obj::X]
    if o[Obj::CMD] & 0x0c != 0
      if o[Obj::CMD] & 4 != 0
        return l540e(w, o, ox + 0x10) if ox < tx
      elsif ox >= tx
        return l540e(w, o, ox - 1)
      end
    end
    l5390(w, o, d3)
  end

  def self.l5390(w, o, d3)
    loop do
      idx = o[Obj::TRAIL]
      if d3
        idx += 1
        idx = 0 if idx >= 0x0a
        o[Obj::TRAIL] = idx
      end
      d3, tx, ty = trail_at(w, idx)
      return l5464(w, o, d3, tx, ty) if o[Obj::Y] != ty
      next if o[Obj::X] == tx && d3
      return o[Obj::X] < tx ? l53f6(o) : l53e6(o)
    end
  end

  def self.l53e6(o)
    o[Obj::CMD] = (o[Obj::CMD] & ~4) | 8
  end

  def self.l53f6(o)
    o[Obj::CMD] = (o[Obj::CMD] & ~8) | 4
  end

  def self.l540e(w, o, x2)
    i = World.cmi(x2, o[Obj::Y])
    if cm(w, i) & 1 == 1
      d0 = cm(w, i + 0x20) & cm(w, i + 0x40) & cm(w, i + 0x60) & cm(w, i + 0x80) & 1
      return l534e(w, o) if d0 == 1 # wall too high
    else
      return if w[:player][:alt_walk] != 0
      return if cm(w, i - 0x20) & 1 == 1
    end
    o[Obj::CMD] & 4 != 0 ? o[Obj::CMD] = (o[Obj::CMD] & 0xf7) | 5 : o[Obj::CMD] = (o[Obj::CMD] & 0xfb) | 9
  end

  def self.l5464(w, o, d3, tx, ty)
    ox = o[Obj::X]
    if o[Obj::Y] > ty
      return ox < tx ? l53f6(o) : l53e6(o)
    end
    return unless d3
    d0 = (ox - tx) & 0xff
    o[Obj::CMD] = if ox >= tx
                    d0 < 4 ? (o[Obj::CMD] & 0xf3) | 1 : (o[Obj::CMD] & 0xfb) | 9
                  else
                    d0 >= 0xfc ? (o[Obj::CMD] & 0xf3) | 1 : (o[Obj::CMD] & 0xf7) | 5
                  end
  end

  def self.l54bc(w, o)
    p = w[:player]
    tr = p[:trail]
    if p[:y] == o[Obj::Y]
      n = 0
      n += 1 while n < 10 && tr[2 * n] != 0
      o[Obj::TRAIL] = n
      o[Obj::CMD] |= 0x40
      return p[:x] >= o[Obj::X] ? l53f6(o) : l53e6(o)
    end
    k = (0...10).find { |n| tr[2 * n] == o[Obj::Y] }
    if k
      o[Obj::TRAIL] = k
      o[Obj::CMD] |= 0x40
      return o[Obj::X] < tr[2 * k + 1] ? l53f6(o) : l53e6(o)
    end
    return l4d48(w, o) if o[Obj::TYPE] == 0x3a
    o[Obj::CMD] &= ~0x80
    o[Obj::TIMER] = 0
  end
end

Scheduler::IMPL[4] = EnemyAI
