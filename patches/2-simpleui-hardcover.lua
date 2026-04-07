-- 2-simpleui-hardcover.lua
-- Registers the SimpleUI Hardcover module in the SimpleUI module registry.
--
-- INSTALLATION
--   Copy this file to koreader/patches/
--
--   module_hardcover.lua must be reachable in ONE of two ways (first match wins):
--     A) It ships inside simpleui.koplugin/desktop_modules/ — no extra step needed
--        when using the komadorirobin fork which bundles the file.
--     B) Copy desktop_modules/module_hardcover.lua from this repo into the same
--        koreader/patches/ directory as this patch file.  Use this option when
--        running a fork that does not bundle module_hardcover.lua (e.g.
--        doctorhetfield-cmd).
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

-- Capture the directory that contains this patch file so we can look for
-- module_hardcover.lua next to it as a fallback (option B above).
local _patch_dir = (function()
    local info = debug.getinfo(1, "S")
    if info and type(info.source) == "string" and info.source:sub(1, 1) == "@" then
        -- source is "@/absolute/path/to/2-simpleui-hardcover.lua"
        return info.source:sub(2):match("^(.+[/\\])[^/\\]+$") or ""
    end
    return ""
end)()

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

        -- ── Option A: standard require (works when the file lives inside the
        --             plugin's desktop_modules/ directory on package.path).
        local ok, HC = pcall(require, _HARDCOVER_KEY)
        if ok and HC and type(HC.id) == "string" then
            _hc_mod = HC
            logger.dbg("simpleui-patch: hardcover module loaded via require, id=" .. tostring(HC.id))
            return _hc_mod
        end

        -- ── Option B: load from the patches directory (fallback for forks that
        --             don't ship module_hardcover.lua in the plugin directory).
        if _patch_dir ~= "" then
            local alt_file = _patch_dir .. "module_hardcover.lua"
            local fh = io.open(alt_file, "r")
            if fh then
                fh:close()
                local ok2, HC2 = pcall(dofile, alt_file)
                if ok2 and HC2 and type(HC2.id) == "string" then
                    -- Register in package.loaded so subsequent require() calls
                    -- return this same instance without re-executing the file.
                    package.loaded[_HARDCOVER_KEY] = HC2
                    _hc_mod = HC2
                    logger.dbg("simpleui-patch: hardcover module loaded from patches dir, id=" .. tostring(HC2.id))
                    return _hc_mod
                else
                    logger.warn("simpleui-patch: dofile(" .. alt_file .. ") failed: " .. tostring(HC2))
                end
            end
        end

        logger.warn("simpleui-patch: failed to load hardcover module — "
            .. "copy module_hardcover.lua to koreader/patches/ (see patch header)")
        return nil
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
    -- Restore original preload so the inner require below doesn't recurse
    -- back into us.
    package.preload[_REGISTRY_KEY] = _orig_preload
    -- Lua's require() sets package.loaded[name] = true (a sentinel) BEFORE
    -- calling the preload function to detect require loops.  If we don't
    -- clear that sentinel the inner require() below sees it and throws
    -- "loop or previous error loading module".
    package.loaded[_REGISTRY_KEY] = nil
    -- Load the original registry module.
    local Registry = require(_REGISTRY_KEY)
    -- Apply our patch (wrapped in pcall so a patching failure never prevents
    -- the registry from being returned and used by the caller).
    local ok, err = pcall(_patchRegistry, Registry)
    if not ok then
        logger.warn("simpleui-patch: hardcover: registry patching failed: " .. tostring(err))
    end
    -- Re-install our wrapper so subsequent hot-reload cycles are also patched.
    package.preload[_REGISTRY_KEY] = _myLoader
    return Registry
end

package.preload[_REGISTRY_KEY] = _myLoader
