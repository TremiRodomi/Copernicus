# Species attacks ($5b3a, run by the enemy body when the AI sets command bit 1) and the enemy shots (tasks 12 / 13).
# Attack poses come from the $1b22 metasprite table ($108e9); unlike walking, the attack frames are plain yields
# (they ignore the speed divider). While posing an enemy still drops 2 px a frame if the ground vanishes ($5da2).
module EnemyAttack
  POSES = :meta_poses
  WIZARD_L = :wizard_attack_l # [pose, frames] ... [pose, 0]   (L = facing +x, R = facing -x)
  WIZARD_R = :wizard_attack_r
  SALAMANDER_L = :salamander_attack_l
  SALAMANDER_R = :salamander_attack_r
  CLERIC_L = :cleric_attack_l # [pose, frames] ... 0
  CLERIC_R = :cleric_attack_r
  SND_MAGIC = 0x19
  SND_BREATH = 0x1c
  SND_FIRE = 0x1e
  SND_SUMMON = 0x24
  LABELS = %i[attack wz_pose wz_hold wz_fire wz_flash wz_hold2 wz_done sa_pose sa_hold sa_hold_b sa_fire sa_burn sa_burn_b
              cl_start cl_pose cl_hold cl_summon cl_sum_snd cl_flash cl_next cl_end]

  # One step of the attack state machine: returns frames to sleep, or nil after changing t[:pc]
  def self.step(w, t, gd, o)
    case t[:pc]
    when :attack # $5b3a
      case o[Obj::TYPE]
      when 0x91
        o[Obj::ST] = 7
        t[:a] = gd.a(o[Obj::FACE] == 0 ? WIZARD_L : WIZARD_R)
        t[:pc] = :wz_pose
      when 0x1d
        o[Obj::ST] = 7
        o[Obj::JDX] = 0x80 # reused as the flame's palette counter
        t[:a] = gd.a(o[Obj::FACE] == 0 ? SALAMANDER_L : SALAMANDER_R)
        t[:pc] = :sa_pose
      when 0x74
        t[:pc] = :cl_start
        return 1
      else
        t[:pc] = :reset
      end
      nil

    # --- Wizard ($5b60): wind-up poses, then a shrink spell (task 12/13), a 46-frame flashing hold, and it turns round
    when :wz_pose
      draw(w, gd, o, gd.byte(t[:a]))
      if o[Obj::CMD] & 0x10 != 0 # bumped: abort
        t[:pc] = :wz_done
        return nil
      end
      t[:pose] = gd.byte(t[:a])
      t[:n] = gd.byte(t[:a] + 1)
      if t[:n] == 0
        t[:pc] = :wz_fire
        return nil
      end
      t[:a] += 2
      t[:pc] = :wz_hold
      1
    when :wz_hold
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      return 1 if t[:n] > 0
      t[:pc] = :wz_pose
      nil
    when :wz_fire # $5bbc
      k = w[:flag654] == 0 && EnemyShot.free(w)
      unless k
        t[:pc] = :wz_done
        return nil
      end
      w[:eshots][k] = [o[Obj::TASK], o[Obj::Y], o[Obj::X], o[Obj::FACE]]
      Scheduler.spawn(w, 0x12 + k)
      w[:sounds] << SND_MAGIC
      t[:n] = 3
      t[:pc] = :wz_flash
      2
    when :wz_flash # 3 x: pose with its palette shifted +1, +2, +3
      pose(w, gd, o, t[:pose])
      shift_palette(w, o[Obj::SLOT], 4 - t[:n])
      t[:n] -= 1
      if t[:n] == 0
        t[:n] = 20
        t[:pc] = :wz_hold2
      end
      2
    when :wz_hold2
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      t[:pc] = :wz_done if t[:n] == 0
      2
    when :wz_done # $5c54
      o[Obj::CMD] ^= 0x0c
      o[Obj::TIMER] = 0x64
      t[:pc] = :reset
      2

    # --- Salamander ($5c6c): flame breath poses (flickering palette), then a fireball (task 12/13) and a 40-frame hold
    when :sa_pose
      f = gd.byte(t[:a])
      w[:sounds] << SND_BREATH if f == 0x1b || f == 0x17
      draw(w, gd, o, f)
      t[:pose] = f
      t[:n] = gd.byte(t[:a] + 1)
      if t[:n] == 0
        t[:pc] = :sa_fire
        return nil
      end
      t[:a] += 2
      t[:pc] = :sa_hold
      1
    when :sa_hold
      pose(w, gd, o, t[:pose])
      flicker(w, o)
      t[:pc] = :sa_hold_b
      1
    when :sa_hold_b
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      if t[:n] > 0
        t[:pc] = :sa_hold
        return 1
      end
      t[:pc] = :sa_pose
      nil
    when :sa_fire # $5cf4: no shot while $654 is set or both shot slots are busy, but the same hold
      k = w[:flag654] == 0 && EnemyShot.free(w)
      if k
        w[:eshots][k] = [0xff, o[Obj::Y], o[Obj::X], o[Obj::FACE]]
        Scheduler.spawn(w, 0x12 + k)
        w[:sounds] << SND_FIRE
      end
      t[:n] = 20
      t[:pc] = :sa_burn
      1
    when :sa_burn
      pose(w, gd, o, t[:pose])
      flicker(w, o)
      t[:pc] = :sa_burn_b
      1
    when :sa_burn_b
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      if t[:n] > 0
        t[:pc] = :sa_burn
        return 1
      end
      t[:pc] = :reset
      nil

    # --- Cleric ($5e00): with fewer than 5 enemies and a free slot, summons up to 3 Clerics (they die to any spell hit)
    when :cl_start
      if (w[:enemies_left] & 0xff) >= 5 || !free_obj(w)
        EnemyBody.walk(w, o, t[:cmd])
        return EnemyBody.after_walk(t, o)
      end
      o[Obj::ST] = 7
      t[:a] = gd.a(o[Obj::FACE] == 0 ? CLERIC_L : CLERIC_R)
      t[:pc] = :cl_pose
      nil
    when :cl_pose
      f = gd.byte(t[:a])
      if f == 0
        o[Obj::ANIM] = 3
        t[:pose] = gd.byte(t[:a] - 2)
        t[:pc] = :cl_summon
        return nil
      end
      draw(w, gd, o, f)
      t[:pose] = f
      t[:n] = gd.byte(t[:a] + 1)
      t[:a] += 2
      t[:pc] = :cl_hold
      1
    when :cl_hold
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      return 1 if t[:n] > 0
      t[:pc] = :cl_pose
      nil
    when :cl_summon # $5e7e
      k = w[:flag654] == 0 && free_obj(w)
      unless k
        t[:n] = 20
        t[:pc] = :cl_end
        return nil
      end
      n = w[:obj][k] # the other fields keep whatever the slot held before, as in the original
      n[Obj::SLOT] = 0x0c + 8 * k
      w[:enemies_left] = (w[:enemies_left] + 1) & 0xff
      n[Obj::ST] = 1
      n[Obj::TYPE] = 0x74
      n[Obj::X] = o[Obj::X]
      n[Obj::Y] = o[Obj::Y]
      n[Obj::TASK] = 5 + k
      Scheduler.spawn(w, 5 + k)
      o[Obj::CMD] ^= 0x0c
      n[Obj::CMD] = o[Obj::CMD] | 0x20 # summoned: killed by any spell hit, 10 points
      pose(w, gd, o, t[:pose])
      t[:pc] = :cl_sum_snd
      2
    when :cl_sum_snd
      w[:sounds] << SND_SUMMON
      t[:n] = 3
      t[:pc] = :cl_flash
      nil
    when :cl_flash
      pose(w, gd, o, t[:pose])
      shift_palette(w, o[Obj::SLOT], 4 - t[:n])
      t[:n] -= 1
      t[:pc] = :cl_next if t[:n] == 0
      2
    when :cl_next
      o[Obj::ANIM] = (o[Obj::ANIM] - 1) & 0xff
      if o[Obj::ANIM] != 0
        t[:pc] = :cl_summon
      else
        t[:n] = 20
        t[:pc] = :cl_end
      end
      nil
    when :cl_end # $5f18
      pose(w, gd, o, t[:pose])
      t[:n] -= 1
      t[:pc] = :reset if t[:n] == 0
      1
    end
  end

  def self.draw(w, gd, o, f)
    Shadow.set_b(w, gd, f, o[Obj::Y], o[Obj::X], o[Obj::SLOT], POSES)
  end

  # $5da2: draw an attack pose; drop 2 px if there is nothing under the feet
  def self.pose(w, gd, o, f)
    draw(w, gd, o, f)
    o[Obj::Y] = (o[Obj::Y] - 2) & 0xff unless Obj.ground?(w, o, o[Obj::X], o[Obj::Y])
  end

  # $19fc + add.b to +4/+$c: both sprites of the pose get their attribute high byte (palette) raised by n
  def self.shift_palette(w, slot, n)
    i = (slot & 0xff) >> 2
    [i, i + 1].each do |j|
      e = w[:shadow][j]
      e[2] = (e[2] + (n << 8)) & 0xffff if e
    end
  end

  # $5dd8: the flame sprite (second part) cycles palettes 2..5
  def self.flicker(w, o)
    o[Obj::JDX] = (o[Obj::JDX] + 1) & 0xff
    e = w[:shadow][((o[Obj::SLOT] + 4) & 0xff) >> 2]
    e[2] = (e[2] & 0xf0ff) | ((((o[Obj::JDX] & 3) + 2)) << 8) if e
  end

  # $5f36: first object slot that is empty and whose sprite slot is clear
  def self.free_obj(w)
    (0...8).find { |k| w[:obj][k][Obj::ST] == 0 && w[:shadow][(0x0c + 8 * k) >> 2].nil? }
  end
