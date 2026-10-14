# How the 256 x 224 playfield reaches the screen (GAME OPTIONS > GRAPHICS). Nothing here touches the game state.
# HD mode (metadata hd=true, all license tiers) renders at the display's real resolution: Grid.render_scale = screen
# pixels per logical pixel (1280 x 720 logical canvas), so the playfield can be sized and placed on whole SCREEN pixels.
#   SCALE   INTEGER: the largest whole multiple of 224 lines that fits; FIT: as large as fits (uneven pixels)
#   ASPECT  SQUARE pixels (256 x 224 as stored), or 4:3 like the cabinet / X68000 monitor (pixels 7:6 wide)
#   SMOOTH  OFF (nearest), SHARP (nearest to the largest whole multiple that fits, then linear for the fraction left:
#           even pixels with soft seams under FIT; the same as OFF under INTEGER), SOFT (linear from the game's own
#           pixels: a soft monitor look). Pass 52 (user): the old x2-then-linear looked smeary and uneven
#   SCANLINES 0-10, MASK off / GRILLE (aperture: RGB stripes) / DOT (slot mask) with MASK LEVEL, VIGNETTE 0-10:
#           overlays (no shaders on this license tier: no curvature / bloom), laid out on screen pixels
#   BORDER  BLACK / BLUE / GREY, THEME (a gradient in the colour of the round's own wall - from the player's data),
#           BEZEL (an original frame drawn here), IMAGE (fairyland/borders/*.png, the player's own pictures)
#   WINDOW  720p / 900p / 1080p / 1440p when windowed (DR.set_window_size: works on desktop, not guaranteed everywhere);
#           FULLSCREEN uses the desktop resolution
module Display
  PAR_CRT = 7.0 / 6 # 256 x 224 stretched to 4:3
  LINES = 224
  VIS_TOP_BG = 16 # the first visible line (main.rb VIS_TOP)
  BORDER_RGB = { black: [0, 0, 0], blue: [10, 14, 40], grey: [34, 34, 38] }.freeze
  WINDOW = { w720: [1280, 720], w900: [1600, 900], w1080: [1920, 1080], w1440: [2560, 1440] }.freeze
  IMAGE_DIR = 'borders'

  class << self
    attr_reader :rect # [x, y, w, h] in logical units, the last playfield placement (widgets lay out around it)
  end

  # HD mode scales render targets too: a target w logical units wide gets a w * render_scale texel texture and its
  # sprites are placed at x * render_scale. Drawn as is, the 256 px frame became 361 texels at render scale 1.41 (a
  # 1080p window the window manager shrank to 1920 x 1019) - the pixel art resampled unevenly before it reached the
  # screen. So targets are drawn in texels: every rect (sprites inside, source rects on it) divided by rs. A target's
  # size is a whole number of logical units (a fraction is dropped: 256.25 / 1.33 -> 192 -> 255 texels), so it is
  # ceil(w / rs): at least w texels, the spare ones (< 1 logical unit) left empty past the edge. Pixel-exact against
  # drawing straight to the screen at 1600x900, 1700x1000, 1920x1019 and 1920x1080 (NOTES pass 45).
  def self.target(args, name, w, h)
    rs = render_scale(args)
    t = args.outputs[name]
    t.w = (w / rs).ceil
    t.h = (h / rs).ceil
    t
  end

  # x / y / w / h of sprites given in texels -> the target's logical units (source rects are texture texels: untouched)
  def self.texels(args, sprites)
    rs = render_scale(args)
    return if rs == 1.0
    sprites.each do |q|
      q[:x] /= rs
      q[:y] /= rs
      q[:w] /= rs
      q[:h] /= rs
    end
  end

  # a source rect on a target, given in texels
  def self.src(args, x, y, w, h)
    rs = render_scale(args)
    { source_x: x / rs, source_y: y / rs, source_w: w / rs, source_h: h / rs }
  end

  # logical pixels a border style draws around the playfield (the widgets keep clear of it)
  def self.frame_pad(p)
    p[:border] == :bezel ? 30 : 0
  end

  def self.render_scale(args)
    rs = args.grid.render_scale
    rs && rs > 0 ? rs : 1.0
  rescue StandardError
    1.0
  end

  # -> [x, y, w, h (logical), k (screen pixels per game line), rs]
  def self.place(args, p)
    rs = render_scale(args)
    ph = 720 * rs
    pw = 1280 * rs
    par = p[:aspect] == :crt ? PAR_CRT : 1.0
    if p[:scale] == :fit
      k = [ph / LINES, pw / (256 * par)].min
    else
      k = (ph / LINES).floor
      k -= 1 while k > 1 && 256 * k * par > pw
      k = 1 if k < 1
    end
    wpx = (256 * k * par).round
    hpx = (LINES * k).round
    xpx = ((pw - wpx) / 2).floor
    ypx = ((ph - hpx) / 2).floor
    [xpx / rs, ypx / rs, wpx / rs, hpx / rs, k, rs]
  end

  # everything that used to be one sprite in main.rb#draw: border, playfield, filters
  def self.draw(args, p, vis_top)
    x, y, w, h, k, rs = place(args, p)
    @rect = [x, y, w, h]
    out = args.outputs
    border(args, p, x, y, w, h, k, rs)
    fsrc = src(args, 0, 256 - vis_top - LINES, 256, LINES)
    if p[:smooth] == :sharp || p[:smooth] == :soft
      smooth(args, p, fsrc, x, y, w, h, rs)
    else
      out.sprites << { x: x, y: y, w: w, h: h, path: :frame, scale_quality_enum: 0 }.merge(fsrc)
    end
    scanlines(out, p[:scanlines], x, y, w, h, k, rs) if p[:scanlines] > 0
    mask(args, p, x, y, w, h, rs) if p[:mask] != :off
    vignette(args, p[:vignette], x, y, w, h) if p[:vignette] > 0
  end

  # the playfield copied nearest at m x n texels per game pixel into :frame_up, then drawn linear to the screen. The
  # copy sits 1 texel in from the target's edges, with the picture smeared into that rim (4 copies 1 texel off), so
  # the linear filter at the playfield's edges blends with the edge pixels themselves - not with the empty texels past
  # the target's edge or the hidden lines above / below the visible 224 (they left a dark seam on the old SMOOTH)
  def self.smooth(args, p, fsrc, x, y, w, h, rs)
    m = p[:smooth] == :soft ? 1 : [((w * rs) / 256).floor, 1].max
    n = p[:smooth] == :soft ? 1 : [((h * rs) / LINES).floor, 1].max
    tw = 256 * m
    th = LINES * n
    up = target(args, :frame_up, tw + 2, th + 2)
    [[0, 1], [2, 1], [1, 0], [1, 2], [1, 1]].each do |dx, dy|
      up.sprites << { x: dx, y: dy, w: tw, h: th, path: :frame, scale_quality_enum: 0 }.merge(fsrc)
    end
    texels(args, up.sprites)
    args.outputs.sprites << { x: x, y: y, w: w, h: h, path: :frame_up, scale_quality_enum: 1 }.merge(src(args, 1, 1, tw, th))
  end

  # dark bands under each game line: 3/8 of a line, at least one screen pixel. Each band starts on a whole screen pixel
  # row and is the same whole number of rows tall: under FIT (k = 4.55 ...) fractional bands came out 1 or 2 rows tall
  # by turns and beat against the picture
  def self.scanlines(out, level, x, y, w, h, k, rs)
    band = [(k * 0.375).round, 1].max
    y0 = (y * rs).round
    a = 22 * level
    LINES.times do |i|
      out.sprites << { path: :solid, x: x, y: (y0 + (i * k).round) / rs, w: w, h: band / rs, r: 0, g: 0, b: 0, a: a }
    end
  end

  # phosphor mask, multiplied over the picture; built on screen pixels (one texel = one screen pixel), cached
  def self.mask(args, p, x, y, w, h, rs)
    wpx = (w * rs).round
    hpx = (h * rs).round
    key = [p[:mask], p[:mask_level], wpx, hpx, rs]
    build_mask(args, key) unless @mask_key == key
    args.outputs.sprites << { x: x, y: y, w: w, h: h, path: :crt_mask, blendmode: 8, scale_quality_enum: 0 }.merge(src(args, 0, 0, wpx, hpx))
  end

  def self.build_mask(args, key)
    type, level, wpx, hpx = key
    d = 255 - 13 * level
    cols = [[255, d, d], [d, 255, d], [d, d, 255]]
    strip = target(args, :crt_mask_strip, wpx, 4) # one 4-row band of the pattern
    wpx.times do |c|
      r, g, b = cols[c % 3]
      strip.sprites << { path: :solid, x: c, y: 0, w: 1, h: 4, r: r, g: g, b: b }
      # slot mask: a dark row every 4, offset by 2 on alternate triplets
      strip.sprites << { path: :solid, x: c, y: (c.idiv(3).even? ? 0 : 2), w: 1, h: 1, r: d, g: d, b: d } if type == :dot
    end
    texels(args, strip.sprites)
    full = target(args, :crt_mask, wpx, hpx)
    (hpx / 4.0).ceil.times { |i| full.sprites << { x: 0, y: 4 * i, w: wpx, h: 4, path: :crt_mask_strip }.merge(src(args, 0, 0, wpx, 4)) }
    texels(args, full.sprites)
    @mask_key = key
  end

  # radial darkening toward the edges: a small alpha texture stretched with linear filtering
  def self.vignette(args, level, x, y, w, h)
    unless @vignette
      pa = args.pixel_array(:vignette)
      pa.w = 64
      pa.h = 48
      pa.pixels = Array.new(64 * 48) do |i|
        dx = ((i % 64) + 0.5) / 32.0 - 1
        dy = ((i.idiv(64)) + 0.5) / 24.0 - 1
        r = Math.sqrt(dx * dx * 0.8 + dy * dy * 0.8)
        a = ((r - 0.55) / 0.6).clamp(0, 1)
        ((a * a * 255).to_i << 24) # ABGR: black, alpha a
      end
      @vignette = true
    end
    args.outputs.sprites << { x: x, y: y, w: w, h: h, path: :vignette, a: 25 * level, scale_quality_enum: 1 }
  end

  # ---- borders ----
  def self.border(args, p, x, y, w, h, k, rs)
    out = args.outputs
    case p[:border]
    when :theme then theme(out, x, w)
    when :bezel then bezel(args, x, y, w, h)
    when :image then image(args, p[:border_image])
    end
    rgb = BORDER_RGB[p[:border]] || [0, 0, 0]
    out.background_color = rgb
  end

  THEME_STRIPS = 48 # per side
  THEME_FADE = 0.08 # share of the way to a new round's colour per frame (~1 s)

  # both side borders shade from the round's wall colour (Screen.wall_rgb, dimmed) at the playfield's edge to near black
  # at the screen's edge; a new theme / palette fades in. Solid strips, no texture: nothing to re-upload when it changes
  def self.theme(out, x, w)
    target = Screen.wall_rgb || BORDER_RGB[:blue]
    @theme_rgb ||= target.map(&:to_f)
    @theme_rgb = @theme_rgb.zip(target).map { |c, t| (t - c).abs < 0.5 ? t.to_f : c + (t - c) * THEME_FADE }
    sw = x / THEME_STRIPS
    return if sw <= 0
    THEME_STRIPS.times do |i| # strip i counted from the screen edge (the playfield covers the overlap)
      f = (i + 1).to_f / THEME_STRIPS
      v = 0.06 + 0.40 * f * f
      r, g, b = @theme_rgb.map { |c| (c * v).round }
      [x - (THEME_STRIPS - i) * sw, x + w + (THEME_STRIPS - 1 - i) * sw].each do |sx|
        out.sprites << { path: :solid, x: sx, y: 0, w: sw + 0.5, h: 720, r: r, g: g, b: b }
      end
    end
  end

  # an original cabinet-style frame: dark gradient field, a bevelled surround and a thin inner lip
  def self.bezel(args, x, y, w, h)
    out = args.outputs
    unless @bezel_grad
      pa = args.pixel_array(:bezel_grad)
      pa.w = 1
      pa.h = 64
      pa.pixels = Array.new(64) do |i|
        t = i / 63.0
        r = (14 + 22 * t).to_i
        g = (12 + 16 * t).to_i
        b = (26 + 30 * t).to_i
        0xff000000 | (b << 16) | (g << 8) | r
      end
      @bezel_grad = true
    end
    out.sprites << { x: 0, y: 0, w: 1280, h: 720, path: :bezel_grad, scale_quality_enum: 1 }
    m = 18
    [[m + 10, [8, 8, 12]], [m + 6, [58, 54, 78]], [m + 4, [28, 26, 40]], [m, [16, 14, 24]], [6, [4, 4, 6]]].each do |pad, (r, g, b)|
      out.sprites << { path: :solid, x: x - pad, y: y - pad, w: w + 2 * pad, h: h + 2 * pad, r: r, g: g, b: b }
    end
    out.sprites << { path: :solid, x: x - m - 6, y: y + h + m + 5, w: w + 2 * m + 12, h: 1, r: 110, g: 100, b: 140 }
  end

  def self.images
    (DR.list_files(IMAGE_DIR) || []).select { |f| f.downcase.end_with?('.png') }.sort
  rescue StandardError
    []
  end

  # the player's own picture, scaled to cover the screen (the playfield is drawn on top)
  def self.image(args, name)
    name = images.first if name.nil? || name.empty? || !images.include?(name)
    return unless name
    path = "#{IMAGE_DIR}/#{name}"
    iw, ih = args.gtk.calcspritebox(path) rescue [1280, 720]
    s = [1280.0 / iw, 720.0 / ih].max
    args.outputs.sprites << { x: (1280 - iw * s) / 2, y: (720 - ih * s) / 2, w: iw * s, h: ih * s, path: path,
                              scale_quality_enum: 1 }
  end

  # the X68000's "Now Loading..." picture (512 x 512, gd.splash_pixels), decoded once; nil without the disk
  def self.splash(gd)
    @splash = gd.splash_pixels if @splash.nil? && !@splash_tried
    @splash_tried = true
    @splash
  end

  # The fade-in (user: the real X68000 fades it in): FS.X sets IOCS _CONTRAST 0, decodes the picture, then _CONTRAST 15
  # ($f5e-$fb2) in one step - the gradual rise is the hardware's contrast output settling. MAME steps it in one frame,
  # so the curve is an estimate: an RC-style approach, SPLASH_TAU frames to 63 %.
  SPLASH_TAU = 20.0

  # over everything, on black: the full screen height, 4:3 like the X68000's monitor (ASPECT 4:3) or square pixels.
  # frame = frames since the picture went up (the fade)
  def self.draw_splash(args, p, frame = nil)
    px = @splash
    return unless px
    pa = args.pixel_array(:x68_splash) # (handed over every tick it is used: DragonRuby clears its pixel-array list)
    pa.width = 512
    pa.height = 512
    pa.pixels = px
    w = p[:aspect] == :crt ? 960 : 720
    args.outputs.sprites << { x: 0, y: 0, w: 1280, h: 720, path: :solid, r: 0, g: 0, b: 0 }
    a = frame ? (255 * (1 - Math.exp(-frame / SPLASH_TAU))).round : 255 # (alpha over black = the contrast)
    args.outputs.sprites << { x: (1280 - w).idiv(2), y: 0, w: w, h: 720, path: :x68_splash, a: a,
                              scale_quality_enum: p[:smooth] == :off ? 0 : 1 }
  end

  # windowed size / fullscreen (applied when the setting changes and at boot)
  def self.apply_window(p)
    DR.set_window_fullscreen(p[:fullscreen] ? true : false)
    return if p[:fullscreen]
    sz = WINDOW[p[:window]]
    DR.set_window_size(*sz) if sz
  rescue StandardError
    nil
  end
end
