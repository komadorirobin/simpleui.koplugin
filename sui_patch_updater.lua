-- sui_patch_updater.lua — OTA updater for SimpleUI companion patches.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")
local _           = require("sui_i18n").translate

local M = {}

local PATCH_NAME     = "Bento Grid Patch"
local PATCH_FILE     = "2-simpleui-bento-grid.lua"
local RAW_URL        = "https://raw.githubusercontent.com/komadorirobin/koreader-patches/main/" .. PATCH_FILE
local VERSION_PATTERN = 'BENTO_GRID_PATCH_VERSION%s*=%s*"([^"]+)"'

local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+$")
    or "/mnt/us/koreader/plugins/simpleui.koplugin"

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

local function _versionGt(a, b)
    if not b or b == "" then return true end
    local function parts(v)
        v = (v or ""):match("^v?(.-)[-+]") or (v or ""):match("^v?(.+)$") or ""
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) or 0 end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] > pb[i] then return true end
        if pa[i] < pb[i] then return false end
    end
    return false
end

local function _readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local body = fh:read("*a")
    fh:close()
    return body
end

local function _parseVersion(body)
    if type(body) ~= "string" then return nil end
    return body:match(VERSION_PATTERN)
end

local function _koreaderDir()
    return _plugin_dir:match("^(.*)/plugins/[^/]+$")
        or _plugin_dir:match("^(.+)/[^/]+$")
        or _plugin_dir
end

local function _patchesDir()
    return _koreaderDir() .. "/patches"
end

local function _patchPath()
    return _patchesDir() .. "/" .. PATCH_FILE
end

local function _ensureDir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then return false, "lfs unavailable" end
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then return true end
    if mode and mode ~= "directory" then return false, "path exists but is not a directory" end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        local ok, err = _ensureDir(parent)
        if not ok then return nil, err end
    end
    local ok, err = lfs.mkdir(path)
    if ok or lfs.attributes(path, "mode") == "directory" then return true end
    return false, err or "mkdir failed"
end

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local code, headers, status = socket.skip(1, http.request({
        url     = url,
        method  = "GET",
        headers = {
            ["User-Agent"] = "KOReader-SimpleUI-Patch-Updater/1.0",
            ["Accept"]     = "text/plain",
        },
        sink     = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return table.concat(chunks) end
    return nil, string.format("HTTP %s", tostring(code))
end

local function _doFetch()
    local body, err = _httpGet(RAW_URL)
    if not body then return { error = err } end
    local version = _parseVersion(body)
    if not version then return { error = "remote version missing" } end
    if not body:find("Bento Grid Layout Engine", 1, true) then
        return { error = "remote file did not look like the Bento Grid patch" }
    end
    return {
        body = body,
        version = version,
        current_version = _parseVersion(_readFile(_patchPath())),
        path = _patchPath(),
    }
end

local function _writePatch(body)
    local dir = _patchesDir()
    local ok_dir, err_dir = _ensureDir(dir)
    if not ok_dir then return nil, "cannot create patches dir: " .. tostring(err_dir) end

    local target = _patchPath()
    local tmp = target .. ".tmp"
    local fh, err_open = io.open(tmp, "wb")
    if not fh then return nil, "cannot write temp file: " .. tostring(err_open) end
    fh:write(body)
    fh:close()

    local ok_rename, err_rename = os.rename(tmp, target)
    if not ok_rename then
        pcall(os.remove, tmp)
        return nil, "cannot replace patch file: " .. tostring(err_rename)
    end
    return true
end

local function _installPatch(release)
    local progress_msg = _toast(string.format(_("Installing %s…"), PATCH_NAME), 120)
    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doInstall()
        local ok, err = _writePatch(release.body)
        if not ok then return { success = false, err = err } end
        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            logger.err("simpleui patch updater: install failed:", result and result.err)
            _toast(_("Patch install error: ") .. tostring(result and result.err or "unknown error"))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("%s %s installed.\n\nRestart KOReader to load the patch?"),
                PATCH_NAME,
                release.version
            ),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doInstall,
            progress_msg,
            function(res) handleInstallResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            _toast(_("Patch update cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doInstall())
        end)
    end
end

local function _showPatchDialog(release)
    local current = release.current_version
    local has_update = current == nil or _versionGt(release.version, current)

    if not has_update then
        _toast(string.format(_("%s is up to date (%s)."), PATCH_NAME, current))
        return
    end

    local current_text = current or _("not installed")
    UIManager:show(ConfirmBox:new{
        text = string.format(
            _("%s %s is available.\nYou have %s.\n\nInstall to:\n%s\n\nRestart is required after installation."),
            PATCH_NAME,
            release.version,
            current_text,
            release.path
        ),
        ok_text = _("Install"),
        cancel_text = _("Cancel"),
        ok_callback = function() _installPatch(release) end,
    })
end

function M.checkBentoGridPatch()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            M._doManualCheck()
        end)
        return
    end
    M._doManualCheck()
end

function M._doManualCheck()
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    local checking_msg = _toast(_("Checking Bento Grid patch…"), 15)

    local function handleFetchResult(result)
        _closeWidget(checking_msg)
        if not result then
            _toast(_("Error checking patch update."))
            return
        end
        if result.error then
            logger.err("simpleui patch updater:", result.error)
            _toast(_("Error checking patch update: ") .. tostring(result.error))
            return
        end
        _showPatchDialog(result)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            _doFetch,
            checking_msg,
            function(res) handleFetchResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleFetchResult(result) end)
        elseif completed == false then
            _closeWidget(checking_msg)
            _toast(_("Patch update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleFetchResult(_doFetch())
        end)
    end
end

return M
