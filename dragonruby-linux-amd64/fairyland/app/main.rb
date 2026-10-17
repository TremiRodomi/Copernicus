# Copernicus - native port of The Fairyland Story (runs from the arcade ROMs or the X68000 disk; Ptolemy walks/jumps/falls with the original timing).
# Loads the player's own game files from data/, builds the round with the original round-build logic, runs the task scheduler.
# Keys: arrows = move, X / Space = jump, F2 = toggle short-hop QOL, PageUp/PageDown = previous/next round (Shift: 10), Tab = toggle enemy preview,
# F4 = NO HIT (the original's debug switch, $578 bit 6), F5 = behaviour ARCADE / X68000 where the versions differ.
# Boots into the title / attract mode; Enter inserts a credit = the coin-up menu (tasks/menu.rb; settings.txt keeps its
# choices). --round N skips the attract.
# In a game: Esc / P = pause menu (game/pause.rb). F12 = dev info in the right border; widgets are a GAME OPTIONS choice.
# Dev: `./dragonruby fairyland --shot 15` saves shot_15.png and quits; `--script "L30 J R20"` replays inputs, writes script_log.txt.
require 'app/fs/lzss.rb'
require 'app/fs/disk.rb'
require 'app/fs/tables.rb'
require 'app/fs/game_data.rb'
require 'app/gfx/palette.rb'
require 'app/gfx/screen.rb'
require 'app/gfx/sprites.rb'
require 'app/gfx/widgets.rb'
require 'app/gfx/display.rb'
require 'app/game/round_builder.rb'
require 'app/game/scheduler.rb'
require 'app/game/world.rb'
require 'app/game/build_times.rb'
require 'app/game/rewind.rb'
require 'app/game/shadow.rb'
require 'app/game/tasks/player.rb'
require 'app/game/tasks/enemy.rb'
require 'app/game/tasks/attacks.rb'
require 'app/game/tasks/director.rb'
require 'app/game/score.rb'
require 'app/game/tasks/objects.rb'
require 'app/game/tasks/effects.rb'
require 'app/game/tasks/spell.rb'
require 'app/game/tasks/cakes.rb'
require 'app/game/text.rb'
require 'app/game/tasks/round_flow.rb'
require 'app/game/tasks/moon.rb'
require 'app/game/tasks/items.rb'
require 'app/game/tasks/horned.rb'
require 'app/game/tasks/worm.rb'
require 'app/game/tasks/doors.rb'
require 'app/game/tasks/dracolisk.rb'
require 'app/game/tasks/ending.rb'
require 'app/game/tasks/intermission.rb'
require 'app/game/save.rb'
require 'app/game/tasks/gameover.rb'
require 'app/game/tasks/attract.rb'
require 'app/game/controls.rb'
require 'app/game/settings.rb'
require 'app/game/tasks/menu.rb'
require 'app/game/pause.rb'
require 'app/audio/audio.rb'

# The frame is composed at native resolution in a 256x256 render target (:frame, game line 0 at the top), then the visible
# area - lines 16-239, 224 lines, as on the arcade monitor and the X68000 - is shown at an integer scale with borders.
SCALE = 3
VIS_TOP = 16
VIS_LINES = 224
VIEW_X = (1280 - 256 * SCALE).idiv(2)
VIEW_Y = (720 - VIS_LINES * SCALE).idiv(2)

# Release builds (dragonruby-publish: DR.production?) keep only the player-facing command-line flag, --source x68k
# (data/README.txt); every dev flag below (--round, --script, --objlog, ...) is ignored there.
def cli_args
  a = DR.cli_arguments
  DR.production? ? a.select { |k, _| k == :source } : a
end

# dev: --dump_meta EB composes metasprite chain EB (:meta_b) at 1x -> meta_dump.txt ("w h", then rows of ABGR hex,
# 0 = transparent) and quits. Used for the game icon (Ptolemy's cake, $eb; tools: make_icon.py).
def dump_meta(gd, idx)
  pals = Palette.sprite_blocks(gd)
  parts = []
  8.times do
    a = gd.a(:meta_b) + 4 * idx
    bank, pal, hflip, vflip = SpriteCache.decode_hi(gd.byte(a + 1))
    parts << [((~0x80) + gd.byte(a)) & 0xff, bank, gd.byte(a + 2), pal, hflip, vflip]
    idx = gd.byte(a + 3)
    break if idx == 0
  end
  top = parts.map(&:first).min
  h = parts.map(&:first).max + 16 - top
  img = Array.new(16 * h, 0)
  parts.each do |py, bank, code, pal, hflip, vflip|
    base = (bank * 256 + code) * 128
    16.times do |y|
      16.times do |x|
        b = gd.spchr[base + ((x >> 3) * 2 + (y >> 3)) * 32 + (y & 7) * 4 + ((x & 7) >> 1)]
        v = x.odd? ? (b & 15) : (b >> 4)
        next if v == 0
        dx = hflip ? 15 - x : x
        dy = (vflip ? 15 - y : y) + py - top
        img[dy * 16 + dx] = pals[pal][v]
      end
    end
  end
  DR.write_file('meta_dump.txt', "16 #{h}\n" + img.each_slice(16).map { |r| r.map { |v| v.to_s(16) }.join(' ') }.join("\n") + "\n")
end

