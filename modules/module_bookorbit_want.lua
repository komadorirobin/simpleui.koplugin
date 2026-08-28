-- module_bookorbit_want.lua -- BookOrbit Want to Read homescreen module.

local _ = require("infra/sui_i18n").translate

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local GridRenderer = require("engines/sui_book_grid")
local SUISettings = require("infra/sui_store")
local BookOrbitWant = require("integrations/sui_bookorbit_want")

local ID = "bookorbit_want"
local CACHE_KEY = "_bookorbit_want_fps"
local AUTO_KEY = "simpleui_bookorbit_want_auto_refresh"

local function _refreshScreen(screen)
    if not screen then return end
    local shown = true
    if UIManager.isWidgetShown then
        local ok, value = pcall(UIManager.isWidgetShown, UIManager, screen)
        shown = ok and value == true
    end
    if not shown then return end

    if screen._ctx_cache then
        screen._ctx_cache[CACHE_KEY] = nil
        screen._ctx_cache["_row_page_" .. ID] = 1
    end
    if screen._book_mod_slots and screen._book_mod_slots[ID]
            and screen._refreshBookModSlot and screen:_refreshBookModSlot(ID) then
        return
    end
    if screen._refreshImmediate then screen:_refreshImmediate(true) end
end

local function _resultText(result)
    if result.ok then
        if (result.skipped or 0) > 0 then
            return string.format(_("BookOrbit Want to Read updated: %d books (%d could not be matched)."),
                result.count or 0, result.skipped)
        end
        return string.format(_("BookOrbit Want to Read updated: %d books."), result.count or 0)
    end
    if result.error == "offline" then return _("BookOrbit refresh skipped: offline.") end
    if result.error == "not_configured" then return _("BookOrbit is not configured.") end
    if result.error == "bookorbit_unavailable" then return _("BookOrbit plugin is not available.") end
    return _("Could not refresh BookOrbit Want to Read.")
end

local function _menuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    return {
        {
            text = _("Refresh from BookOrbit now"),
            keep_menu_open = true,
            callback = function()
                BookOrbitWant.requestRefresh{
                    delay = 0,
                    on_done = function(result)
                        if result.ok and result.changed then refresh() end
                        UIManager:show(InfoMessage:new{ text = _resultText(result), timeout = 4 })
                    end,
                }
            end,
        },
        {
            text = _("Refresh whenever Home opens"),
            checked_func = function() return SUISettings:nilOrTrue(AUTO_KEY) end,
            keep_menu_open = true,
            callback = function()
                SUISettings:saveSetting(AUTO_KEY, not SUISettings:nilOrTrue(AUTO_KEY))
            end,
        },
    }
end

local M = GridRenderer.makeModule{
    id          = ID,
    name        = _("BookOrbit Want to Read"),
    label       = _("BookOrbit Want to Read"),
    default_on  = false,
    is_book_mod = true,
    max_items   = 5,
    paged       = true,
    cache_key   = CACHE_KEY,
    getFileList = BookOrbitWant.getCachedFiles,
    extra_menu_items_before = _menuItems,

    grid         = true,
    default_rows = 1,
    default_cols = 5,

    progress_style = { default = "none" },
    badges = { pages = "off", series = "off", new = "locked_off" },
    reset = function() GridRenderer.reset() end,
}

function M.scheduleAutoRefresh(screen, pfx)
    pfx = pfx or "simpleui_hs_"
    if not SUISettings:nilOrTrue(AUTO_KEY) then return false end
    local enabled = SUISettings:readSetting(pfx .. M.enabled_key)
    if enabled ~= true then return false end
    return BookOrbitWant.requestRefresh{
        on_done = function(result)
            if result.ok and result.changed then _refreshScreen(screen) end
        end,
    }
end

M.getCachedFiles = BookOrbitWant.getCachedFiles
M.refreshNow = BookOrbitWant.requestRefresh

return M
