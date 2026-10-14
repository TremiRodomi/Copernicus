# Task 26 ($8b76, arcade $7b08 - same code): the Worm, which lives behind the arched door of 12 rounds ($ff entries in the
# enemy list; door position $6f5/$6f6). Invincible. When Ptolemy stands in front of the door (same level, up to 76 px on
# its +x side) it opens the door, slides out (less each time it comes out hungry - worm_lengths 16 16 8 2 2 8 2 - until
# it only throws its tongue),
# pushing Ptolemy and enemies ahead of it, opens its mouth and lunges: the first enemy (7000 points) - or Ptolemy (a lost
# life, no death scene) - in reach is eaten and chewed while it retracts. The wall around the door gets the priority
# bit while it is out, so the body is hidden behind the door frame.
module WormTask
  SND_LUNGE = 0x32
  BODY_SLOTS = 0x34 # 7 slots $34-$4c
  MOUTH_SLOTS = 0x40

  def self.run(w, t, gd)
    p = w[:player]
    dx, dy = w[:door]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        t[:len] = 0 # $6fb
        t[:pc] = :reset
      when :reset # $8b7c
        w[:flag6f4] = 0
        t[:ate] = 0 # $6f8: 0, the eaten enemy's sprite slot, or 4 = Ptolemy
        t[:pc] = :poll_wait
        return 0x5a
      when :poll_wait
        t[:pc] = :poll
        return 7
      when :poll # $8b96
        t[:pc] = :poll_wait
        next if w[:t611] != 0 || w[:enemies_left] & 0x7f == 0
        next unless (p[:y] - dy).abs < 8 && ((p[:x] - dx) & 0xff) < 0x4d
        if w[:door_pair] && (w[:door_pair][0, 2] == [dx, dy] || w[:door_pair][2, 2] == [dx, dy])
          Scheduler.suspend(w, 0x20) # $8bc6: its door is also a teleport door
        end
        w[:flag6f4] = 0xff
        block(w, gd, RoundBuilder.cell_at(dx, dy), w[:mode593] == 2 ? :door_open2 : :door_open, 0x19)
        priority(w, dx, dy, true)
        t[:anim] = 2 # $6f7
        t[:x] = dx
        t[:y] = dy
        t[:n] = length(gd, t)
        t[:pc] = :extend
      when :extend # $8c36: one body frame, 6 frames of pushing, 2 px further out
        body(w, gd, t)
        t[:k] = 6
        t[:pc] = :extend_push
      when :extend_push
        push(w, t)
        t[:k] -= 1
        t[:pc] = :extend_next if t[:k] == 0
        return 1
      when :extend_next
        t[:x] = (t[:x] + 2) & 0xff
        t[:n] -= 1
        if t[:n] == 0
          t[:k] = 15
          t[:pc] = :hold
        else
          t[:pc] = :extend
        end
      when :hold
        push(w, t)
        t[:k] -= 1
        t[:pc] = :mouth if t[:k] == 0
        return 1
      when :mouth # $8c68
        t[:x] = (t[:x] - 2) & 0xff
        if w[:enemies_left] & 0x7f == 0
          t[:pc] = :retract_init
          next
        end
        Shadow.set_c(w, gd, 0xe8, t[:y], t[:x])
        w[:sounds] << SND_LUNGE
        t[:a] = gd.a(:worm_lunge)
        t[:pc] = :wind_up
      when :wind_up # [dx, frame] pairs until 0, 4 frames each (the head draws back)
        d = gd.byte(t[:a])
        t[:a] += 1
        if d == 0
          t[:pc] = :lunge
          next
        end
        Shadow.set_c(w, gd, gd.byte(t[:a]), t[:y], (t[:x] + d) & 0xff)
        t[:a] += 1
        t[:k] = 4
        t[:pc] = :wind_up_push
      when :wind_up_push
        push(w, t)
        t[:k] -= 1
        t[:pc] = :wind_up if t[:k] == 0
        return 1
      when :lunge # $8cb6: [dx, frame] pairs until a negative dx, 2 frames each; eats on the way
        d = gd.byte(t[:a])
        t[:a] += 1
        if d >= 0x80
          t[:pc] = :lunge_end
          next
        end
        hx = (t[:x] + d) & 0xff
        Shadow.set_c(w, gd, gd.byte(t[:a]), t[:y], hx)
        bite(w, gd, t, p, hx) if t[:ate] == 0
        Shadow.set_b(w, gd, t[:sprite], t[:y], (hx - 8) & 0xff, t[:ate], :meta_poses) if t[:ate] != 0
        t[:k] = 2
        t[:pc] = :lunge_push
      when :lunge_push
        push(w, t)
        t[:k] -= 1
        if t[:k] == 0
          t[:a] += 1
          t[:pc] = :lunge
        end
        return 1
      when :lunge_end # $8db4
        3.times { |k| Shadow.clear(w, MOUTH_SLOTS + 4 * k) }
        if t[:ate] == 0
          t[:pc] = :retract_init
          next
        end
        if t[:ate] == 4 # Ptolemy: the music stops, her power-up glow ends
          w[:sounds] << 0x0f
          Scheduler.kill(w, 0x1d)
          PalPatch.apply(w, gd, :normal)
        end
        t[:n] = 6
        t[:pc] = :chew
      when :chew
        eaten(w, gd, t)
        t[:k] = 10
        t[:pc] = :chew_push
      when :chew_push
        push(w, t)
        t[:k] -= 1
        if t[:k] == 0
          t[:n] -= 1
          t[:pc] = t[:n] == 0 ? :retract_init : :chew
        end
        return 1
      when :retract_init # $8e12
        t[:n] = length(gd, t)
        t[:pc] = :retract
      when :retract
        eaten(w, gd, t)
        body(w, gd, t)
        t[:k] = 9
        t[:pc] = :retract_push
      when :retract_push
        push(w, t)
        t[:k] -= 1
        if t[:k] == 0
          t[:x] = (t[:x] - 2) & 0xff
          t[:n] -= 1
          t[:pc] = t[:n] == 0 ? :retract_end : :retract
        end
        return 1
      when :retract_end # $8e3a
        7.times { |k| Shadow.clear(w, BODY_SLOTS + 4 * k) }
        t[:pc] = :after
        return 1
      when :after # $8e50: came back hungry -> longer next time; else the eaten sprites go
        t[:pc] = :close
        if t[:ate] == 0
          t[:len] = (t[:len] + 1) % 7
        else
          Shadow.clear(w, t[:ate])
          Shadow.clear(w, t[:ate] + 4)
          return 1
        end
      when :close # $8e7a: the wall loses its priority, the door closes
        priority(w, dx, dy, false)
        Scheduler.resume(w, 0x20)
        block(w, gd, RoundBuilder.cell_at(dx, dy), w[:mode593] == 2 ? :door_blk2 : :door_blk, w[:mode593] == 2 ? 0x59 : 0x19)
        if t[:ate] == 0
          t[:pc] = :reset
        elsif t[:ate] == 4
          t[:pc] = :ate_ptolemy
          return 0x32
        else # $8eb8: 7000 points at the door, 1 EXP, one enemy fewer; the shrinking Wizard eaten -> Ptolemy grows back
          Score.popup(w, 0x0a, 6, t[:ate], dy, dx)
          Score.exp(w, 1)
          w[:enemies_left] = (w[:enemies_left] - 1) & 0xff
          Scheduler.spawn(w, 0x16) if t[:eaten_id] == w[:wizard_id]
          t[:pc] = :reset
        end
      when :ate_ptolemy # $8eee: the life is simply over
        w[:end_code] = 0xff
        return :killed
      else
        raise "WormTask: bad pc #{t[:pc]}"
      end
    end
  end

  def self.length(gd, t)
    gd.byte(gd.a(:worm_lengths) + t[:len])
  end

  # $8f26: next of the 4 body frames at the head position
  def self.body(w, gd, t)
    t[:anim] = (t[:anim] + 1) & 3
    Shadow.set_c(w, gd, gd.byte(gd.a(:worm_anim) + t[:anim]), t[:y], t[:x])
  end

  # $8f04: the eaten enemy / Ptolemy in the mouth, wiggling with the counter
  def self.eaten(w, gd, t)
    return if t[:ate] == 0
    Shadow.set_b(w, gd, (t[:sprite] + (t[:n] & 1)) & 0xff, t[:y], (t[:x] - 8) & 0xff, t[:ate], :meta_poses)
  end

  # $8cd0: the first enemy (states 1-8) or else Ptolemy within reach of the head is swallowed
  def self.bite(w, gd, t, p, hx)
    w[:obj].each do |o|
      next unless ((o[Obj::ST] - 1) & 0xff) < 8
      next unless ((o[Obj::Y] - t[:y]) & 0xff) < 0x0a && ((o[Obj::X] - hx) & 0xff) >= 0xf0
      t[:eaten_id] = o[Obj::TASK] # $6fa
      Scheduler.kill(w, o[Obj::TASK])
      o[Obj::ST] = 0
      a = gd.a(:worm_eaten) + 1
      a += 2 until gd.byte(a) == o[Obj::TYPE]
      t[:sprite] = gd.byte(a + 1) # $6f9
      t[:ate] = o[Obj::SLOT]
      return
    end
    return unless ((p[:y] - t[:y]) & 0xff) < 0x0a && ((p[:x] - hx) & 0xff) >= 0xf0
    return if w[:mode626] != 0 || w[:no_hit]
    Scheduler.kill_others(w)
    w[:sounds] << 0
    t[:sprite] = p[:char] == 0x1c ? 0x74 : 0x70
    w[:prio] = 3 # $8d7e
    t[:ate] = 4
  end

  # $8f48: Ptolemy and enemies just in front of the head are pushed 2 px
  def self.push(w, t)
    p = w[:player]
    if ((p[:y] - t[:y]) & 0xff) < 0x10 && ((p[:x] - t[:x]) & 0xff) >= 0xe8
      p[:x] = (p[:x] + 2) & 0xff
    end
    w[:obj].each do |o|
      next if ((o[Obj::ST] - 1) & 0xff) >= 0x80
      next unless ((o[Obj::Y] - t[:y]) & 0xff) < 0x18 && ((o[Obj::X] - t[:x]) & 0xff) >= 0xe8
      o[Obj::TIMER] = 1
      o[Obj::X] = (o[Obj::X] + 2) & 0xff
    end
  end

  # $728: a block (h, w, tiles) into the name table at a cell, rows downward
  def self.block(w, gd, cell, name, attr)
    a = gd.a(name)
    h = gd.byte(a)
    wd = gd.byte(a + 1)
    h.times do |r|
      wd.times do |c|
        i = cell + 32 * r + c
        w[:bg][:tiles][i] = gd.byte(a + 2 + r * wd + c)
        w[:bg][:attrs][i] = attr
        w[:bg_dirty] << i
      end
    end
  end

  # $b20 / $a6a: priority bit on 4 rows x 5 cells from the cell right of the door's ($86a4 address - 2), rows downward
  def self.priority(w, x, y, on)
    c0 = RoundBuilder.cell_at(x, y) + 1
    4.times do |r|
      5.times do |c|
        i = c0 + 32 * r + c
        next if i < 0 || i >= 1024
        a = w[:bg][:attrs][i]
        w[:bg][:attrs][i] = on ? a | 0x20 : a & 0xdf
        w[:bg_dirty] << i
      end
    end
  end
end

Scheduler::IMPL[0x26] = WormTask
