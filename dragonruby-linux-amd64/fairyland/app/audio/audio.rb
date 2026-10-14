# Sound: the original's command numbers ($4ac, sound_commands.csv) are the event ids - tasks push them to w[:sounds] and
# this module plays canned audio for them (MDRV.X / PCMDRV.R and the arcade sound board are not emulated).
# Files are NOT part of the port (released binaries bundle them). Per set (arcade = OST music + MAME effect recordings, original /
# arrange = the X68000 soundtracks), in fairyland/audio/<set>/:
#   music/tracks.txt  "<cmd hex> = <track> [> <track> ...]"; a track "X" is music/X.ogg played once, or music/X intro.ogg
#                     then music/X loop.ogg looped; "X*" = music/X loop.ogg alone, looped. music/lengths.txt "<file name> = <samples>" (44.1 kHz) says when the
#                     next part starts; intros are whole 1/60 s frames, so the switch lands on the exact frame.
#   <cmd hex> <any name>.ogg|.wav  single sounds by command number (e.g. 16 ptolemy jump.ogg)
#   flat/             the same file names rendered without the TA7630 tone controls (GAME OPTIONS > SFX FILTER = OFF);
#                     any file played (effects and music steps alike) is swapped for its namesake there when one exists
# Music commands come from the set chosen in GAME OPTIONS > MUSIC, falling back to arcade; effects likewise (the X68000
# sets have no effects of their own: its PCM samples are lower-quality copies of the arcade sounds - user's call).
#   FM commands ($4ee table -> MDRV songs): one music channel, a new one replaces the old; PCM commands: one channel each
#   (the same effect restarts). $00 = stop all, $ee = stop + mute (the attract), $ef = unmute.
module Audio
  ROOT = 'audio'
  SETS = %w[arcade original arrange].freeze
  FM = ((0x06..0x15).to_a + [0x30, 0x31, 0x38, 0x3f]).freeze # $4ee: everything else below $40 is a PCM sample id
  EXT = %w[.ogg .wav].freeze
  SAMPLES_PER_FRAME = 735 # 44100 / 60
  # Jingles that play OVER the music instead of replacing it. Measured in MAME (an extend forced at a known point of the
  # round BGM): $08 silences the BGM, which keeps running underneath and is heard again 2.58 s later at the point it
  # had reached (4.48 s in before, 10.06 s in after).
  OVERLAY = { 0x08 => 155 }.freeze
  # $21 (Star Tiara) is the locked looping sample: the driver restarts it whenever it ends ($574) until $01 cancels it
  LOOP_SFX = 0x21
  CANCEL_LOOP = 0x01
  # $04 after the name entry (arcade $7006 / $70dd, X68000 $2eca / $2fd6): the arcade sound board stops the music
  STOP_MUSIC_ARCADE = 0x04

  # The arcade sound board's "busy" for FM effects given as single files, in frames: the tasks that wait for the driver
  # read it. $14: busy 140 frames (MAME, the moon: $14 -> $0a 141 frames later = the reply poll + a 1-frame yield).
  # $0b Miss: busy 298 frames (MAME: $0b -> the restart's $07 = 298 + the round's build time, rounds 1 and 3; the PCB
  # recording runs 310) - the death waits for it ($418e)
  # $15 morning: busy 130 frames (MAME, round 1: $15 -> the moon's next $09 131 frames later = the poll + a 1-frame yield)
  BOARD_BUSY = { 0x14 => 140, 0x0b => 298, 0x15 => 130 }.freeze

  # The arcade sound board's channel logic (MAME, the Dracolisk's crumble, NOTES pass 55; sound CPU not analysed, so
  # this is the measured behaviour; applied with the ARCADE music set, like $04 - the X68000's FM and PCM are separate):
  # CUT: a command that arrives while the given effect still plays STOPS it and is not heard itself - the first $37,
  #   25 frames into the $36 drone, leaves 14 frames of silence; the second $37 then plays.
  # STOPS_MUSIC: the effect takes over the music's channels - the Dracolisk BGM ends at $36 (the gem's $38 is next).
  CUT = { 0x37 => 0x36 }.freeze
  STOPS_MUSIC = [0x36].freeze

  VARIANT = { off: 'flat' }.freeze # SFX FILTER -> sub-folder

  class << self
    attr_accessor :music_gain, :sfx_gain # 0.0-1.0, from GAME OPTIONS
    attr_accessor :filter # :pcb (the files in the set folder), :off
  end
  self.music_gain = 1.0
  self.sfx_gain = 1.0

  class << self
    attr_reader :played # files started (test logs)
  end

  # scan audio/<set>/ once: single sounds by their leading hex number, and the music manifest
  def self.scan
    @index = {}
    @tracks = {}
    @variants = {}
    SETS.each do |set|
      @index[set] = {}
      (DR.list_files("#{ROOT}/#{set}") || []).each do |f|
        next unless EXT.any? { |e| f.downcase.end_with?(e) }
        num = ''
        f.each_char { |c| break unless '0123456789abcdefABCDEF'.include?(c) && num.size < 2; num << c } # (mruby: no Regexp)
        @index[set][num.to_i(16)] = "#{ROOT}/#{set}/#{f}" unless num.empty?
      end
      @tracks[set] = manifest(set)
      @variants[set] = {}
      VARIANT.each do |k, dir|
        names = {}
        (DR.list_files("#{ROOT}/#{set}/#{dir}") || []).each { |f| names[f] = true }
        @variants[set][k] = names
      end
    end
  end

  # music/tracks.txt -> { cmd => [[path, samples or nil, looping], ...] }
  def self.manifest(set)
    dir = "#{ROOT}/#{set}/music"
    raw = DR.read_file("#{dir}/tracks.txt")
    return {} unless raw
    lengths = {}
    (DR.read_file("#{dir}/lengths.txt") || '').each_line do |l|
      k, v = l.strip.split(' = ', 2)
      lengths[k] = v.to_i if k && v
    end
    out = {}
    raw.each_line do |l|
      l = l.strip
      next if l.empty? || l.start_with?('#')
      cmd, list = l.split(' = ', 2)
      next unless list
      steps = []
      list.split(' > ').each do |name|
        name = name.strip
        if name.end_with?('*') # the loop part alone, looped (a BGM restart when the rip has intro + theme in one track)
          steps << ["#{dir}/#{name.chomp('*')} loop.ogg", nil, true]
        elsif lengths["#{name} intro"]
          steps << ["#{dir}/#{name} intro.ogg", lengths["#{name} intro"], false]
          steps << ["#{dir}/#{name} loop.ogg", nil, true]
        else
          steps << ["#{dir}/#{name}.ogg", lengths[name], false]
        end
      end
      out[cmd.to_i(16)] = steps
    end
    out
  end

  def self.path(cmd, music_set)
    scan unless @index
    set = music_set.to_s
    (@index[set] && @index[set][cmd]) || @index['arcade'][cmd]
  end

  def self.music_steps(cmd, music_set)
    scan unless @tracks
    set = music_set.to_s
    (@tracks[set] && @tracks[set][cmd]) || @tracks['arcade'][cmd]
  end

  # once per frame, after the tasks ran: play this frame's commands
  def self.update(args, w, music_set)
    w[:sounds].each do |cmd|
      case cmd
      when 0 then stop_all(args)
      when 0xee
        stop_all(args)
        @muted = true
      when 0xef then @muted = false
      when CANCEL_LOOP then args.audio.delete(:"sfx_#{LOOP_SFX}")
      when STOP_MUSIC_ARCADE
        if music_set.to_s == 'arcade' # the arcade board stops its music (MAME: silent within 0.5 s); X68000: a PCM beep
          args.audio.delete(:music)
          args.audio.delete(:jingle)
          @music = nil
          @overlay = nil
        elsif !@muted && !w[:muted] && (file = path(cmd, music_set))
          start(args, :"sfx_#{cmd}", file, false)
        end
      else
        next if @muted || w[:muted] || cmd >= 0x40
        # PCB (user report): a Salamander's wind-up ($1c) is not heard once Ptolemy is dying, though both versions' code
        # keep sending it until the director stops every task ($423c). Probably the sound board's effect priorities
        # (snd.22 / snd.23 not analysed yet); until then this one case is filtered here.
        next if cmd == 0x1c && w[:end_code] != 0
        board = music_set.to_s == 'arcade'
        if board && (c = CUT[cmd]) && args.audio[:"sfx_#{c}"]
          args.audio.delete(:"sfx_#{c}")
          next
        end
        if board && STOPS_MUSIC.include?(cmd)
          args.audio.delete(:music)
          @music = nil
        end
        steps = FM.include?(cmd) && music_steps(cmd, music_set)
        if steps && OVERLAY[cmd] && @music
          start(args, :jingle, steps[0][0], false)
          @overlay = OVERLAY[cmd]
          @jingle = steps[0][0]
          @jingle_cmd = cmd
          @jingle_frames = 0
          args.audio[:music][:gain] = 0.0 if args.audio[:music]
        elsif steps
          start_music(args, steps, cmd)
          # the arcade board's own busy time for a one-shot jingle (BOARD_BUSY), not the recording's length
          @music[:left] = BOARD_BUSY[cmd] if music_set.to_s == 'arcade' && BOARD_BUSY[cmd] && steps.size == 1 && !steps[0][2]
        elsif (file = path(cmd, music_set)) && FM.include?(cmd) # a music command given as a single file: played once
          n = file.start_with?("#{ROOT}/arcade/") && BOARD_BUSY[cmd]
          start_music(args, [[file, n && n * SAMPLES_PER_FRAME, false]], cmd)
        elsif file
          start(args, :"sfx_#{cmd}", file, cmd == LOOP_SFX)
        elsif FM.include?(cmd) # no file yet: the music channel still switches (to silence), as MDRV would
          args.audio.delete(:music)
          @music = nil
        end
      end
    end
  end

  # titles for commands the arcade OST has no track for (user): $14 the moon / boot jingle, $15 credit / morning,
  # $0f Ptolemy eaten by the Worm or shrunk by a Wizard
  TITLES = { 0x14 => 'Wake Up / Moon Out', 0x15 => 'Credit / Morning', 0x0f => 'Worm & Shrink Death' }.freeze
  SET_NAMES = { 'arcade' => 'ARCADE PCB', 'original' => 'X68000 ORIGINAL', 'arrange' => 'X68000 ARRANGE' }.freeze

  # the music widget: { name:, set:, frames: } of the track heard now (a jingle over the BGM while it plays), or nil.
  # Names are the arcade PCB recording's official titles (user) for every set: an X68000 track is named after the
  # arcade track its command plays (the last one: $07 = Stage Start > First Half BGM -> the BGM, as the X68000's
  # Main Theme 1 has no separate fanfare file). $0f / $14 / $15 are not on the OST: TITLES (user).
  def self.now_playing
    m = @music
    file = @overlay ? @jingle : m && m[:steps][m[:i]][0]
    return nil unless file
    parts = file.split('/')
    cmd = @overlay ? @jingle_cmd : m[:cmd]
    scan unless @tracks
    arc = parts[1] != 'arcade' && cmd && @tracks['arcade'] && @tracks['arcade'][cmd]
    name = TITLES[cmd] || track_name((arc ? arc[-1][0] : file).split('/')[-1])
    { name: name, set: SET_NAMES[parts[1]] || parts[1].to_s.upcase, frames: @overlay ? @jingle_frames : m[:frames] }
  end

  # "03 First Half BGM (Round 1-49) intro.ogg" -> "First Half BGM (Round 1-49)" (no Regexp in DragonRuby's mruby)
  def self.track_name(base)
    n = base.include?('.') ? base[0, base.rindex('.')] : base
    [' intro', ' loop'].each { |suf| n = n[0, n.size - suf.size] if n.end_with?(suf) }
    words = n.split(' ')
    words.shift if words.size > 1 && words[0].each_char.all? { |c| c >= '0' && c <= '9' }
    words.join(' ').sub(' (Arrange)', '')
  end

  # every frame (not while paused): the music sequence moves on when a part ends
  def self.tick(args)
    @music[:frames] += 1 if @music
    @jingle_frames += 1 if @overlay
    if @overlay && (@overlay -= 1) <= 0 # the music underneath is heard again
      @overlay = nil
      args.audio[:music][:gain] = music_gain if args.audio[:music]
    end
    m = @music
    return unless m && m[:left]
    m[:left] -= 1
    return if m[:left] > 0
    m[:i] += 1
    step = m[:steps][m[:i]]
    return @music = nil unless step
    m[:frames] = 0 if track_name(step[0].split('/')[-1]) != track_name(m[:steps][m[:i] - 1][0].split('/')[-1]) # a new track
    start(args, :music, step[0], step[2])
    m[:left] = step[1] && step[1].idiv(SAMPLES_PER_FRAME)
  end

  # GAME OPTIONS volume changed: apply to what is playing
  def self.volumes(args, music, sfx)
    self.music_gain = music / 10.0
    self.sfx_gain = sfx / 10.0
    args.audio.each do |k, a|
      a[:gain] = k == :music || k == :jingle ? (k == :music && @overlay ? 0.0 : music_gain) : sfx_gain
    end
  end

  def self.start_music(args, steps, cmd = nil)
    first = steps[0]
    start(args, :music, first[0], first[2])
    @music = { steps: steps, i: 0, left: first[1] && first[1].idiv(SAMPLES_PER_FRAME), frames: 0, cmd: cmd }
  end

  # the SFX FILTER variant of a file, when that folder has one
  def self.variant(file)
    dir = VARIANT[filter]
    return file unless dir
    scan unless @variants
    parts = file.split('/') # audio / <set> / [music /] name
    v = @variants[parts[1]]
    v && v[filter][parts[-1]] ? "#{ROOT}/#{parts[1]}/#{dir}/#{parts[-1]}" : file
  end

  def self.start(args, key, file, looping)
    file = variant(file)
    gain = key == :music || key == :jingle ? music_gain : sfx_gain
    gain = 0.0 if key == :music && @overlay
    args.audio[key] = { input: file, gain: gain, looping: looping }
    @played ||= []
    @played << file if @played.size < 200
  end

  # $56c (MDRV query $fd): music still playing - a jingle until its end, a looping song always. The tasks that wait for a
  # jingle (death $418e, moon $7260 / $734e) read it as w[:audio_busy]. No file for the command = nothing to wait for.
  def self.busy?(args)
    m = @music
    return false unless m
    return true if m[:steps][m[:i]][2] # looping
    return m[:left] > 0 if m[:left]
    !args.audio[:music].nil? # length unknown: until DragonRuby drops the finished sound
  end

  # the pause menu: everything holds where it is
  def self.pause(args, on)
    args.audio.each_value { |a| a[:paused] = on }
  end

  # the music playing now, for rewind (nil: none). Past its first step, "the start jingle, then the round music" ($07 /
  # $30) is the same music as the round music alone ($09 / $31), so a rewind does not replay the jingle.
  SAME_MUSIC = { 0x07 => 0x09, 0x30 => 0x31 }.freeze

  def self.music_cmd
    return nil unless @music
    c = @music[:cmd]
    @music[:i] > 0 && SAME_MUSIC[c] ? SAME_MUSIC[c] : c
  end

  def self.stop_music(args)
    args.audio.delete(:music)
    args.audio.delete(:jingle)
    @music = nil
    @overlay = nil
  end

  def self.stop_all(args)
    args.audio.keys.each { |k| args.audio.delete(k) }
    @music = nil
    @overlay = nil
  end
end
