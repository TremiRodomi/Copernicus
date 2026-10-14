-- Record an X68000 FM (MDRV) song the OSTs lack: start a round (OPT.2 coin, A pulses), NO HIT, force the music set
-- ($47(a6) = FM_SET: 0 ORIGINAL / $18 ARRANGE), then make one jump's sound call an FM one: the $4ac command table
-- byte for $16 ($4ee + $16, in RAM with the program) is patched to FM_SONG for a few frames around one press of A, so
-- $4ac takes its own FM path (add $47(a6), trap #0). (A read tap does not see that pc-relative table read.)
-- Run with -wavwrite. Songs FM_SONG..FM_LAST (hex) are triggered one every 600 frames; FM_LOG gets each trigger's
-- emulated time. Env: FM_SET, FM_SONG, FM_LAST, FM_LOG, FM_HOLD (frames per song, default 600; a looping song needs
-- several loops, e.g. 3600), FM_FREEZE=1 (holds the round timer $610 and the moon countdown $61b while armed, so
-- the game's own music - time-up, the moon - never cuts a long song short), FM_OPM=<file> (every YM2151 write
-- $e90001 / $e90003 while armed: "<emulated time> <a|d> <byte>" - a looping song's loop shows exactly in the writes).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local a6 = 0xdc730
local set = tonumber(os.getenv("FM_SET"), 16)
local song = tonumber(os.getenv("FM_SONG"), 16)
local last = tonumber(os.getenv("FM_LAST") or os.getenv("FM_SONG"), 16)
local hold = tonumber(os.getenv("FM_HOLD") or "600")
local freeze = os.getenv("FM_FREEZE") == "1"
local opm = os.getenv("FM_OPM") and io.open(os.getenv("FM_OPM"), "w")
local opm_tap
local function opm_install() -- (at arm time: a tap installed before the boot did not fire)
  opm_tap = mem:install_write_tap(0xe90000, 0xe90003, "opm", function(offset, data, mask)
    local b = (mask & 0xff) ~= 0 and (data & 0xff) or ((data >> 8) & 0xff)
    opm:write(string.format("%.7f %s %02x\n", manager.machine.time:as_double(), (offset & 2) == 0 and "a" or "d", b))
  end)
end
local log = io.open(os.getenv("FM_LOG"), "w")
local opt2 = P[":keyboard:x68k:LINEE"].fields["OPT.2"]
local A = P[":joy1:townspad:PAD"].fields["P1 A"]
local f, base, armed, stop = 0, nil, false, nil
-- FS.X's $4ac: tst.b $44(a6) / bne.w $54c / tst.b d0 / beq.w $558
local sig = { 0x4a2e0044, 0x6600009a, 0x4a006700 }
local function find_base()
  for b = 0x0, 0xc0000, 2 do
    if mem:read_u32(b + 0x4ac) == sig[1] and mem:read_u32(b + 0x4b0) == sig[2] and mem:read_u32(b + 0x4b4) == sig[3] then return b end
  end
end
emu.register_frame_done(function()
  f = f + 1
  opt2:set_value((f >= 2400 and f < 2406) and 1 or 0)
  if f >= 2500 then
    mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf) -- NO HIT
    mem:write_u8(a6 + 0x47, set)
  end
  if not armed then A:set_value((f >= 2500 and f < 5000 and f % 60 < 6) and 1 or 0) end
  if freeze and armed then
    mem:write_u8(a6 + 0x610, 1)
    mem:write_u8(a6 + 0x61b, 100)
  end
  if f == 5300 then
    base = find_base()
    log:write(string.format("base %x\n", base or -1))
    if not base then manager.machine:exit() end
    armed = true
    if opm then opm_install() end
  end
  -- every song FM_SONG .. FM_LAST in turn, one every FM_HOLD frames (log: "song <hex> <time>")
  local k = armed and (f - 5330) // hold
  local ph = armed and (f - 5330) % hold
  if armed and k >= 0 and song + k <= last then
    if ph == 0 then
      mem:write_u8(base + 0x4ee + 0x16, song + k)
      A:set_value(1)
      log:write(string.format("song %02x %.6f frame %d\n", song + k, manager.machine.time:as_double(), f))
    elseif ph == 4 then
      A:set_value(0)
      mem:write_u8(base + 0x4ee + 0x16, 0xff)
    end
  end
  if armed and song + (k or 0) > last then stop = stop or f end
  if (stop and f >= stop) or f > 5330 + hold * (last - song + 1) + 600 then log:close(); if opm then opm:close() end; manager.machine:exit() end
end)