def boot(args)
  s = args.state
  cli0 = cli_args
  s.gd = GameData.load(prefer: cli0[:source] == 'x68k' ? :x68000 : nil) # --source x68k: use the X68000 disk when both are present
  World.gd = s.gd
  s.sprites = SpriteCache.new(args, s.gd)
  if cli0[:dump_meta] # dev: the icon's sprite (see dump_meta)
    dump_meta(s.gd, cli0[:dump_meta].to_i(16))
    $gtk.request_quit
    return
  end
  s.builder = RoundBuilder.new(s.gd)
  cli = cli_args
  s.shot = cli[:shot] && cli[:shot].to_i
  # dev: --keys "100:coin,130:down,140:ok" presses coin / up / down / left / right / ok / back on those ticks (one frame)
  s.fake_keys = {}
  (cli[:keys] || '').split(',').each { |e| k, v = e.split(':'); (s.fake_keys[k.to_i] ||= []) << v.to_sym }
  s.objlog = cli[:objlog] && { n: cli[:objlog].to_i, lines: [] } # dev: --objlog N = player + object slots per tick -> objlog.txt (MAME diff)
  s.tasklog = cli[:tasklog] && [] # dev: --tasklog 1 (with --objlog): the task slots each row -> tasklog.txt (play.lua PLAY_TASKS)
  # dev: --item_test N,ROW (with --objlog): at that log row the item spot moves under Ptolemy, the walk counter is set to
  # 798 and the item roll is forced to item N (0-17) - mame_check/play.lua PLAY_ITEM does the same on the arcade
  s.item_test = cli[:item_test] && cli[:item_test].split(',').map(&:to_i)
  s.rewind_dev = cli[:rewind] && cli[:rewind].split('-').map(&:to_i) # dev: --rewind T0-T1 holds REWIND over those ticks
  s.sprlog = cli[:sprlog] && [] # dev: --sprlog 1 (with --objlog): sprite slots $4c-$58 in the arcade's bytes -> sprlog.txt
  s.shots = cli[:shots] && cli[:shots].split(',').map(&:to_i) # dev: --shots 100,400 saves shot_t100.png ... then quits
  # dev: --script_file F reads the script from fairyland/F (DragonRuby drops a long --script argument, ~900+ characters,
  # and every argument after it)
  src = cli[:script_file] ? DR.read_file(cli[:script_file]) : cli[:script]
  s.script = src && parse_script(src.strip)
  s.moon_override = cli[:moon] && cli[:moon].to_i
  s.soak = cli[:soak] && cli[:soak].to_i # dev: --soak N moves to the next round every N ticks (memory / stutter checks)
  # dev: --winseq "120:w1080,240:fs,360:s1920x1019" switches window size (preset, fs, or any size) on those ticks;
  # grid scales + placement -> winseq.txt, shot_w<tick + 40>.png (DragonRuby 7.23 segfaults now and then on a screenshot
  # taken after a resize - a dev-only engine bug, nothing to do with the port)
  s.winseq = cli[:winseq] && cli[:winseq].split(',').map { |e| t, v = e.split(':'); [t.to_i, v.to_sym] }.to_h
  # dev: --sound "120:0f,300:14" sends those sound commands (hex) on those round frames (music widget / audio checks)
  s.dev_sounds = cli[:sound] && cli[:sound].split(',').map { |e| f, c = e.split(':'); [f.to_i, [c.to_i(16)]] }.to_h
  s.inject = cli[:inject] # dev: "slot:state:x:y,..." overrides object slots at round start (e.g. a cake in mid-air)
  s.show_enemies = false
  # settings.txt (the menu's choices = the player's preferences), then the command line on top for dev runs
  s.prefs = Settings.load
  (cli[:gfx] || '').split(',').each do |kv| # dev: --gfx "aspect=crt,scanlines=6,mask=grille" (this run only, not saved)
    k, v = kv.split('=', 2)
    c = Settings::CHOICES[k.to_sym] if k
    next unless c && v
    s.prefs[k.to_sym] = c == :files ? v : c.find { |x| x.to_s == v }
  end
  Display.apply_window(s.prefs) if s.prefs[:fullscreen] || s.prefs[:window] != :w720 # GRAPHICS: window size / fullscreen
  s.prefs[:widgets] = true if cli[:widgets] # dev: --widgets 1
  Audio.volumes(args, s.prefs[:music_volume], s.prefs[:sfx_volume])
  Audio.filter = s.prefs[:sfx_filter]
  s.settings = s.prefs.dup
  s.settings[:short_hop] = cli[:short_hop] != '0' if cli[:short_hop] # QOL options (all off = original behaviour); --short_hop 0 = off
  s.settings[:lives] = cli[:lives].to_i if cli[:lives]
  s.settings[:behaviour] = :x68000 if cli[:x68k] # where the two versions differ, play like the arcade or the X68000
  s.settings[:colours] = :pcb if cli[:colours] == 'pcb'
  s.settings[:music] = cli[:music].to_sym if %w[arcade original arrange].include?(cli[:music]) # dev: --music original
  Audio.warm(args, s.settings[:music])
  s.settings.merge!(no_hit: !cli[:no_hit].nil?,
                 pos: cli[:pos] && cli[:pos].split(',').map { |v| v.to_i(16) }, # dev: --pos e0,aa
                 drac_dead: !cli[:drac_dead].nil?,
                 freeze: cli[:freeze] && cli[:freeze].split(',').map { |v| v.to_i(16) }, # dev: --freeze 00,1d (enemy types)
                 hurry: cli[:hurry] && cli[:hurry].to_i(16), # dev: --hurry 44 (hex)
                 force_item: cli[:item] && cli[:item].to_i, # dev: --item N (0-17) appears at Ptolemy's start spot at once
                 mode: cli[:mode] == 'casual' ? :casual : :arcade) # ARCADE: high scores + progress saved; CASUAL: progress only (user, pass 52)
  Palette.profile = s.settings[:colours] # --colours pcb
  s.gd.behaviour = s.settings[:behaviour] # picks the arcade or X68000 copy of the tables that differ (Tables::VARIANTS)
  s.save = Save.load(s.gd)
  s.demo_k = 0 # $6b9: the last demo shown
  s.round = 1
  new_game(args)
  s.game[:score] = 1309 # power-on: 1UP shows 13,090 (arcade $01d7 `ld hl,$0913 / ld ($e77f),hl`, X68000 $1df4)
  s.game[:score] = cli[:start_score].to_i if cli[:start_score] # dev: --start_score N
  s.game[:moon] = s.moon_override if s.moon_override # dev: --moon N ticks (this game only)
  if cli[:round] || s.shot || s.script || cli[:inject] || cli[:pos] || s.soak # dev flags go straight to a round
    Save.readonly = true
    start_round(args, (cli[:round] && cli[:round].to_i) || s.shot || 1)
  elsif s.prefs[:boot_screen]
    start_boot(args)
  else
    start_title(args)
  end
rescue => e
  s.error = "#{e.class}: #{e.message} #{e.backtrace&.first}"
  s.error_lines = e.lines + ['', 'See data/README.txt - Esc quits.'] if e.is_a?(GameData::Missing)
  DR.write_file('error.txt', s.error + "\n")
  $gtk.request_quit if cli_args[:shot] || cli_args[:script] # test modes must not hang on a boot error
end

