-- MAME (flstory): the Dracolisk's defeat on round 101 without a fight. Coin + start, round 101 at frame 700, NO HIT;
-- at frame DRAC_AT the fight loop's "no hit" path ($819b) is patched to jump to the defeat ($81ae). From then on:
-- a snapshot every frame (the first DRAC_SHOTS frames, into the snapshot directory) and every sound command (DRAC_SND file,
-- "frame cmd seconds" (frames counted from the patch, seconds of emulated time = position in a -wavwrite file), for DRAC_FRAMES frames). Port side: --round 101 --drac_dead 1 --shots ...
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local rom = manager.machine.memory.regions[":maincpu"]
local ports = manager.machine.ioport.ports
local at = tonumber(os.getenv("DRAC_AT") or "1400")
local shots = tonumber(os.getenv("DRAC_SHOTS") or "400")
local frames = tonumber(os.getenv("DRAC_FRAMES") or tostring(shots)) -- log sound commands this long
local snd = io.open(os.getenv("DRAC_SND"), "w")
local log = os.getenv("DRAC_LOG") and io.open(os.getenv("DRAC_LOG"), "w") -- optional: "frame x y sprites" (Ptolemy $e6a9/$e6aa, shadow $e000-$e00f) per frame
local f, P = 0, nil
ports[":SWC"].fields["Invulnerability (Cheat)"].user_value = 0
sndtap = mem:install_write_tap(0xd400, 0xd400, "snd", function(offset, data, mask)
  if P then snd:write(string.format("%d %02x %.4f\n", f - P, data, manager.machine.time:as_double())); snd:flush() end
end)
emu.register_frame_done(function()
  f = f + 1
  if f == 700 then mem:write_u8(0xe781, 100) end
  ports[":SYSTEM"].fields["Coin 1"]:set_value((f >= 600 and f < 606) and 1 or 0)
  ports[":SYSTEM"].fields["1 Player Start"]:set_value((f >= 800 and f < 806) and 1 or 0)
  if f == at then
    rom:write_u8(0x819b, 0xc3); rom:write_u8(0x819c, 0xae); rom:write_u8(0x819d, 0x81) -- jp $81ae
    P = f
  end
  if P and log then local v = {} for a = 0xe000, 0xe00f do v[#v+1] = string.format("%02x", mem:read_u8(a)) end log:write(string.format("%d %02x %02x %s\n", f - P, mem:read_u8(0xe6a9), mem:read_u8(0xe6aa), table.concat(v))) end
  if P and f - P < shots then manager.machine.video:snapshot() end
  if P and f - P >= frames then snd:close(); if log then log:close() end; manager.machine:exit() end
end)
