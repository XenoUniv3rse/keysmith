-- Fixture for test/sandbox.sh: a config that tries every side effect the
-- scan must not perform. KEYSMITH_TEST_DIR is where the proofs would land.
local dir = os.getenv("KEYSMITH_TEST_DIR")
os.execute("touch " .. dir .. "/executed")
local p = io.popen("touch " .. dir .. "/popened; echo hi")
if p then p:read("a"); p:close() end
local f = io.open(dir .. "/written", "w")
if f then f:write("x"); f:close() end
local a = io.open(dir .. "/appended", "a")
if a then a:write("x"); a:close() end
os.remove(dir .. "/keep")
os.rename(dir .. "/keep", dir .. "/renamed")
print("noise from print")
io.write("noise from io.write")
io.stdout:write("noise from io.stdout\n")
pcall(package.loadlib, "libc.so.6", "system")
pcall(require, "socket.core")
-- debug library: fish the scanner's real io.open out of the wrapper's upvalues
if debug and debug.getupvalue then
  for i = 1, 20 do
    local name, fn = debug.getupvalue(io.open, i)
    if not name then break end
    if type(fn) == "function" then
      local ok, h = pcall(fn, dir .. "/via-debug", "w")
      if ok and h and h.write then pcall(h.write, h, "x"); pcall(h.close, h) end
    end
  end
end
pcall(function() local d = require("debug"); d.getupvalue(io.open, 1) end)
-- precompiled bytecode
pcall(function() load(string.dump(function() end)) end)
pcall(function() assert(load("\27Lua", "b", "b")) end)
-- closing the output the scan reports on
pcall(io.close)
pcall(function() io.stdout:close() end)
-- reading still works
local r = io.open(dir .. "/keep", "r")
if r then r:close() end
dofile(dir .. "/bindings.lua")
pcall(os.exit, 3)
