# Round start and end. The original runs these from the main loop with frame waits ($2612 intro, $20c4 clear); the port
# runs them as tasks with their own ids (0x40 / 0x41, unused by the original's 46 types) so they share the scheduler's timing.

# $2612: music, Ptolemy's entrance (task 1a), "READY !" while task 1b plays and the enemies show, then the round's tasks
module IntroTask
  # $2612: the round music - $07 (rounds 1-49), $30 (50-100), $12 (101)
  def self.music(w)
    idx = w[:round] - 1 # $703
    idx >= 0x64 ? 0x12 : idx >= 0x31 ? 0x30 : 0x07
  end

  def self.run(w, t, gd)
    p = w[:player]
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        w[:sounds] << IntroTask.music(w) unless t[:music_sent] # (after a build BuildWaitTask sent it a frame earlier)
        w[:flag6b6] = 0xff
        Scheduler.spawn(w, 0x1a)
        t[:pc] = :entrance
        return 1
      when :entrance
        return 1 if w[:flag6b6] != 0
        p[:x] = 0xa0
        p[:y] = 0x24
        Shadow.set_a(w, gd, p[:char], p[:y], p[:x])
        Shadow.set_c(w, gd, 0x4e, 0x1b, 0x94)
        w[:input_override] = 0xff # $592: no control until the director starts
        w[:flag6b6] = 0xff
        p[:facing] = 0
        Scheduler.spawn(w, 1)
        t[:saved] = Text.save(w, 0xc3a5, 7)
        Text.print(w, 0xc3a5, 0x39, 'READY !')
        Scheduler.spawn(w, 0x1b)
        t[:pc] = :enemies
        return 12
      when :enemies # $270e: every enemy shown at its start, facing Ptolemy
        w[:obj].each do |o|
          next if o[Obj::ST] == 0
          o[Obj::FACE] = p[:x] >= o[Obj::X] ? 0 : 9
          Shadow.set_b(w, gd, o[Obj::TYPE] + o[Obj::FACE], o[Obj::Y], o[Obj::X], o[Obj::SLOT])
        end
        t[:pc] = :ready
        return 1
      when :ready
        return 1 if w[:flag6b6] != 0
        Shadow.clear(w, 0x6c)
        Shadow.clear(w, 0x70)
        Text.restore(w, 0xc3a5, t[:saved])
        # $2066 ($21 and $14 are not ported yet: the scheduler notes them)
        [0, 4, 0x10, 0x14, 0x0e].each { |id| Scheduler.spawn(w, id) unless id == 4 && w[:round] > 100 }
        Scheduler.resume_main(w, 0x21, gd) # $208e: round 101's Dracolisk waits for the intro
        if w[:opts][:pos] # dev: --pos XX,YY (hex) puts Ptolemy there when the round starts
          w[:player][:x], w[:player][:y] = w[:opts][:pos]
        end
        if w[:opts][:force_item] # dev
          w[:item_spawn] = [0xa0, 0x18]
          Scheduler.spawn(w, 0x15)
        end
        return :killed
      end
    end
  end
end

# Tasks 1a ($801a) / 1b ($803a): scripted poses. Script = 4-byte entries [steps, pose, path offset, delay] (0 ends);
# path = (dx, dy) byte pairs from $ca04, where $80 + word jumps (the word is an arcade address: - $5702 = offset).
module ScriptAnimTask
  PATHS = :intro_paths

  def self.run(w, t, gd)
    loop do
      Scheduler.guard(t)
      case t[:pc]
      when :start
        if t[:id] == 0x1a
          t[:x] = 0
          t[:y] = 0xcc
          t[:a] = gd.a(w[:player][:char] == 0x1c ? :intro_script_small : :intro_script)
        else
          t[:x] = 0x94
          t[:y] = 0x1b
          t[:a] = gd.a(:broom_exit)
        end
        t[:pc] = :entry
      when :entry
        n = gd.byte(t[:a])
        if n == 0
          w[:flag6b6] = 0
          return :killed
        end
        t[:n] = n
        t[:p] = gd.a(PATHS) + gd.byte(t[:a] + 2)
        t[:pc] = :step
      when :step
        d = gd.byte(t[:a] + 3)
        dx = gd.byte(t[:p])
        t[:p] += 1
        if dx == 0x80
          # the links are arcade (Z80) addresses even in FS.X: rebase them onto wherever this image keeps the table
          t[:p] = gd.a(PATHS) + (((gd.byte(t[:p] + 1) << 8) | gd.byte(t[:p])) - Tables::ADDR[PATHS][1])
          dx = gd.byte(t[:p])
          t[:p] += 1
        end
        t[:x] = (t[:x] + dx) & 0xff
        t[:y] = (t[:y] + gd.byte(t[:p])) & 0xff
        t[:p] += 1
        Shadow.set_c(w, gd, gd.byte(t[:a] + 1), t[:y], t[:x])
        t[:n] -= 1
        if t[:n] == 0
          t[:a] += 4
          t[:pc] = :entry
        end
        return d
      end
    end
  end
