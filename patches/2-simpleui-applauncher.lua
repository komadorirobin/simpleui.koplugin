-- 2-simpleui-applauncher.lua
-- Registers the App Launcher desktop module in SimpleUI's module registry.
--
-- INSTALLATION
--   This file ships in koreader/patches/ as part of the komadorirobin fork.
--   No manual copying is required.
--
--   module_app_launcher.lua must be present in the plugin's desktop_modules/
--   directory (it is bundled with this fork).
--
-- HOW IT WORKS
--   Identical strategy to 2-simpleui-hardcover.lua:
--     Primary  — inject the entry directly into the MODULES upvalue inside
--                _load() via debug.getupvalue.
--     Fallback — wrap Registry.list() / Registry.get() when the upvalue is
--                not reachable (e.g. bytecode-only builds).
--   Registry.invalidate() is also wrapped to evict module_app_launcher from
--   package.loaded on teardown, ensuring updated code is picked up on reload.
--   A package.preload interceptor re-applies the patch on every hot-reload.

local logger = require("logger")
logger.dbg("simpleui-patch: loading app-launcher registry patch")

local _REGISTRY_KEY    = "desktop_modules/moduleregistry"
local _LAUNCHER_KEY    = "desktop_modules/module_app_launcher"
local _LAUNCHER_ENTRY  = { require_mod = _LAUNCHER_KEY }

-- ---------------------------------------------------------------------------
-- Upvalue helper (same as in 2-simpleui-hardcover.lua)
-- ---------------------------------------------------------------------------

local function _getupvalue(fn, name)
    for i = 1, 200 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v end
    end
end

-- ---------------------------------------------------------------------------
-- Primary strategy: inject directly into MODULES upvalue
-- ---------------------------------------------------------------------------

local function _injectIntoModules(Registry)
    local _load_fn = _getupvalue(Registry.list, "_load")
    if type(_load_fn) ~= "function" then
        logger.warn("simpleui-patch: app-launcher: _load upvalue not found in Registry.list")
        return false
    end
    local modules = _getupvalue(_load_fn, "MODULES")
    if type(modules) ~= "table" then
        logger.warn("simpleui-patch: app-launcher: MODULES upvalue not found in _load")
        return false
    end
    -- Idempotent check
    for _, def in ipairs(modules) do
        if def.require_mod == _LAUNCHER_KEY then
            logger.dbg("simpleui-patch: app-launcher already in MODULES — skipping injection")
            return true
        end
    end
    -- Insert before the last module (quick_actions) so it sits in a sensible position.
    table.insert(modules, #modules, _LAUNCHER_ENTRY)
    Registry.invalidate()
    logger.dbg("simpleui-patch: app-launcher injected into MODULES at position " .. #modules)
    return true
end

-- ---------------------------------------------------------------------------
-- Fallback strategy: wrap Registry.list() / Registry.get()
-- ---------------------------------------------------------------------------

local function _wrapRegistryMethods(Registry)
    local _mod       = nil
    local _tried     = false

    local function _getMod()
        if _tried then return _mod end
        _tried = true
        local ok, AL = pcall(require, _LAUNCHER_KEY)
        if ok and type(AL) == "table" and type(AL.id) == "string" then
            _mod = AL
            logger.dbg("simpleui-patch: app-launcher loaded via require (fallback), id=" .. AL.id)
        else
            logger.warn("simpleui-patch: app-launcher: require(" .. _LAUNCHER_KEY .. ") failed: " .. tostring(AL))
        end
        return _mod
    end

    local orig_list = Registry.list
    Registry.list = function()
        local mods = orig_list()
        local AL = _getMod()
        if not AL then return mods end
        for _, m in ipairs(mods) do
            if m.id == AL.id then return mods end
        end
        mods[#mods + 1] = AL
        return mods
    end

    local orig_get = Registry.get
    Registry.get = function(id)
        local m = orig_get(id)
        if m then return m end
        local AL = _getMod()
        if AL and AL.id == id then return AL end
        return nil
    end

    logger.dbg("simpleui-patch: app-launcher registry methods wrapped (fallback path)")
end

-- ---------------------------------------------------------------------------
-- Core patch entry-point
-- ---------------------------------------------------------------------------

local function _patchRegistry(Registry)
    local injected = _injectIntoModules(Registry)
    if not injected then
        _wrapRegistryMethods(Registry)
    end

    -- Evict module_app_launcher from package.loaded on teardown so that
    -- updated Lua code is picked up after an OTA update.
    local _orig_invalidate = Registry.invalidate
    Registry.invalidate = function()
        package.loaded[_LAUNCHER_KEY] = nil
        return _orig_invalidate()
    end

    logger.dbg("simpleui-patch: app-launcher patch installed (injected=" .. tostring(injected) .. ")")
end

-- ---------------------------------------------------------------------------
-- Preload interceptor — handles plugin hot-reload cycles
-- ---------------------------------------------------------------------------

local _orig_preload = package.preload[_REGISTRY_KEY]

local function _myLoader(...)
    package.preload[_REGISTRY_KEY] = _orig_preload
    package.loaded[_REGISTRY_KEY]  = nil
    local Registry = require(_REGISTRY_KEY)
    local ok, err  = pcall(_patchRegistry, Registry)
    if not ok then
        logger.warn("simpleui-patch: app-launcher: patching failed: " .. tostring(err))
    end
    package.preload[_REGISTRY_KEY] = _myLoader
    return Registry
end

package.preload[_REGISTRY_KEY] = _myLoader

-- Patch the live registry if the registry was already loaded before this patch ran.
if package.loaded[_REGISTRY_KEY] then
    local ok, err = pcall(_patchRegistry, package.loaded[_REGISTRY_KEY])
    if not ok then
        logger.warn("simpleui-patch: app-launcher: live patching failed: " .. tostring(err))
    end
end
