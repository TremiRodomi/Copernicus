# Title and attract mode (X68000 $22a4, arcade $6733 - the same sequence; all waits are 6-frame ticks, $24ce / $6ad0):
#   title: palette set 4, the logo's colours blacked out, logo + TAITO + copyright, two fades, the sparkle blocks, 50 ticks
#   -> the attract intermission (picture $e, "INSERT COIN(S)" instead of the message; DSW / $578 bit 4, on by default)
#   -> a demo round played by task 1e from an input script (rounds 1, 2, 62 in turn) -> BEST 5 for 50 ticks -> the title.
# main.rb switches the scenes on the end codes these tasks set. Port task ids: 46 title, 47 wait, 48 demo start,
# 49 demo watch, 4a best 5; 1e is the original's demo input task.

module Scenes
  # $724 (arcade $0d23): h, w, then h * w tile codes, rows downward from the name-table address `pos`
  def self.block(w, gd, pos, a, attr)
    h = gd.byte(a)
    n = gd.byte(a + 1)
    h.times do |r|
      n.times { |c| Text.put(w, pos - 0x40 * r - 2 * c, gd.byte(a + 2 + r * n + c), attr) }
    end
  end

  # $28f6 on the graphic palette: colour patches on top of palette set 4, kept in the world; main.rb redraws the screen
  def self.bg_patch(w, list)
    pt = w[:bg_pal] ? w[:bg_pal][:patch].dup : {}
    list.each { |i, word| pt[i & 63] = word } # arcade pens $80-$bf -> graphic colours 0-63
    w[:bg_pal] = { set: 4, patch: pt }
    w[:bg_pal_shown] = false
  end
end

# $22d8: the title screen
module TitleTask
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        t[:pc] = :black
        return 6
      when :black # $22ee: the logo's colours start black
        Scenes.bg_patch(w, gd.pal_patch(:title_black))
        t[:pc] = :draw
        return 6
      when :draw # $10c6 (arcade $0c25), then the top line ($7b8)
        Scenes.block(w, gd, 0xc62f, gd.a(:title_logo), 0xbb)
        taito(w, gd)
        Text.print(w, 0xc177, 0x39, '@ 1985 TAITO CORPORATION')
        Text.print(w, 0xc137, 0x39, '@ 1991 SPS') if World.x68k?(w)
        Hud.top(w)
        t[:k] = 0
        t[:pc] = :fade1
        return 6
      when :fade1 # one step per tick, the end seen a tick after the last
        steps = gd.pal_patch(:title_fade1)
        if t[:k] < steps.size
          Scenes.bg_patch(w, steps[t[:k]])
          t[:k] += 1
          return 6
        end
        t[:k] = 0
        t[:pc] = :fade2
        return 5 * 6 + 6
      when :fade2
        steps = gd.pal_patch(:title_fade2)
        if t[:k] < steps.size
          Scenes.bg_patch(w, steps[t[:k]])
          t[:k] += 1
          return 6
        end
        t[:k] = 0
        t[:pc] = :sparkle
        return 6
      when :sparkle # $234a: one group (one or two blocks) per tick, attr $bb
        groups = gd.title_sparkle
        if t[:k] < groups.size
          groups[t[:k]].each { |pos, a| Scenes.block(w, gd, pos, a, 0xbb) }
          t[:k] += 1
          return 6
        end
        t[:pc] = :hold
        return 50 * 6
      when :hold
        w[:end_code] = :title_done
        return :killed
      else
        raise "TitleTask: bad pc #{t[:pc]}"
      end
    end
  end

  # The arcade's (1985) TAITO logo: a 2 x 10 tile block at $c229, attr $b9 (arcade $0d0d). The X68000 drew the modern
  # TAITO logo instead, an 80 x 24 bitmap ($eee: 5 columns of 16 px, 24 rows of 16 bytes each) written into GVRAM at cell
  # (11, 22) - but its BGCHR still holds the old logo's tiles, so these codes (numbers only) give the arcade logo from the
  # disk too. With the ROMs only the old logo exists, so the X68000 behaviour keeps it there.
  OLD_TAITO = [0xd2, 0xd3, 0xd6, 0xd7, 0xda, 0xdb, 0xde, 0xdf, 0xe2, 0xe3,
               0xd4, 0xd5, 0xd8, 0xd9, 0xdc, 0xdd, 0xe0, 0xe1, 0xe4, 0xe5].freeze

  def self.taito(w, gd)
    a = gd.a(:title_taito)
    return Scenes.block(w, gd, 0xc229, a, 0xb9) if gd.version == :arcade
    unless World.x68k?(w)
      OLD_TAITO.each_with_index { |code, k| Text.put(w, 0xc229 - 0x40 * k.idiv(10) - 2 * (k % 10), code, 0xb9) }
      return
    end
    pix = Array.new(80 * 24, 0)
    5.times { |b| 24.times { |r| 16.times { |i| pix[r * 80 + b * 16 + i] = gd.byte(a + (b * 24 + r) * 16 + i) } } }
    w[:overlay] = [88, 176, 80, 24, pix]
  end