# demo: the attract demo's input script address (task 1e plays it; no intro)
def start_round(args, n, keep_exp: false, carry: nil, demo: nil, build: false)
  s = args.state
  s.attract = !demo.nil?
  s.menu = false
  s.round = n
  s.builder.build(n)
  w = s.world = World.new_round(s.gd, s.builder, n, s.game)
  w[:opts] = s.settings
  w[:round_world] = true # a playable round (the pause menu's LOSE A LIFE)
  w[:no_hit] = s.settings[:no_hit] && !DR.production? # (F4, dev only)
  w[:mode593] = s.builder.theme
  w[:player].merge!(carry) if carry # a round clear keeps a Wizard's shrink
  w[:wizard_id] = 0xff if w[:player][:char] == 0x1c # $2530: Obj.load hands the spell to this round's Wizard
  Scheduler.spawn(w, 0x20) if w[:door_pair] # $146c: the round builder starts the teleport doors
  if demo # $240a: the demo loads its enemies ($251c) 2 ticks after the build, with Ptolemy's start (DemoStartTask)
    w[:demo_enemies] = s.builder.enemies.map(&:dup)
  elsif n <= 100
    Obj.load(w, s.builder)
  else # $2548: round 101 = the Dracolisk (one enemy)
    w[:enemies_left] = 1
    Scheduler.spawn(w, 0x21)
  end
  # $1fd8: every new life (and a new game) puts EXP back to the round number - 1 (the arcade notes' "EXP reset on death");
  # a round clear ($200e) keeps it
  # (the moon countdown is NOT reset by a new life: $1fd2 = $78 belongs to the new-game set-up $1f9c, also run by a
  # continue - $1f86; a death re-enters at $1fd8 / arcade $0321. World.new_game starts it at $78)
  unless keep_exp
    s.game[:exp] = n - 1
    s.game[:streak] = 0 # $1ffa
    s.game[:exp_next] = 0x1d
  end
  if demo # the demo loop ($248c) never runs the HUD ($7b8): only the title's top line stays
    w[:hud_off] = true
    Hud.top(w)
  else
    Hud.round(w, n)
    Hud.update(w)
  end
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
  w[:bg_dirty].clear
  inject_objects(w, s.inject) if s.inject
  if demo # $23d6: EXP 0, the demo's inputs; attract mode is silent
    s.game[:exp] = 0
    w[:demo_script] = demo
    w[:muted] = true
    Scheduler.spawn(w, 0x48)
  elsif build # the round is built on screen first ($1114 / arcade $0d41): the measured build time, then the intro
    black, hud = BuildTimes.start(World.x68k?(w), n)
    w[:blackout] = :all
    Scheduler.spawn(w, 0x4e, black: black, hud: hud)
  else
    Scheduler.spawn(w, 0x40) # $2612 intro, which then starts the round's tasks
  end
end

# --- Attract mode (tasks/attract.rb): title -> intermission $e -> demo -> BEST 5 -> title ---

# power-on: the boot jingle on a blue screen (MAME cold boot: solid RGB 0,0,170 = blue level 10), then the title.
# X68000 behaviour with the disk in data/ (user): the "Now Loading..." picture instead (FLS_TTL.DAT), held a moment for
# the loading, then the same jingle over it - FS.X leaves the picture's screen mode only after the jingle ($1e22-$1e4c).
# No credit is taken until the title (user: the arcade ignores the coin while it boots).
def start_boot(args)
  s = args.state
  w = scene_world(args)
  w[:booting] = true
  s.attract = true
  if s.prefs[:behaviour] == :x68000 && Display.splash(s.gd)
    w[:boot_splash] = true
    Scheduler.spawn(w, 0x4c, splash: true)
  else
    w[:boot_blue] = true
    Scheduler.spawn(w, 0x4c)
  end
end

def start_title(args)
  s = args.state
  s.menu = false
  Audio.stop_all(args) # the attract is silent ($ee)
  scene_log(args, 'start_title')
  w = scene_world(args)
  s.attract = true
  w[:muted] = true
  Scheduler.spawn(w, 0x46)
end

# $27c4: the intermission picture $e with INSERT COIN(S), Ptolemy and Rodomy fly across (task 25)
def start_attract_inter(args)
  s = args.state
  scene_log(args, 'start_attract_inter')
  s.builder.build_intermission(14, message: false)
  w = s.world = World.new_round(s.gd, s.builder, s.round, s.game)
  s.attract = true
  w[:opts] = s.settings
  w[:muted] = true
  w[:inter_speed] = 1
  Text.print(w, 0xc5ad, 0x39, World.x68k?(w) ? 'INSERT COIN<S>' : 'INSERT  COIN<S>')
  w[:hud_off] = true
  Hud.top(w)
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
  w[:bg_dirty].clear
  Scheduler.spawn(w, 0x25) # (the attract timing is checked against MAME as it is: no build blackout here)
end

# $23d6: the next of the three demos; a fresh 3-life game state that keeps the shown scores
def start_demo(args)
  s = args.state
  scene_log(args, 'start_demo')
  s.demo_k = (s.demo_k + 1) % 3
  round0, script = s.gd.demo(s.demo_k)
  score = s.game[:score]
  hi = s.game[:hiscore]
  s.game = World.new_game(3)
  s.game[:score] = score
  s.game[:hiscore] = hi
  start_round(args, round0 + 1, demo: script)
end

def start_best5(args)
  scene_log(args, 'start_best5')
  w = scene_world(args)
  args.state.attract = true
  w[:muted] = true
  Scheduler.spawn(w, 0x4a)
end

# dev (--shots runs): the tick each attract scene starts, in scenes.txt
def scene_log(args, what)
  DR.append_file('scenes.txt', "#{Kernel.tick_count} #{what}\n") if args.state.shots
end

# Pause > QUIT TO MENU: the round reached is kept for CASUAL's ROUND SELECT (as at a game over), then the coin-up menu
def quit_to_menu(args)
  s = args.state
  if s.round && s.round <= 101
    s.save[:last_round] = s.round - 1
    s.save[:best_round] = [s.save[:best_round], s.save[:last_round]].max
    Save.write(s.save)
  end
  start_menu(args, coin: false) # (no coin jingle: no credit was inserted)
end

# The menu's START GAME (round: CASUAL's ROUND SELECT, else 1). ARCADE = the arcade's factory DIP settings (3 lives,
# extends 30,000 / every 100,000) and no QOL; CASUAL takes the player's lives and QOL choices.
def start_game(args, round = 1, mode = :arcade)
  s = args.state
  Rewind.clear(s)
  s.menu = false
  pr = s.prefs
  s.settings[:mode] = mode
  s.settings[:behaviour] = pr[:behaviour]
  s.gd.behaviour = pr[:behaviour]
  if mode == :arcade
    s.settings.merge!(lives: 3, short_hop: false)
  else
    s.settings.merge!(lives: pr[:lives], short_hop: pr[:short_hop])
  end
  new_game(args)
  start_round(args, round, build: true)
end

def start_menu(args, coin: true)
  s = args.state
  scene_log(args, 'start_menu')
  Audio.stop_all(args)
  w = scene_world(args)
  w[:opts] = s.prefs # the menu edits the preferences
  s.attract = false
  s.menu = true
  Scheduler.spawn(w, 0x4b, coin: coin)
end

# held menu bits: arrows / d-pad, Enter / the jump and spell bindings / pad south = OK, Esc / Backspace / pad east =
# back (game/controls.rb)
def read_menu_input(args)
  Controls.menu_input(args, args.state.prefs)
end

