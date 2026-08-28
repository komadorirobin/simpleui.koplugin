-- Cached BookOrbit "Want to Read" data source for SimpleUI.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local SUISettings = require("infra/sui_store")

local CACHE_KEY = "simpleui_bookorbit_want_files"
local CACHE_AT_KEY = "simpleui_bookorbit_want_updated_at"
local MATCH_CACHE_KEY = "simpleui_bookorbit_want_id_paths"
local LOCAL_SCAN_AT_KEY = "simpleui_bookorbit_want_local_scan_at"
local LOCAL_SCAN_INTERVAL = 6 * 60 * 60
local AUTO_KEY = "simpleui_bookorbit_want_auto_refresh"
local M = {}
local _cached_files
local _cached_matches
local _cached_path_ids
local _running = false
local _listeners = {}
local _status_updates = {}
local _cache_generation = 0
local _connected

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

local function _sameMap(a, b)
    for key, value in pairs(a or {}) do
        if (b or {})[key] ~= value then return false end
    end
    for key, value in pairs(b or {}) do
        if (a or {})[key] ~= value then return false end
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

local function _loadMatchCache()
    if _cached_matches then return _cached_matches end
    local raw = SUISettings:readSetting(MATCH_CACHE_KEY)
    local clean = {}
    if type(raw) == "table" then
        for book_id, path in pairs(raw) do
            if _fileExists(path) then clean[tostring(book_id)] = path end
        end
    end
    _cached_matches = clean
    return clean
end

function M.getCachedFiles()
    return _copyList(_loadCache())
end

function M.getLastUpdated()
    return tonumber(SUISettings:readSetting(CACHE_AT_KEY))
end

function M.shouldAutoRefreshHome(pfx, module_enabled_key)
    pfx = pfx or "simpleui_hs_"
    module_enabled_key = module_enabled_key or "bookorbit_want_enabled"
    if not SUISettings:nilOrTrue(AUTO_KEY) then return false end
    if SUISettings:readSetting(pfx .. module_enabled_key) == true then return true end
    return SUISettings:readSetting(pfx .. "coverdeck_enabled") == true
        and SUISettings:readSetting(pfx .. "coverdeck_source") == "bookorbit_want"
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

local function _fallbackNormalize(value)
    value = tostring(value or "")
    local replacements = {
        ["À"] = "A", ["Á"] = "A", ["Â"] = "A", ["Ã"] = "A", ["Ä"] = "A", ["Å"] = "A",
        ["È"] = "E", ["É"] = "E", ["Ê"] = "E", ["Ë"] = "E",
        ["Ì"] = "I", ["Í"] = "I", ["Î"] = "I", ["Ï"] = "I",
        ["Ò"] = "O", ["Ó"] = "O", ["Ô"] = "O", ["Õ"] = "O", ["Ö"] = "O",
        ["Ù"] = "U", ["Ú"] = "U", ["Û"] = "U", ["Ü"] = "U",
        ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["å"] = "a",
        ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e",
        ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i",
        ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
        ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u",
        ["\226\128\152"] = "'", ["\226\128\153"] = "'",
        ["\226\128\147"] = "-", ["\226\128\148"] = "-",
    }
    for char, replacement in pairs(replacements) do
        value = value:gsub(char, replacement)
    end
    return value:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function _metadataKey(title, author, library_sync)
    if library_sync and type(library_sync.bookApiMatchKey) == "function" then
        local ok, key = pcall(library_sync.bookApiMatchKey, library_sync, title, author)
        if ok and type(key) == "string" and key ~= "" then return key end
    end
    local normalized_title = _fallbackNormalize(title)
    if normalized_title == "" then return nil end
    return normalized_title .. "|" .. _fallbackNormalize(author)
end

