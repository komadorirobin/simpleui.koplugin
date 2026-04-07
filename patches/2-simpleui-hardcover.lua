-- 2-simpleui-hardcover.lua
-- Registers the SimpleUI Hardcover module in the SimpleUI module registry.
--
-- INSTALLATION
--   Copy this file to koreader/patches/
--   The Hardcover module file (desktop_modules/module_hardcover.lua) must exist
--   inside the simpleui.koplugin directory. It is part of the plugin delivery and
--   does not need to be moved.
--
-- HOW IT WORKS
--   SimpleUI's moduleregistry caches the list of desktop modules at first access.
--   This patch intercepts the registry both at load-time (via package.preload) and
--   live (if the registry was already loaded when the patch ran), then wraps
--   Registry.list() and Registry.get() so the Hardcover module is always present.
--   The wrapper survives Registry.invalidate() and plugin hot-reloads.

local logger = require("logger")
logger.dbg("simpleui-patch: loading hardcover registry patch")

local _REGISTRY_KEY  = "desktop_modules/moduleregistry"
local _HARDCOVER_KEY = "desktop_modules/module_hardcover"

-- ---------------------------------------------------------------------------
-- Core patch: wraps Registry.list() and Registry.get() on a live Registry
-- object so the Hardcover module is always included.
-- ---------------------------------------------------------------------------
local function _patchRegistry(Registry)
    -- Try loading the Hardcover module once (result cached in _hc_mod).
    local _hc_mod         = nil
    local _hc_load_tried  = false

    local function getHC()
        if _hc_load_tried then return _hc_mod end
        _hc_load_tried = true
        local ok, HC = pcall(require, _HARDCOVER_KEY)
        if ok and HC and type(HC.id) == "string" then
            _hc_mod = HC
            logger.dbg("simpleui-patch: hardcover module loaded, id=" .. tostring(HC.id))
        else
            logger.warn("simpleui-patch: failed to load hardcover module: " .. tostring(HC))
        end
        return _hc_mod
    end

    local orig_list = Registry.list
    local orig_get  = Registry.get

    -- list(): ensure hardcover is appended to the internal _loaded table that
    -- orig_list() returns.  Since _loaded IS the returned table, appending to
    -- it is persistent across subsequent list() calls in the same session.
    -- After Registry.invalidate() + a fresh list() call, _loaded is rebuilt
    -- from MODULES and the append runs again.
    Registry.list = function()
        local mods = orig_list()
        local HC = getHC()
        if not HC then return mods end
        for _, m in ipairs(mods) do
            -- Already present: either upstream has added hardcover natively, or
            -- this is a repeat list() call within the same session (where _loaded
            -- is cached and already contains our previously-appended entry).
            if m.id == HC.id then return mods end
        end
        mods[#mods + 1] = HC
        return mods
    end

    -- get(): fall back to our Hardcover module when the upstream registry
    -- does not know the id (i.e. "hardcover" is not in its _by_id table).
    Registry.get = function(id)
        local m = orig_get(id)
        if m then return m end
        local HC = getHC()
        if HC and HC.id == id then return HC end
        return nil
    end

    logger.dbg("simpleui-patch: hardcover registry patch installed")
end

-- ---------------------------------------------------------------------------
-- Apply the patch: live if registry is already loaded, or via preload so
-- it is applied every time the registry module is (re-)required.
-- ---------------------------------------------------------------------------
if package.loaded[_REGISTRY_KEY] then
    -- Registry already in cache — patch it directly.
    _patchRegistry(package.loaded[_REGISTRY_KEY])
end

-- Intercept future loads (including plugin hot-reload cycles where
-- SimpleUI evicts package.loaded entries on teardown).
local _orig_preload = package.preload[_REGISTRY_KEY]

local function _myLoader(...)
    -- Temporarily restore the original preload to avoid infinite recursion.
    package.preload[_REGISTRY_KEY] = _orig_preload
    -- Load the original registry module.
    local Registry = require(_REGISTRY_KEY)
    -- Apply our patch to the freshly-loaded Registry object.
    _patchRegistry(Registry)
    -- Re-install our wrapper so subsequent hot-reload cycles are also patched.
    package.preload[_REGISTRY_KEY] = _myLoader
    return Registry
end

package.preload[_REGISTRY_KEY] = _myLoader
