-- Tests that esphome_climate declares every HVAC state it can send.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_climate_hvac_states.lua
--
-- thermostatV2 accepts HVAC_STATE_CHANGED only for values listed in the
-- driver's <hvac_states>. A value outside the list is dropped with no error and
-- no log line, leaving HVAC_STATE (1107) empty and ANA_HVACSTATE (1215) at "-",
-- so a missing declaration is invisible from the driver side.
--
-- Regression test for DRV-131.

local T = require("testlib")

require("c4_shim")

local ESPHomeProtoSchema = require("esphome.proto_schema")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local src = readFile(root .. "/drivers/esphome_climate/driver.lua")
local xml = readFile(root .. "/drivers/esphome_climate/driver.xml")
T.check("the esphome_climate source was read", src ~= nil, "missing")
T.check("the esphome_climate driver.xml was read", xml ~= nil, "missing")

--------------------------------------------------------------------------------
T.section("the states the driver can send")
--------------------------------------------------------------------------------

-- The mapping comes out of the driver rather than being copied here, so this
-- asserts the driver's own vocabulary.
local mapText = src and src:match("\n(local CLIMATE_ACTION_TO_C4 = %b{})\n")
T.check("CLIMATE_ACTION_TO_C4 was cut out of the source", mapText ~= nil, "no match")

-- A cut of the wrong region would yield an empty table, and every membership
-- case below would then pass vacuously.
T.check(
  "the cut table maps CLIMATE_ACTION_COOLING",
  (mapText or ""):find("CLIMATE_ACTION_COOLING", 1, true) ~= nil,
  "not in the cut text"
)

local function loadMap(text)
  local chunk = loadstring((text or "") .. "\nreturn CLIMATE_ACTION_TO_C4", "=CLIMATE_ACTION_TO_C4")
  if chunk == nil then
    return nil
  end
  return setfenv(chunk, setmetatable({ ESPHomeProtoSchema = ESPHomeProtoSchema }, { __index = _G }))()
end

local map = loadMap(mapText)
T.check("the cut table compiles", type(map) == "table", "it did not compile")

--- Distinct C4 state strings, since several actions share one (Defrosting sends
--- Heating), in a stable order for reporting.
local function sentStates(actionMap)
  local seen, out = {}, {}
  for _, state in pairs(actionMap or {}) do
    if not seen[state] then
      seen[state] = true
      table.insert(out, state)
    end
  end
  table.sort(out)
  return out
end

local SENT = sentStates(map)
T.check("the driver sends at least one state", #SENT > 0, "none")
T.eq("the driver's action map covers every ESPHome climate action", #SENT, 6)

--------------------------------------------------------------------------------
T.section("the states driver.xml declares")
--------------------------------------------------------------------------------

--- Absent and empty are different faults: <hvac_states/> is also what the proxy
--- reports before an update reaches a running thermostat.
local function declaredStates(xmlText)
  if (xmlText or ""):find("<hvac_states%s*/>") then
    return {}, "empty"
  end
  local body = (xmlText or ""):match("<hvac_states>(.-)</hvac_states>")
  if body == nil then
    return nil, "absent"
  end
  local out = {}
  for token in body:gmatch("[^,]+") do
    table.insert(out, token)
  end
  return out, nil
end

local declared, fault = declaredStates(xml)
T.check("driver.xml declares an <hvac_states> list", declared ~= nil, tostring(fault))
T.check("the declared list is not empty", declared ~= nil and #declared > 0, tostring(fault))

--- Membership is per token, never a substring: the mode vocabulary's "Heat" is a
--- prefix of the state "Heating".
local function isDeclared(declaredList, state)
  for _, token in ipairs(declaredList or {}) do
    if token == state then
      return true
    end
  end
  return false
end

local function undeclared(declaredList, sentList)
  local out = {}
  for _, state in ipairs(sentList) do
    if not isDeclared(declaredList, state) then
      table.insert(out, state)
    end
  end
  return out
end

--------------------------------------------------------------------------------
T.section("every state the driver sends is declared")
--------------------------------------------------------------------------------

for _, state in ipairs(SENT) do
  T.check("the proxy accepts " .. state, isDeclared(declared, state), "not in <hvac_states>")
end

-- A state the driver can never send would not break the proxy, but it is the
-- shape a typo takes, and a misspelling that merely adds a token leaves every
-- case above passing.
for _, token in ipairs(declared or {}) do
  local sendable = false
  for _, state in ipairs(SENT) do
    if state == token then
      sendable = true
    end
  end
  T.check("the driver can send the declared " .. token, sendable, "not in CLIMATE_ACTION_TO_C4")
end

local counted = {}
for _, token in ipairs(declared or {}) do
  T.check("the declared " .. token .. " appears once", counted[token] == nil, "declared twice")
  counted[token] = true
end

--------------------------------------------------------------------------------
T.section("the assertion discriminates")
--------------------------------------------------------------------------------

-- Without these arms a declaration that silently stopped matching the map would
-- read the same as one that matches.
local strippedXml = xml and xml:gsub("%s*<hvac_states>.-</hvac_states>", "", 1)
local strippedDeclared, strippedFault = declaredStates(strippedXml)
T.eq("with the declaration removed the list is absent", strippedDeclared, nil)
T.eq("and the fault is reported as absent rather than empty", strippedFault, "absent")
T.eq("so every state the driver sends reads as undeclared", #undeclared(strippedDeclared, SENT), #SENT)

local emptiedXml = xml and xml:gsub("<hvac_states>.-</hvac_states>", "<hvac_states/>", 1)
local emptiedDeclared, emptiedFault = declaredStates(emptiedXml)
T.eq("an empty declaration is told apart from an absent one", emptiedFault, "empty")
T.eq("and declares nothing", #(emptiedDeclared or {}), 0)

-- The pre-fix state of the driver, and the reason DRV-131 was filed: Cooling was
-- dropped while the mode vocabulary was declared and worked.
T.check("Cooling is undeclared before the fix", not isDeclared(emptiedDeclared, "Cooling"), "reported as declared")
T.check("Cooling is declared after it", isDeclared(declared, "Cooling"), "not in <hvac_states>")

-- Substring matching would accept the state "Heating" on the strength of the
-- mode "Heat", which is declared one line above it in driver.xml.
T.check("a prefix of a state does not count as the state", not isDeclared({ "Heat" }, "Heating"), "matched")

T.finish()
