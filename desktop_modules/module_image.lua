-- module_image.lua - Simple UI
-- Shows a rotating image from a user-selected folder on the homescreen.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local ImageWidget     = require("ui/widget/imagewidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("sui_i18n").translate

local Config = require("sui_config")
local UI     = require("sui_core")
local PAD    = UI.PAD

local Screen = Device.screen

local SETTING_DIR       = "image_folder"
local SETTING_ROTATION  = "image_rotation"
local SETTING_HEIGHT    = "image_height"
local SETTING_WIDTH_PCT = "image_width_pct"

local DEFAULT_HEIGHT    = Screen:scaleBySize(96)
local DEFAULT_WIDTH_PCT = 100

local IMAGE_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, bmp = true, webp = true,
}

local _scan_cache_dir = nil
local _scan_cache_mtime = nil
local _scan_cache = nil

local M = {}

M.id          = "image"
M.name        = _("Image")
M.label       = _("Image")
M.enabled_key = "image"
M.default_on  = false

local function _key(pfx, suffix)
    return (pfx or "navbar_homescreen_") .. suffix
end

local function getFolder(pfx)
    return G_reader_settings:readSetting(_key(pfx, SETTING_DIR)) or ""
end

local function getRotation(pfx)
    return G_reader_settings:readSetting(_key(pfx, SETTING_ROTATION)) or "daily"
end

local function getHeightPx(pfx)
    return tonumber(G_reader_settings:readSetting(_key(pfx, SETTING_HEIGHT))) or DEFAULT_HEIGHT
end

local function getWidthPct(pfx)
    return tonumber(G_reader_settings:readSetting(_key(pfx, SETTING_WIDTH_PCT))) or DEFAULT_WIDTH_PCT
end

local function normalizeStartPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/$", "")
    if lfs.attributes(path, "mode") == "directory" then
        return path
    end
    local parent = path:match("^(.+)/[^/]+$")
    if parent and lfs.attributes(parent, "mode") == "directory" then
        return parent
    end
    return nil
end

local function scanImages(dir)
    if dir == "" or lfs.attributes(dir, "mode") ~= "directory" then
        return {}
    end

    local mtime = lfs.attributes(dir, "modification")
    if _scan_cache and _scan_cache_dir == dir and _scan_cache_mtime == mtime then
        return _scan_cache
    end

    local files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and not name:match("^%.") then
                local ext = name:match("%.([^%.]+)$")
                if ext and IMAGE_EXTS[ext:lower()] then
                    local path = dir .. "/" .. name
                    if lfs.attributes(path, "mode") == "file" then
                        files[#files + 1] = path
                    end
                end
            end
        end
    end
    table.sort(files)

    _scan_cache_dir = dir
    _scan_cache_mtime = mtime
    _scan_cache = files
    return files
end

local function pickImage(files, rotation)
    local n = #files
    if n == 0 then return nil end
    if rotation == "off" or n == 1 then
        return files[1]
    end
    local bucket
    if rotation == "hourly" then
        bucket = math.floor(os.time() / 3600)
    elseif rotation == "weekly" then
        bucket = math.floor(os.time() / (86400 * 7))
    else
        local t = os.date("*t")
        bucket = (t.year or 0) * 400 + (t.yday or 1)
    end
    return files[(bucket % n) + 1]
end

local function secondsUntilNextRotation(rotation)
    if rotation == "off" then return nil end
    local now = os.time()
    if rotation == "hourly" then
        return 3600 - (now % 3600) + 1
    end
    local t = os.date("*t", now)
    if rotation == "weekly" then
        local days_until_monday = (9 - (t.wday or 1)) % 7
        if days_until_monday == 0 then days_until_monday = 7 end
        local next_t = {
            year = t.year, month = t.month, day = t.day + days_until_monday,
            hour = 0, min = 0, sec = 1,
        }
        return math.max(60, os.time(next_t) - now)
    end
    local next_t = {
        year = t.year, month = t.month, day = t.day + 1,
        hour = 0, min = 0, sec = 1,
    }
    return math.max(60, os.time(next_t) - now)
end

local function scheduleRotationRefresh(ctx, rotation)
    local hs = ctx and ctx._hs_widget
    if not hs then return end
    if hs._image_module_timer then
        UIManager:unschedule(hs._image_module_timer)
        hs._image_module_timer = nil
    end
    local delay = secondsUntilNextRotation(rotation)
    if not delay then return end
    local timer
    timer = function()
        hs._image_module_timer = nil
        if hs._navbar_container and hs._refresh then
            hs:_refresh(true)
        end
    end
    hs._image_module_timer = timer
    UIManager:scheduleIn(delay, timer)
end

local function placeholder(w, h, text)
    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        dimen      = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text  = text,
                face  = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
                width = w - PAD * 2,
            },
        },
    }
end

function M.reset()
    _scan_cache_dir = nil
    _scan_cache_mtime = nil
    _scan_cache = nil
end

