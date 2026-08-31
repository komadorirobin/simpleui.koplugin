-- Pure-Lua regression tests for SimpleUI-only Recent Books exclusions.

package.path = "./?.lua;./?/init.lua;" .. package.path

local data = {}
package.loaded["infra/sui_store"] = {
    readSetting = function(_self, key) return data[key] end,
    saveSetting = function(_self, key, value) data[key] = value end,
    delSetting = function(_self, key) data[key] = nil end,
}

local RecentHidden = dofile("features/library/sui_recent_hidden.lua")

assert(RecentHidden.count() == 0)
assert(RecentHidden.isHidden("/books/a.epub") == false)
assert(RecentHidden.hide("/books/a.epub") == true)
assert(RecentHidden.isHidden("/books/a.epub") == true)
assert(RecentHidden.count() == 1)
assert(RecentHidden.hide(nil) == false)

local snapshot = RecentHidden.snapshot()
assert(snapshot["/books/a.epub"] ~= nil)

RecentHidden.clear()
assert(RecentHidden.count() == 0)
assert(RecentHidden.isHidden("/books/a.epub") == false)

print("PASS recent hidden")
