# 16x16 sprite patterns from SPCHR (3 banks x 256, X68000 PCG layout: 8x8 blocks UL, LL, UR, LR; 4 bytes per row, high nibble = left)
# turned into pixel arrays on demand, one per (bank, code, palette block). Flips are left to the renderer.
class SpriteCache
  def initialize(args, gd)
    @args = args
    @gd = gd
    @pals = Palette.sprite_blocks(gd)
    @made = {} # name => true
    @names = {} # [key, patch suffix] -> name, so a frame's sprites build no strings
  end

  # once per frame, before the sprites: the palette patch's colours per palette block ([suffix, overrides] or nil),
  # worked out once instead of per sprite
  def begin_frame(patch)
    sig = patch && !patch.empty? ? patch.to_a : nil
    return if sig == @sig
    @sig = sig
    @over = sig && Array.new(16) do |pal|
      over = sig.select { |i, _| i >> 4 == pal }
      over.empty? ? nil : ["_#{over.sort.map { |i, c| "#{i}:#{c}" }.join('_')}", over]
    end
  end

  # patch: true = apply the overrides begin_frame worked out (the shadow sprites), nil = plain colours
  def path(bank, code, pal, patch = nil)
    mode = @gd.behaviour == :arcade ? (Palette.profile == :pcb ? 2 : 0) : 1 # colour scale: behaviour + profile
    @pals = Palette.sprite_blocks(@gd) if @pal_mode != mode
    @pal_mode = mode
    key = (bank << 12) | (code << 4) | pal | (mode << 16)
    suffix, over = patch && @over && @over[pal]
    names = ((@names ||= {})[suffix] ||= {}) # (||=: survives a hot reload of this class into a running game)
    name = (names[key] ||= "spr_#{key}#{suffix}")
    return name if @made[name]
    pa = @args.pixel_array(name)
    pa.width = 16
    pa.height = 16
    px = pa.pixels
    colours = @pals[pal]
    if over
      colours = colours.dup
      over.each { |i, c| colours[i & 15] = Palette.abgr(c, @gd.behaviour == :arcade) }
    end
    base = (bank * 256 + code) * 128
    sp = @gd.spchr
    16.times do |y|
      16.times do |x|
        b = sp[base + ((x >> 3) * 2 + (y >> 3)) * 32 + (y & 7) * 4 + ((x & 7) >> 1)]
        v = x.odd? ? (b & 15) : (b >> 4)
        px[(Screen::ROWS_TOP_DOWN ? y : 15 - y) * 16 + x] = v == 0 ? 0 : colours[v]
      end
    end
    @made[name] = true
    name
  end

  # attr hi byte as stored in the game's tables (before the ^$c0): returns [bank, palette, hflip, vflip]
  def self.decode_hi(hi)
    hi ^= 0xc0
    bank = hi & 0x20 == 0 ? 0 : (hi & 0x10 == 0 ? 1 : 2)
    [bank, hi & 15, hi & 0x40 != 0, hi & 0x80 != 0]
  end
end