function M.build(w, ctx)
    local pfx = ctx.pfx
    Config.applyLabelToggle(M, _("Image"))

    local scale = Config.getModuleScale(M.id, pfx)
    local width_pct = math.max(10, math.min(100, getWidthPct(pfx)))
    local inner_w = math.floor((w - PAD * 2) * width_pct / 100)
    local h = math.max(Screen:scaleBySize(24), math.floor(getHeightPx(pfx) * scale))
    local folder = getFolder(pfx)
    local files = scanImages(folder)
    local rotation = getRotation(pfx)
    scheduleRotationRefresh(ctx, rotation)
    local path = pickImage(files, rotation)

    local child
    if path then
        local ok, img = pcall(function()
            return ImageWidget:new{
                file         = path,
                width        = inner_w,
                height       = h,
                scale_factor = 0,
            }
        end)
        child = ok and img or placeholder(inner_w, h, _("Image not available."))
    elseif folder == "" then
        child = placeholder(inner_w, h, _("Select an image folder."))
    else
        child = placeholder(inner_w, h, _("No images found."))
    end

    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        padding_left = PAD + math.floor(((w - PAD * 2) - inner_w) / 2),
        child,
    }
end

function M.getHeight(ctx)
    local pfx = ctx and ctx.pfx or ""
    local scale = Config.getModuleScale(M.id, pfx)
    return math.max(Screen:scaleBySize(24), math.floor(getHeightPx(pfx) * scale))
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._ or function(s) return s end

    local function chooseFolder()
        local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
        if not ok_pc or not PathChooser then return end
        local start_path = normalizeStartPath(getFolder(pfx))
            or normalizeStartPath(G_reader_settings:readSetting("lastdir"))
            or normalizeStartPath(G_reader_settings:readSetting("home_dir"))
            or "/"
        -- Open the chooser after the module menu has fully closed. Keeping the
        -- menu alive underneath PathChooser leaves KOReader in a bad input state
        -- on some devices and can make the file browser appear frozen.
        UIManager:scheduleIn(0.1, function()
            UIManager:show(PathChooser:new{
                covers_fullscreen = true,
                select_directory  = true,
                select_file       = false,
                show_files        = false,
                path              = start_path,
                onConfirm         = function(path)
                    G_reader_settings:saveSetting(_key(pfx, SETTING_DIR), path:gsub("/$", ""))
                    M.reset()
                    UIManager:scheduleIn(0, refresh)
                end,
            })
        end)
    end

    local function spinItem(text, title, info, get, set, min, max, step, unit, default)
        return {
            text_func      = text,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text    = title,
                    info_text     = info,
                    value         = get(),
                    value_min     = min,
                    value_max     = max,
                    value_step    = step,
                    unit          = unit,
                    ok_text       = _("Apply"),
                    cancel_text   = _("Cancel"),
                    default_value = default,
                    callback      = function(spin)
                        set(spin.value)
                        refresh()
                    end,
                })
            end,
        }
    end

    return {
        Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module."),
            get          = function() return Config.getModuleScalePct(M.id, pfx) end,
            set          = function(v) Config.setModuleScale(v, M.id, pfx) end,
            refresh      = refresh,
        }),
        Config.makeLabelToggleItem(M.id, _("Image"), refresh, _lc),
        {
            text_func      = function()
                local folder = getFolder(pfx)
                return folder ~= "" and (_lc("Image folder") .. " - " .. (folder:match("([^/]+)$") or folder))
                    or _lc("Image folder")
            end,
            callback       = chooseFolder,
        },
        spinItem(
            function() return _lc("Height") .. " - " .. tostring(getHeightPx(pfx)) .. " px" end,
            _lc("Height"),
            _lc("Height reserved for the image."),
            function() return getHeightPx(pfx) end,
            function(v) G_reader_settings:saveSetting(_key(pfx, SETTING_HEIGHT), v) end,
            Screen:scaleBySize(24), Screen:scaleBySize(360), Screen:scaleBySize(8), "px", DEFAULT_HEIGHT
        ),
        spinItem(
            function() return _lc("Width") .. " - " .. tostring(getWidthPct(pfx)) .. "%" end,
            _lc("Width"),
            _lc("Width of the image area."),
            function() return getWidthPct(pfx) end,
            function(v) G_reader_settings:saveSetting(_key(pfx, SETTING_WIDTH_PCT), v) end,
            10, 100, 5, "%", DEFAULT_WIDTH_PCT
        ),
        {
            text_func = function()
                local rotation = getRotation(pfx)
                local labels = {
                    off    = _lc("Off"),
                    hourly = _lc("Hourly"),
                    daily  = _lc("Daily"),
                    weekly = _lc("Weekly"),
                }
                return _lc("Rotation") .. " - " .. (labels[rotation] or labels.daily)
            end,
            sub_item_table = {
                {
                    text = _lc("Off"), radio = true,
                    checked_func = function() return getRotation(pfx) == "off" end,
                    callback = function() G_reader_settings:saveSetting(_key(pfx, SETTING_ROTATION), "off"); refresh() end,
                },
                {
                    text = _lc("Hourly"), radio = true,
                    checked_func = function() return getRotation(pfx) == "hourly" end,
                    callback = function() G_reader_settings:saveSetting(_key(pfx, SETTING_ROTATION), "hourly"); refresh() end,
                },
                {
                    text = _lc("Daily"), radio = true,
                    checked_func = function() return getRotation(pfx) == "daily" end,
                    callback = function() G_reader_settings:saveSetting(_key(pfx, SETTING_ROTATION), "daily"); refresh() end,
                },
                {
                    text = _lc("Weekly"), radio = true,
                    checked_func = function() return getRotation(pfx) == "weekly" end,
                    callback = function() G_reader_settings:saveSetting(_key(pfx, SETTING_ROTATION), "weekly"); refresh() end,
                },
            },
        },
    }
end

return M
