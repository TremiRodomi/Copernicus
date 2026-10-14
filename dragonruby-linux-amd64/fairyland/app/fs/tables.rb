# Every game-data table the engine reads, by name. The engine never uses a raw address: it asks GameData#a(name), and the
# loaded data source answers with the table's address in its own image.
#
# The table FORMATS are the X68000's (the arcade's are byte-identical for almost everything, NOTES.md pass 19). Where a
# format differs (pointer widths, palettes, graphics) the arcade loader converts into the X68000 layout, so the engine has
# one code path. Arcade address nil = the arcade loader has to build that table.
module Tables
  # name => [X68000 FS.X flat-image address, arcade main-CPU (Z80) address]
  ADDR = {
    # Ptolemy (task 01)
    player_walk: [0xc508, 0x43c6], player_walk_alt: [0xc510, 0x43ce],
    broom_l: [0xc518, 0x43d6], broom_r: [0xc520, 0x43de],
    player_slide_l: [0xc528, 0x44aa], player_slide_r: [0xc535, 0x44b7],
    player_jump_l: [0xc542, 0x46a8], player_jump_r: [0xc58f, 0x46f5],
    # her spell (task 03): [sprite, offset] pairs; +$39 = the shrunk version
    spell_wave_l: [0xc64e, 0x1aa1], spell_wave_r: [0xc6a0, 0x1af3],
    fire_spell_l: [0xc6f0, 0x1b45], fire_spell_r: [0xc6f9, 0x1b4e],
    # director (task 00) endings
    death_float: [0xc4e8, 0x17f2], burnt_death: [0xc4f1, 0x188f], shrink_death: [0xc4fd, 0x18e8],
    # enemy body (tasks 05-0c)
    enemy_walk: [0xc702, 0x22ba], enemy_slide_l: [0xc70a, 0x236a], enemy_slide_r: [0xc717, 0x2377],
    enemy_jump_l: [0xc724, 0x256c], enemy_jump_r: [0xc771, 0x25b9],
    escape: [0xc845, 0x206f], dissolve: [0xc865, 0x20d8], burn: [0xc86b, 0x20de],
    # species attacks ($5b3a) and enemy shots (tasks 12/13)
    wizard_attack_l: [0xc7be, 0x4dff], wizard_attack_r: [0xc7c8, 0x4e09],
    salamander_attack_l: [0xc7d2, 0x4f20], salamander_attack_r: [0xc7dc, 0x4f2c],
    cleric_attack_l: [0xc7e6, 0x5026], cleric_attack_r: [0xc7ed, 0x502f],
    magic_shot_l: [0x7070, 0x2f9b], magic_shot_r: [0x70a1, 0x2fcc],
    fireball_l: [0x70d2, 0x2ffd], fireball_r: [0x70e3, 0x300e],
    burst_l: [0x70f4, 0x301f], burst_r: [0x70f7, 0x3022],
    # scoring, sparkles, popups, bonus items
    combo_scores: [0xc7f4, 0x545a], score_table: [0xc800, 0x54f1],
    score_dissolve: [0xc821, 0x0a90], score_cake_break: [0xc833, 0x0aa2],
    drop_value_41: [0xc974, 0x5193], drop_value_49: [0xc977, 0x5196], drop_value_51: [0xc97a, 0x5199],
    drop_codes: [0xc97a, 0x51f0], # bonus coin code by crush count (read at base + count, count 3..7): on the X68000 it
                                  # overlaps drop_value_51, on the arcade it sits elsewhere
    sparkle_frames: [0x6b04, 0x268a], popup_digits: [0x7e38, 0x549d],
    star_paths: [0xc984, 0x563e],  # task 19: 8 paths x 8 [dy, dx]
    item_brackets: [0xc8d8, 0x488d], item_odds: [0xc8de, 0x4893], item_groups: [0xc902, 0x48b7],
    item_timers: [0xc905, 0x48ba], # indexed by level 0-8 (VARIANT: the level-9 byte)
    item_handlers: [0xc90e, 0x48c2], # read through GameData#item_sprite
    moon_frames: [0xc890, 0x31fe],
    # Horned (task 24): entrance scripts (pointer table, entries 1-4), step table (its $80 jumps hold arcade addresses),
    # wing frame offsets, vanish frames read backwards from here (the arcade reuses the escape table, FS.X a copy)
    horned_scripts: [0xcb7e, 0x6e0c], horned_steps: [0xcaf6, 0x6d83], horned_anim: [0xcc2e, 0x6eda],
    horned_vanish: [0xcaf5, 0x208e],
    # Dracolisk (round 101): big-sprite chains ($1c44), leg / tail / head / body frames, breath scripts [wait, head] x 4
    # (wait $19 = breathe fire), the death: giant cake [code, dy, code] .. 0, crumble [dy, code] .. code 0, end frames
    meta_d: [0x110db, 0x873b], drac_legs: [0xcce6, 0x8375], drac_tail: [0xccea, 0x8430], drac_head: [0xcced, 0x84f8],
    drac_body: [0x94f6, 0x8460], breath_low: [0xccf3, 0x84fe], breath_mid: [0xccfb, 0x8506], breath_high: [0xcd03, 0x850e],
    drac_death: [0xccb5, 0x82a8], drac_crumble: [0xccce, 0x82c1], drac_end: [0xcce0, 0x82d3],
    # the ending: celebration jump [dy, pose] .. negative dy; the text (arcade: in the MCU ROM, loaded at $10000 + address)
    # intermission ($1554 / task 25): entries (X68000 8 bytes [w picture, w palette, l message], arcade 4 bytes [picture,
    # palette, w message]), frame block (mirrored), deco list, 5 castle pictures (11 bytes each), Ptolemy + Rodomy
    # animation channels [time, frame], the bob curve
    inter_table: [0xac8e, 0x74ea], inter_frame: [0xabd8, 0x7434], inter_deco: [0xaaae, 0x734c], inter_pics: [0xac57, 0x74b3],
    fly_ch1: [0xcc34, 0x77f9], fly_ch2: [0xcc3e, 0x7803], fly_bob: [0xcc46, 0x780b],
    # game over: default best-5 table (5 x [score BCD x3, round, name x3]), the name wheel (0-terminated), the name filter,
    # the "ENTER YOUR INITIALS !" message, the continue text (arcade: in the MCU ROM)
    hiscore_default: [0xbc96, 0x7233], name_letters: [0xbd38, 0x7099], name_filter: [0xbd57, 0x70b8],
    initials_msg: [0x49ba, 0x7155], continue_text: [0xbcb9, 0x102be],
    # sprite priority lists 1-3 ($57e; X68000 $b158 + 64n [shadow offset, index] pairs, arcade $0510 + 32n bytes $a0 + index)
    prio_lists: [0xb158, 0x0510],
    finale_jump: [0x9bb0, 0x8b02], ending_text: [0xbd7a, 0x1020a],
    # Worm (task 26): open door blocks, 4 body frames, lunge script ([dx, frame].. 0 [dx, frame].. negative), eaten
    # sprites ([type, sprite] pairs from +1), body lengths (7, cycled)
    door_open: [0xcc6a, 0x7e20], door_open2: [0xcc72, 0x7e28], worm_anim: [0xcc7a, 0x7e30], worm_lunge: [0xcc7e, 0x7e34],
    worm_eaten: [0xcc99, 0x7e4f], worm_lengths: [0xcca6, 0x7e5c], # task 14: 8 frames x 9 tiles (3x3), read forwards to rise and backwards to set
    # round intro / clear scripts
    intro_paths: [0xca04, 0x5702], intro_script: [0xca50, 0x57fb], intro_script_small: [0xca6d, 0x5818],
    broom_exit: [0xca8a, 0x583f],
    # title / attract ($22a4, arcade $6733): the logo block, TAITO (arcade: a tile block; X68000: an 80x24 bitmap written
    # straight into GVRAM by $eee), the sparkle block list ($b414: [w pos, l block].. / arcade [w pos, w block]..; one or two
    # per tick, 0 ends a tick's group), the three demos (X68000 [l round, l script], arcade [round, w script])
    title_logo: [0xa3e2, 0x0c5b], title_taito: [0x9c30, 0x0d0d], title_sparkle: [0xb414, 0x69d6],
    demo_table: [0xb2ee, 0x68f6],
    # score extends ($8ee / arcade $09b7): 4 DSW entries x 4 bytes (X68000 [step lo-hi swapped: $58d $58c, first $70a
    # $709], arcade [step lo, step hi, first lo, first hi]); factory setting entry 0 = 30,000 then every 100,000
    extend_table: [0x920, 0x09d8],
    # metasprite chains ($1a48 / $1ab6 / $1b22 / $1b8e)
    meta_a: [0x10234, 0x3353], meta_b: [0x104f5, 0x363e], meta_poses: [0x108e9, 0x3a5c], meta_c: [0x10b29, 0x3cca],
    # round building ($1114 / $1676). Pointer widths and the record tail / decoration formats differ between the versions:
    # read them through GameData#round_record / #round_tail / #deco_entries / #enemy_list, never directly.
    round_records: [0xcd86, 0x78de], enemy_tables: [0xcf1e, 0x79aa], deco_lists: [0x1544, nil], # arcade: no selector table
    deco0: [0xa4aa, 0x1117], deco1: [0xa526, 0x11ed], deco2: [0xa69e, 0x1349], deco3: [0xa778, 0x1421],
    blk_theme1: [0x12f2, 0x0f3a], blk_theme3: [0x121c, 0x0ea4],
    pair_blk0: [0xa82b, 0x151c], pair_blk1: [0xa833, 0x1524], pair_blk2: [0xa83b, 0x152c], pair_blk3: [0xa843, 0x1534],
    autotile1: [0xa87d, 0x156e], autotile2: [0xa867, 0x1558], autotile3: [0xa84b, 0x153c],
    door_blk: [0xb532, 0x151c], door_blk2: [0xb53a, 0x152c],
    final_blk_a: [0xaf09, 0x7f38], final_blk_b: [0xaf97, 0x7fc6], final_blk_c: [0xb033, 0x8062],
    final_blk_d: [0xb039, 0x8068], final_blk_e: [0xb041, 0x8070], final_blk_f: [0xb045, 0x8074],
    final_bitmap: [0xb07b, 0x80aa], final_autotile: [0xb075, 0x80a4],
    # palettes (X68000 GRB555 words; the arcade sets its colours from code - converted by the arcade loader)
    pal_themes: [0xb600, nil], pal_fixed: [0xba00, nil], pal_sprites: [0xba80, nil],
    # the arcade's own palette RAM images (loader $5870 / $58c5): 6 theme sets, the fixed half, the full 512-byte table
    pal_arcade_themes: [nil, 0x58fa], pal_arcade_fixed: [nil, 0x5cfa], pal_arcade_full: [nil, 0x5d7a]
  }.freeze

  # Sprite palette patches (power-up glow, Glass Potion, ice blink, restore). X68000: [palette byte offset, colour word]
  # lists ended by a zero word ($28f6; :glow = consecutive lists, ended by an empty one). Arcade: queued palette writes
  # [pen, hi, lo] ($6290): :glow/:normal are 0-terminated triple tables (glow stores hi first, normal lo first), the
  # others are the operands of `ld c,pen / ld de,hilo` pairs in the code: [pen addr, lo addr, hi addr].
  PAL_PATCH = {
    glow: { x68000: 0xcabc, arcade: [:hilo, 0x6302] },
    normal: { x68000: 0xb5ea, arcade: [:lohi, 0x62c9] },
    ice: { x68000: 0xc956, arcade: [[0x49be, 0x49c0, 0x49c1], [0x49c6, 0x49c8, 0x49c9]] },
    glass: { x68000: 0xc960, arcade: [[0x4b30, 0x4b32, 0x4b33], [0x4b38, 0x4b3a, 0x4b3b]] },
    glass_off: { x68000: 0xc96a, arcade: [[0x4b40, 0x4b42, 0x4b43], [0x4b48, 0x4b4a, 0x4b4b]] },
    # the ending: Holy Gem colours (10 steps x 5: X68000 offsets list + ARCADE-format colour words, arcade pens $cb down),
    # the banner (task 0d, cycled), the graphic-screen colour 63 turned cyan when the text starts
    gem: { x68000: [:gem, 0xcd0c, 0xcd22], arcade: [:pens, 0xcb, 0x89ba] },
    banner: { x68000: 0x6042, arcade: [:cycle, 0x13, 0x8b82] },
    end_bg: { x68000: 0x381a, arcade: [[0x8bca, 0x8bcc, 0x8bcd]] },
    # the title (graphic-screen colours, so the arcade pens are $80-$bf): black-out (arcade: `ld c,pen / ld de,$f000` x 4
    # at $676d), then two fades (arcade: two [pen, hi, lo] writes per step, 0-terminated)
    title_black: { x68000: 0xb2d8, arcade: [[0x676e, 0x6770, 0x6771], [0x6776, 0x6770, 0x6771],
                                            [0x677b, 0x6770, 0x6771], [0x6780, 0x6770, 0x6771]] },
    title_fade1: { x68000: 0xb3a6, arcade: [:hilo2, 0x699e] },
    title_fade2: { x68000: 0xb3e0, arcade: [:hilo2, 0x69b7] }
  }.freeze

  # Single bytes inside pointer-reached data (round records, decoration lists) that differ between the versions:
  # { version => [address in that version's image, its value] }. GameData#behaviour= writes the chosen version's value.
  PATCHES = [
    { what: 'decoration list $13 entry 5 attr (the arcade mirrors this piece)', x68000: [0xa93b, 0x58], arcade: [0x13b3, 0x50] },
    { what: 'decoration list $13 entry 6 attr', x68000: [0xa945, 0x58], arcade: [0x13b8, 0x50] },
    { what: 'round 19 bitmap byte 66: one more solid cell on the arcade (row 16, col 23)',
      x68000: [0xdd71, 0xfe], arcade: [0x99b0, 0xff] }
  ].freeze

  # Tables whose bytes differ between the versions. Both copies live here, so the behaviour setting (ARCADE / X68000)
  # works whichever version's files the player supplied; the loader appends the non-native copy to its image.
  # Tables that differ by a small edit. The other version's copy is made from the player's own data (so the game's text
  # is not copied into this code): { name => { at: offset of the edit, size: { version => table length }, version => bytes } }
  VARIANT_EDITS = {
    # the ending text: the X68000 lost the full stop after "IN YOUR HAND" (and its other copy, $be2d, says "FOI")
    ending_text: { at: 102, size: { arcade: 180, x68000: 179 }, arcade: [0x2e, 0xf0, 0xa0], x68000: [0xf0, 0xa2] }
  }.freeze

  VARIANTS = {
    # level 9 (index 8) reads past the 8 timers: the arcade finds 230 there, the X68000 a 0 (= 256 ticks)
    item_timers: { arcade: [60, 80, 100, 120, 140, 160, 180, 200, 0xe6], x68000: [60, 80, 100, 120, 140, 160, 180, 200, 0] },
    # the arcade's Salamander and Cleric have one more wind-up pose (10 more frames of warning)
    salamander_attack_l: { arcade: [0x1f, 5, 0x17, 5, 0x1f, 5, 0x17, 5, 0x1f, 0x0f, 0x19, 0],
                           x68000: [0x17, 5, 0x1f, 5, 0x17, 5, 0x1f, 0x0f, 0x19, 0] },
    salamander_attack_r: { arcade: [0x21, 5, 0x1b, 5, 0x21, 5, 0x1b, 5, 0x21, 0x0f, 0x1d, 0],
                           x68000: [0x1b, 5, 0x21, 5, 0x1b, 5, 0x21, 0x0f, 0x1d, 0] },
    cleric_attack_l: { arcade: [0x37, 0x0a, 0x38, 5, 0x39, 5, 0x3a, 0x14, 0],
                       x68000: [0x38, 5, 0x39, 5, 0x3a, 0x14, 0] },
    cleric_attack_r: { arcade: [0x3c, 0x0a, 0x3d, 5, 0x3e, 5, 0x3f, 0x14, 0],
                       x68000: [0x3d, 5, 0x3e, 5, 0x3f, 0x14, 0] },
    # the X68000 dropped the last step (7a 07) of the rightward wave: one frame shorter, and the shrunk half (+$39) starts
    # one pair late
    spell_wave_r: {
      arcade: [0x70, 0xf9, 0x70, 0xfa, 0x71, 0xfb, 0x71, 0xfc, 0x72, 0xfd, 0x72, 0xfe, 0x73, 0xff, 0x73, 0, 0x74, 0, 0x74, 0,
               0x74, 0, 0x75, 0, 0x75, 0, 0x75, 0, 0x76, 0, 0x76, 0, 0x76, 0, 0x74, 0, 0x74, 0, 0x74, 0, 0x77, 0, 0x77, 1,
               0x78, 2, 0x78, 3, 0x79, 4, 0x79, 5, 0x7a, 6, 0x7a, 7, 0,
               0x70, 0xf9, 0x70, 0xfa, 0x71, 0xfb, 0x71, 0xfc, 0x72, 0xfd, 0x72, 0xfe, 0x78, 1, 0x78, 2, 0x79, 3, 0x79, 4,
               0x7a, 5, 0x7a, 6, 0],
      x68000: [0x70, 0xf9, 0x70, 0xfa, 0x71, 0xfb, 0x71, 0xfc, 0x72, 0xfd, 0x72, 0xfe, 0x73, 0xff, 0x73, 0, 0x74, 0, 0x74, 0,
               0x74, 0, 0x75, 0, 0x75, 0, 0x75, 0, 0x76, 0, 0x76, 0, 0x76, 0, 0x74, 0, 0x74, 0, 0x74, 0, 0x77, 0, 0x77, 1,
               0x78, 2, 0x78, 3, 0x79, 4, 0x79, 5, 0x7a, 6, 0,
               0x70, 0xf9, 0x70, 0xfa, 0x71, 0xfb, 0x71, 0xfc, 0x72, 0xfd, 0x72, 0xfe, 0x78, 1, 0x78, 2, 0x79, 3, 0x79, 4,
               0x7a, 5, 0x7a, 6, 0]
    }
  }.freeze
end
