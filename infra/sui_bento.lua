-- sui_bento.lua — pure Bento column packing.
--
-- A module width describes a column, not a one-off row cell. If a module no
-- longer fits beside the current columns, a matching-width column receives it
-- vertically. This preserves layouts such as 54 / 46 / 46: one module on the
-- left and two stacked on the right.

local M = {}

function M.buildRows(mods, get_width_pct)
    if type(mods) ~= "table" or type(get_width_pct) ~= "function" then return nil end

    local rows = {}
    local row = { total = 0 }
    local has_bento_width = false

    local function flush()
        if #row > 0 then rows[#rows + 1] = row end
        row = { total = 0 }
    end

    local function startColumn(mod, pct)
        row[#row + 1] = { pct = pct, mods = { mod } }
        row.total = row.total + pct
    end

    for _, mod in ipairs(mods) do
        local pct = math.max(20, math.min(100, tonumber(get_width_pct(mod)) or 100))
        if pct < 100 then has_bento_width = true end

        if pct >= 100 then
            flush()
            rows[#rows + 1] = { { pct = 100, mods = { mod } }, total = 100 }
        elseif row.total + pct <= 100 then
            startColumn(mod, pct)
        else
            local best_col, best_count
            for i = #row, 1, -1 do
                local col = row[i]
                if math.abs((col.pct or 0) - pct) < 1 then
                    local count = #(col.mods or {})
                    if not best_count or count < best_count then
                        best_col, best_count = col, count
                    end
                end
            end
            if best_col then
                best_col.mods[#best_col.mods + 1] = mod
            else
                flush()
                startColumn(mod, pct)
            end
        end
    end
    flush()

    return has_bento_width and rows or nil
end

return M
