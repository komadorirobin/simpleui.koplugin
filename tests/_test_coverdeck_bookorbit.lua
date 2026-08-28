package.path = "./?.lua;./?/init.lua;" .. package.path

local files = {
    "/books/one.epub",
    "/books/two.epub",
    "/books/three.epub",
    "/books/four.epub",
    "/books/five.epub",
    "/books/six.epub",
    "/books/seven.epub",
}

package.loaded["ffi/blitbuffer"] = {}
package.loaded["ui/bidi"] = {}
package.loaded["device"] = { screen = {} }
package.loaded["ui/font"] = {}
package.loaded["ui/widget/container/framecontainer"] = {}
package.loaded["ui/geometry"] = {}
package.loaded["ui/gesturerange"] = {}
package.loaded["ui/widget/container/inputcontainer"] = {}
package.loaded["ui/widget/overlapgroup"] = {}
package.loaded["ui/widget/textwidget"] = {}
package.loaded["ui/widget/verticalgroup"] = {}
package.loaded["sui_i18n"] = {
    translate = function(value) return value end,
    ngettext = function(one, many, count) return count == 1 and one or many end,
}
package.loaded["logger"] = { warn = function() end, dbg = function() end }
package.loaded["sui_config"] = {}
package.loaded["sui_core"] = { PAD = 1, PAD2 = 1, CLR_TEXT_SUB = 0 }
package.loaded["sui_store"] = {
    readSetting = function() return nil end,
    nilOrTrue = function() return true end,
}
package.loaded["sui_style"] = {}
package.loaded["integrations/sui_bookorbit_want"] = {
    getCachedFiles = function()
        local copy = {}
        for i, path in ipairs(files) do copy[i] = path end
        return copy
    end,
}

local CoverDeck = dofile("desktop_modules/module_coverdeck.lua")
local result = CoverDeck.getSourceFileList("bookorbit_want", {})
assert(#result == 7, "BookOrbit Cover Deck source must not be capped at five books")
for i, path in ipairs(files) do assert(result[i] == path) end

print("PASS 1  FAIL 0")
