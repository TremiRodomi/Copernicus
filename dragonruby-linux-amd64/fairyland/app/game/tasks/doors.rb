# Task 20 ($8556, arcade $6b36 - same code): the round's pair of teleport doors (round record pair: x1,y1,x2,y2; the blocks
# are drawn by the round builder). Each frame one door is checked, alternating sides: Ptolemy (or else the first enemy)
# standing exactly at its height and within 2 px of its x is moved to the other door. A latch per side remembers who just
# arrived there (1 = Ptolemy, else the enemy's task id) until they step off, so nobody bounces straight back. The
# destination door shows its open tiles (codes + $f) for one frame, and the Worm is paused meanwhile.
module DoorTask
  def self.run(w, t, gd)
    x1, y1, x2, y2 = w[:door_pair]
    if t[:pc] == :start
      t[:src] = [x1, y1]
      t[:dst] = [x2, y2]
      t[:lat] = 0   # d1: who just arrived at the source door
      t[:lat2] = 0  # d2: who just arrived at the destination door
      t[:pc] = :check
    end
    if t[:pc] == :check
      player(w, t)
      enemies(w, t)
      t[:pc] = :after
      return 1
    end
    # $863e: after the frame, the open door closes again and the Worm carries on; then the other door's turn
    if w[:door_open] != 0
      flash(w, t[:dst], 0xf1)
      w[:door_open] = 0
      Scheduler.resume(w, 0x26)
    end
    t[:src], t[:dst] = t[:dst], t[:src]
    t[:lat], t[:lat2] = t[:lat2], t[:lat]
    t[:pc] = :check
    player(w, t)
    enemies(w, t)
    t[:pc] = :after
    1
  end

  # $858a
  def self.player(w, t)
    return if w[:end_code] != 0
    p = w[:player]
    sx, sy = t[:src]
    if p[:y] == sy && (p[:x] - sx).abs < 2
      return if t[:lat] != 0
      t[:lat2] = 1
      p[:x], p[:y] = t[:dst]
      dir = w[:tasks].find { |k| k && k[:id] == 0 }
      dir[:px] = p[:x] if dir # $594/$595: the jump is not walking (step counter)
      opened(w, t)
    elsif t[:lat] == 1
      t[:lat] = 0
    end
  end

  # $85ca
  def self.enemies(w, t)
    sx, sy = t[:src]
    w[:obj].each do |o|
      next if ((o[Obj::ST] - 1) & 0xff) >= 0x80
      if o[Obj::Y] == sy && (o[Obj::X] - sx).abs < 2
        next if t[:lat] != 0
        t[:lat2] = o[Obj::TASK]
        o[Obj::X], o[Obj::Y] = t[:dst]
        opened(w, t)
        return
      elsif t[:lat] == o[Obj::TASK]
        t[:lat] = 0
      end
    end
  end

  # $861a
  def self.opened(w, t)
    return if w[:door_open] == t[:src][0]
    Scheduler.suspend(w, 0x26)
    flash(w, t[:dst], 0x0f)
    w[:door_open] = t[:src][0]
  end

  # $8660: the door's 3 x 2 tile codes + d (open) / - d (closed again)
  def self.flash(w, pos, d)
    c0 = RoundBuilder.cell_at(pos[0], pos[1])
    3.times do |r|
      2.times do |c|
        i = c0 + 32 * r + c
        w[:bg][:tiles][i] = (w[:bg][:tiles][i] + d) & 0xff
        w[:bg_dirty] << i
      end
    end
  end
end

Scheduler::IMPL[0x20] = DoorTask
