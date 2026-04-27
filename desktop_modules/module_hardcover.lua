-- module_hardcover.lua — Simple UI
-- Hardcover.app reading goal widget.
--
-- Shows your active reading goal fetched live from hardcover.app.
-- Requires an API key: hardcover.app → Settings → Developer.
--
-- Settings keys:
--   simpleui_hc_api_key       — Hardcover API key (Bearer token)
--   simpleui_hc_cache_data    — cached goal as JSON string
--   simpleui_hc_cache_time    — Unix timestamp of last successful fetch
--   simpleui_hc_cache_ttl     — cache TTL in minutes (default 60)

local _        = require("gettext")
local logger   = require("logger")
local Screen   = require("device").screen
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local UI     = require("sui_core")
local Config = require("sui_config")

local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local _BASE_H        = Screen:scaleBySize(82)   -- widget content height (no label)
local _BASE_TITLE_FS = Screen:scaleBySize(13)
local _BASE_BODY_FS  = Screen:scaleBySize(10)
local _BASE_SMALL_FS = Screen:scaleBySize(9)
local _BASE_BAR_H    = Screen:scaleBySize(6)
local _BASE_BAR_R    = Screen:scaleBySize(3)     -- bar corner radius
local _BASE_ROW_H    = Screen:scaleBySize(18)    -- row-mode height
local _BASE_ROW_FS   = Screen:scaleBySize(10)    -- row-mode font size

local _CLR_BAR_BG    = Blitbuffer.gray(0.15)
local _CLR_BAR_FG    = Blitbuffer.gray(0.80)
local _CLR_WARN      = Blitbuffer.COLOR_BLACK    -- bold black for behind-schedule
local _CLR_OK        = Blitbuffer.gray(0.50)     -- softer for on-track / ahead

local API_URL            = "https://api.hardcover.app/v1/graphql"
local CACHE_TTL_DEFAULT  = 60    -- minutes

-- ---------------------------------------------------------------------------
-- Internal section label — replaces the SimpleUI M.label mechanism so the
-- label is built at the correct (possibly bento-reduced) width `w` instead
-- of at full screen width.  This makes the module compatible with the
-- LeviiStar bento-grid patch, which cannot resize externally-created labels.
-- ---------------------------------------------------------------------------

local _SECTION_LABEL_FS = Screen:scaleBySize(11)

