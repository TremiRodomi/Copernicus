# The player's preferences (fairyland/settings.txt, plain key=value lines), edited in the coin-up menu:
#   CASUAL setup: lives 3 / 4 / 5 / 0 = ENDLESS (the arcade DSW and the X68000 LEFT option), short_hop (QOL)
#   GAME OPTIONS: behaviour arcade / x68000 (both modes), music arcade / original / arrange (the arcade OST or the X68000's two sets), colours standard / pcb,
#   widgets (M2-style info panels in the side borders), GRAPHICS (window, scaling, filters, borders: gfx/display.rb), boot_screen (the power-on blue screen + jingle, on as on the
#   cabinet), sfx_filter (the sound board's TA7630 tone controls on the effects: pcb model / off)
# A game's own settings (main.rb s.settings) are derived from these at START GAME: ARCADE mode ignores the CASUAL ones
# (factory settings, no QOL). Command-line flags override for dev runs.
module Settings
  FILE = 'settings.txt'
  DEFAULTS = { lives: 3, behaviour: :arcade, music: :arcade, short_hop: false,
               colours: :standard, widgets: false, music_volume: 3, sfx_volume: 10,
               boot_screen: true, sfx_filter: :pcb,
               # GRAPHICS (gfx/display.rb)
               window: :w720, fullscreen: false, scale: :integer, aspect: :square, smooth: :off, scanlines: 0,
               mask: :off, mask_level: 5, vignette: 0, border: :black, border_image: '',
               # WIDGETS (gfx/widgets.rb): each panel off / top_left / bottom_left / top_right / bottom_right
               widget_level: :top_left, widget_item: :top_left, widget_timer: :top_right, widget_moon: :top_right,
               widget_music: :bottom_right }.merge(Controls::DEFAULTS).freeze # CONTROLS (game/controls.rb): kb_* / pad_*
  CHOICES = { lives: [3, 4, 5, 0], behaviour: %i[arcade x68000], music: %i[arcade original arrange],
              short_hop: [false, true], colours: %i[standard pcb],
              widgets: [false, true], music_volume: (0..10).to_a, sfx_volume: (0..10).to_a,
              boot_screen: [true, false], sfx_filter: %i[pcb off],
              window: %i[w720 w900 w1080 w1440], fullscreen: [false, true], scale: %i[integer fit],
              aspect: %i[square crt], smooth: %i[off sharp soft], scanlines: (0..10).to_a, mask: %i[off grille dot],
              mask_level: (1..10).to_a, vignette: (0..10).to_a, border: %i[black blue grey theme bezel image],
              border_image: :files,
              widget_level: Widgets::SLOTS, widget_item: Widgets::SLOTS, widget_timer: Widgets::SLOTS,
              widget_moon: Widgets::SLOTS, widget_music: Widgets::SLOTS }
            .merge(Controls::DEFAULTS.keys.map { |k| [k, :binding] }.to_h).freeze # :files = a picture in borders/ (the list is read when it is changed)

  def self.load
    d = DEFAULTS.dup
    raw = DR.read_file(FILE)
    return d unless raw
    raw.each_line do |line|
      k, v = line.strip.split('=', 2)
      next unless k && v
      key = k.to_sym
      next unless CHOICES[key]
      next d[key] = v if CHOICES[key] == :files
      next d[key] = Controls.parse(key, v) || d[key] if CHOICES[key] == :binding # (an unreadable list keeps the default)
      v = Widgets::LEGACY[v.to_sym].to_s if key.to_s.start_with?('widget_') && Widgets::LEGACY[v.to_sym] # left1 ... -> corners
      v = 'theme' if key == :border && v == 'tiles' # (TILES gave way to THEME)
      v = { 'false' => 'off', 'true' => 'sharp' }.fetch(v, v) if key == :smooth # (on / off before pass 52)
      val = CHOICES[key].find { |c| c.to_s == v }
      d[key] = val unless val.nil?
    end
    d
  rescue StandardError
    DEFAULTS.dup
  end

  def self.write(s)
    DR.write_file(FILE, DEFAULTS.keys.map { |k| "#{k}=#{CHOICES[k] == :binding ? binding_text(s[k]) : s[k]}" }.join("\n") + "\n")
  end

  def self.binding_text(list)
    list.nil? || list.empty? ? '-' : list.join(',')
  end

  # the next / previous choice for key
  def self.step(s, key, dir)
    list = CHOICES[key]
    list = Display.images if list == :files
    return if list.empty?
    i = list.index(s[key]) || -dir
    s[key] = list[(i + dir) % list.size]
  end
end
