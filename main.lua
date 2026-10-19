-- Reading Log for SimpleUI v1.5.3, by TK. Licensed AGPL-3.0.
-- Bundles the Reading Log kit by stevenzamora1
-- (https://github.com/stevenzamora1/reading-log) — thank you!
-- Full license text: see LICENSE in this folder.
--[[
Reading Log for SimpleUI
------------------------
Runs the Reading Log cards (github.com/stevenzamora1/reading-log, AGPL-3.0)
as SimpleUI home screen modules, without Bookshelf.

Reading Log is written as Bookshelf micro-modules: render(ctx) returns a
canvas widget, taps arrive as ctx.tapped_region, settings go through
Bookshelf's module store. This plugin stands in for Bookshelf:
  * builds the ctx Reading Log expects from SimpleUI's build(w, ctx)
  * wraps each canvas in a tap handler that resolves the canvas's own tap
    regions and calls Reading Log's on_tap / keep_open
  * gives Reading Log its own settings file instead of Bookshelf's store
  * registers everything with SimpleUI's external module registry

The Reading Log kit itself lives untouched in readinglog/almanac/.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local UIManager       = require("ui/uimanager")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local Device          = require("device")
local logger          = require("logger")
local _               = require("gettext")

local Screen = Device.screen
local floor, max, min = math.floor, math.max, math.min

local DIR      = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
local KIT_PATH = DIR .. "/readinglog/almanac/init.lua"
local TAG      = "[simpleui_readinglog]"

-- ─── settings file ──────────────────────────────────────────────────────────

local _store, _flush_queued
local function store()
    if not _store then
        _store = LuaSettings:open(DataStorage:getSettingsDir() .. "/simpleui_readinglog.lua")
    end
    return _store
end

local function sget(key, default)
    local v = store():readSetting(key)
    if v == nil then return default end
    return v
end

local function sput(key, value)
    local s = store()
    if value == nil then s:delSetting(key) else s:saveSetting(key, value) end
    if not _flush_queued then
        _flush_queued = true
        UIManager:scheduleIn(1, function()
            _flush_queued = false
            pcall(s.flush, s)
        end)
    end
end

-- ─── SimpleUI access ────────────────────────────────────────────────────────

local function suiRequire(path)
    local m = package.loaded[path]
    if m then return m end
    local ok, r = pcall(require, path)
    if ok and type(r) == "table" then return r end
    return nil
end

-- Debug lines go through the SimpleUI diagnostics patch when it is installed
-- and logging (it owns the window/expiry); otherwise nowhere.
local function diag(fmt, ...)
    local D = package.loaded["simpleui_diagnostics"]
    if type(D) == "table" and type(D.log) == "function" then
        pcall(D.log, "readinglog: " .. fmt, ...)
    end
end

local function now_ms()
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.now then return time.to_ms(time.now()) end
    return floor(os.clock() * 1000)
end

-- Refreshes asked for, by reason, over a 10 s window. More than a handful in
-- that window means something keeps asking (e.g. a background read that
-- never settles) and the screen is redrawing in a loop.
local _rf = { t0 = 0, n = 0, by = {}, warned = false }
local function noteRefresh(reason)
    local t = os.time()
    if t - _rf.t0 >= 10 then _rf.t0, _rf.n, _rf.by, _rf.warned = t, 0, {}, false end
    _rf.n = _rf.n + 1
    _rf.by[reason] = (_rf.by[reason] or 0) + 1
    if _rf.n > 6 and not _rf.warned then
        _rf.warned = true
        local bits = {}
        for k, n in pairs(_rf.by) do bits[#bits + 1] = n .. " x " .. k end
        diag("POSSIBLE REFRESH LOOP: %d home screen refreshes in 10 s (%s)", _rf.n, table.concat(bits, ", "))
    end
end

local _refresh_queued = false
local function refreshScreen(reason)
    reason = reason or "?"
    noteRefresh(reason)
    diag("refresh home screen (%s)", reason)
    -- several asks in one tick (two cards' data landing together) = one rebuild
    if _refresh_queued then return end
    _refresh_queued = true
    UIManager:nextTick(function()
        _refresh_queued = false
        local SE = suiRequire("engines/sui_screen_engine")
        if SE and SE.refreshAllLiveImmediate then
            pcall(SE.refreshAllLiveImmediate, true)
        elseif SE and SE.refresh then
            pcall(SE.refresh, true)
        end
    end)
end

local function contentHeight()
    local UI = suiRequire("infra/sui_core")
    if UI and UI.getContentHeight then
        local ok, h = pcall(UI.getContentHeight)
        if ok and tonumber(h) then return h end
    end
    return floor(Screen:getHeight() * 0.85)
end

-- Which window each card was last painted in. Filled by the card's own
-- paintTo and the home-window watch below, so it never depends on SimpleUI
-- internals (which differ between SimpleUI builds).
local INSTANCES = {}

-- The window currently showing card `mod_id` (it was painted in that
-- window's last paint), or nil.
local function screenShowing(mod_id)
    local inst = INSTANCES[mod_id]
    local w = inst and inst.on
    if not w then return nil end
    -- the window must still be open
    for _i, e in ipairs(UIManager._window_stack or {}) do
        if e.widget == w then return w end
    end
    inst.on = nil
    return nil
end

local function contentTop()
    local UI = suiRequire("infra/sui_core")
    if UI and type(UI.getContentTop) == "function" then
        local ok, y = pcall(UI.getContentTop)
        if ok and tonumber(y) then return y end
    end
    return nil
end

-- Dashboard layout: "card" (sits in SimpleUI's page like any module) or
-- "full" (fills everything between SimpleUI's status bar and nav bar).
local function dashFull()
    return sget("dash_layout", "card") == "full" and contentTop() ~= nil
end

local function innerWidth()
    local UI = suiRequire("infra/sui_core")
    if UI and UI.getInnerW then
        local ok, w = pcall(UI.getInnerW)
        if ok and tonumber(w) then return w end
    end
    return Screen:getWidth()
end

-- ─── Reading Log kit (loaded on first use) ──────────────────────────────────

local function bookshelfInstalled()
    local lfs = require("libs/libkoreader-lfs")
    local plugins = DIR:match("^(.*)/[^/]+$") or "."
    return lfs.attributes(plugins .. "/bookshelf.koplugin", "mode") == "directory"
end

-- The card in the Today page's book club slot (Dashboard settings →
-- "Today page card"). Year goal with covers unless you pick another.
local TODAY_CHOICES = {
    { "goal_covers", "Year Goal With Covers" },
    { "goal",        "Year Goal" },
    { "bookclub",    "Book Club" },
    { "finished",    "Recently Finished" },
    { "tbr",         "TBR Shelf" },
}
local TODAY_SLOT = nil
local function todayCard()
    local v = sget("today_card", "goal_covers")
    for _i, c in ipairs(TODAY_CHOICES) do if c[1] == v then return v end end
    return "goal_covers"
end

local A, _kit_failed
local function kit()
    if A then return A end
    if _kit_failed then return nil end

    -- Year goal / daily goal live in Bookshelf's settings store. With no
    -- Bookshelf around, give Reading Log one backed by our file. (Never
    -- shadow the real one when Bookshelf is installed.)
    if not bookshelfInstalled() and not package.loaded["lib/bookshelf_settings_store"] then
        package.loaded["lib/bookshelf_settings_store"] = {
            read = function(key, default) return sget("bs_" .. key, default) end,
            save = function(key, value) sput("bs_" .. key, value) end,
        }
    end

    local t0 = now_ms()
    local ok, res = pcall(dofile, KIT_PATH)
    if not ok or type(res) ~= "table" then
        _kit_failed = true
        logger.err(TAG, "could not load Reading Log kit:", res)
        diag("KIT FAILED to load from %s: %s", KIT_PATH, tostring(res))
        return nil
    end
    A = res
    diag("kit %s loaded in %d ms (Bookshelf installed: %s, goal store: %s)",
        tostring(A.VERSION), now_ms() - t0, tostring(bookshelfInstalled()),
        bookshelfInstalled() and "Bookshelf's" or "this plugin's")

    -- Own settings file instead of Bookshelf's module store.
    A.get = function(key, default)
        local v = sget("kit_" .. key)
        if v == nil then return default end
        return v
    end
    A.set = function(key, value)
        sput("kit_" .. key, value)
        A.epoch = (A.epoch or 0) + 1
    end
    -- Goals: SimpleUI's Reading Goals are the ones that count. The year goal
    -- and the daily minutes target are read from (and written to) SimpleUI,
    -- so setting them in either place changes both. Books read outside
    -- KOReader stay Reading Log's own (SimpleUI has no such setting).
    local function suiGoals()
        local G = suiRequire("infra/sui_goals")
        if G and type(G.get) == "function" and type(G.setUnits) == "function" then return G end
        return nil
    end
    local D = A.D
    local origYearGoal, origSetYear, origDaily = D.yearGoal, D.setYearGoal, D.dailyMinutesGoal
    D.yearGoal = function()
        local target, other = origYearGoal()
        local G = suiGoals()
        if G then
            local ok, v = pcall(G.get, "annual")
            if ok and tonumber(v) and tonumber(v) > 0 then target = floor(tonumber(v)) end
        end
        return target, other
    end
    D.setYearGoal = function(target)
        local G = suiGoals()
        if G and tonumber(target) and tonumber(target) > 0 then
            pcall(G.setUnits, "annual", floor(tonumber(target)))
            A.epoch = (A.epoch or 0) + 1
            diag("year goal set to %s (saved to SimpleUI's Reading Goals)", tostring(target))
            return
        end
        return origSetYear(target)
    end
    D.dailyMinutesGoal = function()
        local G = suiGoals()
        if G then
            local ok, v = pcall(G.get, "daily")
            if ok and tonumber(v) and tonumber(v) > 0 then return max(1, floor(tonumber(v) / 60)) end
        end
        return origDaily()
    end

    -- Size (Appearance) reaches big text too, at half strength.
    A.BIG_TEXT_SHARE = 0.5

    -- Bookshelf's grey module card → SimpleUI's white page.
    A.pageColors = function()
        return { 255, 255, 255 }, { 0, 0, 0 }, { 0x55, 0x55, 0x55 }
    end
    -- Today page: "Year Goal With Covers" in place of Book club (which
    -- needs a book club collection). Only the built-in page changes; a page
    -- you've edited in Pages and cards keeps what you chose.
    if A.panels and A.panels.goal_covers then
        A.DASH_WEIGHT.goal_covers = 0.27
        local listed = false
        for _i, n in ipairs(A.DASH_CARDS) do if n == "goal_covers" then listed = true end end
        if not listed then
            for i, n in ipairs(A.DASH_CARDS) do
                if n == "goal" then table.insert(A.DASH_CARDS, i + 1, "goal_covers"); listed = true; break end
            end
            if not listed then A.DASH_CARDS[#A.DASH_CARDS + 1] = "goal_covers" end
        end
        for _i, page in ipairs(A.DASH_PAGES) do
            if page.id == "today" then
                for _j, row in ipairs(page.rows) do
                    for k, name in ipairs(row) do
                        if name == "bookclub" then
                            TODAY_SLOT = { row = row, k = k }
                            row[k] = todayCard()
                        end
                    end
                end
            end
        end
    end

    -- Tab order: Today, Monthly, Yearly. Pages are stored by id, not by
    -- position, so reordering keeps everyone's edited pages intact.
    local ORDER = { today = 1, monthly = 2, yearly = 3 }
    table.sort(A.DASH_PAGES, function(a, b)
        return (ORDER[a.id] or 99) < (ORDER[b.id] or 99)
    end)

    -- "Details" on a book: SimpleUI's own long-press book menu (mark
    -- finished / on hold, collections, book info, ...) instead of
    -- Bookshelf's detail page, which needs Bookshelf's shelf window.
    local D = A.D
    local origDetails = D.showDetails
    D.showDetails = function(ctx, fp)
        local mod_id = ctx and ctx.entry and ctx.entry.id
        local sw = mod_id and (screenShowing(mod_id) or (INSTANCES[mod_id] and INSTANCES[mod_id].lastwin))
        if sw and type(sw._showBookHoldDialog) == "function" and fp then
            local okh, Hold = pcall(require, "features/library/sui_book_hold_dialog")
            -- Wrap this one call's refresh so Reading Log re-reads its data
            -- after a status change (finished, on hold, reset...).
            local orig_show = okh and type(Hold) == "table" and Hold.show
            if orig_show then
                Hold.show = function(file, opts, ...)
                    Hold.show = orig_show
                    if type(opts) == "table" and type(opts.refresh_fn) == "function" then
                        local rf = opts.refresh_fn
                        opts.refresh_fn = function(...)
                            A.epoch = (A.epoch or 0) + 1
                            pcall(D.invalidate)
                            return rf(...)
                        end
                    end
                    return orig_show(file, opts, ...)
                end
            end
            local ok, err = pcall(sw._showBookHoldDialog, sw, fp, mod_id)
            if orig_show then Hold.show = orig_show end
            diag("details %s -> SimpleUI book menu%s", tostring(fp), ok and "" or (" FAILED: " .. tostring(err)))
            if ok then return end
        end
        -- older SimpleUI: call its book menu directly
        local okh, Hold = pcall(require, "features/library/sui_book_hold_dialog")
        if okh and type(Hold) == "table" and type(Hold.show) == "function" and fp then
            local ok = pcall(Hold.show, fp, {
                refresh_fn = function()
                    A.epoch = (A.epoch or 0) + 1
                    pcall(D.invalidate)
                    refreshScreen("book status changed")
                end,
            })
            diag("details %s -> SimpleUI book menu (direct)%s", tostring(fp), ok and "" or " FAILED")
            if ok then return end
        end
        diag("details %s -> no SimpleUI book menu found, opening the book", tostring(fp))
        return origDetails(ctx, fp)
    end

    -- Reading Log paints every theme pre-inverted so it looks the same day
    -- and night. Follow night mode instead: swap to a night theme (Dark by
    -- default) while night mode is on.
    local dayThemeId = A.themeId
    A.themeId = function()
        if Screen.night_mode then
            local t = sget("night_theme", "dark")
            if t ~= "off" and A.THEMES[t] then return t end
        end
        return dayThemeId()
    end
    return A
end

-- ─── module instances ───────────────────────────────────────────────────────

-- Card names (Reading Log's panel ids) and their titles.
local CARDS = {
    { "banner",        "Banner" },
    { "continue",      "Continue Reading" },
    { "activity",      "Activity Rings" },
    { "week_rings",    "Week Rings" },
    { "week",          "This Week" },
    { "goal",          "Year Goal" },
    { "goal_covers",   "Year Goal With Covers" },
    { "bookclub",      "Book Club" },
    { "month_rings",   "Month Rings" },
    { "month_totals",  "Month Totals" },
    { "month_chart",   "Pages Per Day" },
    { "when_read",     "When You Read" },
    { "longest_month", "Longest Reads (Month)" },
    { "year_time",     "Time Read By Month" },
    { "longest_year",  "Longest Reads (Year)" },
    { "year_chart",    "Books And Pages" },
    { "year_covers",   "Year In Covers" },
    { "genres",        "Top Genres" },
    { "heatmap",       "Reading Heatmap" },
    { "finished",      "Recently Finished" },
    { "tbr",           "TBR Shelf" },
    { "deadline",      "Finish By" },
}

-- Smallest tap region containing (x, y): nested controls win over the card.
local function pickRegion(regions, x, y)
    local best, best_area
    for _, r in ipairs(regions or {}) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            local area = r.w * r.h
            if not best_area or area < best_area then best, best_area = r.id, area end
        end
    end
    return best
end

-- ─── repainting one card in place ───────────────────────────────────────────
-- A card that changes on its own (data landed, a tab, a month arrow) is
-- rebuilt and swapped into its existing slot, and only its area is
-- refreshed. Rebuilding the whole SimpleUI page for that cost a full layout
-- pass and a whole-screen update each time.

local _last_tap = 0
local STRENGTH = { ui = 1, partial = 2, flashui = 3, full = 4 }

-- Flash (briefly black/white) to clear ghosting when a whole card changes.
-- Home screen goes back to page 1 after a book or sleep (see further down).
local function firstPageOn() return sget("reset_page", true) ~= false end

local function flashMode() return sget("flash_clean", true) and "flashui" or "ui" end

local renderInto -- defined after bookshelfCtx
local watchWindow, windowOf, prewarm -- defined after MODULES

local function newInstance(id, card, dashboard)
    local inst = { id = id, card = card, dashboard = dashboard, regions = nil }
    INSTANCES[id] = inst
    -- request(reason, mode, now): repaint soon. Data landing is batched
    -- (several loads finishing close together = one repaint); taps go now.
    inst.request = function(reason, mode, now)
        mode = STRENGTH[mode] and mode or "ui"
        if not inst.pending or STRENGTH[mode] > STRENGTH[inst.pending] then inst.pending = mode end
        inst.reason = reason
        if inst.timer then
            if not now then return end
            UIManager:unschedule(inst.timer)
        end
        inst.timer = function()
            inst.timer = nil
            local m, r = inst.pending, inst.reason
            inst.pending, inst.reason = nil, nil
            renderInto(inst, m, r)
        end
        if now then UIManager:nextTick(inst.timer) else UIManager:scheduleIn(0.3, inst.timer) end
    end
    -- one stable function per card: Reading Log compares it
    inst.refresh = function() inst.request("data landed", "ui") end
    inst.config = {
        get = function(_, key, default)
            local v = sget("cfg_" .. id .. "_" .. key)
            if v == nil then return default end
            return v
        end,
        set = function(_, key, value) sput("cfg_" .. id .. "_" .. key, value) end,
        delete = function(_, key) sput("cfg_" .. id .. "_" .. key, nil) end,
    }
    return inst
end

-- The ctx a Bookshelf micro-module expects.
local function bookshelfCtx(inst, w, h)
    return {
        width = w, height = h, max_height = h,
        surface = inst.dashboard and "fullscreen" or nil,
        entry = { id = inst.id },
        config = inst.config,
        -- Reading Log's own size knob (Bookshelf's module text size): it
        -- scales text, rings and charts together. 70-150 %.
        scale = tonumber(sget("cfg_" .. inst.id .. "_scale_pct", 100)) or 100,
        refresh = inst.refresh,
        set_tap_regions = function(regions) inst.regions = regions end,
        menu = { _reload = function() refreshScreen("settings changed: " .. inst.id) end },
    }
end

local function renderCanvas(inst, bctx)
    local Ak = kit()
    if not Ak then return nil, "kit not loaded" end
    local ok, canvas
    if inst.dashboard then
        ok, canvas = pcall(Ak.Dashboard.render, bctx)
    else
        ok, canvas = pcall(Ak.render, inst.card, bctx)
    end
    if not ok or type(canvas) ~= "table" then return nil, canvas end
    return canvas
end

renderInto = function(inst, mode, reason)
    local sw = screenShowing(inst.id)
    -- A tap can only land on a card that is showing: if the window record is
    -- stale (SimpleUI swapped windows), take the current home window.
    if not sw and type(reason) == "string" and reason:find("^tap") and windowOf then
        sw = windowOf()
        if sw then
            inst.on, inst.lastwin = sw, sw
            if watchWindow then watchWindow(inst) end
            diag("window record was stale for %s: re-attached", inst.id)
        end
    end
    if not sw then
        -- not on the visible page: the next page turn builds it fresh anyway
        diag("skip repaint %s (%s): not on screen", inst.id, tostring(reason))
        return
    end
    local box = inst.box
    if not (box and inst.rect and inst.w) then
        return refreshScreen(tostring(reason) .. ": " .. inst.id .. " not placed yet")
    end
    noteRefresh(tostring(reason))
    local t0 = now_ms()
    inst.regions = nil
    local canvas, err = renderCanvas(inst, bookshelfCtx(inst, inst.w, inst.h))
    if not canvas then
        diag("RENDER FAILED %s on repaint: %s", inst.id, tostring(err))
        return refreshScreen("repaint failed: " .. inst.id)
    end
    inst.regions = inst.regions or canvas.regions
    local old = box[1]
    box[1] = canvas
    if old and old ~= canvas and type(old.free) == "function" then pcall(old.free, old) end
    local r = inst.rect
    local region = Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
    UIManager:setDirty(sw, function() return mode, region, true end)
    diag("repaint %s in place (%s, %s) built in %d ms | %d tap regions",
        inst.id, tostring(reason), mode, now_ms() - t0, #(inst.regions or {}))
end

-- slot_w/slot_h: the space SimpleUI gave the module. In full-screen layout
-- the canvas is bigger than that and is drawn at full_x/full_y instead.
local function wrapCanvas(inst, canvas, slot_w, slot_h, full_x, full_y)
    local w, h = canvas.w, canvas.h
    local full = full_x ~= nil
    local box = InputContainer:new{
        dimen = Geom:new{ w = full and slot_w or w, h = full and slot_h or h },
        canvas,
    }
    box.ges_events = {
        ReadingLogTap = { GestureRange:new{ ges = "tap", range = function() return inst.rect or box.dimen end } },
    }
    inst.box, inst.w, inst.h, inst.rect = box, w, h, nil
    local base_paint = box.paintTo
    function box:paintTo(bb, x, y, ...)
        inst.painted = true
        -- SimpleUI rebuilds its home window after menus, Bookshelf, the
        -- calendar...; follow the window we're actually painted in now.
        if watchWindow then
            local cur = windowOf and windowOf()
            if cur and inst.on ~= cur then watchWindow(inst) end
        end
        if full then
            -- SimpleUI places us in its slot; draw over the whole content area
            self.dimen.x, self.dimen.y = x, y
            local c = self[1]
            c:paintTo(bb, full_x, full_y)
            inst.rect = Geom:new{ x = full_x, y = full_y, w = c.w, h = c.h }
            return
        end
        local r = base_paint(self, bb, x, y, ...)
        inst.rect = Geom:new{ x = x, y = y, w = w, h = h }
        return r
    end
    function box:onReadingLogTap(_, ges)
        local Ak = kit()
        if not Ak or not ges or not ges.pos then return false end
        local o = inst.rect or self.dimen
        local rx, ry = ges.pos.x - (o.x or 0), ges.pos.y - (o.y or 0)
        local region = pickRegion(inst.regions, rx, ry)
        local ctx = bookshelfCtx(inst, w, h)
        ctx.tapped_region = region
        local keep
        diag("tap %s at %d,%d of %dx%d -> region %s (%d regions)", inst.id, rx, ry, w, h,
            tostring(region), #(inst.regions or {}))
        if inst.dashboard then
            if region == nil then return false end
            local ok, k = pcall(Ak.Dashboard.keep_open, ctx)
            keep = ok and k
            local ok2, err = pcall(Ak.Dashboard.on_tap, ctx)
            if not ok2 then logger.warn(TAG, "dashboard tap failed:", err) end
        else
            local ok, k = pcall(Ak.keepOpen, inst.card, ctx)
            keep = ok and k
            local ok2, err = pcall(Ak.onTap, inst.card, ctx)
            if not ok2 then logger.warn(TAG, inst.card, "tap failed:", err) end
        end
        if keep then
            -- a new tab or month replaces the whole card: flash it clean
            local whole = type(region) == "string" and (region:find("^tab:") or region:find("^heading|"))
            inst.request("tap " .. tostring(region), whole and flashMode() or "partial", true)
        end
        _last_tap = os.time()
        return true
    end
    return box
end

local function makeModule(inst, title)
    local M = {
        id           = inst.id,
        name         = "Reading Log · " .. title,
        label        = nil,
        enabled_key  = inst.id,
        default_on   = false,
        owns_chrome  = true, -- the cards draw their own rounded panels
        has_covers   = true, -- colour dithering on Kaleido
    }

    function M.getHeight(ctx)
        if inst.dashboard and dashFull() then
            -- the slot SimpleUI lays out; the drawing covers the whole area
            return floor(contentHeight() * 0.8)
        end
        if inst.dashboard then
            local pct = tonumber(sget("dash_height_pct", 92)) or 92
            return floor(contentHeight() * pct / 100)
        end
        local w = (ctx and (ctx.col_w or ctx.inner_w)) or innerWidth()
        local Ak = kit()
        local def = Ak and Ak.panels and Ak.panels[inst.card]
        local ratio = def and ((w < 760 and def.ratio_narrow) or def.ratio) or 0.5
        local mult = tonumber(sget("cfg_" .. inst.id .. "_height_pct", 100)) or 100
        return max(40, floor(w * ratio * mult / 100))
    end

    function M.build(w, ctx)
        local Ak = kit()
        if not Ak then return nil end
        local h = M.getHeight(ctx)
        local slot_w, slot_h = w, h
        local fx, fy
        if inst.dashboard and dashFull() then
            fx, fy = 0, contentTop()
            w, h = Screen:getWidth(), contentHeight()
        end
        inst.regions = nil
        local bctx = bookshelfCtx(inst, w, h)
        local t0 = now_ms()
        local canvas, err = renderCanvas(inst, bctx)
        if not canvas then
            logger.warn(TAG, inst.id, "render failed:", err)
            diag("RENDER FAILED %s (%dx%d): %s", inst.id, w, h, tostring(err))
            return nil
        end
        inst.regions = inst.regions or canvas.regions
        local avail = contentHeight()
        diag("built %s %dx%d (asked %dx%d) in %d ms | size %s%% | theme %s, night %s | %d tap regions%s",
            inst.id, canvas.w or -1, canvas.h or -1, w, h, now_ms() - t0, tostring(bctx.scale),
            tostring(Ak.themeId()), Screen.night_mode and "ON" or "off", #(inst.regions or {}),
            (canvas.h or 0) > avail and string.format("  <-- TALLER THAN THE PAGE (%d px available)", avail) or "")
        if (canvas.w and canvas.w ~= w) or (canvas.h and canvas.h ~= h) then
            diag("  SIZE MISMATCH %s: canvas %sx%s vs slot %dx%d (layout may overlap or leave a gap)",
                inst.id, tostring(canvas.w), tostring(canvas.h), w, h)
        end
        if #(inst.regions or {}) == 0 and inst.dashboard then
            diag("  NO TAP REGIONS on the dashboard: tabs and arrows will not respond")
        end
        if inst.dashboard and prewarm then prewarm(inst) end
        return wrapCanvas(inst, canvas, slot_w, slot_h, fx, fy)
    end

    function M.getMenuItems(ctx_menu)
        local function done()
            if ctx_menu and type(ctx_menu.refresh) == "function" then pcall(ctx_menu.refresh) end
            refreshScreen("menu: " .. inst.id)
        end

        -- A "<label>: <n>%" row that opens a spinner.
        local function spinItem(label, title, key, default, lo, hi, info)
            return {
                text_func = function() return label .. ": " .. tostring(sget(key, default)) .. "%" end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = title,
                        info_text = info,
                        value = tonumber(sget(key, default)) or default,
                        value_min = lo, value_max = hi,
                        value_step = 5, value_hold_step = 10,
                        default_value = default,
                        unit = "%",
                        callback = function(spin)
                            sput(key, spin.value)
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            done()
                        end,
                    })
                end,
            }
        end

        local NIGHT = { { "dark", _("Dark") }, { "paper", _("Paper") }, { "white", _("White") }, { "off", _("Same As Day") } }
        local night_items = {}
        for _i, opt in ipairs(NIGHT) do -- not `_`: that is gettext here
            night_items[#night_items + 1] = {
                text = opt[2],
                radio = true,
                checked_func = function() return sget("night_theme", "dark") == opt[1] end,
                keep_menu_open = true,
                callback = function()
                    sput("night_theme", opt[1])
                    done()
                end,
            }
        end

        local appearance = {
            spinItem(_("Size"), _("Size Of Text, Rings And Charts"), "cfg_" .. inst.id .. "_scale_pct", 100, 70, 150,
                _("Scales everything inside the cards. 100% is Reading Log's normal size.")),
            inst.dashboard
                and spinItem(_("Height (% Of Screen)"), _("Dashboard Height"), "dash_height_pct", 92, 50, 100,
                    _("How much of the page the dashboard fills."))
                or spinItem(_("Height"), _("Card Height"), "cfg_" .. inst.id .. "_height_pct", 100, 50, 250,
                    _("Card height relative to its normal shape.")),
            {
                text_func = function()
                    local cur = sget("night_theme", "dark")
                    for _i, opt in ipairs(NIGHT) do
                        if opt[1] == cur then return _("Night Mode Theme: ") .. opt[2] end
                    end
                    return _("Night Mode Theme")
                end,
                sub_item_table = night_items,
            },
            {
                text = _("Flash To Clear Ghosting"),
                help_text = _("Flash the screen when switching tabs or turning to/from the dashboard page, so the old page doesn't linger."),
                checked_func = function() return sget("flash_clean", true) and true or false end,
                keep_menu_open = true,
                callback = function() sput("flash_clean", not sget("flash_clean", true)) end,
            },
        }

        if inst.dashboard then
            local LAYOUTS = {
                { "card", _("In The Page"), _("Sits in SimpleUI's page like other modules, with its margins and page dots.") },
                { "full", _("Full Screen"), _("Fills everything between the status bar and the nav bar, so every card is bigger.") },
            }
            local layout_items = {}
            for _i, opt in ipairs(LAYOUTS) do
                layout_items[#layout_items + 1] = {
                    text = opt[2], help_text = opt[3], radio = true,
                    checked_func = function() return sget("dash_layout", "card") == opt[1] end,
                    keep_menu_open = true,
                    callback = function()
                        sput("dash_layout", opt[1])
                        if opt[1] == "full" and contentTop() == nil then
                            diag("full-screen layout unavailable: this SimpleUI doesn't report its content area")
                        end
                        done()
                    end,
                }
            end
            table.insert(appearance, 1, {
                text_func = function()
                    return _("Layout: ") .. (sget("dash_layout", "card") == "full" and _("Full Screen") or _("In The Page"))
                end,
                sub_item_table = layout_items,
            })
        end

        -- Reading goals, shared with SimpleUI's own Reading Goals (Stats).
        local function goalsChanged()
            local Ak = kit()
            if Ak then
                Ak.epoch = (Ak.epoch or 0) + 1
                pcall(Ak.D.invalidate)
            end
            done()
        end
        local function numItem(label, get, set, lo, hi, step, unit, info)
            return {
                text_func = function() return label .. ": " .. tostring(get() or "?") .. (unit or "") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = label, info_text = info,
                        value = tonumber(get()) or lo, value_min = lo, value_max = hi,
                        value_step = step or 1, value_hold_step = (step or 1) * 5,
                        ok_text = _("Save"),
                        callback = function(spin)
                            set(spin.value)
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            goalsChanged()
                        end,
                    })
                end,
            }
        end
        local function G() return suiRequire("infra/sui_goals") end
        local goals = {
            numItem(_("Books This Year"),
                function() local Ak = kit(); return Ak and (Ak.D.yearGoal()) end,
                function(v) local Ak = kit(); if Ak then Ak.D.setYearGoal(v) end end,
                1, 365, 1, nil, _("Same as SimpleUI's Annual Goal.")),
            numItem(_("Read Outside KOReader"),
                function() local Ak = kit(); return Ak and select(2, Ak.D.yearGoal()) end,
                function(v) local Ak = kit(); if Ak then Ak.D.setOtherBooks(v) end end,
                0, 365, 1, nil, _("Paper books, audiobooks or another reader. Added to this year's count.")),
            numItem(_("Minutes A Day"),
                function() local Ak = kit(); return Ak and Ak.D.dailyMinutesGoal() end,
                function(v)
                    local g = G()
                    if g and type(g.setUnits) == "function" then pcall(g.setUnits, "daily", v)
                    else
                        local ok, Store = pcall(require, "lib/bookshelf_settings_store")
                        if ok and type(Store) == "table" and Store.save then pcall(Store.save, "micromodule_reading_goal_daily", v) end
                    end
                end,
                5, 720, 5, " min", _("Same as SimpleUI's Daily Goal. Fills the minutes ring.")),
            numItem(_("Pages A Day"),
                function() local Ak = kit(); return Ak and Ak.get("activity_page_goal", 30) end,
                function(v) local Ak = kit(); if Ak then Ak.set("activity_page_goal", v) end end,
                1, 2000, 5, nil, _("Fills the pages ring.")),
        }

        local items = {
            { text = _("Reading Goals"), sub_item_table = goals },
            {
                text = _("Reading Log Settings…"),
                callback = function()
                    local Ak = kit()
                    if not Ak then return end
                    local w = innerWidth()
                    local bctx = bookshelfCtx(inst, w, M.getHeight({ col_w = w }))
                    if inst.dashboard then
                        pcall(Ak.Dashboard.show_settings, bctx)
                    else
                        pcall(Ak.showSettings, inst.card, bctx)
                    end
                end,
            },
            { text = _("Appearance"), sub_item_table = appearance },
        }
        if inst.dashboard then
            local today_items = {}
            for _i, c in ipairs(TODAY_CHOICES) do
                today_items[#today_items + 1] = {
                    text = _(c[2]), radio = true,
                    checked_func = function() return todayCard() == c[1] end,
                    keep_menu_open = true,
                    callback = function()
                        local old = todayCard()
                        if old == c[1] then return end
                        sput("today_card", c[1])
                        local Ak = kit()
                        if Ak then
                            if TODAY_SLOT then TODAY_SLOT.row[TODAY_SLOT.k] = c[1] end
                            -- a Today page edited in Pages and cards is saved whole:
                            -- swap the old choice there too
                            local saved = Ak.get("dash_rows_today", nil)
                            if type(saved) == "table" then
                                for _j, r in ipairs(saved) do
                                    if type(r) == "table" and type(r.c) == "table" then
                                        for k, n in ipairs(r.c) do if n == old then r.c[k] = c[1] end end
                                    end
                                end
                                Ak.set("dash_rows_today", saved)
                            end
                            Ak.epoch = (Ak.epoch or 0) + 1
                        end
                        diag("Today page card: %s -> %s", old, c[1])
                        done()
                    end,
                }
            end
            table.insert(items, 2, {
                text_func = function()
                    for _i, c in ipairs(TODAY_CHOICES) do
                        if c[1] == todayCard() then return _("Today Page Card: ") .. _(c[2]) end
                    end
                    return _("Today Page Card")
                end,
                help_text = _("Which card sits under the rings on the Today tab. Book club uses a collection named like \"Book club\" (set it in that card's Reading Log settings)."),
                sub_item_table = today_items,
            })
            items[#items + 1] = {
                text = _("Start On First Page After Reading Or Sleep"),
                help_text = _("Opening a book or putting the device to sleep sends the home screen back to page 1."),
                checked_func = firstPageOn,
                keep_menu_open = true,
                callback = function() sput("reset_page", not firstPageOn()) end,
            }
        end
        return items
    end

    return M
end

local MODULES = {}
do
    local dash = newInstance("readinglog_dashboard", nil, true)
    MODULES[#MODULES + 1] = makeModule(dash, "Dashboard")
    for _, c in ipairs(CARDS) do
        MODULES[#MODULES + 1] = makeModule(newInstance("readinglog_" .. c[1], c[1], false), c[2])
    end
end

-- ─── ghosting on page turns ─────────────────────────────────────────────────
-- SimpleUI turns home pages with a quiet "ui" update. Going to or from a
-- page with a Reading Log card swaps nearly every pixel (a dark dashboard at
-- night especially) and the old page shows through. The home window's paint
-- is watched: when a paint shows Reading Log cards and the one before did
-- not (or the other way round), one full refresh is added. KOReader merges
-- it with SimpleUI's own update of the same paint.

windowOf = function()
    local stack = UIManager._window_stack or {}
    -- SimpleUI's home window by name; failing that (a custom screen), the
    -- topmost full-screen window that isn't a book
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if type(w) == "table" and w.name == "homescreen" then return w end
    end
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if type(w) == "table" and w.covers_fullscreen and w.name ~= "ReaderUI" then return w end
    end
    return nil
end

watchWindow = function(inst)
    local w = windowOf(inst)
    if not w then return end
    inst.on, inst.lastwin = w, w
    if rawget(w, "_rl_watched") then return end
    w._rl_watched = true
    local orig = w.paintTo
    w.paintTo = function(self, ...)
        for _id, i in pairs(INSTANCES) do i.painted = false end
        local res = { orig(self, ...) }
        local vis = false
        for _id, i in pairs(INSTANCES) do
            if i.painted then
                i.on, i.lastwin = self, self
                vis = true
            elseif i.on == self then
                i.on = nil
            end
        end
        if self._rl_vis ~= nil and vis ~= self._rl_vis and sget("flash_clean", true) then
            UIManager:setDirty(nil, "full")
            diag("page turned %s the Reading Log page -> full refresh", vis and "onto" or "off")
        end
        self._rl_vis = vis
        return unpack(res)
    end
    diag("watching %s for page turns", tostring(w.name or "home window"))
end

-- ─── warm up the other dashboard tabs ───────────────────────────────────────
-- A tab's data is read in the background the first time it is drawn, and
-- each read that lands redraws the card. Draw the hidden tabs once, off
-- screen, a few seconds after the dashboard first shows, so the first real
-- switch to them is a single redraw with everything already there.

local _prewarm_state = nil -- nil = not started, "waiting", "done"
prewarm = function(inst)
    if _prewarm_state ~= nil or sget("prewarm", true) == false then return end
    _prewarm_state = "waiting"
    local tries = 0
    local function run()
        local Ak = kit()
        if not Ak or not inst.w then _prewarm_state = "done"; return end
        -- don't compete with someone tapping around
        if os.time() - _last_tap < 2 and tries < 5 then
            tries = tries + 1
            UIManager:scheduleIn(3, run)
            return
        end
        _prewarm_state = "done"
        local tabs, cur = Ak.state.dash_tabs, Ak.state.dash_page
        if type(tabs) ~= "table" then return end
        local saved_tabs = tabs
        local t0, n = now_ms(), 0
        for _i, tab in ipairs(saved_tabs) do
            if tab.kind == "page" and tab.page ~= cur then
                Ak.state.dash_page = tab.page
                local ctx = bookshelfCtx(inst, inst.w, inst.h)
                ctx.entry = { id = inst.id .. "_prewarm" }
                ctx.refresh = function() end
                ctx.set_tap_regions = function() end
                local ok, c = pcall(Ak.Dashboard.render, ctx)
                if ok and type(c) == "table" and c.free then pcall(c.free, c) end
                n = n + 1
            end
        end
        Ak.state.dash_page, Ak.state.dash_tabs = cur, saved_tabs
        diag("prewarmed %d hidden dashboard tabs in %d ms", n, now_ms() - t0)
    end
    UIManager:scheduleIn(4, run)
end

-- ─── registration ───────────────────────────────────────────────────────────

local _registered = false
local function register()
    if _registered then return true end
    local Registry = suiRequire("modules/moduleregistry")
    if not (Registry and Registry.register) then return false end
    local failed = 0
    for _i, M in ipairs(MODULES) do
        local ok, err = pcall(Registry.register, M)
        if not ok then
            failed = failed + 1
            logger.warn(TAG, "register failed for", M.id, err)
            diag("REGISTER FAILED %s: %s", M.id, tostring(err))
        end
    end
    diag("registered %d modules with SimpleUI (%d failed)", #MODULES - failed, failed)
    _registered = true
    logger.info(TAG, "registered", #MODULES, "Reading Log modules with SimpleUI")
    return true
end

local Plugin = WidgetContainer:extend{
    name = "simpleui_readinglog",
    is_doc_only = false,
}

function Plugin:init()
    if register() then return end
    -- SimpleUI not loaded yet: try again once every plugin is up.
    UIManager:nextTick(function()
        if not register() then
            UIManager:scheduleIn(2, function()
                if register() then refreshScreen("registered late")
                else logger.warn(TAG, "SimpleUI module registry not found; is SimpleUI installed and enabled?") end
            end)
        else
            refreshScreen("registered next tick")
        end
    end)
end

-- ─── back to the first home page ────────────────────────────────────────────
-- After a book is opened or the device sleeps, SimpleUI comes back on the
-- page you left. With this on (Dashboard settings → "Start on first page"),
-- it comes back on page 1 instead.

local function resetHomePage(why)
    if not firstPageOn() then return end
    local SE = package.loaded["engines/sui_screen_engine"]
    if type(SE) ~= "table" then return end
    -- the page SimpleUI remembers for a home screen it will reopen
    if SE._current_page and SE._current_page ~= 1 then SE._current_page = nil end
    if type(SE._cs_state) == "table" then
        for _id, st in pairs(SE._cs_state) do
            if type(st) == "table" and st._current_page and st._current_page ~= 1 then st._current_page = nil end
        end
    end
    -- a home screen that is still open
    local ids = { "hs" }
    if type(SE.liveScreenIds) == "function" then
        local ok, l = pcall(SE.liveScreenIds)
        if ok and type(l) == "table" then ids = l end
    end
    for _i, id in ipairs(ids) do
        local ok, w = pcall(SE.getInstance, id)
        if ok and type(w) == "table" and (w._current_page or 1) ~= 1 then
            if type(w._setPage) == "function" then
                pcall(w._setPage, w, 1)
            else
                w._current_page = 1
            end
            diag("back to page 1 (%s)", why)
        end
    end
end

function Plugin:onSuspend() resetHomePage("sleep") end
function Plugin:onReaderReady() resetHomePage("book opened") end

-- Cards bake their colours in when built, so rebuild them when night mode
-- flips. (Delay: the flip itself is handled elsewhere, maybe after us.)
local _night_queued = false
local function onNightChange()
    if not A or _night_queued then return end
    _night_queued = true
    UIManager:scheduleIn(0.3, function()
        _night_queued = false
        A.epoch = (A.epoch or 0) + 1
        diag("night mode now %s: rebuilding with theme %s", Screen.night_mode and "ON" or "off", tostring(A.themeId()))
        refreshScreen("night mode")
    end)
end
function Plugin:onToggleNightMode() onNightChange() end
function Plugin:onSetNightMode() onNightChange() end

-- Also catch the UIManager-level toggle (used by gestures/quick actions).
if not UIManager._readinglog_night_hooked then
    UIManager._readinglog_night_hooked = true
    for _, fname in ipairs{ "ToggleNightMode", "SetNightMode" } do
        local orig = UIManager[fname]
        if type(orig) == "function" then
            UIManager[fname] = function(self, ...)
                local r = orig(self, ...)
                onNightChange()
                return r
            end
        end
    end
end

return Plugin
