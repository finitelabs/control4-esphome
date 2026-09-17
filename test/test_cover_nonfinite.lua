-- A cover reporting a non-finite position must read as closed, not open.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_cover_nonfinite.lua
--
-- ESPHome sends NaN for a position the device has not reported, and protobuf
-- v0.6.9 decodes it as a real NaN. `tonumber(x) or 0` does not fall back for a
-- NaN, `nan * 100` is NaN, and `tointeger` then yields nil, so the
-- `position == 0` test failed and the else branch reported the cover open.
--
-- Each case uses its own entity: the state is persisted per entity name, and a
-- shared name would let one case read another's value.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local values = require("lib.values")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local CoverEntity = require("esphome.entities.cover")

local NAN = 0 / 0
local IDLE = ESPHomeProtoSchema.Enum.CoverOperation.COVER_OPERATION_IDLE

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

local nextKey = 7300

--- Drive `updated` on one cover and return the state string it published.
--- @param item table The CoverEntity (real or mutant).
--- @param position any The reported position.
--- @return string|nil stateString
local function stateFor(item, position)
  nextKey = nextKey + 1
  local entity = {
    key = nextKey,
    name = "Garage Door " .. nextKey,
    supports_position = true,
  }
  item:updated(entity, {
    key = entity.key,
    position = position,
    current_operation = IDLE,
  })
  return Select(values:getValue(entity.name .. " State"), "value")
end

local cover = CoverEntity:new({})

--------------------------------------------------------------------------------
T.section("a non-finite position reads as closed")
--------------------------------------------------------------------------------

T.eq("NaN", stateFor(cover, NAN), "closed")
T.eq("positive infinity", stateFor(cover, math.huge), "closed")
T.eq("negative infinity", stateFor(cover, -math.huge), "closed")

--------------------------------------------------------------------------------
T.section("a finite position still decides open versus closed")
--------------------------------------------------------------------------------

-- Without these the fix could read every position as closed and still pass above.
T.eq("fully closed", stateFor(cover, 0), "closed")
T.eq("half open", stateFor(cover, 0.5), "open")
T.eq("fully open", stateFor(cover, 1.0), "open")
T.eq("a hair off closed", stateFor(cover, 0.01), "open")
T.eq("an absent position", stateFor(cover, nil), "closed")

--------------------------------------------------------------------------------
T.section("reverting the fix puts the NaN case back")
--------------------------------------------------------------------------------

-- Reverts `tofinite` to the `tonumber` the fix replaced and runs the resulting
-- module, so the NaN assertions above are shown to fail against the pre-fix
-- source rather than passing for some unrelated reason.
local src = readFile(root .. "/src/esphome/entities/cover.lua")
T.check("the cover source was read", src ~= nil, "missing")

local mutatedSrc, swaps = src:gsub("tofinite%(state%.position%)", "tonumber(state.position)")
T.eq("the revert replaced exactly one call", swaps, 1)

local chunk, loadErr = loadstring(mutatedSrc, "cover_reverted")
T.check("the reverted source compiles", chunk ~= nil, loadErr)

local revertedCover = chunk():new({})
T.eq("the reverted source reports a NaN position as open", stateFor(revertedCover, NAN), "open")
T.eq("and still agrees on a finite position", stateFor(revertedCover, 0.5), "open")
T.eq("and on a closed one", stateFor(revertedCover, 0), "closed")

T.finish()
