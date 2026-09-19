package.path = "./?.lua;./?/init.lua;" .. package.path

local home_dir = "/books"
local files = { "/books/billy-bat-02.cbz", "/books/100%.epub", "/books/unknown.epub" }
local metadata = {
    { files[1], title = "Billy Bat, Vol. 2", authors = "Naoki Urasawa", series = "Billy Bat" },
    { files[2], title = "A Different Title", authors = "Another Author", series = "Other Series" },
}
local input, dialog, window, closed, notice, opened, keyboard
local ask_to_open = false
local metadata_calls = 0

local function widget(_self, opts) return opts end
package.loaded["ui/widget/inputdialog"] = {
    new = function(_self, opts)
        opts.getInputText = function() return input end
        opts.onShowKeyboard = function() keyboard = true end
        return opts
    end,
}
package.loaded["ui/widget/confirmbox"] = { new = widget }
package.loaded["ui/uimanager"] = {
    show = function(_self, value) dialog = value end,
    close = function(_self, value) closed = value end,
}
package.loaded["infra/sui_i18n"] = { translate = function(text) return text end }
package.loaded["ffi/util"] = {
    template = function(text, value) return (text:gsub("%%1", function() return value end)) end,
}
package.loaded["engines/sui_library_scan"] = {
    resolveHomeDir = function() return home_dir end,
    getFileList = function(root)
        assert(root == home_dir)
        return files
    end,
}
package.loaded["bookinfomanager"] = {}
package.loaded["features/library/sui_metadata_source"] = {
    getMatchingFiles = function(_bim, root, filter, opts)
        assert(root == home_dir and filter == nil and opts.recursive)
        metadata_calls = metadata_calls + 1
        return metadata
    end,
}
package.loaded["engines/sui_window"] = {
    new = function(_self, opts)
        opts.show = function() window = opts end
        return opts
    end,
    ListRow = function(opts) return opts end,
}
package.loaded["infra/sui_core"] = { Notify = { toast = function(text) notice = text end } }
package.loaded["infra/sui_config"] = { isNavpagerEnabled = function() return false end }
package.loaded["pluginloader"] = { getPluginInstance = function() return nil end }
package.loaded["apps/reader/readerui"] = { showReader = function(_self, path) opened = path end }
G_reader_settings = { isTrue = function(_self, key) return key == "file_ask_to_open" and ask_to_open end }

local Search = dofile("features/library/sui_library_search.lua")
local function search(query)
    input, dialog, window, closed, notice, opened, keyboard = query, nil, nil, nil, nil, nil, false
    Search.show()
    assert(keyboard, "search must explicitly open the keyboard")
    local original = dialog
    original.buttons[1][2].callback()
    assert(closed == original, "submitted search dialog must close")
    if window then return window.screens.__root__({ inner_w = 600, repaint = function() end }) end
end

local rows = search("NAOKI bat")
assert(#rows == 1 and rows[1].title == "Billy Bat, Vol. 2")
assert(rows[1].subtitle == "Naoki Urasawa" and rows[1].right_value == "Open")
rows[1].on_tap()
assert(opened == files[1], "result must open the matched book")
assert(metadata_calls == 1, "one cached metadata lookup per query")

rows = search("other series")
assert(#rows == 1 and rows[1].title == "A Different Title", "match series metadata")
rows = search("100%")
assert(#rows == 1 and rows[1].title == "A Different Title", "query is literal, not a Lua pattern")
rows = search("unknown")
assert(#rows == 1 and rows[1].title == "unknown.epub", "missing metadata uses filename")

ask_to_open = true
rows[1].on_tap()
assert(opened == nil and dialog.ok_callback, "respect confirmation before opening")
dialog.ok_callback()
assert(opened == files[3])

assert(search("unmatched") == nil and notice == "No results for: unmatched")
assert(search("  \t ") == nil, "whitespace must not return the whole library")

files, metadata = {}, {}
for index = 1, 405 do files[index] = string.format("/books/book%03d.epub", index) end
rows = search("book")
assert(#rows == 400, "results must remain bounded")
assert(rows[1].title == "book001.epub" and rows[400].title == "book400.epub")

home_dir, notice, dialog = nil, nil, nil
Search.show()
assert(dialog == nil and notice == "No home folder set.")

print("PASS library search")
