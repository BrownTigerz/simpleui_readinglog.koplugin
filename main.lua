-- Reading Log for SimpleUI v1.8.1, by TK. Licensed AGPL-3.0.
-- Bundles the Reading Log kit by stevenzamora1
-- (https://github.com/stevenzamora1/reading-log-simpleui) — thank you!
-- Built for Simple UI by Doctor Hetfield
-- (https://github.com/doctorhetfield-cmd/simpleui.koplugin) — thank you!
-- Full license text: see LICENSE in this folder.
--[[
Reading Log for SimpleUI
------------------------
Runs the Reading Log cards (github.com/stevenzamora1/reading-log-simpleui,
AGPL-3.0) as SimpleUI home screen modules, without Bookshelf.

The card kit (readinglog/almanac/) draws the cards and owns their own
options. This file is the layer around it:
  * registers every card and the Dashboard with SimpleUI
  * builds, taps and repaints them in place (one card, not the whole page)
  * keeps every setting in settings/simpleui_readinglog.lua
  * adds this plugin's own options: Night Mode Theme, Layout (Full Screen),
    Bottom Space, Tab Bar Position, Size, Height, Flash To Clear Ghosting, Reading Goals,
    Today Page Card, Start On First Page, and the Year Goal With Covers card
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

-- Whether the SimpleUI diagnostics patch is there to take diag lines: lines
-- that cost something to put together are only built then.
local function diagOn()
    local D = package.loaded["simpleui_diagnostics"]
    if type(D) ~= "table" or type(D.log) ~= "function" then return false end
    -- 2.10.1+: whether it's still logging (its 30-minute window)
    if type(D.on) == "function" then
        local ok, v = pcall(D.on)
        return ok and v and true or false
    end
    return true
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

-- Room SimpleUI needs under the content for its page dots / arrows, so the
-- full-screen dashboard doesn't cover them. 0 when there is only one page.
-- The automatic room for the page dots; Appearance → Bottom Space adds or
-- removes pixels on top of it.
local function autoDotsHeight(inst)
    local win = inst and (inst.on or inst.lastwin)
    if win and tonumber(win._total_pages) and win._total_pages <= 1 then return 0 end
    local h = Screen:scaleBySize(28)
    local BB = suiRequire("screens/sui_bottombar")
    if BB and type(BB.getPaginationIconSize) == "function" then
        local ok, icon = pcall(BB.getPaginationIconSize)
        if ok and tonumber(icon) then h = max(h, icon + Screen:scaleBySize(8)) end
    end
    return h
end

local function pageDotsHeight(inst)
    local adj = tonumber(sget("dash_bottom_adjust", 0)) or 0
    return max(0, autoDotsHeight(inst) + adj)
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


-- The card in the Today page's book club slot (Dashboard settings →
-- "Today page card"). Year goal with covers unless you pick another.
local TODAY_PICKS = {
    { "goal_covers", "Year Goal With Covers" },
    { "goal",        "Year Goal" },
    { "bookclub",    "Book Club" },
    { "finished",    "Recently Finished" },
    { "tbr",         "TBR Shelf" },
}
local TODAY_CHOICES = TODAY_PICKS

local TODAY_SLOT = nil
local function todayCard()
    local v = sget("today_card", "goal_covers")
    for _i, c in ipairs(TODAY_CHOICES) do if c[1] == v then return v end end
    return "goal_covers"
end
-- Swipe Between 2-3 Cards (top of Today Page Card): on, the ticked cards.
local function todaySwipeOn()
    local v = sget("today_swipe")
    if v == nil then return sget("today_card") == "swipe_today" end -- 1.7.0 test builds
    return v == true
end
-- What actually sits in the Today slot: the one card, or the swipe card.
local function todaySlot() return todaySwipeOn() and "swipe_today" or todayCard() end

-- defined further down, used by the kit hooks
local flashMode, scheduleClock, quoteOfTheDay, rerollQuote
local dropDash -- kept dashboard tabs (further down)

-- Appearance → Live Clock (on by default).
local function liveClock() return sget("live_clock", true) ~= false end

local A, _kit_failed

-- ─── swipe card (Today page card) ───────────────────────────────
-- One spot shows 2 or 3 cards, one at a time: swipe left/right on it (or tap
-- its dots) to switch. Only that spot's area redraws. "After Reading Or Sleep":
-- stay on the one you picked, or show the next one after a book or sleep.
local SWIPE = {
    today = { panel = "swipe_today", picks = TODAY_PICKS, default = { "goal_covers", "finished" }, cap = 0.36 },
}
local _swipe_i, _swipe_away = {}, {}

local function swipeCards(spot)
    local sp = SWIPE[spot]
    local v = sget("swipe_" .. spot .. "_cards")
    local ok_name = {}
    for _i, c in ipairs(sp.picks) do ok_name[c[1]] = true end
    -- in the order you ticked them, up to 3
    local out, seen = {}, {}
    if type(v) == "table" then
        for _i, n in ipairs(v) do
            if ok_name[n] and not seen[n] and #out < 3 then out[#out + 1] = n; seen[n] = true end
        end
    end
    if #out < 1 then out = { sp.default[1], sp.default[2] } end
    return out
end

local function swipeNext() return sget("swipe_return", "stay") == "next" end

local function swipeWeight(spot)
    if not A then return end
    local wgt = 0
    for _i, n in ipairs(swipeCards(spot)) do wgt = max(wgt, A.DASH_WEIGHT[n] or 0.25) end
    A.DASH_WEIGHT[SWIPE[spot].panel] = min(wgt, SWIPE[spot].cap)
end

-- Which card a spot shows now (1..n). After a book or sleep, "show the next
-- one" moves it on once, at the first build back.
local function swipeIndex(spot, n)
    local i = _swipe_i[spot] or tonumber(sget("swipe_" .. spot .. "_i", 1)) or 1
    if _swipe_away[spot] then
        _swipe_away[spot] = nil
        if swipeNext() then
            i = i + 1
            sput("swipe_" .. spot .. "_i", ((i - 1) % n) + 1)
        end
    end
    i = ((i - 1) % n) + 1
    _swipe_i[spot] = i
    return i
end

-- Start On Tab: which dashboard tab shows when you come back to it (turning
-- onto its page, after a book, after sleep). "last" = the one you left on.
local function startTabId() return sget("start_tab", "last") end
local function goStartTab(why)
    local id = startTabId()
    if id == "last" or not A then return end
    for _i, t in ipairs(A.state.dash_tabs or {}) do
        if t.kind == "page" and t.id == id then
            if A.state.dash_page ~= t.page then
                A.state.dash_page = t.page
                A.state.month_offset = 0
                diag("back on the %s tab (%s)", id, why)
            end
            return
        end
    end
end

local function swipeAway()
    for spot in pairs(SWIPE) do _swipe_away[spot] = true end
end

-- Redraw only the spot: its cell on the dashboard canvas.
local function repaintSwipe(spot, ctx)
    local inst = type(ctx) == "table" and ctx._rl_inst
    if not inst then
        if A then pcall(A.host.repaint, ctx, { flash = true }) end
        return
    end
    local want = SWIPE[spot].panel .. "|"
    for _i, r in ipairs(inst.regions or {}) do
        if r.id == want then
            inst.request("swipe " .. spot, sget("swipe_flash", false) and "flashui" or "ui", true, { x = r.x, y = r.y, w = r.w, h = r.h })
            return
        end
    end
    inst.request("swipe " .. spot, flashMode(), true)
end

local fastSwipe -- below buildSwipe
local function setSwipe(spot, k, ctx)
    local cards = swipeCards(spot)
    local n = #cards
    k = ((k - 1) % n) + 1
    if k == (_swipe_i[spot] or 1) then return end
    _swipe_i[spot] = k
    sput("swipe_" .. spot .. "_i", k)
    diag("swipe %s -> %d of %d (%s)", spot, k, n, tostring(cards[k]))
    if fastSwipe and fastSwipe(spot, k, ctx) then return end
    repaintSwipe(spot, ctx)
end

local function flipSwipe(spot, step, ctx)
    setSwipe(spot, (_swipe_i[spot] or 1) + step, ctx)
end

-- The swipe card keeps every card it has drawn (until the dashboard is
-- rebuilt), so switching is a swap of a ready picture: no rebuild of the
-- dashboard, and only the card's own area is refreshed.
local function buildSwipe(spot, env)
    local P = A.panels
    local cards = swipeCards(spot)
    local n = #cards
    local w, h = env.w, env.h
    local dots_h = n > 1 and max(12, floor(h * 0.075)) or 0
    local ch = h - dots_h
    local c = A.canvas{ w = w, h = h, plain = true, page = env.page }
    local holder = { spot = spot, cards = cards, i = swipeIndex(spot, n), cache = {}, dots = {}, ch = ch }

    function holder.card(name)
        local child = holder.cache[name]
        if child then return child end
        local t0 = now_ms()
        local ienv = A.makeEnv(name, env.ctx, w, ch, { nested = true, slot = 1, page = env.page })
        local ok, built = pcall(P[name].build, ienv)
        if not (ok and built) then
            diag("SWIPE CARD FAILED %s/%s: %s", spot, tostring(name), tostring(built))
            built = A.canvas{ w = w, h = ch, plain = true, page = env.page }
            built:label((P[name] and P[name].title or name) .. " could not be drawn", max(12, floor(ch * 0.08)),
                w / 2, ch / 2, { anchor = "c", valign = "mid", max_w = w - 20 })
        end
        holder.cache[name] = built
        c.owned[#c.owned + 1] = built
        holder.built_ms = now_ms() - t0
        return built
    end

    -- dots under the card, one picture per position
    local page_bg, page_fg = A.dashPage()
    local r = max(3, floor(dots_h * 0.24))
    local step = r * 5
    local x0 = w / 2 - (n - 1) * step / 2
    local function dotsFor(cur)
        if n < 2 then return nil end
        if holder.dots[cur] then return holder.dots[cur] end
        local d = A.canvas{ w = w, h = dots_h, plain = true, page = env.page }
        for k = 1, n do
            local cx = x0 + (k - 1) * step
            d:disc(cx, dots_h / 2, k == cur and r or floor(r * 0.75 + 0.5),
                k == cur and page_fg or A.mix(page_fg, page_bg, 0.6))
        end
        holder.dots[cur] = d
        c.owned[#c.owned + 1] = d
        return d
    end
    holder.dotsFor = dotsFor

    local name = cards[holder.i]
    local child = holder.card(name)
    dotsFor(holder.i)
    c:op(function(bb, ox, oy)
        local cur = holder.cache[holder.cards[holder.i]]
        if cur then cur:paintTo(bb, ox, oy, true) end
        local d = holder.dots[holder.i]
        if d then d:paintTo(bb, ox, oy + ch, true) end
    end)
    -- tap regions of the card shown now (swapped along with it)
    for _i, rg in ipairs(child.regions) do c:region(name .. "|" .. rg.id, rg.x, rg.y, rg.w, rg.h) end
    c:region(name .. "|", 0, 0, w, ch)
    if n > 1 then
        c:region("dots", 0, ch, w, dots_h)
        for k = 1, n do c:region("dot:" .. k, x0 + (k - 1) * step - step / 2, ch, step, dots_h) end
    end
    c._swipe_holder = holder
    return c
end

-- Switch the card on screen without rebuilding the dashboard: swap the
-- picture, swap its tap regions, refresh its area (no flash). false = the
-- dashboard on screen isn't the one built with this card; rebuild instead.
fastSwipe = function(spot, k, ctx)
    local inst = type(ctx) == "table" and ctx._rl_inst
    local dash = inst and inst.box and inst.box[1]
    if not (dash and dash.owned and inst.rect and inst.regions) then return false end
    local holder
    for _i, o in ipairs(dash.owned) do
        if type(o) == "table" and o._swipe_holder and o._swipe_holder.spot == spot then holder = o._swipe_holder end
    end
    if not holder or not holder.cards[k] then return false end
    local sw = screenShowing(inst.id)
    if not sw then return false end
    local panel = SWIPE[spot].panel .. "|"
    local cell
    for _i, r in ipairs(inst.regions) do if r.id == panel then cell = r end end
    if not cell then return false end
    local t0 = now_ms()
    holder.built_ms = 0
    local old, new = holder.cards[holder.i], holder.cards[k]
    A.D.cover_owner = inst.id -- covers still loading redraw this card when ready
    local child = holder.card(new)
    A.D.cover_owner = nil
    holder.dotsFor(k)
    holder.i = k
    -- regions: drop the old card's, add the new one's (dots stay)
    local pfx_old = panel .. old .. "|"
    local out = {}
    for _i, r in ipairs(inst.regions) do
        if r.id:sub(1, #pfx_old) ~= pfx_old then out[#out + 1] = r end
    end
    local base = panel .. new .. "|"
    out[#out + 1] = { id = base, x = cell.x, y = cell.y, w = cell.w, h = holder.ch }
    for _i, r in ipairs(child.regions) do
        out[#out + 1] = { id = base .. r.id, x = cell.x + r.x, y = cell.y + r.y, w = r.w, h = r.h }
    end
    inst.regions = out
    dash.regions = out -- a kept Today tab brings back the card shown now
    local rr = inst.rect
    local region = Geom:new{ x = rr.x + cell.x, y = rr.y + cell.y, w = cell.w, h = cell.h }
    local mode = sget("swipe_flash", false) and "flashui" or "ui"
    UIManager:setDirty(sw, function() return mode, region, true end)
    diag("swipe card swapped in place (%s, %s) in %d ms",
        new, holder.built_ms > 0 and ("drawn in " .. holder.built_ms .. " ms") or "ready", now_ms() - t0)
    return true
end

local function tapSwipe(spot, env, region)
    if type(region) ~= "string" then return end
    if region == "dots" then return flipSwipe(spot, 1, env.ctx) end
    local k = tonumber(region:match("^dot:(%d+)$"))
    if k then return setSwipe(spot, k, env.ctx) end
    local inner, sub = region:match("^([%w_]+)|(.*)$")
    local def = inner and A.panels[inner]
    if not def then return end
    sub = (sub ~= "") and sub or nil
    local custom = A.customTap and A.customTap(inner, sub)
    if custom then return A.runTapAction(custom, env.ctx) end
    if not def.tap then return end
    local ok, err = pcall(def.tap, A.makeEnv(inner, env.ctx, 0, 0, { nested = true, slot = 1 }), sub)
    if not ok then diag("TAP FAILED %s in swipe %s: %s", inner, spot, tostring(err)) end
    if def.keep and def.keep(sub) then A.host.repaint(env.ctx, {}) end
end

-- A spot's built-in place on the Today page, and on a Today page you've
-- edited in Pages and cards (saved whole): swap one card name for another.
local function swapTodayCard(slot, old, new)
    if not A then return end
    if slot then slot.row[slot.k] = new end
    local saved = A.get("dash_rows_today", nil)
    if type(saved) == "table" then
        for _j, r in ipairs(saved) do
            if type(r) == "table" and type(r.c) == "table" then
                for k, n in ipairs(r.c) do if n == old then r.c[k] = new end end
            end
        end
        A.set("dash_rows_today", saved)
    end
    A.epoch = (A.epoch or 0) + 1
end

-- Menu: Alternate Or Keep Last (the swipe card after a book or sleep).
local function alternateMenu(done)
    return {
        text_func = function()
            return _("Alternate Or Keep Last: ") .. (swipeNext() and _("Alternate") or _("Keep Last"))
        end,
        enabled_func = todaySwipeOn,
        help_text = _("After a book or sleep: Alternate shows the next card, Keep Last stays on the card you swiped to."),
        sub_item_table = {
            {
                text = _("Alternate"), radio = true,
                checked_func = swipeNext,
                keep_menu_open = true,
                callback = function() sput("swipe_return", "next"); done() end,
            },
            {
                text = _("Keep Last"), radio = true,
                checked_func = function() return not swipeNext() end,
                keep_menu_open = true,
                callback = function() sput("swipe_return", nil); done() end,
            },
        },
    }
end

local function kit()
    if A then return A end
    if _kit_failed then return nil end

    -- The kit keeps its settings in our file, under "kit_" (as before).
    package.loaded["simpleui_readinglog_store"] = {
        readSetting = function(_, key) return sget("kit_" .. key) end,
        saveSetting = function(_, key, value) sput("kit_" .. key, value) end,
        delSetting = function(_, key) sput("kit_" .. key, nil) end,
        flush = function() pcall(function() store():flush() end) end,
    }

    local t0 = now_ms()
    local ok, res = pcall(dofile, KIT_PATH)
    if not ok or type(res) ~= "table" then
        _kit_failed = true
        logger.err(TAG, "could not load Reading Log kit:", res)
        diag("KIT FAILED to load from %s: %s", KIT_PATH, tostring(res))
        return nil
    end
    A = res
    package.loaded["simpleui_readinglog_kit"] = A -- for the diagnostics patch
    diag("kit %s loaded in %d ms", tostring(A.VERSION), now_ms() - t0)

    -- Quote of the day: your own quote file (SimpleUI's sui_quotes folder),
    -- or your highlights; Quote Of The Day → Source.
    local origQuote, origReroll = A.host.quoteOfTheDay, A.host.rerollQuote
    A.host.quoteOfTheDay = function()
        local q = quoteOfTheDay and quoteOfTheDay()
        if q ~= nil then return q end
        return origQuote()
    end
    A.host.rerollQuote = function()
        if rerollQuote and rerollQuote() then return end
        return origReroll()
    end

    local H, D = A.host, A.D

    -- data dropped (book menu, settings): kept tabs go too
    local origInvalidate = D.invalidate
    D.invalidate = function(...)
        for _id, i in pairs(INSTANCES) do if i.dashboard then dropDash(i) end end
        return origInvalidate(...)
    end

    -- Size (Appearance) is the kit's Text size: one value per card, ours.
    A.textSizePct = function(_pfx, id)
        local v = tonumber(id and sget("cfg_" .. id .. "_scale_pct", 100)) or 100
        return A.clamp(floor(v), 70, 150)
    end

    -- Redraws the kit asks for (a tap changed a card, data or a cover
    -- landed, the dashboard turned a tab) go through our in-place repaint.
    local origRepaint = H.repaint
    H.repaint = function(ctx, o)
        local inst = type(ctx) == "table" and ctx._rl_inst
        if not inst then return origRepaint(ctx, o) end
        o = o or {}
        if o.strip then
            -- a band of the card: the clock's minute, or the critter's new remark
            inst.request(o.reason or "clock", "ui", true, o.strip)
        elseif o.flash then
            inst.request("tap (whole card)", flashMode(), true)
        else
            inst.request("tap", "partial", true)
        end
    end
    -- The banner / Today page clock: once a minute, just its strip.
    local origTick = H.wantTick
    H.wantTick = function(ctx, strip)
        local inst = type(ctx) == "table" and ctx._rl_inst
        if not inst then return origTick(ctx, strip) end
        inst.clock = strip
        if strip and liveClock() then scheduleClock() end
    end

    -- "Details": SimpleUI's book menu; a status changed there (finished,
    -- on hold, reset) is read again straight away.
    local origDetails = H.showDetails
    H.showDetails = function(ctx, fp)
        local okh, Hold = pcall(require, "features/library/sui_book_hold_dialog")
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
        local ok, err = pcall(origDetails, ctx, fp)
        if orig_show then Hold.show = orig_show end
        diag("details %s -> SimpleUI book menu%s", tostring(fp), ok and "" or (" FAILED: " .. tostring(err)))
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
                        end
                    end
                end
            end
        end
    end

    -- Swipe spots: a card that shows one of 2-3 cards (not offered in Pages
    -- and cards; picked under Today Page Card).
    for spot, sp in pairs(SWIPE) do
        A.panels[sp.panel] = {
            title = "Swipe cards (Today card)",
            tone = "ink", ratio = 0.36, ratio_narrow = 0.62,
            does = "switches cards",
            summary = "Two or three cards in one spot: swipe left or right, or tap the dots, to switch.",
            members = function() return swipeCards(spot) end,
            build = function(env) return buildSwipe(spot, env) end,
            tap = function(env, region) return tapSwipe(spot, env, region) end,
        }
        swipeWeight(spot)
    end
    if TODAY_SLOT then TODAY_SLOT.row[TODAY_SLOT.k] = todaySlot() end

    -- Tab order: Today, Monthly, Yearly, Trends, Library. Pages are stored by
    -- id, not by position, so reordering keeps everyone's edited pages intact.
    local ORDER = { today = 1, monthly = 2, yearly = 3, trends = 4, library = 5 }
    table.sort(A.DASH_PAGES, function(a, b)
        return (ORDER[a.id] or 99) < (ORDER[b.id] or 99)
    end)

    -- Reading Log paints every theme pre-inverted so it looks the same day
    -- and night. Follow night mode instead: swap to a night theme (Dark by
    -- default) while night mode is on.
    local dayThemeId = A.themeId
    A.dayThemeId = dayThemeId
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

-- Card names (the kit's panel ids) and their titles, in the order SimpleUI
-- lists them.
local CARDS = {
    { "mini",          "Mini Dashboard" },
    -- Today
    { "banner",        "Banner" },
    { "continue",      "Continue Reading" },
    { "activity",      "Activity Rings" },
    { "week_rings",    "Week Rings" },
    { "week",          "This Week" },
    { "goal",          "Year Goal" },
    { "goal_covers",   "Year Goal With Covers" },
    { "bookclub",      "Book Club" },
    { "timeline",      "Today's Timeline" },
    { "control",       "Control Centre" },
    -- Monthly
    { "month_rings",   "Month Rings" },
    { "month_totals",  "Month Totals" },
    { "month_chart",   "Pages Per Day" },
    { "when_read",     "When You Read" },
    { "longest_month", "Longest Reads (Month)" },
    { "challenge",     "Monthly Challenge" },
    -- Yearly
    { "year_time",     "Time Read By Month" },
    { "longest_year",  "Longest Reads (Year)" },
    { "year_chart",    "Books And Pages" },
    { "year_covers",   "Year In Covers" },
    { "genres",        "Top Genres" },
    { "heatmap",       "Reading Heatmap" },
    { "finished",      "Recently Finished" },
    -- Trends
    { "trends",        "Reading Trends" },
    { "compare",       "This Week Vs Last" },
    { "forecast",      "Finish Forecast" },
    -- Library
    { "library",       "Library Stats" },
    { "authors",       "Most-Read Authors" },
    { "pick",          "Random Pick" },
    { "quote",         "Quote Of The Day" },
    -- Shelves
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

flashMode = function() return sget("flash_clean", true) and "flashui" or "ui" end

local renderInto -- defined after bookshelfCtx
local watchWindow, windowOf, prewarm, cancelPrewarm -- defined after MODULES

-- ─── Quote of the day from your own quote file ──────────────────────────────
-- SimpleUI's Quote of the Day reads quote files from settings/simpleui/
-- sui_quotes/ (Lua files returning { { q = "...", a = "Author", b = "Book" } }).
-- The Reading Log quote card reads the same file: the one picked here, else
-- the one SimpleUI's own module uses, else Quotes.lua, else the first there.
-- Source "highlights" keeps the kit's highlight-a-day instead.

local function quotesDir() return DataStorage:getSettingsDir() .. "/simpleui/sui_quotes" end

local function quoteFiles()
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    if lfs.attributes(quotesDir(), "mode") ~= "directory" then return out end
    for name in lfs.dir(quotesDir()) do
        if name:match("%.lua$") then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

local function quoteFileName()
    local files = quoteFiles()
    if #files == 0 then return nil end
    local have = {}
    for _i, f in ipairs(files) do have[f] = true end
    local mine = sget("quote_file")
    if mine and have[mine] then return mine end
    local S = suiRequire("infra/sui_store")
    local theirs = S and S.readSetting and S:readSetting("simpleui_hs_quote_custom_file")
    if type(theirs) == "string" and have[theirs] then return theirs end
    if have["Quotes.lua"] then return "Quotes.lua" end
    return files[1]
end

local function quoteSource()
    local v = sget("quote_source", "file")
    if v == "file" and not quoteFileName() then return "highlights" end
    return v
end

local _qcache = { path = nil, mtime = nil, list = nil }
local function loadQuoteFile(name)
    local lfs = require("libs/libkoreader-lfs")
    local path = quotesDir() .. "/" .. name
    local mtime = lfs.attributes(path, "modification")
    if not mtime then return nil end
    if _qcache.path == path and _qcache.mtime == mtime then return _qcache.list end
    local ok, data = pcall(dofile, path)
    local list = {}
    if ok and type(data) == "table" then
        for _i, e in ipairs(data) do
            local q = type(e) == "table" and (e.q or e.text or e[1])
            if type(q) == "string" and q ~= "" then
                list[#list + 1] = { q = q, a = type(e.a) == "string" and e.a or nil, b = type(e.b) == "string" and e.b or nil }
            end
        end
    else
        diag("QUOTE FILE FAILED %s: %s", path, tostring(data))
    end
    _qcache.path, _qcache.mtime, _qcache.list = path, mtime, list
    return list
end

local function dayHash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
    return h
end

-- nil = not ours (use highlights); false = nothing to show; else a quote.
quoteOfTheDay = function()
    if quoteSource() ~= "file" then return nil end
    local name = quoteFileName()
    local list = name and loadQuoteFile(name)
    if not list or #list == 0 then return nil end
    local today = os.date("%Y-%m-%d")
    local roll = sget("quote_file_roll")
    if type(roll) ~= "table" or roll.day ~= today or roll.file ~= name then
        roll = { day = today, file = name, n = 0 }
    end
    local idx = tonumber(roll.idx)
    if not idx or idx > #list then
        idx = dayHash(today .. "#" .. tostring(roll.n or 0)) % #list + 1
        if roll.prev and #list > 1 and idx == roll.prev then idx = idx % #list + 1 end
        roll.idx = idx
        sput("quote_file_roll", roll)
    end
    local e = list[idx]
    -- the card shows "— title, author": a quote with no book shows the author
    if e.b then
        return { text = e.q, title = e.b, author = e.a }
    end
    return { text = e.q, title = e.a or "" }
end

rerollQuote = function()
    if quoteSource() ~= "file" then return false end
    local today = os.date("%Y-%m-%d")
    local roll = sget("quote_file_roll")
    if type(roll) ~= "table" or roll.day ~= today then roll = { day = today, n = 0 } end
    sput("quote_file_roll", { day = today, file = roll.file, n = (tonumber(roll.n) or 0) + 1, prev = tonumber(roll.idx) })
    return true
end

local function quoteChanged()
    if A then
        pcall(function() A.D.nextQuote() end)
        A.epoch = (A.epoch or 0) + 1
    end
end

-- Menu: Quote Of The Day → Source, File.
local function quoteMenu(done)
    return {
        text = _("Quote Of The Day"),
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Source: My Quote File"), radio = true,
                    enabled_func = function() return quoteFileName() ~= nil end,
                    checked_func = function() return quoteSource() == "file" end,
                    keep_menu_open = true,
                    callback = function() sput("quote_source", "file"); quoteChanged(); done() end,
                },
                {
                    text = _("Source: My Highlights"), radio = true,
                    checked_func = function() return quoteSource() == "highlights" end,
                    keep_menu_open = true,
                    callback = function() sput("quote_source", "highlights"); quoteChanged(); done() end,
                    separator = true,
                },
            }
            local files = quoteFiles()
            if #files == 0 then
                items[#items + 1] = { text = _("No quote files in settings/simpleui/sui_quotes"), enabled = false }
            end
            for _i, f in ipairs(files) do
                items[#items + 1] = {
                    text = f, radio = true,
                    checked_func = function() return quoteFileName() == f end,
                    keep_menu_open = true,
                    callback = function()
                        sput("quote_file", f)
                        sput("quote_source", "file")
                        quoteChanged()
                        done()
                    end,
                }
            end
            return items
        end,
    }
end

-- ─── the minute tick (Banner / Today page clock) ────────────────────────────
-- Cards with a clock redraw just their clock strip at the start of each
-- minute, while they're on screen, the device is awake and no book is open.

local _clock_timer
local function cancelClock()
    if _clock_timer then
        UIManager:unschedule(_clock_timer)
        _clock_timer = nil
    end
end
local function clockTick()
    _clock_timer = nil
    if Device.screen_saver_mode or not liveClock() then return end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return end
    local any = false
    for _id, inst in pairs(INSTANCES) do
        if inst.clock and screenShowing(inst.id) then
            any = true
            inst.request("clock", "ui", true, inst.clock)
        end
    end
    if any then scheduleClock() end
end
scheduleClock = function()
    if _clock_timer or not liveClock() then return end
    _clock_timer = clockTick
    UIManager:scheduleIn(60 - (os.time() % 60) + 1, clockTick)
end

local function newInstance(id, card, dashboard)
    local inst = { id = id, card = card, dashboard = dashboard, regions = nil }
    INSTANCES[id] = inst
    -- request(reason, mode, now): repaint soon. Data landing is batched
    -- (several loads finishing close together = one repaint); taps go now.
    inst.request = function(reason, mode, now, strip)
        mode = STRENGTH[mode] and mode or "ui"
        -- a clock-only redraw keeps its strip unless something bigger joins it
        if strip and (inst.pending == nil or inst.strip) then inst.strip = strip else inst.strip = nil end
        if not inst.pending or STRENGTH[mode] > STRENGTH[inst.pending] then inst.pending = mode end
        inst.reason = reason
        if inst.timer then
            if not now then return end
            UIManager:unschedule(inst.timer)
        end
        inst.timer = function()
            inst.timer = nil
            local m, r, st = inst.pending, inst.reason, inst.strip
            inst.pending, inst.reason, inst.strip = nil, nil, nil
            renderInto(inst, m, r, st)
        end
        if now then UIManager:nextTick(inst.timer) else UIManager:scheduleIn(0.3, inst.timer) end
    end
    -- one stable function per card: Reading Log compares it
    inst.refresh = function()
        -- new data: kept tabs drawn without it go now, even if a tap
        -- redraw takes this request over before it runs
        if inst.dashboard and dropDash then dropDash(inst) end
        inst.request("data landed", "ui")
    end
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

-- The ctx the card kit draws and taps with. `sui` is SimpleUI's own screen
-- ctx from the last build (opening books, the book menu, Quick Actions).
local function bookshelfCtx(inst, w, h)
    local sctx = inst.sctx
    return {
        width = w, height = h,
        entry = { id = inst.id },
        mod_id = inst.id,
        pfx = type(sctx) == "table" and sctx.pfx or "simpleui_hs_",
        sui = sctx,
        config = inst.config,
        refresh = inst.refresh,
        set_tap_regions = function(regions) inst.regions = regions end,
        _rl_inst = inst,
    }
end

-- ─── dashboard tabs kept ready ─────────────────────────────────────────────
-- Each tab's last drawing is kept for up to a minute (the data's own
-- freshness), so switching back to a tab or turning back onto the page
-- doesn't redraw it. Anything that changes what it shows - other data,
-- settings, theme, night mode, size, the day, the clock's minute - draws it
-- again. Data landing or a reset (book menu, settings) drops them all.
local DASH_KEEP_S = 60
local _dash_cache = {}

local function realFree(c)
    c.free = nil -- back to the canvas's own free
    if type(c.free) == "function" then pcall(c.free, c) end
end

dropDash = function(inst)
    for page, e in pairs(_dash_cache) do
        -- the one on screen is freed by the normal swap, not here
        if inst and inst.box and inst.box[1] == e.canvas then e.canvas.free = nil else realFree(e.canvas) end
        _dash_cache[page] = nil
    end
end

-- Whether Simple UI's wallpaper shows through the dashboard (see
-- H.seeThrough), with a diagnostics line whenever what decides it changes.
local _last_see = {}
local function seeThrough(inst)
    local Ak = A
    local pfx = type(inst.sctx) == "table" and inst.sctx.pfx or "simpleui_hs_"
    local ok, see = pcall(Ak.host.seeThrough, pfx, inst.id)
    see = ok and see or false
    if not diagOn() then return see end
    local wp_on, strength = "?", "?"
    local okw, WP = pcall(require, "features/sui_wallpaper")
    if okw and type(WP) == "table" then
        local o1, v1 = pcall(WP.isWallpaperActive); wp_on = o1 and tostring(v1) or "error"
        local o2, v2 = pcall(WP.getModuleBackdropStrength, pfx, inst.id); strength = o2 and tostring(v2) or "error"
    end
    local line = string.format("wallpaper %s, Background Opacity %s -> %s | theme %s (own page colour %s) | night %s",
        wp_on, strength, see and "page left clear (cards solid, titles on plates)" or "page painted",
        tostring(Ak.themeId()), Ak.theme().page and "yes" or "no", Screen.night_mode and "on" or "off")
    if _last_see[inst.id] ~= line then
        _last_see[inst.id] = line
        diag("%s: %s", inst.id, line)
    end
    return see
end

local function dashKey(inst, w, h)
    local Ak = A
    -- Simple UI's side of the look too (its background colour, the
    -- wallpaper showing through): changing them in its menus draws the tab
    -- again instead of reusing a kept one.
    local bg = Ak.pageColors()
    return table.concat({
        floor(w), floor(h), tostring(Ak.state.dash_page or 1), tostring(Ak.epoch or 0),
        tostring(Ak.themeId()), Screen.night_mode and "n" or "d", tostring(Ak.state.month_offset or 0),
        os.date("%Y-%m-%d"), tostring(Ak.textSizePct(nil, inst.id)),
        bg[1] .. "." .. bg[2] .. "." .. bg[3], seeThrough(inst) and "see" or "solid",
        tostring(Ak.state.critter_rev or 0), -- tapping the critter: a new remark
    }, "|")
end

-- Diagnostics: where the dashboard's heading, cards and tab bar sit, when
-- that changes (Tab Bar Position, page, size).
local function logLayout(inst, canvas)
    if not (diagOn() and inst.dashboard and type(canvas) == "table" and type(canvas.layout) == "table") then return end
    local L = canvas.layout
    local line = string.format("layout %s tab %s: heading %s | cards y %s to %s | tab bar y %s (h %s), moved %s px (Tab Bar Position %s)",
        inst.id, tostring(A.state.dash_page or 1),
        L.head_y and string.format("y %d (h %d)", L.head_y, L.head_h) or "none",
        tostring(L.cards_y), tostring(L.cards_bottom), tostring(L.tabs_y), tostring(L.tabs_h),
        tostring(L.moved or 0), tostring(A.get("tabs_adjust", 0)))
    if inst._last_layout ~= line then
        inst._last_layout = line
        diag("%s", line)
    end
end

local function renderCanvas(inst, bctx, reason)
    local Ak = kit()
    if not Ak then return nil, "kit not loaded" end
    local ok, canvas
    -- a tab drawn less than a minute ago with nothing changed: use it
    local key, page
    if inst.dashboard then
        -- let go of tabs past their minute (not the one on screen)
        for p, e in pairs(_dash_cache) do
            if os.time() - e.at >= DASH_KEEP_S and not (inst.box and inst.box[1] == e.canvas) then
                realFree(e.canvas)
                _dash_cache[p] = nil
            end
        end
        reason = tostring(reason or "")
        if reason:find("^data") or reason:find("^cover") then
            dropDash(inst)
        elseif not reason:find("^clock") then
            key, page = dashKey(inst, bctx.width, bctx.height), Ak.state.dash_page or 1
            local e = _dash_cache[page]
            if e and e.key == key and os.time() - e.at < DASH_KEEP_S
                and (not e.minute or e.minute == os.date("%H:%M")) then
                local c = e.canvas
                if bctx.set_tap_regions then pcall(bctx.set_tap_regions, c.regions) end
                inst.clock = c.clock_y and { y = c.clock_y, h = c.clock_h } or nil
                if inst.clock and liveClock() then scheduleClock() end
                logLayout(inst, c)
                return c, nil, true
            end
        end
    end
    -- covers still being extracted are noted against this card
    Ak.D.cover_pending[inst.id] = nil
    Ak.D.cover_owner = inst.id
    if inst.dashboard then
        ok, canvas = pcall(Ak.Dashboard.render, bctx)
    else
        ok, canvas = pcall(Ak.render, inst.card, bctx)
    end
    Ak.D.cover_owner = nil
    if not ok or type(canvas) ~= "table" then return nil, canvas end
    if inst.dashboard then
        page = Ak.state.dash_page or 1
        key = key or dashKey(inst, bctx.width, bctx.height)
        local old = _dash_cache[page]
        if old and old.canvas ~= canvas then
            if inst.box and inst.box[1] == old.canvas then old.canvas.free = nil else realFree(old.canvas) end
        end
        -- covers still loading: not kept (they'd be missing next time)
        local pend = Ak.D.cover_pending[inst.id]
        if not (pend and next(pend)) then
            canvas.free = function() end -- kept: SimpleUI dropping its box mustn't free it
            _dash_cache[page] = { canvas = canvas, key = key, at = os.time(),
                minute = canvas.clock_y and os.date("%H:%M") or nil }
        else
            _dash_cache[page] = nil
        end
        logLayout(inst, canvas)
    end
    return canvas
end

renderInto = function(inst, mode, reason, strip)
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
    local canvas, err, kept = renderCanvas(inst, bookshelfCtx(inst, inst.w, inst.h), reason)
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
    if strip and tonumber(strip.y) and tonumber(strip.h) then
        local sx = tonumber(strip.x) and floor(strip.x) or 0
        local sw_ = tonumber(strip.w) and floor(strip.w) or r.w
        region = Geom:new{ x = r.x + sx, y = r.y + floor(strip.y), w = max(1, sw_), h = max(1, floor(strip.h)) }
    end
    UIManager:setDirty(sw, function() return mode, region, true end)
    diag("repaint %s in place (%s, %s) %s in %d ms | %d tap regions",
        inst.id, tostring(reason), mode, kept and "ready (kept)" or "built", now_ms() - t0, #(inst.regions or {}))
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
        ReadingLogSwipe = { GestureRange:new{ ges = "swipe", range = function() return inst.rect or box.dimen end } },
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
        diag("tap %s at %d,%d of %dx%d -> region %s (%d regions)", inst.id, rx, ry, w, h,
            tostring(region), #(inst.regions or {}))
        if inst.dashboard and region == nil then return false end
        -- the kit asks for the redraw it needs (H.repaint -> inst.request)
        local ok, err
        if inst.dashboard then
            ok, err = pcall(Ak.Dashboard.on_tap, ctx)
        else
            ok, err = pcall(Ak.onTap, inst.card, ctx)
        end
        if not ok then
            logger.warn(TAG, inst.id, "tap failed:", err)
            diag("TAP FAILED %s (%s): %s", inst.id, tostring(region), tostring(err))
        end
        _last_tap = os.time()
        return true
    end
    -- Left/right swipe that starts on a swipe spot switches its card; any
    -- other swipe is left to SimpleUI (page turns).
    function box:onReadingLogSwipe(_, ges)
        if not inst.dashboard or not ges or not ges.pos then return false end
        local dir = ges.direction
        if dir ~= "west" and dir ~= "east" then return false end
        local o = inst.rect or self.dimen
        local rx, ry = ges.pos.x - (o.x or 0), ges.pos.y - (o.y or 0)
        local spot
        for _i, r in ipairs(inst.regions or {}) do
            local s = type(r.id) == "string" and r.id:match("^swipe_(%a+)|$")
            if s and SWIPE[s] and rx >= r.x and rx < r.x + r.w and ry >= r.y and ry < r.y + r.h then
                spot = s
                break
            end
        end
        if not spot or not kit() then
            diag("swipe %s at %d,%d: not on the swipe card, left to SimpleUI", dir, rx, ry)
            return false
        end
        diag("swipe %s on %s at %d,%d", dir, spot, rx, ry)
        flipSwipe(spot, dir == "west" and 1 or -1, bookshelfCtx(inst, w, h))
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
        inst.sctx = ctx
        local h = M.getHeight(ctx)
        local slot_w, slot_h = w, h
        local fx, fy
        if inst.dashboard and dashFull() then
            fx, fy = 0, contentTop()
            w, h = Screen:getWidth(), contentHeight() - pageDotsHeight(inst)
        end
        inst.regions = nil
        local bctx = bookshelfCtx(inst, w, h)
        local t0 = now_ms()
        local canvas, err, kept = renderCanvas(inst, bctx, "build")
        if not canvas then
            logger.warn(TAG, inst.id, "render failed:", err)
            diag("RENDER FAILED %s (%dx%d): %s", inst.id, w, h, tostring(err))
            return nil
        end
        inst.regions = inst.regions or canvas.regions
        local avail = contentHeight()
        diag("%s %s %dx%d (asked %dx%d) in %d ms | size %s%% | theme %s, night %s | %d tap regions%s",
            kept and "reused kept" or "built", inst.id, canvas.w or -1, canvas.h or -1, w, h, now_ms() - t0, tostring(Ak.textSizePct(nil, inst.id)),
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

    -- Covers that were still being extracted when the card was drawn: once
    -- one lands, redraw the card. SimpleUI calls this from its cover poll;
    -- true = nothing left to wait for.
    function M.updateCovers()
        local Ak = A
        local set = Ak and Ak.D.cover_pending[inst.id]
        if not set or next(set) == nil then return true end
        local arrived, waiting = false, false
        for fp in pairs(set) do
            local st = Ak.host.coverSettled(fp)
            if st == "arrived" then arrived = true; set[fp] = nil
            elseif st == "none" then set[fp] = nil
            else waiting = true end
        end
        if arrived then inst.request("cover arrived", "ui") end
        return not waiting
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
            {
                text = _("Live Clock"),
                help_text = _("Update the clock on the Banner and the Today tab every minute while it's on screen. Off: it updates whenever the page redraws."),
                checked_func = liveClock,
                keep_menu_open = true,
                callback = function()
                    sput("live_clock", not liveClock())
                    if liveClock() then scheduleClock() else cancelClock() end
                end,
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
            -- Tab bar: pixels up (-) or down (+) from where it sits by default.
            -- Kept in the kit's settings (it lays the dashboard out); setting
            -- it there also draws the dashboard fresh.
            table.insert(appearance, 1, {
                text_func = function()
                    local Ak = kit()
                    local adj = Ak and tonumber(Ak.get("tabs_adjust", 0)) or 0
                    return _("Tab Bar Position: ") .. (adj == 0 and _("Default")
                        or ((adj > 0 and "+" or "") .. adj .. " px"))
                end,
                help_text = _("Moves the Today / Monthly / Yearly tab bar up (-) or down (+) from where it normally sits. Handy with a wallpaper showing through. Only the tab bar moves: the heading at the top stays put and the cards make room. It can only go down into the dashboard's margin."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local Ak = kit()
                    if not Ak then return end
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Tab Bar Position"),
                        info_text = _("Pixels up (-) or down (+) from the default (0)."),
                        value = tonumber(Ak.get("tabs_adjust", 0)) or 0,
                        value_min = -300, value_max = 100,
                        value_step = 2, value_hold_step = 10,
                        default_value = 0,
                        unit = "px",
                        ok_text = _("Save"),
                        callback = function(spin)
                            Ak.set("tabs_adjust", spin.value ~= 0 and spin.value or nil)
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            done()
                        end,
                    })
                end,
            })
            table.insert(appearance, 1, {
                text_func = function()
                    local adj = tonumber(sget("dash_bottom_adjust", 0)) or 0
                    return _("Bottom Space: ") .. (adj == 0 and _("Auto")
                        or ((adj > 0 and "+" or "") .. adj .. " px"))
                end,
                help_text = _("Full Screen layout only. Room left under the dashboard for SimpleUI's page dots. Auto fits the dots; add or take away pixels from there."),
                enabled_func = function() return sget("dash_layout", "card") == "full" end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local auto = autoDotsHeight(inst)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Bottom Space"),
                        info_text = string.format(_("Pixels added to the automatic %d px (0 = Auto)."), auto),
                        value = tonumber(sget("dash_bottom_adjust", 0)) or 0,
                        value_min = -auto, value_max = 200,
                        value_step = 2, value_hold_step = 10,
                        default_value = 0,
                        unit = "px",
                        ok_text = _("Save"),
                        callback = function(spin)
                            sput("dash_bottom_adjust", spin.value)
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            done()
                        end,
                    })
                end,
            })
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
                function() local Ak = kit(); return Ak and (Ak.D.dailyMinutesGoal() or 30) end,
                function(v) local Ak = kit(); if Ak then Ak.D.setDailyMinutesGoal(v) end end,
                5, 720, 5, " min", _("Same as SimpleUI's Daily Goal. Fills the minutes ring.")),
            numItem(_("Pages A Day"),
                function() local Ak = kit(); return Ak and Ak.get("activity_page_goal", 30) end,
                function(v) local Ak = kit(); if Ak then Ak.set("activity_page_goal", v) end end,
                1, 2000, 5, nil, _("Fills the pages ring.")),
        }
        -- Book club's own options (collection, this month's books, title),
        -- here so they're not three menus deep.
        goals[#goals].separator = true
        goals[#goals + 1] = {
            text = _("Book Club"),
            help_text = _("The Book Club card: which collection, this month's picks, and its title."),
            sub_item_table_func = function()
                local Ak = kit()
                if not Ak or type(Ak.S.cardContentMenu) ~= "function" then return {} end
                local mctx = {
                    menu = ctx_menu, pfx = ctx_menu and ctx_menu.pfx or "simpleui_hs_",
                    mod_id = inst.id, entry = { id = inst.id }, config = inst.config,
                    menu_refresh = function()
                        Ak.D.invalidate()
                        Ak.epoch = (Ak.epoch or 0) + 1
                        refreshScreen("book club settings: " .. inst.id)
                    end,
                }
                local ok, list = pcall(Ak.S.cardContentMenu, "bookclub", mctx)
                if not ok then diag("BOOK CLUB MENU FAILED: %s", tostring(list)) end
                return (ok and type(list) == "table") and list or {}
            end,
        }

        local items = {
            { text = _("Reading Goals"), sub_item_table = goals },
            {
                -- the kit's own options: the card's content, colour, Look and
                -- colours, When tapped; for the Dashboard, Pages and cards
                text = _("Reading Log Settings"),
                sub_item_table_func = function()
                    local Ak = kit()
                    if not Ak then return {} end
                    local mctx = {
                        menu = ctx_menu, pfx = ctx_menu and ctx_menu.pfx or "simpleui_hs_",
                        mod_id = inst.id, entry = { id = inst.id }, config = inst.config,
                        menu_refresh = function()
                            Ak.D.invalidate()
                            Ak.epoch = (Ak.epoch or 0) + 1
                            refreshScreen("settings changed: " .. inst.id)
                        end,
                    }
                    local ok, list
                    if inst.dashboard then
                        ok, list = pcall(Ak.S.dashboardMenu, mctx, nil, { no_size = true })
                    else
                        ok, list = pcall(Ak.S.cardMenu, inst.card, mctx, nil, { no_size = true })
                    end
                    if not ok then diag("SETTINGS MENU FAILED %s: %s", inst.id, tostring(list)) end
                    return (ok and type(list) == "table") and list or {}
                end,
            },
            { text = _("Appearance"), sub_item_table = appearance },
        }
        if inst.dashboard or inst.card == "quote" then
            items[#items + 1] = quoteMenu(done)
        end
        if inst.dashboard then
            -- Swipe Between 2-3 Cards on top. Off: pick one card. On: tick 2 or 3.
            local function picked()
                local set = {}
                for _i, n in ipairs(swipeCards("today")) do set[n] = true end
                return set
            end
            local function swipeChanged(old)
                local new = todaySlot()
                _swipe_i.today = nil
                swipeWeight("today")
                if kit() then
                    if old ~= new then swapTodayCard(TODAY_SLOT, old, new) else A.epoch = (A.epoch or 0) + 1 end
                end
                done()
            end
            local today_items = {
                {
                    text_func = function()
                        return _("Swipe Between 2-3 Cards") .. (todaySwipeOn() and (" (" .. #swipeCards("today") .. ")") or "")
                    end,
                    checked_func = todaySwipeOn,
                    keep_menu_open = true,
                    help_text = _("On: tick up to 3 cards below (a 4th replaces the oldest), then swipe left or right on the card, or tap its dots, to switch."),
                    callback = function()
                        local old = todaySlot()
                        if not todaySwipeOn() then
                            -- start from the card you have, plus one more
                            local saved = sget("swipe_today_cards")
                            if type(saved) ~= "table" or #saved < 2 then
                                local one = todayCard()
                                sput("swipe_today_cards", { one, one == "goal_covers" and "finished" or "goal_covers" })
                            end
                            sput("today_swipe", true)
                        else
                            sput("today_swipe", false)
                        end
                        diag("Today page card swipe: %s", tostring(todaySwipeOn()))
                        swipeChanged(old)
                    end,
                    separator = true,
                },
            }
            for _i, c in ipairs(TODAY_CHOICES) do
                today_items[#today_items + 1] = {
                    text = _(c[2]),
                    checked_func = function()
                        if todaySwipeOn() then return picked()[c[1]] == true end
                        return todayCard() == c[1]
                    end,
                    keep_menu_open = true,
                    callback = function()
                        if todaySwipeOn() then
                            -- tick: added at the end (a 4th replaces the oldest);
                            -- untick: removed, but at least one stays
                            local list = {}
                            for _j, n in ipairs(swipeCards("today")) do
                                if n ~= c[1] then list[#list + 1] = n end
                            end
                            if picked()[c[1]] then
                                if #list < 1 then return end
                            else
                                list[#list + 1] = c[1]
                                while #list > 3 do table.remove(list, 1) end
                            end
                            sput("swipe_today_cards", list)
                            diag("swipe today cards: %s", table.concat(list, ", "))
                            swipeChanged("swipe_today")
                            return
                        end
                        local old = todayCard()
                        if old == c[1] then return end
                        sput("today_card", c[1])
                        if kit() then swapTodayCard(TODAY_SLOT, old, c[1]) end
                        diag("Today page card: %s -> %s", old, c[1])
                        done()
                    end,
                }
            end
            today_items[#today_items].separator = true
            today_items[#today_items + 1] = alternateMenu(done)
            today_items[#today_items + 1] = {
                text = _("Flash On Swipe"),
                help_text = _("Flash the card when you swipe to another one, to clear ghosting. Off (default) is faster: no flash, a little ghosting may show."),
                enabled_func = todaySwipeOn,
                checked_func = function() return sget("swipe_flash", false) == true end,
                keep_menu_open = true,
                callback = function() sput("swipe_flash", not (sget("swipe_flash", false) == true)) end,
            }
            table.insert(items, 2, {
                text_func = function()
                    if todaySwipeOn() then
                        return _("Today Page Card: ") .. _("Swipe") .. " (" .. #swipeCards("today") .. ")"
                    end
                    for _i, c in ipairs(TODAY_CHOICES) do
                        if c[1] == todayCard() then return _("Today Page Card: ") .. _(c[2]) end
                    end
                    return _("Today Page Card")
                end,
                help_text = _("Which card sits under the rings on the Today tab. Book club uses a collection named like \"Book club\" (set it in that card's Reading Log settings). Swipe Between 2-3 Cards shows 2 or 3 of them in turn."),
                sub_item_table = today_items,
            })
            items[#items + 1] = {
                text_func = function()
                    local id = startTabId()
                    if id == "last" then return _("Start On Tab: Last Viewed") end
                    for _i, t in ipairs((kit() and A.state.dash_tabs) or {}) do
                        if t.id == id then return _("Start On Tab: ") .. tostring(t.label) end
                    end
                    return _("Start On Tab: ") .. id
                end,
                help_text = _("Which tab the dashboard shows when you come back to it: turning onto its page, after a book or after sleep. Last Viewed keeps the one you left on."),
                sub_item_table_func = function()
                    local list = {
                        {
                            text = _("Last Viewed"), radio = true,
                            checked_func = function() return startTabId() == "last" end,
                            keep_menu_open = true,
                            callback = function() sput("start_tab", nil) end,
                            separator = true,
                        },
                    }
                    local Ak = kit()
                    local tabs = Ak and Ak.state.dash_tabs
                    if not tabs and Ak then
                        -- dashboard not drawn yet since start: the pages themselves
                        tabs = {}
                        for i, pg in ipairs(Ak.dashPages()) do
                            tabs[#tabs + 1] = { kind = "page", page = i, id = pg.id, label = pg.label }
                        end
                    end
                    for _i, t in ipairs(tabs or {}) do
                        if t.kind == "page" and t.id then
                            list[#list + 1] = {
                                text = tostring(t.label), radio = true,
                                checked_func = function() return startTabId() == t.id end,
                                keep_menu_open = true,
                                callback = function() sput("start_tab", t.id) end,
                            }
                        end
                    end
                    return list
                end,
            }
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
        -- off the dashboard page: no point pre-loading its hidden tabs now
        if not vis and self._rl_vis then
            cancelPrewarm()
            cancelClock()
            goStartTab("page turned")
        end
        if self._rl_vis ~= nil and vis ~= self._rl_vis and sget("flash_clean", true) then
            UIManager:setDirty(nil, "full")
            diag("page turned %s the Reading Log page -> full refresh", vis and "onto" or "off")
        end
        self._rl_vis = vis
        return unpack(res)
    end
    -- SimpleUI turns pages on a swipe before the cards see it: a left/right
    -- swipe that starts on the Today swipe card goes to the card instead.
    local orig_he = w.handleEvent
    if type(orig_he) == "function" then
        w.handleEvent = function(self, event, ...)
            if type(event) == "table" and event.handler == "onGesture" then
                local ges = event.args and event.args[1]
                if type(ges) == "table" and ges.ges == "swipe"
                    and (ges.direction == "west" or ges.direction == "east") then
                    for _id, i in pairs(INSTANCES) do
                        if i.dashboard and i.on == self and i.box and i.rect then
                            local ok, took = pcall(i.box.onReadingLogSwipe, i.box, nil, ges)
                            if ok and took then return true end
                        end
                    end
                end
            end
            return orig_he(self, event, ...)
        end
    end
    diag("watching %s for page turns", tostring(w.name or "home window"))
end

-- ─── warm up the other dashboard tabs ───────────────────────────────────────
-- A tab's data is read in the background the first time it is drawn, and
-- each read that lands redraws the card. Draw the hidden tabs once, off
-- screen, a few seconds after the dashboard first shows, so the first real
-- switch to them is a single redraw with everything already there.

local _prewarm_state = nil -- nil = not started, "waiting", "done"
local _prewarm_timer = nil
-- Sleep stops it; it starts over the next time the dashboard is drawn.
cancelPrewarm = function()
    if _prewarm_timer then
        UIManager:unschedule(_prewarm_timer)
        _prewarm_timer = nil
        if _prewarm_state == "waiting" then _prewarm_state = nil end
    end
end
prewarm = function(inst)
    if _prewarm_state ~= nil or sget("prewarm", true) == false then return end
    _prewarm_state = "waiting"
    local tries = 0
    local queue, t_total, n = nil, 0, 0
    local function step()
        _prewarm_timer = nil
        local Ak = kit()
        if not Ak or not inst.w then _prewarm_state = "done"; return end
        -- don't compete with someone tapping around
        if os.time() - _last_tap < 2 and tries < 10 then
            tries = tries + 1
            _prewarm_timer = step
            UIManager:scheduleIn(3, step)
            return
        end
        if not queue then
            queue = {}
            for _i, tab in ipairs(Ak.state.dash_tabs or {}) do
                if tab.kind == "page" then queue[#queue + 1] = tab.page end
            end
        end
        -- one hidden tab per step, so no single stall is long
        local cur, tabs = Ak.state.dash_page, Ak.state.dash_tabs
        local page
        repeat page = table.remove(queue, 1) until page == nil or page ~= cur
        if not page then
            _prewarm_timer = nil
            _prewarm_state = "done"
            diag("prewarmed %d hidden dashboard tabs (%d ms in total)", n, t_total)
            return
        end
        local t0 = now_ms()
        Ak.state.dash_page = page
        local ctx = bookshelfCtx(inst, inst.w, inst.h)
        ctx._rl_inst = nil -- not the card on screen: no repaints, no clock
        ctx.entry = { id = inst.id .. "_prewarm" }
        ctx.refresh = function() end
        ctx.set_tap_regions = function() end
        local ok, c = pcall(Ak.Dashboard.render, ctx)
        if ok and type(c) == "table" and c.free then pcall(c.free, c) end
        Ak.state.dash_page, Ak.state.dash_tabs = cur, tabs
        n = n + 1
        t_total = t_total + (now_ms() - t0)
        _prewarm_timer = step
        UIManager:scheduleIn(1, step)
    end
    _prewarm_timer = step
    UIManager:scheduleIn(4, step)
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

function Plugin:onSuspend()
    cancelClock()
    cancelPrewarm()
    swipeAway()
    goStartTab("sleep")
    for _id, i in pairs(INSTANCES) do if i.dashboard then dropDash(i) end end
    resetHomePage("sleep")
end

-- After waking, the home screen redraws and the clock starts again from the
-- next minute (only if a card with a clock is on screen).
function Plugin:onResume()
    UIManager:scheduleIn(2, function()
        if not liveClock() then return end
        for _id, inst in pairs(INSTANCES) do
            if inst.clock and screenShowing(inst.id) then
                inst.request("clock", "ui", true, inst.clock)
                scheduleClock()
                diag("clock restarted after wake")
                return
            end
        end
    end)
end
function Plugin:onReaderReady()
    cancelPrewarm()
    cancelClock()
    swipeAway()
    goStartTab("book opened")
    for _id, i in pairs(INSTANCES) do if i.dashboard then dropDash(i) end end
    resetHomePage("book opened")
end

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
