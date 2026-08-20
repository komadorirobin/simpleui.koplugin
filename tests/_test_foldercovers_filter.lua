-- A cover scan temporarily mutates FileChooser's process-global filter and the
-- menu's dummy state. Verify that an exception cannot leak either mutation to
-- the rest of the KOReader session.

package.path = "./?.lua;./?/init.lua;" .. package.path

local original = { status = "reading" }
local FileChooser = { show_filter = original }
package.loaded["ui/widget/filechooser"] = FileChooser
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
}
local CoverFinder = dofile("features/library/sui_cover_finder.lua")

local original_dummy = { keep = true }
local menu = {
    _dummy = original_dummy,
    genItemTableFromPath = function(self)
        assert(FileChooser.show_filter ~= original,
            "filter should be suppressed inside scan")
        assert(self._dummy == true, "menu should use dummy mode inside scan")
        error("scan failed")
    end,
}

local ok = pcall(CoverFinder.entriesWithNoFilter, menu, "/library")
assert(not ok, "the original scan error must propagate")
assert(FileChooser.show_filter == original, "global filter must always be restored")
assert(menu._dummy == original_dummy, "menu dummy state must always be restored")

print("PASS 1  FAIL 0")
