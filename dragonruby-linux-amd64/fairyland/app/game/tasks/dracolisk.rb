# Round 101: the Dracolisk. The original keeps its state in object slots 0-1 ($59e-$5b1) and the fireballs in an
# emulation of the arcade protection MCU's line stepper ($5b3-$5d0, MCU commands 4-6); the port keeps them in w[:drac].
#   21 ($9016) director: spell hits fill a damage meter (+30, -1 every 6 frames; 256 = defeated); touching it crushes;
#      defeat = it turns into a giant cake, drops, crumbles (then the Holy Gem: tasks 2c/2d/0d, the ending)
#   22 ($92a8) draws it (head, body, tail, legs: four $1c44 chains)   23 ($92ea) body: walk, fall, jump / drop
#   27 ($947a) tail   28 ($94b2) body frames while airborne   29 ($94fa) head turning + fire breath   2a ($9620) AI
#   2b ($980a) the two fireballs
module Drac
  SLOT = 0x0c
  FREEZE = [0x22, 0x23, 0x27, 0x28, 0x29, 0x2a].freeze # $ccae

  def self.init(w)
    w[:drac] = { head: 0, body: 0x0e, legs: 0x19, tail: 0x38, attr: 0xf3, x: 0x68, y: 0xa8, cmd: 0, legph: 0, bodyph: 0,
                 landed: 0, head_target: 1, head_cur: 1, tx: 0, ty: 0, wait: 0, dmg: 0,
                 b0: 0, b1: 0, # $5b0: $ff until Ptolemy reaches the Holy Gem (task 2d); $5b1 (0 = the jump sound plays)
                 mcu: Array.new(4, 0), # MCU RAM $35-$38: line start x, y, end x, y
                 lines: Array.new(2) { { active: 0, x: 0, y: 0, ax: 0, ay: 0, sx: 0, sy: 0 } } }
  end

  # $9466: any of the 5 cells to the -x side of (x, y) solid
  def self.ground?(w, x, y)
    i = World.cmi(x & 0xff, y & 0xff)
    (1..5).any? { |k| World.cm(w, i - k) & 1 == 1 }
  end

  # $97f0: the cell and the 5 above it - any solid
  def self.column?(w, i)
    (0..5).any? { |k| World.cm(w, i + 0x20 * k) & 1 == 1 }
  end

  # its body box: 0 <= x - 8 - px < $30 and -24 <= y - py < 9
  def self.in_box?(d, px, py)
    return false unless ((d[:x] - 8 - px) & 0xff) < 0x30
    d[:y] >= py ? d[:y] - py < 9 : ((d[:y] - py) & 0xff) >= 0xe8
  end

  # $9262: touching it crushes Ptolemy
  def self.contact(w)
    p = w[:player]
    return unless in_box?(w[:drac], p[:x], p[:y]) && !w[:no_hit]
    Scheduler.kill(w, 1)
    w[:end_code] = 0x80
  end

  # $95d4: fire at the remembered target from the mouth (MCU RAM writes; writing $37 starts a line)
  def self.breathe(w)
    d = w[:drac]
    d[:mcu][1] = (d[:y] + 0x1c) & 0xff
    d[:mcu][0] = d[:attr] == 0xf3 ? d[:x] : (d[:x] - 0x40) & 0xff
    d[:mcu][3] = d[:ty]
    d[:mcu][2] = d[:tx]
    World.x68k?(w) ? line_start(d) : mcu_start(d)
    w[:sounds] << 0x39
  end

  # ARCADE: the protection MCU's line stepper (a45-20.mcu, command 5 $15f / command 6 $1c2). Slot: flag (1 = x major,
  # $ff = y major), x, y, acc, major, minor, x step, y step (+-3). Integer Bresenham in 3 px steps from the exact start.
  def self.mcu_start(d)
    l = d[:lines].find { |s| s[:active] == 0 }
    return unless l
    x1, y1, x2, y2 = d[:mcu]
    dx = x2 - x1
    dy = y2 - y1
    l[:xs] = dx < 0 ? 0xfd : 3
    l[:ys] = dy < 0 ? 0xfd : 3
    l[:major], l[:minor] = dx.abs & 0xff, dy.abs & 0xff
    l[:active] = 1
    if l[:minor] >= l[:major]
      l[:major], l[:minor] = l[:minor], l[:major]
      l[:active] = 0xff
    end
    l[:inc] = l[:minor]
    l[:acc] = l[:minor]
    l[:x] = x1
    l[:y] = y1
  end

  def self.mcu_step(l)
    return if l[:active] == 0
    v = l[:acc] + l[:inc]
    l[:acc] = v & 0xff
    if (v & 0xff) >= l[:major] # 8-bit add (carry dropped), then `sub 4,x` without a borrow: both axes
      l[:acc] = ((v & 0xff) - l[:major]) & 0xff
      l[:y] = (l[:y] + l[:ys]) & 0xff
      l[:x] = (l[:x] + l[:xs]) & 0xff
    elsif l[:active] < 0x80
      l[:x] = (l[:x] + l[:xs]) & 0xff
    else
      l[:y] = (l[:y] + l[:ys]) & 0xff
    end
  end

  # X68000: $98d8 rebuilds command 5 differently - 4 px units, an 8.8 slope (minor << 8) / major, positions on a 4 px grid
  def self.line_start(d)
    l = d[:lines].find { |s| s[:active] == 0 }
    return unless l
    l[:active] = 0xff
    x1, y1, x2, y2 = d[:mcu].map { |v| v >> 2 }
    l[:ax] = x1 << 8
    l[:ay] = y1 << 8
    dx = x2 - x1
    dy = y2 - y1
    if dx == 0
      sx, sy = 0, 0x100
    elsif dy == 0
      sx, sy = 0x100, 0
    elsif dy.abs < dx.abs
      sx, sy = 0x100, (dy.abs << 8).idiv(dx.abs)
    else
      sx, sy = (dx.abs << 8).idiv(dy.abs), 0x100
    end
    l[:sx] = dx < 0 ? -sx : sx
    l[:sy] = dy < 0 ? -sy : sy
  end

  # $997c (MCU command 6): one step; positions are 4-px aligned
  def self.line_step(l)
    l[:ax] = (l[:ax] + l[:sx]) & 0xffff
    l[:ay] = (l[:ay] + l[:sy]) & 0xffff
    l[:x] = ((l[:ax] >> 6) + 2) & 0xfc
    l[:y] = ((l[:ay] >> 6) + 2) & 0xfc
  end