# a menu change that shows at once: behaviour (tables, colour scale) and the colour profile
def apply_settings(args)
  s = args.state
  Display.apply_window(s.prefs) if %i[fullscreen window].include?(s.world[:settings_changed])
  s.world[:settings_changed] = nil
  %i[behaviour colours music widgets music_volume sfx_volume sfx_filter].each { |k| s.settings[k] = s.prefs[k] }
  Audio.volumes(args, s.prefs[:music_volume], s.prefs[:sfx_volume])
  Audio.filter = s.prefs[:sfx_filter]
  Audio.warm(args, s.settings[:music])
  s.gd.behaviour = s.settings[:behaviour]
  Palette.profile = s.settings[:colours]
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, s.world[:bg][:tiles], s.world[:bg][:attrs])
  s.world[:bg_dirty].clear
  s.world[:bg_pal_shown] = false
end

def new_game(args)
  s = args.state
  s.game = World.new_game(s.settings[:lives])
  s.game[:hiscore] = s.save[:table][0][0] # the best-5 table's top
end

# lives ran out: "PLAYER<1>GAME OVER" over the current screen (after the ending: silent)
def game_over(args, silent: false)
  w = args.state.world
  w[:end_code] = 0
  Scheduler.kill_others(w)
  Scheduler.spawn(w, 0x43, silent: silent)
end

# a cleared screen (palette set 4) for the name entry / continue scenes
def scene_world(args)
  s = args.state
  s.builder.build_blank
  w = s.world = World.new_round(s.gd, s.builder, s.round, s.game)
  w[:opts] = s.settings
  w[:save] = s.save
  w[:hud_off] = true # the scenes draw the top line themselves ($7b8 is not running)
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
  w[:bg_dirty].clear
  w
end

# $2d84: ARCADE mode only - a score above the 5th gets a name
def after_game_over(args)
  s = args.state
  score = s.game[:score]
  return continue_or_title(args) unless s.settings[:mode] == :arcade && Save.qualifies?(s.save, score)
  w = scene_world(args)
  w[:entry_round] = s.round - 1
  w[:entry_index] = Save.insert(s.save, score, s.round - 1)
  Scheduler.spawn(w, 0x44)
end

# $2cc0: both modes record the progress (user: ARCADE runs open rounds for CASUAL practice); a continue is offered
# from round 8 up to 98 (arcade) / 101 (casual)
def continue_or_title(args)
  s = args.state
  idx = s.round - 1
  s.save[:last_round] = [idx, 0x64].min
  s.save[:best_round] = [s.save[:best_round], s.save[:last_round]].max
  Save.write(s.save)
  limit = s.settings[:mode] == :arcade ? 0x62 : 0x65
  if idx > 6 && idx < limit
    w = scene_world(args)
    Scheduler.spawn(w, 0x45)
  else
    back_to_title(args)
  end
end

# After a game: the attract again with the last score still on 1UP (the original never clears $700 there)
def back_to_title(args)
  s = args.state
  score = s.game[:score]
  new_game(args)
  s.game[:score] = score
  start_title(args)
end

# After a round clear: the queued steps (intermissions, rounds flashed past by a warp), then the next round
def next_scene(args)
  s = args.state
  kind, v = (s.warp_steps ||= []).shift
  return start_intermission(args, v, s.after_inter[2]) if kind == :inter
  if kind == :flash
    first = !s.flashed # the first build after the round clear takes a frame longer on the arcade (MAME)
    s.flashed = true
    return start_flash(args, v, first)
  end
  n, carry, _warp = s.after_inter
  start_round(args, n, keep_exp: true, carry: carry, build: true)
end

# A round passed by a Mystical Feather warp: built and shown briefly (FlashTask), HUD with its number, no tasks.
# The arcade loop ($044c) does not clear the sprites, so the cleared round's enemies stay on screen until an
# intermission clears them (MAME); the X68000 loop clears them ($2198 -> $1a2e).
def start_flash(args, r, first)
  s = args.state
  prev = s.world
  s.round = r
  s.builder.build(r)
  w = s.world = World.new_round(s.gd, s.builder, r, s.game)
  w[:opts] = s.settings
  w[:shadow] = prev[:shadow].map { |e| e && e.dup } unless World.x68k?(w)
  Hud.round(w, r)
  Hud.update(w)
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
  w[:bg_dirty].clear
  black, hud, shown = BuildTimes.flash(World.x68k?(w), r, first)
  w[:blackout] = hud > 0 || black > 0 ? :all : nil # (from this frame on: the task first runs next frame)
  Scheduler.spawn(w, 0x4d, black: black, hud: hud, shown: shown)
end

# $2818 / $1554: the intermission picture, then task 25 (Ptolemy and Rodomy fly to the next castle)
def start_intermission(args, q, warp)
  s = args.state
  s.builder.build_intermission(q)
  w = s.world = World.new_round(s.gd, s.builder, s.round, s.game)
  w[:opts] = s.settings
  w[:inter_speed] = warp ? 8 : 1
  w[:sounds] << 0x0d unless warp # the intermission music
  w[:hud_off] = true # $1554 draws the top line only ($7b8); the main loop's lives ($29f4) does not run while $2818 waits
  Hud.top(w)
  Screen.setup(s.gd, s.builder)
  Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
  w[:bg_dirty].clear
  w[:blackout] = :all # the picture is built first (MAME: arcade 2 frames black, X68000 about 16)
  Scheduler.spawn(w, 0x4e, black: BuildTimes.inter(World.x68k?(w)), hud: 0, next: 0x25)
end

# $20b0 / $21ba: the director has finished the round ending
def round_over(args)
  s = args.state
  g = s.game
  # Every director ending costs a life ($21c0; a round clear takes the $5fd path instead) unless the setting is ENDLESS
  unless g[:endless]
    g[:lives] -= 1
    if g[:lives] <= 0 # $21de: GAME OVER, then name entry / continue (tasks/gameover.rb); the HUD is not redrawn first
      g[:lives] = 0
      game_over(args)
      return
    end
  end
  start_round(args, s.round, build: true) # $1fd8: the round restarts from scratch (enemies back at their start positions)
end

