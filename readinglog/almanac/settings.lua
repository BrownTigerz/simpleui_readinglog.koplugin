--[[
Reading Log settings: the dialogs behind long-press > "Module settings".

Each card has a short dialog of its own options, followed by the rows every
card shares: what a tap on it does, its colour, and "Look and colours" (theme,
accents, week start), which applies to all the cards at once.

Dialogs follow the pattern Bookshelf's own modules use: pick something, the
dialog closes, the card redraws, the dialog comes back with the new value.
]]

local A = ...
local D = A.D
local P = A.panels
local S = {}
A.S = S

local function tr(s)
    local ok, i18n = pcall(require, "lib/bookshelf_i18n")
    if ok and i18n and i18n.gettext then return i18n.gettext(s) end
    return s
end

local CHECK = "\xE2\x9C\x93 "
local ELLIPSIS = "\xE2\x80\xA6"

-- Redraw the card these settings belong to.
local function reload(ctx)
    D.invalidate()
    if ctx and ctx.menu and ctx.menu._reload then pcall(ctx.menu._reload, ctx.menu) end
end
S.reload = reload

-- Redraw every card: a theme or text-size change touches all of them. In the
-- grids that means asking Bookshelf to rebuild the grid; the start menu's
-- own reload already redraws the whole menu.
local function reloadAll(ctx)
    D.invalidate()
    local bw = ctx and ctx.bw
    if bw and ctx.surface == "hero" then
        local ok, HeroModules = pcall(require, "lib/bookshelf_hero_modules")
        if ok and HeroModules and HeroModules._rebuild and pcall(HeroModules._rebuild, bw) then return end
    end
    if ctx and ctx.menu and ctx.menu._reload then pcall(ctx.menu._reload, ctx.menu) end
end

