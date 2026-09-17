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
-- last of those freezes the ramp where the first left it.
--
-- The receive side cannot mirror that by narrowing to one command, because
-- senders disagree on which of the pair they emit: some send only DO_CLICK,
-- some only DO_PUSH. A discrete receiver instead acts on whichever arrives
-- first and ignores the rest of a short window, which is one action per tap for
-- every sender shape.
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
--- only one at column zero: every `end` inside the body is indented.
---
--- @return function|nil fn, string text The compiled function and its source.
local function extract(src, name)
  local text = src and src:match("\n(local function " .. name .. "%s*%b()\n.-\nend)\n")
  if not text then
    return nil, ""
  end
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

  -- A cut that matched the wrong body would emit nothing, which is
  -- indistinguishable from the bug being fixed by deletion.
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

    -- A sender that finds no binding must not send at all.
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

-- Read the real window out of the driver rather than restating it here. Feeding
-- the declared value in as the upvalue is what lets the delay assertion below
-- mean something: it fails if the handler arms a literal of its own instead of
-- the constant, and stays true when the constant is retuned.
local coalesceMs = tonumber(switchbot:match("\nlocal BUTTON_LINK_COALESCE_MS%s*=%s*(%d+)\n"))
T.check("the coalescing window constant was found in the driver", coalesceMs ~= nil, "no declaration matched")
T.check("the coalescing window is a positive duration", coalesceMs ~= nil and coalesceMs > 0, tostring(coalesceMs))

if registrar then
  --- Register a handler for `action`.
  ---
  --- The coalescing window is driven by SetTimer, which is stubbed here so the
  --- window closes exactly when the test says it does rather than on wall clock.
  --- `expire()` runs the pending callback, standing in for the timer firing.
  ---
  --- @return function handler, table fired, function expire, table timers
  local function handlerFor(action)
    local fired = { on = 0, off = 0, toggle = 0 }
    local RFP = {}
    local timers = { set = 0, pending = nil, ids = {}, delays = {} }
    local register = callIn(select(1, extract(switchbot, "registerBotButtonLinkHandler")), {
      log = newLog(),
      RFP = RFP,
      BUTTON_LINK_COALESCE_MS = coalesceMs,
      SetTimer = function(id, delay, fn)
        timers.set = timers.set + 1
        timers.pending = fn
        table.insert(timers.ids, id)
        table.insert(timers.delays, delay)
      end,
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
    local function expire()
      local fn = timers.pending
      timers.pending = nil
      if fn then
        fn()
      end
    end
    return RFP[BINDING_ID], fired, expire, timers
  end

  local function tap(handler)
    handler(BINDING_ID, "DO_PUSH", {}, nil)
    handler(BINDING_ID, "DO_CLICK", {}, nil)
  end

  local press, pressed, pressExpire, pressTimers = handlerFor("press")
  T.check("a press binding registers a handler", press ~= nil, "nothing landed in RFP")

  if press then
    tap(press)
    T.eq("one tap turns the bot on exactly once", pressed.on, 1)

    -- The suppression must be the window, not a command filter: exactly one
    -- timer was armed, and it was armed by the first command of the pair.
    T.eq("one tap arms the coalescing window once", pressTimers.set, 1)
    T.eq("the window armed is the driver's declared constant", pressTimers.delays[1], coalesceMs)

    -- A second tap after the window closes is a second action. Without this the
    -- handler could latch permanently and still pass every count above.
    pressExpire()
    tap(press)
    T.eq("a tap after the window closes fires again", pressed.on, 2)

    -- Derek's case, and the reason the receive side cannot narrow to one
    -- command: a sender emitting only one half must still drive the bot.
    local pushOnly, pushFired = handlerFor("press")
    pushOnly(BINDING_ID, "DO_PUSH", {}, nil)
    T.eq("a DO_PUSH-only sender fires the action", pushFired.on, 1)

    local clickOnly, clickFired = handlerFor("press")
    clickOnly(BINDING_ID, "DO_CLICK", {}, nil)
    T.eq("a DO_CLICK-only sender fires the action", clickFired.on, 1)

    -- Order-independence. A sender emitting the pair backwards (which is what
    -- our own senders did before this change) must still fire exactly once.
    local reversed, reversedFired = handlerFor("press")
    reversed(BINDING_ID, "DO_CLICK", {}, nil)
    reversed(BINDING_ID, "DO_PUSH", {}, nil)
    T.eq("a reversed pair fires exactly once", reversedFired.on, 1)

    -- A hold is DO_PUSH then DO_RELEASE. The push is a real button-down and
    -- fires; DO_RELEASE is not a command this receiver acts on at all.
    local held, heldFired, heldExpire = handlerFor("press")
    held(BINDING_ID, "DO_PUSH", {}, nil)
    held(BINDING_ID, "DO_RELEASE", {}, nil)
    T.eq("a hold fires once, on the push", heldFired.on, 1)
    heldExpire()
    held(BINDING_ID, "DO_RELEASE", {}, nil)
    T.eq("DO_RELEASE on its own never fires", heldFired.on, 1)

    -- An unrelated command is still ignored, and must not arm the window.
    local other, otherFired, _, otherTimers = handlerFor("press")
    other(BINDING_ID, "DO_SOMETHING_ELSE", {}, nil)
    T.eq("an unrelated command does not fire", otherFired.on, 0)
    T.eq("an unrelated command does not arm the window", otherTimers.set, 0)
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