def tick(args)
  s = args.state
  boot(args) if Kernel.tick_count == 0
  Audio.warm_done(args)
  dev_winseq(args) if s.winseq
  args.outputs.background_color = [16, 16, 24]
  if s.error
    if s.error_lines # missing game data: the player's message
      s.error_lines.each_with_index do |l, i|
        args.outputs.labels << { x: 640, y: 420 - 34 * i, text: l, size_px: i == 0 ? 32 : 24, anchor_x: 0.5, anchor_y: 0.5,
                                 r: 255, g: i == 0 ? 210 : 230, b: i == 0 ? 120 : 230 }
      end
      $gtk.request_quit if args.inputs.keyboard.key_down.escape
    else
      args.outputs.labels << { x: 640, y: 380, text: s.error, anchor_x: 0.5, r: 255, g: 200, b: 200 }
    end
    return
  end
  handle_meta_keys(args) unless s.shot || s.script || s.shots || s.pause || DR.production? # (release: no dev keys)
  Pause.open(args) if !s.pause && Pause.allowed?(s) && (Controls.pause?(args, s.prefs) || (s.fake_keys[Kernel.tick_count] || []).include?(:pause))
  if s.pause # everything stands still; only the pause menu runs
    Pause.step(args)
    Screen.flush(args)
    Screen.flush_overlay(args) if s.pause # (closed this frame: the game goes on next frame)
    draw(args)
    dev_shots(args)
    return
  end
  # CASUAL: holding REWIND steps back through the last seconds instead of playing (game/rewind.rb)
  dev_rw = s.rewind_dev && Kernel.tick_count >= s.rewind_dev[0] && Kernel.tick_count <= s.rewind_dev[1]
  if Rewind.step(args, Controls.rewind?(args, s.prefs) || dev_rw)
    Screen.flush(args)
    draw(args)
    dev_shots(args)
    return
  end
  w = s.world
  fake = s.fake_keys[Kernel.tick_count] || []
  if s.attract && !s.script && !w[:booting] && (Controls.coin?(args, s.prefs) || fake.include?(:coin)) # a credit: the coin-up menu
    start_menu(args)
    w = s.world
  end
  if s.menu && w[:capture] # CONTROLS: the next key / button pressed becomes the binding; the menu sees nothing meanwhile
    w[:captured] = Controls.capture(args, w[:capture])
    w[:menu_in] = 0
  elsif s.menu
    w[:menu_in] = read_menu_input(args)
    fake.each { |k| w[:menu_in] |= MenuTask.const_get(k.to_s.upcase) unless %i[coin pause].include?(k) }
  end
  apply_settings(args) if w[:settings_changed]
  w[:input] = s.script ? script_input(s) : s.attract || s.menu ? 0x0f : read_input(args)
  if w[:give_up] && w[:tasks].any? { |t| t && t[:id] == 0 } # pause > LOSE A LIFE ($2268: $62e = $40, $596 = $ff)
    w[:give_up] = false
    if w[:end_code] == 0
      w[:killer] = 0xff
      w[:end_code] = 0x40
    end
  end
  Audio.update(args, w, s.settings[:music]) # sounds queued while a scene was set up (e.g. the intermission music)
  w[:audio_busy] = Audio.busy?(args)
  w[:sounds].clear
  begin
    # the morning wipe's end (arcade): MAME shows the resumed tasks running in this pass - except the moon task, whose
    # hatching starts the pass after (measured, rounds 1 and 12: the AI's cake rescans and the first hatch; not explained
    # by the code, where both are resumed together - NOTES pass 56)
    if w[:night] == 0xff && w[:wipe] && w[:wipe][:finished] && !World.x68k?(w)
      (NightWipe::FREEZE - [0x14, 0x0f]).each { |id| Scheduler.resume(w, id) }
    end
    Scheduler.run(w, s.gd)
    w[:mode626] ^= 1 if w[:mode626] != 0 # $1d4e: Glass Potion - Ptolemy is hidden on alternate frames (semi-transparent)
    w[:sounds].concat(s.dev_sounds[w[:frame]]) if s.dev_sounds && s.dev_sounds[w[:frame]] # dev: --sound
    Audio.update(args, w, s.settings[:music]) # this frame's sound commands
    Audio.tick(args) # intro -> loop, jingle -> BGM
    w[:sounds_played] = w[:sounds].dup
    w[:sounds].clear
    # X68000: the wipe runs inside the main-loop pass that started it ($209e, after that pass's tasks and $2b2), so the
    # frames it takes after that are not passes: no task run (suspended anyway), no $600 count, no --objlog row
    w[:in_wipe] = !w[:wipe].nil? && World.x68k?(w)
    NightWipe.step(w) if w[:night] != 0 # $209e: main-loop night / morning wipe
    unless w[:in_wipe] || w[:blackout] # (a round being built: $2b2 runs only in the gameplay loop)
      v = (w[:div600] - 1) & 0xff # $2b2: the speed divider counts down after the tasks ran; reload from $5fe when it wraps
      w[:div600] = v >= 0x80 ? w[:speed] : v
    end
    s.game[:rng] = (s.game[:rng] + 1) & 0xffff # $1ee: vblank
  rescue => e
    s.error = "#{e.class}: #{e.message} #{e.backtrace&.first}"
    DR.write_file('error.txt', s.error + "\n")
    $gtk.request_quit if s.script || s.shot
    return
  end
  w[:frame] += 1
  log_objects(s, w) if s.objlog
  log_pending(s, w)
  # $20ba: every enemy gone -> the clear sequence (only once the director runs, i.e. after the intro)
  if w[:end_code] == 0 && !w[:clearing] && !w[:demo_script] && (w[:enemies_left] & 0x7f) == 0 && w[:tasks].any? { |t| t && t[:id] == 0 }
    w[:clearing] = true
    w[:timer_end] ||= w[:t610] # (the HORNED TIMER widget stops here)
    Scheduler.spawn(w, 0x41)
  end
  Score.extend_check(w) unless s.attract || s.menu || w[:hud_off] || w[:input_override] # $2976: gameplay loop only
  s.game[:hiscore] = s.game[:score] if s.game[:score] > s.game[:hiscore]
  Hud.update(w)
  Rewind.record(args)
  if s.menu
    case w[:end_code]
    when :menu_title then start_title(args)
    when :menu_quit then $gtk.request_quit
    when :menu_start
      st = w[:menu_start]
      start_game(args, st[:round], st[:mode])
    end
    w = s.world
  elsif s.attract
    case w[:end_code]
    when :boot_done then start_title(args)
    when :title_done then start_attract_inter(args)
    when :intermission_done # $23a6: 10 ticks more on the picture
      w[:end_code] = 0
      Scheduler.spawn(w, 0x47, frames: 10 * 6, code: :inter_wait_done)
    when :inter_wait_done then start_demo(args)
    when :demo_done then start_best5(args)
    when :best5_done then start_title(args)
    end
    w = s.world
  elsif w[:end_code] == :game_over # after the ending: lives = 0 -> the game-over path past its jingle ($2148 -> $21ea)
    s.round = w[:round]
    s.game[:lives] = 0 # $2142
    game_over(args, silent: true)
  elsif w[:end_code] == :game_over_done
    after_game_over(args)
    w = s.world
  elsif w[:end_code] == :name_done
    continue_or_title(args)
    w = s.world
  elsif w[:end_code] == :continue_yes # $1f86: score, level, steps reset; the same round again
    hi = s.game[:hiscore]
    new_game(args)
    s.game[:hiscore] = hi
    start_round(args, s.round, build: true)
    w = s.world
  elsif w[:end_code] == :continue_no # back to the title
    back_to_title(args)
    w = s.world
  elsif w[:end_code] == 0xff
    round_over(args)
    w = s.world
  elsif w[:end_code] == :clear
    p = w[:player]
    n = (w[:warp] & 0x7f) + 1
    # $2184 (arcade $044c): for every round passed, round + 1 and the intermission check ($2818: after 0-based round 7,
    # 14, ...); then, while rounds remain, that round is built and flashed ($2196-$21b8); the last one starts ($200e)
    s.warp_steps = []
    s.flashed = false
    (1..n).each do |i|
      idx = s.round - 1 + i # the 0-based round after the increment
      s.warp_steps << [:inter, (idx - 7).idiv(7)] if idx >= 7 && (idx - 7) % 7 == 0
      s.warp_steps << [:flash, s.round + i] if i < n
    end
    s.after_inter = [s.round + n, { char: p[:char], speed: p[:speed], step_delay: p[:step_delay] }, w[:warp] != 0]
    next_scene(args)
    w = s.world
  elsif w[:end_code] == :intermission_done || w[:end_code] == :flash_done
    next_scene(args)
    w = s.world
  end
  if w[:bg_pal] && !w[:bg_pal_shown] # the ending's palette set 4
    w[:bg_pal_shown] = true
    Screen.setup(s.gd, s.builder, w[:bg_pal])
    Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
    w[:bg_dirty].clear
  end
  unless Screen.overlay.equal?(w[:overlay]) # the X68000 title's TAITO bitmap appeared / the scene changed
    Screen.overlay = w[:overlay]
    Screen.render(args, :bg, w[:bg][:tiles], w[:bg][:attrs])
    w[:bg_dirty].clear
  end
  unless w[:bg_dirty].empty?
    Screen.redraw(args, :bg, w[:bg_dirty], w[:bg][:tiles], w[:bg][:attrs])
    w[:bg_dirty].clear
  end
  Screen.flush(args)
  draw(args)
  if s.shot
    args.outputs.screenshots << { x: 0, y: 0, w: 1280, h: 720, path: "shot_#{s.round}.png" } if Kernel.tick_count == 2
    $gtk.request_quit if Kernel.tick_count == 4
  end
  script_done(args) if s.script && s.script[:i] >= s.script[:steps].size
  dev_shots(args)
