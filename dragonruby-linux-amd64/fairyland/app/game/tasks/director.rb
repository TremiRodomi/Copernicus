# Task 00: the round director ($3ee0). Spawns Ptolemy's tasks, counts her steps for the bonus item, and when the round ends
# ($62e set) plays the matching ending, then sets $62e = $ff for the main loop (lives / restart / next round).
module Director
  DEATH_FLOAT = :death_float # ghost animation frames (0-terminated, loops)
  SND_STOP = 0x00
  SND_HIT = 0x2a
  SND_MISS = 0x0b
  SND_SQUASH = 0x1a
  SND_BURNT = 0x20
  SND_SHRINK = 0x0f
  BURNT = :burnt_death # burnt death: offsets added to $7f (small: $83)
  SHRINK = :shrink_death # shrinking death: $1a48 poses, 0, then $1b22 poses, 0
  # Arcade ghost sway: the MCU's default step sequence (protection MCU ROM $9c-$e6, served by MCU commands 3 and $32).
  # As 0 / +1 / -1 steps: hold, ease ~15 px one way, hold, ease back. The X68000 port replaced it with a fixed +1.
  SWAY = [0] * 12 + [1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1] + [0] * 13 +
         [-1, 0, 0, -1, 0, -1, 0, -1, -1, -1, 0, -1, -1, -1, 0, -1, -1, -1, 0, -1, 0, -1, 0, 0, -1]

  def self.run(w, t, gd)
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start # $3ee0
        t[:px] = p[:x]
        p[:facing] = 0
        w[:input_override] = nil # $592 = 0: the player has control
        Scheduler.spawn(w, 1)
        Scheduler.spawn(w, 3) # Ptolemy's spell
        t[:pc] = :steps
        return 6
      when :steps # $3f0e: every 6 frames
        old = t[:px]
        t[:px] = p[:x]
        d = (p[:x] - old).abs
        if w[:t611] == 0 && d < 0x80
          if w[:power] == 0
            g = w[:game]
            g[:steps] += d
            if g[:steps] >= 800
              g[:steps] -= 800
              Scheduler.spawn(w, 0x15) # bonus item
            end
          elsif w[:power] == 8
            v = d < 10 ? d : d + 6 # the distance as a BCD byte (good up to 15)
            3.times { Score.add(w, 0, v) } # Mystical Orb: walking scores
          end
        end
        return 6 if w[:end_code] == 0
        t[:pc] = :ended
      when :ended # $3f9e
        w[:mode626] = 0
        w[:sounds] << SND_STOP
        Scheduler.kill(w, 0x1d)
        Scheduler.kill(w, 0x15)
        case w[:end_code]
        when 0x40 then t[:pc] = :death
        when 0x20 then t[:pc] = :burnt
        when 0x10 then t[:pc] = :shrunk
        else # $3fde: crushed by a cake ($80); the Worm's code is still to be checked
          Scheduler.kill(w, 3)
          t[:pc] = :crushed
          return 1
        end
      when :crushed # $3fe6: the squashed pose drops 4 px a frame until it lands
        Shadow.set_a(w, gd, p[:char] + 0x1b, p[:y], p[:x])
        i = World.cmi(p[:x] + (p[:facing] == 0 ? 4 : 3), p[:y] - 1)
        if (World.cm(w, i) | World.cm(w, i + 1)) & 1 == 0 && !(w[:power] == 6 && on_frozen_enemy?(w, p))
          p[:y] = (p[:y] - 4) & 0xff
          return 1
        end
        w[:sounds] << SND_SQUASH
        Scheduler.kill_others(w)
        t[:pc] = :crushed_clear
        return 0x3c
      when :crushed_clear
        0x1d.times { |k| Shadow.clear(w, 0x0c + 4 * k) }
        t[:pc] = :over
        return 0x1e
      when :death # $409a: killed by an enemy
        w[:prio] = 2 # $40a8: the bubble's sheen goes in front of her
        Scheduler.kill_others(w)
        t[:pc] = :death_hit
        return 1
      when :death_hit
        p[:char] = p[:char] == 0x1c ? 9 : 0
        Shadow.set_c(w, gd, p[:char], p[:y], p[:x])
        w[:sounds] << SND_HIT
        t[:pc] = :death_flash1
        return 0x28
      when :death_flash1
        Shadow.set_c(w, gd, 0x2b, p[:y], p[:x])
        t[:pc] = :death_flash2
        return 5
      when :death_flash2
        Shadow.set_c(w, gd, 0x2f, p[:y], p[:x])
        t[:pc] = :death_fade
        return 5
      when :death_fade
        hide_others(w, w[:killer])
        Shadow.set_c(w, gd, p[:char] + 1, p[:y], p[:x])
        t[:pc] = :death_ghost
        return 0x28
      when :death_ghost # $411c: the miss jingle, then her ghost floats up off the screen
        w[:sounds] << SND_MISS
        t[:x] = p[:x]
        t[:y] = p[:y]
        p[:jdx] = p[:x] >= 0x80 ? 0xff : 0
        p[:fall_count] = 7
        t[:frame] = 0
        t[:sway] = 0 # the round start used up the round's MCU sequence, so the death reads the sway from its first step
        t[:pc] = :ghost
      when :ghost # $4140
        f = gd.byte(gd.a(DEATH_FLOAT) + t[:frame])
        if f == 0
          t[:frame] = 0
          next
        end
        p[:fall_count] -= 1
        if p[:fall_count] == 0
          t[:frame] += 1
          p[:fall_count] = 7
        end
        Shadow.set_c(w, gd, p[:char] + f, t[:y], t[:x])
        t[:pc] = :ghost_move
        return 1
      when :ghost_move # $416c / arcade $17b8
        if World.x68k?(w) # X68000: 1 px towards the screen centre every 4th frame ($58c is a counter)
          t[:x] = (t[:x] + (p[:jdx] == 0 ? 1 : -1)) & 0xff if World.rand(w) & 3 == 0
        elsif World.r_reg(w) & 3 == 0 # arcade: on a random 1 frame in 4, the next sway step, towards the centre first
          d = SWAY[t[:sway]]
          t[:sway] = (t[:sway] + 1) % SWAY.size
          t[:x] = (t[:x] + (p[:jdx] == 0 ? d : -d)) & 0xff
        end
        t[:y] += 1
        t[:pc] = t[:y] < 0xf7 ? :ghost : :jingle
      when :jingle # $418e: wait for the jingle to finish
        return 1 if w[:audio_busy]
        t[:pc] = :over
      when :burnt # $41ae: burnt by a Salamander's fireball
        w[:prio] = 1
        Scheduler.kill(w, 1)
        Scheduler.kill(w, 3)
        Effects.sparkle(w, 4, p[:x], p[:y])
        t[:pc] = :burnt_pose
        return 0x0f
      when :burnt_pose
        t[:d3] = p[:char] == 0x1c ? 0x83 : 0x7f
        Shadow.set_a(w, gd, t[:d3], p[:y], p[:x])
        t[:pc] = :burnt_fall
      when :burnt_fall # the charred pose drops 2 px a frame until it lands
        i = World.cmi(p[:x] + (p[:facing] == 0 ? 4 : 3), p[:y] - 1)
        if (World.cm(w, i) | World.cm(w, i + 1)) & 1 != 0
          t[:pc] = :burnt_land
          return 0x14
        end
        p[:y] = (p[:y] - 2) & 0xff
        Shadow.set_a(w, gd, t[:d3], p[:y], p[:x])
        return 1
      when :burnt_land
        Scheduler.kill_others(w)
        t[:pc] = :burnt_clear
        return 0x28
      when :burnt_clear
        0x1d.times { |k| Shadow.clear(w, 0x0c + 4 * k) }
        t[:a] = gd.a(BURNT)
        t[:pc] = :burnt_anim
        return 0x1e
      when :burnt_anim # offsets from BURNT added to the pose base; the first one that carries past $ff ends it
        d = gd.byte(t[:a])
        w[:sounds] << SND_BURNT if d == 2
        if d + t[:d3] > 0xff
          t[:pc] = :over
          return 0x3c
        end
        t[:a] += 1
        Shadow.set_a(w, gd, d + t[:d3], p[:y], p[:x])
        return 3
      when :shrunk # $42aa: hit by a Wizard's spell while already small
        Scheduler.kill(w, 3)
        t[:pc] = :shrunk_snd
        return 7
      when :shrunk_snd
        w[:sounds] << SND_SHRINK
        t[:pc] = :shrunk_hide
        return 8
      when :shrunk_hide
        Scheduler.kill_others(w)
        hide_others(w, w[:wizard_id])
        t[:a] = gd.a(SHRINK)
        t[:pc] = :shrunk_pose
      when :shrunk_pose
        f = gd.byte(t[:a])
        t[:a] += 1
        if f != 0
          Shadow.set_a(w, gd, f, p[:y], p[:x])
          return 7
        end
        t[:y] = (p[:y] + 5) & 0xff
        t[:pc] = :shrunk_pop
      when :shrunk_pop # the last frames come from the $1b22 table, in sprite slot 8
        f = gd.byte(t[:a])
        t[:a] += 1
        if f == 0
          Shadow.clear(w, 8)
          t[:pc] = :over
          return 0x32
        end
        Shadow.set_b(w, gd, f, t[:y], p[:x], 8, :meta_poses)
        return 4
      when :over # $41a0
        w[:end_code] = 0xff
        return :killed
      end
    end
  end

  # $402a: with power-up 6 she lands on an enemy in state 9 exactly 24 px below, within 16 px
  def self.on_frozen_enemy?(w, p)
    w[:obj].any? do |o|
      o[Obj::ST] == 9 && ((p[:y] - o[Obj::Y]) & 0xff) == 0x18 && (p[:x] - o[Obj::X]).abs < 0x10
    end
  end

  # $4328: hide every enemy except the killer, then the item / effect slots $5c-$7c
  def self.hide_others(w, killer)
    w[:obj].each do |o|
      next if o[Obj::ST] == 0 || o[Obj::TASK] == killer
      Shadow.clear(w, o[Obj::SLOT])
      Shadow.clear(w, o[Obj::SLOT] + 4)
    end
    9.times { |i| Shadow.clear(w, 0x5c + 4 * i) }
  end
end

Scheduler::IMPL[0x00] = Director
