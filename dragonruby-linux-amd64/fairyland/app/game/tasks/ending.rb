# The ending (after the Dracolisk crumbles). Arcade and X68000 run the same sequence (arcade $898b / $8a1e / $8b4b / $8b8b).
#   2c ($99b6) the Holy Gem where the Dracolisk fell, flashing through 10 colour steps
#   2d ($9a36) Ptolemy (input taken over) walks down and over to the gem, celebrates, and keeps jumping for joy
#   0d ($5ff2) a banner of big sprites at the top, its colour cycling
#   42 (port id; the original runs $3722 from the main loop) waits for her to reach the gem, then palette set 4, +1,000,000,
#      the ending music and the text typed out, then game over (name entry)
module GemTask
  def self.run(w, t, gd)
    d = w[:drac]
    case t[:pc]
    when :start
      t[:pc] = :show
      0x14
    when :show
      w[:sounds] << 0x38
      Shadow.set_c(w, gd, 0xf2, d[:y], d[:x])
      t[:k] = 0
      t[:pc] = :flash
      7
    when :flash # every 7 frames the next of 10 colour steps, forever
      gd.pal_patch(:gem)[t[:k]].each { |i, c| w[:pal_patch][i] = c }
      t[:k] = (t[:k] + 1) % 10
      7
    end
  end
end

module FinaleTask
  LEFT = 0xfb  # input with "left" (+x) held
  RIGHT = 0xf7

  def self.run(w, t, gd)
    p = w[:player]
    d = w[:drac]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $9a36
        w[:input_override] = 0xff
        d[:b0] = 0xff
        t[:pc] = :settle
        return 1
      when :settle # wait until she stands on something, then four jumps for joy
        return 1 unless p[:y] & 7 == 0 && PlayerTask.ground?(w, p, p[:x], p[:y])
        Scheduler.suspend(w, 1)
        t[:n] = 4
        t[:after] = :walk
        t[:pc] = :jump
      when :jump # $9ba0 / $9b88: one jump from the table, then 15 frames
        # $5b1 (arcade $e635) gates the jump sound: cleared at the defeat, so both versions play it; the arcade's ending
        # sets it ($8bff, with the $13 music) so her jumps go silent once the screen is black - the X68000 never does
        w[:sounds] << 0x16 if d[:b1] == 0
        t[:a] = gd.a(:finale_jump)
        t[:pc] = :jump_frame
      when :jump_frame
        Shadow.set_a(w, gd, gd.byte(t[:a] + 1), (p[:y] + gd.byte(t[:a])) & 0xff, p[:x])
        t[:a] += 2
        t[:pc] = :jump_check
        return 1
      when :jump_check # the end of the table is tested AFTER the 1-frame wait (X68000 $9a88, arcade $8a4c): 36 + 15 frames
        if gd.byte(t[:a]) >= 0x80
          t[:n] -= 1
          t[:pc] = t[:n] > 0 ? :jump : t[:after]
          return 0x0f
        end
        t[:pc] = :jump_frame
      when :walk # $9a98: down from ledge to ledge, then over to where the Dracolisk fell
        Scheduler.resume(w, 1)
        if p[:y] >= 0x19
          w[:input_override] = p[:x] < 0x80 ? LEFT : RIGHT
          t[:y] = p[:y]
          t[:pc] = :step_off
          return 1
        end
        t[:target] = (d[:x] - 0x0c) & 0xff
        w[:input_override] = t[:target] >= p[:x] ? LEFT : RIGHT
        t[:pc] = :approach
      when :step_off
        return 1 if p[:y] == t[:y]
        t[:pc] = :walk
      when :approach
        arrived = w[:input_override] == LEFT ? p[:x] >= t[:target] : p[:x] < t[:target]
        return 1 unless arrived
        Scheduler.kill(w, 1) # $9b0c: she has the gem
        d[:b0] = 0
        t[:n] = 4
        t[:after] = :pause
        t[:pc] = :jump
      when :pause # then bursts of 1-4 jumps, forever
        t[:n] = (rnd(w) & 3) + 1
        t[:after] = :rest
        t[:pc] = :jump
        return 0x28
      when :rest
        t[:pc] = :pause_again
        return 0x1e
      when :pause_again
        t[:n] = 4
        t[:after] = :pause
        t[:pc] = :jump
      else
        raise "FinaleTask: bad pc #{t[:pc]}"
      end
    end
  end

  def self.rnd(w)
    World.x68k?(w) ? World.rand(w) : World.r_reg(w)
  end