local function _bookAuthor(book)
    if type(book) ~= "table" then return "" end
    if type(book.authors) == "table" then
        local authors = {}
        for _, author in ipairs(book.authors) do
            local name = type(author) == "table" and (author.name or author.fullName) or author
            if type(name) == "string" and name ~= "" then authors[#authors + 1] = name end
        end
        if #authors > 0 then return table.concat(authors, ", ") end
    end
    return type(book.author) == "string" and book.author or ""
end

function M.librarySyncManifestMaps(manifest, file_exists, metadata_key)
    local by_book_id, id_candidates, metadata_candidates = {}, {}, {}
    file_exists = file_exists or _fileExists
    metadata_key = metadata_key or function(title, author)
        return _metadataKey(title, author)
    end
    for path, entry in pairs((type(manifest) == "table" and manifest.books) or {}) do
        if type(path) == "string" and type(entry) == "table"
                and entry.server_type == "bookorbit" and file_exists(path) then
            local timestamp = tonumber(entry.refreshed_at or entry.tracked_at) or 0
            local book_id = entry.bookorbit_book_id or entry.book_id or entry.bookId
            if book_id == nil and type(entry.remote_key) == "string" then
                book_id = entry.remote_key:match("^id:(%d+)$")
            end
            if book_id then
                book_id = tostring(book_id)
                local previous = id_candidates[book_id]
                if not previous or timestamp > previous.timestamp
                        or (timestamp == previous.timestamp and path < previous.path) then
                    id_candidates[book_id] = { path = path, timestamp = timestamp }
                end
            end

            local key = metadata_key(entry.title, entry.author)
            if key then
                local previous = metadata_candidates[key]
                if not previous then
                    metadata_candidates[key] = { path = path }
                elseif previous.path ~= path then
                    previous.ambiguous = true
                end
            end
        end
    end
    for book_id, candidate in pairs(id_candidates) do
        by_book_id[tonumber(book_id) or book_id] = candidate.path
    end
    local by_metadata = {}
    for key, candidate in pairs(metadata_candidates) do
        if not candidate.ambiguous then by_metadata[key] = candidate.path end
    end
    return by_book_id, by_metadata
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
    return M.librarySyncManifestMaps(manifest, file_exists)
end

local function _librarySyncMaps()
    local plugin = _pluginInstance("grimmorysync")
    if not plugin or type(plugin.loadManifest) ~= "function" then return plugin, {}, {} end
    local ok, manifest = pcall(plugin.loadManifest, plugin)
    if not ok or type(manifest) ~= "table" then return plugin, {}, {} end
    local function key(title, author)
        return _metadataKey(title, author, plugin)
    end
    local by_book_id, by_metadata = M.librarySyncManifestMaps(manifest, nil, key)
    return plugin, by_book_id, by_metadata
end

local function _rememberPathIds(path_ids, by_book_id)
    for book_id, path in pairs(by_book_id or {}) do
        if _fileExists(path) then path_ids[path] = tostring(book_id) end
    end
end

local function _loadPathIds()
    if _cached_path_ids then return _cached_path_ids end

    local path_ids = {}
    _rememberPathIds(path_ids, _loadMatchCache())

    local ok_sm, StateManager = pcall(require, "bookorbit_state_manager")
    if ok_sm and StateManager and type(StateManager.onDeviceMaps) == "function" then
        local ok_maps, maps = pcall(StateManager.onDeviceMaps)
        if ok_maps and type(maps) == "table" then
            _rememberPathIds(path_ids, maps.byBookId)
        end
    end

    local _, by_book_id = _librarySyncMaps()
    _rememberPathIds(path_ids, by_book_id)
    _cached_path_ids = path_ids
    return path_ids
end

function M.getBookId(filepath)
    if not _fileExists(filepath) then return nil end
    local book_id = _loadPathIds()[filepath]
    if book_id then return book_id end

    -- A Library Sync download may have completed since this cache was built.
    _cached_path_ids = nil
    return _loadPathIds()[filepath]
end

function M.isWantToRead(filepath)
    for _, path in ipairs(_loadCache()) do
        if path == filepath then return true end
    end
    return false
end

local function _updateLocalStatus(filepath, book_id, wanted)
    local files, found = _copyList(_loadCache()), false
    for i = #files, 1, -1 do
        if files[i] == filepath then
            found = true
            if not wanted then table.remove(files, i) end
        end
    end
    if wanted and not found then files[#files + 1] = filepath end

    local matches = {}
    for id, path in pairs(_loadMatchCache()) do matches[id] = path end
    matches[tostring(book_id)] = filepath

    _cached_files = files
    _cached_matches = matches
    _cached_path_ids = _cached_path_ids or {}
    _cached_path_ids[filepath] = tostring(book_id)
    _cache_generation = _cache_generation + 1
    SUISettings:setNoFlush(CACHE_KEY, files)
    SUISettings:setNoFlush(CACHE_AT_KEY, os.time())
    SUISettings:setNoFlush(MATCH_CACHE_KEY, matches)
    SUISettings:flush()
end

local function _notifyStatus(callback, result)
    if type(callback) ~= "function" then return end
    local function notify() pcall(callback, result) end
    if UIManager.nextTick then UIManager:nextTick(notify) else notify() end
end

local function _finishStatus(filepath, callback, result)
    _status_updates[filepath] = nil
    _notifyStatus(callback, result)
end

function M.setWantToRead(filepath, wanted, opts)
    opts = opts or {}
    wanted = wanted == true
    local callback = opts.on_done
    local book_id = M.getBookId(filepath)
    if not book_id then
        _notifyStatus(callback, { ok = false, error = "not_linked" })
        return false, "not_linked"
    end
    if _status_updates[filepath] then
        _notifyStatus(callback, { ok = false, error = "busy" })
        return false, "busy"
    end
    if not _connected() then
        _notifyStatus(callback, { ok = false, error = "offline" })
        return false, "offline"
    end

    _status_updates[filepath] = true
    UIManager:scheduleIn(opts.delay or 0, function()
        if not _connected() then
            _finishStatus(filepath, callback, { ok = false, error = "offline" })
            return
        end

        local function run()
            local plugin = _pluginInstance("bookorbit")
            if not plugin or type(plugin.newClient) ~= "function" then
                _finishStatus(filepath, callback, { ok = false, error = "bookorbit_unavailable" })
                return
            end
            if plugin.isLoggedIn and not plugin:isLoggedIn() then
                _finishStatus(filepath, callback, { ok = false, error = "not_configured" })
                return
            end

            local ok_client, client = pcall(plugin.newClient, plugin)
            if not ok_client or not client then
                _finishStatus(filepath, callback, { ok = false, error = "client_unavailable" })
                return
            end
            if type(client.catalogSetReadStatus) ~= "function"
                    or type(client.runInSubprocess) ~= "function" then
                _finishStatus(filepath, callback, { ok = false, error = "bookorbit_update_required" })
                return
            end

            local status = wanted and "want_to_read" or "unread"
            local completed, result = client:runInSubprocess(function()
                return client:catalogSetReadStatus(book_id, status)
            end)
            if not completed then
                _finishStatus(filepath, callback, { ok = false, error = "cancelled" })
                return
            end
            if not result or not result.body then
                _finishStatus(filepath, callback, {
                    ok = false,
                    error = result and result.err or "request_failed",
                })
                return
            end

            local ok_sm, StateManager = pcall(require, "bookorbit_state_manager")
            if ok_sm and StateManager and type(StateManager.applyLibraryVersion) == "function"
                    and result.body.libraryVersion then
                pcall(StateManager.applyLibraryVersion, result.body.libraryVersion)
            end
            _updateLocalStatus(filepath, book_id, wanted)
            _finishStatus(filepath, callback, {
                ok = true,
                wanted = wanted,
                book_id = book_id,
                changed = true,
            })
        end

        local function protectedRun()
            local ok, err = pcall(run)
            if not ok and _status_updates[filepath] then
                logger.warn("simpleui: BookOrbit Want to Read update failed:", tostring(err))
                _finishStatus(filepath, callback, { ok = false, error = tostring(err) })
            end
        end

        local ok_trapper, Trapper = pcall(require, "ui/trapper")
        if ok_trapper and Trapper and Trapper.wrap then
            Trapper:wrap(protectedRun)
        else
            protectedRun()
        end
    end)
    return true
end

function M.isStatusUpdateRunning(filepath)
    return _status_updates[filepath] == true
end

local function _localLibraryMatches(client, library_sync, books)
    if not library_sync or type(library_sync.scanLocalBooks) ~= "function"
            or type(library_sync.buildLocalBookIndex) ~= "function"
            or type(library_sync.findLocalMatch) ~= "function" then
        return {}, false
    end
    local completed, result = client:runInSubprocess(function()
        local local_books = library_sync:scanLocalBooks()
        local local_index = library_sync:buildLocalBookIndex(local_books)
        local matches = {}
        for _, book in ipairs(books or {}) do
            local book_id = book.id
            if book_id ~= nil then
                local remote = {
                    title = book.title,
                    author = _bookAuthor(book),
                    series = book.seriesName,
                    series_index = book.seriesIndex,
                }
                local match = library_sync:findLocalMatch(remote, local_index)
                if match and match.path then matches[tostring(book_id)] = match.path end
            end
        end
        return matches
    end)
    if not completed or not result or type(result.body) ~= "table" then return {}, true end
    return result.body, true
end

_connected = function()
    local ok, value = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok and value == true
end

local function _fetch(force_local_scan)
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
        local books = {}
        -- Want to Read is a dashboard source in BookOrbit, not a valid value
        -- for the ordinary catalog's readStatus filter.
        local body, err = client:catalogDashboardSection("want-to-read")
        if not body then return nil, err end
        local section = type(body.section) == "table" and body.section or nil
        if not section or type(section.books) ~= "table" then
            return nil, "invalid_response"
        end
        for _, book in ipairs(section.books) do
            if book.id ~= nil then books[#books + 1] = book end
        end
        local computed_maps
        if not maps_ready then
            computed_maps = StateManager.computeOnDeviceMaps()
        end
        return { books = books, computed_maps = computed_maps }
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

    local library_sync, by_book_id, by_metadata = _librarySyncMaps()
    for book_id, path in pairs(_loadMatchCache()) do
        by_book_id[book_id] = path
    end
    for book_id, path in pairs(maps.byBookId or {}) do
        by_book_id[book_id] = path
    end

    local unresolved = {}
    for _, book in ipairs(payload.books or {}) do
        local book_id = book.id
        local numeric_id = tonumber(book_id)
        local path = by_book_id[book_id] or (numeric_id and by_book_id[numeric_id])
            or by_book_id[tostring(book_id)]
        if not _fileExists(path) then
            path = by_metadata[_metadataKey(book.title, _bookAuthor(book), library_sync)]
            if _fileExists(path) then
                by_book_id[tostring(book_id)] = path
            else
                unresolved[#unresolved + 1] = book
            end
        end
    end

    local scan_performed = false
    local last_scan = tonumber(SUISettings:readSetting(LOCAL_SCAN_AT_KEY)) or 0
    if #unresolved > 0 and (force_local_scan or os.time() - last_scan >= LOCAL_SCAN_INTERVAL) then
        local local_matches
        local_matches, scan_performed = _localLibraryMatches(client, library_sync, unresolved)
        for book_id, path in pairs(local_matches) do
            if _fileExists(path) then by_book_id[tostring(book_id)] = path end
        end
    end

    local ids, matched_ids = {}, {}
    for _, book in ipairs(payload.books or {}) do ids[#ids + 1] = book.id end
    local files = M.mapBookIdsToFiles(ids, by_book_id)
    for _, book in ipairs(payload.books or {}) do
        local book_id = book.id
        local numeric_id = tonumber(book_id)
        local path = by_book_id[book_id] or (numeric_id and by_book_id[numeric_id])
            or by_book_id[tostring(book_id)]
        if _fileExists(path) then matched_ids[tostring(book_id)] = path end
    end
    return files, nil, math.max(0, #(payload.books or {}) - #files), matched_ids, scan_performed
end

local function _notifyListeners(result)
    local listeners = _listeners
    _listeners = {}
    local function notify()
        for _, listener in ipairs(listeners) do pcall(listener, result) end
    end
    if UIManager.nextTick then UIManager:nextTick(notify) else notify() end
end

local function _finish(files, err, skipped, matches, scan_performed, started_generation)
    _running = false
    if not files then
        logger.warn("simpleui: BookOrbit Want to Read refresh failed:", tostring(err))
        _notifyListeners{ ok = false, error = err }
        return
    end

    if started_generation ~= nil and started_generation ~= _cache_generation then
        _notifyListeners{
            ok = true,
            changed = false,
            count = #_loadCache(),
            skipped = skipped or 0,
            stale = true,
        }
        return
    end

    local old = _loadCache()
    local changed = not _sameList(old, files)
    local old_matches = _loadMatchCache()
    local matches_changed = not _sameMap(old_matches, matches or {})
    _cached_files = files
    _cached_matches = matches or {}
    _cached_path_ids = nil
    SUISettings:setNoFlush(CACHE_KEY, files)
    SUISettings:setNoFlush(CACHE_AT_KEY, os.time())
    SUISettings:setNoFlush(MATCH_CACHE_KEY, _cached_matches)
    if scan_performed then SUISettings:setNoFlush(LOCAL_SCAN_AT_KEY, os.time()) end
    if changed or matches_changed or scan_performed then SUISettings:flush() end
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
    local started_generation = _cache_generation
    UIManager:scheduleIn(opts.delay or 0.1, function()
        if not _connected() then
            _finish(nil, "offline")
            return
        end
        local function run()
            local ok, files, err, skipped, matches, scan_performed = pcall(_fetch, opts.force_local_scan)
            if not ok then
                _finish(nil, tostring(files))
            else
                _finish(files, err, skipped, matches, scan_performed, started_generation)
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
    _cached_matches = nil
    _cached_path_ids = nil
    _running = false
    _listeners = {}
    _status_updates = {}
    _cache_generation = 0
end

return M