end

# Task 21: the fight director
module DracFight
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      d = w[:drac]
      case t[:pc]
      when :start # $9016: set up, start its parts, wait for the intro to finish (the round start resumes this task)
        Drac.init(w)
        [0x29, 0x23, 0x27, 0x22].each { |id| Scheduler.spawn(w, id) }
        t[:suspended] = true
        t[:pc] = :resumed
        return 1
      when :resumed
        [4, 0x0f, 0x11, 0x14].each { |id| Scheduler.kill(w, id) }
        Scheduler.spawn(w, 0x2a)
        Scheduler.spawn(w, 0x2b)
        t[:pc] = :arm
        return 2
      when :arm # $90ae: no Horned / bonus items; sparkle slots 1-2 kept busy
        w[:t611] = 0xff
        w[:sparkles][1][0] = 0xff
        w[:sparkles][2][0] = 0xff
        t[:pc] = w[:opts] && w[:opts][:drac_dead] ? :defeat : :fight # dev: --drac_dead 1
      when :fight # every 6 frames: spell hits fill the meter, which drains 1 a step
        s = w[:shot]
        hit = s[:active] != 0 && Drac.in_box?(d, s[:x], s[:y])
        if hit
          s[:active] = 0
          Effects.sparkle(w, 0, s[:x], s[:y])
          v = d[:dmg] + 0x1e
          d[:dmg] = v & 0xff
          if v > 0xff
            t[:pc] = :defeat
            next
          end
        elsif d[:dmg] > 0
          d[:dmg] -= 1
        end
        Drac.contact(w)
        return 6
      when :defeat # $911c: it turns into a giant cake
        d[:defeated] = true # (port only: the widgets' health bar)
        Drac::FREEZE.each { |id| Scheduler.suspend(w, id) }
        0x13.times { |k| Shadow.clear(w, 0x0c + 4 * k) }
        w[:sounds] << 0x35
        t[:a] = gd.a(:drac_death)
        t[:pc] = :cake
      when :cake # [code, dy, code] .. 0: the big cake (slot $18) + a part at y + dy (slot $0c)
        f = gd.byte(t[:a])
        if f == 0
          d[:y] &= 0xfc
          t[:pc] = :drop
          next
        end
        Shadow.set_d(w, gd, f, d[:y], d[:x], 0x18, 0xfe)
        Shadow.set_d(w, gd, gd.byte(t[:a] + 2), (d[:y] + gd.byte(t[:a] + 1)) & 0xff, d[:x], 0x0c, 0xc2)
        t[:a] += 3
        return 4
      when :drop # $9188: it falls 2 px a frame to the floor
        if d[:y] < 0x19
          t[:pc] = :crumble_snd
          return 0x14
        end
        d[:y] = (d[:y] - 2) & 0xff
        Shadow.set_d(w, gd, 0x51, d[:y], d[:x], 0x18, 0xfe)
        Drac.contact(w)
        return 1
      when :crumble_snd
        w[:sounds] << 0x36
        t[:a] = gd.a(:drac_crumble)
        t[:pc] = :crumble
      when :crumble # [dy, code] pairs until code 0 (dy 0 = sound $37)
        dy = gd.byte(t[:a])
        w[:sounds] << 0x37 if dy == 0
        slot = Shadow.set_d(w, gd, 0x7f, (d[:y] + dy) & 0xff, d[:x], 0x18, 0xfe)
        f = gd.byte(t[:a] + 1)
        t[:a] += 2
        if f == 0
          t[:pc] = :gone
          next
        end
        Shadow.set_d(w, gd, f, d[:y], d[:x], slot, 0xfe)
        return 5
      when :gone # $920e: the round is won; the Holy Gem and the ending (tasks 2c, 2d, 0d) are not ported yet
        w[:enemies_left] = 0
        [0x2c, 0x2d, 0x0d].each { |id| Scheduler.spawn(w, id) }
        t[:a] = gd.a(:drac_end)
        t[:pc] = :end_frame
        return 0x0a
      when :end_frame
        f = gd.byte(t[:a])
        t[:a] += 1
        return :killed if f == 0
        Shadow.set_d(w, gd, f, d[:y], d[:x], 0x18, 0xcc)
        return 0x0a
      else
        raise "DracFight: bad pc #{t[:pc]}"
      end
    end
  end
