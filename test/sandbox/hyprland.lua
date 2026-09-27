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
-- reading still works
local r = io.open(dir .. "/keep", "r")
if r then r:close() end
dofile(dir .. "/bindings.lua")
pcall(os.exit, 3)
