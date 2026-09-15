-- Tests the BUTTON_LINK wire protocol on both sides.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_button_link_protocol.lua
--
-- A Control4 keypad reports one tap as DO_PUSH then DO_CLICK. DO_CLICK and
-- DO_RELEASE are the two mutually exclusive terminations of a press, DO_RELEASE
-- being the one that ends a hold, so a sender emitting all three drives a
-- ramping load through PRESS, RELEASE_CLICK and RELEASE_HOLD in turn and the
-- last of those freezes the ramp where the first left it. Symmetrically, a
-- receiver acting on DO_CLICK *or* DO_PUSH runs its action twice for one tap.
--
-- The senders are file-local functions in drivers/*/driver.lua, and a driver.lua
-- cannot be loaded far enough to reach them (see test_sensor_binding_params.lua).
-- Rather than match the source as text, each function is cut out of the source
-- and compiled on its own against a stub environment, so what is asserted is the
-- sequence the code emits when run, not the shape of the lines that emit it.
--
-- Regression test for DRV-120.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

--- Everything sent since the last reset.
---
--- Captured at C4.SendToProxy rather than the global SendToProxy of the same
--- name: the global is a wrapper in lib/utils.lua that forwards through C4Call,
--- so stubbing it would measure the argument the caller passed instead of what
--- came out the far end of the path the driver actually takes.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams, message = strMessage })
end

--- The commands in `sends`, in order.
local function commands()
  local out = {}
  for _, send in ipairs(sends) do
    table.insert(out, send.command)
  end
  return out
end

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

--- A no-op logger. The drivers call log:trace/debug/info on the way through.
local function newLog()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

--- Cut `local function <name>(...) ... end` out of a source and compile it.
---
--- The closing `end` is matched anchored to the start of a line, which is the
--- only one at column zero: every `end` inside the body is indented. Names the
--- chunk after the file it came from so a syntax error points back at it.
---
--- @return function|nil fn, string text The compiled function and its source.
local function extract(src, name)
  local text = src and src:match("\n(local function " .. name .. "%s*%b()\n.-\nend)\n")
  if not text then
    return nil, ""
  end
  -- The cut text declares the function as a local, which would fall out of scope
  -- at the end of the chunk, so the chunk returns it.
  local chunk = loadstring(text .. "\nreturn " .. name, "=" .. name)
  return chunk, text
end

--- Run a compiled chunk with `env` standing in for its upvalues and globals.
---
--- The function was cut out of its file, so what were upvalues there resolve as
--- globals here and `env` supplies them. Anything env does not name falls
--- through to _G, which is how SendToProxy reaches the real lib/utils.lua
--- wrapper rather than a stub of it.
local function callIn(chunk, env)
  setfenv(chunk, setmetatable(env, { __index = _G }))
  return chunk()
end

local bthome = readFile(root .. "/drivers/esphome_bthome/driver.lua")
local switchbot = readFile(root .. "/drivers/esphome_switchbot/driver.lua")

T.check("the bthome source was read", bthome ~= nil, "missing")
T.check("the switchbot source was read", switchbot ~= nil, "missing")

--------------------------------------------------------------------------------
T.section("each sender emits DO_PUSH then DO_CLICK, and nothing else")
--------------------------------------------------------------------------------

-- Both senders take the binding from a getOrCreateButtonBinding of their own and
-- differ only in its arguments, so each is driven through its own signature.
local SENDERS = {
  {
    what = "bthome",
    src = bthome,
    -- sendButtonEvent(reading)
    drive = function(fn)
      fn({ name = "button", index = 1 })
    end,
  },
  {
    what = "switchbot",
    src = switchbot,
    -- sendButtonEvent(key, displayName)
    drive = function(fn)
      fn("contact_button", "Button")
    end,
  },
}

local BINDING_ID = 4242

for _, case in ipairs(SENDERS) do
  local chunk, text = extract(case.src, "sendButtonEvent")
  T.check(case.what .. ": sendButtonEvent was cut out of the source", chunk ~= nil, "no match, or it did not compile")

  -- Without this the extraction could have matched some other function body and
  -- still have emitted nothing, which is indistinguishable from the bug being
  -- fixed by deletion.
  T.check(case.what .. ": the cut text sends", text:find("SendToProxy", 1, true) ~= nil, text)

  if chunk then
    local bindingRequests = 0
    local fn = callIn(chunk, {
      log = newLog(),
      getOrCreateButtonBinding = function()
        bindingRequests = bindingRequests + 1
        return { bindingId = BINDING_ID, displayName = "Button" }
      end,
    })

    sends = {}
    case.drive(fn)

    T.eq(case.what .. ": the binding is resolved once", bindingRequests, 1)
    T.check(
      case.what .. ": emits exactly DO_PUSH then DO_CLICK",
      T.deepEqual(commands(), { "DO_PUSH", "DO_CLICK" }),
      table.concat(commands(), ", ")
    )
    T.eq(case.what .. ": sends nothing after DO_CLICK", #sends, 2)

    for _, send in ipairs(sends) do
      T.eq(case.what .. ": " .. send.command .. " goes to the button binding", send.idBinding, BINDING_ID)
      T.eq(case.what .. ": " .. send.command .. " is a NOTIFY", send.message, "NOTIFY")
    end

    --------------------------------------------------------------------------------
    -- A sender that finds no binding must not send at all.
    --------------------------------------------------------------------------------
    local noBinding = callIn(select(1, extract(case.src, "sendButtonEvent")), {
      log = newLog(),
      getOrCreateButtonBinding = function()
        return nil
      end,
    })
    sends = {}
    case.drive(noBinding)
    T.eq(case.what .. ": no binding means no sends", #sends, 0)
  end
end

--------------------------------------------------------------------------------
T.section("no sender anywhere emits DO_RELEASE")
--------------------------------------------------------------------------------

-- Scanned over every driver rather than the two edited here, so the triple
-- cannot be reintroduced elsewhere. Sends only: esphome_light and tplink_light
-- legitimately *receive* DO_RELEASE as RELEASE_HOLD, and those are RFP handlers,
-- not SendToProxy calls.
local function ls(dir)
  local names = {}
  local pipe = io.popen(string.format("ls %q 2>/dev/null", dir))
  if not pipe then
    return names
  end
  for name in pipe:lines() do
    table.insert(names, name)
  end
  pipe:close()
  return names
end

local function stripComments(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, (line:gsub("%-%-.*$", "")))
  end
  return table.concat(out, "\n")
end

local scanned, releaseSends, unreadable = 0, 0, 0
for _, name in ipairs(ls(root .. "/drivers")) do
  local body = readFile(root .. "/drivers/" .. name .. "/driver.lua")
  if body then
    scanned = scanned + 1
    local src = stripComments(body)
    for _ in src:gmatch("SendToProxy") do
      unreadable = unreadable + 1
    end
    for call in src:gmatch("SendToProxy%s*(%b())") do
      unreadable = unreadable - 1
      if call:find('"DO_RELEASE"', 1, true) then
        releaseSends = releaseSends + 1
        T.check(name .. ": sends DO_RELEASE", false, (call:gsub("%s+", " ")))
      end
    end
  end
end

-- A rename or a moved tree that stopped matching would otherwise pass silently.
T.check("the scan read some drivers", scanned > 0, scanned)
T.eq("no driver sends DO_RELEASE", releaseSends, 0)
T.check(
  "every SendToProxy occurrence was read as a call",
  unreadable == 0,
  string.format("%d occurrences did not parse as SendToProxy(...)", unreadable)
)

--------------------------------------------------------------------------------
T.section("the switchbot bot handler fires once for a tap")
--------------------------------------------------------------------------------

-- The handler is an anonymous closure installed into RFP by
-- registerBotButtonLinkHandler, so the registrar is what gets cut out and run.
local registrar = extract(switchbot, "registerBotButtonLinkHandler")
T.check("registerBotButtonLinkHandler was cut out of the source", registrar ~= nil, "no match, or it did not compile")

if registrar then
  --- Register a handler for `action` and return it alongside its call counters.
  local function handlerFor(action)
    local fired = { on = 0, off = 0, toggle = 0 }
    local RFP = {}
    local register = callIn(select(1, extract(switchbot, "registerBotButtonLinkHandler")), {
      log = newLog(),
      RFP = RFP,
      turnOn = function()
        fired.on = fired.on + 1
      end,
      turnOff = function()
        fired.off = fired.off + 1
      end,
      toggle = function()
        fired.toggle = fired.toggle + 1
      end,
    })
    register({ bindingId = BINDING_ID, displayName = "Press" }, action)
    return RFP[BINDING_ID], fired
  end

  --- Deliver one keypad tap: DO_PUSH, then DO_CLICK.
  local function tap(handler)
    handler(BINDING_ID, "DO_PUSH", {}, nil)
    handler(BINDING_ID, "DO_CLICK", {}, nil)
  end

  local press, pressed = handlerFor("press")
  T.check("a press binding registers a handler", press ~= nil, "nothing landed in RFP")

  if press then
    tap(press)
    T.eq("one tap turns the bot on exactly once", pressed.on, 1)

    -- The half of the tap that used to fire on its own. Asserted separately so a
    -- handler that had simply stopped responding could not pass the count above.
    local pushOnly, pushFired = handlerFor("press")
    pushOnly(BINDING_ID, "DO_PUSH", {}, nil)
    T.eq("DO_PUSH on its own does nothing", pushFired.on, 0)

    local clickOnly, clickFired = handlerFor("press")
    clickOnly(BINDING_ID, "DO_CLICK", {}, nil)
    T.eq("DO_CLICK on its own is what fires", clickFired.on, 1)

    -- A hold, which terminates in DO_RELEASE rather than DO_CLICK, is not a tap
    -- and must not run the action.
    local held, heldFired = handlerFor("press")
    held(BINDING_ID, "DO_PUSH", {}, nil)
    held(BINDING_ID, "DO_RELEASE", {}, nil)
    T.eq("a hold does not fire the action", heldFired.on, 0)
  end

  -- Every action the registrar dispatches, so a narrowing applied to one branch
  -- and not the rest would still fail here.
  for _, case in ipairs({
    { action = "on", counter = "on" },
    { action = "off", counter = "off" },
    { action = "toggle", counter = "toggle" },
  }) do
    local handler, fired = handlerFor(case.action)
    T.check(case.action .. ": a handler was registered", handler ~= nil, "nothing landed in RFP")
    if handler then
      tap(handler)
      T.eq("one tap runs the " .. case.action .. " action once", fired[case.counter], 1)
    end
  end
end

T.finish()