end

# Task 22: draw the four parts every frame (the jump/fall leg frame $32 comes from sprite bank 0)
module DracDraw
  def self.run(w, t, gd)
    d = w[:drac]
    s = Drac::SLOT
    s = Shadow.set_d(w, gd, d[:head], d[:y], d[:x], s, d[:attr])
    s = Shadow.set_d(w, gd, d[:body], d[:y], d[:x], s, d[:attr])
    s = Shadow.set_d(w, gd, d[:tail], d[:y], d[:x], s, d[:attr])
    Shadow.set_d(w, gd, d[:legs], d[:y], d[:x], s, d[:legs] == 0x32 ? d[:attr] & 0xcf : d[:attr])
    1
  end
end

# Task 23: the body. Walks 2 px per 7 frames within x $60-$d0 (legs cycle), falls 1 px a frame, jumps up a tier, or (cmd
# bit 4) hops and drops through the platform it stands on
module DracBody
  def self.run(w, t, gd)
    d = w[:drac]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        d[:legph] = 0
        d[:legs] = 0x19
        t[:pc] = :walk
      when :walk # $92f6
        unless Drac.ground?(w, d[:x], d[:y] - 1)
          Scheduler.spawn(w, 0x28)
          d[:legs] = 0x32
          t[:pc] = :fall
          next
        end
        c = d[:cmd]
        if c & 1 != 0
          t[:pc] = :jump
          next
        end
        if c & 4 != 0
          if d[:x] < 0xd0
            d[:x] = (d[:x] + 2) & 0xff
            step(w, gd, d, d[:attr] == 0xf3)
          end
        elsif c & 8 != 0
          if d[:x] >= 0x60
            d[:x] = (d[:x] - 2) & 0xff
            step(w, gd, d, d[:attr] == 0xb3)
          end
        end
        return 7
      when :fall # $93ec
        if Drac.ground?(w, d[:x], d[:y] - 5)
          t[:n] = 4
          t[:pc] = :land
          next
        end
        d[:y] = (d[:y] - 1) & 0xff
        return 1
      when :land # $940a: settles 4 px
        d[:y] = (d[:y] - 1) & 0xff
        t[:n] -= 1
        t[:pc] = :landed if t[:n] == 0
        return 3
      when :landed
        d[:landed] = 0xff
        d[:cmd] = 0
        d[:legs] = gd.byte(gd.a(:drac_legs) + d[:legph])
        t[:pc] = :walk
        return 7
      when :jump # $93a0: crouch, push off 4 px
        Scheduler.spawn(w, 0x28)
        t[:pc] = :jump2
        return 0x1e
      when :jump2
        d[:legs] = 0x32
        t[:n] = 4
        t[:pc] = :jump_up
      when :jump_up
        d[:y] = (d[:y] + 1) & 0xff
        t[:n] -= 1
        if t[:n] == 0
          t[:pc] = :jump3
        end
        return 5
      when :jump3
        if d[:cmd] & 0x10 != 0 # drop through: down 12 px, then fall
          t[:n] = 12
          t[:pc] = :hop
          return 0x0a
        end
        t[:n] = 8
        t[:pc] = :rise8
      when :hop
        d[:y] = (d[:y] - 1) & 0xff
        t[:n] -= 1
        t[:pc] = :fall if t[:n] == 0
        return 2
      when :rise8
        d[:y] = (d[:y] + 1) & 0xff
        t[:n] -= 1
        t[:pc] = :rise if t[:n] == 0
        return 2
      when :rise # $943e: up until its feet line up with a platform
        y4 = (d[:y] - 4) & 0xff
        if y4 & 7 == 0 && Drac.ground?(w, d[:x], y4 - 1)
          t[:n] = 4
          t[:pc] = :land
          next
        end
        d[:y] = (d[:y] + 1) & 0xff
        return 2
      else
        raise "DracBody: bad pc #{t[:pc]}"
      end
    end
  end

  def self.step(w, gd, d, forward)
    d[:legph] = forward ? (d[:legph] + 1) % 4 : (d[:legph] - 1) % 4
    d[:legs] = gd.byte(gd.a(:drac_legs) + d[:legph])
  end