end

module BannerTask
  def self.run(w, t, gd)
    case t[:pc]
    when :start
      t[:pc] = :show
      0x78
    when :show
      slot = Shadow.set_d(w, gd, 0x8d, 0xa8, 0x98, 0x28, 0xf1)
      6.times { |k| slot = Shadow.set_d(w, gd, 0x93, 0xa8, (0x88 - 0x10 * k) & 0xff, slot, 0xf1) }
      t[:k] = 0
      t[:pc] = :cycle
      1
    when :cycle # every 2 frames the next colour
      steps = gd.pal_patch(:banner)
      steps[t[:k] % steps.size].each { |i, c| w[:pal_patch][i] = c }
      t[:k] += 1
      2
    end
  end
end

module EndingTask
  UNIT = 6 # $2b2 / arcade $04f1: waits count in 6-frame units

  def self.run(w, t, gd)
    g = w[:game]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $3722: wait until Ptolemy has the gem
        return 1 if w[:drac][:b0] != 0
        t[:pc] = :dim
        return 30 * UNIT
      when :dim # $372c: the screen below the scores is cleared, banner away, palette set 4 with colour 63 cyan
        w[:hud_off] = true
        clear_screen(w)
        Scheduler.kill(w, 0x0d)
        12.times { |k| Shadow.clear(w, 0x28 + 4 * k) }
        idx, word = gd.pal_patch(:end_bg)[0]
        w[:bg_pal] = { set: 4, patch: { (idx & 63) => word } }
        g[:score] = [g[:score] + 100_000, 999_999].min # + $10 in the top BCD byte: 1,000,000 on screen
        Hud.score(w)
        t[:pc] = :music
        return 10 * UNIT
      when :music
        clear_screen(w) # $37aa: cleared again before the text
        w[:sounds] << 0x13
        w[:drac][:b1] = 0x13 if w[:drac] && !World.x68k?(w) # arcade $8bff: the jumps for joy go silent from here
        t[:a] = gd.a(:ending_text)
        t[:segs] = [[0xc5f1, 10], [0xc4f3, nil], [:number, 10], [0xc17b, 60]]
        t[:pc] = :segment
      when :segment
        seg = t[:segs].shift
        unless seg
          t[:pc] = :done
          next
        end
        pos, t[:wait] = seg
        if pos == :number # $982: the rounds, then the rest of the paragraph
          '101'.each_char { |ch| Text.put(w, t[:pos], ch.ord, t[:attr]); t[:pos] -= 2 }
        else
          t[:pos] = pos
        end
        t[:pc] = :char
        return UNIT
      when :char # $3832: one byte per 6 frames: 0 ends the block, $f0 n moves back n, $f1 n sets the attribute
        b = gd.byte(t[:a])
        t[:a] += 1
        case b
        when 0
          t[:pc] = :segment
          return t[:wait] ? t[:wait] * UNIT : 1
        when 0xf0
          t[:pos] -= gd.byte(t[:a])
          t[:a] += 1
        when 0xf1
          t[:attr] = gd.byte(t[:a])
          t[:a] += 1
        else
          Text.put(w, t[:pos], b, t[:attr])
          t[:pos] -= 2
        end
        return UNIT
      when :done # $37fa: kill everything, clear the sprites ($1a2e) and the screen below the scores ($706), then the
        # caller's GAME OVER without its jingle ($2148 -> $21ea)
        Scheduler.kill_others(w)
        w[:shadow].map! { nil } # (mruby: fill(nil) counts as no argument)
        clear_screen(w)
        w[:input_override] = nil
        w[:round] += 1 # $3814: 102 = "ALL" in the best-5 table
        w[:end_code] = :game_over
        return :killed
      else
        raise "EndingTask: bad pc #{t[:pc]}"
      end
    end
  end
end

module EndingTask
  # $706 / arcade $0b9b: name-table offsets $000-$6ff = screen rows 4-31 (the HUD's top four rows stay)
  def self.clear_screen(w)
    (128...1024).each do |i|
      w[:bg][:tiles][i] = 0
      w[:bg][:attrs][i] = 0
      w[:bg_dirty] << i
    end
  end
end

Scheduler::IMPL[0x2c] = GemTask
Scheduler::IMPL[0x2d] = FinaleTask
Scheduler::IMPL[0x0d] = BannerTask
Scheduler::IMPL[0x42] = EndingTask
