# Game over, best-5 name entry and the continue screen (X68000 $21ea / $2d84 / $2cc0, arcade $047a / $6f18 / $8c7c - the
# same sequence). Port task ids: 43 game over text, 44 name entry, 45 continue; task 02 is the original's "ENTER YOUR
# INITIALS !" flyer. Each finishes by setting w[:end_code] for main.rb to move on.

# $21de: sound $10, then $21ea: "PLAYER<1>GAME OVER", 38 x 6 frames. After the ending the caller jumps straight to
# $21ea: no jingle (t[:silent])
module GameOverTask
  def self.run(w, t, gd)
    if t[:pc] == :start
      w[:sounds] << 0x10 unless t[:silent]
      Text.print(w, 0xc4b3, 0x39, 'PLAYER< > GAME OVER')
      Text.print(w, 0xc4a5, 0x38, '1')
      t[:pc] = :done
      return 38 * 6
    end
    w[:end_code] = :game_over_done
    :killed
  end
end

module Scenes
  ROWS = [0xc3b5, 0xc335, 0xc2b5, 0xc235, 0xc1b5].freeze
  RANKS = ['1ST ', '2ND ', '3RD ', '4TH ', '5TH '].freeze

  # $2cac: the round reached, +1; 101 cleared = "ALL"
  def self.round_text(idx)
    idx + 1 >= 0x66 ? 'ALL' : (idx + 1).to_s.rjust(3)
  end

  # $2bf0: the best-5 table (the slot being entered, `skip`, stays blank)
  def self.table(w, d, skip = nil)
    Text.print(w, 0xc429, 0x39, 'SCORE ROUND NAME')
    ROWS.each_with_index do |a, k|
      Text.print(w, a, 0x39, RANKS[k])
      next if k == skip
      score, round, name = d[:table][k]
      p = a - 8
      Text.print(w, p, 0x39, Hud.digits(score) + '0')
      p -= 14 + 6
      Text.print(w, p, 0x39, round_text(round))
      Text.print(w, p - 6 - 4, 0x39, name)
    end
  end

  # $706: clear screen rows 4-31
  def self.clear(w)
    (128...1024).each do |i|
      w[:bg][:tiles][i] = 0
      w[:bg][:attrs][i] = 0
      w[:bg_dirty] << i
    end
  end

  # $382c: a text block at once (0 ends, $f0 n = back n, $f1 n = attribute)
  def self.text(w, gd, a, pos)
    attr = 0x39
    loop do
      b = gd.byte(a)
      a += 1
      case b
      when 0 then return
      when 0xf0 then pos -= gd.byte(a); a += 1
      when 0xf1 then attr = gd.byte(a); a += 1
      else
        Text.put(w, pos, b, attr)
        pos -= 2
      end
    end
  end
end

# $2d84: name entry (ARCADE mode only - the only mode whose high scores are kept)
module NameEntryTask
  def self.run(w, t, gd)
    d = w[:save]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        Hud.top(w)
        w[:sounds] << 0x11
        Scenes.table(w, d, w[:entry_index])
        w[:initials_busy] = true
        Scheduler.spawn(w, 0x02)
        t[:pc] = :wait_initials
        return 1
      when :wait_initials
        return 1 if w[:initials_busy]
        t[:pc] = :header
        return 7 * 6
      when :header
        Text.print(w, 0xc571, 0x39, 'SCORE  ROUND  NAME')
        Text.print(w, 0xc4f5, 0x39, Hud.digits(w[:game][:score]) + '0')
        Text.print(w, 0xc4df, 0x39, Scenes.round_text(w[:entry_round]))
        t[:pos] = 0xc4d3
        t[:left] = 3
        t[:wheel] = 0
        t[:timeout] = 0x64
        t[:rep] = 2
        t[:latch] = 0
        t[:name] = ''
        t[:pc] = :entry
      when :entry # every 6 frames: the wheel ($2eea), the button ($2f3c), the timeout
        letters = gd.a(:name_letters)
        n = 0
        n += 1 while gd.byte(letters + n) != 0
        inp = World.input(w)
        lr = (~inp) & 0x0c
        if lr != 0
          t[:rep] -= 1
          if t[:rep] == 0
            t[:rep] = 2
            t[:wheel] = lr & 8 != 0 ? (t[:wheel] + 1) % n : (t[:wheel] - 1) % n
            t[:timeout] = 0x64
          end
        else
          t[:rep] = 1
        end
        letter = gd.byte(letters + t[:wheel])
        Text.put(w, t[:pos], letter, 0x3a)
        if (~inp) & 3 != 0
          if t[:latch] == 0
            t[:latch] = 0xff
            Text.put(w, t[:pos], letter, 0x39)
            t[:name] << letter.chr
            t[:pos] -= 2
            t[:wheel] = 0
            t[:timeout] = 0x64
            t[:left] -= 1
            if t[:left] == 0
              t[:pc] = :done
              next
            end
          end
        else
          t[:latch] = 0
        end
        t[:timeout] -= 1
        t[:pc] = :done if t[:timeout] == 0
        return 6
      when :done # the "SEX" filter ($bd57 compared backwards -> "H !"), sound 4, then BEST 5
        name = t[:name].ljust(3)
        f = gd.a(:name_filter)
        name = 'H !' if t[:left] == 0 && name == (0..2).map { |i| gd.byte(f + 2 - i).chr }.join
        d[:table][w[:entry_index]][2] = name
        w[:sounds] << 0x04
        t[:pc] = :best
        return 10 * 6
      when :best # $2bd4
        Hud.top(w)
        Scenes.clear(w)
        Text.print(w, 0xc5e5, 0x3a, 'BEST 5')
        Scenes.table(w, d)
        t[:pc] = :save
        return 40 * 6
      when :save # $2adc: written to disk
        Save.write(d)
        w[:end_code] = :name_done
        return :killed
      else
        raise "NameEntryTask: bad pc #{t[:pc]}"
      end
    end
  end
