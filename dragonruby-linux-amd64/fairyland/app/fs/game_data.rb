# Loads the player's own copy of the game from data/ - EITHER version works, nothing from the game is shipped with the port:
#   X68000: the Disk 1 image (.hdm / .dim) or the files FS.X, BGCHR.DAT, SPCHR.DAT taken from it
#   arcade: the ROM files of the "flstory" set (main CPU cpu-a45.15-17, graphics vid-a45.06-09 / .18-21, MCU a45-20.mcu),
#   loose in data/ under any names - they are recognised by their contents (CRC32), see ARCADE_CRC - or inside the
#   Arcade Archives (Switch) executable `main`, see extract_embedded
# Whichever is loaded, the engine sees the same thing: tables by name (fs/tables.rb), BGCHR as one byte per pixel (64 per
# 8x8 tile), SPCHR in the X68000 PCG layout and palettes as X68000 GRB555+I words. The arcade path converts into those.
class GameData
  attr_reader :img, :bgchr, :spchr, :source, :version, :behaviour
  attr_accessor :splash_raw # FLS_TTL.DAT (LZSS) whenever an X68000 disk is there, even if the ROMs are played: the boot
                            # splash of X68000 behaviour (main.rb start_boot)

  MULTI = %i[glow gem banner title_fade1 title_fade2].freeze # palette patches that are step sequences
  TEXT_SIZE = 0x9bfa # FS.X text segment; the flat image (text + data) is what all table addresses in NOTES.md refer to
  X68_FILES = %w[FS.X BGCHR.DAT SPCHR.DAT].freeze
  ARCADE_CPU = %w[cpu-a45.15 cpu-a45.16 cpu-a45.17].freeze # Z80 $0000-$bfff
  ARCADE_MCU = 'a45-20.mcu'.freeze # the protection MCU: ending / continue text, loaded at image $10000
  # The arcade ROMs by content, so any file names work: MAME "flstory" and the older "flstoryo" (they differ only in the
  # sound CPU ROMs, which the port does not use), Taito Legends 2's old MAME set (no MCU - dumped later, must be added),
  # files extracted from other releases. A file larger than one ROM is searched in 16 KB / 2 KB blocks (merged dumps).
  ARCADE_CRC = { 'cpu-a45.15' => 0xf03fc969, 'cpu-a45.16' => 0x311aa82e, 'cpu-a45.17' => 0xa2b5d17d,
                 'vid-a45.06' => 0xdc856a75, 'vid-a45.07' => 0xaa4b0762, 'vid-a45.08' => 0xd0b028ca,
                 'vid-a45.09' => 0x8336be58, 'vid-a45.18' => 0x6f08f69e, 'vid-a45.19' => 0x2b572dc9,
                 'vid-a45.20' => 0x1b0edf34, 'vid-a45.21' => 0xfc382bd1, 'a45-20.mcu' => 0x7d2cdd9b }.freeze
  CRC_TABLE = (0...256).map { |n| c = n; 8.times { c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }; c }.freeze
  ARCADE_GFX = %w[vid-a45.06 vid-a45.07 vid-a45.08 vid-a45.09 vid-a45.18 vid-a45.19 vid-a45.20 vid-a45.21].freeze

  # no usable game data: a short message for the player (main.rb shows the lines, no class or backtrace)
  class Missing < StandardError
    attr_reader :lines

    def initialize(*lines)
      @lines = lines
      super(lines.join(' '))
    end
  end

  # prefer: :arcade / :x68000 when both are present (default: arcade)
  def self.load(dir = 'data', prefer: nil)
    names = (DR.list_files(dir) || []).reject { |n| n.start_with?('.') }
    find = ->(f) { names.find { |x| x.downcase == f.downcase } }
    read = ->(f) { DR.read_file("#{dir}/#{find.call(f)}") }
    roms = find_arcade(dir, names)
    roms.merge!(extract_embedded(dir, names, roms)) unless ARCADE_CRC.keys.all? { |f| roms[f] } # (Arcade Archives)
    arcade = ARCADE_CRC.keys.all? { |f| roms[f] }
    x68 = nil
    image = names.find { |n| n.downcase.end_with?('.hdm') || n.downcase.end_with?('.dim') }
    if image
      disk = Disk.root_files(DR.read_file("#{dir}/#{image}"), dim: image.downcase.end_with?('.dim'))
      x68 = [disk, image] if disk['FS.X']
    end
    grab = ->(list) { h = {}; list.each { |f| h[f] = read.call(f) }; h }
    x68 ||= [grab.call(X68_FILES), 'loose files'] if X68_FILES.all? { |f| find.call(f) }
    splash = x68 && x68[0]['FLS_TTL.DAT'] || (find.call('FLS_TTL.DAT') && read.call('FLS_TTL.DAT'))
    if arcade && (prefer != :x68000 || !x68)
      gd = new(:arcade, roms, 'arcade ROMs')
      gd.splash_raw = splash
      return gd
    end
    unless x68
      missing = ARCADE_CRC.keys.reject { |f| roms[f] }
      unless roms.empty?
        mcu = missing.include?(ARCADE_MCU) ? ['a45-20.mcu was dumped later: take it from a current MAME flstory set.'] : []
        raise Missing.new('ARCADE ROMS INCOMPLETE', "Missing: #{missing.join(' ')}", *mcu)
      end
      raise Missing.new('GAME DATA NOT FOUND', 'Put your X68000 Disk 1 image (.hdm / .dim)',
                        'or the arcade ROM set (flstory) in the data folder.')
    end
    gd = new(:x68000, x68[0], x68[1])
    gd.splash_raw = splash
    gd
  end

  # the X68000's "Now Loading..." picture: 512 x 512 GRB555+I words (CRTMOD $10c, loader $f5e) -> ABGR, top row first;
  # nil without the disk or if the file does not decode to 512 KB
  def splash_pixels
    return nil unless @splash_raw
    d = LZSS.decode(@splash_raw)
    return nil unless d.size == 0x80000
    cache = {}
    (0...0x40000).map do |i|
      w = (d[2 * i] << 8) | d[2 * i + 1]
      cache[w] ||= Palette.abgr(w, false)
    end
  rescue StandardError
    nil
  end

  # name => contents for every arcade ROM found in dir, matched by CRC32 (whole files, or 16 KB / 2 KB blocks of a bigger one)
  def self.find_arcade(dir, names)
    want = ARCADE_CRC.invert
    found = {}
    names.each do |n|
      next if n.downcase.end_with?('.hdm', '.dim', '.txt', '.x', '.dat')
      data = DR.read_file("#{dir}/#{n}")
      next unless data && data.bytesize >= 0x800 && data.bytesize <= 0x100000
      [0x4000, 0x800].each do |blk|
        next if data.bytesize % blk != 0 || (blk == 0x800 && found[ARCADE_MCU])
        data.bytesize.idiv(blk).times do |k| # (mruby: no Range#step)
          chunk = data.byteslice(k * blk, blk)
          name = want[crc32(chunk)]
          found[name] ||= chunk if name && (blk == 0x800) == (name == ARCADE_MCU)
        end
      end
    end
    found
  end

  # Arcade Archives (Hamster, Switch; pass 59): the ROMs - the MCU too - are stored whole but unaligned inside the game's
  # executable `main` (an NSO: its segments LZ4-compressed). The player copies that file into data/; the ROMs are found by
  # sliding a rolling checksum over it (ROLL: [sum of the bytes, sum of (size - i) * byte i] of each ROM - numbers like
  # the CRCs), confirmed by CRC32, then written to data/ under their MAME names so the next start loads them directly.
  # Any other big file (another release's executable or archive, uncompressed) is scanned the same way.
  ROLL = { 'cpu-a45.15' => [1833116, 14356488950], 'cpu-a45.16' => [1880475, 15452112885],
           'cpu-a45.17' => [1545673, 13103843317], 'vid-a45.06' => [2375079, 18747390702],
           'vid-a45.07' => [1544831, 11157794191], 'vid-a45.08' => [1299676, 9733209172],
           'vid-a45.09' => [590187, 4225108109], 'vid-a45.18' => [1068875, 8698605842],
           'vid-a45.19' => [583024, 5428648351], 'vid-a45.20' => [1545791, 12538022726],
           'vid-a45.21' => [949420, 7647368472], 'a45-20.mcu' => [175687, 167888702] }.freeze
  SCAN_MAX = 0x4000000 # 64 MB: bigger files are not looked into

  # name => contents of the ROMs found inside the big files of dir (written to dir as well); {} if none
  def self.extract_embedded(dir, names, have)
    found = {}
    names.each do |n|
      next if n.downcase.end_with?('.hdm', '.dim', '.txt', '.png', '.ogg', '.wav')
      size = (DR.stat_file("#{dir}/#{n}") || {})[:file_size] || 0
      next if size <= 0x100000 || size > SCAN_MAX
      data = DR.read_file("#{dir}/#{n}")
      next unless data
      data = nso_image(data) if data.byteslice(0, 4) == 'NSO0'
      scan_roms(data, have.merge(found)).each { |name, rom| found[name] = rom }
      break if ARCADE_CRC.keys.all? { |f| have[f] || found[f] }
    end
    found.each { |name, rom| DR.write_file("#{dir}/#{name}", rom) }
    found
  end

  # every ROM not in `have` whose rolling sums and CRC32 match somewhere in data
  def self.scan_roms(data, have)
    found = {}
    [0x4000, 0x800].each do |n|
      want = {}
      ROLL.each { |name, (a, b)| want[(b << 23) | a] = name if !have[name] && (name == ARCADE_MCU) == (n == 0x800) }
      next if want.empty? || data.bytesize < n
      bytes = data.bytes
      a = 0
      b = 0
      n.times { |i| a += bytes[i]; b += (n - i) * bytes[i] }
      i = 0
      last = bytes.size - n
      while true
        name = want[(b << 23) | a]
        if name && !found[name]
          rom = data.byteslice(i, n)
          found[name] = rom if crc32(rom) == ARCADE_CRC[name]
        end
        break if i == last
        out = bytes[i]
        a += bytes[i + n] - out
        b += a - n * out
        i += 1
      end
    end
    found
  end

  # The Switch executable format (NSO: header 'NSO0'): segments .text, .rodata, .data, each LZ4-block compressed when
  # its flag bit (header +$0c) is set. Only .rodata + .data are returned - the ROMs are data (Arcade Archives: in
  # .rodata), and skipping the code makes the one-time scan about 4x faster.
  def self.nso_image(d)
    u32 = ->(o) { d.getbyte(o) | (d.getbyte(o + 1) << 8) | (d.getbyte(o + 2) << 16) | (d.getbyte(o + 3) << 24) }
    flags = u32.call(0x0c)
    img = ''
    [1, 2].each do |k|
      foff = u32.call(0x10 + 16 * k)
      size = u32.call(0x18 + 16 * k)
      seg = d.byteslice(foff, u32.call(0x60 + 4 * k))
      img << ((flags >> k) & 1 == 1 ? lz4_block(seg) : seg.byteslice(0, size))
    end
    img
  end

  # one LZ4 block (no frame header): tokens of literals then a back-reference (16-bit offset, length + 4)
  def self.lz4_block(src)
    out = ''
    i = 0
    len = src.bytesize
    while i < len
      tok = src.getbyte(i)
      i += 1
      lit = tok >> 4
      if lit == 15
        loop { b = src.getbyte(i); i += 1; lit += b; break if b != 255 }
      end
      out << src.byteslice(i, lit)
      i += lit
      break if i >= len
      off = src.getbyte(i) | (src.getbyte(i + 1) << 8)
      i += 2
      ml = tok & 15
      if ml == 15
        loop { b = src.getbyte(i); i += 1; ml += b; break if b != 255 }
      end
      ml += 4
      start = out.bytesize - off
      while ml > 0 # (overlapping copies repeat the last `off` bytes)
        part = out.byteslice(start, [ml, off].min)
        out << part
        start += part.bytesize
        ml -= part.bytesize
      end
    end
    out
  end

  def self.crc32(s)
    c = 0xffffffff
    s.each_byte { |b| c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >> 8) }
    c ^ 0xffffffff
  end

  def initialize(kind, files, source)
    @source = source
    @version = kind
    kind == :x68000 ? load_x68(files) : load_arcade(files)
    setup_tables(kind == :x68000 ? 0 : 1)
    synth_palettes(files) if kind == :arcade
    self.behaviour = :arcade
  end

  # :arcade / :x68000 - picks the copy of every Tables::VARIANTS table and Tables::PATCHES byte
  def behaviour=(b)
    @behaviour = b
    Tables::PATCHES.each do |pt|
      put(pt[@version][0], pt[b][1])
    end
  end

  # --- Round data readers: the one place that knows each version's pointer widths and record layouts ---
  # X68000: 32-bit pointers; record tail [item x, item y, unused, decoration selector ($11+n into :deco_lists, 0 = none)];
  #   decoration entries [word attr, long screen pos, long block], ended by a zero word.
  # Arcade: 16-bit little-endian pointers; tail [item x, item y, word pointer to the decoration list (0 = none)];
  #   entries [attr, word screen pos, word block], ended by a zero attr.

  # address of round rnd's record (0-based): theme byte, 100-byte bitmap, block pair, tail
  def round_record(rnd)
    ptr(a(:round_records), rnd)
  end

  # address of round rnd's enemy list: [speed] [count] count x [type, x, y]
  def enemy_list(rnd)
    ptr(a(:enemy_tables), rnd)
  end

  # tail at t -> [item x, item y, decoration list address or nil]
  def round_tail(t)
    list = if @version == :x68000
             sel = byte(t + 3)
             long(a(:deco_lists) + 4 * (sel - 0x11)) if sel != 0
           else
             v = byte(t + 2) | (byte(t + 3) << 8)
             v if v != 0
           end
    [byte(t), byte(t + 1), list]
  end

  # decoration list -> [[attr, screen pos, block address], ...]
  def deco_entries(l)
    out = []
    if @version == :x68000
      while (w = word(l)) != 0
        out << [w & 0xff, long(l + 2), long(l + 6)]
        l += 10
      end
    else
      while (v = byte(l)) != 0
        out << [v, byte(l + 1) | (byte(l + 2) << 8), byte(l + 3) | (byte(l + 4) << 8)]
        l += 5
      end
    end
    out
  end

  # score extend DSW entry k -> [first threshold, step], 4-digit decimals of the score's top BCD digits (score / 100);
  # an odd threshold = the repeating stage (bit 0 of $709 - the step's own bit 0 keeps it set)
  def extend_entry(k)
    a = a(:extend_table) + 4 * k
    b = (0..3).map { |i| Score.bcd(byte(a + i)) }
    @version == :x68000 ? [b[2] * 100 + b[3], b[0] * 100 + b[1]] : [b[3] * 100 + b[2], b[1] * 100 + b[0]]
  end

  # attract demo k (0-2) -> [0-based round, input script address]
  def demo(k)
    t = a(:demo_table)
    @version == :x68000 ? [long(t + 8 * k), long(t + 8 * k + 4)] : [byte(t + 3 * k), byte(t + 3 * k + 1) | (byte(t + 3 * k + 2) << 8)]
  end

  # the title's sparkle list -> one group per tick, each [[name-table address, block address], ...] (one or two)
  def title_sparkle
    @title_sparkle ||= begin
      x68 = @version == :x68000
      w = x68 ? 6 : 4
      entry = ->(ad) { [x68 ? word(ad) : byte(ad) | (byte(ad + 1) << 8), x68 ? long(ad + 2) : byte(ad + 2) | (byte(ad + 3) << 8)] }
      zero = ->(ad) { x68 ? word(ad) == 0 : byte(ad) == 0 } # the arcade tests the low byte only
      groups = []
      ad = a(:title_sparkle)
      until zero.call(ad)
        g = [entry.call(ad)]
        ad += w
        if zero.call(ad)
          ad += x68 ? 2 : 1
        else
          g << entry.call(ad)
          ad += w
        end
        groups << g
      end
      groups
    end
  end

  # intermission n -> [castle picture (0-4, $ff = attract), palette set, message address]
  def intermission(n)
    t = a(:inter_table)
    if @version == :x68000
      [byte(t + 8 * n + 1), byte(t + 8 * n + 3), long(t + 8 * n + 4)]
    else
      [byte(t + 4 * n), byte(t + 4 * n + 1), byte(t + 4 * n + 2) | (byte(t + 4 * n + 3) << 8)]
    end
  end

  # sprite priority list n (1 normal, 2 death / potions, 3 eaten by the Worm): 32 sprite indices, the FIRST drawn on top
  def sprite_order(n)
    @sprite_order ||= {}
    @sprite_order[n] ||= (0...32).map do |k|
      @version == :x68000 ? byte(a(:prio_lists) + 64 * n + 2 * k + 1) & 0x1f : byte(a(:prio_lists) + 32 * n + k) & 0x1f
    end
  end

  # address of Horned's entrance script i (1-4)
  def horned_script(i)
    ptr(a(:horned_scripts), i)
  end

  # sprite code of bonus item idx (0-17): first word of its handler (X68000) / first byte (arcade)
  def item_sprite(idx)
    if @version == :x68000
      word(long(a(:item_handlers) + 4 * idx)) & 0xff
    else
      byte(ptr(a(:item_handlers), idx))
    end
  end

  # Sprite palette patch -> [[colour index (block * 16 + pixel), X68000 colour word], ...]; :glow -> list of such steps
  def pal_patch(name)
    @pal_patch ||= {}
    @pal_patch[name] ||= begin
      spec = Tables::PAL_PATCH.fetch(name)[@version]
      steps = if spec.is_a?(Array) && spec[0] == :gem # 10 steps: offsets list x colour words (arcade format)
                offs = (0...5).map { |k| word(spec[1] + 4 * k) >> 1 }
                (0...10).map { |s| offs.each_with_index.map { |o, k| c = word(spec[2] + 10 * s + 2 * k); [o, arcade_colour(c >> 8, c & 0xff)] } }
              elsif spec.is_a?(Array) && spec[0] == :pens # arcade gem: pens counting down, [hi, lo] pairs
                (0...10).map { |s| (0...5).map { |k| a = spec[2] + 10 * s + 2 * k; [arcade_pen(spec[1] - k), arcade_colour(byte(a), byte(a + 1))] } }
              elsif spec.is_a?(Array) && spec[0] == :cycle # arcade banner: one pen, [hi, lo] pairs until 0
                out = []
                ad = spec[2]
                while byte(ad) != 0
                  out << [[arcade_pen(spec[1]), arcade_colour(byte(ad), byte(ad + 1))]]
                  ad += 2
                end
                out
              elsif spec.is_a?(Array) && spec[0] == :hilo2 # arcade title fades: two [pen, hi, lo] writes per step
                out = []
                ad = spec[1]
                while byte(ad) != 0
                  out << [0, 3].map { |o| [arcade_pen(byte(ad + o)), arcade_colour(byte(ad + o + 1), byte(ad + o + 2))] }
                  ad += 6
                end
                out
              elsif @version == :x68000
                lists = []
                ad = spec
                loop do
                  l = []
                  while (off = word(ad)) != 0
                    l << [off >> 1, word(ad + 2)]
                    ad += 4
                  end
                  ad += 2
                  break if l.empty?
                  lists << l
                  break unless MULTI.include?(name)
                end
                lists
              elsif spec[0].is_a?(Symbol)
                out = []
                ad = spec[1]
                while (pen = byte(ad)) != 0
                  hi, lo = spec[0] == :hilo ? [byte(ad + 1), byte(ad + 2)] : [byte(ad + 2), byte(ad + 1)]
                  out << [[arcade_pen(pen), arcade_colour(hi, lo)]]
                  ad += 3
                end
                MULTI.include?(name) ? out : [out.flatten(1)]
              else
                [spec.map { |pa, la, ha| [arcade_pen(byte(pa)), arcade_colour(byte(ha), byte(la))] }]
              end
      MULTI.include?(name) ? steps : steps[0]
    end
  end

  # Address of a named table (Tables::ADDR) in this image
  def a(name)
    (@behaviour != @version && @alt[name]) || @addr.fetch(name)
  end

  def byte(a)
    @img.getbyte(a)
  end

  def sbyte(a)
    v = @img.getbyte(a)
    v >= 0x80 ? v - 0x100 : v
  end

  def word(a)
    (@img.getbyte(a) << 8) | @img.getbyte(a + 1)
  end

  def long(a)
    long_at(@img, a)
  end

  private

  def load_x68(files)
    x = files['FS.X']
    raise 'FS.X is not a Human68k executable' unless x.byteslice(0, 2) == 'HU'
    text = long_at(x, 12)
    data = long_at(x, 16)
    raise "unexpected FS.X layout (text #{text})" unless text == TEXT_SIZE
    @img = x.byteslice(0x40, text + data)
    @bgchr = LZSS.decode(files['BGCHR.DAT'])
    @spchr = LZSS.decode(files['SPCHR.DAT'])
    raise 'BGCHR.DAT has the wrong size' unless @bgchr.size == 131_072
    raise 'SPCHR.DAT has the wrong size' unless @spchr.size == 98_304
  end

  # Arcade graphics: each ROM pair holds 1024 8x8 tiles, 16 bytes per tile per ROM, 2 bytes per row; pixel x (0-3 of each
  # byte) takes bits x and x+4 of the first ROM (pen bits 0, 1) and of the second (bits 2, 3). The X68000 conversion kept
  # these pen values and the numbering exactly (NOTES.md pass 20): BG tiles 0-1023 = .06/.07, 1024-2047 = .20/.21;
  # sprite banks 0/1/2 = .18/.19, .08/.09, .20/.21, a 16x16 sprite being 4 consecutive tiles (TL, TR, BL, BR).
  def load_arcade(files)
    sizes = files.map { |n, d| [n, d.bytesize] }.reject { |n, sz| sz == (n == ARCADE_MCU ? 2048 : 16_384) }
    raise "wrong ROM size: #{sizes.map { |n, sz| "#{n} #{sz}" }.join(', ')}" unless sizes.empty?
    @img = ARCADE_CPU.map { |f| files[f] }.join + ([0] * 0x4000).pack('C*') + files[ARCADE_MCU]
    pair = ->(a, b) { [files["vid-a45.#{a}"], files["vid-a45.#{b}"]] }
    @bgchr = Array.new(131_072, 0)
    [pair.call('06', '07'), pair.call('20', '21')].each_with_index do |(lo, hi), h|
      1024.times { |t| arcade_tile(lo, hi, t) { |x, y, v| @bgchr[(h * 1024 + t) * 64 + y * 8 + x] = v } }
    end
    @spchr = Array.new(98_304, 0)
    [pair.call('18', '19'), pair.call('08', '09'), pair.call('20', '21')].each_with_index do |(lo, hi), bank|
      256.times do |k|
        base = (bank * 256 + k) * 128
        4.times do |q|
          ox = (q & 1) * 8
          oy = (q >> 1) * 8
          arcade_tile(lo, hi, 4 * k + q) do |x, y, v|
            sx = ox + x
            sy = oy + y
            i = base + ((sx >> 3) * 2 + (sy >> 3)) * 32 + (sy & 7) * 4 + ((sx & 7) >> 1)
            @spchr[i] |= sx.even? ? v << 4 : v
          end
        end
      end
    end
  end

  def arcade_tile(lo, hi, t)
    o = t * 16
    8.times do |y|
      8.times do |x|
        a = o + y * 2 + (x >> 2)
        bit = x & 3
        l = lo.getbyte(a)
        h = hi.getbyte(a)
        yield x, y, ((l >> bit) & 1) | (((l >> (bit + 4)) & 1) << 1) | (((h >> bit) & 1) << 2) | (((h >> (bit + 4)) & 1) << 3)
      end
    end
  end

  # Arcade palette RAM: low byte GGGGRRRR, high byte ----BBBB, stored as n low bytes then n high bytes. The boards invert the
  # graphics data, so within each group of 16 the pen is 15 - pixel; the X68000 tables are the same colours in pixel order,
  # at twice the value with the intensity bit set. Rebuild them in that form and point the palette tables at them.
  def synth_palettes(_files)
    words = lambda do |base, n, count|
      (0...count).map do |i|
        e = (i & ~15) | (15 - (i & 15))
        lo = byte(base + e)
        hi = byte(base + n + e)
        ((lo >> 4) * 2 << 11) | ((lo & 15) * 2 << 6) | ((hi & 15) * 2 << 1) | 1
      end
    end
    # 8 sets: the intermissions use sets 5-7; on the arcade sets 6 and 7 are simply the next 128-byte chunks (they overlap
    # the fixed and boot tables) - and equal the X68000's sets 6-7
    tables = { pal_themes: (0...8).flat_map { |s| words.call(a(:pal_arcade_themes) + 128 * s, 64, 64) },
               pal_fixed: words.call(a(:pal_arcade_fixed), 64, 64),
               pal_sprites: words.call(a(:pal_arcade_full), 256, 256) }
    tables.each do |name, ws|
      @addr[name] = @img.bytesize
      @img << ws.flat_map { |w| [w >> 8, w & 0xff] }.pack('C*')
    end
  end

  # arcade sprite pen -> the X68000 colour index (pens run 15 - pixel within each block of 16)
  def arcade_pen(p)
    (p & ~15) | (15 - (p & 15))
  end

  # arcade palette bytes (hi ----BBBB, lo GGGGRRRR) -> X68000 word (level * 2 per channel, intensity bit set)
  def arcade_colour(hi, lo)
    ((lo >> 4) * 2 << 11) | ((lo & 15) * 2 << 6) | ((hi & 15) * 2 << 1) | 1
  end

  def put(addr, v)
    @img = @img.byteslice(0, addr) + [v].pack('C') + @img.byteslice(addr + 1, @img.bytesize - addr - 1)
  end

  def ptr(table, i)
    @version == :x68000 ? long(table + 4 * i) : byte(table + 2 * i) | (byte(table + 2 * i + 1) << 8)
  end

  # col = this version's column in Tables::ADDR. Checks the native copy of every variant against the player's data, then
  # appends the other version's copy to the image.
  def setup_tables(col)
    @addr = {}
    Tables::ADDR.each { |n, v| @addr[n] = v[col] if v[col] }
    other = @version == :x68000 ? :arcade : :x68000
    @alt = {}
    @img = @img.dup
    Tables::VARIANTS.each do |n, v|
      mine = v[@version]
      have = (0...mine.size).map { |i| byte(@addr.fetch(n) + i) }
      raise "data check failed for table #{n}: is this the right version of the game?" unless have == mine
      @alt[n] = @img.bytesize
      @img << v[other].pack('C*')
    end
    Tables::VARIANT_EDITS.each do |n, e|
      t = (0...e[:size][@version]).map { |i| byte(@addr.fetch(n) + i) }
      mine = e[@version]
      raise "data check failed for table #{n}: is this the right version of the game?" unless t[e[:at], mine.size] == mine
      t[e[:at], mine.size] = e[other]
      @alt[n] = @img.bytesize
      @img << t.pack('C*')
    end
    Tables::PATCHES.each do |pt|
      ad, v = pt[@version]
      raise "data check failed at #{format('$%x', ad)} (#{pt[:what]}): is this the right version of the game?" unless byte(ad) == v
    end
  end

  def long_at(s, a)
    (s.getbyte(a) << 24) | (s.getbyte(a + 1) << 16) | (s.getbyte(a + 2) << 8) | s.getbyte(a + 3)
  end
end
