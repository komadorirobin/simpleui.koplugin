-- Pure-Lua regression tests for SimpleUI's cover-cache ownership and shared
-- Android background-extraction policy.

package.path = "./?.lua;./?/init.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function eq(got, want, msg)
    if got ~= want then
        error((msg or "") .. " expected=" .. tostring(want)
            .. " got=" .. tostring(got), 2)
    end
end

local scheduled = {}
local UIManager = {
    scheduleIn = function(_self, _delay, fn) scheduled[#scheduled + 1] = fn end,
}
local function drainScheduled()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end

local next_bb, freed = 0, 0
local function makeBB(w, h)
    next_bb = next_bb + 1
    return {
        id = next_bb,
        getWidth = function() return w end,
        getHeight = function() return h end,
        getType = function() return 1 end,
        blitFrom = function() end,
        free = function(self)
            assert(not self.freed, "buffer freed twice: " .. tostring(self.id))
            self.freed = true
            freed = freed + 1
        end,
    }
end

local android = true
local bookshelf_safe = true
local extract_calls = 0
local BIM = {
    getBookInfo = function(_self, _filepath)
        return {
            cover_fetched = false,
            has_cover = false,
        }
    end,
    extractInBackground = function(_self, _files) extract_calls = extract_calls + 1 end,
}

local reader_settings = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return reader_settings[key] end,
    saveSetting = function(_, key, value) reader_settings[key] = value end,
    delSetting = function(_, key) reader_settings[key] = nil end,
}
package.loaded["ffi/blitbuffer"] = {
    new = function(w, h) return makeBB(w, h) end,
}
package.loaded["datastorage"] = { getDataDir = function() return "/tmp/simpleui-test" end }
local store_settings = {}
package.loaded["infra/sui_store"] = {
    get = function(_, key) return store_settings[key] end,
    set = function(_, key, value) store_settings[key] = value end,
    readSetting = function() return nil end,
    saveSetting = function() end,
    flush = function() end,
}
package.loaded["logger"] = { dbg = function() end }
package.loaded["infra/sui_i18n"] = { translate = function(s) return s end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, field)
        if path:match("^/book/") then
            if field == "mode" then return "file" end
            return { mode = "file" }
        end
        return nil
    end,
}
package.loaded["bookinfomanager"] = BIM
package.loaded["ui/uimanager"] = UIManager
package.loaded["device"] = {
    isAndroid = function() return android end,
}
package.loaded["lib/bookshelf_settings_store"] = {
    nilOrTrue = function(key)
        assert(key == "android_safe_mode")
        return bookshelf_safe
    end,
}

local CoverCache = dofile("infra/sui_cover_cache.lua")
local Config = dofile("infra/sui_config.lua")

test("native Bento widths preserve legacy settings and menu entries", function()
    local legacy_key = "simpleui_bento_width_clock"
    local native_key = "simpleui_hs_bento_width_clock"
    reader_settings[legacy_key] = nil
    store_settings[native_key] = nil
    eq(Config.getBentoWidth("clock", "simpleui_hs_"), 100)

    reader_settings[legacy_key] = 15
    eq(Config.getBentoWidth("clock", "simpleui_hs_"), 20, "legacy values must be clamped")
    eq(store_settings[native_key], 20, "legacy width must migrate to native storage")

    Config.setBentoWidth(55, "clock", "simpleui_hs_")
    eq(store_settings[native_key], 55)

    local item = Config.makeBentoWidthItem{
        get = function() return Config.getBentoWidth("clock", "simpleui_hs_") end,
        set = function(v) Config.setBentoWidth(v, "clock", "simpleui_hs_") end,
        refresh = function() end,
    }
    eq(item.value_func(), "55%")

    Config.setBentoWidth(100, "clock", "simpleui_hs_")
    eq(store_settings[native_key], 100)
end)

test("section labels survive hidden and rebuilt Bento modules", function()
    local hide_key = "simpleui_hide_label_currently"
    local mod = {
        id = "currently",
        label = "Currently Reading",
    }

    store_settings[hide_key] = true
    Config.applyLabelToggle(mod, "Currently Reading")
    eq(mod.label, nil, "hidden compatibility label must be cleared")
    eq(mod._section_label, "Currently Reading", "declared label must survive")
    eq(Config.getModuleSectionLabel(mod, {}), nil, "hidden label must stay hidden")

    store_settings[hide_key] = nil
    -- Rebuild paths may still see the compatibility field cleared from the
    -- previous render. The immutable declaration must restore the heading.
    mod.label = nil
    eq(Config.getModuleSectionLabel(mod, {}), "Currently Reading")

    mod.label_func = function() return "Dynamic heading" end
    eq(Config.getModuleSectionLabel(mod, {}), "Dynamic heading")
end)

test("LRU eviction drops cache ownership without freeing live buffers", function()
    freed = 0
    CoverCache:clear()
    CoverCache:setCapacity(2)
    CoverCache:setByteBudget(1024 * 1024)

    local first = makeBB(10, 10)
    CoverCache:put("/book/1.epub", first)
    CoverCache:put("/book/2.epub", makeBB(10, 10))
    CoverCache:put("/book/3.epub", makeBB(10, 10))

    eq(CoverCache:has("/book/1.epub"), false, "oldest entry must be evicted")
    eq(CoverCache:has("/book/2.epub"), true)
    eq(CoverCache:has("/book/3.epub"), true)
    eq(freed, 0, "eviction must not invalidate buffers held by live widgets")
    eq(first.freed, nil)

    CoverCache:clear()
    CoverCache:setCapacity(512)
    CoverCache:setByteBudget(20 * 1024 * 1024)
end)

test("Bookshelf Android safe mode suppresses SimpleUI BIM forks", function()
    android, bookshelf_safe, extract_calls = true, true, 0
    Config._cover_extract_queue = { "/book/safe.epub" }
    Config._cover_extract_pending["/book/safe.epub"] = true
    Config._cover_extract_specs["/book/safe.epub"] = { max_cover_w = 10, max_cover_h = 10 }
    Config.cover_extraction_pending = true
    eq(Config.flushCoverQueue(), false)
    eq(extract_calls, 0, "safe mode must not invoke extractInBackground")
    eq(Config._cover_extract_pending["/book/safe.epub"], nil)
    eq(Config.cover_extraction_pending, false)
end)

test("disabling shared safe mode allows BIM extraction", function()
    android, bookshelf_safe, extract_calls = true, false, 0
    Config._cover_extract_queue = { "/book/allowed.epub" }
    Config._cover_extract_pending["/book/allowed.epub"] = true
    Config._cover_extract_specs["/book/allowed.epub"] = { max_cover_w = 10, max_cover_h = 10 }
    Config.cover_extraction_pending = true
    eq(Config.flushCoverQueue(), true)
    eq(extract_calls, 1)
end)

print(string.format("PASS %d  FAIL %d", passed, failed))
if failed > 0 then os.exit(1) end