end

# Task 02 ($4904): a sign block, then sprite $40 flies across writing "ENTER YOUR INITIALS !" one letter per 8 px
module InitialsTask
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        block(w, 0xc687, 0x5c)
        t[:x] = 0
        t[:n] = 0x24
        t[:pc] = :fly1
      when :fly1
        Shadow.set_c(w, gd, 0x40, 0xb8, t[:x])
        t[:x] = (t[:x] - 2) & 0xff
        t[:n] -= 1
        t[:pc] = :swap if t[:n] == 0
        return 1
      when :swap
        block(w, 0xc687, 0)
        block(w, 0xc6bf, 0x5c)
        t[:x] = 0xb8
        t[:a] = gd.a(:initials_msg)
        t[:pos] = 0xc633
        t[:pc] = :write
      when :write # a letter, then fly on; every 8 px the next letter
        b = gd.byte(t[:a])
        if b != 0
          t[:a] += 1
          Text.put(w, t[:pos], b, 0x1a)
          t[:pos] -= 2
        end
        t[:pc] = :fly2
      when :fly2
        Shadow.set_c(w, gd, 0x40, 0xb8, t[:x])
        t[:x] = (t[:x] - 2) & 0xff
        if t[:x] == 0xe0
          w[:shadow].map! { nil }
          w[:initials_busy] = false
          return :killed
        end
        t[:pc] = :write if t[:x] & 7 == 0
        return 1
      else
        raise "InitialsTask: bad pc #{t[:pc]}"
      end
    end
  end

  # $782 / $79c: a 4 x 4 block of one tile, attr $3b
  def self.block(w, addr, tile)
    4.times { |r| 4.times { |c| Text.put(w, addr - 0x40 * r - 2 * c, tile, 0x3b) } }
  end
end

# $2cc0: the continue screen - the text, then 10..1, one per 60 frames; JUMP or SPELL continues (free play)
module ContinueTask
  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        Hud.top(w)
        Scenes.text(w, gd, gd.a(:continue_text), 0xc62f)
        t[:n] = 10
        t[:pc] = :count
      when :count
        Text.print(w, 0xc1e1, 0x38, t[:n].to_s.rjust(3))
        t[:k] = 10
        t[:pc] = :tick
      when :tick
        if (~World.input(w)) & 3 != 0
          w[:end_code] = :continue_yes
          return :killed
        end
        t[:k] -= 1
        if t[:k] == 0
          t[:n] -= 1
          if t[:n] == 0
            w[:end_code] = :continue_no
            return :killed
          end
          t[:pc] = :count
        end
        return 6
      else
        raise "ContinueTask: bad pc #{t[:pc]}"
      end
    end
  end
end

Scheduler::IMPL[0x43] = GameOverTask
Scheduler::IMPL[0x44] = NameEntryTask
Scheduler::IMPL[0x02] = InitialsTask
Scheduler::IMPL[0x45] = ContinueTask
