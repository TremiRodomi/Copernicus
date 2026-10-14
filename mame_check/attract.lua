-- MAME (flstory) attract trace: $e600-$e6ff every frame from power-on (TRACE_OUT, TRACE_FRAMES); the port side is --objlog N.
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local out = io.open(os.getenv("TRACE_OUT"), "w")
local last = tonumber(os.getenv("TRACE_FRAMES"))
local f = 0
emu.register_frame_done(function()
  f = f + 1
  local t = {}
  for a = 0xe600, 0xe6ff do t[#t+1] = string.format("%02x", mem:read_u8(a)) end
  out:write(string.format("%d %02x %02x %02x %02x %s\n", f, mem:read_u8(0xe6a9), mem:read_u8(0xe6aa), mem:read_u8(0xe682), mem:read_u8(0xe67f), table.concat(t)))
  if f >= last then out:close(); manager.machine:exit() end
end)
