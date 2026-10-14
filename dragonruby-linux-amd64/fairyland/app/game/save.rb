# The port's save file (fairyland/save.txt, plain text). Two kinds of data (user design, pass 52):
#   high scores: the best-5 table ($6d0: 5 x [score, round, name]) - ARCADE mode only
#   progress like the X68000's FS.DAT - last and best round reached ($6ce / $6cf) for CASUAL's ROUND SELECT - both
#   modes (an ARCADE run opens rounds to practise in CASUAL)
# Defaults come from the player's game data (X68000 $bc96 / arcade $7233).
module Save
  FILE = 'save.txt'

  class << self
    attr_accessor :readonly # dev runs started by flags (--round ...) never write: test scores once filled the user's table
  end

  def self.load(gd)
    d = { table: default_table(gd), last_round: 0, best_round: 0 }
    raw = DR.read_file(FILE)
    return d unless raw
    rows = []
    raw.each_line do |line|
      k, v = line.strip.split('=', 2)
      next unless v
      case k
      when 'last_round' then d[:last_round] = v.to_i
      when 'best_round' then d[:best_round] = v.to_i
      when 'score'
        s, r, name = v.split(',', 3)
        rows << [s.to_i, r.to_i, (name || '   ')[0, 3].ljust(3)]
      end
    end
    d[:table] = rows if rows.size == 5
    d
  rescue StandardError
    { table: default_table(gd), last_round: 0, best_round: 0 }
  end

  def self.write(d)
    return if readonly
    lines = ["last_round=#{d[:last_round]}", "best_round=#{d[:best_round]}"]
    d[:table].each { |s, r, name| lines << "score=#{s},#{r},#{name}" }
    DR.write_file(FILE, lines.join("\n") + "\n")
  end

  def self.default_table(gd)
    a = gd.a(:hiscore_default)
    (0...5).map do |k|
      e = a + 7 * k
      score = Score.bcd(gd.byte(e)) * 10_000 + Score.bcd(gd.byte(e + 1)) * 100 + Score.bcd(gd.byte(e + 2))
      [score, gd.byte(e + 3), (0..2).map { |i| gd.byte(e + 4 + i).chr }.join]
    end
  end

  # $2f84: a new entry needs a score above the 5th
  def self.qualifies?(d, score)
    score > d[:table][4][0]
  end

  # $2da0: from the 4th entry up, entries with a lower score move down one; returns the new entry's index
  def self.insert(d, score, round)
    i = 4
    i -= 1 while i > 0 && score > d[:table][i - 1][0]
    d[:table].insert(i, [score, round, '   '])
    d[:table].pop
    i
  end
end
