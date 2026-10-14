# Player 1's controls (GAME OPTIONS > CONTROLS; user design): the keyboard and ANY connected pad at once, read into the
# arcade's 2-way lever + 2 buttons (the input byte the game tasks see, active low: 1 spell, 2 jump, 4 left, 8 right)
# and the port's START (user: one button - a coin in the attract, the pause menu in a game). Up / down are not game
# inputs (the cabinet's lever is 2-way).
#   keyboard: LEFT RIGHT JUMP SPELL START, two keys each (settings kb_*)
#   pad: d-pad + left stick move (fixed); JUMP SPELL START, two buttons each (settings pad_*)
# Menus also take arrows / Enter / Esc / Backspace and the pad's d-pad / south (OK) / east (back) whatever the bindings,
# so a bad binding never locks the player out. Names are DragonRuby's (keyboard.key_down_or_held?(name)); an unknown
# one raises there, so settings.txt values are checked against KEYS / BUTTONS.
module Controls
  KB_ACTIONS = %i[kb_left kb_right kb_jump kb_spell kb_start kb_rewind].freeze
  PAD_ACTIONS = %i[pad_jump pad_spell pad_start pad_rewind].freeze
  DEFAULTS = { kb_left: %i[left_arrow], kb_right: %i[right_arrow], kb_jump: %i[x space], kb_spell: %i[z],
               kb_start: %i[enter escape], kb_rewind: %i[r], pad_jump: %i[a], pad_spell: %i[x],
               pad_start: %i[start select], pad_rewind: %i[l1] }.freeze
  # keys a binding can use, in the order a press is named (truthy_keys lists synonyms: left_arrow and left ...)
  KEYS = (%i[left_arrow right_arrow up_arrow down_arrow space enter escape backspace tab delete insert home end
             page_up page_down shift_left shift_right control_left control_right alt_left alt_right] +
          ('a'..'z').map(&:to_sym) +
          %i[zero one two three four five six seven eight nine] +
          (1..12).map { |n| :"f#{n}" } +
          %i[kp_zero kp_one kp_two kp_three kp_four kp_five kp_six kp_seven kp_eight kp_nine kp_period kp_plus
             kp_minus kp_multiply kp_divide kp_enter comma period forward_slash back_slash semicolon
             single_quotation_mark open_square_brace close_square_brace hyphen equal backtick]).freeze
  BUTTONS = %i[a b x y l1 r1 l2 r2 l3 r3 start select].freeze
  # how a binding shows in the menu's font (7 characters at most)
  SHORT = { left_arrow: 'LEFT', right_arrow: 'RIGHT', up_arrow: 'UP', down_arrow: 'DOWN', escape: 'ESC',
            backspace: 'BKSPACE', page_up: 'PGUP', page_down: 'PGDN', shift_left: 'LSHIFT', shift_right: 'RSHIFT',
            control_left: 'LCTRL', control_right: 'RCTRL', alt_left: 'LALT', alt_right: 'RALT', delete: 'DEL',
            insert: 'INS', kp_period: 'KP .', kp_plus: 'KP +', kp_minus: 'KP -', kp_multiply: 'KP *',
            kp_divide: 'KP DIV', kp_enter: 'KPENTER', comma: ',', period: '.', forward_slash: 'SLASH',
            back_slash: 'BSLASH', semicolon: ';', single_quotation_mark: "'", open_square_brace: '[',
            close_square_brace: ']', hyphen: '-', equal: '=', backtick: '`',
            l1: 'LB', r1: 'RB', l2: 'LT', r2: 'RT', l3: 'L3', r3: 'R3', select: 'SELECT', start: 'START',
            zero: '0', one: '1', two: '2', three: '3', four: '4', five: '5', six: '6', seven: '7', eight: '8',
            nine: '9' }.freeze

  def self.name(k)
    return '-' if k.nil?
    s = SHORT[k] || k.to_s.sub('kp_', 'KP ').upcase
    s[0, 7]
  end

  def self.kb_action?(a)
    KB_ACTIONS.include?(a)
  end

  # settings.txt value "x,space" -> [:x, :space] (unknown names dropped; nil = the default)
  def self.parse(action, v)
    allowed = kb_action?(action) ? KEYS : BUTTONS
    list = v.split(',').map { |n| n.strip.to_sym }.select { |n| allowed.include?(n) }.first(2)
    list.empty? && !v.strip.empty? && v.strip != '-' ? nil : list
  end

  # REWIND (CASUAL mode, game/rewind.rb): the keyboard binding or the pad's
  def self.rewind?(args, prefs)
    held?(args, prefs, :kb_rewind) || held?(args, prefs, :pad_rewind)
  end

  def self.pads(args)
    args.inputs.controllers.select { |c| c && c.connected }
  end

  def self.held?(args, prefs, action)
    list = prefs[action] || DEFAULTS[action]
    if kb_action?(action)
      kb = args.inputs.keyboard
      list.any? { |k| kb.key_down_or_held?(k) }
    else
      pads(args).any? { |c| list.any? { |k| c.key_down_or_held?(k) } }
    end
  end

  def self.pressed?(args, prefs, action)
    list = prefs[action] || DEFAULTS[action]
    if kb_action?(action)
      kb = args.inputs.keyboard.key_down
      list.any? { |k| kb.send(k) }
    else
      pads(args).any? { |c| list.any? { |k| c.key_down.send(k) } }
    end
  end

  # the game's input byte (active low): left wins when both directions are held, as before
  def self.game_input(args, prefs)
    pad_l = pads(args).any?(&:left)
    pad_r = pads(args).any?(&:right)
    left = held?(args, prefs, :kb_left) || pad_l
    right = held?(args, prefs, :kb_right) || pad_r
    v = 0x0f
    v &= ~4 if left
    v &= ~8 if right && !left
    v &= ~2 if held?(args, prefs, :kb_jump) || held?(args, prefs, :pad_jump)
    v &= ~1 if held?(args, prefs, :kb_spell) || held?(args, prefs, :pad_spell)
    v
  end

  # Enter always inserts a coin too (the attract has no other use for it); Esc always pauses unless it was made a
  # game key - so neither can be lost by rebinding
  def self.coin?(args, prefs)
    start?(args, prefs) || args.inputs.keyboard.key_down.enter
  end

  def self.pause?(args, prefs)
    game = %i[kb_left kb_right kb_jump kb_spell].any? { |a| (prefs[a] || DEFAULTS[a]).include?(:escape) }
    start?(args, prefs) || (!game && args.inputs.keyboard.key_down.escape)
  end

  def self.start?(args, prefs)
    pressed?(args, prefs, :kb_start) || pressed?(args, prefs, :pad_start)
  end

  # held menu bits (MenuTask::UP ... BACK)
  def self.menu_input(args, prefs)
    kb = args.inputs.keyboard
    ps = pads(args)
    v = 0
    v |= MenuTask::UP if kb.key_down_or_held?(:up_arrow) || ps.any?(&:up)
    v |= MenuTask::DOWN if kb.key_down_or_held?(:down_arrow) || ps.any?(&:down)
    v |= MenuTask::LEFT if kb.key_down_or_held?(:left_arrow) || held?(args, prefs, :kb_left) || ps.any?(&:left)
    v |= MenuTask::RIGHT if kb.key_down_or_held?(:right_arrow) || held?(args, prefs, :kb_right) || ps.any?(&:right)
    v |= MenuTask::OK if kb.enter || held?(args, prefs, :kb_jump) || held?(args, prefs, :kb_spell) ||
                         ps.any? { |c| c.key_down_or_held?(:a) } || held?(args, prefs, :pad_jump)
    v |= MenuTask::BACK if kb.escape || kb.backspace || ps.any? { |c| c.key_down_or_held?(:b) }
    v &= ~MenuTask::BACK if v & MenuTask::OK != 0 # (a button bound to both: OK)
    v
  end

  # the key / button newly pressed this frame for a binding being set (nil: none yet)
  def self.capture(args, action)
    if kb_action?(action)
      kb = args.inputs.keyboard.key_down
      KEYS.find { |k| kb.send(k) }
    else
      pads(args).each do |c|
        b = BUTTONS.find { |k| c.key_down.send(k) }
        return b if b
      end
      nil
    end
  end

  # a new binding in slot 0 / 1; the key leaves the other slot and the device's other actions
  def self.bind(prefs, action, slot, key)
    list = (prefs[action] || DEFAULTS[action]).dup
    list[slot] = key
    list = list.compact.uniq
    (kb_action?(action) ? KB_ACTIONS : PAD_ACTIONS).each do |a|
      prefs[a] = (prefs[a] || DEFAULTS[a]) - [key] unless a == action
    end
    prefs[action] = list
  end

  def self.unbind(prefs, action, slot)
    list = (prefs[action] || DEFAULTS[action]).dup
    list.delete_at(slot)
    prefs[action] = list
  end

  def self.reset(prefs)
    DEFAULTS.each { |k, v| prefs[k] = v.dup }
  end
end
