-- lib/persist.lua reading a stored table that JSON:decode rejects. JSON:encode
-- copies a string's bytes as they are and JSON:decode rejects bytes that are not
-- UTF-8, so one such string made the whole table read back as its base64 text.
-- lib/values raised on it at every load, and starting over would renumber its
-- variables.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_undecodable.lua

local T = require("testlib")
local H = require("values_harness")

local log = require("lib.logging")
local warnings = {}
log.warn = function(_, text, ...)
  table.insert(warnings, string.format(text, ...))
end

-- The Values a control4-zigbee3 driver stored for an Aqara FP300 (2026-09-24), its two
-- EUIs made up. A setting's raw bytes, "\0\3\255\255\255", sit in two of its strings.
local STORED_VALUES = table.concat({
  "eyJDb25maWdEZWZhdWx0cyI6eyJpbmRleCI6MTYsInZhbHVlIjoie1wiYWJzZW5jZV9kZWxheV90aW1lclwiOjEwLFwiYWlfaW50",
  "ZXJmZXJlbmNlX3NvdXJjZV9zZWxmaWRlbnRpZmljYXRpb25cIjowLFwiYWlfc2Vuc2l0aXZpdHlfYWRhcHRpdmVcIjoxLFwiZGV0",
  "ZWN0aW9uX3JhbmdlXCI6XCJcXHUwMDAwXFx1MDAwM////1wiLFwiaHVtaWRpdHlfcmVwb3J0X21vZGVcIjozLFwiaHVtaWRpdHlf",
  "cmVwb3J0aW5nX2ludGVydmFsXCI6MzYwMDAwMCxcImh1bWlkaXR5X3JlcG9ydGluZ190aHJlc2hvbGRcIjoxNTAwLFwibGVkX2Rp",
  "c2FibGVkX25pZ2h0XCI6MCxcImxpZ2h0X3JlcG9ydF9tb2RlXCI6MyxcImxpZ2h0X3JlcG9ydGluZ19pbnRlcnZhbFwiOjM2MDAw",
  "MDAsXCJsaWdodF9yZXBvcnRpbmdfdGhyZXNob2xkXCI6MTUwMCxcImxpZ2h0X3NhbXBsaW5nXCI6MSxcImxpZ2h0X3NhbXBsaW5n",
  "X3BlcmlvZFwiOjEwMDAwLFwibW90aW9uX3NlbnNpdGl2aXR5XCI6MixcInBpcl9kZXRlY3Rpb25faW50ZXJ2YWxcIjozMCxcInBy",
  "ZXNlbmNlX2RldGVjdGlvbl9vcHRpb25zXCI6MCxcInRlbXBfYW5kX2h1bWlkaXR5X3NhbXBsaW5nXCI6MSxcInRlbXBfYW5kX2h1",
  "bWlkaXR5X3NhbXBsaW5nX3BlcmlvZFwiOjYwMDAwMCxcInRlbXBfcmVwb3J0aW5nX2ludGVydmFsXCI6MzYwMDAwMCxcInRlbXBf",
  "cmVwb3J0aW5nX21vZGVcIjozLFwidGVtcF9yZXBvcnRpbmdfdGhyZXNob2xkXCI6MTAwfSIsIndyaXRhYmxlIjpmYWxzZX0sIkRl",
  "dmljZUNvbmZpZyI6eyJpbmRleCI6MTQsInZhbHVlIjoie1wiYWJzZW5jZV9kZWxheV90aW1lclwiOjEwLFwiYWlfaW50ZXJmZXJl",
  "bmNlX3NvdXJjZV9zZWxmaWRlbnRpZmljYXRpb25cIjowLFwiYWlfc2Vuc2l0aXZpdHlfYWRhcHRpdmVcIjoxLFwiZGV0ZWN0aW9u",
  "X3JhbmdlXCI6XCJcXHUwMDAwXFx1MDAwM////1wiLFwiaHVtaWRpdHlfcmVwb3J0X21vZGVcIjozLFwiaHVtaWRpdHlfcmVwb3J0",
  "aW5nX2ludGVydmFsXCI6MzYwMDAwMCxcImh1bWlkaXR5X3JlcG9ydGluZ190aHJlc2hvbGRcIjoxNTAwLFwibGVkX2Rpc2FibGVk",
  "X25pZ2h0XCI6MCxcImxpZ2h0X3JlcG9ydF9tb2RlXCI6MyxcImxpZ2h0X3JlcG9ydGluZ19pbnRlcnZhbFwiOjM2MDAwMDAsXCJs",
  "aWdodF9yZXBvcnRpbmdfdGhyZXNob2xkXCI6MTUwMCxcImxpZ2h0X3NhbXBsaW5nXCI6MSxcImxpZ2h0X3NhbXBsaW5nX3Blcmlv",
  "ZFwiOjEwMDAwLFwibW90aW9uX3NlbnNpdGl2aXR5XCI6MixcInBpcl9kZXRlY3Rpb25faW50ZXJ2YWxcIjozMCxcInByZXNlbmNl",
  "X2RldGVjdGlvbl9vcHRpb25zXCI6MCxcInJlcG9ydDpiYXR0ZXJ5XCI6e1wiY2hhbmdlXCI6MTAsXCJtYXhcIjo2NTAwMCxcIm1p",
  "blwiOjM2MDB9LFwicmVwb3J0Omh1bWlkaXR5XCI6e1wiY2hhbmdlXCI6MTAwLFwibWF4XCI6MzYwMCxcIm1pblwiOjEwfSxcInJl",
  "cG9ydDppbGx1bWluYW5jZVwiOntcImNoYW5nZVwiOjUsXCJtYXhcIjozNjAwLFwibWluXCI6MTB9LFwicmVwb3J0OnRlbXBlcmF0",
  "dXJlXCI6e1wiY2hhbmdlXCI6MTAwLFwibWF4XCI6MzYwMCxcIm1pblwiOjEwfSxcInRlbXBfYW5kX2h1bWlkaXR5X3NhbXBsaW5n",
  "XCI6MSxcInRlbXBfYW5kX2h1bWlkaXR5X3NhbXBsaW5nX3BlcmlvZFwiOjYwMDAwMCxcInRlbXBfcmVwb3J0aW5nX2ludGVydmFs",
  "XCI6MzYwMDAwMCxcInRlbXBfcmVwb3J0aW5nX21vZGVcIjozLFwidGVtcF9yZXBvcnRpbmdfdGhyZXNob2xkXCI6MTAwfSIsIndy",
  "aXRhYmxlIjpmYWxzZX0sIkRldmljZUV1aSI6eyJpbmRleCI6MTcsInZhbHVlIjoiMDIwMDAwMDAwMDAwMDY3NCIsIndyaXRhYmxl",
  "IjpmYWxzZX0sIkh1bWlkaXR5Ijp7ImluZGV4Ijo3LCJzdWZmaXgiOiIgJSIsInZhbHVlIjo0Ni4zLCJ2YXJUeXBlIjoiTlVNQkVS",
  "Iiwid3JpdGFibGUiOmZhbHNlfSwiSWxsdW1pbmFuY2UiOnsiaW5kZXgiOjYsInN1ZmZpeCI6IiBsdXgiLCJ2YWx1ZSI6NjgsInZh",
  "clR5cGUiOiJOVU1CRVIiLCJ3cml0YWJsZSI6ZmFsc2V9LCJJbnZlbnRvcnkiOnsiaW5kZXgiOjEwLCJ2YWx1ZSI6IntcImFwcFZl",
  "cnNpb25cIjo0MixcImNsdXN0ZXJzXCI6e1wiMFwiOntcIjFcIjp0cnVlfSxcIjFcIjp7XCIxXCI6dHJ1ZX0sXCIxMDI0XCI6e1wi",
  "MVwiOnRydWV9LFwiMTAyNlwiOntcIjFcIjp0cnVlfSxcIjEwMjlcIjp7XCIxXCI6dHJ1ZX0sXCIxMDMwXCI6e1wiMVwiOnRydWV9",
  "LFwiMThcIjp7XCIxXCI6dHJ1ZX0sXCIyNVwiOntcIjFcIjp0cnVlfSxcIjNcIjp7XCIxXCI6dHJ1ZX0sXCIzMlwiOntcIjFcIjp0",
  "cnVlfSxcIjM3XCI6e1wiMVwiOnRydWV9LFwiNjQ1MTdcIjp7XCIxXCI6dHJ1ZX0sXCI2NDcwNFwiOntcIjFcIjp0cnVlfX0sXCJw",
  "b3dlclwiOjMsXCJyeE1haW5zXCI6ZmFsc2UsXCJzZXJ2ZXJDbHVzdGVyc1wiOntcIjBcIjp7XCIxXCI6dHJ1ZX0sXCIxXCI6e1wi",
  "MVwiOnRydWV9LFwiMTAyNFwiOntcIjFcIjp0cnVlfSxcIjEwMjZcIjp7XCIxXCI6dHJ1ZX0sXCIxMDI5XCI6e1wiMVwiOnRydWV9",
  "LFwiMThcIjp7XCIxXCI6dHJ1ZX0sXCIzXCI6e1wiMVwiOnRydWV9LFwiNjQ3MDRcIjp7XCIxXCI6dHJ1ZX19LFwic2VydmVyS25v",
  "d25cIjp0cnVlfSIsIndyaXRhYmxlIjpmYWxzZX0sIkxhc3QgU2VlbiI6eyJpbmRleCI6MSwidmFsdWUiOiIyMDI2LTA5LTI0IDEz",
  "OjIxOjI1IiwidmFyVHlwZSI6IlNUUklORyIsIndyaXRhYmxlIjpmYWxzZX0sIlBlbmRpbmdDb25maWciOnsiZGVsZXRlZCI6dHJ1",
  "ZSwiaWQiOjEwMDUsImluZGV4Ijo1LCJ3cml0YWJsZSI6ZmFsc2V9LCJQaXIgZGV0ZWN0aW9uIFN0YXRlIjp7ImluZGV4IjozLCJ2",
  "YWx1ZSI6dHJ1ZSwidmFyVHlwZSI6IkJPT0wiLCJ3cml0YWJsZSI6ZmFsc2V9LCJQcmVzZW5jZSBTdGF0ZSI6eyJpbmRleCI6Miwi",
  "dmFsdWUiOnRydWUsInZhclR5cGUiOiJCT09MIiwid3JpdGFibGUiOmZhbHNlfSwiUmVzb2x2ZWRNYW51ZmFjdHVyZXIiOnsiaW5k",
  "ZXgiOjEyLCJ2YWx1ZSI6IkFxYXJhIiwid3JpdGFibGUiOmZhbHNlfSwiUmVzb2x2ZWRNb2RlbCI6eyJpbmRleCI6MTEsInZhbHVl",
  "IjoibHVtaS5zZW5zb3Jfb2NjdXB5LmFnbDgiLCJ3cml0YWJsZSI6ZmFsc2V9LCJTbmFwc2hvdCI6eyJpbmRleCI6MTUsInZhbHVl",
  "Ijoie1wiY2hhbm5lbHNcIjp7XCJodW1pZGl0eVwiOjQ2LjMsXCJpbGx1bWluYW5jZVwiOjY4LFwidGVtcGVyYXR1cmVcIjoyMS4z",
  "fSxcImNvbnRhY3RzXCI6e1wiY29udGFjdEAxXCI6dHJ1ZSxcIm9jY3VwYW5jeUAxXCI6dHJ1ZX0sXCJsaWdodHNcIjpbXSxcImxv",
  "Y2tzXCI6W10sXCJyZWxheXNcIjpbXX0iLCJ3cml0YWJsZSI6ZmFsc2V9LCJUZW1wZXJhdHVyZSBDIjp7ImlkIjoxMDA4LCJpbmRl",
  "eCI6OCwic3VmZml4IjoiIMKwQyIsInZhbHVlIjoyMS4zLCJ2YXJUeXBlIjoiTlVNQkVSIiwid3JpdGFibGUiOmZhbHNlfSwiVGVt",
  "cGVyYXR1cmUgRiI6eyJpZCI6MTAwOSwiaW5kZXgiOjksInN1ZmZpeCI6IiDCsEYiLCJ2YWx1ZSI6NzAuMywidmFyVHlwZSI6Ik5V",
  "TUJFUiIsIndyaXRhYmxlIjpmYWxzZX0sIlVuc3VwcG9ydGVkQ29uZmlnIjp7ImluZGV4IjoxMywidmFsdWUiOiJ7XCJyZXBvcnQ6",
  "b2NjdXBhbmN5XCI6dHJ1ZX0iLCJ3cml0YWJsZSI6ZmFsc2V9LCJaaWdiZWUgQ29vcmRpbmF0b3IgRVVJIjp7ImlkIjoxMDA0LCJp",
  "bmRleCI6NCwidmFsdWUiOiIwMjAwMDAwMDAwMDAwMDAxIiwidmFyVHlwZSI6IlNUUklORyIsIndyaXRhYmxlIjpmYWxzZX19",
})

