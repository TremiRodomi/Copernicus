# Text in the name table ($b52 / $930). Addresses are the original's $c000-$c7ff name-table addresses of the ATTRIBUTE byte
# (the code byte sits just below it); each character moves one cell right (a2 -= 2). Writes go to w[:bg] and mark the
# cell dirty; main.rb redraws dirty cells.
module Text
  def self.cell(addr)
    (0x7ff - (addr & 0x7ff)) >> 1
  end

  def self.put(w, addr, code, attr)
    i = cell(addr)
    return if i < 0 || i >= 1024
    w[:bg][:tiles][i] = code & 0xff
    w[:bg][:attrs][i] = attr & 0xff
    w[:bg_dirty] << i
  end

  def self.print(w, addr, attr, str)
    str.each_char.with_index { |c, k| put(w, addr - 2 * k, c.ord, attr) }
  end

  # (tile, attr) pairs under a run of cells, for putting the background back after a message
  def self.save(w, addr, n)
    (0...n).map { |k| i = cell(addr - 2 * k); [w[:bg][:tiles][i], w[:bg][:attrs][i]] }
  end

  def self.restore(w, addr, saved)
    saved.each_with_index { |(t, a), k| put(w, addr - 2 * k, t, a) }
  end
end

# The HUD ($7b8 every frame in the original; here only when a value changed): HIGH SCORE, 1UP + score, ROUND, lives ($29f4)
module Hud
  def self.update(w)
    return if w[:hud_off] # the ending runs instead of the main loop: no HUD refresh
    g = w[:game]
    key = [g[:score], g[:hiscore], g[:lives], w[:no_hit]]
    return if w[:hud_key] == key
    w[:hud_key] = key
    Text.print(w, 0xc769, 0x39, 'HIGH SCORE')
    Text.print(w, 0xc727, 0x38, digits(g[:hiscore]) + '0')
    Text.print(w, 0xc777, 0x39, '1UP')
    Text.print(w, 0xc73b, 0x38, digits(g[:score]) + '0')
    lives(w, g)
  end

  # the top line only: HIGH SCORE + value, 1UP + score (the scenes' $7b8 call)
  def self.top(w)
    g = w[:game]
    Text.print(w, 0xc769, 0x39, 'HIGH SCORE')
    Text.print(w, 0xc727, 0x38, digits(g[:hiscore]) + '0')
    score(w)
  end

  # $7ee: "1UP" and the score only (the ending redraws just these)
  def self.score(w)
    Text.print(w, 0xc777, 0x39, '1UP')
    Text.print(w, 0xc73b, 0x38, digits(w[:game][:score]) + '0')
  end

  # $838: six digits, leading zeros as spaces
  def self.digits(v)
    s = format('%06d', v)
    n = 0
    n += 1 while n < 6 && s[n] == '0'
    (' ' * n) + s[n..]
  end

  # $1160: "ROUND:" and the number ($982: three digits, leading zeros as spaces)
  def self.round(w, n)
    Text.print(w, 0xc093, 0x3d, 'ROUND:')
    Text.print(w, 0xc093 - 12, 0x3c, n.to_s.rjust(3))
  end

  # $29f4
  def self.lives(w, g)
    a = 0xc0bb # like the original, prints over what is there (lives only change on a fresh screen or go up)
    return Text.print(w, a, 0x3c, 'NO HIT') if w[:no_hit]
    return Text.print(w, a, 0x3c, 'ENDLESS') if g[:endless] # from the setting ($2a18), never from the counter
    n = g[:lives] - 1
    return if n <= 0 # $2a3c: no spare life, nothing printed
    if n < 5
      Text.print(w, a, 0x3c, '[' * n)
    else
      Text.print(w, a, 0x3c, '[[')
      Text.print(w, a - 4, 0x3d, '..')
      Text.print(w, a - 8, 0x3c, n.to_s) # $956: BCD, leading 0 dropped
    end
  end
end
