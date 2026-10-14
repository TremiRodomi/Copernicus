# X68000 palette words are GRB555+I: GGGGG RRRRR BBBBB I. Pixel arrays want ABGR.
# Every colour in the game is an arcade 4-bit level stored as level * 2 with I set (NOTES.md pass 20), so the two behaviours
# differ only in the output scale: arcade = level * 17 (full white is 255), X68000 = its 6-bit DAC, (c5 * 2 + I) / 63.
# Optional colour profile :pcb = the transfer curve measured from the user's own board (PCB captures, NOTES.md pass 21):
# levels 0-3 black, then about 255 * ((level - 3) / 12) ^ 1.3. It applies on top of arcade behaviour only.
module Palette
  PCB_CURVE = (0..15).map { |l| l <= 3 ? 0 : (255 * (((l - 3) / 12.0)**1.3)).round }.freeze

  class << self
    attr_accessor :profile # :standard (default) or :pcb
  end

  def self.abgr(w, arcade = true)
    # NB: in DragonRuby Integer / Integer returns a Float - always use idiv for integer maths
    pcb = arcade && profile == :pcb
    ch = [(w >> 6) & 31, (w >> 11) & 31, (w >> 1) & 31].map do |c|
      if pcb then PCB_CURVE[c >> 1]
      elsif arcade then (c >> 1) * 17
      else ((c * 2 + (w & 1)) * 255).idiv(63)
      end
    end
    0xFF000000 | (ch[2] << 16) | (ch[1] << 8) | ch[0]
  end

  # 16 sprite/text blocks of 16 colours ($ba80 -> $e82200). Index 0 of each block is transparent for sprites.
  def self.sprite_blocks(gd)
    arc = gd.behaviour == :arcade
    (0...16).map { |b| (0...16).map { |i| abgr(gd.word(gd.a(:pal_sprites) + 32 * b + 2 * i), arc) } }
  end

  # Graphic screen (256-colour mode). Palette writes below $e82200 go through the doubling copier ($386): source word j lands in
  # entries 2j and 2j+1. So set n ($b600 + n*128, 64 words, chosen by $28a4) fills 0-127 and the fixed table $ba00 (queued to
  # $e82080) fills 128-255. Net effect: colour = word[group * 16 + pixel]; the tile cache's "odd" bit selects the same colour.
  def self.graphic(gd, set)
    words = (0...64).map { |i| gd.word(gd.a(:pal_themes) + 128 * set + 2 * i) } + (0...64).map { |i| gd.word(gd.a(:pal_fixed) + 2 * i) }
    (0...256).map { |i| abgr(words[i >> 1], gd.behaviour == :arcade) }
  end
end