end

# A plain wait that hands main.rb an end code (the attract's "wait n ticks" between scenes)
module AttractWait
  def self.run(w, t, _gd)
    if t[:pc] == :start
      t[:pc] = :done
      return t[:frames]
    end
    w[:end_code] = t[:code]
    :killed
  end
end

# $240a: the demo round is built; 2 ticks later the enemies are loaded ($251c), Ptolemy is put at ($a0, $18) and the round's tasks
# start with task 1e at the controls (no intro, no READY, no moon)
module DemoStartTask
  def self.run(w, t, _gd)
    if t[:pc] == :start
      t[:pc] = :go
      return 2 * 6
    end
    w[:tasks][w[:running]] = nil # main-loop code holds no slot: the director's player task (01) must not land in this one
    Obj.load_list(w, w[:demo_enemies])
    p = w[:player]
    p[:x] = 0xa0
    p[:y] = 0x18
    [0, 4, 0x10, 0x0e, 0x1e].each { |id| Scheduler.spawn_main(w, id) } # (main-loop spawns: all first run next frame)
    Scheduler.spawn(w, 0x49, main: true) # $248c is main-loop code: the death sequence's $1890 must not stop it
    :killed
  end
end

# Task 1e ($8504, arcade the same): [input, ticks] pairs into $592 (active low, as $48ca returns it); 0 ends, the last
# input stays
module DemoInputTask
  def self.run(w, t, gd)
    t[:a] ||= w[:demo_script]
    v = gd.byte(t[:a])
    return :killed if v == 0
    w[:input_override] = v
    n = gd.byte(t[:a] + 1)
    t[:a] += 2
    n * 6
  end
end

# $248c: every tick, a death ($62e) or no enemies left ends the demo; 6 more ticks of play, every task stopped ($1890),
# 5 ticks frozen, then BEST 5. So a death in the demo is cut during her hit pose: no ghost bubble.
module DemoWatchTask
  def self.run(w, t, _gd)
    case t[:pc]
    when :start
      t[:pc] = :poll
      6
    when :poll
      return 6 if w[:end_code] == 0 && (w[:enemies_left] & 0x7f) != 0
      t[:pc] = :stop
      6 * 6
    when :stop
      Scheduler.kill_others(w)
      t[:pc] = :frozen
      5 * 6
    else
      w[:end_code] = :demo_done
      :killed
    end
  end
end

# $2bd4: BEST 5 for 50 ticks, then the title again
module Best5Task
  def self.run(w, t, _gd)
    if t[:pc] == :start
      Hud.top(w)
      Text.print(w, 0xc5e5, 0x3a, 'BEST 5')
      Scenes.table(w, w[:save])
      t[:pc] = :done
      return 50 * 6
    end
    w[:end_code] = :best5_done
    :killed
  end
end

# Power-on ($1e22 / arcade $0204): sound $14 (the boot / sun jingle), then wait while it plays - at most 50 ticks - before
# the attract starts (port task 4c)
module BootTask
  def self.run(w, t, _gd)
    if t[:pc] == :start && t[:splash] # X68000: the picture stays up while the disk loads (stand-in: 1.5 s)
      t[:pc] = :jingle
      return 90
    end
    if t[:pc] == :start || t[:pc] == :jingle
      w[:sounds] << 0x14
      t[:n] = 50 * 6
      t[:pc] = :wait
      return 2 # the sound starts this frame; the busy flag is set from the next one
    end
    t[:n] -= 1
    return 1 if w[:audio_busy] && t[:n] > 0
    w[:end_code] = :boot_done
    :killed
  end
end

Scheduler::IMPL[0x4c] = BootTask
Scheduler::IMPL[0x46] = TitleTask
Scheduler::IMPL[0x47] = AttractWait
Scheduler::IMPL[0x48] = DemoStartTask
Scheduler::IMPL[0x1e] = DemoInputTask
Scheduler::IMPL[0x49] = DemoWatchTask
Scheduler::IMPL[0x4a] = Best5Task
