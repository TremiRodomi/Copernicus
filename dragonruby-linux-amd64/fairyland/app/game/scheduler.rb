# The original's cooperative task scheduler ($1820 spawn, $186e kill, $18b6 run), with tasks as plain-data Hashes.
# A task Hash holds :id, :delay, :pc (resume label) and any locals the task keeps across yields.
# Each task module implements run(world, task, gd) -> frames to sleep (0 means 256, as in the original), or :killed.
module Scheduler
  SLOTS = 23
  IMPL = {} # id -> module, filled in by the task files

  # $1820: kill any existing task with this id, then take the first free slot; delay 1 (so a slot after the current one runs this frame)
  def self.spawn(w, id, locals = {})
    unless IMPL[id] # task not ported yet: note it so the gap is visible in logs
      w[:pending] << format('task%02x', id)
      return nil
    end
    kill(w, id)
    i = w[:tasks].index(nil)
    return nil unless i # all slots busy: fails silently, like the original
    w[:tasks][i] = { id: id, delay: 1, pc: :start }.merge(locals)
    i
  end

  # $1820 called from the original's MAIN LOOP (between two scheduler passes): the task's first run is the next pass, wherever
  # its slot is. Port stand-ins for main-loop code are tasks themselves, so a slot after the running one gets one frame more.
  def self.spawn_main(w, id)
    i = spawn(w, id)
    w[:tasks][i][:delay] = 2 if i && w[:running] && i > w[:running]
    i
  end

  # $186e: first slot with this id only
  def self.kill(w, id)
    i = w[:tasks].index { |t| t && t[:id] == id }
    w[:tasks][i] = nil if i
  end

  # $187a / $1886: suspend / resume the first slot with this id (a suspended task keeps its state and delay)
  def self.suspend(w, id)
    t = w[:tasks].find { |k| k && k[:id] == id }
    t[:suspended] = true if t
  end

  def self.resume(w, id)
    t = w[:tasks].find { |k| k && k[:id] == id }
    t[:suspended] = false if t
  end

  # Resume from a port stand-in for MAIN-LOOP code: the original resumes it between two passes, so it runs in the next
  # pass wherever its slot is. The stand-in runs inside a pass (its spawns into later slots run in this pass = the
  # original's next one), so a task in an EARLIER slot, already passed, runs now. (Round 101: task 21 in slot 0 is
  # resumed by the intro; without this it and the AI it spawns ran a frame late - MAME check, NOTES pass 49.)
  def self.resume_main(w, id, gd)
    resume(w, id)
    i = w[:tasks].index { |k| k && k[:id] == id }
    me = w[:running]
    return unless i && me && i < me
    run_slot(w, i, gd)
    w[:running] = me
  end

  # Called at the top of every task state-machine loop: a task that never yields would freeze the game, so fail loudly
  def self.guard(t)
    t[:spin] += 1
    raise "task #{format('%02x', t[:id])} is not yielding (stuck at #{t[:pc]})" if t[:spin] > 1000
  end

  # $1890: kill every task except the one running. Tasks spawned with main: true stand in for the original's main-loop
  # code (not tasks there), so they survive it.
  def self.kill_others(w)
    SLOTS.times { |i| w[:tasks][i] = nil unless i == w[:running] || (w[:tasks][i] && w[:tasks][i][:main]) }
  end

  # $18b6: once per frame
  def self.run(w, gd)
    SLOTS.times { |i| run_slot(w, i, gd) }
    w[:running] = nil
  end

  def self.run_slot(w, i, gd)
    t = w[:tasks][i]
    return unless t && !t[:suspended]
    t[:delay] -= 1
    return if t[:delay] > 0
    w[:running] = i
    t[:spin] = 0
    r = IMPL[t[:id]].run(w, t, gd)
    if r == :killed || w[:tasks][i] != t
      w[:tasks][i] = nil if w[:tasks][i].equal?(t)
    else
      t[:delay] = r == 0 ? 256 : r
    end
  end
end
