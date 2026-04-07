-- 2-simpleui-hardcover.lua
-- Registers the Hardcover desktop module in SimpleUI's module registry.
--
-- INSTALLATION
--   Copy this file to koreader/patches/
--   (e.g. /mnt/us/koreader/patches/ on Kindle,
--         /mnt/onboard/.adds/koreader/patches/ on Kobo)
--
--   module_hardcover.lua must be present in the plugin's desktop_modules/
--   directory.  It is bundled with the komadorirobin fork and does not need
--   to be moved.
--
-- HOW IT WORKS
--   Primary strategy — direct MODULES injection:
--     Uses debug.getupvalue to locate the MODULES table that is an upvalue of
--     _load() inside moduleregistry.lua, then appends the hardcover entry to
--     it.  This is equivalent to editing moduleregistry.lua directly, but
--     survives upstream OTA updates because the patch lives outside the plugin.
--
--   Fallback strategy — method wrapping:
--     If the debug library cannot find the upvalues (e.g. bytecode-only build),
--     falls back to wrapping Registry.list() / Registry.get() so that hardcover
--     is included in every call.
--
--   Teardown handling:
--     Registry.invalidate() is also wrapped so that module_hardcover is evicted
--     from package.loaded at teardown time, ensuring that OTA-updated module
--     code is picked up on the next reload cycle rather than serving a stale
--     in-memory copy.
--
--   Hot-reload support:
--     A package.preload interceptor re-applies the patch every time SimpleUI
--     evicts and re-requires the registry (which happens on plugin teardown /
--     hot-reload).

local logger = require("logger")
logger.dbg("simpleui-patch: loading hardcover registry patch")

local _REGISTRY_KEY  = "desktop_modules/moduleregistry"
local _HARDCOVER_KEY = "desktop_modules/module_hardcover"
-- Entry that would normally live in the MODULES table in moduleregistry.lua.
local _HC_ENTRY = { require_mod = _HARDCOVER_KEY }

-- ---------------------------------------------------------------------------
-- Upvalue helper
-- ---------------------------------------------------------------------------

--- Returns the value of the first upvalue named @name in function @fn,
--- or nil if not found.
local function _getupvalue(fn, name)
    for i = 1, 200 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v end
    end
end

