-- module_tbr.lua — Simple UI
-- Module: To Be Read (TBR).
-- Shows up to 5 books marked by the user as "to be read".
-- The TBR list is stored in G_reader_settings["sui_tbr_list"] as
-- an ordered array of filepaths: { fp1, fp2, ... } (max. 5).
--
-- Entry points for marking books:
--   • Hold on a book in the Library (single-file dialog)  → via main.lua
--
-- Public API used by main.lua / sui_patches.lua:
--   M.getTBRList()                                       → { fp, ... }
--   M.getTBRCount()                                      → number
--   M.isTBR(filepath)                                    → bool
--   M.addTBR(filepath)                                   → bool
--   M.removeTBR(filepath)
--   M.genTBRButton(file, close_cb)                       → button table

local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local UIManager       = require("ui/uimanager")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")

local logger = require("logger")
local _SH    = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_tbr: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config = require("sui_config")
local UI     = require("sui_core")
local PAD    = UI.PAD

local TBR_MAX     = 5
local TBR_SETTING = "sui_tbr_list"  -- ordered array of filepaths

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function getTBRList()
    local raw = G_reader_settings:readSetting(TBR_SETTING)
    if type(raw) ~= "table" then return {} end
    -- Filter out entries whose files no longer exist on disk.
    local clean = {}
    for _, fp in ipairs(raw) do
        if type(fp) == "string" and lfs.attributes(fp, "mode") == "file" then
            clean[#clean + 1] = fp
        end
    end
    return clean
end

local function saveTBRList(list)
    G_reader_settings:saveSetting(TBR_SETTING, list)
end

local function getTBRCount()
    return #getTBRList()
end

local function isTBR(filepath)
    for _, fp in ipairs(getTBRList()) do
        if fp == filepath then return true end
    end
    return false
end

--- Adds a book to the TBR list.
--- Returns true on success, false if the list already has TBR_MAX entries.
local function addTBR(filepath)
    local list = getTBRList()
    for _, fp in ipairs(list) do
        if fp == filepath then return true end  -- already present
    end
    if #list >= TBR_MAX then return false end
    list[#list + 1] = filepath
    saveTBRList(list)
    return true
end

local function removeTBR(filepath)
    local list = getTBRList()
    local new  = {}
    for _, fp in ipairs(list) do
        if fp ~= filepath then new[#new + 1] = fp end
    end
    saveTBRList(new)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "tbr"
M.name        = _("To Be Read")
M.label       = _("To Be Read")
M.enabled_key = "tbr"
M.default_on  = false

function M.reset() _SH = nil end

-- Public API
M.getTBRList  = getTBRList
M.getTBRCount = getTBRCount
M.isTBR       = isTBR
M.addTBR      = addTBR
M.removeTBR   = removeTBR

-- ---------------------------------------------------------------------------
-- genTBRButton — button for the single-book hold dialog.
-- Follows the same pattern as filemanagerutil.genStatusButtonsRow buttons.
-- ---------------------------------------------------------------------------
function M.genTBRButton(file, close_cb)
    local in_tbr    = isTBR(file)
    local count     = getTBRCount()
    local indicator = string.format("(%d/%d)", count, TBR_MAX)
    local full      = (not in_tbr) and (count >= TBR_MAX)

    return {
        text    = (in_tbr and _("Remove from To Be Read") or _("Add to To Be Read"))
                  .. "  " .. indicator,
        enabled = not full,
        callback = function()
            if in_tbr then removeTBR(file) else addTBR(file) end
            if close_cb then close_cb() end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("To Be Read"))

    local tbr_fps = ctx._tbr_fps
    if not tbr_fps then
        tbr_fps = getTBRList()
        ctx._tbr_fps = tbr_fps
    end

    if #tbr_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("tbr", ctx.pfx)
    local thumb_scale = Config.getThumbScale("tbr", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)

    local cols    = math.min(#tbr_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local fp    = tbr_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, cw, ch)

        -- No progress bar, no percentage — just the cover.
        local cell = VerticalGroup:new{
            align = "center",
            cover,
        }

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = D.RECENT_H },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- getHeight
-- ---------------------------------------------------------------------------

function M.getHeight(_ctx)
    local SH = getSH()
    local D  = SH.getDims(Config.getModuleScale("tbr", _ctx and _ctx.pfx),
                           Config.getThumbScale("tbr", _ctx and _ctx.pfx))
    -- Cell is cover only (no progress bar / label), so height = cover height.
    return D.RECENT_H
end

-- ---------------------------------------------------------------------------
-- getMenuItems
-- ---------------------------------------------------------------------------

local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("tbr", pfx) end,
        set          = function(v) Config.setModuleScale(v, "tbr", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

-- Returns a short display title for a filepath.
local function _getBookTitle(fp)
    local title = fp:match("([^/]+)%.[^%.]+$") or fp
    pcall(function()
        local DS = require("docsettings")
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            local rp = ds:readSetting("doc_props") or {}
            if rp.title and rp.title ~= "" then title = rp.title end
            pcall(function() ds:close() end)
        end
    end)
    if #title > 48 then title = title:sub(1, 45) .. "…" end
    return title
end

function M.getMenuItems(ctx_menu)
    local _lc      = ctx_menu._
    local refresh  = ctx_menu.refresh
    local SortWidget = ctx_menu.SortWidget
    local _UIManager = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage

    local items = {}

    items[#items + 1] = _makeScaleItem(ctx_menu)
    items[#items + 1] = Config.makeLabelToggleItem("tbr", _("To Be Read"), refresh, _lc)

    -- Arrange TBR list — SortWidget with covers_fullscreen, same as Collections.
    items[#items + 1] = {
        text         = _lc("Arrange To Be Read list"),
        enabled_func = function() return getTBRCount() > 1 end,
        keep_menu_open = true,
        callback = function()
            local list = getTBRList()
            if #list < 2 then
                _UIManager:show(InfoMessage:new{
                    text = _lc("Add at least 2 books to arrange."), timeout = 2 })
                return
            end
            local sort_items = {}
            for _, fp in ipairs(list) do
                sort_items[#sort_items + 1] = {
                    text     = _getBookTitle(fp),
                    filepath = fp,
                    mandatory = "",
                }
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Arrange To Be Read list"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    local new_list = {}
                    for _, item in ipairs(sort_items) do
                        if item.filepath then
                            new_list[#new_list + 1] = item.filepath
                        end
                    end
                    saveTBRList(new_list)
                    refresh()
                end,
            })
        end,
    }

    -- Separator before book list (same visual pattern as Collections).
    items[#items + 1] = { text = _lc("To Be Read books"), enabled = false, separator = true }

    -- One checkbox entry per book in the TBR list.
    local list = getTBRList()
    if #list == 0 then
        items[#items + 1] = { text = _lc("No books in To Be Read list."), enabled = false }
    else
        for _, fp in ipairs(list) do
            local _fp    = fp
            local _title = _getBookTitle(fp)
            items[#items + 1] = {
                text           = _title,
                checked_func   = function() return isTBR(_fp) end,
                keep_menu_open = true,
                callback       = function()
                    removeTBR(_fp)
                    refresh()
                end,
            }
        end
    end

    return items
end

return M
