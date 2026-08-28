-- sui_bookorbit_want.lua -- cached BookOrbit "Want to Read" data source.
--
-- The homescreen always reads a local filepath cache. A refresh is scheduled
-- after the screen is already visible and BookOrbit performs the HTTP request
-- in its subprocess, so neither startup nor repaint waits for the server.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local SUISettings = require("infra/sui_store")

local CACHE_KEY = "simpleui_bookorbit_want_files"
local CACHE_AT_KEY = "simpleui_bookorbit_want_updated_at"
local PAGE_SIZE = 100
local MAX_PAGES = 100

local M = {}
local _cached_files
local _running = false
local _listeners = {}

local function _copyList(list)
    local copy = {}
    for i, value in ipairs(list or {}) do copy[i] = value end
    return copy
end

local function _sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function _fileExists(path)
    return type(path) == "string" and path ~= ""
        and lfs.attributes(path, "mode") == "file"
end

local function _loadCache()
    if _cached_files then return _cached_files end
    local raw = SUISettings:readSetting(CACHE_KEY)
    local clean, seen = {}, {}
    if type(raw) == "table" then
        for _, path in ipairs(raw) do
            if _fileExists(path) and not seen[path] then
                seen[path] = true
                clean[#clean + 1] = path
            end
        end
    end
    _cached_files = clean
    return clean
end

function M.getCachedFiles()
    return _copyList(_loadCache())
end

function M.getLastUpdated()
    return tonumber(SUISettings:readSetting(CACHE_AT_KEY))
end

-- Pure mapping helper kept public for regression tests. BookOrbit's state map
-- normally uses numeric ids, while decoded API fixtures may use strings.
function M.mapBookIdsToFiles(book_ids, by_book_id, file_exists)
    local files, seen = {}, {}
    file_exists = file_exists or _fileExists
    by_book_id = type(by_book_id) == "table" and by_book_id or {}
    for _, raw_id in ipairs(book_ids or {}) do
        local numeric_id = tonumber(raw_id)
        local path = by_book_id[raw_id]
            or (numeric_id and by_book_id[numeric_id])
            or by_book_id[tostring(raw_id)]
        if path and not seen[path] and file_exists(path) then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    return files
end

local function _pluginInstance()
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader or not PluginLoader.getPluginInstance then
        return nil
    end
    local ok_instance, plugin = pcall(PluginLoader.getPluginInstance, PluginLoader, "bookorbit")
    if ok_instance then return plugin end
    return nil
end

local function _connected()
    local ok, value = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok and value == true
end

local function _fetch()
    local plugin = _pluginInstance()
    if not plugin or not plugin.newClient then return nil, "bookorbit_unavailable" end
    if plugin.isLoggedIn and not plugin:isLoggedIn() then return nil, "not_configured" end

    local ok_sm, StateManager = pcall(require, "bookorbit_state_manager")
    if not ok_sm or not StateManager then return nil, "bookorbit_unavailable" end

    local ok_client, client = pcall(plugin.newClient, plugin)
    if not ok_client or not client then return nil, "client_unavailable" end

    local maps_ready = false
    local ok_ready, ready = pcall(StateManager.hasOnDeviceMaps)
    if ok_ready then maps_ready = ready == true end

    -- One subprocess owns every page and, when needed, the local-state scan.
    -- This avoids one process launch per page and keeps a large matched library
    -- off Android's five-second UI thread.
    local completed, result = client:runInSubprocess(function()
        local ids = {}
        for page = 1, MAX_PAGES do
            local body, err = client:catalogBooks{
                page = page,
                size = PAGE_SIZE,
                sort = "recently_added",
                order = "desc",
                readStatus = "want_to_read",
            }
            if not body then return nil, err end
            for _, book in ipairs(body.items or {}) do
                if book.id ~= nil then ids[#ids + 1] = book.id end
            end
            if body.hasNext ~= true then
                local computed_maps
                if not maps_ready then
                    computed_maps = StateManager.computeOnDeviceMaps()
                end
                return { book_ids = ids, computed_maps = computed_maps }
            end
        end
        return nil, "too_many_pages"
    end)

    if not completed then return nil, "cancelled" end
    if not result or not result.body then
        return nil, result and result.err or "request_failed"
    end

    local payload = result.body
    if payload.computed_maps then
        local adopted, adopt_err = StateManager.adoptOnDeviceMaps(payload.computed_maps)
        if not adopted then return nil, adopt_err or "stale_generation" end
    end

    local ok_maps, maps = pcall(StateManager.onDeviceMaps)
    if not ok_maps or not maps then return nil, "local_map_unavailable" end

    local files = M.mapBookIdsToFiles(payload.book_ids, maps.byBookId)
    return files, nil, math.max(0, #(payload.book_ids or {}) - #files)
end

local function _notifyListeners(result)
    local listeners = _listeners
    _listeners = {}
    local function notify()
        for _, listener in ipairs(listeners) do
            pcall(listener, result)
        end
    end
    if UIManager.nextTick then UIManager:nextTick(notify) else notify() end
end

local function _finish(files, err, skipped)
    _running = false
    if not files then
        logger.warn("simpleui: BookOrbit Want to Read refresh failed:", tostring(err))
        _notifyListeners{ ok = false, error = err }
        return
    end

    local old = _loadCache()
    local changed = not _sameList(old, files)
    _cached_files = files
    SUISettings:setNoFlush(CACHE_KEY, files)
    SUISettings:setNoFlush(CACHE_AT_KEY, os.time())
    if changed then SUISettings:flush() end
    _notifyListeners{
        ok = true,
        changed = changed,
        count = #files,
        skipped = skipped or 0,
    }
end

-- Starts one invisible refresh. Concurrent homescreen opens subscribe to the
-- same job instead of launching duplicate HTTP requests.
function M.requestRefresh(opts)
    opts = opts or {}
    if type(opts.on_done) == "function" then
        _listeners[#_listeners + 1] = opts.on_done
    end
    if _running then return true, "running" end
    if not _connected() then
        _notifyListeners{ ok = false, error = "offline" }
        return false, "offline"
    end

    _running = true
    UIManager:scheduleIn(opts.delay or 0.1, function()
        if not _connected() then
            _finish(nil, "offline")
            return
        end
        local function run()
            local ok, files, err, skipped = pcall(_fetch)
            if not ok then
                _finish(nil, tostring(files))
            else
                _finish(files, err, skipped)
            end
        end
        local ok_trapper, Trapper = pcall(require, "ui/trapper")
        if ok_trapper and Trapper and Trapper.wrap then
            Trapper:wrap(run)
        else
            run()
        end
    end)
    return true
end

function M.isRefreshing()
    return _running
end

function M._resetForTests()
    _cached_files = nil
    _running = false
    _listeners = {}
end

return M