-- ---------------------------------------------------------------------------
-- Primary strategy: inject _HC_ENTRY directly into the MODULES upvalue
-- that _load() iterates.  After this, _load() discovers hardcover just like
-- any built-in module — _loaded AND _by_id are both populated correctly.
-- Returns true on success, false on failure.
-- ---------------------------------------------------------------------------
local function _injectIntoModules(Registry)
    -- _load is an upvalue of Registry.list (it is called inside list()).
    local _load_fn = _getupvalue(Registry.list, "_load")
    if type(_load_fn) ~= "function" then
        logger.warn("simpleui-patch: hardcover: _load upvalue not found in Registry.list")
        return false
    end
    -- MODULES is an upvalue of _load (it is the table iterated in _load()).
    local modules = _getupvalue(_load_fn, "MODULES")
    if type(modules) ~= "table" then
        logger.warn("simpleui-patch: hardcover: MODULES upvalue not found in _load")
        return false
    end
    -- Idempotent: skip when the entry is already present (upstream may have
    -- added native support, or the patch ran twice on the same table).
    for _, def in ipairs(modules) do
        if def.require_mod == _HARDCOVER_KEY then
            logger.dbg("simpleui-patch: hardcover already in MODULES — skipping injection")
            return true
        end
    end
    -- Insert before quick_actions (the last module in the default list) so
    -- hardcover lands in a sensible default position.
    table.insert(modules, #modules, _HC_ENTRY)
    -- Invalidate the registry cache so the next Registry.list() / .get() call
    -- re-runs _load() with the updated MODULES table, populating both
    -- _loaded and _by_id with the hardcover entry.
    Registry.invalidate()
    logger.dbg("simpleui-patch: hardcover injected into MODULES at position " .. #modules)
    return true
end

-- ---------------------------------------------------------------------------
-- Fallback strategy: wrap Registry.list() and Registry.get().
-- Used when debug.getupvalue cannot reach the MODULES upvalue.
-- ---------------------------------------------------------------------------
local function _wrapRegistryMethods(Registry)
    local _hc_mod    = nil
    local _hc_tried  = false

    local function _getHC()
        if _hc_tried then return _hc_mod end
        _hc_tried = true
        local ok, HC = pcall(require, _HARDCOVER_KEY)
        if ok and type(HC) == "table" and type(HC.id) == "string" then
            _hc_mod = HC
            logger.dbg("simpleui-patch: hardcover loaded via require (fallback), id=" .. HC.id)
        else
            logger.warn("simpleui-patch: hardcover: require(" .. _HARDCOVER_KEY .. ") failed: " .. tostring(HC))
        end
        return _hc_mod
    end

    local orig_list = Registry.list
    Registry.list = function()
        local mods = orig_list()
        local HC = _getHC()
        if not HC then return mods end
        for _, m in ipairs(mods) do
            if m.id == HC.id then return mods end   -- already present
        end
        mods[#mods + 1] = HC
        return mods
    end

    local orig_get = Registry.get
    Registry.get = function(id)
        local m = orig_get(id)
        if m then return m end
        local HC = _getHC()
        if HC and HC.id == id then return HC end
        return nil
    end

    logger.dbg("simpleui-patch: hardcover registry methods wrapped (fallback path)")
end

-- ---------------------------------------------------------------------------
-- Core patch entry-point: applies whichever strategy succeeds, then always
-- wraps Registry.invalidate() for teardown eviction.
-- ---------------------------------------------------------------------------
local function _patchRegistry(Registry)
    -- Try direct MODULES injection first; fall back to method wrapping.
    local injected = _injectIntoModules(Registry)
    if not injected then
        _wrapRegistryMethods(Registry)
    end

    -- Wrap Registry.invalidate() so that module_hardcover is evicted from
    -- package.loaded at teardown.  Without this, OTA-updated code in
    -- module_hardcover.lua would not be picked up until a full KOReader
    -- restart (the stale require() result would keep serving the old object).
    -- NOTE: Registry.invalidate() is only called during plugin teardown
    -- (sui_patches.lua teardownAll), so this does not add overhead elsewhere.
    local _orig_invalidate = Registry.invalidate
    Registry.invalidate = function()
        package.loaded[_HARDCOVER_KEY] = nil
        return _orig_invalidate()
    end

    logger.dbg("simpleui-patch: hardcover patch installed (injected=" .. tostring(injected) .. ")")
end

-- ---------------------------------------------------------------------------
-- Preload interceptor: re-applies the patch on every (re-)load of the
-- registry module so that plugin hot-reload cycles are handled correctly.
-- SimpleUI's onTeardown() evicts "desktop_modules/moduleregistry" from
-- package.loaded; the next require() of the registry hits this interceptor,
-- which loads a fresh registry and patches it before returning it to the
-- caller.
-- ---------------------------------------------------------------------------
local _orig_preload = package.preload[_REGISTRY_KEY]

local function _myLoader(...)
    -- Restore previous preload (normally nil) so the inner require below
    -- finds the file via package.path instead of calling us recursively.
    package.preload[_REGISTRY_KEY] = _orig_preload
    -- Clear any require-loop sentinel that a caller's require() may have
    -- placed in package.loaded before invoking us.
    package.loaded[_REGISTRY_KEY] = nil
    -- Load the real registry module.
    local Registry = require(_REGISTRY_KEY)
    -- Patch it; pcall ensures a patching failure never prevents the registry
    -- from being returned to the caller.
    local ok, err = pcall(_patchRegistry, Registry)
    if not ok then
        logger.warn("simpleui-patch: hardcover: patching failed: " .. tostring(err))
    end
    -- Re-install so the next hot-reload cycle is also intercepted.
    package.preload[_REGISTRY_KEY] = _myLoader
    return Registry
end

package.preload[_REGISTRY_KEY] = _myLoader

-- If the registry is already cached (patch executed after plugin init —
-- unusual but possible), patch the live object directly as well.
if package.loaded[_REGISTRY_KEY] then
    local ok, err = pcall(_patchRegistry, package.loaded[_REGISTRY_KEY])
    if not ok then
        logger.warn("simpleui-patch: hardcover: live patching failed: " .. tostring(err))
    end
end
