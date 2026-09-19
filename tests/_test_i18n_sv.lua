package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["logger"] = { info = function() end }
package.loaded["infra/sui_paths"] = { getPluginDir = function() return "./" end }
package.loaded["gettext"] = setmetatable({}, {
    __call = function(_self, text) return text end,
})
local native_gettext = package.loaded["gettext"]
G_reader_settings = { readSetting = function() return "sv_SE" end }

local I18n = dofile("infra/sui_i18n.lua")
local expected = {
    ["BookOrbit Want to Read"] = "BookOrbit Vill l\195\164sa",
    ["Recent Books"] = "P\195\165g\195\165ende b\195\182cker",
    ["New Books"] = "Nya b\195\182cker",
    ["Remove from Recent Books"] = "Ta bort fr\195\165n P\195\165g\195\165ende b\195\182cker",
    ["Search library"] = "S\195\182k i biblioteket",
    ["Search results: %1"] = "S\195\182kresultat: %1",
}
for source, translated in pairs(expected) do
    assert(I18n.translate(source) == translated, "Swedish translation lost: " .. source)
end
assert(I18n.ngettext("day streak", "days streak", 1) == "dag i rad")
assert(I18n.ngettext("day streak", "days streak", 2) == "dagar i rad")
assert(package.loaded["gettext"] == native_gettext, "translation must not replace KOReader's gettext")

print("PASS Swedish fork translations")
