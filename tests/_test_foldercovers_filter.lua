-- The no-filter helper mutates FileChooser's process-global filter. Verify that
-- an exception inside the scan cannot leave the rest of the KOReader session
-- unfiltered.

local src = assert(io.open("sui_foldercovers.lua")):read("*a")
local body = src:match("local function _withNoFilter%(fn%)\n(.-)\nend\n")
assert(body, "_withNoFilter helper not found")

local original = { status = "reading" }
local FileChooser = { show_filter = original }
local env = {
    FileChooser = FileChooser,
    _EMPTY_FILTER = {},
    pcall = pcall,
    error = error,
}
local chunk
if _G.setfenv then
    chunk = assert(loadstring("return function(fn) " .. body .. " end"))
    setfenv(chunk, env)
else
    chunk = assert(load("return function(fn) " .. body .. " end", "filter", "t", env))
end
local withNoFilter = chunk()

local ok = pcall(withNoFilter, function()
    assert(FileChooser.show_filter ~= original, "filter should be suppressed inside scan")
    error("scan failed")
end)
assert(not ok, "the original scan error must propagate")
assert(FileChooser.show_filter == original, "global filter must always be restored")

print("PASS 1  FAIL 0")
