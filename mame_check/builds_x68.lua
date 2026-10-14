-- MAME (x68000 + the user's FS disks): the round-start build time of every round, as builds.lua on the arcade.
-- ROUND SELECT to BUILD_FROM (disk 2 needs that much progress: FS.DAT byte 0), NO HIT. Every BUILD_EVERY video frames
-- the round is ended ($5fd = $80: & $7f == 0) -> the round clear (44 ticks), then the next round's build. A snapshot of
-- every frame from BUILD_SNAP0 to BUILD_SNAP1 frames after each round end (-snapname %i) - classified offline - and
-- BUILD_OUT: "end frame, round(1-based) at the end" per round end, to number the snapshots. Env: BUILD_A6 ($dc730).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local a6 = tonumber(os.getenv("BUILD_A6") or "dc730", 16)
local from = tonumber(os.getenv("BUILD_FROM") or "1")
local every = tonumber(os.getenv("BUILD_EVERY") or "800")
local s0 = tonumber(os.getenv("BUILD_SNAP0") or "230")
local s1 = tonumber(os.getenv("BUILD_SNAP1") or "340")
local count = tonumber(os.getenv("BUILD_COUNT") or "200") -- round ends to make before quitting
local out = io.open(os.getenv("BUILD_OUT"), "w")
local opt2 = P[":keyboard:x68k:LINEE"].fields["OPT.2"]
local pad = P[":joy1:townspad:PAD"].fields
local f, L, E = 0, nil, nil
emu.register_frame_done(function()
  f = f + 1
  if not L then
    opt2:set_value((f >= 2400 and f < 2406) and 1 or 0)
    pad["P1 A"]:set_value((f >= 2500 and f % 60 < 6) and 1 or 0)
    if f >= 2500 then
      mem:write_u8(a6 + 0x703, from - 1)
      mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
      if f > 2500 and mem:read_u8(a6 + 0x5fd) ~= 0 and mem:read_u8(a6 + 0x59d) ~= 0 then L = f; pad["P1 A"]:set_value(0) end
    end
    return
  end
  mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
  if (f - L) % every == 300 then
    if mem:read_u8(a6 + 0x703) >= (tonumber(os.getenv("BUILD_LAST") or "100") - 1) or count == 0 then out:close(); manager.machine:exit(); return end
    count = count - 1
    mem:write_u8(a6 + 0x5fd, 0x80); E = f
    out:write(string.format("%d %d\n", f, mem:read_u8(a6 + 0x703) + 1)); out:flush()
  end
  if E and f - E >= s0 and f - E < s1 then manager.machine.video:snapshot() end
end)
