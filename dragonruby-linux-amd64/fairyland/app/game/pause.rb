# Pause (user design, from the X68000 version's ESC pause - $27c: ESC freezes everything until pressed again, no text):
# Esc / P during a game freezes it and opens a small menu in the game's font on a black box, drawn on its own layer over
# the screen: CONTINUE, LOSE A LIFE (CASUAL only - the X68000's F1 key, $2268: $62e = $40, no killer $596 = $ff - for
# getting out of a stuck spot; only while Ptolemy is in play - not at READY, nor once the round is ending),
# QUIT TO MENU (back to the coin-up menu; CASUAL records the round reached first).
module Pause
  BOX = [7, 11, 18, 8].freeze # col, row, width, height (cells)
  ITEMS = { continue: 'CONTINUE', give_up: 'LOSE A LIFE', quit: 'QUIT TO MENU' }.freeze

  # not on the title / attract / menus, nor once the game is over: GAME OVER (port task $43), name entry ($44) and the
  # continue screen ($45) - user, both modes
  OVER = [0x43, 0x44, 0x45].freeze

  def self.allowed?(s)
    !s.attract && !s.menu && !s.script && !s.shot && !s.world[:tasks].any? { |t| t && OVER.include?(t[:id]) }
  end

  # LOSE A LIFE only while Ptolemy is in play (user): the director runs (not READY / an intermission) and the round is
  # not ending (no clear, escape or death under way)
  def self.playing?(w)
    w[:round_world] && w[:end_code] == 0 && !w[:clearing] && !w[:timer_end] && (w[:enemies_left] & 0x7f) != 0 &&
      w[:tasks].any? { |t| t && t[:id] == 0 }
  end

  def self.open(args)
    s = args.state
    w = s.world
    rows = [:continue]
    rows << :give_up if s.settings[:mode] == :casual && playing?(w)
    rows << :quit
    s.pause = { rows: rows, sel: 0, prev: 0xff }
    Audio.pause(args, true)
    render(args)
  end

  # one frame while paused; returns the action taken, if any
  def self.step(args)
    s = args.state
    pz = s.pause
    held = read_menu_input(args)
    held |= MenuTask::BACK if Controls.pause?(args, s.prefs) # (the pause key closes it again)
    (s.fake_keys[Kernel.tick_count] || []).each { |k| held |= MenuTask.const_get(k.to_s.upcase) unless %i[coin pause].include?(k) }
    edge = held & ~pz[:prev]
    pz[:prev] = held
    return close(args) if edge & MenuTask::BACK != 0
    if edge & (MenuTask::UP | MenuTask::DOWN) != 0
      pz[:sel] = (pz[:sel] + (edge & MenuTask::DOWN != 0 ? 1 : -1)) % pz[:rows].size
      render(args)
    end
    return unless edge & MenuTask::OK != 0
    case pz[:rows][pz[:sel]]
    when :continue then close(args)
    when :give_up
      close(args)
      s.world[:give_up] = true # main.rb: as soon as the director runs and Ptolemy is not already dying
    when :quit
      close(args)
      quit_to_menu(args)
    end
  end

  def self.close(args)
    args.state.pause = nil
    Audio.pause(args, false)
  end

  # the cells of the box: [cell index, tile, attr]; colour 0 is drawn black
  def self.render(args)
    pz = args.state.pause
    col, row, wd, ht = BOX
    cells = {}
    ht.times { |r| wd.times { |c| cells[(row + r) * 32 + col + c] = [0x20, 0x38] } }
    put = ->(r, c, str, attr) { str.each_char.with_index { |ch, k| cells[r * 32 + c + k] = [ch.ord, attr] } }
    put.call(row + 1, col + 6, 'PAUSE', 0x3a)
    pz[:rows].each_with_index do |key, k|
      sel = k == pz[:sel]
      cells[(row + 3 + k) * 32 + col + 1] = sel ? [MenuTask::CURSOR, 0x3c] : [0x20, 0x38]
      put.call(row + 3 + k, col + 3, ITEMS[key], sel ? 0x3a : 0x39)
    end
    Screen.overlay_cells(cells)
  end
end