end

# Tasks 12 / 13 ($6d94 / $6da0): an enemy shot, data at $613 / $617 = [owner task id or $ff, y, x, facing], sprite slot $74 / $78.
#  Wizard spell: 24 px of flight from 12 px in front; touching Ptolemy costs 10 EXP and shrinks her (Ptolemy restarts small,
#    $612 = the Wizard); hitting an already shrunk Ptolemy is the shrinking death ($62e = $10).
#  Salamander fireball ($ff): flies 2 px a frame, 8 px up, until a wall or the screen edge; touching Ptolemy burns her ($62e = $20).
#    It then bursts, and the slot stays busy for 50 more frames (limits the fire rate).
module EnemyShot
  MAGIC_L = :magic_shot_l # [pose, dx] ... 0
  MAGIC_R = :magic_shot_r
  FIRE_L = :fireball_l # [pose, dx] ... 0, loops
  FIRE_R = :fireball_r
  BURST_L = :burst_l # poses, 0
  BURST_R = :burst_r

  def self.free(w)
    w[:eshots].index { |s| s[0] == 0 }
  end

  # wall = the cell and the one above it both solid
  def self.wall?(w, x, y)
    i = World.cmi(x & 0xff, y & 0xff)
    World.cm(w, i) & World.cm(w, i + 0x20) & 1 == 1
  end

  def self.run(w, t, gd)
    k = t[:id] - 0x12
    s = w[:eshots][k]
    slot = 0x74 + 4 * k
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        if s[0] >= 0x80
          t[:pc] = :fire_start
          next
        end
        s[2] = (s[2] + (s[3] == 0 ? 0x0c : -0x0c)) & 0xff
        t[:a] = gd.a(s[3] == 0 ? MAGIC_L : MAGIC_R)
        t[:pc] = :m_wall
        return 1
      when :m_wall
        if wall?(w, s[2] + 6, s[1])
          t[:pc] = :end
          next
        end
        t[:pc] = :m_loop
        return 1
      when :m_loop # $6e02
        Shadow.set_b(w, gd, gd.byte(t[:a]), s[1], s[2], slot, EnemyAttack::POSES)
        t[:a] += 1
        dx = World.sbyte(p[:x] - s[2]).abs
        dy = World.sbyte(p[:y] - s[1])
        if dx < 0x0e && dy >= -0x0e && dy < 0x0c
          t[:pc] = :hit
          next
        end
        t[:pc] = :m_move
        return 1
      when :m_move
        s[2] = (s[2] + World.sbyte(gd.byte(t[:a]))) & 0xff
        t[:a] += 1
        # the original computes a +1 for rightward moves into d0 and then never uses it: always x + 7
        t[:pc] = gd.byte(t[:a]) == 0 || wall?(w, s[2] + 7, s[1]) ? :end : :m_loop
      when :end # $6e70
        Shadow.clear(w, slot)
        s[0] = 0
        return :killed
      when :hit # $6e86
        g = w[:game]
        g[:exp] = [g[:exp] - 10, 0].max
        Shadow.clear(w, slot)
        Scheduler.kill(w, 1)
        p[:y] &= 0xf8
        Effects.sparkle(w, 0, p[:x], p[:y])
        t[:pc] = :hit2
        return 0x14
      when :hit2
        w[:wizard_id] = s[0]
        if p[:char] == 0x1c && !w[:no_hit]
          Scheduler.kill(w, s[0]) # already small: the Wizard stops and Ptolemy shrinks away
          w[:end_code] = 0x10
        else
          unless p[:char] == 0x1c
            p[:char] = 0x1c
            p[:step_delay] = 1
            p[:speed] = 1
          end
          Scheduler.spawn(w, 1) # Ptolemy's task restarts with the small sprite set
        end
        s[0] = 0
        return :killed

      when :fire_start # $6f06
        t[:x] = (s[2] + (s[3] == 0 ? 0x0c : -0x0c)) & 0xff
        t[:a] = gd.a(s[3] == 0 ? FIRE_L : FIRE_R)
        t[:y] = (s[1] + 8) & 0xff
        t[:pc] = :f_wall
        return 1
      when :f_wall
        t[:pc] = wall?(w, t[:x] + 6, t[:y]) ? :burst : :f_loop
        return 1 if t[:pc] == :f_loop
      when :f_loop # $6f56
        f = gd.byte(t[:a])
        if f == 0
          t[:a] = gd.a(s[3] == 0 ? FIRE_L : FIRE_R)
          f = gd.byte(t[:a])
        end
        t[:a] += 1
        Shadow.set_b(w, gd, f, t[:y], t[:x], slot, EnemyAttack::POSES)
        if burns?(w, t[:x], t[:y])
          t[:pc] = :burst
          next
        end
        t[:pc] = :f_move
        return 1
      when :f_move
        dx = gd.byte(t[:a])
        t[:a] += 1
        x = t[:x] + dx
        if dx < 0x80
          t[:x] = x & 0xff
          t[:pc] = t[:x] >= 0xf0 || wall?(w, t[:x] + 8, t[:y]) ? :burst : :f_loop
        else
          t[:x] = x & 0xff
          t[:pc] = x < 0x100 || wall?(w, t[:x] + 7, t[:y]) ? :burst : :f_loop # no carry = it went past x 0
        end
      when :burst # $6fbe
        t[:a] = gd.a(s[3] == 0 ? BURST_L : BURST_R)
        t[:pc] = :burst_frame
      when :burst_frame
        f = gd.byte(t[:a])
        if f == 0
          Shadow.clear(w, slot)
          t[:pc] = :burst_done
          return 0x32
        end
        t[:a] += 1
        Shadow.set_b(w, gd, f, t[:y], t[:x], slot, EnemyAttack::POSES)
        return 6
      when :burst_done
        s[0] = 0
        # the original also kills task 04 here when byte $6fc is set; nothing in FS.X writes $6fc by name
        return :killed
      else
        raise "EnemyShot: bad pc #{t[:pc]}"
      end
    end
  end

  # $701c: |dx| < 6 and Ptolemy 0..6 px above or up to 13 px (shrunk: 7 px) below the fireball
  def self.burns?(w, x, y)
    p = w[:player]
    return false unless (p[:x] - x).abs < 6
    d = p[:y] - y
    ok = d >= 0 ? d < 7 : -d < (p[:char] == 0x1c ? 8 : 0x0e)
    return false unless ok && !w[:no_hit]
    w[:end_code] = 0x20
    true
  end
end

Scheduler::IMPL[0x12] = EnemyShot
Scheduler::IMPL[0x13] = EnemyShot
