# Task 14 ($70fa, arcade $3030): the moon. A countdown that survives round changes AND deaths ($61b: 120 ticks at a new
# game or a continue - $1fd2 in the $1f9c set-up, not the new-life entry $1fd8 -, then 240 after each moon) ticks every 2 seconds (1 second while Ptolemy is shrunk); the Moon Tiara item sets it to 1. When it runs out the
# moon rises in the top-right sky, night spreads from it (NightWipe), every enemy turns into a cake for ~8.4 s with its
# own music (cake breaks drop bonus coins meanwhile: $623), then the moon sets, morning returns and the cakes hatch.
module MoonTask
  FRAMES = :moon_frames # 8 frames x 3x3 tiles: rising forwards, setting backwards
  POS = 0xc74f          # name-table address of the 3x3 block (1UP; 2UP would use $c775 / column $19)
  COL = 6               # wipe centre column in name-table terms (= screen column 25)
  SND_RISE = 0x14
  SND_NIGHT = 0x3f
  SND_NIGHT_ARCADE = 0x0a
  SND_MORNING = 0x15
  CAKE = 0xeb
  HUD_ATTR = 0x38       # $79c clears with the text attribute $6a, last set by the HUD's score digits

  def self.run(w, t, gd)
    g = w[:game]
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        w[:moon_pos] = POS
        w[:moon_col] = COL
        w[:bonus623] = false
        t[:pc] = :tick
      when :tick # $711e / $713c
        g[:moon] = (g[:moon] - 1) & 0xff
        if g[:moon] == 0
          t[:pc] = :event
          next
        end
        t[:pc] = :wait
        return 60
      when :wait # a second 60-frame wait unless Ptolemy is shrunk
        t[:pc] = :tick
        return 60 unless p[:char] == 0x1c
      when :event # $7142
        g[:moon] = 0xf0
        t[:a] = gd.a(FRAMES)
        t[:n] = 8
        t[:pc] = :rise
      when :rise
        draw(w, gd, t[:a])
        t[:a] += 9
        t[:n] -= 1
        t[:pc] = :night if t[:n] == 0
        return 10
      when :night # the main loop's NightWipe resumes this task when night has spread
        w[:sounds] << SND_RISE
        w[:night] = 1
        t[:pc] = :cakes
        t[:k] = 0
        t[:suspended] = true
        return 1
      when :cakes # $717a: every enemy becomes a cake; Cleric-summoned ones just vanish
        w[:bonus623] = true if t[:k] == 0
        if t[:k] == 8
          t[:pc] = :unshrink
          next
        end
        o = w[:obj][t[:k]]
        st = o[Obj::ST]
        if st == 0 || (st >= 0x80 && st < 0xf0)
          t[:k] += 1
          next
        end
        if o[Obj::CMD] & 0x20 != 0
          o[Obj::ST] = 0
          Scheduler.kill(w, o[Obj::TASK])
          Shadow.clear(w, o[Obj::SLOT])
          Shadow.clear(w, o[Obj::SLOT] + 4)
          w[:enemies_left] = (w[:enemies_left] - 1) & 0xff
          t[:k] += 1
          return 1
        end
        Effects.sparkle(w, 0, o[Obj::X], o[Obj::Y]) if st < 0x80
        Scheduler.kill(w, o[Obj::TASK])
        o[Obj::ST] = 0
        t[:y] = o[Obj::Y]
        t[:pc] = :cake
        return 7
      when :cake
        o = w[:obj][t[:k]]
        o[Obj::ST] = 0xf0
        o[Obj::ANIM] = 0xc8
        o[Obj::Y] = t[:y] & 0xf8
        Shadow.set_b(w, gd, CAKE, o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        t[:k] += 1
        t[:pc] = :cakes
        return 9
      when :unshrink # $7228: night lifts a Wizard's shrink (remembered in $61c to put back in the morning)
        t[:wiz] = w[:wizard_id]
        t[:pc] = :hush
        if t[:wiz] != 0
          w[:wizard_id] = 0
          Effects.sparkle(w, 0, p[:x], p[:y])
          t[:pc] = :grow
          return 0x14
        end
      when :grow
        p[:char] = 0
        p[:step_delay] = 3
        p[:speed] = 2
        t[:pc] = :hush
      when :hush # wait for the sound driver ($7258: yield first), then the night music and ~8.4 s of night
        t[:pc] = :hush_wait
        return 1
      when :hush_wait
        return 1 if w[:audio_busy]
        t[:pc] = :music
        return 1
      when :music # VERSION DIFFERENCE: the arcade sends $0a ($3127) and waits 240 + 240 + 40, the X68000 $3f ($7272) and
        # 240 + 240 + 22 (MAME: $0a -> $15 in 600 frames)
        w[:sounds] << (World.x68k?(w) ? SND_NIGHT : SND_NIGHT_ARCADE)
        t[:n] = 3
        t[:pc] = :dark
      when :dark
        t[:n] -= 1
        if t[:n] == 0
          t[:a] = gd.a(FRAMES) + 63
          t[:n] = 8
          t[:pc] = :set
          return World.x68k?(w) ? 0x16 : 0x28
        end
        return 0xf0
      when :set # the moon sets: the rising frames backwards
        draw(w, gd, t[:a])
        t[:a] -= 9
        t[:n] -= 1
        t[:pc] = :morning if t[:n] == 0
        return 10
      when :morning
        3.times { |r| 3.times { |c| Text.put(w, w[:moon_pos] - 0x40 * r - 2 * c, 0, HUD_ATTR) } }
        w[:sounds] << SND_MORNING
        w[:night] = 0xff
        t[:pc] = :hatch
        t[:k] = 0
        t[:suspended] = true
        return 1
      when :hatch # $72dc: the cakes hatch one by one; the Wizard that had shrunk Ptolemy shrinks her again
        w[:bonus623] = false
        if t[:k] == 8
          reshrink(w, p, 0xff) if t[:wiz] == 0xff
          t[:pc] = :hush2
          next
        end
        o = w[:obj][t[:k]]
        unless o[Obj::ST] == 0xf0
          t[:k] += 1
          next
        end
        Effects.sparkle(w, 0, o[Obj::X], o[Obj::Y])
        o[Obj::ST] = 0
        t[:pc] = :hatch2
        return 7
      when :hatch2
        o = w[:obj][t[:k]]
        Cake.unmark(w, o)
        Scheduler.spawn(w, o[Obj::TASK])
        reshrink(w, p, o[Obj::TASK]) if t[:wiz] == o[Obj::TASK]
        t[:k] += 1
        t[:pc] = :hatch
        return 0x0f
      when :hush2
        t[:pc] = :hush2_wait
        return 1
      when :hush2_wait
        return 1 if w[:audio_busy]
        t[:pc] = :bgm
        return 1
      when :bgm # the round music again ($09 up to round 49, $31 after)
        w[:sounds] << (w[:round] - 1 < 0x31 ? 0x09 : 0x31)
        t[:pc] = :tick
      else
        raise "MoonTask: bad pc #{t[:pc]}"
      end
    end
  end

  # $7376: one 3x3 frame, rows of 3 tiles, attr $1c
  def self.draw(w, gd, a)
    3.times { |r| 3.times { |c| Text.put(w, w[:moon_pos] - 0x40 * r - 2 * c, gd.byte(a + 3 * r + c), 0x1c) } }
  end

  # $73a2
  def self.reshrink(w, p, id)
    w[:wizard_id] = id
    Effects.sparkle(w, 0, p[:x], p[:y])
    p[:char] = 0x1c
    p[:step_delay] = 1
    p[:speed] = 1
  end
end

# Main-loop part ($73c6, arcade $3246): while $61d is set the game's tasks are suspended and night spreads from the moon in
# 45 growing circles (attr bit 1 = the night palette), or morning shrinks back into it. The original draws all 45 rings in
# one go at CPU speed (no yields), so its pace is the CPU's; the port draws RINGS_PER_FRAME rings a frame.
module NightWipe
  # The original draws all 45 rings without yielding, so the wipe's pace is the Z80's. MEASURED in MAME (bit-1 cells of
  # the name table each frame, round 12 night + morning): a loop iteration costs ~8 units + 1 per cell plotted, ~367
  # units a frame; the first frame has 70 % of that (night) / 40 % (morning) - the moon task ran first. Fits every frame
  # within a few cells; night 34 frames, morning 35, as the arcade.
  # X68000 (MAME x68000 + the disk, $61d per video frame): night and morning both 38 frames; the 68000 runs the same loop
  # at its own pace, all inside one main-loop pass (no task pass, no $600 count, while it lasts): budget 328, no first-
  # frame share measured.
  BUDGET = 367
  FIRST = { true => 257, false => 60 }.freeze
  BUDGET_X68 = 328
  ITER = 8
  FREEZE = [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x11, 0x12, 0x13, 0x14, 0x24, 0x0f,
            0x26].freeze # $c87b (suspend) = $7516 (resume)

  def self.step(w)
    night = w[:night] == 1
    unless w[:wipe]
      FREEZE.each { |id| Scheduler.suspend(w, id) }
      budget = World.x68k?(w) ? BUDGET_X68 : BUDGET
      w[:wipe] = { r: night ? 1 : 0x2d, x: nil, y: 0, budget: budget, credit: World.x68k?(w) ? 0 : FIRST[night] - BUDGET }
    end
    wp = w[:wipe]
    if wp[:finished] # the main loop resumes the tasks on its next pass (MAME: one frame after the last ring)
      FREEZE.each { |id| Scheduler.resume(w, id) }
      w[:night] = 0
      w[:wipe] = nil
      return
    end
    wp[:credit] += wp[:budget]
    loop do
      wp[:x] ||= wp[:r] << 8
      plotted = iterate(w, wp, w[:moon_col], night)
      if plotted == :done
        wp[:r] += night ? 1 : -1
        wp[:x] = nil
        wp[:y] = 0
        plotted = 0
      end
      wp[:credit] -= ITER + plotted
      if night ? wp[:r] > 0x2d : wp[:r] < 1
        wp[:finished] = true
        return unless World.x68k?(w) # X68000: the pass ends with the wipe, the next one runs the tasks
        return step(w)
      end
      return if wp[:credit] < ITER
    end
  end

  # $741c, one loop iteration: Minsky circle of radius r (8.8 fixed point) from (x = r, y = 0): x -= y / r, y += x / r,
  # until x < 0; each point is mirrored left/right of the centre column and stops the ring once it passes name-table row
  # $1c. Returns the number of cells plotted, or :done when the ring ends.
  def self.iterate(w, wp, col, night)
    r = wp[:r]
    x = wp[:x]
    y = wp[:y]
    n = 0
    d6 = (x >> 8) & 0xff
    c = (col + d6) & 0xff
    if c < 0x20
      return :done if y > 0x1c00
      n += plot(w, (0x1c00 - y) & 0xff00, c, night)
    end
    c = col - d6
    if c >= 0
      return :done if y > 0x1c00
      n += plot(w, (0x1c00 - y) & 0xff00, c, night)
    end
    nx = x - y.idiv(r)
    return :done if nx < 0
    wp[:x] = nx
    wp[:y] = (y + nx.idiv(r)) & 0xffff
    n
  end

  # $747c: two cells (this name-table row and the next) get attr bit 1 set or cleared; returns the cells on screen
  def self.plot(w, row, col, night)
    a = 0xc001 + (row >> 2) + 2 * col
    n = 0
    [a, a + 0x40].each do |addr|
      i = Text.cell(addr)
      next if i < 0 || i >= 1024
      at = w[:bg][:attrs][i]
      w[:bg][:attrs][i] = night ? at | 2 : at & 0xfd
      w[:bg_dirty] << i
      n += 1
    end
    n
  end
end

Scheduler::IMPL[0x14] = MoonTask