end

# Task 27: the tail swings while it walks
module DracTail
  def self.run(w, t, gd)
    d = w[:drac]
    t[:k] ||= 0
    c = d[:cmd]
    if c & 0x0c != 0 && c & 0xf3 == 0
      t[:k] = (t[:k] + 1) % 3
      d[:tail] = gd.byte(gd.a(:drac_tail) + t[:k])
    end
    9
  end
end

# Task 28: body frames while airborne, until it has landed and the cycle wraps
module DracAir
  def self.run(w, t, gd)
    d = w[:drac]
    if t[:pc] == :start
      d[:bodyph] = 2
      d[:landed] = 0
      t[:pc] = :cycle
      return 5
    end
    n = d[:bodyph] + 1
    if n >= 3
      return :killed if d[:landed] != 0
      n = 0
    end
    d[:bodyph] = n
    d[:body] = gd.byte(gd.a(:drac_body) + n)
    5
  end
end

# Task 29: the head turns towards its target pose one step per 10 frames; pose 5 + cmd bit 7 = it turns round; cmd bit 1
# = breathe fire (a 4-step script by pose; wait $19 = fire, twice when the target is close)
module DracHead
  def self.run(w, t, gd)
    d = w[:drac]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start, :turn # $94fa: direction and step count are taken ONCE; a target set meanwhile waits until the
        # whole move is done (MAME check, NOTES pass 49: the port re-aimed every step and turned the head back early)
        if d[:head_target] != d[:head_cur]
          t[:dir] = d[:head_target] > d[:head_cur] ? 1 : -1
          t[:count] = (d[:head_target] - d[:head_cur]).abs
          t[:pc] = :step
          next
        end
        t[:pc] = :act
      when :step
        d[:head_cur] = (d[:head_cur] + t[:dir]) & 0xff
        d[:head] = gd.byte(gd.a(:drac_head) + d[:head_cur])
        t[:pc] = :stepped
        return 0x0a
      when :stepped
        t[:count] -= 1
        t[:pc] = t[:count] != 0 ? :step : :act
      when :act # $9534
        c = d[:cmd]
        if d[:head_cur] == 5 && c & 0x80 != 0
          d[:cmd] &= 0x7f
          d[:attr] = d[:attr] == 0xf3 ? 0xb3 : 0xf3
          d[:head_target] = 1
        end
        if c & 2 == 0
          t[:pc] = :turn
          return 3
        end
        d[:cmd] = c & 0xfd # quirk: written from the copy taken before bit 7 was cleared
        name = d[:head_cur] == 1 ? :breath_low : d[:head_cur] == 4 ? :breath_mid : :breath_high
        t[:a] = gd.a(name)
        t[:n] = 4
        t[:pc] = :script
      when :script
        if t[:n] == 0
          t[:pc] = :turn
          return 3
        end
        v = gd.byte(t[:a])
        t[:a] += 1
        if v == 0x19
          Drac.breathe(w)
          if d[:wait] < 0x28
            t[:pc] = :fire2
            return 0x0a
          end
        end
        t[:pc] = :script_head
        return v
      when :fire2
        Drac.breathe(w)
        t[:pc] = :script_head
        return 0x19
      when :script_head
        d[:head] = gd.byte(t[:a])
        t[:a] += 1
        t[:n] -= 1
        t[:pc] = :script
      else
        raise "DracHead: bad pc #{t[:pc]}"
      end
    end
  end
