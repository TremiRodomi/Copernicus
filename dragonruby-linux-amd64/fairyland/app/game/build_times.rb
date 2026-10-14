# Round build times, MEASURED in MAME (our own measurements, not game data; NOTES pass 55). While a round is built
# ($1114 / arcade $0d41) the screen shows black; on the arcade the bottom ROUND line appears a few frames before the
# rest. The values depend on the round (its layout) and on what came before the build:
#   flash - a round passed by a Mystical Feather warp (mame_check/warp.lua, warp_x68.lua: a forced 98-round warp)
#   start - a round start after a round clear (mame_check/builds.lua, builds_x68.lua: every round cleared in turn)
# Arcade: [black, bottom line only, shown] frames (shown = the rest of the warp's 6-frame tick); start [black, line].
# X68000: black frames only (the HUD appears with the round); a flash is shown 7 frames. Its timings include the
# 10 MHz machine's lag, so they are what MAME's x68000 showed on the user's disks (one run each).
module BuildTimes
  ARC_FLASH = [ # rounds 2-100 (100 cannot be reached by a warp: its start values)
    [2, 3, 5], [5, 2, 5], [2, 3, 5], [2, 3, 5], [5, 2, 5], [2, 3, 5], [5, 3, 5], [5, 2, 5], [5, 2, 5], [2, 3, 5],
    [4, 3, 5], [6, 2, 5], [5, 3, 5], [5, 3, 5], [5, 2, 5], [5, 3, 5], [2, 3, 5], [5, 3, 5], [6, 2, 5], [2, 3, 5],
    [2, 3, 5], [5, 3, 5], [2, 3, 5], [5, 2, 5], [5, 3, 5], [2, 3, 5], [5, 3, 5], [6, 2, 5], [2, 3, 5], [2, 3, 5],
    [5, 2, 5], [6, 2, 5], [6, 2, 5], [2, 3, 5], [5, 2, 5], [2, 3, 5], [2, 3, 5], [2, 3, 5], [4, 3, 5], [5, 3, 5],
    [5, 3, 5], [5, 2, 5], [2, 3, 5], [5, 3, 5], [2, 3, 5], [5, 2, 6], [6, 3, 5], [4, 3, 5], [6, 2, 5], [2, 3, 5],
    [2, 3, 5], [2, 3, 5], [2, 3, 5], [2, 3, 5], [5, 2, 6], [2, 3, 5], [6, 2, 5], [2, 3, 5], [6, 2, 5], [5, 3, 5],
    [5, 2, 5], [2, 3, 5], [5, 2, 5], [5, 3, 5], [6, 2, 5], [5, 3, 5], [8, 3, 5], [6, 2, 5], [5, 3, 5], [2, 3, 5],
    [5, 2, 5], [2, 3, 5], [2, 3, 5], [5, 3, 5], [2, 3, 5], [5, 2, 5], [2, 3, 5], [2, 3, 5], [2, 3, 5], [6, 2, 5],
    [5, 3, 5], [5, 3, 5], [2, 3, 5], [6, 3, 5], [5, 3, 5], [2, 3, 5], [5, 2, 5], [6, 3, 5], [5, 3, 5], [2, 3, 5],
    [5, 3, 5], [2, 3, 5], [6, 2, 5], [2, 3, 5], [6, 2, 5], [5, 3, 5], [2, 3, 5], [2, 3, 5], [5, 3, 5]
  ].freeze
  ARC_START = [ # rounds 2-101
    [2, 3], [5, 3], [2, 3], [2, 3], [5, 3], [2, 3], [5, 3], [5, 2], [5, 3], [2, 3], [4, 3], [6, 2], [5, 3], [5, 3],
    [5, 2], [5, 3], [2, 3], [5, 3], [6, 2], [2, 3], [2, 3], [5, 3], [2, 3], [5, 2], [5, 3], [2, 3], [5, 3], [6, 2],
    [2, 3], [2, 3], [5, 3], [6, 2], [6, 3], [2, 3], [5, 2], [2, 3], [2, 3], [2, 3], [4, 3], [5, 3], [5, 3], [5, 2],
    [2, 3], [5, 3], [2, 3], [5, 3], [6, 3], [4, 3], [6, 2], [2, 3], [2, 3], [2, 3], [2, 3], [2, 3], [5, 3], [2, 3],
    [6, 2], [2, 3], [6, 3], [5, 3], [5, 2], [2, 3], [5, 2], [5, 3], [6, 3], [5, 3], [8, 3], [6, 2], [5, 3], [2, 3],
    [5, 3], [2, 3], [2, 3], [5, 3], [2, 3], [5, 2], [2, 3], [2, 3], [2, 3], [6, 3], [5, 3], [5, 3], [2, 3], [6, 3],
    [5, 3], [2, 3], [5, 3], [6, 3], [5, 3], [2, 3], [5, 3], [2, 3], [6, 2], [2, 3], [6, 3], [5, 3], [2, 3], [2, 3],
    [5, 3], [2, 3]
  ].freeze
  X68_FLASH = [ # rounds 2-100
    19, 21, 19, 19, 21, 19, 21, 21, 21, 19, 21, 21, 20, 21, 20, 21, 19, 20, 21, 19, 19, 21, 17, 20, 22, 19, 20, 20,
    17, 17, 19, 20, 21, 19, 20, 18, 18, 19, 21, 21, 21, 19, 17, 20, 19, 20, 21, 20, 21, 18, 17, 17, 17, 17, 19, 19,
    21, 19, 21, 21, 20, 19, 21, 22, 20, 20, 22, 20, 20, 18, 20, 18, 19, 21, 18, 20, 18, 18, 18, 22, 21, 20, 18, 22,
    19, 18, 20, 21, 20, 17, 21, 18, 21, 18, 20, 21, 18, 18, 20
  ].freeze
  X68_START = [ # rounds 2-101
    20, 22, 20, 20, 22, 20, 21, 22, 22, 20, 22, 23, 22, 21, 22, 22, 20, 22, 23, 20, 19, 22, 20, 22, 22, 20, 22, 20,
    20, 20, 22, 23, 23, 20, 20, 20, 20, 20, 21, 22, 22, 19, 20, 23, 20, 22, 23, 22, 21, 20, 20, 20, 20, 20, 22, 19,
    23, 20, 23, 22, 22, 20, 21, 22, 23, 22, 25, 23, 22, 18, 22, 20, 20, 22, 20, 22, 18, 20, 20, 23, 22, 22, 20, 22,
    22, 20, 22, 23, 22, 20, 21, 20, 23, 20, 23, 22, 20, 18, 22, 20
  ].freeze
  X68_SHOWN = 7
  # the intermission picture ($1554 / arcade $727e) is built first too: black frames before it appears
  INTER = { arcade: 2, x68000: 16 }.freeze

  # [black, line, shown] for a round flashed past by a warp; on the arcade the first one after the round clear builds
  # like a start
  def self.flash(x68k, r, first)
    r = r.clamp(2, 100)
    return [X68_FLASH[r - 2], 0, X68_SHOWN] if x68k # (no first-flash difference on the X68000: MAME, warp from 97)
    return ARC_START[r - 2] + [ARC_FLASH[r - 2][2]] if first
    ARC_FLASH[r - 2]
  end

  # [black, line] for a round start (round 1 - a new game - builds like round 2)
  def self.start(x68k, r)
    r = r.clamp(2, 101)
    x68k ? [X68_START[r - 2], 0] : ARC_START[r - 2]
  end

  def self.inter(x68k)
    INTER[x68k ? :x68000 : :arcade]
  end
end