end

def dev_winseq(args)
  s = args.state
  t = Kernel.tick_count
  if (v = s.winseq[t])
    p = s.prefs.merge(fullscreen: v == :fs)
    p[:window] = v unless v == :fs
    if v.to_s.start_with?('s') # s1856x1044: an arbitrary window size
      DR.set_window_fullscreen(false)
      DR.set_window_size(*v.to_s[1..].split('x').map(&:to_i))
    else
      Display.apply_window(p)
    end
  end
  g = args.grid
  if args.events.resize_occurred || (s.winseq.keys.any? { |k| t == k + 30 })
    DR.append_file('winseq.txt', "#{t} resize=#{args.events.resize_occurred} native=#{g.native_scale} render=#{g.render_scale} " \
                   "tex=#{g.texture_scale} px=#{g.w_px}x#{g.h_px} all=#{g.allscreen_w_px}x#{g.allscreen_h_px} pt=#{g.allscreen_w_pt}x#{g.allscreen_h_pt} off=#{g.allscreen_offset_x_px},#{g.allscreen_offset_y_px} hdpi=#{g.high_dpi_scale} " \
                   "place=#{Display.place(args, s.prefs).inspect}\n")
  end
  args.outputs.screenshots << { x: 0, y: 0, w: 1280, h: 720, path: "shot_w#{t}.png" } if s.winseq.keys.any? { |k| t == k + 40 }
  $gtk.request_quit if t > s.winseq.keys.max + 60
end

def dev_shots(args)
  s = args.state
  return unless s.shots
  args.outputs.screenshots << { x: 0, y: 0, w: 1280, h: 720, path: "shot_t#{Kernel.tick_count}.png" } if s.shots.include?(Kernel.tick_count)
  $gtk.request_quit if Kernel.tick_count > s.shots.max + 2
end

# $48ca layout, active low: bit0 spell, bit1 jump, bit2 left (+x), bit3 right (-x)
def read_input(args)
  Controls.game_input(args, args.state.prefs)
end

def handle_meta_keys(args)
  s = args.state
  kb = args.inputs.keyboard
  step = kb.shift ? 10 : 1
  n = s.round
  n -= step if kb.key_down.pageup
  n += step if kb.key_down.pagedown
  n = n.clamp(1, 101) if n != s.round # (only on a key: after the ending s.round is 102 = "ALL", which a clamp on
  # every tick turned into a restart of round 101 - user's report: the ending looped back to the fight)
  s.show_enemies = !s.show_enemies if kb.key_down.tab
  s.dev = !s.dev if kb.key_down.f12
  s.settings[:short_hop] = !s.settings[:short_hop] if kb.key_down.f2
  s.world[:no_hit] = s.settings[:no_hit] = !s.settings[:no_hit] if kb.key_down.f4
  if kb.key_down.f6 # colour profile: standard arcade scale / measured from the user's PCB
    Palette.profile = s.settings[:colours] = Palette.profile == :pcb ? :standard : :pcb
    Screen.setup(s.gd, s.builder)
    Screen.render(args, :bg, s.world[:bg][:tiles], s.world[:bg][:attrs])
    s.world[:bg_pal_shown] = false # a palette patch (title fades, ending) goes back on top
  end
  if kb.key_down.f5
    s.settings[:behaviour] = s.settings[:behaviour] == :arcade ? :x68000 : :arcade
    s.gd.behaviour = s.settings[:behaviour]
    Screen.setup(s.gd, s.builder) # redraw with this behaviour's colour scale
    Screen.render(args, :bg, s.world[:bg][:tiles], s.world[:bg][:attrs])
    s.world[:bg_pal_shown] = false # a palette patch (title fades, ending) goes back on top
  end
  n = n % 101 + 1 if s.soak && Kernel.tick_count % s.soak == 0
  start_round(args, n) if n != s.round
end

def inject_objects(w, spec)
  spec.split(',').each do |e|
    k, st, x, y = e.split(':').map { |v| v.to_i(16) }
    o = w[:obj][k]
    w[:enemies_left] -= 1 if st == 0 && o[Obj::ST] != 0
    o[Obj::ST] = st
    o[Obj::X] = x
    o[Obj::Y] = y
    o[Obj::ANIM] = 0x0c
    o[Obj::JDX] = 0x0a
  end
end

