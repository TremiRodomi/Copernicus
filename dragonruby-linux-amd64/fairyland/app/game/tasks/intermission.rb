# Task 25 ($896e, arcade $772b): Ptolemy rides her dragon Rodomy across the intermission picture towards the castle of the
# coming theme. Two animation channels (Ptolemy, Rodomy: [time, frame] tables) drawn with $1b8e at y $70 + a bob, x from
# $80 moving w[:inter_speed] px a frame (8 after a Mystical Feather warp); the priority bit on 4-column strips flips as
# she passes, so she flies behind / in front of parts of the picture.
module IntermissionTask
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        t[:ch] = [[1, 0, 0], [1, 0, 0]] # [timer, index, frame]
        t[:bob] = 0
        t[:x] = 0x80
        prio(w, 0xc5bf, 12, 16, true)
        t[:pc] = :fly_a
      when :fly_a # until x wraps to 0
        fly(w, t, gd)
        t[:pc] = t[:x] == 0 ? :strips_out : :fly_a
        return 1
      when :strips_out # X68000: 4 strips lose their priority on consecutive frames; arcade ($7756): all 16 columns at once
        t[:k] ||= 0
        prio(w, 0xc5a7 + 8 * t[:k], 12, 4, false)
        t[:k] += 1
        (prio(w, 0xc5a7 + 8 * t[:k], 12, 4, false); t[:k] += 1) while t[:k] < 4 && !World.x68k?(w)
        fly(w, t, gd)
        if t[:k] == 4
          t[:k] = nil
          t[:pc] = :fly_b
        end
        return 1
      when :fly_b # until x reaches $80
        fly(w, t, gd)
        t[:pc] = :strips_in if t[:x] == 0x80
        return 1
      when :strips_in # likewise ($7770: $c55f 15 x 16 at once)
        t[:k] ||= 0
        prio(w, 0xc547 + 8 * t[:k], 15, 4, true)
        t[:k] += 1
        (prio(w, 0xc547 + 8 * t[:k], 15, 4, true); t[:k] += 1) while t[:k] < 4 && !World.x68k?(w)
        fly(w, t, gd)
        if t[:k] == 4
          t[:pc] = :fly_c
        end
        return 1
      when :fly_c # until x wraps to 0 again
        fly(w, t, gd)
        if t[:x] == 0
          w[:shadow].map! { nil } # (mruby: fill(nil) counts as no argument)
          t[:pc] = :wait_music
        end
        return 1
      when :wait_music
        # $2818 goes on as soon as task 25 ends, cutting the X68000's longer Round Demo song; as with the round clear,
        # on a real X68000 the music finishes first (user): with an X68000 soundtrack, wait for it
        # (not after a warp: no Round Demo music was started, and the round's looping BGM would keep the wait going for ever)
        return 1 if w[:inter_speed] == 1 && w[:audio_busy] && %i[original arrange].include?(w[:opts] && w[:opts][:music])
        t[:pc] = :done
        # X68000 after a warp: MAME's x68000 shows the fast intermission 3 frames longer (52 vs 49; the 10 MHz machine's
        # lag while the flyer is drawn - where exactly is not known, so the frames are added at the end)
        return 3 if w[:inter_speed] != 1 && World.x68k?(w)
      when :done
        w[:end_code] = :intermission_done
        return :killed
      else
        raise "IntermissionTask: bad pc #{t[:pc]}"
      end
    end
  end

  # $8ae8: draw, then move on
  def self.fly(w, t, gd)
    r = World.x68k?(w) ? World.rand(w) : World.r_reg(w) # arcade: LD A,R ($7795)
    t[:bob] = (t[:bob] + 1) % 0x90 if r & 1 != 0
    bob = gd.byte(gd.a(:fly_bob) + (t[:bob] >> 2))
    [[:fly_ch1, 5], [:fly_ch2, 4]].each_with_index do |(tab, n), k|
      c = t[:ch][k]
      c[0] -= 1
      if c[0] == 0
        c[1] = (c[1] + 1) % n
        c[0] = gd.byte(gd.a(tab) + 2 * c[1])
        c[2] = gd.byte(gd.a(tab) + 2 * c[1] + 1)
      end
      Shadow.set_c(w, gd, c[2], (0x70 + bob) & 0xff, t[:x])
    end
    t[:x] = (t[:x] + w[:inter_speed]) & 0xff
  end

  # $9b8 / $a6a: the priority bit on rows x cols cells from a name-table address
  def self.prio(w, addr, rows, cols, on)
    c0 = Text.cell(addr)
    rows.times do |r|
      cols.times do |c|
        i = c0 + 32 * r + c
        next if i < 0 || i >= 1024
        a = w[:bg][:attrs][i]
        w[:bg][:attrs][i] = on ? a | 0x20 : a & 0xdf
        w[:bg_dirty] << i
      end
    end
  end
end

Scheduler::IMPL[0x25] = IntermissionTask
