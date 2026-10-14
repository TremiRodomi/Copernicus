# Sprite shadow writers. Hardware sprite coords: X = (-x) & $ff, Y = ((~y + yoff - ($591 & 2)) & $ff) + $11; (16,16) = screen top-left.
# Entry attr = ((hi ^ $c0) << 8) | code: bit15 V-flip, bit14 H-flip, bits 13-12 bank, bits 11-8 palette, bits 7-0 pattern.
module Shadow
  # $1a48: chain from table $10234, 5-byte entries [slot, y offset, hi, code, next]; slot / 4 = shadow index
  def self.set_a(w, gd, idx, y, x)
    start = idx
    guard = 0
    loop do
      a = gd.a(:meta_a) + 5 * idx
      slot = gd.byte(a)
      sy = ((~y + gd.byte(a + 1) - (w[:flags591] & 2)) & 0xff) + 0x11
      w[:shadow][slot >> 2] = [(-x) & 0xff, sy, ((gd.byte(a + 2) ^ 0xc0) << 8) | gd.byte(a + 3)]
      idx = gd.byte(a + 4)
      break if idx == 0
      raise "sprite chain loops (start #{start})" if (guard += 1) > 64
    end
  end

  # $1ab6 (:meta_b) / $1b22 (:meta_poses): 4-byte entries [y offset, hi, code, next]; x from the caller;
  # the slot byte (d3) advances by 4 for each part of the chain
  def self.set_b(w, gd, idx, y, x, slot, table = :meta_b)
    start = idx
    guard = 0
    loop do
      a = gd.a(table) + 4 * (idx & 0xff)
      sy = ((~y + gd.byte(a) - (w[:flags591] & 2)) & 0xff) + 0x11
      w[:shadow][(slot & 0xff) >> 2] = [(-x) & 0xff, sy, ((gd.byte(a + 1) ^ 0xc0) << 8) | gd.byte(a + 2)]
      slot += 4
      idx = gd.byte(a + 3)
      break if idx == 0
      raise "sprite chain loops (start #{start})" if (guard += 1) > 64
    end
    slot # the original leaves d3 pointing past the last part; some callers use it
  end

  # $1bfe: one sprite at a given shadow index (callers walk a4 forward 8 bytes = one index per call)
  def self.single(w, index, code, hi, y, x)
    sy = ((~y - (w[:flags591] & 2)) & 0xff) + 0x11
    w[:shadow][index] = [(-x) & 0xff, sy, ((hi ^ 0xc0) << 8) | (code & 0xff)]
  end

  # Palette tweaks on an entry already written ($19fc + bset/bclr, or `move.b $4(a2)` edits): attr bits 11-8
  def self.set_palette(w, index, pal)
    e = w[:shadow][index]
    e[2] = (e[2] & ~0x0f00) | ((pal & 15) << 8) if e
  end

  def self.palette(w, index)
    e = w[:shadow][index]
    e ? (e[2] >> 8) & 15 : 0
  end

  # $1b8e: chain from table $10b29, 6-byte entries [slot, y offset, hi, code, x offset, next] (multi-part poses, e.g. the death animation)
  def self.set_c(w, gd, idx, y, x)
    start = idx
    guard = 0
    loop do
      a = gd.a(:meta_c) + 6 * (idx & 0xff)
      sy = ((~y + gd.byte(a + 1) - (w[:flags591] & 2)) & 0xff) + 0x11
      w[:shadow][gd.byte(a) >> 2] = [(-(x + gd.byte(a + 4))) & 0xff, sy, ((gd.byte(a + 2) ^ 0xc0) << 8) | gd.byte(a + 3)]
      idx = gd.byte(a + 5)
      break if idx == 0
      raise "sprite chain loops (start #{start})" if (guard += 1) > 64
    end
  end

  # $1c44 (:meta_d): big multi-part sprites (the Dracolisk). 4-byte entries [y offset, code, x offset, next]; hi = the attr
  # high byte for every part; with hi bit 6 clear the x offsets are mirrored ($c0 - off). Returns the slot after the last part.
  def self.set_d(w, gd, idx, y, x, slot, hi)
    start = idx
    guard = 0
    loop do
      a = gd.a(:meta_d) + 4 * (idx & 0xff)
      sy = ((~y + gd.byte(a) - (w[:flags591] & 2)) & 0xff) + 0x11
      xo = hi & 0x40 != 0 ? gd.byte(a + 2) : (0xc0 - gd.byte(a + 2)) & 0xff
      w[:shadow][(slot & 0xff) >> 2] = [(-((xo + x) & 0xff)) & 0xff, sy, ((hi ^ 0xc0) << 8) | gd.byte(a + 1)]
      slot += 4
      idx = gd.byte(a + 3)
      break if idx == 0
      raise "sprite chain loops (start #{start})" if (guard += 1) > 64
    end
    slot
  end

  # $1a0e: clear one slot (takes the slot byte as used in the tables)
  def self.clear(w, slot)
    w[:shadow][(slot & 0xff) >> 2] = nil
  end
end
