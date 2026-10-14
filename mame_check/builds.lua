-- MAME (flstory): the round-start build time of every round. Coin + start, round BUILD_FROM (1-based) at frame 700, NO HIT.
-- At each round start (round music $07 / $30 / $12 written to $d400) it waits BUILD_PLAY frames, then ends the round
-- ($e681 enemies left = 0): the normal round clear ($0c, 44 ticks), then the next round's build. Per frame from the $0c,
-- the screen is classified on a 32 x 28 grid of sampled pixels: R = playfield shown, h = only the bottom line (the
-- ROUND line is drawn before the rest), b = black. BUILD_OUT: "round(1-based, the one being built) $0c->$07 frames
-- runs" for each transition, e.g. "2 270 R264 b2 h3 R1".
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local ports = manager.machine.ioport.ports
local scr = manager.machine.screens[":screen"]
local from = tonumber(os.getenv("BUILD_FROM") or "1")
local play = tonumber(os.getenv("BUILD_PLAY") or "120")
local out = io.open(os.getenv("BUILD_OUT"), "w")
local snap = os.getenv("BUILD_SNAP") -- set: also a snapshot of every frame from 255 frames after each $0c to the $07
                                     -- (named <frame>.png with -snapname %i; the sampled bottom line misses sparse text)
local f, cleared, started, runs, cur, n, c0 = 0, nil, nil, {}, nil, 0, nil
ports[":SWC"].fields["Invulnerability (Cheat)"].user_value = 0
local function lit(x0, y0, x1, y1, st) -- screen coordinates: game line L = y (the visible area is lines 16-239)
  st = st or 8
  local k, t = 0, 0
  for y = y0, y1, st do for x = x0, x1, st do
    t = t + 1
    if (scr:pixel(x, y) & 0xffffff) ~= 0 then k = k + 1 end
  end end
  return k / t
end
sndtap = mem:install_write_tap(0xd400, 0xd400, "snd", function(offset, data, mask)
  if data == 0x0c and started then c0 = f end
  if (data == 0x07 or data == 0x30 or data == 0x12) and f > 806 then
    if c0 then
      if cur then runs[#runs+1] = cur .. n end
      out:write(string.format("%d %d %s\n", mem:read_u8(0xe781) + 1, f - c0, table.concat(runs, " "))); out:flush()
      runs, cur, n, c0 = {}, nil, 0, nil
      if mem:read_u8(0xe781) >= (tonumber(os.getenv("BUILD_LAST") or "100") - 1) then out:close(); manager.machine:exit() end
    end
    started = f
  end
end)
emu.register_frame_done(function()
  f = f + 1
  if f == 700 then mem:write_u8(0xe781, from - 1) end
  ports[":SYSTEM"].fields["Coin 1"]:set_value((f >= 600 and f < 606) and 1 or 0)
  ports[":SYSTEM"].fields["1 Player Start"]:set_value((f >= 800 and f < 806) and 1 or 0)
  if started and f == started + play then mem:write_u8(0xe681, 0) end
  if c0 and snap and f - c0 >= 255 then manager.machine.video:snapshot() end
  if c0 then
    local pf = lit(4, 48, 252, 212)
    local c = pf > 0.3 and "R" or (lit(4, 232, 252, 239, 4) > 0.3 and "h" or "b")
    if c == cur then n = n + 1 else if cur then runs[#runs+1] = cur .. n end; cur, n = c, 1 end
  end
end)