end

# $20c4: all enemies gone. Ptolemy keeps control during the clear jingle (44 x 6 frames), then the next round.
module RoundClearTask
  def self.run(w, t, gd)
    p = w[:player]
    case t[:pc]
    when :start
      [0x1d, 0x15, 0x14, 0].each { |id| Scheduler.kill(w, id) }
      Scheduler.kill(w, 0x26) if w[:flag6f4] == 0
      Shadow.clear(w, 0)
      PalPatch.apply(w, gd, :normal) # $2100
      t[:pc] = :settle
      5 # (arcade $03f9: one tick; MAME, items check: $0c / the warp's next round come 1 frame earlier than with 6)
    when :settle
      w[:mode626] = 0
      w[:power] = 0
      unless p[:char] == 0x1c # a Wizard's shrink carries over into the next round
        p[:step_delay] = 3
        p[:speed] = 2
        p[:char] = 0
      end
      if w[:warp] != 0 # Mystical Feather: no jingle; the skipped rounds flash past (FlashTask)
        t[:pc] = :done
        return 1
      end
      if w[:round] - 1 >= 0x64
        Scheduler.spawn(w, 0x42) # $213e: the ending ($3722), then game over
        return :killed
      end
      w[:sounds] << 0x0c
      t[:n] = 0x2c
      t[:pc] = :jingle
      6
    when :jingle # after the 44th tick the next round is built at once ($216e / arcade $0447 - MAME: 264 frames of
      t[:n] -= 1  # the old round after the $0c, then the build)
      return 6 if t[:n] > 0
      t[:pc] = :wait_music
      1 # (MAME: $0c -> next round's $07 = 270 frames with the build)
    when :wait_music
      # 44 ticks cut the clear jingle on both versions' code, but on a real X68000 the jingle finishes before the next
      # round (user; the round build there takes time): with an X68000 soundtrack, also wait for the music to end
      return 1 if w[:audio_busy] && %i[original arrange].include?(w[:opts] && w[:opts][:music])
      t[:pc] = :done
      run(w, t, gd)
    when :done
      Scheduler.kill_others(w)
      w[:end_code] = :clear
      :killed
    end
  end
end

# Port task $4d: one round skipped by a Mystical Feather warp ($2184 loop, arcade $044c): the screen is cleared and the
# round built ($646 $1114 / $0baf $0d41), then shown for one 6-frame tick, no tasks. The build time is the measured one
# (BuildTimes: black, then on the arcade a few frames with only the bottom ROUND line). Ends with :flash_done.
module FlashTask
  def self.run(w, t, _gd)
    case t[:pc]
    when :start # (start_flash blacked the screen out on the frame before)
      t[:pc] = :hud
      return t[:black] - 1 if t[:black] > 1
      run(w, t, _gd)
    when :hud
      t[:pc] = :show
      if t[:hud] > 0
        w[:blackout] = :hud_bottom
        return t[:hud]
      end
      run(w, t, _gd)
    when :show
      w[:blackout] = nil
      t[:pc] = :done
      t[:shown]
    when :done
      w[:end_code] = :flash_done
      :killed
    end
  end
end

# Port task $4e: a round build at a round start (game start, round clear, new life, continue - $1114 / arcade $0d41):
# the measured build time (BuildTimes) with the screen black, then the intro ($2612, task $40) as the round appears.
# Also before an intermission ($1554 builds its picture): then next: $25.
module BuildWaitTask
  def self.run(w, t, gd)
    case t[:pc]
    # Frames from the world's frame 0: 0 .. black - 1 all black, black .. B - 1 only the bottom ROUND line (B = black +
    # hud), B the picture. MAME: the round music is heard on frame B and the intro proper (enemies, broom, then the AI)
    # starts the frame after. This first run is frame 1.
    when :start
      t[:pc] = t[:hud] > 0 ? :hud : :intro
      return t[:black] - 1 if t[:black] > 1
      run(w, t, gd)
    when :hud # frame black
      w[:blackout] = :hud_bottom
      t[:pc] = :intro
      return t[:hud]
    when :intro # frame B
      w[:blackout] = nil
      nxt = { id: t[:next] || 0x40, delay: 1, pc: :start }
      if nxt[:id] == 0x40
        w[:sounds] << IntroTask.music(w)
        nxt[:music_sent] = true
      end
      # the intro (or the intermission's flyer) takes over THIS slot (slot 0, as in a start without a build: the slots
      # of everything it spawns, and so who runs first, stay the same); first run next frame
      w[:tasks][w[:running]] = nxt
      :killed
    end
  end
end

Scheduler::IMPL[0x40] = IntroTask
Scheduler::IMPL[0x41] = RoundClearTask
Scheduler::IMPL[0x4d] = FlashTask
Scheduler::IMPL[0x4e] = BuildWaitTask
Scheduler::IMPL[0x1a] = ScriptAnimTask
Scheduler::IMPL[0x1b] = ScriptAnimTask