local function _buildLabel(w)
    local scale   = Config.getLabelScale()
    local fs      = math.max(8, math.floor(_SECTION_LABEL_FS * scale))
    local label_h = math.max(8, math.floor(Screen:scaleBySize(16) * scale))
    return FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_left   = PAD,
        padding_right  = PAD,
        padding_bottom = PAD2,
        TextWidget:new{
            text   = _("Hardcover"),
            face   = Font:getFace("smallinfofont", fs),
            bold   = true,
            max_width = w - PAD * 2,
            height    = label_h,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SK = {
    api_key    = "simpleui_hc_api_key",
    cache_data = "simpleui_hc_cache_data",
    cache_time = "simpleui_hc_cache_time",
    cache_ttl  = "simpleui_hc_cache_ttl",
    text_scale = "simpleui_hc_text_scale",
    layout     = "simpleui_hc_layout",
}

local _HC_TEXT_SCALE_MIN  = 50
local _HC_TEXT_SCALE_MAX  = 200
local _HC_TEXT_SCALE_STEP = 5
local _HC_TEXT_SCALE_DEF  = 100

local function _getApiKey()
    local k = G_reader_settings:readSetting(SK.api_key) or ""
    -- Strip common prefixes users might paste
    k = k:gsub("^%s+", ""):gsub("%s+$", "")
    k = k:gsub("^[Bb]earer%s+", "")
    k = k:gsub('^"(.*)"$', "%1")
    return k
end

local function _getCacheTtlMin()
    return G_reader_settings:readSetting(SK.cache_ttl) or CACHE_TTL_DEFAULT
end

local function _getTextScalePct()
    return tonumber(G_reader_settings:readSetting(SK.text_scale)) or _HC_TEXT_SCALE_DEF
end

local function _getLayout()
    return G_reader_settings:readSetting(SK.layout) or "card"
end

-- ---------------------------------------------------------------------------
-- JSON helper (tries rapidjson then cjson then json)
-- ---------------------------------------------------------------------------

local _json
local function _getJson()
    if _json then return _json end
    local ok, j
    ok, j = pcall(require, "rapidjson")
    if ok and j then _json = j; return j end
    ok, j = pcall(require, "cjson")
    if ok and j then _json = j; return j end
    ok, j = pcall(require, "json")
    if ok and j then _json = j; return j end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _getCached()
    local data_str = G_reader_settings:readSetting(SK.cache_data)
    if not data_str then return nil end
    local j = _getJson()
    if not j then return nil end
    local ok, data = pcall(j.decode, data_str)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function _saveCache(goal)
    local j = _getJson()
    if not j then return end
    local ok, str = pcall(j.encode, goal)
    if not ok then return end
    G_reader_settings:saveSetting(SK.cache_data, str)
    G_reader_settings:saveSetting(SK.cache_time, os.time())
end

local function _isCacheStale()
    local ts  = G_reader_settings:readSetting(SK.cache_time) or 0
    local ttl = _getCacheTtlMin() * 60
    return (os.time() - ts) > ttl
end

-- ---------------------------------------------------------------------------
-- Goal parsing and selection
-- ---------------------------------------------------------------------------

-- Extract goal list from raw API response.
local function _parseGoals(resp_data)
    if not resp_data or not resp_data.data then return nil end
    local me = resp_data.data.me
    if not me then return nil end
    -- Hardcover returns me as an array in some schema versions
    local me_obj = (type(me) == "table" and me[1]) or me
    if not me_obj then return nil end
    local goals = me_obj.goals
    if not goals or (type(goals) == "table" and #goals == 0) then return nil end
    return goals
end

-- Choose the single most-relevant goal:
--   1) Active now (start_date ≤ today ≤ end_date)
--   2) Nearest future end_date
--   3) Most recently ended
local function _selectGoal(goals)
    if not goals or #goals == 0 then return nil end
    local today = os.date("%Y-%m-%d")

    for _, g in ipairs(goals) do
        if not g.archived then
            local s = g.start_date or ""
            local e = g.end_date   or ""
            if s <= today and today <= e then return g end
        end
    end

    local future = {}
    for _, g in ipairs(goals) do
        if not g.archived and (g.end_date or "") > today then
            future[#future + 1] = g
        end
    end
    if #future > 0 then
        table.sort(future, function(a, b)
            return (a.end_date or "") < (b.end_date or "")
        end)
        return future[1]
    end

    local rest = {}
    for _, g in ipairs(goals) do
        if not g.archived then rest[#rest + 1] = g end
    end
    if #rest == 0 then return nil end
    table.sort(rest, function(a, b)
        return (a.end_date or "") > (b.end_date or "")
    end)
    return rest[1]
end

-- ---------------------------------------------------------------------------
-- HTTP fetch  (ssl.https → curl async fallback)
-- ---------------------------------------------------------------------------

-- Internal: parse + cache a raw JSON body string.
-- Returns the selected goal on success, nil on failure.
local function _processBody(j, body)
    local ok, resp = pcall(j.decode, body)
    if not ok or type(resp) ~= "table" then
        logger.warn("simpleui hardcover: JSON parse failed: " .. tostring(body):sub(1, 120))
        return nil
    end
    local goals = _parseGoals(resp)
    if not goals then
        logger.info("simpleui hardcover: no goals in response: " .. tostring(body):sub(1, 200))
        return nil
    end
    local goal = _selectGoal(goals)
    if goal then _saveCache(goal) end
    return goal
end

-- Async fetch: tries ssl.https first (sync with timeout, fast on good
-- connections), then falls back to a background curl process that never
-- blocks the UI thread.
-- on_done(goal_or_nil) is called exactly once when the result is ready.
local function _fetchAsync(api_key, on_done)
    local j = _getJson()
    if not j then on_done(nil); return end

    local payload = '{"query":"{ me { goals { id goal metric start_date end_date progress description archived } } }"}'
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Authorization"]  = "Bearer " .. api_key,
        ["Content-Length"] = tostring(#payload),
    }

    -- ── Try ssl.https (luasec) — blocks ≤ 8 s then returns ─────────────────
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn,   ltn12 = pcall(require, "ltn12")
    if ok_https and ok_ltn and https and ltn12 then
        local resp = {}
        local ok2, b, code = pcall(function()
            -- NOTE: do NOT pass a custom `create` function — luasec on Android
            -- rejects it with "create function not permitted".
            return https.request({
                url     = API_URL,
                method  = "POST",
                headers = headers,
                source  = ltn12.source.string(payload),
                sink    = ltn12.sink.table(resp),
            })
        end)
        local body = table.concat(resp)
        if ok2 and body ~= "" then
            local result = _processBody(j, body)
            if result then
                on_done(result)
                return
            end
            -- Body received but no valid goal — log first 200 chars and fall through.
            logger.warn("simpleui hardcover: ssl.https got body but no goal (code="
                .. tostring(code) .. "): " .. body:sub(1, 200))
            on_done(nil)
            return
        end
        logger.warn("simpleui hardcover: ssl.https failed (ok2=" .. tostring(ok2)
            .. " code=" .. tostring(code) .. " body_len=" .. tostring(#table.concat(resp)) .. ")")
    end

    -- ── Async curl fallback — never blocks the UI thread ────────────────────
    -- Sanitize key to safe subset (API tokens are hex/base64url).
    local safe_key = api_key:gsub("[^%w%-%_%.~%+%/=]", "")
    if safe_key == "" then on_done(nil); return end

    -- Use KOReader's own data directory — /tmp does not exist on Android.
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local base_dir = (ok_ds and DataStorage and DataStorage.getDataDir())
        or "/storage/emulated/0/koreader"
    local dir       = base_dir .. "/simpleui_hc"
    local p_file    = dir .. "/query.json"
    local out_file  = dir .. "/resp.json"
    local done_file = dir .. "/resp.done"

    os.execute("mkdir -p '" .. dir .. "'")
    -- Remove stale files so we can detect completion reliably.
    os.remove(out_file)
    os.remove(done_file)

    local fp = io.open(p_file, "w")
    if not fp then on_done(nil); return end
    fp:write(payload)
    fp:close()

    -- Spawn curl in the background; touch done_file on success so the
    -- poll loop knows the output file is complete.
    local cmd = "curl -s --connect-timeout 5 -m 10 -X POST"
        .. " -H 'Content-Type: application/json'"
        .. " -H 'Authorization: Bearer " .. safe_key .. "'"
        .. " --data-binary @'" .. p_file .. "'"
        .. " -o '" .. out_file .. "'"
        .. " 2>/dev/null"
        .. " && touch '" .. done_file .. "'"
        .. " &"  -- ← run in background; os.execute returns immediately
    os.execute(cmd)

    -- Poll every second for up to 15 s.
    local UIManager = require("ui/uimanager")
    local attempts  = 0
    local function _poll()
        attempts = attempts + 1
        local df = io.open(done_file, "r")
        if df then
            df:close()
            local g = io.open(out_file, "r")
            if g then
                local body = g:read("*a"); g:close()
                on_done(_processBody(j, body))
                return
            end
        end
        if attempts < 15 then
            UIManager:scheduleIn(1.0, _poll)
        else
            logger.warn("simpleui hardcover: async curl timed out after 15 polls")
            on_done(nil)
        end
    end
    UIManager:scheduleIn(1.0, _poll)
end

-- ---------------------------------------------------------------------------
-- Trigger homescreen refresh after background fetch
-- ---------------------------------------------------------------------------

local function _refreshHomescreen()
    local HS = package.loaded["sui_homescreen"]
    if HS and HS._instance then
        pcall(function() HS._instance:_refresh(false) end)
    end
end

-- ---------------------------------------------------------------------------
-- Date formatting helpers
-- ---------------------------------------------------------------------------

local _SV_MONTHS = {
    "jan.", "feb.", "mars", "apr.", "maj", "jun.",
    "jul.", "aug.", "sep.", "okt.", "nov.", "dec."
}

local function _parseYMD(s)
    if not s then return nil end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

local function _fmtDate(date_str)
    local y, m, d = _parseYMD(date_str)
    if not y then return date_str or "" end
    return string.format("%d %s %d", d, _SV_MONTHS[m] or "?", y)
end

-- Returns a Unix timestamp for the start of the given date (local noon,
-- which avoids DST boundary issues for day-level comparisons).
local function _dateTs(date_str)
    local y, m, d = _parseYMD(date_str)
    if not y then return nil end
    return os.time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
end

-- ---------------------------------------------------------------------------
-- Goal title (translates "YYYY Reading Goal" → "Läsmål för YYYY")
-- ---------------------------------------------------------------------------

local function _goalTitle(goal)
    if not goal then return "Hardcover" end
    local desc = goal.description or ""
    local year = desc:match("^(%d%d%d%d) Reading Goal$")
    if year then return string.format("Läsmål för %s", year) end
    year = desc:match("^Läsmål för (%d%d%d%d)$")
    if year then return desc end
    return desc ~= "" and desc or "Hardcover"
end

-- ---------------------------------------------------------------------------
-- "On schedule?" status line
-- ---------------------------------------------------------------------------

local function _statusText(goal)
    if not goal then return nil, false end
    local progress = goal.progress or 0
    local target   = goal.goal    or 0
    if target <= 0 then return nil, false end

    local metric = (goal.metric or "book"):lower()
    local today  = os.date("%Y-%m-%d")

    local function _unit(n)
        if metric == "page" then
            return n == 1 and "sida" or "sidor"
        else
            return n == 1 and "bok" or "böcker"
        end
    end

    -- Completed
    if progress >= target then
        return "🎉 Mål uppnått!", false
    end

    local end_date = goal.end_date or ""
    -- Goal has passed
    if today > end_date then
        local left = target - progress
        return string.format("Avslutad – %d %s kvar", left, _unit(left)), true
    end

    -- Compute fraction of goal period elapsed
    local ts_start = _dateTs(goal.start_date)
    local ts_end   = _dateTs(end_date)
    local ts_now   = os.time()

    if ts_start and ts_end and ts_end > ts_start then
        local frac     = math.max(0, math.min(1, (ts_now - ts_start) / (ts_end - ts_start)))
        local expected = math.floor(target * frac)
        local delta    = progress - expected

        if delta < -1 then
            local behind = -delta
            return string.format("%d %s efter schemat.", behind, _unit(behind)), true
        elseif delta > 1 then
            local ahead = delta
            return string.format("%d %s före schemat.", ahead, _unit(ahead)), false
        else
            return "I fas.", false
        end
    end

    return nil, false
end

-- ---------------------------------------------------------------------------
-- Progress bar (same pattern as module_reading_goals)
-- ---------------------------------------------------------------------------

local function _buildBar(w, h, pct)
    pct = math.max(0, math.min(1, pct or 0))
    local fill_w = math.max(0, math.floor(w * pct))
    if fill_w <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = h }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LineWidget:new{ dimen = Geom:new{ w = w,       h = h }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fill_w,  h = h }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- Build the row widget (compact single-line layout)
-- Title · mini-bar · X% · X av Y böcker [· status]
-- ---------------------------------------------------------------------------

local function _buildRow(w, goal)
    local scale    = Config.getModuleScale("hardcover")
    local ts       = scale * (_getTextScalePct() / 100)
    local row_h    = math.max(14, math.floor(_BASE_ROW_H * scale))
    local fs       = math.max(7,  math.floor(_BASE_ROW_FS * ts))
    local bar_h    = math.max(2,  math.floor(_BASE_BAR_H  * scale))
    local face     = Font:getFace("cfont", fs)

    local progress = goal.progress or 0
    local target   = math.max(1, goal.goal or 1)
    local pct      = math.min(1.0, progress / target)
    local pct_str  = string.format("%d%%", math.floor(pct * 100))
    local metric   = (goal.metric or "book"):lower()
    local unit     = metric == "page" and "sidor" or "böcker"
    local title    = _goalTitle(goal)
    local status, is_warn = _statusText(goal)

    -- Build parts: title, bar, pct, count, optional status
    -- Allocate widths so the HorizontalGroup never exceeds `w`.
    -- Fixed parts: sep(5) + bar + span(4) + dot(~20) = ~29 + BAR_W
    -- Variable: title + pct + count + optional status.
    local BAR_W      = math.floor(w * 0.12)
    local SEP_W      = Screen:scaleBySize(5)
    local SPAN_W     = Screen:scaleBySize(4)
    local DOT_W      = Screen:scaleBySize(20)  -- approximate " · " width
    local fixed_w    = SEP_W + BAR_W + SPAN_W + DOT_W
    local title_max  = math.floor(w * 0.32)
    local pct_max    = math.floor(w * 0.09)
    -- Remaining budget for count (and optional status).
    local remain     = math.max(0, w - fixed_w - title_max - pct_max - DOT_W)
    local count_max  = status and math.floor(remain * 0.55) or remain
    local status_max = status and math.max(0, remain - count_max - DOT_W) or 0

    local title_w  = TextWidget:new{
        text      = title,
        face      = Font:getFace("cfont", math.max(7, math.floor(_BASE_ROW_FS * ts))),
        bold      = true,
        fgcolor   = Blitbuffer.COLOR_BLACK,
        max_width = title_max,
    }

    local count_str = string.format("%d / %d %s", progress, goal.goal or 0, unit)

    local row = HorizontalGroup:new{ align = "center" }
    row[#row+1] = title_w
    row[#row+1] = HorizontalSpan:new{ width = SEP_W }
    row[#row+1] = _buildBar(BAR_W, bar_h, pct)
    row[#row+1] = HorizontalSpan:new{ width = SPAN_W }
    row[#row+1] = TextWidget:new{ text = pct_str,   face = face, fgcolor = Blitbuffer.COLOR_BLACK,
                                  max_width = pct_max }
    row[#row+1] = TextWidget:new{ text = " · ",     face = face, fgcolor = CLR_TEXT_SUB }
    row[#row+1] = TextWidget:new{ text = count_str, face = face, fgcolor = CLR_TEXT_SUB,
                                  max_width = count_max }
    if status and status_max > 0 then
        row[#row+1] = TextWidget:new{ text = " · ", face = face, fgcolor = CLR_TEXT_SUB }
        row[#row+1] = TextWidget:new{
            text      = status,
            face      = face,
            fgcolor   = is_warn and Blitbuffer.COLOR_BLACK or CLR_TEXT_SUB,
            max_width = status_max,
        }
    end

    -- Do NOT use CenterContainer here: if row exceeds `w`, CenterContainer
    -- would compute a negative x-offset, pushing content off-screen to the left.
    -- Left-align inside the FrameContainer instead.
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = w, h = row_h },
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Build the card widget from a goal table
-- ---------------------------------------------------------------------------

local function _buildCard(w, goal)
    local scale      = Config.getModuleScale("hardcover")
    local text_scale = scale * (_getTextScalePct() / 100)
    local inner_w    = w - PAD * 2
    local face_title = Font:getFace("cfont", math.max(8, math.floor(_BASE_TITLE_FS * text_scale)))
    local face_body  = Font:getFace("cfont", math.max(7, math.floor(_BASE_BODY_FS  * text_scale)))
    local face_small = Font:getFace("cfont", math.max(6, math.floor(_BASE_SMALL_FS * text_scale)))
    local bar_h      = math.max(2, math.floor(_BASE_BAR_H * scale))

    local progress = goal.progress or 0
    local target   = math.max(1, goal.goal or 1)
    local pct      = math.min(1.0, progress / target)
    local pct_str  = string.format("%d%%", math.floor(pct * 100))
    local metric   = (goal.metric or "book"):lower()
    local unit     = metric == "page" and "sidor" or "böcker"
    local prog_str = string.format("%d av %d %s", progress, goal.goal or 0, unit)
    local title    = _goalTitle(goal)
    local status, is_warn = _statusText(goal)
    local date_str = _fmtDate(goal.start_date) .. " – " .. _fmtDate(goal.end_date)

    local rows = VerticalGroup:new{ align = "left" }

    -- ── Row 1: Title (full width, wraps if needed) ────────────────────────
    rows[#rows + 1] = TextBoxWidget:new{
        text  = title,
        face  = face_title,
        bold  = true,
        width = inner_w,
    }
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }

    -- ── Row 2: Progress bar + percentage ─────────────────────────────────
    local pct_widget = TextWidget:new{ text = pct_str, face = face_body,
                                       fgcolor = CLR_TEXT_SUB }
    local pct_w      = pct_widget:getSize().w
    local bar_w      = math.max(0, inner_w - pct_w - Screen:scaleBySize(4))
    local bar_row    = HorizontalGroup:new{
        align = "center",
        _buildBar(bar_w, bar_h, pct),
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        pct_widget,
    }
    rows[#rows + 1] = bar_row
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(5) }

    -- ── Row 3: "X av Y böcker" ────────────────────────────────────────────
    rows[#rows + 1] = TextBoxWidget:new{
        text    = prog_str,
        face    = face_body,
        fgcolor = CLR_TEXT_SUB,
        width   = inner_w,
    }

    -- ── Row 4: Status (optional) ──────────────────────────────────────────
    if status then
        rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        rows[#rows + 1] = TextBoxWidget:new{
            text    = status,
            face    = face_small,
            fgcolor = is_warn and _CLR_WARN or _CLR_OK,
            width   = inner_w,
        }
    end

    -- ── Row 5: Date range ─────────────────────────────────────────────────
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
    rows[#rows + 1] = TextBoxWidget:new{
        text    = date_str,
        face    = face_small,
        fgcolor = CLR_TEXT_SUB,
        width   = inner_w,
    }

    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        rows,
    }
end

-- Placeholder shown when there is no data.
local function _buildPlaceholder(w, msg)
    local face = Font:getFace("cfont", _BASE_BODY_FS)
    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        TextWidget:new{
            text    = msg,
            face    = face,
            fgcolor = CLR_TEXT_SUB,
            max_width = w - PAD * 2,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _fetch_pending = false   -- guard against duplicate scheduled fetches
local _last_error    = nil     -- last fetch error message (string) or nil

-- ---------------------------------------------------------------------------
-- Module export
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "hardcover"
M.name        = _("Hardcover")
M.label       = nil      -- label is rendered internally at bento-safe width
M.enabled_key = "hardcover"
M.default_on  = false
M._getCached  = _getCached   -- exposed for module_reading_stats

-- Called by module_reading_stats (and M.build) to trigger a background fetch
-- when the cache is stale. Safe to call from anywhere — returns immediately.
function M.ensureFresh()
    local api_key = _getApiKey()
    if api_key == "" or _fetch_pending or not _isCacheStale() then return end
    _fetch_pending = true
    _fetchAsync(api_key, function(goal)
        _fetch_pending = false
        if goal then
            _last_error = nil
        else
            local retry_delay_secs = math.max(300, (_getCacheTtlMin() - 5) * 60)
            G_reader_settings:saveSetting(SK.cache_time,
                os.time() - (_getCacheTtlMin() * 60) + retry_delay_secs)
            _last_error = _("Hardcover: kunde inte hämta data. Kontrollera API-nyckeln och nätverket.")
        end
        _refreshHomescreen()
    end)
end

function M.build(w, ctx)
    local ok_build, result = pcall(_doBuild, w, ctx)
    if ok_build then
        return result
    else
        logger.warn("simpleui hardcover: M.build crashed: " .. tostring(result))
        local face = Font:getFace("cfont", _BASE_BODY_FS)
        return TextWidget:new{ text = "Hardcover: " .. tostring(result):sub(1, 80), face = face }
    end
end

function _doBuild(w, ctx)
    local api_key = _getApiKey()

    if api_key == "" then
        return _buildPlaceholder(w, _("Hardcover: ange API-nyckel i modulinställningarna."))
    end

    local cached = _getCached()
    local layout  = _getLayout()
    local widget

    if cached then
        if layout == "row" then
            widget = _buildRow(w, cached)
        else
            widget = _buildCard(w, cached)
        end
    elseif _last_error then
        widget = _buildPlaceholder(w, _last_error)
    else
        widget = _buildPlaceholder(w, _("Hardcover: hämtar data…"))
    end

    -- Wrap with internal label if the user has it enabled.
    -- We do NOT use Config.applyLabelToggle / M.label because SimpleUI would
    -- then call sectionLabel(mod.label, inner_w) with the *full* screen width,
    -- which breaks the LeviiStar bento-grid patch.  Building the label here
    -- ensures it is always sized to `w` (the bento-reduced width).
    if not Config.isLabelHidden("hardcover") then
        local vg = VerticalGroup:new{ align = "left" }
        vg[1] = _buildLabel(w)
        vg[2] = widget
        widget = vg
    end

    M.ensureFresh()

    return widget
end

function M.getHeight(ctx)
    local label_h = (not Config.isLabelHidden("hardcover")) and Config.getScaledLabelH() or 0
    local scale   = Config.getModuleScale("hardcover")
    if _getApiKey() == "" then
        return label_h + math.floor(_BASE_BODY_FS * scale) + PAD * 2
    end
    if _getLayout() == "row" then
        return label_h + math.max(14, math.floor(_BASE_ROW_H * scale))
    end
    return label_h + math.floor(_BASE_H * scale)
end

function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local items = {}

    -- ── Show label ────────────────────────────────────────────────────────
    items[#items + 1] = Config.makeLabelToggleItem("hardcover", _("Hardcover"), refresh, _lc)

    -- ── Type (Card / Row) ────────────────────────────────────────────────────
    items[#items + 1] = {
        text           = _lc("Type"),
        sub_item_table = {
            {
                text           = _lc("Card"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return _getLayout() == "card" end,
                callback       = function()
                    G_reader_settings:saveSetting(SK.layout, "card")
                    refresh()
                end,
            },
            {
                text           = _lc("Row"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return _getLayout() == "row" end,
                callback       = function()
                    G_reader_settings:saveSetting(SK.layout, "row")
                    refresh()
                end,
            },
        },
        separator = true,
    }

    -- ── Scale ──────────────────────────────────────────────────────────────
    items[#items + 1] = Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("hardcover", ctx_menu.pfx) end,
        set          = function(v) Config.setModuleScale(v, "hardcover", ctx_menu.pfx) end,
        refresh      = refresh,
    })

    -- ── Text Size ─────────────────────────────────────────────────────────
    items[#items + 1] = Config.makeScaleItem({
        text_func     = function()
            local pct = _getTextScalePct()
            return pct == _HC_TEXT_SCALE_DEF
                and _lc("Text Size")
                or  string.format(_lc("Text Size — %d%%"), pct)
        end,
        title         = _lc("Text Size"),
        info          = _lc("Size of the text inside the Hardcover widget.\n100% is the default size."),
        get           = _getTextScalePct,
        set           = function(pct) G_reader_settings:saveSetting(SK.text_scale, pct) end,
        refresh       = refresh,
        value_min     = _HC_TEXT_SCALE_MIN,
        value_max     = _HC_TEXT_SCALE_MAX,
        value_step    = _HC_TEXT_SCALE_STEP,
        default_value = _HC_TEXT_SCALE_DEF,
        separator     = true,
    })

    -- ── API key ───────────────────────────────────────────────────────────
    items[#items + 1] = {
        text_func = function()
            local k = _getApiKey()
            if k == "" then
                return _lc("API-nyckel: (ej angiven)")
            else
                return _lc("API-nyckel: ****") .. k:sub(-4)
            end
        end,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager   = require("ui/uimanager")
            local dlg
            dlg = InputDialog:new{
                title       = _lc("Hardcover API-nyckel"),
                description = _lc("hardcover.app → Inställningar → Utvecklare"),
                input       = _getApiKey(),
                buttons = {{
                    {
                        text     = _lc("Avbryt"),
                        callback = function() UIManager:close(dlg) end,
                    },
                    {
                        text             = _lc("Spara"),
                        is_enter_default = true,
                        callback = function()
                            local raw = dlg:getInputText()
                            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                            raw = raw:gsub("^[Bb]earer%s+", "")
                            raw = raw:gsub('^"(.*)"$', "%1")
                            G_reader_settings:saveSetting(SK.api_key, raw)
                            -- Invalidate cache so the next build fetches fresh data
                            G_reader_settings:saveSetting(SK.cache_time, 0)
                            UIManager:close(dlg)
                            if refresh then refresh() end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
        end,
        keep_menu_open = false,
    }

    -- ── Manual refresh ────────────────────────────────────────────────────
    items[#items + 1] = {
        text     = _lc("Uppdatera nu"),
        enabled_func = function() return _getApiKey() ~= "" end,
        callback = function()
            local api_key = _getApiKey()
            if api_key == "" then return end
            -- Force-reset the pending guard so a manual refresh always fires,
            -- even if a background fetch got stuck.
            _fetch_pending = false
            G_reader_settings:saveSetting(SK.cache_time, 0)
            _fetch_pending = true
            local UIManager  = require("ui/uimanager")
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
                text    = _("Hardcover: hämtar data…"),
                timeout = 3,
            })
            _fetchAsync(api_key, function(goal)
                _fetch_pending = false
                if goal then
                    UIManager:show(Notification:new{
                        text    = _("Hardcover: uppdaterad!"),
                        timeout = 3,
                    })
                else
                    UIManager:show(Notification:new{
                        text    = _("Hardcover: kunde inte hämta data."),
                        timeout = 5,
                    })
                end
                _refreshHomescreen()
            end)
        end,
        keep_menu_open = false,
    }

    -- ── Cache TTL ─────────────────────────────────────────────────────────
    items[#items + 1] = {
        text_func = function()
            return string.format(_lc("Uppdateringsintervall: %d min"), _getCacheTtlMin())
        end,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager   = require("ui/uimanager")
            local dlg
            dlg = InputDialog:new{
                title      = _lc("Uppdateringsintervall (minuter)"),
                input      = tostring(_getCacheTtlMin()),
                input_type = "number",
                buttons = {{
                    {
                        text     = _lc("Avbryt"),
                        callback = function() UIManager:close(dlg) end,
                    },
                    {
                        text             = _lc("OK"),
                        is_enter_default = true,
                        callback = function()
                            local val = math.max(5, math.min(1440,
                                tonumber(dlg:getInputText()) or CACHE_TTL_DEFAULT))
                            G_reader_settings:saveSetting(SK.cache_ttl, val)
                            UIManager:close(dlg)
                            if refresh then refresh() end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
        end,
        keep_menu_open = false,
    }

    return items
end

return M
