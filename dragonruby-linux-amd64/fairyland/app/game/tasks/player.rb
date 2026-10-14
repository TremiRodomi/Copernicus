# Task 01: Ptolemy ($4366..$4904). One `when` per resume point of the original coroutine; `return n` = yield n frames.
# Locals the original kept in registers across yields live in the task Hash: :x/:y (d2/d1), :a (a0 table pointer),
# :frame (a2), :inp (d2 input copy), :tab (walk table).
module PlayerTask
  WALK = :player_walk      # 8 walk frames
  WALK_ALT = :player_walk_alt  # alternate walk frames ($633)
  BROOM_L = :broom_l   # extra part drawn in shrunk mode, facing left / right
  BROOM_R = :broom_r
  SLIDE_L = :player_slide_l   # step-off-a-ledge slide: (dx, dy, frame) triples, 0-terminated
  SLIDE_R = :player_slide_r
  JUMP_L = :player_jump_l    # jump: (frame, dy) pairs, 0-terminated; dy $f7 = "fall 2 px, no x"
  JUMP_R = :player_jump_r
  CAST_FRAME = 0x0c
  FALL_FRAME = 0x1a
  SND_JUMP = 0x16

  def self.run(w, t, gd)
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $4366
        p[:anim] = 1
        p[:jdx] = 0
        p[:latch] = 0
        p[:trail].fill(0)
        p[:trail_pos] = 0
        t[:pc] = :loop_top
      when :loop_top # $4386
        p[:cast] = 0
        trail_push(p, p[:y], p[:x])
        t[:pc] = :walk
      when :walk # $4398
        if ground?(w, p, p[:x], p[:y])
          p[:riding] = 0
        elsif !stand_on_object?(w)
          t[:pc] = :fall_start
          next
        end
        inp = input(w)
        p[:last_input] = inp
        t[:inp] = inp
        if inp & 2 == 0 # jump pressed
          if p[:latch] == 0
            t[:pc] = :jump_start
            next
          end
        else
          p[:latch] = 0
        end
        if p[:cast] != 0 # $43ce
          p[:cast] = (p[:cast] - 3) & 0xff
          return draw_walk(w, gd, t, p, CAST_FRAME)
        end
        if inp & 4 == 0 # left: +x
          p[:facing] = 0
          unless World.solid?(w, p[:x] + 16, p[:y])
            p[:x] = (p[:x] + p[:speed]) & 0xff
            advance_anim(p)
          end
        elsif inp & 8 == 0 # right: -x
          p[:facing] = 0x0d
          unless World.solid?(w, p[:x] - 1, p[:y])
            p[:x] = (p[:x] - p[:speed]) & 0xff
            advance_anim(p)
          end
        end
        t[:pc] = :walk_tab
      when :walk_tab # $4456
        t[:tab] = gd.a(WALK)
        if p[:alt_walk] != 0
          p[:alt_walk] = 0
          t[:tab] = gd.a(WALK_ALT)
          t[:pc] = :walk_draw
          return 1
        end
        t[:pc] = :walk_draw
      when :walk_draw # $4476
        return draw_walk(w, gd, t, p, gd.byte(t[:tab] + (p[:anim] & 0x7f)))
      when :walk_after # $44a0
        if p[:char] != 0x1c
          t[:pc] = :walk
          next
        end
        inp = input(w) # $44aa: shrunk mode draws a second part and animates twice per step
        d3 = (~inp & 0x0c) == 0 ? 0 : p[:anim]
        tab = gd.a(p[:facing] != 0 ? BROOM_R : BROOM_L)
        Shadow.set_a(w, gd, gd.byte(tab + d3), t[:y], t[:x])
        if p[:anim] & 1 == 0
          p[:anim] = (p[:anim] + 1) >= 8 ? 0 : p[:anim] + 1 # $4448, then on through $4456 (the alternate-table yield)
          t[:pc] = :walk_tab
        else
          t[:pc] = :walk
        end
      when :fall_start # $44ec
        p[:fall_count] = 4
        trail_push(p, p[:y], p[:x])
        t[:x] = p[:x]
        t[:y] = p[:y]
        inp = input(w)
        if (~inp & 0x0c) != 0
          t[:a] = gd.a(p[:facing] == 0 ? SLIDE_L : SLIDE_R)
          t[:pc] = :fall_slide
          return 1
        end
        p[:cast] = 0 # $4546
        t[:pc] = :fall_body
        return 1
      when :fall_slide # $4526
        dx = gd.byte(t[:a])
        if dx == 0
          p[:cast] = 0
          t[:pc] = :fall_body
          return 1
        end
        t[:x] = (t[:x] + dx) & 0xff if t[:x] & 7 != 0
        t[:y] = (t[:y] + gd.byte(t[:a] + 1)) & 0xff
        Shadow.set_a(w, gd, (gd.byte(t[:a] + 2) + p[:char]) & 0xff, t[:y], t[:x])
        t[:a] += 3
        return 1
      when :fall_body # $4554
        p[:x] = t[:x]
        p[:y] = t[:y]
        inp = input(w)
        if inp & 4 == 0
          p[:facing] = 0
        elsif inp & 8 == 0
          p[:facing] = 0x0d
        end
        if t[:y] & 7 == 0 && ground?(w, p, t[:x], t[:y])
          t[:pc] = :land
          next
        end
        p[:fall_count] = (p[:fall_count] - 1) & 0xff
        if p[:fall_count] >= 0x80 && stand_on_object?(w) # objects only count after the first 4 frames
          t[:pc] = :land
          next
        end
        p[:y] = (p[:y] - 2) & 0xff # falling 2 px/frame; y wraps, so falling off the bottom re-enters at the top
        t[:x] = p[:x]
        t[:y] = p[:y]
        f = if p[:cast] != 0
              p[:cast] -= 1
              CAST_FRAME + p[:facing]
            else
              FALL_FRAME
            end
        Shadow.set_a(w, gd, (f + p[:char]) & 0xff, t[:y], t[:x])
        return 1
      when :land # $45ca
        t[:pc] = :land2
        return 2
      when :land2
        if p[:x].odd?
          p[:x] = (p[:x] + (p[:facing] == 0 ? 1 : -1)) & 0xff
        end
        t[:pc] = :loop_top
      when :jump_start # $45fc
        p[:latch] = 0xff
        w[:sounds] << SND_JUMP
        p[:riding] = 0
        inp = t[:inp]
        if inp & 4 == 0
          p[:facing] = 0
          p[:jdx] = 1
        elsif inp & 8 == 0
          p[:facing] = 0x0d
          p[:jdx] = 0xff
        else
          p[:jdx] = 0
        end
        t[:a] = gd.a(p[:facing] == 0 ? JUMP_L : JUMP_R)
        p[:fall_count] = 0x11
        t[:x] = p[:x]
        t[:y] = p[:y]
        trail_push(p, p[:y], p[:x])
        t[:pc] = :jump_body
        return 1
      when :jump_body # $466c
        r = jump_step(w, gd, t, p)
        return r if r
      else
        raise "PlayerTask: bad pc #{t[:pc]}"
      end
    end
  end

  # One frame of the jump. Returns frames to yield, or nil after changing t[:pc] (continue without yielding).
  def self.jump_step(w, gd, t, p)
    d3 = (p[:fall_count] - 1) & 0xff
    p[:fall_count] = d3
    b = gd.byte(t[:a])
    t[:a] += 1
    if b == 0 # end of table: keep falling
      t[:pc] = :fall_body
      return nil
    end
    t[:frame] = b
    x = t[:x]
    y = t[:y]
    early = World.sbyte(d3 + 1) >= 0 # first 18 frames
    if !early
      if p[:jdx] != 0 && World.solid?(w, World.sbyte(p[:jdx]) >= 0 ? x + 16 : x - 1, y - 1)
        p[:jdx] = 0 # hit a wall
      end
    elsif p[:jdx] == 0 || short_hop?(w, p)
      if y & 7 == 0 # vertical jump at a cell boundary: push sideways to step onto a ledge
        inp = input(w)
        step = nil
        if inp & 4 == 0
          step = 2
          p[:facing] = 0
          wx = x + 16
        elsif inp & 8 == 0
          step = 0xfe
          p[:facing] = 0x0d
          wx = x - 1
        end
        if step
          i = World.cmi(wx, y)
          if World.cm(w, i) & 1 == 0 && World.cm(w, i - 0x20) & 1 == 1
            p[:x] = (x + step) & 0xff
            p[:y] = y
            t[:pc] = :loop_top
            return nil
          end
        end
      end
    else
      wx = World.sbyte(p[:jdx]) >= 0 ? x + 16 : x - 1
      wy = gd.byte(t[:a]) >= 4 ? y + 8 : y - 8
      i = World.cmi(wx, wy)
      p[:jdx] = 0 if (World.cm(w, i) & World.cm(w, i + 0x20) & 1) == 1
    end
    dy = gd.byte(t[:a]) # $4766
    if dy >= 0x80 && y & 7 == 0 # descending at a cell boundary: land on a solid top
      i = World.cmi(x + (p[:facing] == 0 ? 4 : 3), y)
      here = ~(World.cm(w, i) | World.cm(w, i + 1))
      below = World.cm(w, i - 0x1f) | World.cm(w, i - 0x20)
      if (below & here & 1) == 1 || stand_on_object?(w)
        t[:pc] = :loop_top
        return nil
      end
    end
    t[:a] += 1
    if dy == 0xf7
      y = (y - 2) & 0xff
    else
      y = (y + dy) & 0xff
      x = (x + p[:jdx]) & 0xff
    end
    p[:x] = t[:x] = x
    p[:y] = t[:y] = y
    f = if p[:cast] != 0
          p[:cast] -= 1
          CAST_FRAME + p[:facing] + p[:char]
        else
          p[:char] + t[:frame]
        end
    Shadow.set_a(w, gd, f & 0xff, y, x)
    1
  end

  # QOL option (off = original behaviour): a directional jump whose button was tapped (already released) while the direction
  # is still held gets the vertical jump's ledge step, so "tap jump + hold direction" performs the short hop.
  def self.short_hop?(w, p)
    return false unless w[:opts] && w[:opts][:short_hop] && !w[:demo_script] # the attract demos are always the arcade's
    inp = input(w)
    return false if inp & 2 == 0 # jump still held: normal full jump
    held = inp & 4 == 0 ? 1 : (inp & 8 == 0 ? 0xff : nil)
    held == p[:jdx]
  end

  def self.draw_walk(w, gd, t, p, f) # $4482
    t[:x] = p[:x]
    t[:y] = p[:y]
    Shadow.set_a(w, gd, (f + p[:facing] + p[:char]) & 0xff, p[:y], p[:x])
    t[:pc] = :walk_after
    p[:step_delay]
  end

  # $4436: walk cycle 0..7; with sprite set $38 it only advances every other step
  def self.advance_anim(p)
    a = p[:anim]
    if p[:char] == 0x38
      a ^= 0x80
      if a & 0x80 != 0
        p[:anim] = a
        return
      end
    end
    a = (a & 0x7f) + 1
    p[:anim] = a >= 8 ? 0 : a
  end

  # $47fe/$4806: standing on the top surface of a block under either foot column
  def self.ground?(w, p, x, y)
    i = World.cmi(x + (p[:facing] == 0 ? 4 : 3), y - 1)
    c = ->(o) { World.cm(w, i + o) }
    ((c.(0) & ~c.(0x20)) | (c.(1) & ~c.(0x21))) & 1 == 1
  end

  # $4836: standing on an object (state 1..$0f, Ptolemy 17..24 px above it, within 12 px horizontally) -> $632 = its task id
  def self.stand_on_object?(w)
    p = w[:player]
    w[:obj].each do |o|
      next unless o[Obj::ST] != 0 && o[Obj::ST] < 0x10
      dy = (p[:y] - o[Obj::Y]) & 0xff
      next unless dy >= 0x11 && dy < 0x19
      next unless (p[:x] - o[Obj::X]).abs < 0x0d
      p[:riding] = o[Obj::TASK]
      return true
    end
    p[:riding] = 0
    false
  end

  # $48ca: active-low 4 bits (demo input $592 not implemented yet)
  def self.input(w)
    World.input(w)
  end

  # $488c
  # $488c: store (y, x) and zero the next entry's y, so the ring always holds a terminator where the AI's scans stop.
  # On the wrap the zero lands in $64e (index 20) and again in the first entry.
  def self.trail_push(p, y, x)
    tr = p[:trail]
    tr[p[:trail_pos]] = y
    tr[p[:trail_pos] + 1] = x
    p[:trail_pos] += 2
    tr[p[:trail_pos]] = 0
    return if p[:trail_pos] < 20
    p[:trail_pos] = 0
    tr[0] = 0
  end
end

Scheduler::IMPL[1] = PlayerTask