-- S.open(ctx, title, rows_fn, all): rows_fn(api) returns ButtonDialog rows.
--   api.again()   show this dialog again (nothing changed)
--   api.changed() redraw the card (every card when `all`), then show this dialog again
--   api.close()
function S.open(ctx, title, rows_fn, all)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local dialog
    local api = {}
    function api.close() if dialog then UIManager:close(dialog) end end
    function api.again() api.close(); S.open(ctx, title, rows_fn, all) end
    function api.changed()
        api.close()
        if all then reloadAll(ctx) else reload(ctx) end
        S.open(ctx, title, rows_fn, all)
    end
    local rows = rows_fn(api)
    rows[#rows + 1] = { { text = tr("Close"), callback = function() api.close() end } }
    dialog = ButtonDialog:new{
        title = title, title_align = "center", width_factor = 0.86, buttons = rows,
    }
    UIManager:show(dialog)
end

function S.header(text) return { { text = text, enabled = false } } end

-- A row of radio buttons. options = { { value, label }, ... }
function S.radio(api, options, current, on_pick)
    local row = {}
    for _, opt in ipairs(options) do
        local active = opt[1] == current
        row[#row + 1] = {
            text = (active and CHECK or "") .. tostring(opt[2]),
            callback = function()
                if active then return end
                on_pick(opt[1])
                api.changed()
            end,
        }
    end
    return row
end

local function shorten(v, n)
    v = tostring(v)
    if #v > n then return v:sub(1, n - 1) .. ELLIPSIS end
    return v
end

-- "Label: value" row that opens a text or number prompt.
-- o = { hint=, number=bool, min=, max=, empty_label=, description= }
function S.input(api, label, value, on_save, o)
    o = o or {}
    local shown = (value == nil or value == "") and (o.empty_label or "not set") or shorten(value, 28)
    return { {
        text = label .. ": " .. shown,
        callback = function()
            api.close()
            local UIManager = require("ui/uimanager")
            local InputDialog = require("ui/widget/inputdialog")
            local input
            input = InputDialog:new{
                title = label,
                description = o.description,
                input = value ~= nil and tostring(value) or "",
                input_hint = o.hint,
                input_type = o.number and "number" or nil,
                buttons = { {
                    { text = tr("Cancel"), id = "close", callback = function()
                        UIManager:close(input)
                        api.again()
                    end },
                    { text = tr("Save"), is_enter_default = true, callback = function()
                        local txt = input:getInputText() or ""
                        UIManager:close(input)
                        if o.number then
                            local n = tonumber(txt)
                            if n then
                                n = math.floor(n)
                                if o.min and n < o.min then n = o.min end
                                if o.max and n > o.max then n = o.max end
                                on_save(n)
                            end
                        else
                            on_save((txt:gsub("^%s+", ""):gsub("%s+$", "")))
                        end
                        api.changed()
                    end },
                } },
            }
            UIManager:show(input)
            input:onShowKeyboard()
        end,
    } }
end

-- "Label: 4 Oct 2026" row that opens KOReader's date picker.
function S.date(api, label, value, on_save)
    local y, m, d = A.parseYmd(value)
    local shown = y and (d .. " " .. A.date("%b", os.time{ year = y, month = m, day = d, hour = 12 }) .. " " .. y) or "not set"
    return { {
        text = label .. ": " .. shown,
        callback = function()
            api.close()
            local UIManager = require("ui/uimanager")
            local DateTimeWidget = require("ui/widget/datetimewidget")
            if not y then
                local t = os.date("*t")
                y, m, d = t.year, t.month, t.day
            end
            UIManager:show(DateTimeWidget:new{
                year = y, month = m, day = d,
                ok_text = tr("Set date"),
                title_text = label,
                callback = function(t)
                    on_save(string.format("%04d-%02d-%02d", t.year, t.month, t.day))
                    api.changed()
                end,
                cancel_callback = function() api.again() end,
            })
        end,
    } }
end

-- "Label: value" row that opens a list to pick one from.
-- options = { { value, label }, ... }
function S.pick(ctx, api, label, options, current, on_pick)
    local shown = "not set"
    for _, opt in ipairs(options) do
        if opt[1] == current then shown = shorten(opt[2], 28) end
    end
    return { {
        text = label .. ": " .. shown,
        callback = function()
            api.close()
            S.open(ctx, label, function(sub)
                local rows = {}
                for _, opt in ipairs(options) do
                    rows[#rows + 1] = { {
                        text = ((opt[1] == current) and CHECK or "") .. shorten(opt[2], 44),
                        callback = function()
                            on_pick(opt[1])
                            sub.close()
                            reload(ctx)
                            api.again()
                        end,
                    } }
                end
                if #rows == 0 then rows[1] = S.header("Nothing to choose from yet") end
                -- replace the sub-dialog's own Close with "back to the card's settings"
                rows[#rows + 1] = { { text = tr("Back"), callback = function() sub.close(); api.again() end } }
                return rows
            end)
        end,
    } }
end

-- ─── per-card rows ───────────────────────────────────────────────────────────


local function collectionOptions(with_none)
    local names = D.collections()
    local out = {}
    if with_none then out[1] = { "", with_none } end
    for _, n in ipairs(names) do out[#out + 1] = { n, D.collectionLabel(n) } end
    return out
end

local ROWS = {}

ROWS.banner = function(env, api)
    return {
        S.header("Style"),
        S.radio(api, { { "heading", "Heading" }, { "glance", "At a glance" }, { "classic", "Classic" } },
            env.cfg("style", "heading"), function(v) env.setcfg("style", v) end),
        S.input(api, "Top line", env.cfg("line1", ""), function(v) env.setcfg("line1", v) end,
            { hint = "e.g. Sam's", empty_label = "(hidden)" }),
        S.input(api, "Bottom line", env.cfg("line2", ""), function(v) env.setcfg("line2", v) end,
            { hint = "e.g. My Library", empty_label = "(hidden)" }),
    }
end

ROWS.continue = function(env, api)
    return {
        S.header("How many books to cycle through"),
        S.radio(api, { { 3, "3" }, { 5, "5" }, { 8, "8" } }, tonumber(env.cfg("count", 5)) or 5,
            function(v) env.setcfg("count", v) end),
    }
end

ROWS.activity = function(env, api)
    local Store = select(2, pcall(require, "lib/bookshelf_settings_store"))
    return {
        S.input(api, "Pages a day", env.cfg("page_goal", 30), function(v) env.setcfg("page_goal", v) end,
            { number = true, min = 1, max = 2000 }),
        S.input(api, "Minutes a day", D.dailyMinutesGoal(), function(v)
            if type(Store) == "table" and Store.save then pcall(Store.save, "micromodule_reading_goal_daily", v) end
            A.epoch = A.epoch + 1
        end, { number = true, min = 1, max = 1440, description = "Shared with Bookshelf's Reading goals card." }),
        S.header("Streak ring fills at"),
        S.radio(api, { { 7, "7 days" }, { 14, "14 days" }, { 30, "30 days" } },
            tonumber(env.cfg("streak_goal", 7)) or 7, function(v) env.setcfg("streak_goal", v) end),
    }
end

ROWS.goal = function(env, api)
    local target, other = D.yearGoal()
    return {
        S.input(api, "Books this year", target, function(v) D.setYearGoal(v) end,
            { number = true, min = 1, max = 1000, description = "Shared with Bookshelf's Reading goals card." }),
        S.input(api, "Read outside KOReader", other, function(v) D.setOtherBooks(v) end,
            { number = true, min = 0, max = 1000, description = "Paper books, audiobooks or another reader. Added to this year's count." }),
    }
end

ROWS.tbr = function(env, api, ctx)
    local coll = P.tbr.collection(env)
    return {
        S.pick(ctx, api, "Collection", collectionOptions(), coll, function(v) env.setcfg("coll", v) end),
        S.input(api, "Title", env.cfg("title", ""), function(v) env.setcfg("title", v) end,
            { hint = "e.g. October TBR", empty_label = "(month) TBR" }),
        S.input(api, "Line underneath", env.cfg("tagline", ""), function(v) env.setcfg("tagline", v) end,
            { hint = "e.g. It's spooky season", empty_label = "(none)" }),
        S.header("Covers in the row"),
        S.radio(api, { { 4, "4" }, { 5, "5" }, { 6, "6" }, { 8, "8" } }, tonumber(env.cfg("count", 6)) or 6,
            function(v) env.setcfg("count", v) end),
        S.header("Label under each cover"),
        S.radio(api, { { "auto", "Auto" }, { "status", "Progress" }, { "format", "Digital / Hardcopy" }, { "none", "None" } },
            env.cfg("labels", "auto"), function(v) env.setcfg("labels", v) end),
        S.pick(ctx, api, "Hardcopy collection", collectionOptions(), env.cfg("hardcopy", "Hardcopy"),
            function(v) env.setcfg("hardcopy", v) end),
        S.header("Tapping a cover"),
        S.radio(api, { { "open", "Opens the book" }, { "details", "Shows book details" } },
            env.cfg("tap", "open"), function(v) env.setcfg("tap", v) end),
    }
end

ROWS.genres = function(env, api)
    return {
        S.header("Genres to list"),
        S.radio(api, { { 3, "3" }, { 4, "4" }, { 5, "5" } }, tonumber(env.cfg("count", 3)) or 3,
            function(v) env.setcfg("count", v) end),
    }
end

ROWS.year_covers = function(env, api)
    return {
        S.header("Layout"),
        S.radio(api, { { "wall", "Cover wall" }, { "months", "Stacked by month" } }, env.cfg("layout", "wall"),
            function(v) env.setcfg("layout", v ~= "wall" and v or nil) end),
    }
end

ROWS.week = function(env, api)
    return {
        S.header("Bars show"),
        S.radio(api, { { "pages", "Pages" }, { "minutes", "Minutes" } }, env.cfg("metric", "pages"),
            function(v) env.setcfg("metric", v) end),
    }
end

ROWS.finished = function(env, api)
    return {
        S.header("Covers in the row"),
        S.radio(api, { { 4, "4" }, { 5, "5" }, { 6, "6" }, { 8, "8" } }, tonumber(env.cfg("count", 6)) or 6,
            function(v) env.setcfg("count", v) end),
    }
end

ROWS.deadline = function(env, api, ctx)
    local books = {}
    local seen = {}
    local cur = env.cfg("book", "")
    for _, b in ipairs(D.reading(8)) do
        books[#books + 1] = { b.fp, b.title }
        seen[b.fp] = true
    end
    if cur ~= "" and not seen[cur] then
        table.insert(books, 1, { cur, D.info(cur).title })
    end
    local today = A.todayYmd()
    return {
        S.pick(ctx, api, "Book", books, cur, function(v)
            env.setcfg("book", v)
            env.setcfg("since", today)
        end),
        S.date(api, "Finish by", env.cfg("due", ""), function(v)
            env.setcfg("due", v)
            if env.cfg("since", "") == "" then env.setcfg("since", today) end
        end),
        S.input(api, "For", env.cfg("label", "Finish by"), function(v) env.setcfg("label", v) end,
            { hint = "e.g. Library loan", empty_label = "(no label)" }),
        S.date(api, "Counting from", env.cfg("since", ""), function(v) env.setcfg("since", v) end),
    }
end

-- Tick which of the collection's books are the club's picks for a month.
-- The arrows step to other months, so next month's can be lined up early.
local function clubPicks(ctx, env, back)
    local offset = 0
    local function show()
        local key, when = P.bookclub.monthKey(offset)
        local label = A.date("%B", when) .. " " .. os.date("%Y", when)
        S.open(ctx, "Book club picks", function(sub)
            local st = P.bookclub.state(env)
            local all = env.cfg("picks", nil)
            if type(all) ~= "table" then all = {} end
            local chosen = {}
            for _, fp in ipairs(type(all[key]) == "table" and all[key] or {}) do chosen[fp] = true end
            local rows = { {
                { text = "\xE2\x80\xB9", callback = function() offset = offset - 1; sub.close(); show() end },
                { text = label, enabled = false },
                { text = "\xE2\x80\xBA", callback = function() offset = offset + 1; sub.close(); show() end },
            } }
            local books = st and st.books or {}
            for _, b in ipairs(books) do
                rows[#rows + 1] = { {
                    text = (chosen[b.fp] and CHECK or "") .. shorten(b.title, 40),
                    callback = function()
                        -- keep the picks in the collection's own order
                        local list = {}
                        for _, other in ipairs(books) do
                            local on = chosen[other.fp]
                            if other.fp == b.fp then on = not on end
                            if on then list[#list + 1] = other.fp end
                        end
                        local copy = {}
                        for k, v in pairs(all) do copy[k] = v end
                        copy[key] = (#list > 0) and list or nil
                        env.setcfg("picks", copy)
                        sub.changed()
                    end,
                } }
            end
            if #books == 0 then
                rows[#rows + 1] = S.header(st and "No books in the collection yet" or "No book club collection yet")
            end
            rows[#rows + 1] = { { text = tr("Back"), callback = function() sub.close(); back() end } }
            return rows
        end)
    end
    show()
end

ROWS.bookclub = function(env, api, ctx)
    local _, when = P.bookclub.monthKey(0)
    return {
        S.pick(ctx, api, "Collection", collectionOptions(), P.bookclub.collection(env),
            function(v) env.setcfg("coll", v) end),
        { { text = A.date("%B", when) .. "'s books" .. ELLIPSIS, callback = function()
            api.close()
            clubPicks(ctx, env, api.again)
        end } },
        S.input(api, "Title", env.cfg("title", "Book club"), function(v) env.setcfg("title", v) end,
            { hint = "e.g. Book club", empty_label = "Book club" }),
    }
end

ROWS.week_rings = function(env, api)
    local Store = select(2, pcall(require, "lib/bookshelf_settings_store"))
    return {
        S.input(api, "Pages a day", A.get("activity_page_goal", 30), function(v) A.set("activity_page_goal", v) end,
            { number = true, min = 1, max = 2000, description = "Shared with the Activity rings card." }),
        S.input(api, "Minutes a day", D.dailyMinutesGoal(), function(v)
            if type(Store) == "table" and Store.save then pcall(Store.save, "micromodule_reading_goal_daily", v) end
            A.epoch = A.epoch + 1
        end, { number = true, min = 1, max = 1440, description = "Shared with Bookshelf's Reading goals card." }),
    }
end

ROWS.month_rings = ROWS.week_rings

ROWS.longest_year = function(env, api)
    return {
        S.header("Longest by"),
        S.radio(api, { { "time", "Time read" }, { "days", "Days taken" } }, env.cfg("by", "time"),
            function(v) env.setcfg("by", v) end),
        S.header("How many"),
        S.radio(api, { { 2, "2" }, { 3, "3" }, { 4, "4" }, { 5, "5" } }, tonumber(env.cfg("count", 3)) or 3,
            function(v) env.setcfg("count", v) end),
    }
end
ROWS.longest_month = ROWS.longest_year

ROWS.month_chart = function(env, api)
    return {
        S.header("Bars show"),
        S.radio(api, { { "pages", "Pages read" }, { "time", "Time read" } }, env.cfg("metric", "pages"),
            function(v) env.setcfg("metric", v) end),
    }
end

ROWS.year_chart = function(env, api)
    return {
        S.header("Pages counted"),
        S.radio(api, { { "read", "Read that month" }, { "books", "Of the books finished" } },
            env.cfg("pages", "read"), function(v) env.setcfg("pages", v) end),
    }
end

S.ROWS = ROWS

-- ─── shared rows ─────────────────────────────────────────────────────────────

local function toneOptions()
    local out = {}
    for _, t in ipairs(A.TONES) do out[#out + 1] = { t, A.toneLabel(t) } end
    return out
end

-- A grid of the accent colours to pick one from. `auto_label` adds a first
-- choice that clears the setting (the second accent's "matched" option).
local function accentPicker(ctx, title, key, current, auto_label, back)
    S.open(ctx, title, function(api)
        local rows = {}
        local function choose(id)
            return function()
                A.set(key, id)
                api.close()
                reloadAll(ctx)
                back()
            end
        end
        if auto_label then
            rows[#rows + 1] = { { text = ((A.get(key, nil) == nil) and CHECK or "") .. auto_label, callback = choose(nil) } }
        end
        local row = {}
        for _, id in ipairs(A.ACCENT_ORDER) do
            row[#row + 1] = { text = ((id == current) and CHECK or "") .. A.ACCENTS[id].label, callback = choose(id) }
            if #row == 3 then rows[#rows + 1] = row; row = {} end
        end
        if #row > 0 then rows[#rows + 1] = row end
        rows[#rows + 1] = { { text = tr("Back"), callback = function() api.close(); back() end } }
        return rows
    end, true)
end

function S.look(ctx, back)
    local function again() S.look(ctx, back) end
    S.open(ctx, "Look and colours", function(api)
        local themes = {}
        for _, id in ipairs(A.THEME_ORDER) do themes[#themes + 1] = { id, A.THEMES[id].label } end
        local a1, a2 = A.accentIds()
        local matched = A.get("accent2", nil) == nil
        local rows = {
            S.header("Theme"),
            S.radio(api, themes, A.themeId(), function(v) A.set("theme", v) end),
            -- Two accent colours, used for labels, rings, bars and buttons.
            -- A card's own "Card colour" setting decides which of the two leads.
            { { text = "Accent colour: " .. A.ACCENTS[a1].label, callback = function()
                api.close()
                accentPicker(ctx, "Accent colour", "accent", a1, nil, again)
            end } },
            { { text = "Second accent: " .. A.ACCENTS[a2].label .. (matched and " (matched)" or ""), callback = function()
                api.close()
                accentPicker(ctx, "Second accent", "accent2", (not matched) and a2 or nil,
                    "Matched to the first", again)
            end } },
            -- Cards placed on their own in Bookshelf's grids (not in the
            -- Dashboard): Bookshelf's card as theirs, or the theme's frame.
            S.header("Cards on their own"),
            S.radio(api, { { "native", "Match Bookshelf" }, { "framed", "Framed, in the theme" } },
                A.standaloneNative() and "native" or "framed",
                function(v) A.set("standalone", v ~= "native" and v or nil) end),
            S.header("Week starts on"),
            S.radio(api, { { 0, "Follow KOReader" }, { 2, "Monday" }, { 1, "Sunday" } },
                tonumber(A.get("week_start", 0)) or 0, function(v) A.set("week_start", v ~= 0 and v or nil) end),
        }
        rows[#rows + 1] = { { text = "Diagnostics" .. ELLIPSIS, callback = function()
            api.close()
            S.diagnostics(ctx, again)
        end } }
        if back then
            rows[#rows + 1] = { { text = tr("Back"), callback = function() api.close(); back() end } }
        end
        return rows
    end, true)
end

-- What this device and this session look like from here: the facts needed to
-- tell why something looks or refreshes the way it does on a screen nobody
-- but the reader can see. Nothing is changed by opening it.
function S.diagnostics(ctx, back)
    local function yn(v) return v and "on" or "off" end
    local function safe(fn, fallback)
        local ok, v = pcall(fn)
        if ok and v ~= nil then return v end
        return fallback
    end
    S.open(ctx, A.NAME .. " diagnostics", function(api)
        local Screen = A.screen()
        local Device = safe(function() return require("device") end, {})
        local ko = safe(function() return require("version"):getCurrentRevision() end, "?")
        -- Bookshelf's version, from the _meta.lua beside the code that is running
        local shelf = safe(function()
            local Kit = require("lib/bookshelf_module_kit")
            local fn
            for _, v in pairs(Kit) do if type(v) == "function" then fn = v break end end
            local src = debug.getinfo(fn, "S").source:gsub("^@", "")
            return dofile(src:match("^(.*)/lib/[^/]*$") .. "/_meta.lua").version
        end, "?")
        local fs = ctx and ctx.bw and ctx.bw._micro_fullscreen
        local n = A.counts
        local lines = {
            A.NAME .. " " .. A.VERSION .. "  \xC2\xB7  Bookshelf " .. tostring(shelf),
            "KOReader " .. tostring(ko),
            tostring(Device.model or "?") .. "  \xC2\xB7  " .. Screen:getWidth() .. "x" .. Screen:getHeight()
                .. "  \xC2\xB7  colour " .. yn(safe(function() return Screen:isColorEnabled() end, false)),
            "Night mode " .. yn(Screen.night_mode) .. "  \xC2\xB7  page looks " .. (A.pageLooksDark() and "dark" or "light"),
            "Hardware dithering " .. yn(Screen.hw_dithering) .. "  \xC2\xB7  avoid flashes "
                .. yn(safe(function() return G_reader_settings:isTrue("avoid_flashing_ui") end, false)),
            "Theme " .. A.themeId() .. "  \xC2\xB7  refresh " .. A.refreshMode()
                .. "  \xC2\xB7  in full-screen view: " .. (fs and "yes" or "no"),
            "Opened " .. n.views .. "  \xC2\xB7  flashes asked " .. n.flashes .. "  \xC2\xB7  clock re-inks " .. n.reinks,
            "Clock updates narrowed " .. n.narrowed .. "  \xC2\xB7  stray pixels stopped " .. n.clipped,
        }
        local rows = {}
        for _, l in ipairs(lines) do rows[#rows + 1] = S.header(l) end
        rows[#rows + 1] = { { text = "Flash the screen clean now", callback = function()
            api.close()
            A.cleanScreen()
        end } }
        if back then
            rows[#rows + 1] = { { text = tr("Back"), callback = function() api.close(); back() end } }
        end
        return rows
    end)
end

-- What a tap on a card does: the card's own thing (open the book, list a
-- month's books, the reading calendar), the reading calendar or progress,
-- or anything else KOReader or a plugin can do, picked with Bookshelf's own
-- action chooser (the one its Action module and start menu use).
local BUILTIN_TAPS = {
    { id = "stats_calendar_view", label = "Reading calendar" },
    { id = "reading_progress", label = "Reading progress" },
}

function S.tapLabel(name)
    local e = A.tapAction(name)
    if not e then return "the card's own" end
    return e.label or "an action"
end

function S.tapChooser(ctx, name, back)
    local def = P[name]
    S.open(ctx, def.title .. ": when tapped", function(api)
        local cur = A.tapAction(name)
        local cur_id = cur and type(cur.action) == "table" and next(cur.action) or nil
        local function done(entry)
            A.set(name .. "_tap_action", entry)
            api.close()
            if back then back() end
        end
        local rows = {}
        rows[#rows + 1] = { { text = (cur == nil and CHECK or "") .. "The card's own: " .. (def.does or "as it comes"),
            callback = function() done(nil) end } }
        local row = {}
        for _, b in ipairs(BUILTIN_TAPS) do
            local on = cur ~= nil and cur_id == b.id and cur.builtin
            row[#row + 1] = { text = (on and CHECK or "") .. b.label, callback = function()
                done({ label = b.label, action = { [b.id] = true }, builtin = true })
            end }
        end
        rows[#rows + 1] = row
        local ok, Chooser = pcall(require, "lib/bookshelf_action_chooser")
        if ok and type(Chooser) == "table" and Chooser.actionRows then
            rows[#rows + 1] = S.header((cur and not cur.builtin) and (CHECK .. "Now: " .. tostring(cur.label or "an action"))
                or "Or anything else:")
            local function close(fn) return function() api.close(); fn() end end
            local ok2, extra = pcall(Chooser.actionRows, close, function(fields)
                fields.builtin = nil
                A.set(name .. "_tap_action", fields)
                if back then back() end
            end)
            if ok2 and type(extra) == "table" then
                for _, r in ipairs(extra) do rows[#rows + 1] = r end
            end
        end
        rows[#rows + 1] = S.header("Buttons on the card (Continue, Details, +, \xE2\x88\x92) keep their own job.")
        if back then
            rows[#rows + 1] = { { text = tr("Back"), callback = function() api.close(); back() end } }
        end
        return rows
    end)
end

-- The settings dialog for one card. env_fn() builds a fresh env each time the
-- dialog is shown (tone and slot can change while it is open). `back`
-- (optional) returns to a parent dialog.
function S.card(name, ctx, env_fn, back)
    local def = P[name]
    local function show()
        S.open(ctx, def.title, function(api)
            local env = env_fn()
            local rows = ROWS[name] and ROWS[name](env, api, ctx) or {}
            if def.slots and not env.nested and ctx and ctx.config then
                rows[#rows + 1] = S.header("This card shows")
                local row = {}
                for i = 1, 3 do
                    local active = env.slot == i
                    row[#row + 1] = {
                        text = (active and CHECK or "") .. "Set " .. i,
                        callback = function()
                            if active then return end
                            api.close()
                            -- saving the entry redraws the card; then show the new set
                            ctx.config:set("alm_slot", i)
                            D.invalidate()
                            show()
                        end,
                    }
                end
                rows[#rows + 1] = row
            end
            if name ~= "dashboard" then
                rows[#rows + 1] = { { text = "When tapped: " .. S.tapLabel(name) .. ELLIPSIS, callback = function()
                    api.close()
                    S.tapChooser(ctx, name, show)
                end } }
            end
            rows[#rows + 1] = S.header("Card colour")
            local tones = toneOptions()
            local function pickTone(v) A.set(name .. "_tone", v) end
            rows[#rows + 1] = S.radio(api, { tones[1], tones[2] }, env.tone.name, pickTone)
            rows[#rows + 1] = S.radio(api, { tones[3], tones[4] }, env.tone.name, pickTone)
            rows[#rows + 1] = { { text = "Look and colours" .. ELLIPSIS, callback = function()
                api.close()
                S.look(ctx, show)
            end } }
            if back then
                rows[#rows + 1] = { { text = tr("Back"), callback = function() api.close(); back() end } }
            end
            return rows
        end)
    end
    show()
end

return S