# --objlog: one line per tick in the MAME trace format (arcade $e6a9 x, $e6aa y, $e682 divider, then the 8 slots at $e621)
def log_objects(s, w)
  return if w[:in_wipe] # (not a game pass on the X68000: mame_check logs per pass)
  o = s.objlog
  p = w[:player]
  h = ->(v) { (v.to_i & 0xff).to_s(16).rjust(2, "0") }
  slots = w[:obj].map { |sl| sl.map { |v| h.(v) }.join }
  if (d = w[:drac]) # round 101: the original keeps the Dracolisk in slots 0-1 ($59d-$5b4 = arcade $e621-$e638)
    b = [0, d[:head], d[:body], d[:legs], d[:tail], d[:attr], d[:x], d[:y], d[:cmd], d[:legph], d[:bodyph], d[:landed], 0,
         d[:head_target], d[:head_cur], d[:tx], d[:ty], d[:wait], d[:dmg], d[:b0], d[:b1], 0, 0, 0].map { |v| h.(v) }.join
    slots[0] = b[0, 24]
    slots[1] = b[24, 24]
    # the X68000's fireball lines at $5b7-$5d1 (line k at +8k: flag, x, y, x 8.8, y 8.8; slopes at $5c6 + 8k) -> f=
    fb = Array.new(27, 0)
    d[:lines].each_with_index do |l, k|
      o8 = 8 * k
      fb[o8, 7] = [l[:active], l[:x], l[:y], l[:ax] >> 8, l[:ax], l[:ay] >> 8, l[:ay]]
      fb[15 + o8, 4] = [l[:sx] >> 8, l[:sx], l[:sy] >> 8, l[:sy]]
    end
    fire = " f=#{fb.map { |v| h.(v) }.join}"
  end
  o[:lines] << "#{Kernel.tick_count} #{h.(p[:x])} #{h.(p[:y])} #{h.(w[:div600])} #{slots.join} #{(t1 = w[:tasks].compact.find { |k| k[:id] == 1 }) && t1[:pc]} n=#{w[:night]},#{w[:wipe] && w[:wipe][:r]},#{(t0f = w[:tasks].compact.find { |k| k[:id] == 0x0f }) && t0f[:suspended]} m=#{h.(w[:game][:moon])},#{h.(w[:night])}#{fire}"
  if s.sprlog # (arcade $e04c-$e05b: [~y + dy, code, attr, x + dx]; a cleared entry is 4 zero bytes)
    s.sprlog << "#{o[:lines].size - 1} " + (0x13..0x16).map { |k|
      e = w[:shadow][k]
      e ? [(e[1] - 0x11) & 0xff, (e[2] >> 8) ^ 0xc0, e[2] & 0xff, (-e[0]) & 0xff].map { |v| h.(v) }.join : '00000000'
    }.join
  end
  s.tasklog << "#{o[:lines].size - 1} " + w[:tasks].map { |k| k ? h.(k[:id]) : '--' }.join(' ') if s.tasklog
  if s.item_test && o[:lines].size - 1 == s.item_test[1]
    w[:item_spawn] = [p[:x], p[:y]]
    w[:game][:steps] = 798
    w[:force_item] = s.item_test[0]
  end
  return if o[:lines].size < o[:n]
  DR.write_file('tasklog.txt', s.tasklog.join("\n") + "\n") if s.tasklog
  DR.write_file('sprlog.txt', s.sprlog.join("\n") + "\n") if s.sprlog
  DR.write_file('objlog.txt', o[:lines].join("\n") + "\n")
  s.objlog = nil
  $gtk.request_quit
end

# Events for parts that are not ported yet (unported task spawns, endings): logged once each when scripting
def log_pending(s, w)
  return if w[:pending].empty?
  s.script[:log] << "#{w[:frame]} pending: #{w[:pending].join(' ')}" if s.script
  w[:pending].clear
end

# Test scripts: tokens like L30 (left 30 frames), R12, J (jump 1 frame), JL8 (jump+left 8 frames), Z (spell), W20 (nothing 20 frames)
def parse_script(str)
  steps = []
  str.split(' ').each do |tok|
    letters = tok.delete('0123456789')
    count = tok.delete('ABCDEFGHIJKLMNOPQRSTUVWXYZ') # NB: mruby's delete('A-Z') leaves the Z
    v = 0x0f
    v &= ~4 if letters.include?('L')
    v &= ~8 if letters.include?('R')
    v &= ~2 if letters.include?('J')
    v &= 0x0e if letters.include?("Z")
    (count.empty? ? 1 : count.to_i).times { steps << v }
  end
  { steps: steps, i: 0, log: ["script: #{str.inspect} -> #{steps.size} steps"] }
end

def script_input(s)
  sc = s.script
  v = sc[:steps][sc[:i]] || 0x0f
  p = s.world[:player]
  t = s.world[:tasks].compact.first
  en = s.world[:obj].select { |o| o[Obj::ST] != 0 }.map { |o| "#{o[Obj::ST].to_s(16)}:#{o[Obj::X]},#{o[Obj::Y]}/#{o[Obj::CMD].to_s(16)}" }.join(' ')
  gt = s.world[:tasks].compact.find { |k| k[:id] == 0 }
  sc[:log] << "#{s.world[:frame]} sc=#{s.game[:score]} shot=#{s.world[:shot][:active]}@#{s.world[:shot][:x]} ghost=#{gt && gt[:x]},#{gt && gt[:y]} in=#{v.to_s(16)} x=#{p[:x]} y=#{p[:y]} pc=#{t && t[:pc]} delay=#{t && t[:delay]} ch=#{p[:char]} end=#{s.world[:end_code]} es=#{s.world[:eshots].map { |e| e.join(',') }.join('/')} snd=#{(s.world[:sounds_played] || []).map { |v| v.to_s(16) }.join(',')} g=#{s.game[:exp]}/#{s.game[:level]}/#{s.game[:lives]}/#{s.world[:power].to_s(16)}/#{s.game[:moon]}/#{s.world[:power_timer]} t=#{s.world[:tasks].compact.map { |k| k[:id].to_s(16) + (k[:suspended] ? 's' : '') }.join(',')} | #{en}"
  sc[:i] += 1 unless s.world[:wipe] && World.x68k?(s.world) # X68000 wipe frames are not game passes (mame_check)
  DR.write_file('script_log.txt', sc[:log].join("\n") + "\n") if sc[:i] % 60 == 0 # partial log, in case of a hang
  v
end

def script_done(args)
  s = args.state
  return if s.script[:done]
  s.script[:done] = true
  sh = s.world[:shadow].each_with_index.select { |e, _| e }.map { |e, i| "shadow[#{i}] = #{e.inspect}" }
  played = (Audio.played || []).tally.map { |f, n| "audio: #{f} x#{n}" }
  DR.write_file('script_log.txt', (s.script[:log] + sh + played).join("\n") + "\n")
  args.outputs.screenshots << { x: 0, y: 0, w: 1280, h: 720, path: 'script_end.png' }
  s.quit_at = Kernel.tick_count + 2
