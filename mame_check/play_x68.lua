-- MAME (x68000 + the user's FS disks) side of the port-vs-X68000 check: OPT.2 = coin, trigger A = 1PLAYER START,
-- ROUND SELECT set by writing $703 (re-read by its loop $324c), A again to confirm (A pulsed every 60 frames); NO HIT = $578 bit 6 clear.
-- Then the scripted inputs (port active-low bits: 1 spell = B, 2 jump = A, 4 left, 8 right) from the frame the round's
-- first enemy slot appears; logs a6+$500..$7ff every GAME PASS (PLAY_OUT, see the $600 tap). Env as play.lua (+ PLAY_A6, default $dc730).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local a6 = tonumber(os.getenv("PLAY_A6") or "dc730", 16)
local round = tonumber(os.getenv("PLAY_ROUND"))
local want = os.getenv("PLAY_SLOT0")
local shift = tonumber(os.getenv("PLAY_SHIFT") or "0")
local inputs = {}
for l in io.lines(os.getenv("PLAY_INPUTS")) do inputs[#inputs+1] = tonumber(l, 16) end
local n = tonumber(os.getenv("PLAY_FRAMES"))
local out = io.open(os.getenv("PLAY_OUT"), "w")
local tout = os.getenv("PLAY_TASKS") and io.open(os.getenv("PLAY_TASKS"), "w")
local opt2 = P[":keyboard:x68k:LINEE"].fields["OPT.2"]
local pad = P[":joy1:townspad:PAD"].fields
local fields = { [1] = pad["P1 B"], [2] = pad["P1 A"], [4] = pad["P1 Left"], [8] = pad["P1 Right"] }
local function press(v) for bit, fl in pairs(fields) do fl:set_value((v & bit) == 0 and 1 or 0) end end
local function slot0()
  local t = {}
  for a = a6 + 0x59d, a6 + 0x5a4 do t[#t+1] = string.format("%02x", mem:read_u8(a)) end
  return table.concat(t)
end
local f, L, logged = 0, nil, 0
-- ONE ROW PER GAME PASS: the 10 MHz X68000 does not always fit a pass into a frame (lag frames, then catch-up passes),
-- so rows are taken when $2b2 writes the speed divider $600 - once at the end of every main-loop pass - not per video
-- frame. The next input is set there too. (The row's $600 is the value being written.) $4c00 also writes it (AI init).
divtap = mem:install_write_tap(a6 + 0x600, a6 + 0x601, "div", function(offset, data, mask)
  if not L or logged >= n then return end
  if mask & 0xff00 == 0 then return end -- 16-bit bus: $600 (even) is the high byte
  local d = (data >> 8) & 0xff
  -- $2b2: subq.b #1,$600 then, when that went negative, move.b $5fe,$600: one row per pass, after the reload if any.
  -- A subq writes the old value - 1 (the tap runs before the write lands); other writes count only right after a
  -- negative subq (the reload) - $4c00's (AI init) is ignored.
  local sub = d == ((mem:read_u8(a6 + 0x600) - 1) & 0xff)
  if sub and d >= 0x80 then reload = true; return end
  if not sub and not reload then return end
  reload = false
  mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
  local t = {}
  for a = a6 + 0x500, a6 + 0x7ff do t[#t+1] = string.format("%02x", a == a6 + 0x600 and d or mem:read_u8(a)) end
  out:write(string.format("%d 00 00 00 00 %s\n", logged, table.concat(t)))
  if tout then -- PLAY_TASKS: the 23 task slots at a6+$234 (36 bytes each): id, or -- when not allocated (flags bit 0)
    local ids = {}
    for i = 0, 22 do
      local b = a6 + 0x234 + 0x24 * i
      ids[#ids+1] = (mem:read_u8(b + 1) & 1) == 1 and string.format("%02x", mem:read_u8(b)) or "--"
    end
    tout:write(logged .. " " .. table.concat(ids, " ") .. "\n")
  end
  logged = logged + 1
  press(inputs[logged + 1 + shift] or 0x0f)
  if logged >= n then out:close(); if tout then tout:close() end; done = true end
end)
emu.register_frame_done(function()
  f = f + 1
  if not L then
    opt2:set_value((f >= 2400 and f < 2406) and 1 or 0)
    -- floppy timing moves the menus from run to run: after the coin, pulse A every 60 frames with $703 held at the
    -- round until the round's enemy slots are filled (the round build, before Ptolemy can move)
    pad["P1 A"]:set_value((f >= 2500 and f % 60 < 6) and 1 or 0)
    if f >= 2500 then
      mem:write_u8(a6 + 0x703, round - 1)
      mem:write_u8(a6 + 0x578, mem:read_u8(a6 + 0x578) & 0xbf)
    end
    if f > 2500 and slot0() == want then
      L = f; pad["P1 A"]:set_value(0); press(inputs[1 + shift] or 0x0f)
      if os.getenv("PLAY_MOON") then mem:write_u8(a6 + 0x61b, tonumber(os.getenv("PLAY_MOON"))) end -- port: --moon N
    end
  end
  if done then manager.machine:exit() end
  if f > 30000 then out:close(); manager.machine:exit() end
end)
