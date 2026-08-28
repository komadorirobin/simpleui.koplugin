-- Pure-Lua regression tests for the optional SimpleUI/Bookshelf bridge.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fake_now = 1000
local scheduled = {}
local shown = {}
local broadcasts = 0

local UIManager = {
    _window_stack = {},
    scheduleIn = function(_self, _delay, fn)
        scheduled[#scheduled + 1] = fn
    end,
    isWidgetShown = function(_self, widget)
        return shown[widget] == true
    end,
    broadcastEvent = function()
        broadcasts = broadcasts + 1
    end,
    sendEvent = function() end,
}

package.loaded["socket"] = { gettime = function() return fake_now end }
package.loaded["ui/uimanager"] = UIManager
package.loaded["ui/event"] = {
    new = function(_self, name, payload)
        return { name = name, payload = payload }
    end,
}
package.loaded["logger"] = {
    dbg = function() end,
    warn = function() end,
}
package.loaded["infra/sui_store"] = { get = function() return nil end }

local FileManager = { instance = { _simpleui_plugin = {} } }
local ReaderUI = { instance = nil }
package.loaded["apps/filemanager/filemanager"] = FileManager
package.loaded["apps/reader/readerui"] = ReaderUI

local Bridge = dofile("sui_bookshelf_bridge.lua")

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

local function reset()
    scheduled = {}
    broadcasts = 0
    ReaderUI.instance = nil
    FileManager.instance = { _simpleui_plugin = {} }
    UIManager._window_stack = {}
    shown = {}
end

local function fireNext()
    local fn = table.remove(scheduled, 1)
    assert(fn, "expected a scheduled callback")
    fn()
end

test("latest prepareReturn request cancels older retries", function()
    reset()
    local received = {}
    local bookshelf = {
        onPrepareBookshelfReturn = function(_self, payload)
            received[#received + 1] = payload
        end,
    }
    ReaderUI.instance = {
        document = { file = "/books/b.epub" },
        bookshelf = bookshelf,
    }
    Bridge.prepareReturn("/books/a.epub", "test-a")
    Bridge.prepareReturn("/books/b.epub", "test-b")
    fireNext()
    fireNext()
    eq(#received, 1)
    eq(received[1].requested_file, "/books/b.epub")
    eq(received[1].file, "/books/b.epub")
end)

test("prepareReturn waits until the requested ReaderUI is live", function()
    reset()
    local received
    ReaderUI.instance = {
        document = { file = "/books/old.epub" },
        bookshelf = {
            onPrepareBookshelfReturn = function(_self, payload)
                received = payload
            end,
        },
    }
    Bridge.prepareReturn("/books/new.epub", "test")
    fireNext()
    eq(received, nil)
    eq(#scheduled, 1, "mismatched reader should retry")
    ReaderUI.instance.document.file = "/books/new.epub"
    fireNext()
    eq(received.requested_file, "/books/new.epub")
end)

test("Home prewarm accepts an explicit Bookshelf acknowledgement", function()
    reset()
    local homescreen = {}
    local calls = 0
    package.loaded["screens/sui_homescreen"] = { _instance = homescreen }
    shown[homescreen] = true
    UIManager._window_stack = { { widget = homescreen } }
    FileManager.instance.bookshelf = {
        onPrepareBookshelfHome = function(_self, payload)
            calls = calls + 1
            return payload.is_alive() and payload.is_active()
        end,
    }
    Bridge.scheduleHomePrewarm(homescreen)
    fake_now = fake_now + 6
    fireNext()
    eq(calls, 1)
    eq(#scheduled, 0)
    eq(broadcasts, 0)
    Bridge.cancelHomePrewarm(homescreen)
end)

test("Home prewarm does not treat an unhandled broadcast as delivery", function()
    reset()
    local homescreen = {}
    package.loaded["screens/sui_homescreen"] = { _instance = homescreen }
    shown[homescreen] = true
    UIManager._window_stack = { { widget = homescreen } }
    FileManager.instance.bookshelf = nil
    Bridge.scheduleHomePrewarm(homescreen)
    fake_now = fake_now + 6
    for _i = 1, 11 do
        fireNext()
        fake_now = fake_now + 1
    end
    eq(broadcasts, 1, "fallback broadcast should be sent only once")
    eq(#scheduled, 0, "unhandled request must stop after bounded retries")
    Bridge.cancelHomePrewarm(homescreen)
end)

test("Home prewarm stops polling when Home never becomes topmost", function()
    reset()
    local homescreen = {}
    package.loaded["screens/sui_homescreen"] = { _instance = homescreen }
    shown[homescreen] = true
    UIManager._window_stack = { { widget = homescreen }, { widget = {} } }
    Bridge.scheduleHomePrewarm(homescreen)
    for _i = 1, 60 do
        fake_now = fake_now + 1
        fireNext()
    end
    eq(#scheduled, 0, "inactive Home prewarm must have a bounded lifetime")
    eq(broadcasts, 0, "an inactive Home must not broadcast a preload")
    Bridge.cancelHomePrewarm(homescreen)
end)

print(string.format("PASS %d  FAIL %d", passed, failed))
if failed > 0 then os.exit(1) end
