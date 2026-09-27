-- Reads every keybinding Hyprland would register, by running the real config
-- against recording stubs. Lua reading Lua, so loops, requires and helper
-- tables resolve exactly as they do in the compositor.
--
--   lua scan.lua <hyprland.lua> <bindings.lua>
--
-- Prints a marker line (MARKER below), then one JSON object:
--
--   events   every hl.bind / hl.unbind in load order, with the file and line
--            that caused it; binds from bindings.lua also carry the raw call
--            (function name + literal arguments) and its source span
--   lines    bindings.lua split into lines, so the panel edits exactly what
--            was scanned
--   blocks   "-- BEGIN <owner>" / "-- END <owner>" fences in bindings.lua
--
-- Nothing is applied: every hl.* function only records, and the config runs
-- sandboxed (see sandbox()) so it can't run commands or change files.

local config_path, user_path = arg[1], arg[2]

-- The JSON follows this line. Anything a config writes to stdout on its own
-- lands before it and is ignored by the panel.
local MARKER = "@@KEYSMITH-SCAN@@"

-- ------------------------------------------------------------------ json

local encode

local function encode_string(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

encode = function(v, seen)
  local tv = type(v)
  if v == nil then return "null" end
  if tv == "boolean" then return tostring(v) end
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type and math.type(v) == "integer" then return tostring(v) end
    return string.format("%.14g", v)
  end
  if tv == "string" then return encode_string(v) end
  if tv == "function" then return '{"__fn":true}' end
  if tv == "table" then
    seen = seen or {}
    if seen[v] then return "null" end
    seen[v] = true
    local mt = getmetatable(v)
    if mt and mt.__noop then seen[v] = nil; return '{"__opaque":true}' end
    local out = {}
    if next(v) ~= nil and is_array(v) then
      for i = 1, #v do out[i] = encode(v[i], seen) end
      seen[v] = nil
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      out[#out + 1] = encode_string(tostring(k)) .. ":" .. encode(v[k], seen)
    end
    seen[v] = nil
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

-- -------------------------------------------------------- source tracking

-- Lexical path cleanup ("//", "/./", "/x/../"), so a module found through
-- package.path compares equal to the path the panel passed in. Pure Lua: the
-- scan runs no external commands.
local function real(p)
  if not p or p == "" then return "" end
  local absolute = p:sub(1, 1) == "/"
  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil
      elseif not absolute then parts[#parts + 1] = part end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return (absolute and "/" or "") .. table.concat(parts, "/")
end

local user_real = real(user_path)
local src_cache = {}

local function src_path(source)
  if src_cache[source] ~= nil then return src_cache[source] end
  local p = ""
  if source:sub(1, 1) == "@" then p = real(source:sub(2)) end
  src_cache[source] = p
  return p
end

local self_source = debug.getinfo(1, "S").source

-- The first frame that isn't this scanner or Omarchy's helpers.lua: that's
-- the line a person would point at as "where this binding comes from".
local function origin()
  for level = 3, 40 do
    local info = debug.getinfo(level, "Sl")
    if not info then break end
    if info.source ~= self_source and info.what ~= "C" then
      local p = src_path(info.source)
      if not p:match("/default/hypr/helpers%.lua$") then
        return { file = p, line = info.currentline, main = info.what == "main" }
      end
    end
  end
  return { file = "", line = 0, main = false }
end

-- --------------------------------------------------------------- stubs

local events = {}
local pending_raw = nil   -- raw o.bind call waiting for the hl.bind it produces
local wrap_depth = 0

local noop
noop = setmetatable({}, {
  __noop = true,
  __index = function() return noop end,
  __call = function() return noop end,
})

local function call_expression(path, ...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" then parts[i] = string.format("%q", v)
    elseif type(v) == "table" then
      -- Lua table literal, keys sorted for a stable round-trip
      local inner, keys = {}, {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local val = v[k]
        local lit = type(val) == "string" and string.format("%q", val) or tostring(val)
        if type(k) == "number" then inner[#inner + 1] = lit
        else inner[#inner + 1] = k .. " = " .. lit end
      end
      parts[i] = "{ " .. table.concat(inner, ", ") .. " }"
    else parts[i] = tostring(v) end
  end
  return path .. "(" .. table.concat(parts, ", ") .. ")"
end

local function dsp_proxy(path)
  return setmetatable({}, {
    __index = function(_, key) return dsp_proxy(path .. "." .. tostring(key)) end,
    __call = function(_, ...)
      local first = ...
      local expr = call_expression(path, ...)
      if path == "hl.dsp.exec_cmd" and type(first) == "string" then
        return { __dsp = true, kind = "exec", arg = first, expr = expr }
      end
      return { __dsp = true, kind = "lua", arg = expr, expr = expr }
    end,
  })
end

local function pack(...) return { n = select("#", ...), ... } end

local function args_list(p)
  local out = {}
  for i = 1, p.n do
    local v = p[i]
    if v == nil then out[i] = { __nil = true } else out[i] = v end
  end
  return out
end

hl = setmetatable({
  dsp = dsp_proxy("hl.dsp"),
  bind = function(...)
    local p = pack(...)
    local keys, dispatcher, opts = p[1], p[2], p[3]
    local ev = {
      t = "bind",
      keys = tostring(keys or ""),
      opts = type(opts) == "table" and opts or {},
      origin = origin(),
    }
    if type(dispatcher) == "table" and dispatcher.__dsp then ev.dsp = dispatcher
    elseif type(dispatcher) == "function" then ev.dsp = { kind = "function", arg = "", expr = "" }
    elseif type(dispatcher) == "string" then ev.dsp = { kind = "exec", arg = dispatcher, expr = "" }
    else ev.dsp = { kind = "unknown", arg = "", expr = "" } end

    if pending_raw then
      ev.raw = pending_raw
      pending_raw = nil
    elseif ev.origin.file == user_real then
      ev.raw = { fn = "hl.bind", args = args_list(p) }
    end
    events[#events + 1] = ev
    return noop
  end,
  unbind = function(keys)
    events[#events + 1] = { t = "unbind", keys = tostring(keys or ""), origin = origin() }
    return noop
  end,
  get_config = function() return nil end,
}, { __index = function() return noop end })

-- Omarchy's helpers.lua opens with `o = o or {}` and then defines o.bind and
-- friends on it. Catching those assignments lets the scanner see the raw
-- arguments of each o.bind call before helpers.lua rewrites them.
local function wrap(name, fn)
  return function(...)
    local outer = wrap_depth == 0
    if outer then pending_raw = { fn = "o." .. name, args = args_list(pack(...)) } end
    wrap_depth = wrap_depth + 1
    local ok, a, b, c = pcall(fn, ...)
    wrap_depth = wrap_depth - 1
    if outer then pending_raw = nil end
    if not ok then error(a, 0) end
    return a, b, c
  end
end

o = setmetatable({}, {
  __newindex = function(t, k, v)
    if (k == "bind" or k == "bind_toggle") and type(v) == "function" then v = wrap(k, v) end
    rawset(t, k, v)
  end,
})

-- --------------------------------------------------------------- run

-- Hyprland puts the config directory on the module path, so a bare
-- require("super-w-wait") in bindings.lua resolves next to hyprland.lua.
local config_dir = config_path:match("^(.*)/[^/]*$") or "."
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

-- The config runs to be read, not applied, so anything that would reach
-- outside this process becomes a no-op while it runs: shell commands
-- (os.execute, io.popen), file writes, deletes and renames, exiting, and
-- native modules. Reading files and loading Lua modules stay allowed, since
-- that is how the config finds its own parts. The scanner keeps private
-- copies of what it needs itself.
local open_file = io.open
local stdout = io.stdout

-- Blocked calls pretend to succeed, the way writing to /dev/null does, so a
-- config that checks its own writes (super-w-wait asserts on its state file)
-- keeps loading and its later bindings still get scanned.

-- A handle that reads as empty and swallows writes. Used for io.popen and for
-- opening a file to write.
local function null_handle(close_result)
  return setmetatable({}, { __index = {
    read = function(_, fmt)
      fmt = fmt or "l"
      if fmt == "a" or fmt == "*a" then return "" end
      return nil
    end,
    lines = function() return function() return nil end end,
    write = function(self) return self end,
    flush = function(self) return self end,
    setvbuf = function() return true end,
    seek = function() return 0 end,
    close = function() return table.unpack(close_result) end,
  } })
end

local warnings = {}

local function sandbox()
  -- commands report failure: a config branching on one takes the
  -- "not available" path rather than believing something ran
  os.execute = function(cmd)
    if cmd == nil then return false end  -- "is a shell available?"
    return nil, "exit", 1
  end
  io.popen = function() return null_handle({ nil, "exit", 1 }) end

  os.remove = function() return true end
  os.rename = function() return true end
  os.tmpname = function() return "/dev/null" end
  os.exit = function() error("os.exit is blocked during keysmith scan", 2) end
  os.setlocale = function() return nil end

  io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("[wa+]") then return null_handle({ true }) end
    return open_file(path, mode)
  end
  io.output = function() return stdout end
  -- a config that prints must not corrupt the JSON this script emits
  io.write = function() return stdout end
  print = function() end

  package.loadlib = function() return nil, "blocked during keysmith scan", "absent" end
  package.cpath = ""
  -- keep only the preload and Lua-file searchers; drop the C loaders
  for i = #package.searchers, 3, -1 do package.searchers[i] = nil end

  -- One module failing under the stubs shouldn't hide every binding after
  -- the require that loaded it.
  local real_require = require
  require = function(name)
    local ok, result = pcall(real_require, name)
    if ok then return result end
    warnings[#warnings + 1] = tostring(result)
    return nil
  end
end

local load_error = nil
do
  sandbox()
  local ok, err = pcall(dofile, config_path)
  if not ok then load_error = tostring(err) end
end

-- ------------------------------------------------------- user file spans

local lines = {}
do
  local f = open_file(user_path, "r")
  if f then
    local text = f:read("a")
    f:close()
    -- keep a trailing empty line out of the list; it is re-added on write
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
      lines[#lines + 1] = line
    end
  end
end

-- How many recorded calls came from each line of bindings.lua. A line hit more
-- than once is a loop or two calls on one line, and can't be edited as text.
local hits = {}
for _, ev in ipairs(events) do
  if ev.origin.file == user_real then
    hits[ev.origin.line] = (hits[ev.origin.line] or 0) + 1
  end
end

local call_start = "^%s*([%a_][%w_]*%.[%a_][%w_]*)%s*%("
local editable_fns = { ["o.bind"] = true, ["o.bind_toggle"] = true, ["hl.bind"] = true, ["hl.unbind"] = true }

-- A line with its trailing comment removed. Quoted strings are skipped, so the
-- "--" in a command like "wtype -- 'hi'" is not mistaken for a comment.
local function strip_comment(line)
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '"' or c == "'" then
      i = i + 1
      while i <= n and line:sub(i, i) ~= c do
        if line:sub(i, i) == "\\" then i = i + 1 end
        i = i + 1
      end
    elseif c == "[" and line:match("^%[=*%[", i) then
      local eq = line:match("^%[(=*)%[", i)
      local close = line:find("]" .. eq .. "]", i, true)
      if not close then return line end
      i = close + #eq + 1
    elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
      return line:sub(1, i - 1)
    end
    i = i + 1
  end
  return line
end

-- The statement starting on `start` ends on the first line that makes the
-- slice compile on its own.
local function span_for(start)
  local first = lines[start]
  if not first then return nil end
  local fn = first:match(call_start)
  if not fn or not editable_fns[fn] then return nil end
  for stop = start, math.min(#lines, start + 80) do
    local chunk = table.concat(lines, "\n", start, stop)
    if load(chunk, "span", "t") then
      local tail = strip_comment(lines[stop]):gsub("%s+$", "")
      if tail:sub(-1) ~= ")" then return nil end
      return { start = start, stop = stop, fn = fn }
    end
  end
  return nil
end

for _, ev in ipairs(events) do
  if ev.origin.file == user_real then
    local line = ev.origin.line
    ev.hits = hits[line]
    if ev.origin.main and hits[line] == 1 then
      local span = span_for(line)
      if span then
        ev.span = { start = span.start, stop = span.stop }
        ev.spanFn = span.fn
        ev.text = table.concat(lines, "\n", span.start, span.stop)
      end
    end
  end
end

local blocks = {}
do
  local open = {}
  for i, line in ipairs(lines) do
    local b = line:match("^%s*%-%-%s*BEGIN%s+(%S+)")
    local e = line:match("^%s*%-%-%s*END%s+(%S+)")
    if b then open[b] = i end
    if e and open[e] then
      blocks[#blocks + 1] = { owner = e, start = open[e], stop = i }
      open[e] = nil
    end
  end
end

stdout:write("\n" .. MARKER .. "\n")
stdout:write(encode({
  userFile = user_real,
  loadError = load_error,
  warnings = warnings,
  events = events,
  lines = lines,
  blocks = blocks,
}))
stdout:write("\n")
