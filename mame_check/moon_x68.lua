-- X68000 night / morning wipe duration in VIDEO frames: start a round (as play_x68.lua), force the moon (countdown $61b
-- = 1 once the round runs), print each change of $61d (1 night wipe, $ff morning wipe, 0 none) and of $600 (passes).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local a6 = 0xdc730
local round = tonumber(os.getenv("PLAY_ROUND") or "1")
local opt2 = P[":keyboard:x68k:LINEE"].fields["OPT.2"]
local pad = P[":joy1:townspad:PAD"].fields
local f, started, forced, last = 0, nil, false, nil
emu.register_frame_done(function()
  f = f + 1
  if not started then
    opt2:set_value((f >= 2400 and f < 2406) and 1 or 0)
    pad["P1 A"]:set_value((f >= 2500 and f % 60 < 6) and 1 or 0)
    if f >= 2500 then mem:write_u8(a6 + 0x703, round - 1); mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf) end
    if f > 2500 and mem:read_u8(a6 + 0x59d) == 0x20 then started = f; pad["P1 A"]:set_value(0) end
    return
  end
  mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
  if not forced and f > started + 300 then mem:write_u8(a6 + 0x61b, 1); forced = true end
  local v = mem:read_u8(a6 + 0x61d)
  if v ~= last then print("frame", f - started, "61d", string.format("%02x", v)); last = v end
  if f > started + 1800 then manager.machine:exit() end
end)
