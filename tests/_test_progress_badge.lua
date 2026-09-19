package.path = "./?.lua;./?/init.lua;" .. package.path

local function widget(_self, opts) return opts end
for _, name in ipairs({
    "ui/bidi", "ffi/blitbuffer", "ui/widget/container/centercontainer",
    "ui/font", "ui/widget/container/framecontainer", "ui/geometry",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/size",
    "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/verticalgroup",
    "ui/widget/verticalspan", "libs/libkoreader-lfs", "util", "infra/sui_config",
}) do
    package.loaded[name] = { new = widget }
end
package.loaded["device"] = { screen = { scaleBySize = function(_self, value) return value end } }
package.loaded["features/sui_style"] = { BADGE_BORDER_SZ = 2 }
local library_color = "dark"
local calls, last_desc = 0, nil
package.loaded["features/library/sui_foldercovers"] = {
    getBadgeColorProgress = function() return library_color end,
}
package.loaded["features/library/sui_cover_widgets"] = {
    buildProgressBadgeDesc = function(size, status, percent, border, dark)
        calls = calls + 1
        last_desc = { size = size, status = status, percent = percent, border = border, dark = dark }
        return last_desc
    end,
    buildProgressBadgeWidget = function(desc)
        return { desc = desc, getSize = function() return { w = desc.size, h = desc.size + 2 } end }
    end,
}

local Shared = dofile("modules/module_books_shared.lua")
local cover = {}
assert(Shared.applyProgressBadge(cover, { percent = 0 }, 100, 150) == cover)
assert(calls == 0, "unread covers must not gain a badge")

local progress = { percent = 0.52, status = "reading" }
local result = Shared.applyProgressBadge(cover, progress, 100, 150)
assert(result[1] == cover and result.dimen.w == 100 and result.dimen.h == 150)
assert(last_desc.size == 14 and last_desc.border == 2 and last_desc.dark == true)
assert(result[2].overlap_offset[1] == 78 and result[2].overlap_offset[2] == 0)

library_color = "light"
Shared.buildProgressBadgeWidget(progress, 20)
assert(last_desc.dark == false, "unset color follows the library")
Shared.buildProgressBadgeWidget(progress, 20, "dark")
assert(last_desc.dark == true, "explicit color overrides the library")
Shared.buildProgressBadgeWidget(progress, 20, "light")
assert(last_desc.dark == false)

for _, status in ipairs({ "complete", "abandoned" }) do
    assert(Shared.buildProgressBadgeWidget({ percent = 0, status = status }, 14))
    assert(last_desc.status == status, "terminal status must reach the badge builder")
end

result = Shared.applyProgressBadge(cover, progress, 30, 120, nil, 100, 150)
assert(last_desc.size == 11, "peek badge uses full cover dimensions, not its narrow crop")
assert(result[2].overlap_offset[1] == 13 and result[2].overlap_offset[2] == 0)

local real_builder = Shared.buildProgressBadgeWidget
Shared.buildProgressBadgeWidget = function() return nil end
assert(Shared.applyProgressBadge(cover, progress, 100, 150) == cover)
Shared.buildProgressBadgeWidget = real_builder

print("PASS shared progress badges")
