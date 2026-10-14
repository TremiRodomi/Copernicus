-- MAME (flstory): a Mystical Feather warp without the item. Coin + start, round WARP_ROUND (1-based) at frame 700,
-- NO HIT; at frame WARP_AT: $e6d2 (X68000 $653, rounds to skip) = WARP_N and $e681 ($5fd, enemies left) = 0, so the
-- round ends as after the feather. Then a snapshot every frame for WARP_SHOTS frames (snapshot directory) and the
-- sound commands (WARP_SND: "frame cmd", frames from WARP_AT). Port side: --round N --item 16 (feather).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local ports = manager.machine.ioport.ports
local round = tonumber(os.getenv("WARP_ROUND") or "5")
local at = tonumber(os.getenv("WARP_AT") or "1500")
local n = tonumber(os.getenv("WARP_N") or "4")
local shots = tonumber(os.getenv("WARP_SHOTS") or "900")
local snd = io.open(os.getenv("WARP_SND"), "w")
local f = 0
ports[":SWC"].fields["Invulnerability (Cheat)"].user_value = 0
sndtap = mem:install_write_tap(0xd400, 0xd400, "snd", function(offset, data, mask)
  if f >= at then snd:write(string.format("%d %02x\n", f - at, data)); snd:flush() end
end)
emu.register_frame_done(function()
  f = f + 1
  if f == 700 then mem:write_u8(0xe781, round - 1) end
  ports[":SYSTEM"].fields["Coin 1"]:set_value((f >= 600 and f < 606) and 1 or 0)
  ports[":SYSTEM"].fields["1 Player Start"]:set_value((f >= 800 and f < 806) and 1 or 0)
  if f == at then mem:write_u8(0xe6d2, n); mem:write_u8(0xe681, 0) end
  if f >= at and f - at < shots then manager.machine.video:snapshot() end
  if f - at >= shots then snd:close(); manager.machine:exit() end
end)
