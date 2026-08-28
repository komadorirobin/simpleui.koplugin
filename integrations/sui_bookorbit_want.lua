-- Cached BookOrbit "Want to Read" data source for the legacy/beta UI.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local SUISettings = require("sui_store")

local CACHE_KEY = "simpleui_bookorbit_want_files"
local CACHE_AT_KEY = "simpleui_bookorbit_want_updated_at"
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

local function _pluginInstance(name)
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader or not PluginLoader.getPluginInstance then
        return nil
    end
    local ok_instance, plugin = pcall(PluginLoader.getPluginInstance, PluginLoader, name)
    if ok_instance then return plugin end
    return nil
end

function M.librarySyncBookIdMap(manifest, file_exists)
    local by_book_id, candidates = {}, {}
    file_exists = file_exists or _fileExists
    for path, entry in pairs((type(manifest) == "table" and manifest.books) or {}) do
        if type(path) == "string" and type(entry) == "table"
                and entry.server_type == "bookorbit" and file_exists(path) then
            local book_id = type(entry.remote_key) == "string"
                and entry.remote_key:match("^id:(%d+)$") or nil
            if book_id then
                local timestamp = tonumber(entry.refreshed_at or entry.tracked_at) or 0
                local previous = candidates[book_id]
                if not previous or timestamp > previous.timestamp
                        or (timestamp == previous.timestamp and path < previous.path) then
                    candidates[book_id] = { path = path, timestamp = timestamp }
                end
            end
        end
    end
    for book_id, candidate in pairs(candidates) do
        by_book_id[tonumber(book_id) or book_id] = candidate.path
    end
    return by_book_id
end

local function _librarySyncBookIdMap()
    local plugin = _pluginInstance("grimmorysync")
    if not plugin or type(plugin.loadManifest) ~= "function" then return {} end
    local ok, manifest = pcall(plugin.loadManifest, plugin)
    if not ok or type(manifest) ~= "table" then return {} end
    return M.librarySyncBookIdMap(manifest)
end

local function _connected()
    local ok, value = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok and value == true
end

local function _fetch()
    local plugin = _pluginInstance("bookorbit")
    if not plugin or not plugin.newClient then return nil, "bookorbit_unavailable" end
    if plugin.isLoggedIn and not plugin:isLoggedIn() then return nil, "not_configured" end

    local ok_sm, StateManager = pcall(require, "bookorbit_state_manager")
    if not ok_sm or not StateManager then return nil, "bookorbit_unavailable" end

    local ok_client, client = pcall(plugin.newClient, plugin)
    if not ok_client or not client then return nil, "client_unavailable" end
    if type(client.catalogDashboardSection) ~= "function" then
        return nil, "bookorbit_update_required"
    end

    local maps_ready = false
    local ok_ready, ready = pcall(StateManager.hasOnDeviceMaps)
    if ok_ready then maps_ready = ready == true end

    local completed, result = client:runInSubprocess(function()
        local ids = {}
        -- Want to Read is a dashboard source in BookOrbit, not a valid value
        -- for the ordinary catalog's readStatus filter.
        local body, err = client:catalogDashboardSection("want-to-read")
        if not body then return nil, err end
        local section = type(body.section) == "table" and body.section or nil
        if not section or type(section.books) ~= "table" then
            return nil, "invalid_response"
        end
        for _, book in ipairs(section.books) do
            if book.id ~= nil then ids[#ids + 1] = book.id end
        end
        local computed_maps
        if not maps_ready then
            computed_maps = StateManager.computeOnDeviceMaps()
        end
        return { book_ids = ids, computed_maps = computed_maps }
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

    local by_book_id = _librarySyncBookIdMap()
    for book_id, path in pairs(maps.byBookId or {}) do
        by_book_id[book_id] = path
    end
    local files = M.mapBookIdsToFiles(payload.book_ids, by_book_id)
    return files, nil, math.max(0, #(payload.book_ids or {}) - #files)
end

local function _notifyListeners(result)
    local listeners = _listeners
    _listeners = {}
    local function notify()
        for _, listener in ipairs(listeners) do pcall(listener, result) end
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
