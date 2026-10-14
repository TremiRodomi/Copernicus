# Optional info panels in the side borders (GAME OPTIONS > WIDGETS; user idea, in the style of M2's arcade ports). They
# only read the game state, never change it. Panels:
#   LEVEL   the level ($705) and EXP ($57f) towards the next level threshold ($706)
#   BONUS ITEM  the walking counter ($3f0e: every 800 px walked an item appears) and the items that can come now with
#           their odds - $7534: group by enemies left ($c902), tier by a roll & $7f against the EXP bracket's odds ($c8de)
#   HORNED TIMER  the round timer ($610, task 04) as a bar: hurry-up mark at $41, full = Horned ($46); with one enemy
#           left it counts to its escape. Text only for HURRY UP! / LAST ENEMY REMAINING
#           Round 101 (user): the panel becomes DRACOLISK, the boss's health (widget_drac)
#   MOON    the moon countdown ($61b, task 14: one tick per 120 frames, 60 while shrunk)
#   MUSIC   the track playing (its file name: the arcade set's are the official titles of the user's PCB recording,
#           the track number and intro / loop dropped), the set, and the time since it started (user idea)
# Look: the game's own 8x8 font (BG characters $20-$5f of the player's data, made white and tinted), the item sprites as
# icons. Size: a panel is COLS (or NARROW) characters wide; its font pixel is a whole number of LOGICAL (720p) pixels, the
# largest that fits the border beside the playfield, so the panels keep the same share of the screen at every resolution
# (user: they shrank at 1080p when sized in whole screen pixels). They are drawn sharp into a 1280 x 720 texel layer,
# then the layer is scaled to the window LINEAR (user, pass 52: even at 1.5x, where nearest made some font pixels 1
# screen px and some 2; other choices kept in NOTES pass 52). They never cover the game.
# Layout (user): each panel OFF or in one of four corners of the side borders (settings widget_*). The panels of one
# corner stack in PANELS order (= the menu's): top corners from the top down, bottom corners the same way but the
# whole stack sits on the bottom edge.
module Widgets
  PANELS = %i[widget_level widget_item widget_timer widget_moon widget_music].freeze
  SLOTS = %i[top_left bottom_left top_right bottom_right off].freeze
  LEGACY = { left1: :top_left, left2: :top_left, left3: :bottom_left, left4: :bottom_left, # settings.txt before
             right1: :top_right, right2: :top_right, right3: :bottom_right, right4: :bottom_right }.freeze # pass 46
  MARGIN = 12 # logical px between a stack and the screen edge
  GAP = 6     # font px between panels
  COLS = 23   # characters per panel line (icon + MYSTICAL FEATHER + odds)
  NARROW = 19 # the narrow layout (odds under the item name, shorter texts): used when it gets a larger font pixel -
              # a narrow border (4:3 + bezel: 1 logical px instead of 0.9)
  PAD = 4   # font pixels of padding inside a panel
  ITEMS = ['SILVER SCEPTER', 'SILVER SCEPTER', 'MOON TIARA', 'MAGIC STAFF', 'MAGIC STAFF', 'SCROLL OF FIRE',
           'MYSTICAL ORB', 'MYSTICAL ORB', 'GLASS POTION', 'HOLY WATER', 'GOLD SCEPTER', 'STAR TIARA', 'CRYSTAL RING',
           'SCROLL OF ICE', 'CHANGE POTION', 'BOOK OF LIFE', 'MYSTICAL FEATHER', 'BOOK OF DEATH'].freeze
  # colours after the HUD's: yellow titles (1UP / HIGH SCORE), white text, the round line's orange for warnings
  TITLE = [255, 222, 66].freeze
  INK = [236, 236, 236].freeze
  DIM = [150, 150, 176].freeze
  WARN = [255, 120, 96].freeze
  FRAME = [[22, 20, 44], [90, 84, 150], [8, 8, 16]].freeze # fill, light edge, shadow edge

  # ---- the font atlas: one row of 64 glyphs, white where the character has ink ----
  def self.font(args)
    gd = args.state.gd
    @font ||= begin
      px = Array.new(512 * 8, 0)
      64.times do |k|
        8.times do |y|
          8.times { |x| px[y * 512 + k * 8 + x] = gd.bgchr[(0x20 + k) * 64 + y * 8 + x] != 0 ? 0xffffffff : 0 }
        end
      end
      px
    end
    pa = args.pixel_array(:wfont) # (handed over every tick it is used: DragonRuby clears its pixel-array list)
    pa.width = 512
    pa.height = 8
    pa.pixels = @font
  end

  # Fades (user): the panels fade in as a game starts, go see-through while Ptolemy dies (until the round restarts) and
  # fade out for the ending, the game over and its scenes (name entry, continue). MUSIC has its own fade (user): deaths
  # and the ending leave it alone; it stays through the game over (and ARCADE's high score entry) and goes after it.
  # Port-only: the alphas live here, not in the game state (a rewind out of a death simply fades them back in).
  DIMMED = 0.3
  FADE_IN = 1 / 30.0   # per frame
  FADE_OUT = 1 / 45.0
  DEATH_CODES = [0x10, 0x20, 0x40, 0x80, 0xff].freeze # w[:end_code] while the director plays a death (tasks/director.rb)
  ENDED_TASKS = [0x42, 0x43, 0x44, 0x45].freeze # the ending, game over, name entry, continue
  # the WIDGETS page's preview: a made-up mid-round state (the timer and the walk counter run so the bars move)
  SAMPLE_GAME = { level: 4, exp: 37, exp_next: 0x3c, steps: 0, moon: 0x30 }.freeze

  # every frame: in a game, the panels at their fades; on the menu's WIDGETS page, a preview with sample values
  def self.frame(args)
    s = args.state
    w = s.world
    if s.menu || !s.prefs[:widgets]
      @alpha = @music_alpha = 0.0 # (a game starts with them faded out)
      t = s.menu && w[:tasks].compact.find { |k| k[:id] == 0x4b }
      preview(args) if s.prefs[:widgets] && t && t[:page] == :widgets_page
      return
    end
    ids = w[:tasks].compact.map { |k| k[:id] }
    target = if s.attract || ids.any? { |id| ENDED_TASKS.include?(id) } then 0.0
             elsif DEATH_CODES.include?(w[:end_code]) then DIMMED
             else 1.0
             end
    music = s.attract || ids.include?(0x45) ? 0.0 : 1.0 # (the continue screen or the title)
    @alpha = fade(@alpha || 0.0, target)
    @music_alpha = fade(@music_alpha || 0.0, music)
    draw(args, w, s.game, Audio.now_playing, @alpha, @music_alpha) if @alpha > 0 || @music_alpha > 0
  end

  def self.fade(a, target)
    a < target ? [a + FADE_IN, target].min : [a - FADE_OUT, target].max
  end

  def self.preview(args)
    f = Kernel.tick_count
    w = { drac: nil, t610: (f.idiv(6) % 0x50).clamp(0, 0x46), t611: 0, enemies_left: 3, tasks: [], player: { char: 0 },
          night: 0, round_world: true }
    g = SAMPLE_GAME.merge(steps: f % 800)
    np = Audio.now_playing || { name: 'NOW PLAYING', set: 'ARCADE', frames: f % 3600 }
    draw(args, w, g, np, 1.0, 1.0)
  end

  # two layers, so MUSIC can fade on its own: each lays out every panel (the stacks keep their places) but draws
  # only its own
  def self.draw(args, w, g, np, alpha, music_alpha)
    rect = Display.rect
    return unless rect
    @w = w
    @g = g
    @np = np
    [[:widget_layer, PANELS - [:widget_music], alpha], [:widget_music_layer, [:widget_music], music_alpha]].each do |path, keys, a|
      next if a <= 0
      @only = keys
      @out = Display.target(args, path, 1280, 720)
      panels(args, rect)
      next if @out.sprites.empty?
      Display.texels(args, @out.sprites)
      args.outputs.sprites << { x: 0, y: 0, w: 1280, h: 720, path: path, scale_quality_enum: 1, a: (255 * a).round }
                              .merge(Display.src(args, 0, 0, 1280, 720))
    end
  end

  # a one-line banner in the panels' style (frame, game font, title colour), centred under the playfield's HUD - shown
  # whatever the WIDGETS setting (rewind). Its own layer, sized like the panels: whole logical pixels, at most 2.
  def self.banner(args, str)
    rect = Display.rect
    return unless rect
    font(args)
    @out = Display.target(args, :banner_layer, 1280, 720)
    px, py, pw, ph = rect
    u = [[(pw - 16) / units(str.size), 2].min.floor, 1].max
    w = units(str.size) * u
    h = (8 + 2 * PAD + 4) * u
    x = px + ((pw - w) / 2).floor
    top = py + ph - (20 * ph / 224.0).floor # (under the HUD's top two text rows, game lines 16-31)
    fill, light, dark = FRAME
    box(@out, x, top - h, w, h, dark)
    box(@out, x, top - h + u, w - u, h - u, light)
    box(@out, x + u, top - h + u, w - 2 * u, h - 2 * u, fill)
    text(@out, x + (PAD + 2) * u, top - h + (PAD + 2) * u, u, str, TITLE)
    Display.texels(args, @out.sprites)
    args.outputs.sprites << { x: 0, y: 0, w: 1280, h: 720, path: :banner_layer, scale_quality_enum: 1 }
                            .merge(Display.src(args, 0, 0, 1280, 720))
  end

  # the panels in the layer's texels (= 720p logical pixels)
  def self.panels(args, rect)
    s = args.state
    font(args)
    px, py, pw, ph = rect
    fp = Display.frame_pad(s.prefs)
    px -= fp
    pw += 2 * fp
    left_w = px
    right_w = 1280 - px - pw
    areas = Hash.new { |h, k| h[k] = [] }
    PANELS.each do |key|
      slot = s.prefs[key] || :off
      areas[slot] << key unless slot == :off
    end
    %i[left right].each do |side|
      tops = areas[:"top_#{side}"]
      bottoms = areas[:"bottom_#{side}"]
      next if tops.empty? && bottoms.empty?
      avail = side == :left ? left_w : right_w
      wide = fit(avail - 16, COLS)
      slim = fit(avail - 16, NARROW)
      @cols, u = slim > wide ? [NARROW, slim] : [COLS, wide] # (a tie: wide; mruby arrays have no <=>)
      next if u < 0.6
      pw_l = units(@cols) * u
      x0 = side == :left ? px - pw_l - ((px - pw_l) / 2).floor : px + pw + ((1280 - px - pw - pw_l) / 2).floor
      stack(args, tops, x0, 720 - MARGIN, u)
      stack(args, bottoms, x0, MARGIN + stack(args, bottoms, x0, 0, u, true), u) unless bottoms.empty?
    end
  end

  # font pixels across a panel of c characters
  def self.units(c)
    c * 8 + 2 * PAD + 4
  end

  # logical pixels per font pixel for c characters in avail logical pixels: whole when possible, else shrunk to fit a
  # very narrow border, down to 0.6
  def self.fit(avail, c)
    v = avail / units(c)
    v >= 1 ? v.floor : v
  end

  def self.narrow?
    @cols == NARROW
  end

  # draws the panels top-down from y; returns their total height (dry: measures only, draws nothing)
  def self.stack(args, keys, x, y, u, dry = false)
    top = y
    keys.each_with_index do |key, k|
      @dry = dry || !@only.include?(key) # (the other layer's panels: measured only)
      y = send(key, args, x, y - (k > 0 ? GAP * u : 0), u)
    end
    top - y
  ensure
    @dry = false
  end

  # ---- panels: each draws itself with its top at y and returns its bottom ----
  def self.widget_level(args, x, y, u)
    g = @g
    panel(args, x, y, u, 'LEVEL', 3.5) do |l|
      l.call(0, "LEVEL #{g[:level]}", INK)
      l.call(1, narrow? ? "EXP #{g[:exp]}  NEXT #{g[:exp_next]}" : "EXP #{g[:exp]}   NEXT AT #{g[:exp_next]}", DIM)
      l.call(2.5, nil, nil, [g[:exp], g[:exp_next], [110, 190, 255]])
    end
  end

  def self.widget_item(args, x, y, u)
    s = args.state
    w = @w
    g = @g
    return panel(args, x, y, u, 'BONUS ITEM', 1) { |l| l.call(0, 'NO ITEMS', DIM) } if w[:drac] # round 101 ($611 set)
    rows = item_odds(w, g, s.gd)
    panel(args, x, y, u, 'BONUS ITEM', 3 + 2.25 * [rows.size, 1].max) do |l|
      l.call(0, w[:t611] != 0 ? (narrow? ? 'NO ITEMS: HORNED' : 'NO ITEM WHILE HORNED') : "WALK #{800 - g[:steps]} PX", INK)
      l.call(1.5, nil, nil, [g[:steps], 800, [255, 206, 80]])
      l.call(3, 'ALL ENEMIES GONE', DIM) if rows.empty?
      rows.each_with_index do |(idx, pct), k|
        line = 3 + 2.25 * k
        l.call(line, nil, nil, nil, s.gd.item_sprite(idx))
        if narrow? # name beside the icon's top half, odds right-aligned under it
          l.call(line, "   #{ITEMS[idx]}", INK)
          l.call(line + 1, "#{pct}%".rjust(@cols), DIM)
        else
          l.call(line + 0.5, "   #{ITEMS[idx].ljust(COLS - 7)}#{pct.to_s.rjust(3)}%", INK) # (icon, name, odds)
        end
      end
    end
  end

  # the round timer as a bar (user): full when Horned comes ($46), the mark is the hurry-up time ($41). Text only as a
  # warning: HURRY UP! from $41 until Horned shows, LAST ENEMY REMAINING while the last enemy's escape timer runs (it
  # restarts at $32 / $40 and the same bar runs to the escape at $46).
  def self.widget_timer(args, x, y, u)
    w = @w
    return widget_drac(args, x, y, u, w[:drac]) if w[:drac] # round 101: no timer, the boss's health instead
    t = w[:t610]
    text = if w[:enemies_left] & 0x80 != 0 then narrow? ? 'LAST ENEMY LEFT' : 'LAST ENEMY REMAINING'
           elsif w[:t611] == 0 && t >= 0x41 then 'HURRY UP!'
           end
    barv = [[t, 0x46].min, 0x46, [255, 110, 96], 0x41]
    panel(args, x, y, u, 'HORNED TIMER', text ? 3 : 1) do |l|
      if text
        l.call(0, text, WARN)
        l.call(1.5, nil, nil, barv)
      else
        l.call(0.25, nil, nil, barv) # (centred in the panel)
      end
    end
  end

  # round 101 (user): the HORNED TIMER panel becomes the Dracolisk's health - 256 less its damage meter (spell hits +30,
  # drains 1 every 6 frames, defeated past 255: tasks/dracolisk.rb), so it drops on a hit and creeps back up
  def self.widget_drac(args, x, y, u, d)
    hp = d[:defeated] ? 0 : 0x100 - d[:dmg]
    panel(args, x, y, u, 'DRACOLISK', d[:defeated] ? 3 : 1) do |l|
      if d[:defeated]
        l.call(0, 'DEFEATED!', TITLE)
        l.call(1.5, nil, nil, [0, 0x100, [120, 220, 110]])
      else
        l.call(0.25, nil, nil, [hp, 0x100, [120, 220, 110]])
      end
    end
  end

  # The moon countdown (task 14, game/tasks/moon.rb): one count runs through the whole game (deaths do not reset it):
  # 120 ticks at a new game / continue, 240 after each moon; a tick is 120 frames (60 while Ptolemy is shrunk). It only
  # counts while the task runs: an item on screen pauses it, Horned stops it for the rest of the round, between rounds
  # it waits (and each restart of the task takes one tick at once); round 101 has none.
  def self.widget_moon(args, x, y, u)
    w = @w
    m = @g[:moon]
    t = w[:tasks].compact.find { |k| k[:id] == 0x14 }
    period = w[:player][:char] == 0x1c ? 60 : 120
    lines =
      if w[:drac] then [['NO MOON', INK]]
      elsif w[:night] != 0 || (t && !%i[tick wait].include?(t[:pc])) then [['MOON IS OUT', TITLE]]
      else
        frames = if t # the frames to the next tick, then the ticks after it
                   to_next = t[:pc] == :wait ? t[:delay] + (period == 60 ? 0 : 60) : t[:delay]
                   to_next + (m - 1) * period
                 else # (re)started by the next round / life, when it takes one tick at once
                   [m - 1, 0].max * period
                 end
        secs = (frames + 59).idiv(60)
        time = [format('RISES IN %d:%02d', secs.idiv(60), secs % 60), INK]
        if t && t[:suspended] then [time, [narrow? ? 'PAUSED: ITEM' : 'PAUSED: BONUS ITEM', DIM]]
        elsif !t && w[:t611] != 0 && w[:round_world] then [time, ['STOPPED: HORNED', DIM]]
        else [time]
        end
      end
    panel(args, x, y, u, 'MOON', lines.size) { |l| lines.each_with_index { |(str, c), k| l.call(k, str, c) } }
  end

  def self.widget_music(args, x, y, u)
    np = @np
    name = np ? np[:name].upcase : 'NO MUSIC'
    rows = wrap(name, @cols).first(3)
    panel(args, x, y, u, 'MUSIC', rows.size + (np ? 1.5 : 0)) do |l|
      rows.each_with_index { |r, k| l.call(k, r, np ? INK : DIM) }
      if np
        secs = np[:frames].idiv(60)
        t = format('%d:%02d', secs.idiv(60), secs % 60)
        set = narrow? ? np[:set].sub('X68000', 'X68') : np[:set]
        l.call(rows.size + 0.5, set.ljust(@cols - t.size) + t, DIM)
      end
    end
  end

  # words into lines of at most n characters (a longer word is cut)
  def self.wrap(str, n)
    lines = ['']
    str.split(' ').each do |word|
      word = word[0, n]
      if lines[-1].empty? then lines[-1] = word
      elsif lines[-1].size + 1 + word.size <= n then lines[-1] += " #{word}"
      else lines << word
      end
    end
    lines
  end

  # A framed box: title bar, then `lines` text lines (8 font px + 4 gap each). The block gets a line function:
  # l.call(line, text, colour) / l.call(line, nil, nil, [value, max, colour, mark]) for a bar / (.., icon code) for an icon
  def self.panel(args, x, y, u, title, lines)
    out = @out
    w = units(@cols) * u
    h = ((lines * 12 + 12) + 2 * PAD + 6) * u
    return y - h if @dry
    fill, light, dark = FRAME
    box(out, x, y - h, w, h, dark)
    box(out, x, y - h + u, w - u, h - u, light)
    box(out, x + u, y - h + u, w - 2 * u, h - 2 * u, fill)
    box(out, x + u, y - 13 * u, w - 2 * u, 12 * u, [40, 34, 78]) # title bar
    text(out, x + (PAD + 2) * u, y - 10 * u, u, title, TITLE)
    top = y - (14 + PAD) * u
    line = lambda do |n, str, colour, barv = nil, icon = nil|
      ly = top - (n * 12 + 8) * u
      text(out, x + (PAD + 2) * u, ly, u, str, colour) if str
      bar(out, x + (PAD + 2) * u, ly + 2 * u, @cols * 8 * u, u, *barv) if barv
      sprite(args, x + (PAD + 2) * u, ly - 4 * u, u, icon) if icon
    end
    yield line
    y - h
  end

  def self.box(out, x, y, w, h, (r, g, b))
    out.sprites << { path: :solid, x: x, y: y, w: w, h: h, r: r, g: g, b: b, a: 235 }
  end

  # game-font text, bottom-left at (x, y), u = logical size of one font pixel. The font's "/" is a division sign:
  # a slash is drawn instead (2 font px wide strokes like the font's)
  def self.text(out, x, y, u, str, (r, g, b))
    str.each_char.with_index do |ch, k|
      if ch == '/'
        7.times { |i| out.sprites << { path: :solid, x: x + (8 * k + i) * u, y: y + i * u, w: 2 * u, h: u, r: r, g: g, b: b } }
        next
      end
      c = ch.ord - 0x20
      next if c <= 0 || c >= 64
      out.sprites << { x: x + 8 * k * u, y: y, w: 8 * u, h: 8 * u, path: :wfont, source_x: 8 * c, source_y: 0,
                       source_w: 8, source_h: 8, r: r, g: g, b: b, scale_quality_enum: 0 }
    end
  end

  def self.bar(out, x, y, w, u, v, max, (r, g, b), mark = nil)
    out.sprites << { path: :solid, x: x, y: y, w: w, h: 4 * u, r: 44, g: 40, b: 70 }
    f = max > 0 ? [[v.to_f / max, 0].max, 1].min : 0
    fw = ((w / u) * f).floor * u
    out.sprites << { path: :solid, x: x, y: y, w: fw, h: 4 * u, r: r, g: g, b: b }
    out.sprites << { path: :solid, x: x + ((w / u) * mark / max).floor * u, y: y - u, w: u, h: 6 * u, r: 255, g: 255, b: 255 } if mark
  end

  # an item's sprite (16x16 game pixels at the font's pixel size) - attr high $ed (bank 1, palette 13) as the item task
  def self.sprite(args, x, y, u, code)
    attr = ((0xed ^ 0xc0) << 8) | (code & 0xff)
    @out.sprites << { x: x, y: y, w: 16 * u, h: 16 * u, path: args.state.sprites.path(1, attr & 0xff, (attr >> 8) & 15, nil),
                              scale_quality_enum: 0 }
  end

  # [item index, chance %] for every item the next spawn can be ($7534)
  def self.item_odds(w, g, gd)
    n = (w[:enemies_left] & 0x7f) - 1
    return [] if n < 0
    b = 0
    b += 1 while g[:exp] >= gd.byte(gd.a(:item_brackets) + b)
    grp = 0
    grp += 1 while n >= gd.byte(gd.a(:item_groups) + grp)
    prev = 0
    (0...6).map do |tier|
      c = gd.byte(gd.a(:item_odds) + 6 * b + tier)
      pct = ((c - prev) * 100.0 / 128).round
      prev = c
      [tier * 3 + grp, pct]
    end.select { |_, pct| pct > 0 }
  end
end