end

# Task 2a: the AI (every 6 frames). Ptolemy well above -> jump (or walk to where it can); far below -> drop through;
# otherwise keep 56-72 px from her (turning round when she gets behind it), and breathe fire when she is in front and not
# above its mouth: head pose by slope (1 low, 4 mid, 5 high), then wait (distance / 2) frames
module DracAI
  def self.run(w, t, gd)
    d = w[:drac]
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start, :think
        t[:pc] = :breath_check
        dy = p[:y] - ((d[:y] + 0x28) & 0xff)
        if dy >= 0
          climb(w, d)
        elsif (dy & 0xff) < 0x80
          d[:cmd] |= 0x11 # far below: hop down
        else
          walk(d, p)
        end
      when :breath_check # $96ae
        v = (d[:y] + 0x21 - p[:y])
        if v < 0
          t[:pc] = :think
          return 6
        end
        v &= 0xff
        if d[:attr] == 0xf3
          h = (d[:x] - 8 - p[:x])
          if h >= 0
            t[:pc] = :think
            return 6
          end
          h = (-h) & 0xff
        else
          h = d[:x] - 0x38 - p[:x]
          if h < 0
            t[:pc] = :think
            return 6
          end
          h &= 0xff
        end
        d[:tx] = p[:x]
        d[:ty] = p[:y]
        t[:v] = v
        t[:h] = h
        t[:pc] = :aim
        return 1
      when :aim
        slope = t[:h] == 0 ? 0xffff : (t[:v] << 8).idiv(t[:h])
        d[:head_target] = slope < 0xab ? 1 : slope < 0x200 ? 4 : 5
        d[:cmd] |= 2
        t[:pc] = :breathing
        return 1
      when :breathing
        return 1 if d[:cmd] & 2 != 0
        d[:wait] = ((t[:v] + t[:h]) & 0xff) >> 1
        t[:pc] = :rest
        return d[:wait] if d[:wait] != 0
      when :rest
        t[:pc] = :think
        return 6
      else
        raise "DracAI: bad pc #{t[:pc]}"
      end
    end
  end

  # $963e
  def self.walk(d, p)
    d2 = (d[:x] - 0x20) & 0xff
    v = p[:x] - d2
    o = v & 0xff
    if d[:attr] == 0xf3
      if v >= 0
        return move(d, 4) if o >= 0x48
        return move(d, 8) if o < 0x38
        return d[:cmd] &= 0xf3
      end
      return turn(d) if o >= 0xc8
      return move(d, 4) if d2 < 0x80
      turn(d)
    else
      if v < 0
        return move(d, 8) if o < 0xb8
        return move(d, 4) if o >= 0xc8
        return d[:cmd] &= 0xf3
      end
      return turn(d) if o < 0x38 || d2 < 0x80
      move(d, 8)
    end
  end

  def self.move(d, bit)
    d[:cmd] = (d[:cmd] & ~(bit == 4 ? 8 : 4)) | bit
  end

  def self.turn(d)
    d[:cmd] |= 0x80
    d[:head_target] = 5
  end

  # $976a: Ptolemy is above: jump if the way up is clear over its head, else walk to where it is
  def self.climb(w, d)
    i = World.cmi((d[:x] - 0x18) & 0xff, (d[:y] + 8) & 0xff)
    if Drac.column?(w, i)
      d[:cmd] = (d[:cmd] & 0xef) | 1
      return
    end
    step = d[:attr] == 0xf3 ? 1 : -1
    loop do
      i += step
      if i & 0x1f == 0
        move(d, step > 0 ? 4 : 8)
        return turn(d)
      end
      return move(d, step > 0 ? 4 : 8) if Drac.column?(w, i)
    end
  end
