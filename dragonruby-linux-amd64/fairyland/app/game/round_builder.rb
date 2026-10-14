# Builds a round's background + collision exactly like FS.X $1114 (rounds 1-100) / $1676 (round 101). See NOTES.md pass 10.
# Reference implementation: level_render.py (the Python renderer is the test oracle for this file).
#
# Screen: 32x32 cells of 8x8, cell i = row * 32 + col (row 0 = top). tiles[i], attrs[i] as in the original map.
# Level cells: k = 0..799 (32 x 25) map to screen cell 160 + k (rows 5..29). solid?(k) = collision.
class RoundBuilder
  attr_reader :tiles, :attrs, :theme, :bg_half, :palette_set, :item_spawn, :door_pair, :enemy_speed, :enemies

  SOLID_PAD = 256 # the original clears $716..$b36: level cells -192..863

  def initialize(gd)
    @gd = gd
  end

  # number: 1..101
  def build(number)
    @tiles = Array.new(1024, 0) # port: the original clears with a pattern read from $6e4 (an rts opcode) - only visible in hidden rows
    @attrs = Array.new(1024, 0)
    @solid = Array.new(800 + 2 * SOLID_PAD, 0)
    @attr = 0
    @door_pair = nil
    @item_spawn = nil
    @enemies = []
    if number == 101
      build_final
    else
      build_normal(number - 1)
      load_enemies(number - 1)
    end
    self
  end

  def solid?(k)
    @solid[k + SOLID_PAD] & 1 == 1
  end

  # The game's collision memory $716..$b35 ($420 bytes), laid out exactly as the original so lookups port 1:1:
  # index = 32 * (y >> 3) + (x >> 3) in game coordinates ($48b0); level cell k lives at index $35f - k.
  def collision_map
    (0...0x420).map { |i| @solid[0x35f - i + SOLID_PAD] }
  end

  # Screen-position words ($cXXX, as used by the game's draw calls) -> cell index. They are always odd.
  def self.cell_of(pos)
    (0x7ff - (pos - 0xc000)).idiv(2)
  end

  # Game coordinates (x grows leftward, y grows upward: rotated 180 deg from the screen) -> cell, as $86a4.
  def self.cell_at(x, y)
    958 - 32 * (y >> 3) - (x >> 3)
  end

  private

  def g
    @gd
  end

  # address of a named data table (fs/tables.rb)
  def t(name)
    @gd.a(name)
  end

  def set(i, tile, attr)
    @tiles[i] = tile & 0xff
    @attrs[i] = attr
  end

  # $177e: h, w, then h*w tile codes, laid left to right, rows downward. Returns the address after the block.
  def block(cell, a)
    h = g.byte(a)
    w = g.byte(a + 1)
    a += 2
    h.times do |r|
      w.times do |c|
        set(cell + r * 32 + c, g.byte(a), @attr)
        a += 1
      end
    end
    a
  end

  # $17b6: same data, each row laid right to left (used with an H-flipped attr to mirror a block)
  def mirror(cell, a)
    h = g.byte(a)
    w = g.byte(a + 1)
    a += 2
    h.times do |r|
      w.times do |c|
        set(cell + r * 32 - c, g.byte(a), @attr)
        a += 1
      end
    end
    a
  end

  # $17f2
  def fill(cell, rows, cols, tile)
    rows.times { |r| cols.times { |c| set(cell + r * 32 + c, tile, @attr) } }
  end

  # $13da: 100 bytes, MSB first, level cell k = bit index
  def bitmap(a, tile)
    @solid.fill(0)
    800.times do |k|
      next unless (g.byte(a + (k >> 3)) << (k & 7)) & 0x80 != 0
      set(160 + k, tile, @attr)
      @solid[k + SOLID_PAD] = 1
    end
    a + 100
  end

  # $142e: 0, or x1,y1,x2,y2 -> the same block at both (task $20 drives it)
  def pair(a, blk)
    return a + 1 if g.byte(a) == 0
    x1, y1, x2, y2 = (0..3).map { |i| g.byte(a + i) }
    @door_pair = [x1, y1, x2, y2]
    block(RoundBuilder.cell_at(x1, y1), blk)
    block(RoundBuilder.cell_at(x2, y2), blk)
    a + 4
  end

  # $133e: 4-neighbour mask (1 above, 2 left, 4 below, 8 right) -> tile from (mask, tile) pairs, 0-terminated, then default
  def autotile(tab, theme)
    0x340.times do |k|
      next unless solid?(k)
      m = (solid?(k - 32) ? 1 : 0) | (solid?(k - 1) ? 2 : 0) | (solid?(k + 32) ? 4 : 0) | (solid?(k + 1) ? 8 : 0)
      next if m == 0
      p = tab
      p += 2 while g.byte(p) != 0 && g.byte(p) != m
      i = 160 + k
      @tiles[i] = g.byte(p + 1)
      if theme & 0x80 != 0
        @attrs[i] = 0x5a
      elsif theme == 3 && (m == 3 || m == 0xc || m == 6)
        @attrs[i] = { 3 => 0x51, 0xc => 0x49, 6 => 0x41 }[m]
      end
    end
  end

  # $152a: draw a decoration list (format per version: GameData#deco_entries)
  def decos(list)
    g.deco_entries(list).each do |attr, pos, blk|
      @attr = attr
      block(RoundBuilder.cell_of(pos), blk)
    end
  end

  # $14be: edges of the bottom level row
  def floor_edge
    31.times do |j|
      k = 768 + j
      next unless solid?(k)
      if !solid?(k - 1)
        set(160 + k, 0x72, 0x14)
      elsif !solid?(k + 1)
        set(160 + k, 0x72, 0x1c)
      else
        set(160 + k, 0, 0x1c)
      end
    end
    set(160 + 799, 0, 0x1c)
  end

  # $1478: drop shadows on empty cells below/right of solid ones
  def shadows
    800.times do |k|
      next if solid?(k)
      add = if solid?(k - 33) then 2
            elsif solid?(k - 32) then solid?(k - 1) ? 2 : 1
            elsif solid?(k - 1) then 3
            else 0
            end
      @tiles[160 + k] = (@tiles[160 + k] + add) & 0xff if add > 0
    end
  end

  def build_normal(rnd)
    a = g.round_record(rnd)
    @theme = g.byte(a)
    a += 1
    @bg_half = 0
    @palette_set = @theme
    c = RoundBuilder.method(:cell_of)
    case @theme
    when 0
      @attr = 0x19
      fill(c.call(0xc6bb), 0x19, 0x1c, 0xbe)
      a = bitmap(a, 0xc2)
      @attr = 0x19
      a = pair(a, t(:pair_blk0))
      decos(t(:deco0))
    when 1
      @attr = 0x59
      13.times { |r| 7.times { |col| block(c.call(0xc6bb - 0x80 * r - 8 * col), t(:blk_theme1)) } }
      a = bitmap(a, 0x3b)
      @attr = 0x59
      a = pair(a, t(:pair_blk1))
      autotile(t(:autotile1), @theme)
      decos(t(:deco1))
    when 2
      @attr = 0x59
      fill(c.call(0xc63b), 0x17, 0x1c, 0x8d)
      a = bitmap(a, 0x9b)
      @attr = 0x59
      a = pair(a, t(:pair_blk2))
      autotile(t(:autotile2), @theme)
      decos(t(:deco2))
      @attr = 0x59
      fill(c.call(0xc639), 1, 0x1b, 0x8f)
    else
      @attr = 0x59
      13.times { |r| 14.times { |col| block(c.call(0xc6bb - 0x80 * r - 4 * col), t(:blk_theme3)) } }
      a = bitmap(a, 0xba)
      @attr = 0x59
      a = pair(a, t(:pair_blk3))
      autotile(t(:autotile3), @theme)
      decos(t(:deco3))
    end
    floor_edge
    shadows
    # $150e: item spawn x, y ($650/$651), then the round's own decoration list
    ix, iy, list = g.round_tail(a)
    @item_spawn = [ix, iy]
    decos(list) if list
  end

  # $1554 (arcade $727e): the intermission picture - sky, frame, decorations, the castle of the coming theme, the message
  # message false: the attract's copy ($27c4) prints INSERT COIN(S) itself instead of the message
  def build_intermission(n, message: true)
    @tiles = Array.new(1024, 0)
    @attrs = Array.new(1024, 0)
    @solid = Array.new(800 + 2 * SOLID_PAD, 0)
    @door_pair = nil
    @item_spawn = nil
    @enemies = []
    @enemy_speed = 0xff
    @theme = 0
    @bg_half = 0
    c = RoundBuilder.method(:cell_of)
    @attr = 0xd8
    fill(c.call(0xc77f), 14, 32, 0xf1)
    fill(c.call(0xc3f3), 1, 0x15, 0xf2)
    fill(c.call(0xc3bf), 1, 0x1b, 0xf3)
    fill(c.call(0xc373), 8, 0x15, 0xf4)
    @attr = 0xd0
    mirror(c.call(0xc331), t(:inter_frame))
    decos(t(:inter_deco))
    pic, pal, msg = g.intermission(n)
    k = pic <= 4 ? pic : 4
    @attr = k <= 2 ? 0x99 : 0xd9
    block(c.call(0xc4fb), t(:inter_pics) + 11 * k)
    @palette_set = pal
    return self unless message
    pos = line = 0xc5fb # $284e: the message, attr $19, $0d = next line two rows down
    loop do
      b = g.byte(msg)
      msg += 1
      break if b == 0
      if b == 0x0d
        pos = line = line - 0x80
      else
        set(RoundBuilder.cell_of(pos), b, 0x19)
        pos -= 2
      end
    end
    self
  end

  # a cleared screen for the game-over scenes ($646 + palette set 4)
  def build_blank
    @tiles = Array.new(1024, 0)
    @attrs = Array.new(1024, 0)
    @solid = Array.new(800 + 2 * SOLID_PAD, 0)
    @door_pair = nil
    @item_spawn = nil
    @enemies = []
    @enemy_speed = 0xff
    @theme = 0
    @bg_half = 0
    @palette_set = 4
    self
  end

  def build_final
    @theme = 0xff
    @bg_half = 1     # $591 |= $18: BG cache from the second 64 KB of BGCHR
    @palette_set = 5
    c = RoundBuilder.method(:cell_of)
    at = lambda do |attr, pos, blk, mirrored = false|
      @attr = attr
      mirrored ? mirror(c.call(pos), blk) : block(c.call(pos), blk)
    end
    at.call(0x5a, 0xc67b, t(:final_blk_a))
    at.call(0x52, 0xc645, t(:final_blk_a), true)
    at.call(0x5a, 0xc37b, t(:final_blk_b))
    at.call(0x52, 0xc345, t(:final_blk_b), true)
    14.times { |k| at.call(0x5a, 0xc3fb - 4 * k, t(:final_blk_c)) }
    bitmap(t(:final_bitmap), 0xed)
    autotile(t(:final_autotile), 0xff)
    15.times { |k| at.call(0x1b, 0xc6fd - 4 * k, t(:final_blk_d)) }
    at.call(0x1b, 0xc6ff, t(:final_blk_e))
    at.call(0x1b, 0xc67f, t(:final_blk_f))
    at.call(0x13, 0xc641, t(:final_blk_f), true)
    floor_edge
  end

  # $253e: table $cf1e -> [speed -> $5fe] [count] count x [type, x, y]; type $ff = Worm door
  def load_enemies(rnd)
    a = g.enemy_list(rnd)
    @enemy_speed = g.byte(a)
    g.byte(a + 1).times do |k|
      @enemies << [g.byte(a + 2 + 3 * k), g.byte(a + 3 + 3 * k), g.byte(a + 4 + 3 * k)]
    end
    @enemies.each do |t, x, y|
      next unless t == 0xff
      @attr = @theme == 2 ? 0x59 : 0x19
      block(RoundBuilder.cell_at(x, y), @theme == 2 ? t(:door_blk2) : t(:door_blk))
    end
  end
end
