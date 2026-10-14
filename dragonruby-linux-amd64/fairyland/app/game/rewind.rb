# Rewind (port feature, CASUAL mode only - ARCADE stays the arcade, and records high scores): while REWIND is held the
# game steps back through snapshots of the last SECONDS seconds, one per EVERY frames (so it plays back at that speed);
# on release it goes on from there. All game state is plain data in the world hash (World.new_round), so a snapshot is a
# deep copy of it; big flat Integer arrays (tile map, collision map) are copied with one dup. Snapshots are taken only in
# round worlds (not intermissions, warp flashes or the ending), and carry the round number, so rewinding back past a
# death or a round clear rebuilds that round's screen. The music is held while rewinding; on release, if the snapshot
# was playing another music command, that one starts again (from its beginning).
module Rewind
  EVERY = 2
  SECONDS = 20
  SIZE = 60 * SECONDS / EVERY
  SKIP = %i[opts sounds sounds_played].freeze # settings (shared), this frame's sound queue

  def self.deep(o)
    case o
    when Hash
      h = {}
      o.each { |k, v| h[k] = deep(v) }
      h
    when Array
      o.size > 64 && o[0].is_a?(Integer) ? o.dup : o.map { |v| deep(v) }
    when String then o.dup
    else o
    end
  end

  def self.allowed?(s)
    s.settings[:mode] == :casual && !s.attract && !s.menu && !s.objlog
  end

  def self.clear(s)
    s.rewind = { buf: [], k: 0, active: false }
  end

  # after a frame of play: every EVERY frames a snapshot of a round world, once the round is under way (the director,
  # task 0, runs; not while the round is built or its intro plays - a rewind there would replay the round start)
  def self.record(args)
    s = args.state
    return unless allowed?(s) && s.world[:round_world] && !s.world[:blackout]
    return unless s.world[:tasks].any? { |t| t && t[:id] == 0 }
    r = s.rewind || clear(s)
    r[:k] += 1
    return if r[:k] % EVERY != 0
    w = s.world
    snap = {}
    w.each { |k, v| snap[k] = deep(v) unless SKIP.include?(k) }
    r[:buf] << { w: snap, round: s.round, music: Audio.music_cmd }
    r[:buf].shift if r[:buf].size > SIZE
  end

  # one frame with REWIND held: back one snapshot (the oldest one stays). Returns true when it took over the frame.
  def self.step(args, held)
    s = args.state
    r = s.rewind
    unless held && allowed?(s) && r && !r[:buf].empty? && s.world[:round_world]
      finish(args) if r && r[:active]
      return false
    end
    unless r[:active]
      r[:active] = true
      Audio.pause(args, true)
    end
    snap = r[:buf].size > 1 ? r[:buf].pop : r[:buf][0]
    restore(args, snap)
    true
  end

  def self.restore(args, snap)
    s = args.state
    w = deep(snap[:w])
    w[:opts] = s.settings
    w[:sounds] = []
    w[:sounds_played] = []
    if snap[:round] != s.round || !s.world[:round_world] # another round: rebuild its screen set-up
      s.round = snap[:round]
      s.builder.build(s.round)
    end
    s.world = w
    s.game = w[:game]
    Screen.setup(s.gd, s.builder, w[:bg_pal])
    Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
    w[:bg_dirty].clear
    s.rewind[:music] = snap[:music]
  end

  def self.finish(args)
    s = args.state
    r = s.rewind
    r[:active] = false
    Audio.pause(args, false)
    return if r[:music] == Audio.music_cmd
    r[:music] ? s.world[:sounds] << r[:music] : Audio.stop_music(args) # (Audio.update plays it next frame)
  end
end
