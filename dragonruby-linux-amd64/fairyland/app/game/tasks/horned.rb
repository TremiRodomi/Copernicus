# Task 24 ($86be, arcade $6c0c): Horned, the time-up devil. The AI spawns it when the round timer runs out ($610 = $46).
# It waits out the Worm, a Change Potion and the moon (and cuts a Mystical Orb short), stops the moon countdown, plays its
# music, flies in along one of four entrance scripts (taken in turn), then chases Ptolemy along Bresenham lines at
# 1 px a frame, re-aiming whenever it reaches the point it aimed at. Invincible; touching it is an ordinary death.
# When the last enemy is gone it vanishes (the escape animation backwards).
module HornedTask
  SND_MUSIC = 0x12
  SND_GONE = 0x25

  def self.run(w, t, gd)
    g = w[:game]
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        t[:pc] = :check
        return 1
      when :check # $86c6
        return 1 if w[:flag6f4] != 0 || w[:power] == 0x81
        w[:power_timer] = 1 if w[:power] == 8
        return 1 if g[:moon] == 0xf0
        Scheduler.kill(w, 0x14)
        return :killed if w[:enemies_left] & 0x7f == 0
        w[:sounds] << SND_MUSIC
        t[:pc] = :enter
        return 0xe5
      when :enter # $8716: the next of the four entrance scripts, from off the top-left
        t[:anim] = 0
        t[:frame] = 0
        g[:horned_path] = (g[:horned_path] >= 4 ? 0 : g[:horned_path]) + 1
        t[:e] = gd.horned_script(g[:horned_path])
        t[:y] = 0xf4
        t[:x] = 0xff
        t[:pc] = :entry
      when :entry # [steps, frame base, step-table offset, frames per step]
        n = gd.byte(t[:e])
        if n == 0
          t[:pc] = :aim
          next
        end
        t[:n] = n
        t[:fb] = gd.byte(t[:e] + 1)
        t[:a] = gd.a(:horned_steps) + gd.byte(t[:e] + 2)
        t[:pc] = :step
      when :step
        t[:d] = gd.byte(t[:e] + 3)
        dx = gd.byte(t[:a])
        t[:a] += 1
        if dx == 0x80 # jump: a little-endian arcade address inside the step table (FS.X keeps them too)
          ptr = gd.byte(t[:a]) | (gd.byte(t[:a] + 1) << 8)
          t[:a] = gd.a(:horned_steps) + ptr - Tables::ADDR[:horned_steps][1]
          dx = gd.byte(t[:a])
          t[:a] += 1
        end
        t[:x] = (t[:x] + dx) & 0xff
        t[:y] = (t[:y] + gd.byte(t[:a])) & 0xff
        t[:a] += 1
        Shadow.set_c(w, gd, (t[:frame] + t[:fb]) & 0xff, t[:y], t[:x])
        touch(w, t, p)
        t[:pc] = :step_wait
        return 1
      when :step_wait
        if w[:enemies_left] & 0x7f == 0
          t[:pc] = :leave
          next
        end
        animate(w, t, gd)
        t[:d] -= 1
        return 1 if t[:d] != 0
        t[:n] -= 1
        if t[:n] != 0
          t[:pc] = :step
        else
          t[:e] += 4
          t[:pc] = :entry
        end
      when :aim # $87c0
        t[:dx] = 1
        t[:dy] = 1
        d = p[:x] - t[:x]
        t[:dx] = 0xff if d < 0
        adx = d.abs & 0xff
        d = p[:y] - t[:y]
        t[:dy] = 0xff if d < 0
        ady = d.abs & 0xff
        if ady < adx # x is the major axis
          t[:xmajor] = true
          t[:target] = p[:x]
          t[:major] = adx
          t[:acc] = ady
          t[:minor] = ady
        else
          t[:xmajor] = false
          t[:target] = p[:y]
          t[:major] = ady
          t[:acc] = adx
          t[:minor] = adx
        end
        t[:pc] = :chase
      when :chase # $880e
        Shadow.set_c(w, gd, (t[:frame] + (t[:dx] < 0x80 ? 0x78 : 0x7c)) & 0xff, t[:y], t[:x])
        touch(w, t, p)
        animate(w, t, gd)
        t[:pc] = :chase_move
        return 1
      when :chase_move
        if w[:enemies_left] & 0x7f == 0
          t[:pc] = :leave
          next
        end
        if t[:target] == (t[:xmajor] ? t[:x] : t[:y])
          t[:pc] = :aim
          next
        end
        acc = (t[:acc] + t[:minor]) & 0xff
        t[:acc] = acc
        if acc >= t[:major]
          t[:acc] = acc - t[:major]
          t[:y] = (t[:y] + t[:dy]) & 0xff
          t[:x] = (t[:x] + t[:dx]) & 0xff
        elsif t[:xmajor]
          t[:x] = (t[:x] + t[:dx]) & 0xff
        else
          t[:y] = (t[:y] + t[:dy]) & 0xff
        end
        t[:pc] = :chase
      when :leave # $8888
        4.times { |k| Shadow.clear(w, 0x4c + 4 * k) }
        w[:sounds] << SND_GONE if t[:y] < 0xe8
        t[:a] = gd.a(:horned_vanish)
        t[:n] = 32
        t[:pc] = :vanish
        return 2
      when :vanish
        Shadow.set_b(w, gd, gd.byte(t[:a]), t[:y], t[:x], 0x4c, :meta_poses)
        t[:a] -= 1
        t[:n] -= 1
        if t[:n] == 0
          Shadow.clear(w, 0x4c)
          return :killed
        end
        return 2
      else
        raise "HornedTask: bad pc #{t[:pc]}"
      end
    end
  end

  # $88e2: every 7 frames the next of 6 wing frames ($cc2e)
  def self.animate(w, t, gd)
    v = t[:anim] + 0x10
    if v < 0x70
      t[:anim] = v
      return
    end
    v = (v & 0x0f) + 1
    v = 0 if v >= 6
    t[:anim] = v
    t[:frame] = gd.byte(gd.a(:horned_anim) + v)
  end

  # $8920: |dx| < 8 and Ptolemy 0..7 px above or up to 8 (shrunk: 4) px below
  def self.touch(w, t, p)
    return unless (p[:x] - t[:x]).abs < 8
    d = (p[:y] - t[:y]) & 0xff
    hit = p[:y] >= t[:y] ? d < 8 : d >= (p[:char] == 0x1c ? 0xfc : 0xf8)
    return unless hit && !w[:no_hit]
    w[:end_code] = 0x40
    # no enemy has either id (tasks 5-12): the death hides every enemy, Horned stays visible. VERSION DIFFERENCE: the
    # X68000 writes $40 to both $62e and $596; the arcade ($6f0e) clears $e61a (= $596) instead
    w[:killer] = World.x68k?(w) ? 0x40 : 0
    NightWipe::FREEZE.each { |id| Scheduler.suspend(w, id) unless id == 0x24 } # $69ce
  end
end

Scheduler::IMPL[0x24] = HornedTask