end

# Task 2b: the two fireballs fly 4 px a frame along their lines (sprite $8e, slots $74 / $78) and burn on contact;
# off the playfield they end
module DracFire
  def self.run(w, t, gd)
    if t[:pc] == :start # $980a / arcade $869e: 60 frames, then the loop yields 1 BEFORE its first read (MAME x68000)
      t[:pc] = :wait
      return 0x3c
    end
    if t[:pc] == :wait
      t[:pc] = :fly
      return 1
    end
    d = w[:drac]
    arcade = !World.x68k?(w)
    d[:lines].each_with_index do |l, k|
      active = l[:active]
      Drac.line_step(l) unless arcade # X68000: the line steps whenever its flag is read
      next if active == 0
      slot = 0x74 + 4 * k
      Shadow.set_b(w, gd, 0x8e + (l[:x] & 1), l[:y], l[:x], slot, :meta_poses)
      if l[:x] >= 0xe0 || l[:x] < 0x10 || l[:y] < 0x18
        l[:active] = 0
        Shadow.clear(w, slot)
      else
        EnemyShot.burns?(w, l[:x], l[:y])
      end
    end
    d[:lines].each { |l| Drac.mcu_step(l) } if arcade # arcade: MCU command 6 after both were drawn
    1
  end
end

Scheduler::IMPL[0x21] = DracFight
Scheduler::IMPL[0x22] = DracDraw
Scheduler::IMPL[0x23] = DracBody
Scheduler::IMPL[0x27] = DracTail
Scheduler::IMPL[0x28] = DracAir
Scheduler::IMPL[0x29] = DracHead
Scheduler::IMPL[0x2a] = DracAI
Scheduler::IMPL[0x2b] = DracFire
