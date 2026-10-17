# The coin-up menu (port task 4b; user design): inserting a credit during the attract opens a menu in the style of the
# X68000 version's front end - its start menu under the logo ($10a4 / $32fc: cursor glyph $5b = Ptolemy's hat, attr $3c,
# items attr $38; $3348 patches graphic colour 64 - group 4's colour 0, the hat's background - to black ($3364: $0080 ->
# $0001); only on confirming a start does $336a turn it orange ($8681))
# and its GAME OPTIONS page ($346a: the selected row attr $3a, the others $39; up / down picks a row, left / right
# changes it). Pages:
#   main    ARCADE START / CASUAL START / GAME OPTIONS
#   ARCADE START goes straight into a game: strictly the arcade - factory DIP settings, no QOL (high scores and
#           progress kept). CASUAL START opens the setup page: ROUND SELECT from the last round reached up to the best (like
#           $3206), LIVES and the QOL options, then START GAME (progress saved only).
#   options preferences for both modes: BEHAVIOUR (arcade / X68000 where the versions differ), MUSIC, volumes, COLOURS,
#           WIDGETS, GRAPHICS > (its own page: window, scaling, filters, borders - gfx/display.rb), CONTROLS > (the
#           keyboard and pad bindings, two per action: left / right picks the slot, OK waits for the new key or button
#           - main.rb reads it through w[:capture] / w[:captured] - and 4 s without one clears the slot; game/controls.rb)
# Input: w[:menu_in] from main.rb, held bits (MenuTask::UP ... BACK). Directions auto-repeat like $3296.
# Ends with w[:end_code] = :menu_title (back to the attract) or :menu_start (w[:menu_start] = { mode:, round: }).
module MenuTask
  UP = 1
  DOWN = 2
  LEFT = 4
  RIGHT = 8
  OK = 16
  BACK = 32
  CURSOR = 0x5b
  MAIN = [['ARCADE START', 'HISCORE & PROGRESS SAVED'], ['CASUAL START', 'ONLY PROGRESS SAVED'],
          ['GAME OPTIONS', ''], ['QUIT GAME', '']].freeze
  LABELS = { round: 'ROUND', lives: 'LIVES', behaviour: 'BEHAVIOUR', music: 'MUSIC', short_hop: 'EASY SHORT HOP',
             colours: 'COLOURS', widgets: 'SHOW', music_volume: 'MUSIC VOLUME', sfx_volume: 'SFX VOLUME', boot_screen: 'BOOT SCREEN', sfx_filter: 'SFX FILTER',
             graphics: 'GRAPHICS', fullscreen: 'FULLSCREEN', window: 'WINDOW', scale: 'SCALE', aspect: 'ASPECT',
             smooth: 'SMOOTH', scanlines: 'SCANLINES', mask: 'MASK', mask_level: 'MASK LEVEL', vignette: 'VIGNETTE',
             border: 'BORDER', border_image: 'IMAGE', widgets_page: 'WIDGETS', widget_level: 'LEVEL',
             widget_item: 'BONUS ITEM', widget_timer: 'HORNED TIMER', widget_moon: 'MOON', widget_music: 'MUSIC',
             controls_page: 'CONTROLS', kb_left: 'LEFT', kb_right: 'RIGHT', kb_jump: 'JUMP', kb_spell: 'SPELL',
             kb_start: 'START', kb_rewind: 'REWIND', pad_jump: 'PAD JUMP', pad_spell: 'PAD SPELL', pad_start: 'PAD START',
             pad_rewind: 'PAD REWIND',
             controls_reset: 'RESET DEFAULTS',
             start: 'START GAME',
             exit: 'EXIT' }.freeze
  NAMES = { 0 => 'ENDLESS', arcade: 'ARCADE', x68000: 'X68000', original: 'X68 OG', arrange: 'ARRANGE',
            standard: 'STANDARD', pcb: 'PCB', false => 'OFF', true => 'ON', off: 'OFF',
            w720: '1280X720', w900: '1600X900', w1080: '1920X1080', w1440: '2560X1440', integer: 'INTEGER', fit: 'FIT',
            square: 'SQUARE', crt: '4:3', grille: 'GRILLE', dot: 'DOT', black: 'BLACK', blue: 'BLUE', grey: 'GREY',
            theme: 'THEME', sharp: 'SHARP', soft: 'SOFT', bezel: 'BEZEL', image: 'IMAGE' }.freeze

  # name-table address of (row, column) - row 0 is the top line, 32 columns
  def self.at(row, col)
    0xc7ff - 2 * (row * 32 + col)
  end

  def self.run(w, t, gd)
    if t[:pc] == :start
      t[:pc] = :run
      t[:rep] = [0, 0, 0, 0, 0] # $3296: [last held, frames to repeat, repeat delay, repeats left, repeats per stage]
      t[:prev] = 0xff # nothing counts as a new press on the first frame (the coin key is still down)
      w[:sounds] << 0x06 unless t[:coin] == false # the coin jingle ($30ee) - only for a real credit, not QUIT TO MENU
      w[:bg_pal] = { set: 4, patch: { 64 => 0x0001 } } # $3348: the cursor's background black
      w[:bg_pal_shown] = false
      show(w, t, gd, :main)
      return 1
    end
    return capture(w, t) if t[:capturing]
    held = w[:menu_in] || 0
    edge = held & ~t[:prev]
    t[:prev] = held
    dirs = repeat(t, held & 15)
    page = t[:page]
    if edge & BACK != 0
      return finish(w, :menu_title) if page == :main
      Settings.write(w[:opts])
      show(w, t, gd, %i[graphics widgets_page controls_page].include?(page) ? :options : :main)
      return 1
    end
    rows = t[:rows]
    if dirs & (UP | DOWN) != 0
      t[:sel] = (t[:sel] + (dirs & DOWN != 0 ? 1 : -1)) % rows.size
      draw(w, t)
    end
    key = rows[t[:sel]]
    if dirs & (LEFT | RIGHT) != 0 && page == :controls_page
      t[:slot] = dirs & RIGHT != 0 ? 1 : 0
      draw(w, t)
    elsif dirs & (LEFT | RIGHT) != 0 && page != :main
      change(w, t, key, dirs & RIGHT != 0 ? 1 : -1)
    elsif edge & OK != 0
      case page
      when :main
        if t[:sel] == 0 # ARCADE START: no choices to make
          Settings.write(w[:opts])
          w[:menu_start] = { mode: :arcade, round: 1 }
          return finish(w, :menu_start)
        end
        if t[:sel] == 3 # QUIT GAME
          Settings.write(w[:opts])
          return finish(w, :menu_quit)
        end
        show(w, t, gd, t[:sel] == 1 ? :setup_casual : :options)
      when :options
        if key == :graphics then show(w, t, gd, :graphics)
        elsif key == :widgets_page then show(w, t, gd, :widgets_page)
        elsif key == :controls_page then show(w, t, gd, :controls_page)
        elsif key == :exit then show(w, t, gd, :main)
        else change(w, t, key, 1)
        end
      when :graphics, :widgets_page
        key == :exit ? (Settings.write(w[:opts]); show(w, t, gd, :options)) : change(w, t, key, 1)
      when :controls_page
        if key == :exit
          Settings.write(w[:opts])
          show(w, t, gd, :options)
        elsif key == :controls_reset
          Controls.reset(w[:opts])
          draw(w, t)
        else
          t[:capturing] = 4 * 60
          w[:capture] = key
          draw(w, t)
        end
      else
        if key == :start
          Settings.write(w[:opts])
          w[:menu_start] = { mode: page == :setup_casual ? :casual : :arcade, round: (t[:round] || 0) + 1 }
          return finish(w, :menu_start)
        end
        change(w, t, key, 1)
      end
    end
    1
  end

  # CONTROLS: waiting for the new key / button (main.rb fills w[:captured]); 4 s without one clears the slot
  def self.capture(w, t)
    key = t[:rows][t[:sel]]
    got = w[:captured]
    t[:capturing] -= 1
    return 1 unless got || t[:capturing] <= 0
    got ? Controls.bind(w[:opts], key, t[:slot], got) : Controls.unbind(w[:opts], key, t[:slot])
    t[:capturing] = nil
    w[:capture] = nil
    w[:captured] = nil
    t[:prev] = 0xff # (the key just bound is still down: it must not act on the menu)
    draw(w, t)
    1
  end

  def self.finish(w, code)
    w[:end_code] = code
    :killed
  end

  # $3296: a new press counts at once; held, it repeats after 16 frames, 4 times every 16, then 16 times every 4,
  # then every frame
  def self.repeat(t, bits)
    r = t[:rep]
    if bits == 0 || bits != r[0]
      t[:rep] = [bits, 16, 16, 4, 4]
      return bits
    end
    r[1] -= 1
    return 0 if r[1] > 0
    r[3] -= 1
    if r[3] == 0
      r[2] >>= 2 if (r[2] >> 2) != 0
      r[4] <<= 2
      r[3] = r[4]
    end
    r[1] = r[2]
    bits
  end

  def self.change(w, t, key, dir)
    return if %i[start exit graphics widgets_page controls_page controls_reset].include?(key) || Controls::DEFAULTS[key]
    if key == :round # $327a: 1 .. the best round reached, no wrap
      t[:round] = (t[:round] + dir).clamp(0, w[:save][:best_round])
    else
      Settings.step(w[:opts], key, dir)
      w[:settings_changed] = key # main.rb applies behaviour / colours at once
    end
    draw(w, t)
  end

  # LEFT 1 .. RIGHT 4 / OFF
  def self.slot_name(v)
    return 'OFF' if v.nil? || v == :off
    v.to_s.tr('_', ' ').upcase # TOP LEFT ... BOTTOM RIGHT
  end

  # a picture's file name as the game font can show it (upper case, 10 characters)
  def self.image_name(name)
    return 'NONE' if Display.images.empty?
    name = Display.images.first if name.nil? || name.empty?
    name = name[0, name.size - 4] if name.downcase.end_with?('.png') # (mruby: no Regexp)
    name.upcase[0, 10].each_char.map { |c| c.ord >= 0x20 && c.ord <= 0x5a ? c : '-' }.join # (the font's characters only)
  rescue StandardError
    'NONE'
  end

  def self.show(w, t, gd, page)
    t[:page] = page
    t[:sel] = 0
    Scenes.clear(w)
    Hud.top(w)
    case page
    when :main # $10a4: the logo, then the items ($32fc)
      t[:rows] = MAIN.map { |m| m[0] }
      Scenes.block(w, gd, 0xc62f, gd.a(:title_logo), 0xbb)
    when :options
      t[:rows] = %i[behaviour music music_volume sfx_volume sfx_filter colours boot_screen graphics widgets_page
                    controls_page exit]
      Text.print(w, at(6, 9), 0x3a, 'GAME  OPTIONS')
    when :graphics
      t[:rows] = %i[fullscreen window scale aspect smooth scanlines mask mask_level vignette border border_image exit]
      Text.print(w, at(6, 11), 0x3a, 'GRAPHICS')
    when :widgets_page
      t[:rows] = %i[widgets widget_level widget_item widget_timer widget_moon widget_music exit]
      Text.print(w, at(6, 12), 0x3a, 'WIDGETS')
    when :controls_page
      t[:rows] = Controls::KB_ACTIONS + Controls::PAD_ACTIONS + %i[controls_reset exit]
      t[:slot] = 0
      Text.print(w, at(6, 12), 0x3a, 'CONTROLS')
    else
      casual = page == :setup_casual
      t[:rows] = %i[round lives short_hop start]
      t[:round] = casual ? [w[:save][:last_round], w[:save][:best_round]].min : nil
      title = casual ? 'CASUAL  MODE' : 'ARCADE  MODE'
      Text.print(w, at(6, 16 - title.size.idiv(2)), 0x3a, title)
    end
    draw(w, t)
  end

  def self.draw(w, t)
    if t[:page] == :main
      t[:rows].each_with_index do |name, k|
        Text.put(w, at(19 + k, 8), *(k == t[:sel] ? [CURSOR, 0x3c] : [0x20, 0x38]))
        Text.print(w, at(19 + k, 10), 0x38, name)
      end
      desc = MAIN[t[:sel]][1]
      Text.print(w, at(24, 0), 0x39, ' ' * 32)
      Text.print(w, at(24, 16 - desc.size.idiv(2)), 0x39, desc)
      return
    end
    return draw_controls(w, t) if t[:page] == :controls_page
    long = t[:rows].size > 9 # (longer pages: one row apart)
    t[:rows].each_with_index do |key, k|
      row = long ? 8 + k + (key == :exit ? 1 : 0) : 9 + 2 * k + (%i[start exit].include?(key) ? 1 : 0)
      attr = k == t[:sel] ? 0x3a : 0x39
      Text.put(w, at(row, 3), *(k == t[:sel] ? [CURSOR, 0x3c] : [0x20, 0x38]))
      Text.print(w, at(row, 5), attr, LABELS[key])
      next if %i[start exit].include?(key)
      v = if key == :round then (t[:round] + 1).to_s
          elsif key == :graphics || key == :widgets_page then '>'
          elsif key.to_s.start_with?('widget_') then slot_name(w[:opts][key])
          elsif key == :border_image then image_name(w[:opts][:border_image])
          elsif %i[scanlines vignette].include?(key) && w[:opts][key] == 0 then 'OFF'
          elsif key.to_s.end_with?('volume') || key.to_s.end_with?('level') || %i[scanlines vignette].include?(key) then w[:opts][key].to_s
          else NAMES.fetch(w[:opts][key], w[:opts][key].to_s)
          end
      if key.to_s.start_with?('widget_') # corner names are longer: from column 18
        Text.print(w, at(row, 18), attr, v.ljust(12))
      else
        Text.print(w, at(row, 21), attr, v.ljust(11)) # to the screen edge: a shorter value clears a longer one (1920X1080)
      end
    end
  end

  # CONTROLS: the label, then the two bindings (columns 16 and 24); the selected row's chosen slot in the cursor's colour
  def self.draw_controls(w, t)
    t[:rows].each_with_index do |key, k|
      row = 8 + k + (k >= Controls::KB_ACTIONS.size ? 1 : 0) + (k >= Controls::DEFAULTS.size ? 1 : 0)
      sel = k == t[:sel]
      Text.put(w, at(row, 3), *(sel ? [CURSOR, 0x3c] : [0x20, 0x38]))
      Text.print(w, at(row, 5), sel ? 0x3a : 0x39, LABELS[key])
      next unless Controls::DEFAULTS[key]
      list = w[:opts][key] || Controls::DEFAULTS[key]
      2.times do |i|
        v = sel && t[:capturing] && i == t[:slot] ? '...' : Controls.name(list[i])
        Text.print(w, at(row, 16 + 8 * i), sel && i == t[:slot] ? 0x3c : 0x39, v.ljust(7))
      end
    end
    help = if t[:capturing] then Controls.kb_action?(t[:rows][t[:sel]]) ? 'PRESS A KEY  (WAIT = NONE)' : 'PRESS A BUTTON  (WAIT = NONE)'
           else 'ARROWS SLOT   OK CHANGE'
           end
    Text.print(w, at(24, 0), 0x39, ' ' * 32)
    Text.print(w, at(24, 16 - help.size.idiv(2)), 0x39, help)
  end
end

Scheduler::IMPL[0x4b] = MenuTask
