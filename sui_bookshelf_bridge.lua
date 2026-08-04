-- sui_bookshelf_bridge.lua — optional coordination with bookshelf.koplugin.
--
-- SimpleUI can open books without Bookshelf being involved. When Bookshelf's
-- "instant close" prewarm is enabled, tell it about that open explicitly so it
-- can prepare the matching shelf in the background instead of guessing from
-- reader hooks.

local UIManager = require("ui/uimanager")
local Event     = require("ui/event")
local logger    = require("logger")
local SUISettings = require("sui_store")

local M = {}

local HOME_PREWARM_IDLE_S = 5
local HOME_PREWARM_POLL_S = 1
local _home_last_input = 0
local _home_token = nil

local function _now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end

local function _installHomeInputStamp()
    if UIManager._simpleui_bookshelf_home_input_stamp or not UIManager.sendEvent then
        return
    end
    UIManager._simpleui_bookshelf_home_input_stamp = true
    local orig = UIManager.sendEvent
    UIManager.sendEvent = function(self_um, event, ...)
        local handler = type(event) == "table" and event.handler
        if handler == "onGesture" or handler == "onKeyPress"
                or handler == "onKeyRepeat" then
            _home_last_input = _now()
        end
        return orig(self_um, event, ...)
    end
end

local function _isTopmost(widget)
    local stack = UIManager._window_stack
    if not stack then return false end
    for i = #stack, 1, -1 do
        local entry = stack[i]
        if entry and entry.widget then return entry.widget == widget end
    end
    return false
end

local PROFILE_ACTIONS = {
    prose = {
        bookshelf_prose = true,
        bookshelf_prose_menu = true,
        open_bookshelf_prose = true,
        open_bookshelf_prose_start_menu = true,
    },
    comics = {
        bookshelf_comics = true,
        bookshelf_comics_menu = true,
        open_bookshelf_comics = true,
        open_bookshelf_comics_start_menu = true,
    },
}

-- Resolve the actual navbar slot for a Bookshelf profile. The slot may be a
-- built-in Bookshelf action or a user-created Quick Action whose dispatcher
-- target opens that profile.
function M.resolveProfileTab(profile_key, tabs)
    local targets = PROFILE_ACTIONS[profile_key]
    if not (targets and type(tabs) == "table") then return nil end
    for _, action_id in ipairs(tabs) do
        if targets[action_id] then return action_id end
        if type(action_id) == "string" and action_id:match("^custom_qa_%d+$") then
            local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}
            if targets[cfg.dispatcher_action] then return action_id end
        end
    end
    return nil
end

-- Bookshelf calls this before rendering SimpleUI's embedded dock. Keeping the
-- state on the live plugin also means subsequent navbar rebuilds retain the
-- correct underline instead of falling back to Home.
function M.activateProfile(profile_key, plugin, tabs)
    if type(plugin) ~= "table" then return nil end
    local action_id = M.resolveProfileTab(profile_key, tabs)
    if action_id then plugin.active_action = action_id end
    return action_id
end

function M.prepareReturn(filepath, source)
    if type(filepath) ~= "string" or filepath == "" then return end
    source = source or "simpleui"

    -- Capture the live SimpleUI host before ReaderUI closes FileManager. The
    -- references remain valid long enough for Bookshelf to build an embedded
    -- dock during reader prewarm; without them the dock can only appear after
    -- the real idle close recreates FileManager.
    local simpleui_bar_host
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance or nil
    local plugin = fm and fm._simpleui_plugin
    if fm and plugin then
        simpleui_bar_host = { fm = fm, plugin = plugin }
    end

    local function emit(attempt)
        local RUI = package.loaded["apps/reader/readerui"]
        local readerui = RUI and RUI.instance
        local live_file = readerui and readerui.document and readerui.document.file
        if readerui and live_file then
            local ok, err = pcall(function()
                local payload = {
                    file = live_file,
                    requested_file = filepath,
                    source = source,
                    simpleui_bar_host = simpleui_bar_host,
                }
                -- ReaderUI registers reader plugins directly by plugin name.
                -- Prefer the active Bookshelf instance: window-stack event
                -- propagation differs between KOReader versions and may miss
                -- dynamically loaded modules.
                local bookshelf = readerui.bookshelf
                if bookshelf and bookshelf.onPrepareBookshelfReturn then
                    bookshelf:onPrepareBookshelfReturn(payload, source)
                else
                    UIManager:broadcastEvent(Event:new(
                        "PrepareBookshelfReturn", payload))
                end
            end)
            if not ok then
                logger.warn("simpleui: bookshelf prepare return failed:",
                    tostring(err))
            end
            return
        end

        if attempt < 10 then
            UIManager:scheduleIn(0.5, function() emit(attempt + 1) end)
        end
    end

    UIManager:scheduleIn(0.5, function() emit(0) end)
end

-- Ask Bookshelf to warm its shared repository caches after the SimpleUI Home
-- screen has been genuinely idle. No Bookshelf widget is created here: the
-- real profile remains unknown until the user taps Books or Manga.
function M.scheduleHomePrewarm(homescreen)
    if type(homescreen) ~= "table" then return end
    if _home_token and _home_token.homescreen == homescreen then return end

    _installHomeInputStamp()
    _home_last_input = _now()
    local token = { homescreen = homescreen }
    _home_token = token

    local function isAlive()
        local Homescreen = package.loaded["sui_homescreen"]
        return _home_token == token
            and Homescreen and Homescreen._instance == homescreen
            and UIManager:isWidgetShown(homescreen)
    end

    local function isActive()
        return isAlive() and _isTopmost(homescreen)
    end

    local function probe()
        if not isAlive() then return end
        if not isActive() or (_now() - _home_last_input) < HOME_PREWARM_IDLE_S then
            UIManager:scheduleIn(HOME_PREWARM_POLL_S, probe)
            return
        end

        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FM and FM.instance or nil
        local bookshelf = fm and fm.bookshelf
        local payload = {
            source = "simpleui_homescreen",
            homescreen = homescreen,
            is_alive = isAlive,
            is_active = isActive,
            last_input_at = function() return _home_last_input end,
        }
        local delivered = false
        if bookshelf and type(bookshelf.onPrepareBookshelfHome) == "function" then
            local ok, accepted = pcall(bookshelf.onPrepareBookshelfHome,
                bookshelf, payload)
            delivered = ok and accepted ~= false
            if not ok then
                logger.warn("simpleui: bookshelf Home preload failed:",
                    tostring(accepted))
            end
        end
        if not delivered then
            local ok = pcall(function()
                UIManager:broadcastEvent(Event:new("PrepareBookshelfHome", payload))
            end)
            delivered = ok
        end
        if delivered then
            token.delivered = true
        else
            UIManager:scheduleIn(HOME_PREWARM_POLL_S, probe)
        end
    end

    UIManager:scheduleIn(HOME_PREWARM_POLL_S, probe)
end

function M.cancelHomePrewarm(homescreen)
    if not homescreen or (_home_token and _home_token.homescreen == homescreen) then
        _home_token = nil
    end
end

return M