end

def draw(args)
  s = args.state
  rb = s.builder
  fr = Display.target(args, :frame, 256, 256) # (sprites below in game pixels; Display.texels converts them)
  sh = s.world[:shake] # Book of Death: the background scrolls 3 px (the tilemap wraps)
  fr.sprites << { x: 0, y: -sh, w: 256, h: 256, path: :bg }
  fr.sprites << { x: 0, y: 256 - sh, w: 256, h: 256, path: :bg } if sh != 0
  bo = s.world[:blackout] # a round being built (start_flash / start_round): the tiles are black; the arcade draws the
  if bo                    # bottom ROUND line (lines 232-239) a few frames before the rest, and its sprites stay
    hgt = bo == :hud_bottom ? 232 : 256
    fr.sprites << { x: 0, y: 256 - hgt, w: 256, h: hgt, path: :pixel, r: 0, g: 0, b: 0 }
  end
  rb.enemies.each { |t, x, y| draw_enemy(args, fr, t, x, y) unless t == 0xff } if s.show_enemies
  draw_shadow(args, fr)
  unless bo
    fr.sprites << { x: 0, y: -sh, w: 256, h: 256, path: :bg_front } # priority cells over the sprites
    fr.sprites << { x: 0, y: 256 - sh, w: 256, h: 256, path: :bg_front } if sh != 0
  end
  fr.sprites << { x: 0, y: 0, w: 256, h: 256, path: :ovl } if s.pause
  if s.world[:boot_blue] # blue level 10 through the palette code (so the PCB colour profile applies)
    c = Palette.abgr(20 << 1 | 1, s.gd.behaviour == :arcade)
    fr.sprites << { x: 0, y: 0, w: 256, h: 256, path: :pixel, r: c & 0xff, g: (c >> 8) & 0xff, b: (c >> 16) & 0xff } # (solids draw under sprites)
  end
  Display.texels(args, fr.sprites)
  Display.draw(args, s.prefs, VIS_TOP) # border, playfield (scaled per GRAPHICS), filters
  Display.draw_splash(args, s.prefs, s.world[:frame]) if s.world[:boot_splash]
  p = s.world[:player]
  g = s.game
  lines = ["ROUND #{s.round}   LIVES #{g[:endless] ? '-' : g[:lives]}", "SCORE #{g[:score]}0  LV #{g[:level]} EXP #{g[:exp]}", format('x %02x  y %02x', p[:x], p[:y]), 'arrows move, X jump, Z spell', 'PgUp/PgDn round', 'Tab static enemy preview',
           "F2 short hop: #{s.settings[:short_hop] ? 'ON' : 'off'}",
           "F4 no hit (debug): #{s.settings[:no_hit] ? 'ON' : 'off'}",
           "F5 behaviour: #{s.settings[:behaviour] == :arcade ? 'ARCADE' : 'X68000'}",
           "F6 colours: #{Palette.profile == :pcb ? 'PCB (measured)' : 'standard'}",
           "data: #{s.gd.version == :arcade ? 'arcade ROMs' : 'X68000 disk'}"]
  # F12: dev info in the right border; widgets (GAME OPTIONS) in the left one during a game
  lines.each_with_index { |l, i| args.outputs.labels << { x: 1272, y: 710 - i * 24, text: l, size_px: 20, alignment_enum: 2, r: 220, g: 220, b: 220 } } if s.dev
  Widgets.frame(args) # from START GAME on, between rounds too (user); a preview on the menu's WIDGETS page
  if s.rewind && s.rewind[:active] # (game/rewind.rb): seconds of history left
    left = (s.rewind[:buf].size * Rewind::EVERY).idiv(60)
    Widgets.banner(args, "<< REWIND  #{left.idiv(60)}:#{(left % 60).to_s.rjust(2, '0')}")
  end
  if s.message && s.message[1] > 0
    args.outputs.labels << { x: 640, y: 400, text: s.message[0], size_px: 48, anchor_x: 0.5, r: 255, g: 255, b: 255 }
    s.message[1] -= 1
  end
  $gtk.request_quit if s.quit_at && Kernel.tick_count >= s.quit_at
end

# Sprite shadow -> frame (render target coordinates: y up, line L = 256 - L). Lower entry numbers have priority, so draw from
# the back. Hardware coords: X reg - 16 = left edge, Y reg = line below the bottom edge.
def draw_shadow(args, fr)
  s = args.state
  sh = s.world[:shadow]
  # $57e priority list (arcade sprite RAM $dc80, X68000 $b158): drawn from the last entry up, so the first ends on top
  order = s.gd.sprite_order(s.world[:prio] || 1)
  wrap = !World.x68k?(s.world)
  glass = s.world[:mode626] & 1 != 0 # $1d4e blanks her two sprites (slots 4 and 8) on these frames
  s.sprites.begin_frame(s.world[:pal_patch])
  @draw_order ||= {}
  (@draw_order[order] ||= order.reverse + (32...128).to_a.reverse).each do |i|
    e = sh[i]
    next unless e
    next if glass && (i == 1 || i == 2)
    x, y, attr = e
    bank = attr & 0x2000 == 0 ? 0 : (attr & 0x1000 == 0 ? 1 : 2)
    path = s.sprites.path(bank, attr & 0xff, (attr >> 8) & 15, true)
    spr = { x: x - 16, y: 256 - y, w: 16, h: 16, path: path,
            flip_horizontally: attr & 0x4000 != 0, flip_vertically: attr & 0x8000 != 0 }
    fr.sprites << spr
    # the 8-bit sprite x wraps, so a part across the left edge also shows at the right edge: arcade hardware (MAME flstory
    # draws sx and sx - 256); the X68000's VBlank copy ($32c) does it in software for the 32 priority-list sprites, a
    # second hardware sprite at X + $100 when X < $10
    fr.sprites << spr.merge(x: x + 240) if x < 16 && (wrap || i < 32)
  end
end

# Static enemy preview (frame 0 of $1ab6) until the enemy tasks are ported
def draw_enemy(args, fr, type, x, y)
  s = args.state
  gd = s.gd
  idx = type
  8.times do
    a = s.gd.a(:meta_b) + 4 * idx
    bank, pal, hflip, vflip = SpriteCache.decode_hi(gd.byte(a + 1))
    px = ((-x) & 0xff) - 16
    py = ((((~y) + gd.byte(a) - (s.world[:flags591] & 2)) & 0xff) + 0x11) - 16
    fr.sprites << { x: px, y: 256 - (py + 16), w: 16, h: 16,
                    path: s.sprites.path(bank, gd.byte(a + 2), pal), flip_horizontally: hflip, flip_vertically: vflip }
    idx = gd.byte(a + 3)
    break if idx == 0
  end
end
