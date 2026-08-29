-- Pure-Lua regression tests for Bento's column packing.

package.path = "./?.lua;./?/init.lua;" .. package.path

local Bento = require("infra/sui_bento")
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
        error((msg or "") .. " expected=" .. tostring(want) .. " got=" .. tostring(got), 2)
    end
end

local function rowsFor(widths)
    local mods = {}
    for i, width in ipairs(widths) do mods[i] = { id = i, width = width } end
    return Bento.buildRows(mods, function(mod) return mod.width end)
end

test("54/46/46 stacks the repeated right column", function()
    local rows = rowsFor({ 54, 46, 46 })
    eq(#rows, 1)
    eq(#rows[1], 2)
    eq(#rows[1][1].mods, 1)
    eq(#rows[1][2].mods, 2)
    eq(rows[1][2].mods[2].id, 3)
end)

test("equal columns are balanced vertically", function()
    local rows = rowsFor({ 50, 50, 50, 50 })
    eq(#rows, 1)
    eq(#rows[1][1].mods, 2)
    eq(#rows[1][2].mods, 2)
end)

test("an unmatched overflowing width starts a new row", function()
    local rows = rowsFor({ 60, 40, 30 })
    eq(#rows, 2)
    eq(#rows[1], 2)
    eq(#rows[2], 1)
    eq(rows[2][1].mods[1].id, 3)
end)

test("100 percent modules stay on independent rows", function()
    local rows = rowsFor({ 50, 100, 50 })
    eq(#rows, 3)
    eq(rows[2][1].pct, 100)
end)

test("all-default layouts bypass Bento rendering", function()
    eq(rowsFor({ 100, 100 }), nil)
end)

print(string.format("PASS %d  FAIL %d", passed, failed))
if failed > 0 then os.exit(1) end
