-- SimpleUI-only exclusions for the Recent Books module.
--
-- KOReader's Reset action clears document state, but deliberately leaves the
-- file in ReadHistory.  Keep these exclusions separate so hiding an
-- accidentally opened book does not alter reading progress or global history.

local SUISettings = require("infra/sui_store")

local M = {}

local SETTING_KEY = "simpleui_recent_hidden"
local MAX_HIDDEN = 100

local function _read()
    local value = SUISettings:readSetting(SETTING_KEY)
    return type(value) == "table" and value or {}
end

local function _count(value)
    local n = 0
    for _ in pairs(value) do n = n + 1 end
    return n
end

local function _trim(value)
    while _count(value) > MAX_HIDDEN do
        local oldest_fp
        local oldest_at
        for fp, hidden_at in pairs(value) do
            local timestamp = tonumber(hidden_at) or 0
            if oldest_at == nil or timestamp < oldest_at then
                oldest_fp = fp
                oldest_at = timestamp
            end
        end
        if not oldest_fp then break end
        value[oldest_fp] = nil
    end
end

function M.snapshot()
    return _read()
end

function M.isHidden(file)
    if not file then return false end
    return _read()[file] ~= nil
end

function M.hide(file)
    if not file or file == "" then return false end
    local hidden = _read()
    hidden[file] = os.time()
    _trim(hidden)
    SUISettings:saveSetting(SETTING_KEY, hidden)
    return true
end

function M.clear()
    SUISettings:delSetting(SETTING_KEY)
end

function M.count()
    return _count(_read())
end

return M
