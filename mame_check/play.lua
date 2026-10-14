-- MAME (flstory) side of the port-vs-arcade check: coin + start, round set at frame 700 (the cheat file's $e781),
-- NO HIT DIP on, then a scripted input stream from the frame the round's first enemy slot appears; logs $e600-$e6ff
-- every frame (PLAY_OUT), optionally sound commands written to $d400 (PLAY_SND) and the name table (PLAY_VRAM).
-- env: PLAY_ROUND (1-based), PLAY_INPUTS (file: one active-low input byte per line, hex), PLAY_FRAMES, PLAY_OUT, PLAY_SHIFT
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local ports = manager.machine.ioport.ports
local round = tonumber(os.getenv("PLAY_ROUND"))
local want = os.getenv("PLAY_SLOT0") -- the round's first slot (state, anim, type, task, facing, jdx, x, y) in hex
local function slot0()
  local t = {}
  for a = 0xe621, 0xe628 do t[#t+1] = string.format("%02x", mem:read_u8(a)) end
  return table.concat(t)
end
local shift = tonumber(os.getenv("PLAY_SHIFT") or "0")
local inputs = {}
for l in io.lines(os.getenv("PLAY_INPUTS")) do inputs[#inputs+1] = tonumber(l, 16) end
local n = tonumber(os.getenv("PLAY_FRAMES"))
local out = io.open(os.getenv("PLAY_OUT"), "w")
local vr = os.getenv("PLAY_VRAM") and io.open(os.getenv("PLAY_VRAM"), "w")
-- PLAY_SPR=<file>: the shadow sprite list entries $e04c-$e05b (Horned: slots $4c-$58, [~y + dy, code, attr, x + dx])
-- every logged frame (port: --sprlog, the same bytes rebuilt from its X68000-format list)
local spr = os.getenv("PLAY_SPR") and io.open(os.getenv("PLAY_SPR"), "w")
-- PLAY_ITEM="N,ROW": at that logged row the item spot ($e6cf/$e6d0) moves under Ptolemy, the walk counter ($e785/6) is set
-- to 798 and every entry of the item handler table ($48c2) is patched to item N's, so the next roll picks it (port:
-- --item_test N,ROW)
local item = os.getenv("PLAY_ITEM")
local item_n, item_row
if item then item_n, item_row = item:match("(%d+),(%d+)"); item_n, item_row = tonumber(item_n), tonumber(item_row) end
-- PLAY_TASKS=<file>: the task table every logged frame - 23 slots of 15 bytes from $e4a9 (id, status: bit 0 = active,
-- delay); "id" for an active slot, "--" for a free one (port: --tasklog)
local tasks = os.getenv("PLAY_TASKS") and io.open(os.getenv("PLAY_TASKS"), "w")
-- NO HIT (the Invulnerability DIP on) unless PLAY_HITS is set (then the DIP's default: enemies kill)
local inv = ports[":SWC"].fields["Invulnerability (Cheat)"]
inv.user_value = os.getenv("PLAY_HITS") and inv.defvalue or 0
-- PLAY_MOON=N: the moon countdown $e69f (X68000 $61b) set to N on the first logged row (port: --moon N)
local moon = tonumber(os.getenv("PLAY_MOON") or "")
local patched = false
local f, L, logged = 0, nil, 0
local snd = os.getenv("PLAY_SND") and io.open(os.getenv("PLAY_SND"), "w")
sndtap = snd and mem:install_write_tap(0xd400, 0xd400, "snd", function(offset, data, mask)
  if L then snd:write(string.format("%d %02x\n", f - L, data)) end
end)
local fields = { [1] = ports[":P1"].fields["P1 Button 1"], [2] = ports[":P1"].fields["P1 Button 2"],
                 [4] = ports[":P1"].fields["P1 Left"], [8] = ports[":P1"].fields["P1 Right"] }
local function press(v) -- v active-low like the port's inputs
  for bit, fl in pairs(fields) do fl:set_value((v & bit) == 0 and 1 or 0) end
end
emu.register_frame_done(function()
  f = f + 1
  if f == 700 then mem:write_u8(0xe781, round - 1); patched = true end -- the cheat file's "Select Current Round" (coin-up clears it at 601, the build reads it ~840; game start copies it to EXP)
  ports[":SYSTEM"].fields["Coin 1"]:set_value((f >= 600 and f < 606) and 1 or 0)
  ports[":SYSTEM"].fields["1 Player Start"]:set_value((f >= 800 and f < 806) and 1 or 0)
  if not L and patched and f > 806 and slot0() == want then L = f; if moon then mem:write_u8(0xe69f, moon) end end
  if L then
    local k = f - L + 1 + shift -- input for the coming frame
    press(inputs[k + 1] or 0x0f)
    local t = {}
    for a = 0xe600, 0xe6ff do t[#t+1] = string.format("%02x", mem:read_u8(a)) end
    out:write(string.format("%d 00 00 00 00 %s\n", f - L, table.concat(t)))
    if vr and ((f - L >= 2590 and f - L <= 2632) or (f - L >= 3330 and f - L <= 3374)) then
      local v = {}
      for a = 0xc000, 0xc7ff do v[#v+1] = string.format("%02x", mem:read_u8(a)) end
      vr:write((f - L) .. " " .. table.concat(v) .. "\n")
    end
    if tasks then
      local v = {}
      for k = 0, 22 do
        local a = 0xe4a9 + 15 * k
        v[#v+1] = (mem:read_u8(a + 1) & 1) == 1 and string.format("%02x", mem:read_u8(a)) or "--"
      end
      tasks:write((f - L) .. " " .. table.concat(v, " ") .. "\n")
    end
    if spr then
      local v = {}
      for a = 0xe04c, 0xe05b do v[#v+1] = string.format("%02x", mem:read_u8(a)) end
      spr:write((f - L) .. " " .. table.concat(v) .. "\n")
    end
    if item and f - L == item_row then
      mem:write_u8(0xe6cf, mem:read_u8(0xe6a9)); mem:write_u8(0xe6d0, mem:read_u8(0xe6aa))
      mem:write_u8(0xe785, 0x1e); mem:write_u8(0xe786, 0x03)
      local rom = manager.machine.memory.regions[":maincpu"]
      local lo, hi = rom:read_u8(0x48c2 + 2 * item_n), rom:read_u8(0x48c3 + 2 * item_n)
      for k = 0, 17 do rom:write_u8(0x48c2 + 2 * k, lo); rom:write_u8(0x48c3 + 2 * k, hi) end
    end
    logged = logged + 1
    if logged >= n then out:close(); if snd then snd:close() end; if spr then spr:close() end; if tasks then tasks:close() end; if vr then vr:close() end; manager.machine:exit() end
  end
  if f > 20000 then out:close(); manager.machine:exit() end
end)
