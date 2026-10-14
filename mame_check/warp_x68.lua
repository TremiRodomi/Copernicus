-- MAME (x68000 + the user's FS disks): a Mystical Feather warp without the item, as warp.lua does on the arcade.
-- OPT.2 = coin, A pulsed into ROUND SELECT with $703 held at WARP_ROUND - 1 until the round's enemies are loaded ($5fd),
-- NO HIT; WARP_AT frames later: $653 (rounds to skip) = WARP_N, $5fd (enemies left) = 0. Then a snapshot every video
-- frame for WARP_SHOTS frames, and WARP_LOG: "frame round(0-based) $5fd" per video frame (frames from WARP_AT).
-- Env: WARP_A6 (default $dc730, see play_x68.lua).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local a6 = tonumber(os.getenv("WARP_A6") or "dc730", 16)
local round = tonumber(os.getenv("WARP_ROUND") or "5")
local at = tonumber(os.getenv("WARP_AT") or "300")
local n = tonumber(os.getenv("WARP_N") or "4")
local shots = tonumber(os.getenv("WARP_SHOTS") or "900")
local log = io.open(os.getenv("WARP_LOG"), "w")
local opt2 = P[":keyboard:x68k:LINEE"].fields["OPT.2"]
local pad = P[":joy1:townspad:PAD"].fields
local f, L, T = 0, nil, nil
emu.register_frame_done(function()
  f = f + 1
  if not L then
    opt2:set_value((f >= 2400 and f < 2406) and 1 or 0)
    pad["P1 A"]:set_value((f >= 2500 and f % 60 < 6) and 1 or 0)
    if f >= 2500 then
      mem:write_u8(a6 + 0x703, round - 1)
      mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
      -- (in the menus $5fd holds a leftover value: also wait for the first object slot to be filled)
      if f > 2500 and mem:read_u8(a6 + 0x5fd) ~= 0 and mem:read_u8(a6 + 0x59d) ~= 0 then L = f; pad["P1 A"]:set_value(0) end
    end
    return
  end
  if f == L + at then
    mem:write_u8(a6 + 0x653, n); mem:write_u8(a6 + 0x5fd, 0x80); T = f -- ($5fd & $7f == 0 ends the round; 0 was counted down to $ff)
  end
  if T then
    log:write(string.format("%d %02x %02x\n", f - T, mem:read_u8(a6 + 0x703), mem:read_u8(a6 + 0x5fd)))
    if f - T < shots then manager.machine.video:snapshot() end
    if f - T >= shots then log:close(); manager.machine:exit() end
  end
  if f > 60000 then log:close(); manager.machine:exit() end
end)
