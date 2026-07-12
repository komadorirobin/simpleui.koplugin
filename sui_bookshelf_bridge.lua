-- sui_bookshelf_bridge.lua — optional coordination with bookshelf.koplugin.
--
-- SimpleUI can open books without Bookshelf being involved. When Bookshelf's
-- "instant close" prewarm is enabled, tell it about that open explicitly so it
-- can prepare the matching shelf in the background instead of guessing from
-- reader hooks.

local UIManager = require("ui/uimanager")
local Event     = require("ui/event")
local logger    = require("logger")

local M = {}

function M.prepareReturn(filepath, source)
    if type(filepath) ~= "string" or filepath == "" then return end
    source = source or "simpleui"

    local function emit(attempt)
        local RUI = package.loaded["apps/reader/readerui"]
        local readerui = RUI and RUI.instance
        local live_file = readerui and readerui.document and readerui.document.file
        if readerui and live_file then
            local ok, err = pcall(function()
                UIManager:broadcastEvent(Event:new("PrepareBookshelfReturn", {
                    file = live_file,
                    requested_file = filepath,
                    source = source,
                }))
            end)
            if not ok then
                logger.warn("simpleui: bookshelf prepare return failed:",
                    tostring(err))
            end
            return
        end

        if attempt < 10 then
            UIManager:scheduleIn(0.5, function() emit(attempt + 1) end)
        end
    end

    UIManager:scheduleIn(0.5, function() emit(0) end)
end

return M
