package.path = "./?.lua;./?/init.lua;" .. package.path

local notices = {}
local closed

package.loaded["ui/uimanager"] = {
    close = function(_self, widget) closed = widget end,
}
package.loaded["ui/widget/confirmbox"] = {}
package.loaded["logger"] = {
    dbg = function() end,
    info = function() end,
    warn = function() end,
    err = function() end,
}
package.loaded["infra/sui_i18n"] = {
    translate = function(text) return text end,
}
package.loaded["infra/sui_core"] = {
    Notify = {
        toast = function(text, timeout)
            local widget = { text = text, timeout = timeout }
            notices[#notices + 1] = widget
            return widget
        end,
    },
}
package.loaded["infra/sui_paths"] = {
    getPluginDirNoSlash = function() return "/tmp/simpleui.koplugin" end,
}
package.loaded["ui/trapper"] = {
    dismissableRunInSubprocess = function() return false end,
}

local Updater = dofile("infra/sui_updater.lua")
Updater._doManualBranchCheck("beta", "2.7.1-beta.5")

assert(#notices == 2, "branch cancellation should show start and cancellation notices")
assert(notices[1].text == "Checking for updates…")
assert(notices[1].timeout == 15)
assert(notices[2].text == "Update check cancelled.")
assert(notices[2].timeout == 4)
assert(closed == notices[1], "checking notice should be closed on cancellation")

print("PASS updater branch notifications")
