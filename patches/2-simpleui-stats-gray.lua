-- 2-simpleui-stats-gray.lua
-- Makes the SimpleUI reading_stats module use a light-gray background on stat
-- cards when the "Cards" display mode is active.
--
-- INSTALLATION
--   Copy this file to koreader/patches/
--
-- WHAT IT CHANGES
--   In "Cards" mode, each stat card has a FrameContainer with bordersize=1 and
--   a white background.  This patch wraps M.build() and, after the widget tree
--   is constructed, replaces the white background on those bordered card frames
--   with a light gray (Blitbuffer.gray(0.88)).
--
-- HOW IT WORKS
--   The patch intercepts module_reading_stats at load time via package.preload,
--   so it is applied after every plugin hot-reload cycle as well as on first
--   load.  If the module is already cached when the patch file runs, the live
--   object is patched directly in addition to installing the preload wrapper.

local logger = require("logger")
logger.dbg("simpleui-patch: loading stats gray-background patch")

local _RS_KEY = "desktop_modules/module_reading_stats"

-- ---------------------------------------------------------------------------
-- Gray-background value — adjust to taste:
--   0.0 = black … 1.0 = white
--   0.88 gives a noticeable but subtle light-gray tint on e-ink displays.
-- Note: after editing this value, restart KOReader for the change to take effect.
-- ---------------------------------------------------------------------------
local _GRAY_LEVEL = 0.88

-- ---------------------------------------------------------------------------
-- Core patch: wraps M.build() on a live module_reading_stats object.
-- ---------------------------------------------------------------------------
local function _patchRS(RS)
    local Blitbuffer = require("ffi/blitbuffer")
    local _GRAY_BG   = Blitbuffer.gray(_GRAY_LEVEL)

    local orig_build = RS.build

    RS.build = function(w, ctx)
        local widget = orig_build(w, ctx)
        if not widget then return widget end

        -- Walk the widget tree (max depth 8 to stay fast) and change the
        -- background of bordered, rounded-corner FrameContainers — those are
        -- the individual stat cards in "Cards" mode.
        local function applyGray(t, depth)
            if depth > 8 then return end
            if type(t) ~= "table" then return end
            -- Stat cards: bordersize==1, radius>0 (rounded corners).
            if t.bordersize == 1 and t.radius and t.radius > 0 then
                t.background = _GRAY_BG
            end
            for i = 1, #t do
                applyGray(t[i], depth + 1)
            end
        end

        applyGray(widget, 0)
        return widget
    end

    logger.dbg("simpleui-patch: stats gray-background patch installed")
end

-- ---------------------------------------------------------------------------
-- Apply the patch: live if the module is already cached, and via preload for
-- every future (re-)load caused by plugin hot-reload cycles.
-- ---------------------------------------------------------------------------
if package.loaded[_RS_KEY] then
    _patchRS(package.loaded[_RS_KEY])
end

local _orig_preload = package.preload[_RS_KEY]

local function _myLoader(...)
    -- Restore original preload so the inner require below doesn't recurse
    -- back into us.
    package.preload[_RS_KEY] = _orig_preload
    -- Lua's require() sets package.loaded[name] = true (a sentinel) BEFORE
    -- calling the preload function to detect require loops.  If we don't
    -- clear that sentinel the inner require() below sees it and throws
    -- "loop or previous error loading module".
    package.loaded[_RS_KEY] = nil
    -- Load the original module.
    local RS = require(_RS_KEY)
    -- Apply our patch (wrapped in pcall so a patching failure never prevents
    -- the module from being returned and registered by the caller).
    local ok, err = pcall(_patchRS, RS)
    if not ok then
        logger.warn("simpleui-patch: stats gray: patching failed: " .. tostring(err))
    end
    -- Re-install our wrapper for future hot-reload cycles.
    package.preload[_RS_KEY] = _myLoader
    return RS
end

package.preload[_RS_KEY] = _myLoader
