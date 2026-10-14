# Small round tasks: hit sparkles (10), score popups (18), the button-release watcher (0e) and the Wizard's death (16).
module Effects
  SND_SPARK = 0x22
  SND_FIRE = 0x1e

  # $7b9e (type 0, sound $22) / $7be4 (type 4, sound $1e): start a sparkle in a free slot of $601, else replace the oldest
  def self.sparkle(w, type, x, y)
    w[:sounds] << (type == 4 ? SND_FIRE : SND_SPARK)
    sl = w[:sparkles]
    e = sl.find { |s| s[0] == 0 } || sl.min_by { |s| s[0] } # the original picks the smallest timer, earliest on ties
    e.replace([4, type, x, y])
  end

  # $69ec / $6a44 popup entry: [timer, kind, shadow slot, y, x]; silently dropped when all 8 are busy
  def self.add_popup(w, e)
    i = w[:popups].index { |p| p[0] == 0 }
    w[:popups][i] = e if i
  end
end

# Task 10 ($6a9a): three sparkle slots, one frame every 7 frames, drawn at shadow slots $5c/$64/$6c
module SparkleTask
  FRAMES = :sparkle_frames

  def self.run(w, t, gd)
    if t[:pc] == :start
      w[:sparkles].each { |s| s.fill(0) }
      t[:pc] = :loop
      return 1
    end
    slot = 0x5c
    w[:sparkles].each do |s|
      n = (s[0] - 1) & 0xff
      if n >= 0x80 # `subq.b #1; bpl`: 0 = idle, and $ff (the Dracolisk fight keeps slots 1-2 so) = disabled
        Shadow.clear(w, slot)
        Shadow.clear(w, slot + 4)
        slot += 8
        next
      end
      s[0] = n
      slot = Shadow.set_b(w, gd, gd.byte(gd.a(FRAMES) + n + s[1]), s[3], s[2], slot, :meta_poses)
    end
    7
  end
end

# Task 18 ($7d98): score popups. Every 10 frames each timer counts down; the popup appears at 5 and is removed at 0.
module PopupTask
  DIGITS = :popup_digits # two sprite codes per popup kind

  def self.run(w, t, gd)
    if t[:pc] == :start
      w[:popups].each { |p| p.fill(0) }
      t[:pc] = :loop
      return 1
    end
    w[:popups].each do |p|
      next if p[0] == 0
      p[0] -= 1
      if p[0] == 0
        Shadow.clear(w, p[2])
        Shadow.clear(w, p[2] + 4)
      elsif p[0] == 5
        i = p[2] >> 2
        a = gd.a(DIGITS) + 2 * p[1]
        Shadow.single(w, i, gd.byte(a), 0xe0, (p[3] - 0xf2) & 0xff, (p[4] - 3) & 0xff)
        Shadow.single(w, i + 1, gd.byte(a + 1), 0xe0, (p[3] - 0xf2) & 0xff, (p[4] + 0x0d) & 0xff)
      end
    end
    0x0a
  end
end

# Task 0e ($605c): releasing jump re-arms jumping ($62f), releasing spell resets the spell repeat delay ($597); then the
# theme's little background animation by $593 (= the round's theme): flags waving / candles flickering, by swapping the
# tile codes of a few name-table cells (attributes kept). Its delay is also how often releases are noticed.
module ReleaseTask
  def self.run(w, t, gd)
    inp = World.input(w)
    w[:player][:latch] = 0 if inp & 2 != 0
    w[:spell_delay] = 0 if inp & 1 != 0
    case w[:mode593]
    when 0 # $6094: two cells, codes $bc / $bd
      code = toggle(w) ? 0xbd : 0xbc
      [0xc4ff, 0xc4c1].each { |a| Text.put(w, a, code, attr(w, a)) }
      7
    when 2 # $60c8: two cell pairs at the top corners, mirrored
      a, b = toggle(w) ? [0x8a, 0x8b] : [0x5b, 0x5c]
      Text.put(w, 0xc77f, a, attr(w, 0xc77f))
      Text.put(w, 0xc77d, b, attr(w, 0xc77f)) # the original keeps d1 from the first cell
      Text.put(w, 0xc743, b, attr(w, 0xc743))
      Text.put(w, 0xc741, a, attr(w, 0xc743))
      4
    when 3 # $6116: fixed attributes $58 / $98
      a, b, at = toggle(w) ? [0x20, 0x21, 0x98] : [0xf1, 0xf3, 0x58]
      Text.put(w, 0xc77d, a, at)
      Text.put(w, 0xc741, b, at)
      3
    else
      6
    end
  end

  def self.toggle(w)
    w[:anim6f3] ^= 1
    w[:anim6f3] != 0
  end

  def self.attr(w, addr)
    w[:bg][:attrs][Text.cell(addr)]
  end
end

# Task 16 ($7b6c): the Wizard is gone: sparkle on Ptolemy, wait 15 frames, she is back to normal size and speed
module WizardGoneTask
  def self.run(w, t, gd)
    p = w[:player]
    if t[:pc] == :start
      t[:x] = p[:x]
      t[:y] = p[:y]
      Effects.sparkle(w, 0, t[:x], t[:y])
      w[:wizard_id] = 0
      t[:pc] = :grow
      return 0x0f
    end
    p[:step_delay] = 3
    p[:speed] = 2
    p[:char] = 0
    # the original kills itself and then runs on into $7b9e: a second sparkle where the first one was
    Effects.sparkle(w, 0, t[:x], t[:y])
    :killed
  end
end

Scheduler::IMPL[0x10] = SparkleTask
Scheduler::IMPL[0x18] = PopupTask
Scheduler::IMPL[0x0e] = ReleaseTask
Scheduler::IMPL[0x16] = WizardGoneTask
