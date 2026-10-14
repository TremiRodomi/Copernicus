# Score ($700-$702: 6 BCD digits; the HUD prints a fixed 0 after them) and the hidden EXP / level system.
module Score
  def self.bcd(v)
    (v >> 4) * 10 + (v & 15)
  end

  # $8fe4: d4 = lowest BCD pair, d3 = the pair above; caps at 999999. Not counted in the attract demo ($592).
  def self.add(w, d3, d4)
    return if w[:input_override] # $592 set: intro / attract demo
    g = w[:game]
    g[:score] = [g[:score] + bcd(d3) * 100 + bcd(d4), 999_999].min
  end

  # $2976 (every frame of play): the extra life by score. Factory DSW entry 0 (30,000, then every 100,000); a repeating
  # threshold that would pass 9999 stops the extends. Sound 8, lives +1 (99 at most; ENDLESS stays endless).
  def self.extend_check(w)
    g = w[:game]
    g[:extend] ||= World.gd.extend_entry(0)
    t, step = g[:extend]
    top = g[:score].idiv(100)
    if t.odd?
      return if top < t - 1
      return if t - 1 + step > 9999
      g[:extend] = [t - 1 + step, step]
    else
      return if top < t
      g[:extend] = [step, step]
    end
    g[:lives] = [g[:lives] + 1, 99].min unless g[:endless]
    w[:sounds] << 0x08
  end

  # $68f4 ($c821: wrapped-cake kill) / $68fc ($c833: crushed by a falling cake): [type, d4, d3] x 6
  def self.by_type(w, o, table)
    gd = World.gd
    6.times do |i|
      a = gd.a(table) + 3 * i
      next unless gd.byte(a) == o[Obj::TYPE]
      return add(w, gd.byte(a + 2), gd.byte(a + 1))
    end
  end

  # $6854: EXP += n (ignored if it would reach $f0); passing the threshold $706 raises it by 30 and the level ($705, max 7)
  def self.exp(w, n)
    g = w[:game]
    v = g[:exp] + n
    return if v >= 0xf0
    g[:exp] = v
    return if g[:exp_next] >= v
    return if g[:exp_next] + 0x1e > 0xff
    g[:exp_next] += 0x1e
    g[:level] += 1 if g[:level] < 7
  end

  # $691e: kills by a power-up spell. The first scores via $6a44 (entry 0), later ones as a combo ($69ec) by the count $5ff
  def self.multi_kill(w, o, timer)
    w[:kills5ff] = (w[:kills5ff] + 1) & 0xff
    if w[:kills5ff] >= 2
      save = w[:combo]
      w[:combo] = w[:kills5ff]
      combo(w, o, timer)
      w[:combo] = save
    else
      popup(w, 0, timer, o[Obj::SLOT], o[Obj::Y], o[Obj::X])
    end
  end

  # $69ec: combo score by $67e (2..7) from $c7f4, with a popup
  def self.combo(w, o, timer)
    n = w[:combo]
    n = w[:combo] = 7 if n >= 8
    return if n < 2
    gd = World.gd
    a = gd.a(:combo_scores) + 2 * (n - 2)
    add(w, gd.byte(a + 1), gd.byte(a))
    Effects.add_popup(w, [timer, n - 2, o[Obj::SLOT], o[Obj::Y], o[Obj::X]])
  end

  # $6a44: score entry d0 of $c800 [d4, d3, popup kind] with a popup
  def self.popup(w, index, timer, slot, y, x)
    gd = World.gd
    a = gd.a(:score_table) + 3 * index
    add(w, gd.byte(a + 1), gd.byte(a))
    Effects.add_popup(w, [timer, gd.byte(a + 2), slot, y, x])
  end
end
