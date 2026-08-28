package.path = "./?.lua;./?/init.lua;" .. package.path

local existing_files = {
    ["/books/seven.epub"] = true,
    ["/books/three.epub"] = true,
    ["/books/five.epub"] = true,
}
local settings = {}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if key == "mode" and existing_files[path] then return "file" end
    end,
}
package.loaded["logger"] = { warn = function() end }
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _delay, fn) fn() end,
    nextTick = function(_self, fn) fn() end,
}
package.loaded["sui_store"] = {
    readSetting = function(_self, key) return settings[key] end,
    setNoFlush = function(_self, key, value) settings[key] = value end,
    flush = function() end,
}

local Source = dofile("integrations/sui_bookorbit_want.lua")

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

local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or "") .. " expected=" .. tostring(expected)
            .. " got=" .. tostring(actual), 2)
    end
end

test("maps numeric and string ids in server order", function()
    local files = Source.mapBookIdsToFiles({ "7", 3 }, {
        [7] = "/books/seven.epub",
        [3] = "/books/three.epub",
    }, function() return true end)
    eq(#files, 2)
    eq(files[1], "/books/seven.epub")
    eq(files[2], "/books/three.epub")
end)

test("deduplicates paths and skips missing local files", function()
    local files = Source.mapBookIdsToFiles({ 1, 2, 3 }, {
        [1] = "/books/same.epub",
        [2] = "/books/same.epub",
        [3] = "/books/missing.epub",
    }, function(path) return path ~= "/books/missing.epub" end)
    eq(#files, 1)
    eq(files[1], "/books/same.epub")
end)

test("refreshes every server page into the local filepath cache", function()
    local requested_pages = {}
    local client = {
        runInSubprocess = function(_self, fn)
            local body, err = fn()
            return true, { body = body, err = err }
        end,
        catalogBooks = function(_self, params)
            requested_pages[#requested_pages + 1] = params.page
            eq(params.readStatus, "want_to_read")
            if params.page == 1 then
                return { items = { { id = 7 }, { id = 99 } }, hasNext = true }
            end
            return { items = { { id = 5 } }, hasNext = false }
        end,
    }
    local plugin = {
        isLoggedIn = function() return true end,
        newClient = function() return client end,
    }
    package.loaded["pluginloader"] = {
        getPluginInstance = function(_self, name)
            eq(name, "bookorbit")
            return plugin
        end,
    }
    package.loaded["bookorbit_state_manager"] = {
        hasOnDeviceMaps = function() return true end,
        onDeviceMaps = function()
            return { byBookId = {
                [7] = "/books/seven.epub",
                [5] = "/books/five.epub",
            } }
        end,
    }
    package.loaded["ui/trapper"] = { wrap = function(_self, fn) fn() end }

    settings = {}
    Source._resetForTests()
    local result
    local started = Source.requestRefresh{
        delay = 0,
        on_done = function(value) result = value end,
    }

    eq(started, true)
    eq(#requested_pages, 2)
    eq(result.ok, true)
    eq(result.changed, true)
    eq(result.count, 2)
    eq(result.skipped, 1)
    local cached = Source.getCachedFiles()
    eq(cached[1], "/books/seven.epub")
    eq(cached[2], "/books/five.epub")
end)

print(string.format("PASS %d  FAIL %d", passed, failed))
if failed > 0 then os.exit(1) end
