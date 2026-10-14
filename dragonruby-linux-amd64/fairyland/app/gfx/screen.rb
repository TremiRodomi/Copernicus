# The graphic screen: 32x32 cells of 8x8 drawn into one 256x256 pixel array, using the X68000 BG tile cache rules ($eb2 / $d10):
#   source = BGCHR[half * 64K + (attr & $c0) << 8 + tile * 64], one byte (0-15) per pixel, 8 bytes per row
#   attr bit 3 clear = H-flip, bit 4 clear = V-flip, bit 5 = odd colour variant, bits 2-0 = palette group (x32)
#   colour index = group * 32 + 2 * pixel (+1 for the odd variant when pixel != 0)
# Text and HUD go through the same path: the original's $b52 writes (code, attr) into the name table and redraws the cell.
module Screen
  ROWS_TOP_DOWN = true # pixel array row 0 = top of the image (verified by screenshot in the first run - see NOTES.md)

  class << self
    # A bitmap written straight into the graphic screen, over the cells (the X68000 title's TAITO, $eee):
    # [x, y, w, h, colour indices row by row] or nil
    attr_accessor :overlay
    attr_reader :wall_rgb
  end

  # Per round: the palette set and BGCHR half the round builder chose
  # pal (optional): { set: palette set, patch: { word index => X68000 colour word } } - the ending's palette change
  def self.setup(gd, rb, pal = nil)
    @gd = gd
    @pal = Palette.graphic(gd, pal ? pal[:set] : rb.palette_set)
    (pal ? pal[:patch] : {}).each do |i, word|
      c = Palette.abgr(word, gd.behaviour == :arcade)
      @pal[2 * i] = c
      @pal[2 * i + 1] = c
    end
    @half = rb.bg_half * 0x10000
  end

  # DragonRuby discards args.pixel_array objects after every tick (Runtime#clear_draw_passes); the uploaded texture stays.
  # So the screen keeps its own pixel buffer and hands it over again on any tick where cells changed.
  # Attr bit 5 = priority: the cell's non-zero pixels are drawn IN FRONT of sprites (arcade tile category 1; X68000 special
  # priority via the odd colour codes). Those pixels also go into a second layer, "<name>_front", drawn after the sprites.
  def self.render(args, name, tiles, attrs)
    # allocated once: handing DragonRuby a NEW array for an existing pixel-array name left the texture blank (white)
    @px ||= Array.new(256 * 256, 0)
    @front ||= Array.new(256 * 256, 0)
    1024.times { |i| draw_cell(@px, i, tiles[i], attrs[i]) }
    draw_overlay
    @wall_rgb = wall_colour
    @pending = name
  end

  # the most common clearly visible colour of the left wall column (x 0-15, visible lines 16-239) as [r, g, b], or nil
  # when it is all dark (title, menus): the THEME border's colour (Display.theme)
  def self.wall_colour
    count = Hash.new(0)
    (16...240).each do |sy|
      o = (ROWS_TOP_DOWN ? sy : 255 - sy) * 256
      16.times do |x|
        c = @px[o + x]
        count[c] += 1 if (c & 0xff) + ((c >> 8) & 0xff) + ((c >> 16) & 0xff) > 120
      end
    end
    best = count.max_by { |_, n| n }
    best && [best[0] & 0xff, (best[0] >> 8) & 0xff, (best[0] >> 16) & 0xff]
  end

  # Redraw only the given cells (the name table changed there)
  def self.redraw(args, name, cells, tiles, attrs)
    cells.uniq.each { |i| draw_cell(@px, i, tiles[i], attrs[i]) }
    draw_overlay
    @pending = name
  end

  # Upload every tick, once, just before drawing. Uploading only on change left the screen white now and then (a texture
  # that went missing was never re-sent; DragonRuby clears its pixel-array list every tick anyway).
  def self.flush(args)
    @name = @pending if @pending
    @pending = nil
    upload(args, @name) if @name && @px
  end

  def self.upload(args, name)
    [[name, @px], [:"#{name}_front", @front]].each do |n, buf|
      pa = args.pixel_array(n)
      pa.width = 256
      pa.height = 256
      pa.pixels = buf
    end
    name
  end

  # A text layer over the whole frame (the pause menu): { cell index => [tile, attr] } in the current palette, colour 0 drawn
  # black, every other cell transparent. Uploaded as :ovl by flush; nil cells clears it.
  def self.overlay_cells(cells)
    @ovl ||= Array.new(256 * 256, 0)
    @ovl.fill(0)
    (cells || {}).each do |i, (tile, attr)|
      src = @half + ((attr & 0xc0) << 8) + tile * 64
      hflip = attr & 8 == 0
      vflip = attr & 0x10 == 0
      base = (attr & 7) * 32
      odd = attr & 0x20 != 0 ? 1 : 0
      cx = (i & 31) * 8
      cy = (i >> 5) * 8
      8.times do |y|
        row = src + 8 * (vflip ? 7 - y : y)
        o = (ROWS_TOP_DOWN ? cy + y : 255 - cy - y) * 256 + cx
        8.times do |x|
          v = @gd.bgchr[row + (hflip ? 7 - x : x)]
          @ovl[o + x] = v == 0 ? 0xff000000 : @pal[base | (v << 1) | odd]
        end
      end
    end
    @ovl_dirty = true
  end

  def self.flush_overlay(args)
    return unless @ovl
    pa = args.pixel_array(:ovl)
    pa.width = 256
    pa.height = 256
    pa.pixels = @ovl
  end

  def self.draw_overlay
    return unless @overlay
    x0, y0, w, h, pix = @overlay
    h.times do |y|
      o = (ROWS_TOP_DOWN ? y0 + y : 255 - y0 - y) * 256 + x0
      w.times do |x|
        @px[o + x] = @pal[pix[y * w + x]]
        @front[o + x] = 0
      end
    end
  end

  def self.draw_cell(px, i, tile, attr)
    bg = @gd.bgchr
    src = @half + ((attr & 0xc0) << 8) + tile * 64
    hflip = attr & 8 == 0
    vflip = attr & 0x10 == 0
    odd = attr & 0x20 != 0
    base = (attr & 7) * 32
    cx = (i & 31) * 8
    cy = (i >> 5) * 8
    8.times do |y|
      row = src + 8 * (vflip ? 7 - y : y)
      sy = cy + y
      o = (ROWS_TOP_DOWN ? sy : 255 - sy) * 256 + cx
      8.times do |x|
        v = bg[row + (hflip ? 7 - x : x)]
        c = @pal[base | (v << 1) | (odd && v != 0 ? 1 : 0)]
        px[o + x] = c
        @front[o + x] = odd && v != 0 ? c : 0
      end
    end
  end
end