-- A fresh instance has an empty cache, so get() reads storage as it does after a reload.
local function reload()
  return getmetatable(require("lib.persist")):new()
end

T.section("the stored Values read back, every record kept")
C4:PersistSetValue("Values", STORED_VALUES)
local values = reload():get("Values")
local count = 0
for _ in pairs(type(values) == "table" and values or {}) do
  count = count + 1
end
T.eq("every record is read", count, 17)
T.contains("the raw bytes read as Latin-1", Select(values, "DeviceConfig", "value"), '\\u0003\195\191\195\191\195\191"')
T.eq("text that is UTF-8 reads as it is", Select(values, "Temperature C", "suffix"), " \194\176C")
T.eq("one warning is logged", #warnings, 1)

T.section("lib/values restores them at their recorded ids")
H.wipe()
C4:PersistSetValue("Values", STORED_VALUES)
H.load("restart")
local visible = H.visible()
T.eq(
  "each recorded id is kept",
  { visible["Zigbee Coordinator EUI"], visible["Temperature C"], visible["Temperature F"] },
  { 1004, 1008, 1009 }
)
warnings = {}
H.load("update")
T.eq("once written back, they read with no warning", warnings, {})

T.section("a table set with text that is not UTF-8 reads back")
local p = reload()
-- A name cut mid-character, whole characters of 2 to 4 bytes then a stray byte, and bytes shaped
-- like UTF-8 whose lead byte JSON:decode refuses
p:set("Names", {
  cafe = "Caf\195",
  city = "Z\195\188rich \224\164\185\240\159\152\128\195\169\169",
  octets = "\192\128\245\128\128\128",
})
T.eq("with each bad byte as its Latin-1 character", reload():get("Names"), {
  cafe = "Caf\195\131",
  city = "Z\195\188rich \224\164\185\240\159\152\128\195\169\194\169",
  octets = "\195\128\194\128\195\181\194\128\194\128\194\128",
})
p:set("Name", "IgRqjfg02aoi") -- base64 of a JSON string with bytes that are not UTF-8
T.eq("a string stored raw still reads as itself", reload():get("Name"), "IgRqjfg02aoi")

T.finish()
