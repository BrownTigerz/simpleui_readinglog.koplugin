-- Modified by TK for SimpleUI, 2026 (ported from stevenzamora1/reading-log).
--[[
Reading Log panels: one builder per card.

A builder takes `env` and returns a Canvas:
  env.w, env.h      the box to fill, in pixels
  env.tone          resolved card colours (see A.tone)
  env.ts            text-size multiplier (1 = normal; small text gets it all, see boost)
  env.cfg(key, d)   this card's saved setting
  env.refresh       call to redraw this card after a background read lands
  env.nested        true inside the dashboard (panel keeps its own rectangle)
  env.native        on its own in a Bookshelf grid: Bookshelf's card is the
                    card (no frame of our own; see A.nativeTone)
  env.slot          which saved set a slotted card uses (tbr / deadline)

Sizes are worked out from the box: `s` is how big the box is against the
card's reference design, and every length is a reference length times `s`.
]]

local A = ...
local D = A.D
local P = {}
A.panels = P
A.state = A.state or {}

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local round = A.round

-- Smallest text worth drawing: about 1.2 mm on the screen in hand.
local function minFont()
    return max(9, floor(A.screen():scaleBySize(13) / 2))
end

-- How much of the text-size boost a font of reference size n gets: all of it
-- for small text (labels, captions, axis figures: the text that is hard to
-- read on e-ink), none for big text (titles, clock, big figures, which are
-- already easy to read and would otherwise crowd everything else off the
-- card), in between on a slope.
local function boost(n, ts)
    ts = ts or 1
    -- Reading Log for SimpleUI: its Size setting also reaches big text, at
    -- half strength (A.BIG_TEXT_SHARE), so a size change is visible.
    return 1 + (ts - 1) * max(A.BIG_TEXT_SHARE or 0, A.clamp((36 - n) / 16, 0, 1))
end
A.textBoost = boost

-- Returns px(n) for lengths and fpx(n) for font sizes, both scaled by s.
local function scaler(s, ts)
    local floor_px = minFont()
    return function(n) return max(1, floor(n * s + 0.5)) end,
           function(n) return max(floor_px, floor(n * s * boost(n, ts) + 0.5)) end
end

local function card(env, s)
    local radius = max(4, round(32 * s))
    radius = min(radius, floor(min(env.w, env.h) / 4))
    if env.native then
        -- Bookshelf's card is the card: nothing drawn under the content,
        -- or a soft frameless panel for the tinted styles.
        return A.canvas{ w = env.w, h = env.h, tone = env.tone, radius = radius,
            plain = not env.tone.panel, bleed = env.bleed }
    end
    return A.canvas{
        w = env.w, h = env.h, tone = env.tone, radius = radius,
        border_w = env.tone.border and (env.tone.border_thin and max(1, round(2 * s)) or max(2, round(4 * s))) or 0,
        bleed = env.bleed and not env.nested,
        page = env.page,
    }
end

-- Two centred lines for a card with nothing to show yet.
local function emptyState(env, c, s, heading, line1, line2)
    local _, fpx = scaler(s, env.ts)
    local tone = env.tone
    local pad = round(36 * s)
    if heading then
        c:label(heading, fpx(22), pad, round(26 * s), { bold = true, caps = true, color = tone.accent, max_w = env.w - 2 * pad })
    end
    local t1 = c:text(line1, fpx(30), { bold = true, color = tone.fg, max_w = env.w - 2 * pad })
    local t2 = line2 and c:textbox(line2, fpx(22), env.w - 2 * pad, 2, { color = tone.muted, align = "center" }) or nil
    local total = t1.h + (t2 and (t2.h + round(6 * s)) or 0)
    local y = floor((env.h - total) / 2) + (heading and round(10 * s) or 0)
    c:put(t1, env.w / 2, y, "c")
    if t2 then c:put(t2, (env.w - t2.w) / 2, y + t1.h + round(6 * s)) end
    return c
end

local function monthLetter(m)
    return ({ "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" })[m]
end

local function shortMonth(m)
    return A.date("%b", os.time{ year = 2024, month = m, day = 15, hour = 12 })
end

-- The month the Monthly cards show: this one, or one the reader stepped back
-- to with the arrows on the Monthly page (A.state.month_offset, 0 to -12).
-- Returns year, month, whether it is this month.
function A.viewMonth()
    local off = A.clamp(floor(tonumber(A.state.month_offset) or 0), -(D.BACK_MONTHS or 12), 0)
    local t = os.date("*t")
    local vt = os.date("*t", os.time{ year = t.year, month = t.month + off, day = 1, hour = 12 })
    return vt.year, vt.month, off == 0
end

-- "September", or "September 2025" for a month of another year.
function A.monthTitle(y, m)
    local name = A.date("%B", os.time{ year = y, month = m, day = 15, hour = 12 })
    if y ~= tonumber(os.date("%Y")) then name = name .. " " .. y end
    return name
end

-- ════════════════════════════════════════════════════════════════════════════
-- Banner: clock, date, and a two-line name for the library
-- ════════════════════════════════════════════════════════════════════════════

P.banner = {
    does = "flashes the screen clean",
    title = "Banner", tone = "ink", ratio = 0.19, ratio_narrow = 0.42, tick = true,
    summary = "Clock, date and your library's name, or today's reading at a glance. Works offline.",
}

-- Tapping the clock flashes the whole screen once: the manual cure for
-- ghosting, wherever it came from.
function P.banner.tap() A.cleanScreen() end

-- The time as text, and "PM" (or nil) for a twelve-hour clock.
local function clockText(now)
    if G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock") then
        return (os.date("%I:%M", now):gsub("^0", "")), os.date("%p", now)
    end
    return os.date("%H:%M", now), nil
end

-- Three looks, picked in the card's settings (Style):
--   heading  (default) like the Yearly and Monthly page headings: the date as
--            a small accent line over the time in big bold type, your two
--            lines the same way on the right. On the Dashboard it sits
--            straight on the page, with no card round it.
--   glance   the time and date, with today's pages, minutes and streak
--   classic  thin digits, a divider, serif lines
function P.banner.build(env)
    local style = env.cfg("style", "heading")
    if style == "classic" then return P.banner.classic(env) end
    if style == "glance" then return P.banner.glance(env) end
    return P.banner.heading(env)
end

function P.banner.heading(env)
    local w, h = env.w, env.h
    local s = min(h / 170, w / 700)
    local px, fpx = scaler(s, env.ts)
    local c, fg, accent, muted
    if env.nested then
        local page_bg, page_fg, _, page_accent = A.dashPage()
        fg, accent = page_fg, page_accent
        c = A.canvas{ w = w, h = h, plain = true }
        muted = A.mix(page_bg, page_fg, 0.72)
    else
        c = card(env, s)
        fg, accent, muted = env.tone.fg, env.tone.accent, env.tone.muted
    end
    local pad = env.nested and 0 or px(36)
    local now = os.time()
    local time_str, suffix = clockText(now)
    local kicker = A.date("%A", now) .. "  \xE2\x80\xA2  " .. tonumber(os.date("%d", now)) .. " " .. A.date("%B", now)
    local t_k = c:text(kicker, fpx(24), { bold = true, caps = true, color = accent })
    local t_t = c:text(time_str, fpx(84), { bold = true, color = fg })
    local t_suf = suffix and c:text(suffix, fpx(30), { bold = true, color = muted }) or nil
    local tight = round(t_t.h * 0.14)
    local block = t_k.h + t_t.h - tight
    local y = floor((h - block) / 2)
    c:put(t_k, pad, y)
    local ty = y + t_k.h - tight
    c:put(t_t, pad - round(t_t.px * 0.03), ty)
    if t_suf then c:put(t_suf, pad + t_t.w + px(10), ty + t_t.base, "l", "base") end
    local left_w = max(t_k.w, t_t.w + (t_suf and (t_suf.w + px(10)) or 0))

    -- your two lines, right-aligned, in the same small-over-big pattern
    local line1, line2 = env.cfg("line1", ""), env.cfg("line2", "")
    local room = w - 2 * pad - left_w - px(48)
    if room > px(120) and (line1 ~= "" or line2 ~= "") then
        local t1 = line1 ~= "" and c:text(line1, fpx(24), { bold = true, caps = true, color = muted, max_w = room }) or nil
        local f2 = fpx(50)
        local t2 = line2 ~= "" and c:text(line2, f2, { bold = true, color = fg }) or nil
        if t2 and t2.w > room then
            t2 = c:text(line2, max(minFont(), floor(f2 * max(0.55, room / t2.w))), { bold = true, color = fg, max_w = room })
        end
        -- the big line sits on the clock's baseline
        local base = ty + t_t.base
        if t2 then c:put(t2, w - pad, base, "r", "base") end
        if t1 then c:put(t1, w - pad, y + t_k.base, "r", "base") end
    end
    return c
end

function P.banner.glance(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 200, w / 760)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local pad = px(36)
    local now = os.time()
    local time_str, suffix = clockText(now)
    local t_k = c:text(A.date("%A", now) .. "  \xE2\x80\xA2  " .. tonumber(os.date("%d", now)) .. " " .. A.date("%b", now),
        fpx(22), { bold = true, caps = true, color = tone.accent })
    local t_t = c:text(time_str, fpx(76), { bold = true, color = tone.fg })
    local t_suf = suffix and c:text(suffix, fpx(26), { bold = true, color = tone.muted }) or nil
    local tight = round(t_t.h * 0.14)
    local y = floor((h - (t_k.h + t_t.h - tight)) / 2)
    c:put(t_k, pad, y)
    local ty = y + t_k.h - tight
    c:put(t_t, pad - round(t_t.px * 0.03), ty)
    if t_suf then c:put(t_suf, pad + t_t.w + px(8), ty + t_t.base, "l", "base") end
    local left_w = max(t_k.w, t_t.w + (t_suf and (t_suf.w + px(8)) or 0))

    -- today at a glance: pages, minutes, streak (the Activity rings' figures)
    local st
    if env.sample then st = { today = { pages = 24, secs = 1560 }, streak = 5 }
    else st = D.stats(env.refresh) end
    local vals
    if st then
        vals = {
            { A.thousands(st.today.pages or 0), (st.today.pages == 1) and "page today" or "pages today", tone.accent },
            { A.fmtMinutes((st.today.secs or 0) / 60), "read today", tone.accent2 },
            { tostring(st.streak or 0), "day streak", tone.fg },
        }
    else
        local dash = st == false and "\xE2\x80\x94" or "\xE2\x80\xA6"
        vals = { { dash, "pages today", tone.accent }, { dash, "read today", tone.accent2 }, { dash, "day streak", tone.fg } }
    end
    local x0 = pad + left_w + px(40)
    local area = w - pad - x0
    if area < px(200) then return c end
    local cw = area / 3
    for i, v in ipairs(vals) do
        local cx = x0 + (i - 1) * cw
        local t_l = c:text(v[2], fpx(19), { bold = true, caps = true, color = tone.muted, max_w = cw - px(12) })
        local t_v = c:text(v[1], fpx(54), { bold = true, color = tone.fg, max_w = cw - px(12) })
        local bh = t_v.h + t_l.h - round(t_v.h * 0.12)
        local by = floor((h - bh) / 2)
        -- a short bar in the figure's colour, as on the Month totals card
        c:rrect(cx, by + round(t_v.h * 0.2), max(3, px(6)), bh - round(t_v.h * 0.3), max(2, px(3)), v[3], tone.bg)
        c:put(t_v, cx + px(18), by)
        c:put(t_l, cx + px(18), by + t_v.h - round(t_v.h * 0.12))
    end
    return c
end

function P.banner.classic(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 210, w / 640)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local pad = px(40)
    local now = os.time()

    local twelve = G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock")
    local time_str, suffix
    if twelve then
        time_str = (os.date("%I:%M", now):gsub("^0", ""))
        suffix = os.date("%p", now)
    else
        time_str = os.date("%H:%M", now)
    end
    local date_str = A.date("%A", now) .. ", " .. tonumber(os.date("%d", now)) .. " " .. A.date("%B", now)

    local line1 = env.cfg("line1", "")
    local line2 = env.cfg("line2", "")
    local has_right = (line1 ~= "" or line2 ~= "")

    local t_time = c:text(time_str, fpx(82), { color = tone.fg })
    local t_suf = suffix and c:text(suffix, fpx(28), { color = tone.muted, bold = true }) or nil
    local t_date = c:text(date_str, fpx(27), { color = tone.accent })
    local left_w = max(t_time.w + (t_suf and (t_suf.w + px(10)) or 0), t_date.w)

    -- The big digits carry a lot of built-in leading; pull the date up under them.
    local tighten = round(t_time.h * 0.16)
    local block_h = t_time.h + t_date.h - tighten
    local y0 = floor((h - block_h) / 2) - round(t_time.h * 0.03)

    local div_x = pad + left_w + px(44)
    local right_room = w - pad - (div_x + px(40))
    local t1, t2
    if has_right and right_room > px(150) then
        local f1, f2 = fpx(44), fpx(64)
        t1 = line1 ~= "" and c:text(line1, f1, { serif = true, color = tone.fg }) or nil
        t2 = line2 ~= "" and c:text(line2, f2, { serif = true, color = tone.fg }) or nil
        local need = max(t1 and t1.w or 0, t2 and t2.w or 0)
        if need > right_room then
            -- Shrink to fit, down to a size that still reads as a title (on a
            -- tall banner that is a long way down); past that, an ellipsis.
            local k = max(0.4, right_room / need)
            f1, f2 = max(minFont(), floor(f1 * k)), max(minFont(), floor(f2 * k))
            t1 = line1 ~= "" and c:text(line1, f1, { serif = true, color = tone.fg, max_w = right_room }) or nil
            t2 = line2 ~= "" and c:text(line2, f2, { serif = true, color = tone.fg, max_w = right_room }) or nil
        end
    else
        has_right = false
    end

    local lx = pad
    if not has_right then lx = floor((w - left_w) / 2) end
    c:put(t_time, lx, y0)
    if t_suf then c:put(t_suf, lx + t_time.w + px(10), y0 + t_time.base, "l", "base") end
    c:put(t_date, lx, y0 + t_time.h - tighten)

    if has_right then
        c:rect(div_x, 0, max(2, px(3)), h, tone.accent)
        local gap = t1 and t2 and -round((t2.h) * 0.14) or 0
        local rh = (t1 and t1.h or 0) + (t2 and t2.h or 0) + gap
        local ry = floor((h - rh) / 2)
        if t1 then c:put(t1, w - pad, ry, "r"); ry = ry + t1.h + gap end
        if t2 then c:put(t2, w - pad, ry, "r") end
    end
    return c
end

-- ════════════════════════════════════════════════════════════════════════════
-- Continue reading
-- ════════════════════════════════════════════════════════════════════════════

P.continue = {
    does = "opens the book",
    title = "Continue reading", tone = "paper", ratio = 0.36, ratio_narrow = 0.62,
    summary = "Books in progress, with cover and time left. Works offline.",
}

local SAMPLE_READING = {
    { title = "Carrie", author = "Stephen King", pct = 0.20, left_min = 282 },
    { title = "The Haunting of Hill House", author = "Shirley Jackson", pct = 0.46, left_min = 190 },
}

local function readingNow(env)
    if env.sample then return SAMPLE_READING end
    return D.reading(tonumber(env.cfg("count", 5)) or 5)
end

function P.continue.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local stacked = (w / h) < 1.9
    local s = stacked and min(w / 546, h / 400) or min(h / 400, w / 760)
    local px = scaler(s, env.ts)
    local c = card(env, s)
    local list = readingNow(env)
    if #list == 0 then
        return emptyState(env, c, s, "Continue reading", "Nothing in progress",
            "Open a book and it shows up here.")
    end
    local idx = A.clamp(tonumber(A.state.continue_idx) or 1, 1, #list)
    A.state.continue_idx = idx
    local book = list[idx]
    -- the picker's sample render must not disturb what a tap on the live card opens
    if not env.sample then A.state.continue_fp = book.fp end

    local floor_px = minFont()
    local function f(n) return max(floor_px, floor(n * s * boost(n, env.ts) + 0.5)) end
    local edge = tone.border or tone.muted
    local pct_txt = string.format("%d%%", floor(book.pct * 100 + 0.5))
    local left_txt = book.left_min and (A.fmtMinutes(book.left_min) .. " left") or nil
    local bar_h = max(4, px(10))
    -- how long this book has been on the go, from the first session the
    -- statistics recorded, and the time spent reading it so far
    local days_n, book_secs
    if env.sample then
        days_n, book_secs = 12, 4 * 3600 + 25 * 60
    else
        local _
        days_n, _, book_secs = D.dayOfBook(env.refresh, book.fp)
    end
    local span_txt, time_txt
    if days_n then
        span_txt = A.plural(days_n, "day", "days") .. " of reading"
        if book_secs and book_secs >= 60 then time_txt = A.fmtMinutes(book_secs / 60) .. " read" end
    end

    -- progress bar, "20%  ...  4 h left", and the two buttons, in a column
    -- x..x+width whose bottom edge is `bottom`. Returns the y it starts at.
    local function footer(x, width, bottom, with_buttons)
        local btn_h = f(58)
        local t_pct = c:text(pct_txt, f(26), { bold = true, color = tone.fg })
        local t_left = left_txt and c:text(left_txt, f(24), { bold = true, color = tone.muted, max_w = width - t_pct.w - f(20) }) or nil
        local y_btn = bottom - btn_h
        local y_row = (with_buttons and (y_btn - px(12)) or bottom) - t_pct.h
        local y_bar = y_row - px(8) - bar_h
        c:rrect(x, y_bar, width, bar_h, bar_h / 2, tone.track)
        c:rrect(x, y_bar, max(bar_h, round(width * A.clamp(book.pct, 0, 1))), bar_h, bar_h / 2, tone.btn, tone.track)
        c:put(t_pct, x, y_row)
        if t_left then c:put(t_left, x + width, y_row + t_pct.base, "r", "base") end
        if with_buttons then
            local two = width >= f(28) * 13
            local bgap = px(16)
            local w1 = two and floor((width - bgap) / 2) or width
            c:rrect(x, y_btn, w1, btn_h, btn_h / 2, tone.btn)
            c:label("Continue", f(28), x + w1 / 2, y_btn + btn_h / 2,
                { bold = true, color = tone.btn_fg, anchor = "c", valign = "mid" })
            c:region("open", x, y_btn, w1, btn_h, px(6))
            if two then
                local x2, w2 = x + w1 + bgap, width - w1 - bgap
                c:frame(x2, y_btn, w2, btn_h, btn_h / 2, max(2, px(4)), tone.border or tone.fg, tone.bg)
                c:label("Details", f(28), x2 + w2 / 2, y_btn + btn_h / 2,
                    { bold = true, color = tone.fg, anchor = "c", valign = "mid" })
                c:region("details", x2, y_btn, w2, btn_h, px(6))
            end
        end
        return y_bar
    end

    -- "CONTINUE READING" on the left, the "1 / 3 >" pager on the right.
    -- Returns the y below the row.
    local function header(x, width, y)
        local pill_h = f(46)
        local used = 0
        if #list > 1 then
            local t_pg = c:text(string.format("%d / %d  \xE2\x80\xBA", idx, #list), f(22), { bold = true, color = tone.fg })
            local pw = t_pg.w + f(36)
            local pxx = x + width - pw
            c:frame(pxx, y, pw, pill_h, pill_h / 2, max(2, px(3)), tone.border or tone.fg, tone.bg)
            c:put(t_pg, pxx + pw / 2, y + pill_h / 2, "c", "mid")
            c:region("next", pxx, y, pw, pill_h, px(14))
            used = pw + px(14)
        end
        -- the label is the first thing to go when the column is narrow
        local t_label = c:text("Continue reading", f(24), { bold = true, caps = true, color = tone.accent })
        if t_label.w <= width - used then
            c:put(t_label, x, y + pill_h / 2, "l", "mid")
        elseif used == 0 then
            c:label("Reading", f(24), x, y + pill_h / 2,
                { bold = true, caps = true, color = tone.accent, valign = "mid", max_w = width })
        end
        return y + pill_h
    end

    -- "4 days of reading  ·  2 h 14 m read" as the line after one whose
    -- baseline is prev_base (font prev_px), in a column x..x+width, if its
    -- letters stay above limit_y. Lines are spaced by baseline, not by the
    -- text boxes, whose built-in leading would waste the room. Returns
    -- whether it was drawn.
    local function spanLine(x, width, prev_base, prev_px, limit_y)
        if not span_txt then return false end
        local t_a = c:text(span_txt, f(25), { bold = true, color = tone.accent2 })
        local base = prev_base + floor(max(prev_px, t_a.px) * 1.2 + 0.5)
        if base + t_a.px * 0.28 > limit_y or t_a.w > width then return false end
        c:put(t_a, x, base, "l", "base")
        if time_txt then
            local t_b = c:text("  \xC2\xB7  " .. time_txt, f(25), { bold = true, color = tone.muted })
            if t_a.w + t_b.w <= width then c:put(t_b, x + t_a.w, base, "l", "base") end
        end
        return true
    end

    if stacked then
        -- Squarer card: cover and titles on top, bar and buttons full width below.
        local pad = px(30)
        local inner = w - 2 * pad
        local y_bar = footer(pad, inner, h - pad, h >= f(58) * 5)
        local top_h = y_bar - px(18) - pad
        local cover_h = max(8, top_h)
        local cover_w = round(cover_h * 2 / 3)
        if cover_w > inner * 0.34 then
            cover_w = round(inner * 0.34)
            cover_h = round(cover_w * 1.5)
        end
        c:cover(book.fp, pad, pad, cover_w, cover_h, { title = book.title, edge = edge })
        c:region("open", pad, pad, cover_w, cover_h)
        local tx = pad + cover_w + px(24)
        local tw = w - pad - tx
        local y = header(tx, tw, pad) + px(8)
        local room = pad + top_h - y
        local t_author = book.author and c:text(book.author, f(24), { color = tone.muted, max_w = tw }) or nil
        local t_title = c:textbox(book.title, f(34), tw, 2, { bold = true, color = tone.fg })
        if t_title.h + (t_author and t_author.h or 0) > room then
            t_title = c:textbox(book.title, f(34), tw, 1, { bold = true, color = tone.fg })
        end
        if t_title.h <= room then
            c:put(t_title, tx, y)
            local prev_base, prev_px = y + t_title.base, t_title.px
            if t_author and t_title.h + t_author.h <= room then
                c:put(t_author, tx, y + t_title.h)
                prev_base, prev_px = y + t_title.h + t_author.base, t_author.px
            end
            spanLine(tx, tw, prev_base, prev_px, pad + top_h)
        end
        return c
    end

    -- Wide card: cover on the left, everything else in a column beside it.
    local pad_x, pad_y = px(40), px(26)
    local cover_h = h - 2 * pad_y
    local cover_w = round(cover_h * 2 / 3)
    c:cover(book.fp, pad_x, pad_y, cover_w, cover_h, { title = book.title, edge = edge })
    c:region("open", pad_x, pad_y, cover_w, cover_h)
    local tx = pad_x + cover_w + px(38)
    local tw = w - tx - pad_x
    local y = header(tx, tw, pad_y + px(4)) + px(6)
    local t_title = c:text(book.title, f(44), { bold = true, color = tone.fg })
    if t_title.w > tw then t_title = c:text(book.title, f(36), { bold = true, color = tone.fg, max_w = tw }) end
    local t_author = book.author and c:text(book.author, f(28), { color = tone.muted, max_w = tw }) or nil
    local bottom = h - pad_y
    local need = t_title.h + f(58) + f(26) * 1.4 + bar_h + px(40)
    local with_buttons = (bottom - y) >= need
    local y_bar = footer(tx, tw, bottom, with_buttons)
    c:put(t_title, tx, y)
    local prev_base, prev_px = y + t_title.base, t_title.px
    local author_y = y + t_title.h - px(8)
    if t_author and author_y + t_author.h <= y_bar - px(6) then
        c:put(t_author, tx, author_y)
        prev_base, prev_px = author_y + t_author.base, t_author.px
    end
    -- "4 days of reading  ·  2 h 14 m read" under the author; on a short card,
    -- the days alone at the right-hand end of the author's line
    if not spanLine(tx, tw, prev_base, prev_px, y_bar - px(4)) and span_txt and t_author then
        local t_a = c:text(span_txt, f(25), { bold = true, color = tone.accent2 })
        if t_author.w + px(24) + t_a.w <= tw and author_y + t_author.h <= y_bar - px(6) then
            c:put(t_a, tx + tw, prev_base, "r", "base")
        end
    end
    return c
end

function P.continue.tap(env, region)
    local fp = A.state.continue_fp
    if region == "next" then
        A.state.continue_idx = (tonumber(A.state.continue_idx) or 1) + 1
        local list = readingNow(env)
        if A.state.continue_idx > #list then A.state.continue_idx = 1 end
        return
    end
    if not fp then return end
    if region == "details" then D.showDetails(env.ctx, fp) else D.openBook(env.ctx, fp) end
end

function P.continue.keep(region) return region == "next" end
function P.continue.controls(region) return region == "open" or region == "details" or region == "next" end

-- ════════════════════════════════════════════════════════════════════════════
-- Activity rings: pages, minutes, streak
-- ════════════════════════════════════════════════════════════════════════════

P.activity = {
    does = "opens reading progress",
    title = "Activity rings", tone = "plum", ratio = 0.61, ratio_narrow = 0.61,
    summary = "Today's pages, minutes and streak as rings. Needs the statistics plugin.",
}

local SAMPLE_STATS = {
    today = { pages = 24, secs = 1560 }, streak = 5, best = 21, week_pages = 262, week_secs = 15120,
    week = {
        { pages = 140, secs = 5400, wday = 2 }, { pages = 121, secs = 4800, wday = 3 },
        { pages = 1, secs = 120, wday = 4, today = true }, { pages = 0, secs = 0, wday = 5, future = true },
        { pages = 0, secs = 0, wday = 6, future = true }, { pages = 0, secs = 0, wday = 7, future = true },
        { pages = 0, secs = 0, wday = 1, future = true },
    },
    days = {},
}

local function statsFor(env)
    if env.sample then return SAMPLE_STATS end
    return D.stats(env.refresh)
end

function P.activity.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 335)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st = statsFor(env)
    if st == false then
        return emptyState(env, c, s, "Activity", "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local pad = px(30)
    local t_label = c:label("Activity", fpx(22), pad, px(24), { bold = true, caps = true, color = tone.accent })
    c:label("Today", fpx(22), w - pad, px(24), { color = tone.accent2, anchor = "r" })

    local pages = st and st.today.pages or 0
    local mins = st and floor(st.today.secs / 60 + 0.5) or 0
    local streak = st and st.streak or 0
    local page_goal = max(1, tonumber(env.cfg("page_goal", 30)) or 30)
    local min_goal = D.dailyMinutesGoal()
    local streak_goal = max(1, tonumber(env.cfg("streak_goal", 7)) or 7)

    local top = px(24) + t_label.h + px(10)
    local avail = h - top - px(22)
    local R = min(px(118), floor(avail / 2), floor(w * 0.24))
    local cx, cy = pad + R, top + floor(avail / 2)
    local t = max(3, round(R * 0.215))
    local gap = max(1, round(R * 0.055))
    local cols = tone.series
    c:ring(cx, cy, R, t, pages / page_goal, tone.track, cols[1])
    c:ring(cx, cy, R - t - gap, t, mins / min_goal, tone.track, cols[2])
    c:ring(cx, cy, R - 2 * (t + gap), t, streak / streak_goal, tone.track, cols[3])

    local lines = {
        st and A.plural(pages, "page", "pages") or "\xE2\x80\xA6",
        st and (A.fmtMinutes(mins) .. " read") or "\xE2\x80\xA6",
        st and (streak > 0 and ("Streak " .. A.plural(streak, "day", "days")) or "No streak yet") or "\xE2\x80\xA6",
    }
    local tx = cx + R + px(34)
    local room = w - pad - tx
    local size = fpx(29)
    local texts
    for _ = 1, 3 do
        texts = {}
        local widest = 0
        for i, str in ipairs(lines) do
            texts[i] = c:text(str, size, { bold = true, color = cols[i] })
            widest = max(widest, texts[i].w)
        end
        if widest <= room or size <= minFont() then break end
        size = max(minFont(), floor(size * max(0.6, room / widest)))
    end
    local step = max(texts[1].h + px(4), px(57))
    step = min(step, floor((2 * R) / 3))
    local y = cy - step
    for i = 1, 3 do
        c:put(texts[i], tx, y + (i - 1) * step, "l", "mid")
    end
    return c
end

function P.activity.tap(env)
    D.dispatch(env.cfg("tap", "reading_progress"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Year goal
-- ════════════════════════════════════════════════════════════════════════════

P.goal = {
    does = "nothing",
    title = "Year goal", tone = "wine", ratio = 0.61, ratio_narrow = 0.61,
    summary = "Books finished this year against your goal. Works offline.",
}

local function yearFor(env)
    if env.sample then
        return { year = os.date("*t").year, month = os.date("*t").month, total = 29, months = {}, list = {}, genres = {
            { name = "Horror", n = 7 }, { name = "Literary Fiction", n = 7 }, { name = "Thriller", n = 7 } } }
    end
    return D.year(env.refresh)
end

function P.goal.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local strip = (w / h) > 2.6
    local s = strip and min(h / 200, w / 620) or min(w / 546, h / 335)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local yr = yearFor(env)
    local t = os.date("*t")
    local pad = px(32)
    local t_label = c:label(tostring(t.year) .. " goal", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })

    local target, other = D.yearGoal()
    if env.sample then target, other = 36, 0 end
    local done = (yr and yr.total or 0) + other

    local status
    local yday = tonumber(os.date("%j"))
    local leap = (t.year % 4 == 0 and (t.year % 100 ~= 0 or t.year % 400 == 0))
    local expected = target * yday / (leap and 366 or 365)
    local diff = done - expected
    if not yr then
        status = "\xE2\x80\xA6"
    elseif done >= target then
        status = "Goal reached"
    elseif diff >= 1 then
        status = A.plural(floor(diff), "book", "books") .. " ahead"
    elseif diff <= -1 then
        status = A.plural(ceil(-diff), "book", "books") .. " behind"
    else
        status = "On track"
    end

    local top = px(22) + t_label.h
    local pill_h = fpx(56)
    local big_px = fpx(strip and 120 or 150)
    local big = c:text(yr and tostring(done) or "\xE2\x80\xA6", big_px, { bold = true, color = tone.fg })
    local of_txt = "of " .. A.plural(target, "book", "books")

    -- where the pill goes, and the band the number is centred in
    local pill_x, pill_y, pill_w, band_bottom
    if strip then
        pill_w = min(floor(w * 0.42), px(420))
        pill_x, pill_y = w - pad - pill_w, floor((h - pill_h) / 2)
        band_bottom = h - px(10)
    else
        pill_x, pill_w = pad, w - 2 * pad
        pill_y = h - px(26) - pill_h
        band_bottom = pill_y
        -- no room for both: the number wins
        if pill_y < top + big.h * 0.62 then pill_y, band_bottom = nil, h - px(10) end
    end

    local by = top + floor((band_bottom - top - big.h) / 2) - round(big.h * 0.02)
    c:put(big, pad - round(big_px * 0.04), by)
    local ox = pad + big.w + px(16)
    local limit = (strip and pill_x - px(16)) or (w - pad + px(8))
    local t_of = c:text(of_txt, fpx(28), { color = tone.accent2 })
    if ox + t_of.w > limit then t_of = c:text("/ " .. target, fpx(28), { color = tone.accent2 }) end
    if ox + t_of.w <= limit then
        c:put(t_of, ox, by + big.base - round(big_px * 0.02), "l", "base")
    end
    if pill_y then
        c:rrect(pill_x, pill_y, pill_w, pill_h, pill_h / 2, tone.btn)
        c:label(status, fpx(26), pill_x + pill_w / 2, pill_y + pill_h / 2,
            { bold = true, color = tone.btn_fg, anchor = "c", valign = "mid", max_w = pill_w - px(30) })
    end
    return c
end

-- A titled row of covers with a caption under each: the TBR shelf and the
-- recently-finished card. A very wide, short box moves the title to a column
-- on the left so the covers can use the full height.
--   o = { title=, dots=bool, counter=, counter_color=, tagline=, items=, max_n=, prefix= }
--   items[i] = { fp=, title=, label=, strong=bool }
-- Returns the files shown, in order (for the tap handler).
local function coverShelf(env, c, s, o)
    local w, h, tone = env.w, env.h, env.tone
    local px, fpx = scaler(s, env.ts)
    local pad = px(36)
    local items = o.items
    local probe = c:text("Ag", fpx(19), { bold = true })
    local has_labels = false
    for _, it in ipairs(items) do if it.label then has_labels = true end end
    local label_h = has_labels and (probe.h + px(10)) or px(6)
    local tagline = o.tagline or ""
    local area_x, area_w, top, avail_h

    if (w / h) > 3.4 then
        local lw = floor(w * 0.27)
        local y = px(24)
        local t_title = c:textbox(o.title, fpx(26), lw - pad, 2, { bold = true, caps = true, color = tone.fg })
        c:put(t_title, pad, y)
        y = y + t_title.h + px(6)
        if o.counter then
            local t = c:label(o.counter, fpx(24), pad, y, { bold = true, color = o.counter_color or tone.accent2, max_w = lw - pad })
            y = y + t.h + px(6)
        end
        if tagline ~= "" then
            local t_tag = c:textbox(tagline, fpx(20), lw - pad, 2, { color = tone.muted })
            if y + t_tag.h <= h - px(16) then c:put(t_tag, pad, y) end
        end
        area_x, area_w = lw + px(8), w - lw - px(8) - pad
        top = px(20)
        avail_h = h - top - label_h - px(16)
    else
        local hy = px(28)
        local t_title = c:text(o.title, fpx(26), { bold = true, caps = true, color = tone.fg, max_w = w * 0.6 })
        local tx = pad
        if o.dots then
            local dot = max(3, px(8))
            c:disc(pad + dot, hy + t_title.h / 2, dot, tone.accent)
            tx = pad + 2 * dot + px(12)
            c:disc(tx + t_title.w + px(12) + dot, hy + t_title.h / 2, dot, tone.accent)
        end
        c:put(t_title, tx, hy)
        if o.counter then
            c:label(o.counter, fpx(24), w - pad, hy + t_title.base,
                { bold = true, color = o.counter_color or tone.accent2, anchor = "r", valign = "base" })
        end
        local t_tag = tagline ~= "" and c:text(tagline, fpx(24), { bold = true, caps = true, color = tone.fg, max_w = w - 2 * pad }) or nil
        if t_tag then c:put(t_tag, w / 2, h - px(20) - t_tag.h, "c") end
        area_x, area_w = pad, w - 2 * pad
        top = hy + t_title.h + px(20)
        avail_h = h - top - label_h - (t_tag and (t_tag.h + px(14)) or 0) - px(20)
    end

    if #items == 0 then
        local cy = top + avail_h / 2
        local t1 = c:text(o.empty or "Nothing here yet", fpx(28), { bold = true, color = tone.fg, max_w = area_w })
        c:put(t1, area_x + area_w / 2, cy - t1.h / 2, "c")
        if o.empty_hint then
            c:label(o.empty_hint, fpx(22), area_x + area_w / 2, cy + t1.h / 2 + px(4),
                { color = tone.muted, anchor = "c", max_w = area_w })
        end
        return {}
    end
    if avail_h < 24 then return {} end

    local n = min(#items, o.max_n or 6)
    local gap = px(26)
    local min_cw = max(px(56), A.screen():scaleBySize(32))
    local ch = floor(avail_h)
    local cw = round(ch / 1.5)
    local fit_w = floor((area_w - (n - 1) * gap) / n)
    if fit_w < cw then
        if fit_w < min_cw then
            -- too many to show at a readable size: show fewer, not smaller
            n = A.clamp(floor((area_w + gap) / (min_cw + gap)), 1, n)
            fit_w = floor((area_w - (n - 1) * gap) / n)
        end
        cw = min(cw, fit_w)
        ch = round(cw * 1.5)
    end
    if n > 1 then gap = min(px(80), floor((area_w - n * cw) / (n - 1))) end
    local x0 = area_x + floor((area_w - (n * cw + (n - 1) * gap)) / 2)
    local cy0 = top + floor((avail_h - ch) / 2)
    local files = {}
    for i = 1, n do
        local b = items[i]
        local x = x0 + (i - 1) * (cw + gap)
        c:cover(b.fp, x, cy0, cw, ch, { title = b.title, edge = tone.border or tone.bg })
        if b.label then
            c:label(b.label, fpx(19), x + cw / 2, cy0 + ch + px(10),
                { bold = true, caps = true, anchor = "c", max_w = cw + gap * 0.8,
                  color = b.strong and tone.accent2 or tone.muted })
        end
        files[i] = b.fp or false
        c:region((o.prefix or "book:") .. i, x, cy0, cw, ch + label_h, px(4))
    end
    return files
end

-- ════════════════════════════════════════════════════════════════════════════
-- Shelf of covers from a collection (the "October TBR" card)
-- ════════════════════════════════════════════════════════════════════════════

P.tbr = {
    does = "opens the book tapped",
    title = "TBR shelf", tone = "paper", ratio = 0.41, ratio_narrow = 0.6, slots = true,
    summary = "A row of covers from one of your collections. Works offline.",
}

-- Which collection the shelf shows: the chosen one, else a likely TBR.
function P.tbr.collection(env)
    local names, fav = D.collections()
    local want = env.cfg("coll", "")
    for _, n in ipairs(names) do if n == want then return n end end
    local month = os.date("%B"):lower()
    local best
    for _, n in ipairs(names) do
        local l = n:lower()
        if l:find("tbr", 1, true) and l:find(month, 1, true) then return n end
        if not best and (l:find("tbr", 1, true) or l:find("to be read", 1, true) or l:find("to read", 1, true)) then
            best = n
        end
    end
    return best or fav or names[1]
end

local function tbrBooks(env)
    if env.sample then
        local out = {}
        for i, t in ipairs{ "Carrie", "Needless Street", "Wayward Girls", "Ask for Andrea", "Come Closer", "HEX" } do
            out[i] = { title = t, label = (i == 1 or i == 5) and "Digital" or "Hardcopy", strong = not (i == 1 or i == 5) }
        end
        return out, 6, "October TBR"
    end
    local coll = P.tbr.collection(env)
    local files = coll and D.collection(coll) or {}
    local hard = env.cfg("hardcopy", "Hardcopy")
    local names = D.collections()
    local has_hard = false
    for _, n in ipairs(names) do if n == hard then has_hard = true end end
    local mode = env.cfg("labels", "auto")
    if mode == "auto" then mode = (has_hard and hard ~= coll) and "format" or "status" end
    local out, todo = {}, 0
    for _, fp in ipairs(files) do
        local pct, status = D.progress(fp)
        if status ~= "finished" then todo = todo + 1 end
        local info = D.info(fp)
        local label, strong
        if mode == "format" then
            strong = D.inCollection(hard, fp)
            label = strong and "Hardcopy" or "Digital"
        elseif mode == "none" then
            label = nil
        elseif status == "finished" then
            label, strong = "Read", true
        elseif pct and pct > 0 then
            label, strong = string.format("%d%%", floor(pct * 100 + 0.5)), true
        else
            label = "To read"
        end
        out[#out + 1] = { fp = fp, title = info.title, label = label, strong = strong }
    end
    return out, todo, coll
end

function P.tbr.build(env)
    local w, h = env.w, env.h
    local s = min(h / 460, w / 900)
    if (w / h) > 3.4 then s = min(h / 300, w / 900) end
    local c = card(env, s)
    local books, todo, coll = tbrBooks(env)
    local title = env.cfg("title", "")
    if title == "" then
        title = env.sample and "October TBR" or (A.date("%B") .. " TBR")
    end
    local tagline = env.sample and "It's spooky season" or env.cfg("tagline", "")
    local name = coll and D.collectionLabel(coll) or "a collection"
    local files = coverShelf(env, c, s, {
        title = title, dots = true, counter = todo .. " to read", tagline = tagline,
        items = books, max_n = A.clamp(tonumber(env.cfg("count", 6)) or 6, 2, 10),
        empty = "No books here yet", empty_hint = "Add some to \xE2\x80\x9C" .. name .. "\xE2\x80\x9D.",
    })
    if not env.sample then A.state["tbr_files_" .. tostring(env.slot or 1)] = files end
    return c
end

function P.tbr.tap(env, region)
    local i = region and tonumber(region:match("^book:(%d+)$"))
    local files = A.state["tbr_files_" .. tostring(env.slot or 1)]
    local fp = i and files and files[i]
    if not fp then return end
    if env.cfg("tap", "open") == "details" then D.showDetails(env.ctx, fp) else D.openBook(env.ctx, fp) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Top genres of the year
-- ════════════════════════════════════════════════════════════════════════════

P.genres = {
    does = "nothing",
    title = "Top genres", tone = "plum", ratio = 0.25, ratio_narrow = 0.52,
    summary = "The genres you finished most this year. Works offline.",
}

function P.genres.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local rows = A.clamp(tonumber(env.cfg("count", 3)) or 3, 2, 6)
    local s = min(h / (104 + 57 * rows), w / 760)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local yr = yearFor(env)
    local pad = px(38)
    local t_head = c:label("Top genres", fpx(22), pad, px(26), { bold = true, caps = true, color = tone.accent })
    local year = yr and yr.year or os.date("*t").year
    local sub = c:text("books finished in " .. year, fpx(22), { bold = true, color = tone.muted })
    if pad + t_head.w + px(30) + sub.w <= w - pad then c:put(sub, w - pad, px(26), "r") end

    local list = yr and yr.genres or {}
    if yr == nil then
        c:label("\xE2\x80\xA6", fpx(30), w / 2, h / 2, { anchor = "c", valign = "mid", color = tone.muted })
        return c
    end
    if #list == 0 then
        c:label("Finish a book this year to see your genres", fpx(24), w / 2, h / 2 + px(10),
            { anchor = "c", valign = "mid", color = tone.muted, max_w = w - 2 * pad })
        return c
    end
    rows = min(rows, #list)
    local top = px(26) + t_head.h + px(12)
    local area = h - top - px(22)
    local row_h = min(px(60), floor(area / rows))
    local y0 = top + floor((area - rows * row_h) / 2)
    local count_w = px(64)
    local name_w = min(floor(w * 0.32), px(330))
    local bx = pad + name_w
    local bmax = w - pad - count_w - bx
    local bar_h = max(4, px(14))
    local top_n = max(1, list[1].n)
    for i = 1, rows do
        local g = list[i]
        local col = tone.series[((i - 1) % #tone.series) + 1]
        local cy = y0 + (i - 1) * row_h + row_h / 2
        c:label(g.name, fpx(28), pad, cy, { bold = true, color = tone.fg, valign = "mid", max_w = name_w - px(16) })
        c:rrect(bx, cy - bar_h / 2, max(bar_h, round(bmax * g.n / top_n)), bar_h, bar_h / 2, col)
        c:label(tostring(g.n), fpx(26), w - pad, cy, { bold = true, color = col, anchor = "r", valign = "mid" })
    end
    return c
end

-- ════════════════════════════════════════════════════════════════════════════
-- Year in covers: a stack of what you finished, month by month
-- ════════════════════════════════════════════════════════════════════════════

P.year_covers = {
    does = "shows the book tapped (elsewhere: opens the reading calendar)",
    title = "Year in covers", tone = "ink", ratio = 0.34, ratio_narrow = 0.7,
    summary = "Every cover you finished this year, in the order you finished them. Works offline.",
}

-- The grid that shows n covers (2:3) biggest in a W x H area, `gap` apart
-- side by side, each row with a label lane `lane` px tall above it (the lane
-- is the space between rows). Returns rows, columns, cover width.
local function coverGrid(n, W, H, gap, lane)
    local best_r, best_c, best_w = 1, max(1, n), 0
    for rows = 1, min(max(1, n), 12) do
        local cols = ceil(n / rows)
        local cw = (W - (cols - 1) * gap) / cols
        local ch = (H - rows * lane) / rows
        local k = min(cw, ch / 1.5)
        if k > best_w then best_r, best_c, best_w = rows, cols, k end
    end
    return best_r, best_c, floor(best_w)
end

-- Layouts: "wall" (default) = every cover of the year as big as the card
-- allows, oldest first, with the month named where each month starts;
-- "months" = the earlier look, a small stack of covers over each month.
function P.year_covers.build(env)
    if env.cfg("layout", "wall") == "months" then return P.year_covers.months(env) end
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 380, w / 640)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local yr = yearFor(env)
    if yr and yr.total == 0 and not env.sample then
        return emptyState(env, c, s, "Year in covers", "No books finished yet",
            "Each book you finish this year adds its cover here.")
    end
    local pad = px(36)
    local t_head = c:label("Year in covers", fpx(22), pad, px(26), { bold = true, caps = true, color = tone.accent })
    c:label(yr and (yr.total .. " finished") or "\xE2\x80\xA6", fpx(24), w - pad, px(26) + t_head.base,
        { bold = true, color = tone.fg, anchor = "r", valign = "base" })
    if not yr then return c end

    -- oldest first, so the wall reads like the year: left to right, top down
    local all = {}
    if env.sample then
        local now_m = os.date("*t").month
        for m = 1, now_m do
            for _ = 1, (m % 3) + 1 do all[#all + 1] = { month = m } end
        end
    else
        for i = #yr.list, 1, -1 do all[#all + 1] = yr.list[i] end
    end

    local top = px(26) + t_head.base + px(14)
    local W, H = w - 2 * pad, h - top - px(22)
    local gap = max(2, px(10))
    -- room for a month name in capitals above each row
    local lane = round(fpx(19) * 0.74) + px(10)
    -- smallest cover worth showing: about 4 mm across on the screen in hand
    local min_cw = max(px(46), A.screen():scaleBySize(24))
    -- Too many to show at a readable size: the newest that fit, after a tile
    -- counting the rest.
    local n = #all
    local shown, more = n, 0
    local rows, cols, cw = coverGrid(n, W, H, gap, lane)
    if cw < min_cw and n > 1 then
        local per_row = max(1, floor((W + gap) / (min_cw + gap)))
        local fit_rows = max(1, floor(H / (lane + min_cw * 1.5)))
        shown = A.clamp(per_row * fit_rows - 1, 1, n - 1)
        more = n - shown
        rows, cols, cw = coverGrid(shown + 1, W, H, gap, lane)
    end
    cw = max(8, cw)
    local ch = floor(cw * 1.5)
    local cells = shown + (more > 0 and 1 or 0)
    cols = min(cols, cells)
    local block_w = cols * cw + (cols - 1) * gap
    local block_h = rows * (lane + ch)
    local x0 = pad + floor((W - block_w) / 2)
    local y0 = top + floor((H - block_h) / 2)
    local now = os.date("*t")
    local files = {}

    local function cell(i)
        local r, col = floor((i - 1) / cols), (i - 1) % cols
        return x0 + col * (cw + gap), y0 + r * (lane + ch) + lane, col
    end

    local k = 0
    if more > 0 then
        k = 1
        local x, y = cell(1)
        c:rrect(x, y, cw, ch, max(2, px(6)), tone.track)
        local t_n = c:text("+" .. more, fpx(cw > px(70) and 34 or 26), { bold = true, color = tone.fg, max_w = cw - 4 })
        local t_e = c:text("earlier", fpx(19), { bold = true, color = tone.label })
        if t_e.w > cw - 4 then t_e = c:text("more", fpx(17), { bold = true, color = tone.label }) end
        if t_e.w > cw - 4 then t_e = nil end
        local ty = y + floor((ch - t_n.h - (t_e and t_e.h or 0)) / 2)
        c:put(t_n, x + cw / 2, ty, "c")
        if t_e then c:put(t_e, x + cw / 2, ty + t_n.h, "c") end
    end
    local prev_m
    for j = more + 1, n do
        k = k + 1
        local it = all[j]
        local x, y, col = cell(k)
        c:cover(it.fp, x, y, cw, ch, { title = it.title, edge = tone.border or tone.bg })
        -- name the month where it starts, and again at the start of a row
        if it.month ~= prev_m or col == 0 then
            local is_now = (it.month == now.month)
            local fresh = it.month ~= prev_m
            local color = is_now and tone.accent or (fresh and tone.label or tone.muted)
            local room = cw + gap - px(6)
            local t = c:text(shortMonth(it.month), fpx(19), { bold = true, caps = true, color = color })
            if t.w > room then t = c:text(monthLetter(it.month), fpx(19), { bold = true, color = color }) end
            c:put(t, x, y - px(6), "l", "base")
        end
        prev_m = it.month
        if it.fp then
            files[k] = it.fp
            c:region("book:" .. k, x, y, cw, ch, px(3))
        end
    end
    if not env.sample then A.state.year_cover_files = files end
    return c
end

function P.year_covers.months(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 380, w / 860)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local yr = yearFor(env)
    local pad = px(36)
    local t_head = c:label("Year in covers", fpx(22), pad, px(26), { bold = true, caps = true, color = tone.accent })
    c:label(yr and (yr.total .. " finished") or "\xE2\x80\xA6", fpx(24), w - pad, px(26) + t_head.base,
        { bold = true, color = tone.fg, anchor = "r", valign = "base" })

    local t_letter = c:text("M", fpx(22), { color = tone.muted })
    local base_y = h - px(22) - t_letter.h - px(22)
    c:rect(pad, base_y, w - 2 * pad, max(1, px(2)), A.mix(tone.bg, tone.accent, 0.8))

    local col_w = (w - 2 * pad) / 12
    local stack_w = floor(min(col_w * 0.74, px(74)))
    local t_count = c:text("8", fpx(22), { bold = true })
    local top_y = px(26) + t_head.h + px(8) + t_count.h + px(6)
    local max_h = base_y - px(3) - top_y
    local now_m = os.date("*t").month

    local max_n = 1
    local months = yr and yr.months or {}
    for m = 1, 12 do max_n = max(max_n, months[m] and #months[m] or 0) end
    local ch = round(stack_w * 1.5)
    local sl = max(3, round(ch * 0.21))
    local need = ch + (max_n - 1) * sl
    if need > max_h then
        local k = max_h / need
        ch = max(6, floor(ch * k))
        sl = max(2, floor(sl * k))
    end

    for m = 1, 12 do
        local cx = pad + (m - 1) * col_w + col_w / 2
        local is_now = (m == now_m)
        c:label(monthLetter(m), fpx(22), cx, base_y + px(14),
            { anchor = "c", color = is_now and tone.accent or tone.label, bold = true })
        if is_now then c:disc(cx, base_y + px(14) + t_letter.h + px(8), max(2, px(4)), tone.accent) end
        local list = months[m]
        if list and #list > 0 then
            local n = #list
            local sh = ch + (n - 1) * sl
            local x = floor(cx - stack_w / 2)
            local y = base_y - px(3) - sh
            c:cover(list[1].fp, x, y, stack_w, ch, { title = list[1].title, edge = tone.bg, top = true })
            for j = 2, n do
                local sy = y + ch + (j - 2) * sl
                c:cover(list[j].fp, x, sy, stack_w, sl, { edge = tone.bg, border = false })
                c:rect(x, sy, stack_w, 1, tone.bg)
            end
            c:label(tostring(n), fpx(22), cx, y - px(6) - t_count.h, { anchor = "c", bold = true, color = tone.accent })
        end
    end
    return c
end

function P.year_covers.tap(env, region)
    local i = region and tonumber(region:match("^book:(%d+)$"))
    local files = A.state.year_cover_files
    local fp = i and files and files[i]
    if fp then return D.showDetails(env.ctx, fp) end
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- This week, day by day
-- ════════════════════════════════════════════════════════════════════════════

P.week = {
    does = "opens the reading calendar",
    title = "This week", tone = "ink", ratio = 0.61, ratio_narrow = 0.61,
    summary = "Pages or minutes read each day this week. Needs the statistics plugin.",
}

local DAY_LETTERS = { "S", "M", "T", "W", "T", "F", "S" }

function P.week.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 335)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st = statsFor(env)
    if st == false then
        return emptyState(env, c, s, "This week", "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local pad = px(30)
    local by_minutes = env.cfg("metric", "pages") == "minutes"
    local t_head = c:label("This week", fpx(22), pad, px(24), { bold = true, caps = true, color = tone.accent })
    local total
    if not st then total = "\xE2\x80\xA6"
    elseif by_minutes then total = A.fmtMinutes(st.week_secs / 60)
    else total = A.plural(st.week_pages, "page", "pages") end
    c:label(total, fpx(24), w - pad, px(24) + t_head.base, { bold = true, color = tone.fg, anchor = "r", valign = "base" })

    local t_day = c:text("M", fpx(20), { bold = true })
    local base_y = h - px(22) - t_day.h - px(8)
    local top = px(24) + t_head.h + px(18)
    local area = max(4, base_y - top)
    local col_w = (w - 2 * pad) / 7
    local bar_w = max(4, floor(col_w * 0.5))
    local week = st and st.week or {}
    local top_v = 1
    for i = 1, 7 do
        local d = week[i]
        if d then top_v = max(top_v, by_minutes and d.secs or d.pages) end
    end
    for i = 1, 7 do
        local d = week[i] or { pages = 0, secs = 0, wday = ((D.weekStart() + i - 2) % 7) + 1, future = true }
        local v = by_minutes and d.secs or d.pages
        local cx = pad + (i - 1) * col_w + col_w / 2
        local x = floor(cx - bar_w / 2)
        local bh = v > 0 and max(bar_w, round(area * v / top_v)) or max(3, px(6))
        bh = min(bh, area)
        local col = v <= 0 and tone.track or (d.today and tone.accent or tone.accent2)
        c:rrect(x, base_y - bh, bar_w, bh, min(bar_w / 2, px(10)), col)
        c:label(DAY_LETTERS[d.wday] or "", fpx(20), cx, base_y + px(8),
            { anchor = "c", bold = true, color = d.today and tone.accent or tone.label })
    end
    return c
end

function P.week.tap(env)
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Reading heatmap
-- ════════════════════════════════════════════════════════════════════════════

P.heatmap = {
    does = "opens the reading calendar",
    title = "Reading heatmap", tone = "plum", ratio = 0.27, ratio_narrow = 0.6,
    summary = "A square for every day, brighter the more you read. Needs the statistics plugin.",
}

function P.heatmap.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 300, w / 700)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st = statsFor(env)
    if st == false then
        return emptyState(env, c, s, "Reading heatmap", "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local pad = px(36)
    local t_head = c:label("Reading heatmap", fpx(22), pad, px(24), { bold = true, caps = true, color = tone.accent })
    if st then
        local info = "Streak " .. st.streak .. "  \xC2\xB7  Best " .. st.best
        local t_info = c:text(info, fpx(22), { bold = true, color = tone.muted })
        if pad + t_head.w + px(24) + t_info.w <= w - pad then c:put(t_info, w - pad, px(24), "r") end
    end

    local t_m = c:text("Mar", fpx(17), { color = tone.muted })
    local grid_top = px(24) + t_head.h + px(8) + t_m.h + px(4)
    local grid_h = h - grid_top - px(24)
    local g = max(2, px(5))
    local cell = floor((grid_h - 6 * g) / 7)
    if cell < 3 then return c end
    local label_w = t_m.w + px(10)
    local weeks = floor((w - 2 * pad - label_w + g) / (cell + g))
    weeks = A.clamp(weeks, 4, 26)
    -- spread the columns across the width
    local gx = g
    if weeks > 1 then
        gx = min(g * 3, floor((w - 2 * pad - label_w - weeks * cell) / (weeks - 1)))
        gx = max(g, gx)
    end
    local grid_w = weeks * cell + (weeks - 1) * gx
    local x0 = pad + label_w + floor((w - 2 * pad - label_w - grid_w) / 2)

    local t = os.date("*t")
    local ws = D.weekStart()
    local back = (t.wday - ws) % 7
    local days = st and st.days or {}

    -- levels from the spread of the days on show
    local vals = {}
    local first_off = -((weeks - 1) * 7 + back)
    for off = first_off, 0 do
        local key = os.date("%Y-%m-%d", os.time{ year = t.year, month = t.month, day = t.day + off, hour = 12 })
        local d = days[key]
        if d and d.secs > 0 then vals[#vals + 1] = d.secs end
    end
    table.sort(vals)
    local function q(p) return vals[max(1, ceil(#vals * p))] or 0 end
    local q1, q2, q3 = q(0.25), q(0.5), q(0.75)
    local shades = {
        tone.track, A.mix(tone.track, tone.accent, 0.38), A.mix(tone.track, tone.accent, 0.62),
        A.mix(tone.track, tone.accent, 0.82), tone.accent,
    }
    local r = max(1, floor(cell * 0.22))
    local last_month
    for col = 0, weeks - 1 do
        local x = x0 + col * (cell + gx)
        for row = 0, 6 do
            local off = first_off + col * 7 + row
            if off <= 0 then
                local dt = os.time{ year = t.year, month = t.month, day = t.day + off, hour = 12 }
                local key = os.date("%Y-%m-%d", dt)
                local d = days[key]
                local v = d and d.secs or 0
                local lvl = 1
                if v > 0 then
                    if v <= q1 then lvl = 2 elseif v <= q2 then lvl = 3 elseif v <= q3 then lvl = 4 else lvl = 5 end
                end
                local y = grid_top + row * (cell + g)
                if off == 0 then
                    c:frame(x - 2, y - 2, cell + 4, cell + 4, r + 2, max(1, px(2)), tone.fg, shades[lvl])
                else
                    c:rrect(x, y, cell, cell, r, shades[lvl])
                end
                if row == 0 then
                    local mo = tonumber(os.date("%m", dt))
                    if mo ~= last_month then
                        if last_month ~= nil or tonumber(os.date("%d", dt)) <= 7 then
                            c:label(shortMonth(mo), fpx(18), x, grid_top - t_m.h - px(4), { bold = true, color = tone.label })
                        end
                        last_month = mo
                    end
                end
            end
        end
    end
    for _, row in ipairs{ 0, 2, 4, 6 } do
        local wd = ((ws - 1 + row) % 7) + 1
        c:label(DAY_LETTERS[wd], fpx(18), pad, grid_top + row * (cell + g) + cell / 2,
            { bold = true, color = tone.label, valign = "mid" })
    end
    return c
end

function P.heatmap.tap(env)
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Recently finished
-- ════════════════════════════════════════════════════════════════════════════

P.finished = {
    does = "shows the book tapped",
    title = "Recently finished", tone = "wine", ratio = 0.36, ratio_narrow = 0.6,
    summary = "The last few books you finished this year. Works offline.",
}

function P.finished.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 400, w / 860)
    if (w / h) > 3.4 then s = min(h / 300, w / 900) end
    local c = card(env, s)
    local yr = yearFor(env)
    local list = yr and yr.list or {}
    if env.sample then
        list = {}
        for i, tt in ipairs{ "Our Wives Under the Sea", "The Starless Sea", "Dark Matter", "Educated" } do
            list[i] = { title = tt, month = 10 - floor(i / 2), day = 3 * i }
        end
    end
    local items = {}
    for i, b in ipairs(list) do
        items[i] = { fp = b.fp, title = b.title, label = b.day .. " " .. shortMonth(b.month), strong = true }
    end
    local files = coverShelf(env, c, s, {
        title = "Recently finished", counter = yr and (yr.total .. " this year") or nil,
        counter_color = tone.fg, items = items,
        max_n = A.clamp(tonumber(env.cfg("count", 6)) or 6, 2, 10),
        empty = yr == nil and "\xE2\x80\xA6" or "Nothing finished yet this year",
    })
    if not env.sample then A.state.finished_files = files end
    return c
end

function P.finished.tap(env, region)
    local i = region and tonumber(region:match("^book:(%d+)$"))
    local fp = i and A.state.finished_files and A.state.finished_files[i]
    if fp then D.showDetails(env.ctx, fp) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Year goal with covers (added by Reading Log for SimpleUI)
-- ════════════════════════════════════════════════════════════════════════════
-- The year goal on the left (books finished, "of N books", ahead/behind),
-- the covers of this year's finished books on the right, newest first, and a
-- progress bar along the bottom with a tick where you should be by today.
P.goal_covers = {
    does = "shows the book tapped",
    title = "Year goal with covers", tone = "ink", ratio = 0.36, ratio_narrow = 0.62,
    summary = "Books finished this year against your goal, with their covers. Works offline.",
}

function P.goal_covers.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(h / 300, w / 860)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local yr = yearFor(env)
    local t = os.date("*t")
    local pad = px(30)

    local target, other = D.yearGoal()
    local list = yr and yr.list or {}
    if env.sample then
        target, other = 36, 0
        list = {}
        for i, tt in ipairs{ "Our Wives Under the Sea", "The Starless Sea", "Dark Matter", "Educated" } do
            list[i] = { title = tt }
        end
    end
    target = max(1, target or 24)
    local done = (yr and yr.total or (env.sample and 29 or 0)) + (other or 0)

    local yday = tonumber(os.date("%j"))
    local leap = (t.year % 4 == 0 and (t.year % 100 ~= 0 or t.year % 400 == 0))
    local expected = target * yday / (leap and 366 or 365)
    local diff = done - expected
    local status
    if not yr and not env.sample then status = "\xE2\x80\xA6"
    elseif done >= target then status = "Goal reached"
    elseif diff >= 1 then status = A.plural(floor(diff), "book", "books") .. " ahead"
    elseif diff <= -1 then status = A.plural(ceil(-diff), "book", "books") .. " behind"
    else status = "On track" end

    -- header: "2026 GOAL" left, status right
    local hy = px(20)
    local t_label = c:label(tostring(t.year) .. " goal", fpx(22), pad, hy, { bold = true, caps = true, color = tone.accent })
    c:label(status, fpx(22), w - pad, hy, { bold = true, color = tone.accent2, anchor = "r", max_w = w * 0.5 })

    -- progress bar along the bottom, with a tick for "where you should be"
    local bar_h = max(4, px(12))
    local bar_y = h - px(22) - bar_h
    local bar_w = w - 2 * pad
    c:rrect(pad, bar_y, bar_w, bar_h, bar_h / 2, tone.track)
    local frac = min(1, done / target)
    if frac > 0 then
        c:rrect(pad, bar_y, max(bar_h, floor(bar_w * frac)), bar_h, bar_h / 2, tone.accent)
    end
    local ex = pad + floor(bar_w * min(1, expected / target))
    c:rrect(ex - max(1, px(2)), bar_y - px(6), max(2, px(4)), bar_h + px(12), max(1, px(2)), tone.fg)

    -- left: the count
    local top = hy + t_label.h + px(12)
    local band_h = bar_y - px(16) - top
    local left_w = floor(w * 0.30)
    local big = c:text((yr or env.sample) and tostring(done) or "\xE2\x80\xA6", fpx(104), { bold = true, color = tone.fg })
    local of_t = c:text("of " .. A.plural(target, "book", "books"), fpx(26), { color = tone.accent2, max_w = left_w })
    local by = top + floor((band_h - big.h - of_t.h) / 2)
    c:put(big, pad - round(fpx(104) * 0.04), by)
    c:put(of_t, pad, by + big.h)

    -- right: this year's covers, newest first
    local area_x = pad + left_w
    local area_w = w - pad - area_x
    local files = {}
    if #list == 0 then
        local msg = (yr or env.sample) and "No books finished yet this year" or "\xE2\x80\xA6"
        local t1 = c:text(msg, fpx(24), { bold = true, color = tone.muted, max_w = area_w })
        c:put(t1, area_x + area_w / 2, top + band_h / 2, "c", "mid")
    elseif band_h > 24 then
        local gap = px(16)
        local ch = band_h
        local cw = round(ch / 1.5)
        local fit = max(1, floor((area_w + gap) / (cw + gap)))
        local n = min(#list, fit, A.clamp(tonumber(env.cfg("count", 8)) or 8, 1, 12))
        for i = 1, n do
            local b = list[i]
            local x = area_x + (i - 1) * (cw + gap)
            c:cover(b.fp, x, top, cw, ch, { title = b.title, edge = tone.border or tone.bg })
            files[i] = b.fp or false
            c:region("book:" .. i, x, top, cw, ch, px(4))
        end
        if #list > n then
            c:label("+" .. (#list - n), fpx(22), w - pad, top + ch, { bold = true, color = tone.muted, anchor = "r", valign = "base" })
        end
    end
    if not env.sample then A.state.goal_covers_files = files end
    return c
end

function P.goal_covers.tap(env, region)
    local i = region and tonumber(region:match("^book:(%d+)$"))
    local fp = i and A.state.goal_covers_files and A.state.goal_covers_files[i]
    if fp then D.showDetails(env.ctx, fp) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Longest reads: the books that took longest, this year or this month
-- ════════════════════════════════════════════════════════════════════════════
-- Ranked by reading time (or by days, from the first session to the day the
-- book was marked finished). Each row: cover, title, a bar against the
-- longest, the ranking figure large and the other one small.

local function longestCard(period)
    local def = {
        does = "shows the book tapped",
        title = period == "month" and "Longest reads (month)" or "Longest reads (year)",
        tone = period == "month" and "tint2" or "tint", ratio = 0.62, ratio_narrow = 0.75,
        summary = period == "month"
            and "The books you finished this month that took longest, by reading time or days. Needs the statistics plugin."
            or "The books you finished this year that took longest, by reading time or days. Needs the statistics plugin.",
    }
    local state_key = "longest_files_" .. period

    local SAMPLE = {
        { title = "The Starless Sea", author = "Erin Morgenstern", secs = 61200, span = 34, read_days = 21 },
        { title = "A Little Life", author = "Hanya Yanagihara", secs = 50400, span = 41, read_days = 26 },
        { title = "Piranesi", author = "Susanna Clarke", secs = 19800, span = 9, read_days = 6 },
        { title = "Educated", author = "Tara Westover", secs = 16200, span = 12, read_days = 8 },
    }

    function def.build(env)
        local w, h, tone = env.w, env.h, env.tone
        local s = min(w / 546, h / 400)
        local px, fpx = scaler(s, env.ts)
        local c = card(env, s)
        local now = os.date("*t")
        local by = env.cfg("by", "time")
        local vy, vm = A.viewMonth()
        local when = period == "month" and A.monthTitle(vy, vm) or tostring(now.year)
        local rows
        if env.sample then
            rows = SAMPLE
        elseif period == "month" then
            rows = D.longest(env.refresh, vm, by, vy)
        else
            rows = D.longest(env.refresh, nil, by)
        end
        if rows == false then
            return emptyState(env, c, s, "Longest reads", "No reading statistics",
                "Turn on KOReader's Reading statistics plugin.")
        end
        local pad = px(28)
        local t_head = c:label("Longest reads", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
        local t_when = c:text(when, fpx(21), { bold = true, color = tone.muted })
        if pad + t_head.w + px(16) + t_when.w <= w - pad then
            c:put(t_when, w - pad, px(22) + t_head.base, "r", "base")
        end
        local top = px(22) + t_head.h + px(14)
        if not rows then return c end
        if #rows == 0 then
            local msg = period == "month" and ("Nothing finished in " .. when) or "Nothing finished this year yet"
            c:label(msg, fpx(24), w / 2, top + (h - top) / 2, { anchor = "c", valign = "mid", color = tone.muted, max_w = w - 2 * pad })
            return c
        end

        -- What one full row needs: title, bar, then author and second figure.
        local probe_t = c:text("Ag", fpx(22), { bold = true })
        local probe_s = c:text("Ag", fpx(19))
        local bar_h = max(3, px(8))
        local full_row = probe_t.h + px(12) + bar_h + px(8) + probe_s.h
        -- As many rows as fit at a readable height, no more than asked for,
        -- and no taller than a full row: spare room goes to a total underneath.
        local want = A.clamp(tonumber(env.cfg("count", 3)) or 3, 1, 6)
        local t_foot = c:text("Ag", fpx(19))
        local avail = h - top - px(20)
        local min_row = px(64)
        local gap = px(14)
        local n = min(want, #rows, max(1, floor((avail + gap) / (min_row + gap))))
        local row_h = A.clamp(floor((avail - gap * (n - 1)) / n), min_row, full_row)
        local show_foot = (avail - n * row_h - (n - 1) * gap) >= t_foot.h + px(16)
        local cover_h = row_h
        local cover_w = floor(cover_h * 0.66)
        local x_text = pad + cover_w + px(18)
        local text_w = w - pad - x_text
        local function fig(r)
            if by == "days" then return r.span end
            return r.secs
        end
        local top_v = 0
        for i = 1, n do top_v = max(top_v, fig(rows[i]) or 0) end
        top_v = max(top_v, 1)
        local files = {}
        for i = 1, n do
            local r = rows[i]
            local y = top + (i - 1) * (row_h + gap)
            files[i] = r.fp
            c:cover(r.fp, pad, y, cover_w, cover_h, { title = r.title, edge = tone.muted })
            local big = by == "days" and A.plural(r.span, "day", "days") or A.fmtMinutes((r.secs or 0) / 60)
            local small = by == "days" and A.fmtMinutes((r.secs or 0) / 60) or A.plural(r.span, "day", "days")
            local t_big = c:text(big, fpx(26), { bold = true, color = tone.accent })
            local t_small = c:text(small, fpx(19), { bold = true, color = tone.muted })
            -- title on the first line, the figures to its right
            local t_title = c:text(r.title or "", fpx(22), { bold = true, color = tone.fg,
                max_w = max(px(40), text_w - t_big.w - px(14)) })
            c:put(t_title, x_text, y + px(2))
            c:put(t_big, w - pad, y + px(2) + t_title.base, "r", "base")
            -- A bar against the longest. Under it, the author and the second
            -- figure; in a short row the second figure goes beside the bar.
            local bar_y = y + px(2) + t_title.h + px(10)
            local sub_y = bar_y + bar_h + px(8)
            local roomy = sub_y + t_small.h <= y + row_h + px(4)
            local bar_w = roomy and text_w or (text_w - t_small.w - px(14))
            if bar_y + bar_h <= y + row_h and bar_w > px(30) then
                c:rrect(x_text, bar_y, bar_w, bar_h, bar_h / 2, tone.track)
                local fw = max(bar_h, floor(bar_w * (fig(r) or 0) / top_v))
                c:rrect(x_text, bar_y, fw, bar_h, bar_h / 2, tone.accent)
                if not roomy then c:put(t_small, w - pad, bar_y + bar_h / 2, "r", "mid") end
            end
            if roomy then
                local author = (r.author and r.author ~= "") and c:text(r.author, fpx(19), { color = tone.muted,
                    max_w = max(px(40), text_w - t_small.w - px(14)) }) or nil
                if author then c:put(author, x_text, sub_y) end
                c:put(t_small, w - pad, sub_y, "r")
            end
            c:region("book:" .. i, pad, y, w - 2 * pad, row_h)
        end
        if show_foot then
            -- the whole period: how many books, how much reading in them
            local secs = 0
            for _, r in ipairs(rows) do secs = secs + (r.secs or 0) end
            local line = A.plural(#rows, "book", "books") .. " finished  \xC2\xB7  "
                .. A.fmtMinutes(secs / 60) .. " read in them"
            c:label(line, fpx(19), pad, h - px(20), { valign = "base", color = tone.muted, max_w = w - 2 * pad })
        end
        if not env.sample then A.state[state_key] = files end
        return c
    end

    function def.tap(env, region)
        local i = region and tonumber(region:match("^book:(%d+)$"))
        local fp = i and A.state[state_key] and A.state[state_key][i]
        if fp then D.showDetails(env.ctx, fp) end
    end
    return def
end

P.longest_year = longestCard("year")
P.longest_month = longestCard("month")

-- ════════════════════════════════════════════════════════════════════════════
-- Finish by: a real book against a date (a library loan, say)
-- ════════════════════════════════════════════════════════════════════════════

P.deadline = {
    does = "opens its book",
    title = "Finish by", tone = "wine", ratio = 0.61, ratio_narrow = 0.61, slots = true,
    summary = "Pages a day to finish a book by a date. Works offline.",
}

function P.deadline.state(env)
    local fp = env.cfg("book", "")
    local y, m, d = A.parseYmd(env.cfg("due", ""))
    if fp == "" or not y then return nil end
    local t = os.date("*t")
    local today = A.dayNumber(t.year, t.month, t.day)
    local due = A.dayNumber(y, m, d)
    local sy, sm, sd = A.parseYmd(env.cfg("since", ""))
    local since = sy and A.dayNumber(sy, sm, sd) or today
    local pct, status, pages = D.progress(fp)
    pct = A.clamp(tonumber(pct) or 0, 0, 1)
    if status == "finished" then pct = 1 end
    local info = D.info(fp)
    local days_left = due - today
    local st = {
        fp = fp, title = info.title, label = env.cfg("label", "Finish by"),
        pct = pct, pages = tonumber(pages), days_left = days_left,
        due_txt = d .. " " .. shortMonth(m), done = pct >= 0.995,
    }
    local span = max(1, due - since)
    st.expected = A.clamp((today - since) / span, 0, 1)
    local divisor = max(1, days_left + 1) -- today still counts
    if st.pages and st.pages > 0 then
        st.per_day = ceil(st.pages * (1 - pct) / divisor)
        st.unit = "pages a day"
    else
        st.per_day = ceil(100 * (1 - pct) / divisor)
        st.unit = "% a day"
    end
    return st
end

function P.deadline.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 335)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st
    if env.sample then
        st = { title = "Piranesi", label = "Library loan", pct = 0.71, days_left = 12, due_txt = "21 Oct",
               expected = 0.6, per_day = 7, unit = "pages a day" }
    else
        st = P.deadline.state(env)
    end
    if not st then
        return emptyState(env, c, s, "Finish by", "Pick a book and a date",
            "Long-press this card, then Module settings.")
    end
    if not env.sample then A.state["deadline_fp_" .. tostring(env.slot or 1)] = st.fp end
    local pad = px(32)
    local head = st.label ~= "" and st.label or "Finish by"
    head = (head:lower() == "finish by") and ("Finish by " .. st.due_txt) or (head .. "  \xC2\xB7  due " .. st.due_txt)
    local t_head = c:label(head, fpx(22), pad, px(24), { bold = true, caps = true, color = tone.accent, max_w = w - 2 * pad })
    local t_title = c:label(st.title, fpx(32), pad, px(24) + t_head.h + px(4), { bold = true, color = tone.fg, max_w = w - 2 * pad })

    local pill_h = fpx(52)
    local pill_y = h - px(24) - pill_h
    local bar_h = max(4, px(12))
    local bar_y = pill_y - px(18) - bar_h
    local top = px(24) + t_head.h + px(4) + t_title.h
    local big_txt, unit_txt
    if st.done then big_txt, unit_txt = "Done", ""
    elseif st.days_left < 0 then big_txt, unit_txt = tostring(-st.days_left), (st.days_left == -1 and "day over" or "days over")
    elseif st.days_left == 0 then big_txt, unit_txt = "Today", ""
    else big_txt, unit_txt = tostring(st.days_left), (st.days_left == 1 and "day left" or "days left") end
    local room = bar_y - px(6) - top
    local big_px = min(fpx(92), floor(room * 0.8))
    local big = c:text(big_txt, big_px, { bold = true, color = tone.fg })
    local by = top + floor((room - big.h) / 2)
    c:put(big, pad - round(big_px * 0.04), by)
    local ux = pad + big.w + px(14)
    if unit_txt ~= "" then
        c:label(unit_txt, fpx(26), ux, by + big.base - round(big_px * 0.02), { color = tone.accent2, valign = "base" })
    end
    if not st.done and st.days_left >= 0 then
        local t_rate = c:text(tostring(st.per_day), fpx(40), { bold = true, color = tone.fg })
        local t_unit = c:text(st.unit, fpx(20), { bold = true, color = tone.muted })
        local rx = w - pad
        if rx - max(t_rate.w, t_unit.w) > ux + px(150) * (unit_txt ~= "" and 1 or 0.2) then
            local ry = by + floor((big.h - t_rate.h - t_unit.h) / 2) + px(4)
            c:put(t_rate, rx, ry, "r")
            c:put(t_unit, rx, ry + t_rate.h - px(4), "r")
        end
    end

    local bwid = w - 2 * pad
    c:rrect(pad, bar_y, bwid, bar_h, bar_h / 2, tone.track)
    c:rrect(pad, bar_y, max(bar_h, round(bwid * st.pct)), bar_h, bar_h / 2, tone.accent, tone.track)
    if not st.done then
        local mx = pad + round(bwid * st.expected)
        c:rect(mx - 1, bar_y - px(5), max(2, px(3)), bar_h + px(10), tone.fg)
    end

    local status
    if st.done then status = "Finished"
    elseif st.days_left < 0 then status = "Past due  \xC2\xB7  " .. floor(st.pct * 100 + 0.5) .. "% read"
    elseif st.pct + 0.02 >= st.expected then status = "On pace  \xC2\xB7  " .. floor(st.pct * 100 + 0.5) .. "% read"
    else status = "Behind  \xC2\xB7  " .. floor(st.pct * 100 + 0.5) .. "% read" end
    c:rrect(pad, pill_y, bwid, pill_h, pill_h / 2, tone.btn)
    c:label(status, fpx(24), w / 2, pill_y + pill_h / 2,
        { bold = true, color = tone.btn_fg, anchor = "c", valign = "mid", max_w = bwid - px(30) })
    return c
end

function P.deadline.tap(env)
    local fp = A.state["deadline_fp_" .. tostring(env.slot or 1)]
    if fp then D.openBook(env.ctx, fp) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Book club: this month's picks from one collection, and how much of the
-- whole list is read
-- ════════════════════════════════════════════════════════════════════════════

P.bookclub = {
    does = "opens the pick tapped",
    title = "Book club", tone = "ink", ratio = 0.27, ratio_narrow = 0.62,
    summary = "This month's picks from your book club collection, and how many are read. Works offline.",
}

-- The collection that holds the club's books: the chosen one, else one named
-- like "bookclub 2026" (this year's first), else any "book club" collection.
function P.bookclub.collection(env)
    local names = D.collections()
    local want = env.cfg("coll", "")
    for _, n in ipairs(names) do if n == want then return n end end
    local year = tostring(os.date("*t").year)
    local best
    for _, n in ipairs(names) do
        local squashed = (n:lower():gsub("[%s%-_]", ""))
        if squashed:find("bookclub", 1, true) then
            if n:find(year, 1, true) then return n end
            best = best or n
        end
    end
    return best
end

-- "YYYY-MM" for the month `offset` months from now.
function P.bookclub.monthKey(offset)
    local t = os.date("*t")
    local when = os.time{ year = t.year, month = t.month + (offset or 0), day = 1, hour = 12 }
    return os.date("%Y-%m", when), when
end

-- Every book in the collection with its progress, and this month's picks.
-- Picks are the ones ticked in the settings for this month; until some are
-- ticked, whatever from the collection is being read right now stands in.
function P.bookclub.state(env)
    local coll = P.bookclub.collection(env)
    if not coll then return nil end
    local files = D.collection(coll) or {}
    local by_fp, books, done = {}, {}, 0
    for i, fp in ipairs(files) do
        local pct, status = D.progress(fp)
        pct = A.clamp(tonumber(pct) or 0, 0, 1)
        local finished = status == "finished"
        if finished then done = done + 1 end
        local info = D.info(fp)
        books[i] = {
            fp = fp, title = info.title, author = info.author,
            pct = finished and 1 or pct, finished = finished,
            started = status == "reading" or (pct > 0 and pct < 0.995),
        }
        by_fp[fp] = books[i]
    end
    local all = env.cfg("picks", nil)
    local chosen = type(all) == "table" and all[P.bookclub.monthKey(0)] or nil
    local picks, auto = {}, false
    if type(chosen) == "table" then
        for _, fp in ipairs(chosen) do
            if by_fp[fp] then picks[#picks + 1] = by_fp[fp] end
        end
    end
    if #picks == 0 then
        auto = true
        for _, b in ipairs(books) do
            if b.started and not b.finished then picks[#picks + 1] = b end
        end
    end
    return { coll = coll, books = books, total = #books, done = done, picks = picks, auto = auto }
end

function P.bookclub.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = h / 300
    if w < 760 * s then s = w / 760 end
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st
    if env.sample then
        st = { coll = "bookclub 2026", total = 12, done = 7, books = {}, picks = {
            { title = "The Haunting of Hill House", author = "Shirley Jackson", pct = 0.46, started = true },
            { title = "HEX", author = "Thomas Olde Heuvelt", pct = 0 },
        } }
    else
        st = P.bookclub.state(env)
    end
    if not st then
        return emptyState(env, c, s, "Book club", "No book club collection yet",
            "Make a collection called \xE2\x80\x9Cbookclub " .. os.date("%Y") .. "\xE2\x80\x9D and add your books to it.")
    end
    local pad = px(36)
    local month = A.date("%B")
    local title = env.cfg("title", "Book club")
    if title == "" then title = "Book club" end

    -- header: "BOOK CLUB · OCTOBER", and how long the month has left
    local t = os.date("*t")
    local last = os.date("*t", os.time{ year = t.year, month = t.month + 1, day = 0, hour = 12 }).day
    local left = last - t.day
    local t_left = c:text(left == 0 and "Last day" or (A.plural(left, "day", "days") .. " left"), fpx(22), { bold = true, color = tone.muted })
    local t_head = c:label(title .. "  \xC2\xB7  " .. month, fpx(22), pad, px(24),
        { bold = true, caps = true, color = tone.accent, max_w = w - 2 * pad - t_left.w - px(20) })
    c:put(t_left, w - pad, px(24) + t_head.base, "r", "base")

    -- along the bottom: one segment per book in the collection, filled for
    -- each one finished, with the count beside it
    local t_count = c:text(st.done .. " of " .. st.total .. " read", fpx(22), { bold = true, color = tone.fg })
    local bar_h = max(5, px(16))
    local bar_y = h - px(24) - bar_h
    c:put(t_count, w - pad, bar_y + bar_h / 2, "r", "mid")
    local bwid = w - 2 * pad - t_count.w - px(18)
    if st.total > 0 and st.total <= 40 then
        local sgap = max(2, px(6))
        local seg = (bwid - (st.total - 1) * sgap) / st.total
        if seg < bar_h * 0.6 then
            sgap = max(1, floor(sgap / 2))
            seg = (bwid - (st.total - 1) * sgap) / st.total
        end
        for i = 1, st.total do
            local x0 = pad + round((i - 1) * (seg + sgap))
            local x1 = pad + round((i - 1) * (seg + sgap) + seg)
            c:rrect(x0, bar_y, max(2, x1 - x0), bar_h, bar_h / 2, i <= st.done and tone.accent or tone.track)
        end
    else
        c:rrect(pad, bar_y, bwid, bar_h, bar_h / 2, tone.track)
        if st.total > 0 and st.done > 0 then
            c:rrect(pad, bar_y, max(bar_h, round(bwid * st.done / st.total)), bar_h, bar_h / 2, tone.accent, tone.track)
        end
    end
    bwid = w - 2 * pad

    -- this month's picks, side by side
    local top = px(24) + t_head.h + px(14)
    local area_h = bar_y - px(20) - top
    local picks = st.picks
    local max_n = (w / h) < 1.9 and 2 or 3
    local n = min(#picks, max_n)
    local files = {}
    if n == 0 or area_h < px(60) then
        local line
        if st.total == 0 then
            line = "Add your club's books to \xE2\x80\x9C" .. D.collectionLabel(st.coll) .. "\xE2\x80\x9D"
        elseif n == 0 then
            line = "Choose " .. month .. "'s books in Module settings"
        end
        if line and area_h >= px(30) then
            c:label(line, fpx(24), w / 2, top + area_h / 2, { anchor = "c", valign = "mid", color = tone.muted, max_w = bwid })
        end
    else
        local gap = px(30)
        local col_w = floor((bwid - (n - 1) * gap) / n)
        for i = 1, n do
            local b = picks[i]
            local x = pad + (i - 1) * (col_w + gap)
            local cover_h = floor(area_h)
            local cover_w = round(cover_h * 2 / 3)
            if cover_w > col_w * 0.38 then
                cover_w = round(col_w * 0.38)
                cover_h = round(cover_w * 1.5)
            end
            local cy = top + floor((area_h - cover_h) / 2)
            c:cover(b.fp, x, cy, cover_w, cover_h, { title = b.title, edge = tone.muted })
            local tx = x + cover_w + px(20)
            local tw = col_w - cover_w - px(20)
            -- bottom of the column: status over a small progress bar
            local mb_h = max(4, px(9))
            local status = b.finished and "Finished" or (b.pct > 0 and string.format("%d%%", floor(b.pct * 100 + 0.5)) or "Not started")
            local t_status = c:text(status, fpx(22), { bold = true, max_w = tw,
                color = (b.finished and tone.accent) or (b.pct > 0 and tone.fg) or tone.muted })
            -- the words run the cover's height, so a short cover (a narrow
            -- card) has its title beside it rather than above it
            local mb_y = cy + cover_h - mb_h
            c:rrect(tx, mb_y, tw, mb_h, mb_h / 2, tone.track)
            if b.pct > 0 then
                c:rrect(tx, mb_y, max(mb_h, round(tw * b.pct)), mb_h, mb_h / 2, tone.accent, tone.track)
            end
            local st_y = mb_y - px(6) - t_status.h
            c:put(t_status, tx, st_y)
            -- top of the column: title, then author if there is room
            local room = st_y - px(4) - cy
            local t_title = c:textbox(b.title, fpx(n == 1 and 34 or 28), tw, 2, { bold = true, color = tone.fg })
            if t_title.h > room then t_title = c:textbox(b.title, fpx(n == 1 and 34 or 28), tw, 1, { bold = true, color = tone.fg }) end
            if t_title.h <= room then
                c:put(t_title, tx, cy - px(2))
                local t_author = b.author and c:text(b.author, fpx(21), { color = tone.muted, max_w = tw }) or nil
                if t_author and t_title.h + t_author.h <= room then c:put(t_author, tx, cy - px(2) + t_title.h) end
            end
            files[i] = b.fp or false
            c:region("pick:" .. i, x, top, col_w, area_h, px(4))
        end
    end
    if not env.sample then A.state.bookclub_files = files end
    return c
end

function P.bookclub.tap(env, region)
    local i = region and tonumber(region:match("^pick:(%d+)$"))
    local fp = i and A.state.bookclub_files and A.state.bookclub_files[i]
    if fp then D.openBook(env.ctx, fp) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Week rings: a pair of rings for each day of the week, and daily averages
-- ════════════════════════════════════════════════════════════════════════════

P.week_rings = {
    does = "opens the reading calendar",
    title = "Week rings", tone = "plum", ratio = 0.61, ratio_narrow = 0.61,
    summary = "Pages and minutes rings for each day this week, with daily averages. Needs the statistics plugin.",
}

function P.week_rings.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 335)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st = statsFor(env)
    if st == false then
        return emptyState(env, c, s, "This week", "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local pad = px(28)
    local cols = tone.series
    -- the same daily goals as the Activity rings card
    local page_goal = max(1, tonumber(A.get("activity_page_goal", 30)) or 30)
    local min_goal = D.dailyMinutesGoal()
    local week = st and st.week or {}

    local t_head = c:label("This week", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
    if st then
        local total = A.plural(st.week_pages, "page", "pages") .. "  \xC2\xB7  " .. A.fmtMinutes(st.week_secs / 60)
        local t_total = c:text(total, fpx(21), { bold = true, color = tone.muted })
        if pad + t_head.w + px(20) + t_total.w > w - pad then
            t_total = c:text(A.plural(st.week_pages, "page", "pages"), fpx(21), { bold = true, color = tone.muted })
        end
        if pad + t_head.w + px(20) + t_total.w <= w - pad then
            c:put(t_total, w - pad, px(22) + t_head.base, "r", "base")
        end
    end

    -- averages along the bottom, over the days of the week so far
    local elapsed = 0
    for i = 1, 7 do if week[i] and not week[i].future then elapsed = elapsed + 1 end end
    elapsed = max(1, elapsed)
    local avg_pages = st and floor(st.week_pages / elapsed + 0.5) or nil
    local avg_mins = st and (st.week_secs / 60 / elapsed) or nil
    local half = floor((w - 2 * pad) / 2)
    local t_v1 = c:text(avg_pages and A.plural(avg_pages, "page", "pages") or "\xE2\x80\xA6", fpx(27),
        { bold = true, color = cols[1], max_w = half - px(8) })
    local t_v2 = c:text(avg_mins and A.fmtMinutes(avg_mins) or "\xE2\x80\xA6", fpx(27),
        { bold = true, color = cols[2], max_w = half - px(8) })
    local t_c1 = c:text("a day on average", fpx(18), { bold = true, color = tone.muted, max_w = half - px(8) })
    local t_c2 = c:text("a day on average", fpx(18), { bold = true, color = tone.muted, max_w = half - px(8) })
    local tighten = round(t_v1.h * 0.12)
    local stats_y = h - px(18) - (t_v1.h + t_c1.h - tighten)
    c:put(t_v1, pad, stats_y)
    c:put(t_c1, pad, stats_y + t_v1.h - tighten)
    c:put(t_v2, pad + half + px(8), stats_y)
    c:put(t_c2, pad + half + px(8), stats_y + t_v1.h - tighten)

    -- day letters, then one pair of rings under each
    local t_l = c:text("M", fpx(20), { bold = true })
    local letters_y = px(22) + t_head.h + px(10)
    local rings_top = letters_y + t_l.h + px(8)
    local ring_area = stats_y - px(12) - rings_top
    local col_w = (w - 2 * pad) / 7
    local d = min(floor(col_w * 0.9), floor(ring_area))
    if d >= 10 then
        local R = d / 2
        local t = max(2, round(R * 0.27))
        local gap = max(1, round(R * 0.08))
        local cy = rings_top + ring_area / 2
        local ws = D.weekStart()
        for i = 1, 7 do
            local day = week[i] or { pages = 0, secs = 0, wday = ((ws + i - 2) % 7) + 1, future = true }
            local cx = pad + (i - 0.5) * col_w
            c:label(DAY_LETTERS[day.wday] or "", fpx(20), cx, letters_y,
                { anchor = "c", bold = true, color = day.today and tone.accent or tone.label })
            local fp = day.future and 0 or day.pages / page_goal
            local fm = day.future and 0 or (day.secs / 60) / min_goal
            -- a ring with nothing in it is all track: no start dot
            c:ring(cx, cy, R, t, fp, tone.track, fp > 0 and cols[1] or tone.track)
            c:ring(cx, cy, R - t - gap, t, fm, tone.track, fm > 0 and cols[2] or tone.track)
            local hole = R - 2 * t - 2 * gap
            if fp >= 1 and fm >= 1 and hole >= 2 then
                -- both goals met: fill the middle
                c:disc(cx, cy, max(1.5, hole * 0.7), cols[3])
            end
        end
    end
    return c
end

function P.week_rings.tap(env)
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Month rings: the same two rings for every day of this month, as a calendar
-- ════════════════════════════════════════════════════════════════════════════

P.month_rings = {
    does = "opens the reading calendar",
    title = "Month rings", tone = "plum", ratio = 0.82, ratio_narrow = 0.9,
    summary = "Pages and minutes rings for each day this month, laid out as a calendar. Needs the statistics plugin.",
}

function P.month_rings.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 450)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local st = statsFor(env)
    local now = os.date("*t")
    -- the month shown: this one, or one stepped back to on the Monthly page
    local year, month, current = A.viewMonth()
    if env.sample then year, month, current = now.year, now.month, true end
    local month_name = A.monthTitle(year, month)
    if st == false then
        return emptyState(env, c, s, month_name, "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local pad = px(28)
    local cols = tone.series
    -- the same daily goals as the Activity and Week rings cards
    local page_goal = max(1, tonumber(A.get("activity_page_goal", 30)) or 30)
    local min_goal = D.dailyMinutesGoal()

    -- the month, day by day; a past month has every day behind it
    local today = current and now.day or 99
    local n_days = tonumber(os.date("%d", os.time{ year = year, month = month + 1, day = 0, hour = 12 })) or 30
    local first_wday = tonumber(os.date("%w", os.time{ year = year, month = month, day = 1, hour = 12 })) + 1
    local ws = D.weekStart()
    local offset = (first_wday - ws) % 7
    local n_rows = ceil((offset + n_days) / 7)
    local days = st and st.days or {}
    local function dayRec(d)
        if env.sample then
            -- a believable month for the picker's preview
            if d > today then return { pages = 0, secs = 0 } end
            local v = (d * 37) % 11
            return { pages = v * 7, secs = v * 380 }
        end
        return days[string.format("%04d-%02d-%02d", year, month, d)] or { pages = 0, secs = 0 }
    end
    local sum_pages, sum_secs = 0, 0
    for d = 1, min(today, n_days) do
        local rec = dayRec(d)
        sum_pages, sum_secs = sum_pages + (rec.pages or 0), sum_secs + (rec.secs or 0)
    end

    local t_head = c:label(month_name, fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
    -- Top right: the averages per day over the month so far, each in the
    -- colour of its ring ("86 pages  1 h 35 m  a day"). Shortened, then
    -- dropped, when the card is too narrow for them beside the month.
    local elapsed = max(1, min(today, n_days))
    do
        local dots = "\xE2\x80\xA6"
        local v_pages = st and A.plural(floor(sum_pages / elapsed + 0.5), "page", "pages") or dots
        local v_time = st and A.fmtMinutes(sum_secs / 60 / elapsed) or dots
        local f_v = fpx(23)
        local function try(parts)
            local items, width = {}, 0
            for i, p in ipairs(parts) do
                local t = c:text(p[1], p[3] or f_v, { bold = true, color = p[2] })
                items[i] = t
                width = width + t.w + (i > 1 and px(14) or 0)
            end
            if pad + t_head.w + px(20) + width > w - pad then return false end
            local x = w - pad - width
            for i, t in ipairs(items) do
                if i > 1 then x = x + px(14) end
                c:put(t, x, px(22) + t_head.base, "l", "base")
                x = x + t.w
            end
            return true
        end
        local _ = try({ { v_pages, cols[1] }, { v_time, cols[2] }, { "a day", tone.muted, fpx(19) } })
            or try({ { v_pages, cols[1] }, { v_time, cols[2] } })
            or try({ { v_pages, cols[1] } })
    end
    local stats_y = h - px(12)

    -- weekday letters, then one row of rings per week
    local t_l = c:text("M", fpx(19), { bold = true })
    local letters_y = px(22) + t_head.h + px(8)
    local grid_top = letters_y + t_l.h + px(6)
    local grid_h = stats_y - grid_top
    local col_w = (w - 2 * pad) / 7
    local row_h = grid_h / n_rows
    local today_col = current and (((offset + today - 1) % 7) + 1) or 0
    for i = 1, 7 do
        local wday = ((ws + i - 2) % 7) + 1
        local is_today = (i == today_col)
        c:label(DAY_LETTERS[wday] or "", fpx(19), pad + (i - 0.5) * col_w, letters_y,
            { anchor = "c", bold = true, color = is_today and tone.accent or tone.label })
    end
    -- as big as the cell allows, leaving a little air (and room for the
    -- short bar under today)
    local d_ring = min(floor(col_w * 0.9), floor(row_h * 0.86))
    if d_ring >= 8 then
        local R = d_ring / 2
        local two = R >= 13            -- room for both rings; below that, pages only
        local t = two and max(2, round(R * 0.27)) or max(2, round(R * 0.38))
        local gap = max(1, round(R * 0.08))
        for d = 1, n_days do
            local slot = offset + d - 1
            local cx = pad + ((slot % 7) + 0.5) * col_w
            local cy = grid_top + (floor(slot / 7) + 0.5) * row_h
            local rec = dayRec(d)
            local future = d > today
            local fp = future and 0 or (rec.pages or 0) / page_goal
            local fm = future and 0 or ((rec.secs or 0) / 60) / min_goal
            -- a ring with nothing in it is all track: no start dot
            c:ring(cx, cy, R, t, fp, tone.track, fp > 0 and cols[1] or tone.track)
            if two then
                c:ring(cx, cy, R - t - gap, t, fm, tone.track, fm > 0 and cols[2] or tone.track)
                local hole = R - 2 * t - 2 * gap
                if fp >= 1 and fm >= 1 and hole >= 2 then c:disc(cx, cy, max(1.5, hole * 0.7), cols[3]) end
            elseif fm >= 1 and R - t >= 3 then
                -- one ring only: the minutes goal shows as a filled middle
                c:disc(cx, cy, max(1.5, (R - t) * 0.6), cols[2])
            end
            if current and d == today then
                -- today: a short bar under its rings
                local bar_w, bar_h = max(4, round(R * 0.9)), max(2, round(R * 0.14))
                local by = cy + R + max(1, round((row_h - d_ring) * 0.2))
                if by + bar_h <= grid_top + grid_h + px(8) then
                    c:rrect(cx - bar_w / 2, by, bar_w, bar_h, bar_h / 2, tone.fg)
                end
            end
        end
    end
    return c
end

function P.month_rings.tap(env)
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Year chart: books finished and pages read, month by month, as two lines
-- ════════════════════════════════════════════════════════════════════════════

P.year_chart = {
    does = "lists a month's books",
    title = "Books and pages", tone = "ink", ratio = 0.4, ratio_narrow = 0.62,
    summary = "Books finished and pages read each month this year, as two lines. Tap a month for its books.",
}

local MONTH_LETTERS = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }

-- A step for an axis with four divisions that reaches `top`: 1, 2, 2.5 or 5
-- times a power of ten.
local function niceStep(top)
    if not (top and top > 0) then return 1 end
    local raw = top / 4
    local mag = 10 ^ floor(math.log10(raw))
    for _, k in ipairs{ 1, 2, 2.5, 5, 10 } do
        if k * mag >= raw then return k * mag end
    end
    return 10 * mag
end

-- Points along a smooth curve through (xs[i], ys[i]) that never swings past
-- its neighbouring values (monotone cubic, Fritsch-Carlson), so a month with
-- nothing in it stays on the axis instead of dipping below it.
local function smoothPoints(xs, ys, steps)
    local n = #xs
    local out = {}
    if n == 0 then return out end
    if n == 1 then return { xs[1], ys[1], xs[1], ys[1] } end
    local d, m = {}, {}
    for i = 1, n - 1 do d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) end
    m[1], m[n] = d[1], d[n - 1]
    for i = 2, n - 1 do
        if d[i - 1] * d[i] <= 0 then m[i] = 0 else m[i] = (d[i - 1] + d[i]) / 2 end
    end
    for i = 1, n - 1 do
        if d[i] == 0 then
            m[i], m[i + 1] = 0, 0
        else
            local a, b = m[i] / d[i], m[i + 1] / d[i]
            local q = a * a + b * b
            if q > 9 then
                local t = 3 / math.sqrt(q)
                m[i], m[i + 1] = t * a * d[i], t * b * d[i]
            end
        end
    end
    for i = 1, n - 1 do
        local x0, x1, y0, y1 = xs[i], xs[i + 1], ys[i], ys[i + 1]
        local hx = x1 - x0
        for k = (i == 1) and 0 or 1, steps do
            local t = k / steps
            local t2, t3 = t * t, t * t * t
            local y = (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * hx * m[i]
                + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * hx * m[i + 1]
            out[#out + 1] = x0 + t * hx
            out[#out + 1] = y
        end
    end
    return out
end

local SAMPLE_BOOKS = { 0, 0, 0, 0, 2, 5, 9, 5, 10, 3, 0, 0 }
local SAMPLE_PAGES = { 0, 0, 0, 0, 820, 2340, 3760, 3300, 3180, 1420, 0, 0 }

function P.year_chart.build(env)
    local w, h, tone = env.w, env.h, env.tone
    -- sized like the other cards: by width, unless the card is short
    local s = min(w / 900, h / 330)
    if w < 760 then s = min(w / 600, h / 380) end
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local cols = tone.series
    local Screen = A.screen()
    if not (Screen.isColorEnabled and Screen:isColorEnabled()) then
        -- in greys the two accents look alike: ink for books, a light grey for pages
        cols = { tone.fg, A.mix(tone.bg, tone.fg, 0.45) }
    end
    local now = os.date("*t")
    local cur = now.month
    local mode = env.cfg("pages", "read")

    -- the figures, month by month
    local books, pages = {}, {}
    local have_pages = true
    if env.sample then
        for m = 1, 12 do books[m], pages[m] = SAMPLE_BOOKS[m], SAMPLE_PAGES[m] end
        cur = 10
    else
        local yr = D.year(env.refresh)
        for m = 1, 12 do
            local list = yr and yr.months and yr.months[m] or {}
            books[m] = #list
            local p = 0
            for _, it in ipairs(list) do p = p + (tonumber(it.pages) or 0) end
            pages[m] = p
        end
        if mode == "read" then
            local st = statsFor(env)
            if st and st.month_pages then
                for m = 1, 12 do pages[m] = st.month_pages[m] or 0 end
            else
                have_pages = false
            end
        end
    end
    local total_b, total_p, max_b, max_p = 0, 0, 0, 0
    for m = 1, cur do
        total_b, total_p = total_b + books[m], total_p + pages[m]
        max_b, max_p = max(max_b, books[m]), max(max_p, pages[m])
    end

    local pad = px(28)
    -- header: what it is on the left, the year's totals as a legend on the right
    local t_head = c:label("Books and pages", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
    local dot_r = max(3, px(7))
    local function legend(parts)
        local items, width = {}, 0
        for _, part in ipairs(parts) do
            local t = c:text(part[1], fpx(21), { bold = true, color = tone.fg })
            items[#items + 1] = { t = t, col = part[2] }
            width = width + 2 * dot_r + px(8) + t.w
        end
        return items, width + px(18) * (#items - 1)
    end
    local parts = { { A.plural(total_b, "book", "books"), cols[1] } }
    if have_pages then parts[2] = { A.thousands(total_p) .. " pages", cols[2] } end
    local items, lw_total = legend(parts)
    if pad + t_head.w + px(24) + lw_total > w - pad then
        -- too long beside the title: numbers only
        parts = { { tostring(total_b), cols[1] } }
        if have_pages then parts[2] = { A.thousands(total_p), cols[2] } end
        items, lw_total = legend(parts)
    end
    if pad + t_head.w + px(24) + lw_total <= w - pad then
        local x = w - pad - lw_total
        local base = px(22) + t_head.base
        for _, it in ipairs(items) do
            c:disc(x + dot_r, base - it.t.base * 0.36, dot_r, it.col)
            x = x + 2 * dot_r + px(8)
            c:put(it.t, x, base, "l", "base")
            x = x + it.t.w + px(18)
        end
    end

    -- the axes: four divisions, both scales on the same grid lines
    local step_b = max(1, ceil(max_b / 4))
    local top_b = 4 * step_b
    local step_p = niceStep(max(max_p, 400))
    local top_p = 4 * step_p
    local f_axis = fpx(18)
    local left, right = {}, {}
    local wl, wr = 0, 0
    for i = 0, 4 do
        left[i] = c:text(tostring(i * step_b), f_axis, { bold = true, color = tone.label })
        wl = max(wl, left[i].w)
        if have_pages then
            local v = i * step_p
            local label = v >= 10000 and (A.thousands(v / 1000) .. "k") or A.thousands(v)
            right[i] = c:text(label, f_axis, { bold = true, color = tone.label })
            wr = max(wr, right[i].w)
        end
    end
    local t_m = c:text("M", fpx(19), { bold = true })
    local plot_top = px(22) + t_head.h + px(18) + floor(left[0].h / 2)
    local plot_bottom = h - px(16) - t_m.h - px(8)
    local x0 = pad + wl + px(12)
    local x1 = w - pad - (have_pages and (wr + px(12)) or px(6))
    if plot_bottom - plot_top < px(30) or x1 - x0 < 12 * 6 then return c end
    local ph = plot_bottom - plot_top
    local grid_w = max(1, px(2))
    for i = 0, 4 do
        local y = plot_bottom - ph * i / 4
        c:rect(x0, floor(y + 0.5) - floor(grid_w / 2), x1 - x0, grid_w, i == 0 and A.mix(tone.track, tone.fg, 0.35) or tone.track)
        c:put(left[i], x0 - px(12), y, "r", "mid")
        if right[i] then c:put(right[i], x1 + px(12), y, "l", "mid") end
    end

    -- months along the bottom: short names when they fit, else initials
    local xs = {}
    for m = 1, 12 do xs[m] = x0 + (x1 - x0) * (m - 1) / 11 end
    local col_w = (x1 - x0) / 11
    local names, widest = {}, 0
    for m = 1, 12 do
        names[m] = A.date("%b", os.time{ year = now.year, month = m, day = 1, hour = 12 })
        local t = c:text(names[m], fpx(19), { bold = true })
        widest = max(widest, t.w)
    end
    if widest > col_w * 0.92 then names = MONTH_LETTERS end
    for m = 1, 12 do
        local is_cur = (m == cur)
        c:label(names[m], fpx(19), xs[m], plot_bottom + px(8),
            { anchor = "c", bold = true, color = is_cur and tone.fg or tone.label })
        -- tapping a month lists the books finished in it
        local rx = (m == 1) and x0 - col_w / 2 or xs[m] - col_w / 2
        c:region("month:" .. m, rx, plot_top, col_w, plot_bottom - plot_top + px(8) + t_m.h)
    end

    -- the two lines, up to this month; pages underneath, books on top
    local lw = max(2, round(4.5 * s))
    local dot = max(2.5, 6 * s)
    local function series(values, top, colour)
        local ys = {}
        local xs_c = {}
        for m = 1, cur do
            xs_c[m] = xs[m]
            ys[m] = plot_bottom - ph * min(1, values[m] / top)
        end
        c:polyline(smoothPoints(xs_c, ys, 16), lw, colour)
        return xs_c, ys
    end
    local pxs, pys
    if have_pages then pxs, pys = series(pages, top_p, cols[2]) end
    local bxs, bys = series(books, top_b, cols[1])
    if pxs then for m = 1, cur do c:disc(pxs[m], pys[m], dot, cols[2]) end end
    for m = 1, cur do c:disc(bxs[m], bys[m], dot, cols[1]) end
    return c
end

function P.year_chart.tap(env, region)
    local m = region and tonumber(region:match("^month:(%d+)$"))
    if not m then return end
    return A.listFinished(env, tonumber(os.date("%Y")), m)
end

-- A dialog listing the books finished in month m of year y; tap one for its details.
function A.listFinished(env, y, m)
    local list = D.finishedIn(nil, y, m) or {}
    local month_name = A.monthTitle(y, m)
    local S = A.S
    S.open(env.ctx, "Finished in " .. month_name, function(api)
        local rows = {}
        if #list == 0 then rows[1] = S.header("No books finished in " .. month_name) end
        for _, it in ipairs(list) do
            local label = A.safe(it.title or it.fp:match("([^/]+)$") or "?")
            if it.author and it.author ~= "" then label = label .. "  \xC2\xB7  " .. A.safe(it.author) end
            rows[#rows + 1] = { { text = label, callback = function()
                api.close()
                D.showDetails(env.ctx, it.fp)
            end } }
        end
        return rows
    end)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Bar charts: time read month by month, pages read day by day
-- ════════════════════════════════════════════════════════════════════════════

-- "142 h" for a big total, "4 h 12 m" for a small one
local function hoursText(secs)
    secs = tonumber(secs) or 0
    if secs >= 10 * 3600 then return A.thousands(floor(secs / 3600 + 0.5)) .. " h" end
    return A.fmtMinutes(secs / 60)
end

-- 2.5 -> "2.5", 3 -> "3"
local function figure(v)
    if v == floor(v) then return A.thousands(v) end
    return string.format("%.1f", v)
end

-- A dashed line from x0 to x1 at y.
local function dashed(c, x0, x1, y, lw, dash, gap, rgb)
    local x = x0
    while x < x1 do
        c:rect(x, y - floor(lw / 2), min(dash, x1 - x), lw, rgb)
        x = x + dash + gap
    end
end

-- A bar chart in the box (o.x, o.y, o.w, o.h) of canvas c: the value axis on
-- the left with four grid lines, one bar per slot, labels under the bars.
--   o.n          number of slots
--   o.values[i]  the figure, or nil for a slot still to come (no bar)
--   o.labels[i]  text under slot i, or nil
--   o.current    the slot drawn in the first accent (this month, today)
--   o.fmt(v)     an axis figure
--   o.floor_top  the axis reaches at least this
--   o.average    optional: a dashed line at this value
--   o.avg_label  what to call it on the chart ("average 42")
--   o.mark       optional: text over the current bar
--   o.region     optional: a tap region per slot, named o.region .. i
local function barChart(c, tone, s, ts, o)
    local px, fpx = scaler(s, ts)
    local n = o.n
    local top_v = o.floor_top or 1
    for i = 1, n do
        local v = o.values[i]
        if v then top_v = max(top_v, v) end
    end
    local step = niceStep(top_v)
    local top = 4 * step
    local f_axis = fpx(18)
    local ylab, wl = {}, 0
    for i = 0, 4 do
        ylab[i] = c:text(o.fmt(i * step), f_axis, { bold = true, color = tone.label })
        wl = max(wl, ylab[i].w)
    end
    local t_x = c:text("0", fpx(19), { bold = true })
    local plot_top = o.y + floor(ylab[4].h / 2)
    local plot_bottom = o.y + o.h - t_x.h - px(8)
    local x0 = o.x + wl + px(12)
    local x1 = o.x + o.w
    if plot_bottom - plot_top < px(24) or x1 - x0 < n * 3 then return end
    local ph = plot_bottom - plot_top
    local grid_w = max(1, px(2))
    for i = 0, 4 do
        local gy = floor(plot_bottom - ph * i / 4 + 0.5)
        c:rect(x0, gy - floor(grid_w / 2), x1 - x0, grid_w, i == 0 and A.mix(tone.track, tone.fg, 0.35) or tone.track)
        c:put(ylab[i], x0 - px(12), gy, "r", "mid")
    end
    local col_w = (x1 - x0) / n
    local bar_w = max(2, floor(col_w * (o.bar_k or 0.6)))
    local radius = min(floor(bar_w / 2), px(6))
    local base = floor(plot_bottom + 0.5) - floor(grid_w / 2)
    local stub = max(2, px(4))
    for i = 1, n do
        local cx = x0 + (i - 0.5) * col_w
        local bx = floor(cx - bar_w / 2)
        local v = o.values[i]
        local is_cur = (i == o.current)
        if v then
            local bh = (v > 0) and max(stub, round(ph * min(1, v / top))) or 0
            if bh > 0 then
                local col = is_cur and tone.accent or tone.accent2
                -- rounded on top, square where it stands on the axis
                local r = min(radius, floor(bh / 2))
                c:rrect(bx, base - bh, bar_w, bh, r, col, tone.bg)
                if bh > r and r > 0 then c:rect(bx, base - r, bar_w, r, col) end
                if is_cur and o.mark then
                    -- Just over the bar. The figure is wider than a bar, so it
                    -- is slid sideways (centred, or starting at the bar's left
                    -- or right edge) to whichever position clears the bars it
                    -- spans lowest: usually towards the empty months still to
                    -- come, rather than lifting it over a taller neighbour.
                    local t_m = c:text(o.mark, fpx(19), { bold = true, color = tone.accent })
                    local function reachAt(mx)
                        local reach = base - bh
                        for j = 1, n do
                            local jx = x0 + (j - 0.5) * col_w
                            local vj = o.values[j]
                            if j ~= i and vj and vj > 0 and jx + bar_w / 2 >= mx - px(4) and jx - bar_w / 2 <= mx + t_m.w + px(4) then
                                reach = min(reach, base - max(stub, round(ph * min(1, vj / top))))
                            end
                        end
                        return reach
                    end
                    local best_x, best_reach
                    for _, mx in ipairs{ cx - t_m.w / 2, bx, bx + bar_w - t_m.w } do
                        mx = A.clamp(mx, x0, x1 - t_m.w)
                        local rr = reachAt(mx)
                        if not best_reach or rr > best_reach + 1 then best_x, best_reach = mx, rr end
                    end
                    local my = best_reach - px(6) - t_m.h
                    if my >= o.y - px(4) then c:put(t_m, best_x, my) end
                end
            end
        end
        local lab = o.labels[i]
        if lab then
            c:label(lab, fpx(19), cx, plot_bottom + px(8),
                { anchor = "c", bold = true, color = is_cur and tone.fg or tone.label })
        end
        if o.region then c:region(o.region .. i, cx - col_w / 2, plot_top, col_w, o.y + o.h - plot_top) end
    end
    if o.average and o.average > 0 then
        local ay = floor(plot_bottom - ph * min(1, o.average / top) + 0.5)
        local lw = max(2, px(3))
        dashed(c, x0, x1, ay, lw, px(10), px(7), tone.fg)
        if o.avg_label then
            -- named at its right-hand end, on a patch of card so bars and grid
            -- lines do not run through the words; below the line near the top
            local t = c:text(o.avg_label, fpx(19), { bold = true, color = tone.fg })
            local ty = ay - lw - px(4) - t.h
            if ty < o.y then ty = ay + lw + px(4) end
            local tx = x1 - t.w
            c:rect(tx - px(8), ty, t.w + px(8), t.h, tone.bg)
            c:put(t, tx, ty)
        end
    end
end

-- The figures a card header shows on the right: bold text, with optional
-- muted text before it, right-aligned at x and sitting on baseline y.
-- Returns false (and draws nothing) when it would run into `left_edge`.
local function headerRight(c, tone, fpx, parts, x, y, left_edge)
    local items, width = {}, 0
    for i, p in ipairs(parts) do
        local t = c:text(p[1], fpx(21), { bold = true, color = p[2] == "muted" and tone.muted or tone.fg })
        items[i] = { t = t, dash = p.dash }
        width = width + t.w + (p.dash and (fpx(21) * 1.6) or 0) + (i > 1 and fpx(10) or 0)
    end
    if x - width < left_edge then return false end
    local cx = x - width
    for i, it in ipairs(items) do
        if i > 1 then cx = cx + fpx(10) end
        if it.dash then
            local dw = floor(fpx(21) * 1.6)
            dashed(c, cx, cx + dw - fpx(6), floor(y - it.t.base * 0.36), max(2, round(fpx(21) / 7)),
                max(3, floor(dw / 4)), max(2, floor(dw / 7)), tone.fg)
            cx = cx + dw
        end
        c:put(it.t, cx, y, "l", "base")
        cx = cx + it.t.w
    end
    return true
end

-- ─── Time read, month by month ──────────────────────────────────────────────

P.year_time = {
    does = "lists a month's books",
    title = "Time read by month", tone = "ink", ratio = 0.62, ratio_narrow = 0.75,
    summary = "Hours read each month this year, as bars. Tap a month for its books. Needs the statistics plugin.",
}

local SAMPLE_MONTH_SECS = { 0, 0, 0, 0, 30600, 52200, 77400, 64800, 61200, 23400, 0, 0 }

function P.year_time.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 400)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local now = os.date("*t")
    local cur, secs = now.month, {}
    if env.sample then
        cur = 10
        for m = 1, 12 do secs[m] = SAMPLE_MONTH_SECS[m] end
    else
        local st = statsFor(env)
        if st == false then
            return emptyState(env, c, s, "Time read", "No reading statistics",
                "Turn on KOReader's Reading statistics plugin.")
        end
        for m = 1, 12 do secs[m] = st and st.month_secs and st.month_secs[m] or 0 end
    end
    local pad = px(28)
    local t_head = c:label("Time read", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
    local total = 0
    for m = 1, cur do total = total + secs[m] end
    local base = px(22) + t_head.base
    if not headerRight(c, tone, fpx, { { tostring(now.year), "muted" }, { hoursText(total) } }, w - pad, base, pad + t_head.w + px(16)) then
        headerRight(c, tone, fpx, { { hoursText(total) } }, w - pad, base, pad + t_head.w + px(16))
    end

    -- hours on the axis; months under the bars, short names when they fit
    local values, labels = {}, {}
    for m = 1, 12 do values[m] = (m <= cur) and secs[m] / 3600 or nil end
    local col_w = (w - 2 * pad) / 12 * 0.86
    local widest = 0
    for m = 1, 12 do
        labels[m] = shortMonth(m)
        widest = max(widest, c:text(labels[m], fpx(19), { bold = true }).w)
    end
    if widest > col_w * 0.92 then
        for m = 1, 12 do labels[m] = MONTH_LETTERS[m] end
    end
    local top = px(22) + t_head.h + px(22)
    barChart(c, tone, s, env.ts, {
        x = pad, y = top, w = w - 2 * pad, h = h - top - px(18),
        n = 12, values = values, labels = labels, current = cur, bar_k = 0.62,
        floor_top = 4, fmt = function(v) return figure(v) .. " h" end,
        mark = secs[cur] > 0 and hoursText(secs[cur]) or nil, region = "month:",
    })
    return c
end

function P.year_time.tap(env, region) return P.year_chart.tap(env, region) end

-- ─── Pages (or time) read each day this month ───────────────────────────────

P.month_chart = {
    does = "opens the reading calendar",
    title = "Pages per day", tone = "ink", ratio = 0.4, ratio_narrow = 0.62,
    summary = "Pages (or time) read each day this month, as bars, with your daily average. Needs the statistics plugin.",
}

function P.month_chart.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 900, h / 330)
    if w < 760 then s = min(w / 600, h / 380) end
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local by_time = env.cfg("metric", "pages") == "time"
    local now = os.date("*t")
    local year, month, current = A.viewMonth()
    if env.sample then year, month, current = now.year, now.month, true end
    local n_days = tonumber(os.date("%d", os.time{ year = year, month = month + 1, day = 0, hour = 12 })) or 30
    -- a past month has all its days behind it
    local today = current and now.day or n_days
    local st = statsFor(env)
    if st == false then
        return emptyState(env, c, s, by_time and "Time per day" or "Pages per day", "No reading statistics",
            "Turn on KOReader's Reading statistics plugin.")
    end
    local values, total = {}, 0
    for d = 1, n_days do
        if d <= today then
            local rec
            if env.sample then
                local v = (d * 37) % 11
                rec = { pages = v * 9, secs = v * 520 }
            else
                rec = st and st.days and st.days[string.format("%04d-%02d-%02d", year, month, d)] or {}
            end
            local v = by_time and (rec.secs or 0) / 60 or (rec.pages or 0)
            values[d] = v
            total = total + v
        end
    end
    local avg = total / max(1, today)

    local pad = px(28)
    local t_head = c:label(by_time and "Time per day" or "Pages per day", fpx(22), pad, px(22),
        { bold = true, caps = true, color = tone.accent })
    local base = px(22) + t_head.base
    local tot_txt = by_time and A.fmtMinutes(total) or A.plural(floor(total + 0.5), "page", "pages")
    local avg_txt = "average " .. (by_time and A.fmtMinutes(avg) or A.thousands(avg))
    local left_edge = pad + t_head.w + px(20)
    if st then
        if not headerRight(c, tone, fpx, { { A.monthTitle(year, month), "muted" }, { tot_txt } }, w - pad, base, left_edge) then
            headerRight(c, tone, fpx, { { tot_txt } }, w - pad, base, left_edge)
        end
    end

    -- day numbers: the 1st, every fifth day, and today
    local labels = {}
    for d = 1, n_days do
        if d == 1 or d % 5 == 0 then labels[d] = tostring(d) end
    end
    if current then
        for d = today - 2, today + 2 do
            if d ~= today and d >= 1 and d <= n_days then labels[d] = nil end
        end
        labels[today] = tostring(today)
    end
    local top = px(22) + t_head.h + px(18)
    barChart(c, tone, s, env.ts, {
        x = pad, y = top, w = w - 2 * pad, h = h - top - px(16),
        n = n_days, values = values, labels = labels, current = current and today or nil, bar_k = 0.58,
        floor_top = by_time and 60 or 20, average = st and avg > 0 and avg or nil, avg_label = avg_txt,
        fmt = by_time and function(v)
            if v >= 60 and v % 60 == 0 then return figure(v / 60) .. " h" end
            return figure(v) .. " m"
        end or figure,
    })
    return c
end

function P.month_chart.tap(env)
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Month totals: books finished, time spent reading, pages read this month
-- ════════════════════════════════════════════════════════════════════════════

P.month_totals = {
    does = "lists this month's books",
    title = "Month totals", tone = "ink", ratio = 0.82, ratio_narrow = 0.9,
    summary = "Books finished, time spent reading and pages read this month. Needs the statistics plugin.",
}

function P.month_totals.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local wide = w / h > 1.7
    -- sized like Month rings, its usual neighbour, so the two headers match
    local s = wide and min(w / 900, h / 300) or min(w / 546, h / 450)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    local now = os.date("*t")
    local year, month, current = A.viewMonth()
    if env.sample then year, month, current = now.year, now.month, true end
    local n_days = tonumber(os.date("%d", os.time{ year = year, month = month + 1, day = 0, hour = 12 })) or 30
    local books, secs, pages
    if env.sample then
        books, secs, pages = 3, 45600, 1234
    else
        local st = statsFor(env)
        local list = D.finishedIn(env.refresh, year, month)
        books = list and #list or nil
        if st then
            local ms = D.monthStats(st, year, month)
            secs, pages = ms.secs, ms.pages
        end
        if st == false then secs, pages = false, false end
    end
    local pad = px(30)
    local month_name = A.monthTitle(year, month)
    local t_head = c:label(month_name, fpx(22), pad, px(24), { bold = true, caps = true, color = tone.accent })
    -- (on the Dashboard the page heading already says which day it is)
    local t_day = c:text(current and ("day " .. now.day .. " of " .. n_days) or A.plural(n_days, "day", "days"),
        fpx(21), { bold = true, color = tone.muted })
    if not env.nested and pad + t_head.w + px(16) + t_day.w <= w - pad then
        c:put(t_day, w - pad, px(24) + t_head.base, "r", "base")
    end
    local dots = "\xE2\x80\xA6"
    local stats_off = "turn on Reading statistics"
    local blocks = {
        { value = books and tostring(books) or dots, label = (books == 1) and "book finished" or "books finished",
          col = tone.fg, region = "books" },
        { value = secs == false and "\xE2\x80\x94" or (secs and A.fmtMinutes(secs / 60) or dots),
          label = secs == false and stats_off or "spent reading", col = tone.accent2 },
        { value = pages == false and "\xE2\x80\x94" or (pages and A.thousands(pages) or dots),
          label = pages == false and stats_off or ((pages == 1) and "page read" or "pages read"), col = tone.accent },
    }
    local top = px(24) + t_head.h + px(14)
    local bottom = h - px(22)
    local stripe = max(3, px(8))
    if wide then
        -- three columns
        local cw = (w - 2 * pad) / 3
        for i, b in ipairs(blocks) do
            local x = pad + (i - 1) * cw
            local inner = cw - px(24)
            local t_l = c:text(b.label, fpx(22), { bold = true, color = tone.muted, max_w = inner })
            local size = min(fpx(64), floor((bottom - top - t_l.h) * 0.9))
            local t_v = c:text(b.value, size, { bold = true, color = tone.fg })
            if t_v.w > inner then t_v = c:text(b.value, max(minFont(), floor(size * inner / t_v.w)), { bold = true, color = tone.fg }) end
            local y = top + floor((bottom - top - t_v.h - t_l.h) / 2)
            c:rrect(x, y + px(6), stripe, t_v.h + t_l.h - px(12), stripe / 2, b.col, tone.bg)
            c:put(t_v, x + stripe + px(16), y)
            c:put(t_l, x + stripe + px(16), y + t_v.h - px(4))
            if b.region then c:region(b.region, x, top, cw, bottom - top) end
        end
        return c
    end
    -- three rows, divided by thin lines
    local rh = (bottom - top) / 3
    local inner = w - 2 * pad - stripe - px(20)
    for i, b in ipairs(blocks) do
        local y0 = top + (i - 1) * rh
        if i > 1 then c:rect(pad, floor(y0), w - 2 * pad, max(1, px(2)), tone.track) end
        local t_l = c:text(b.label, fpx(23), { bold = true, color = tone.muted, max_w = inner })
        local size = min(fpx(70), floor((rh - t_l.h - px(16)) * 0.95))
        local t_v = c:text(b.value, size, { bold = true, color = tone.fg })
        if t_v.w > inner then t_v = c:text(b.value, max(minFont(), floor(size * inner / t_v.w)), { bold = true, color = tone.fg }) end
        local tight = round(t_v.h * 0.1)
        local block_h = t_v.h + t_l.h - tight
        local y = floor(y0 + (rh - block_h) / 2)
        c:rrect(pad, y + round(t_v.h * 0.16), stripe, block_h - round(t_v.h * 0.22), stripe / 2, b.col, tone.bg)
        c:put(t_v, pad + stripe + px(20), y)
        c:put(t_l, pad + stripe + px(20), y + t_v.h - tight)
        if b.region then c:region(b.region, pad, floor(y0), w - 2 * pad, floor(rh)) end
    end
    return c
end

function P.month_totals.tap(env, region)
    if region == "books" then
        local y, m = A.viewMonth()
        return A.listFinished(env, y, m)
    end
    D.dispatch(env.cfg("tap", "stats_calendar_view"))
end

-- ════════════════════════════════════════════════════════════════════════════
-- When you read: the hours of the day the reading happened
-- ════════════════════════════════════════════════════════════════════════════

P.when_read = {
    does = "nothing",
    title = "When you read", tone = "ink", ratio = 0.62, ratio_narrow = 0.75,
    summary = "Which hours of the day you read in, over the month the Monthly page shows. Needs the statistics plugin.",
}

-- the four parts of the day, by starting hour
local DAY_PARTS = {
    { name = "Morning",   many = "Mornings",   from = 5,  to = 11 },
    { name = "Afternoon", many = "Afternoons", from = 12, to = 16 },
    { name = "Evening",   many = "Evenings",   from = 17, to = 20 },
    { name = "Night",     many = "Nights",     from = 21, to = 28 }, -- through 4 am
}
local function partOf(hr)
    for i, p in ipairs(DAY_PARTS) do
        if (hr >= p.from and hr <= p.to) or (hr + 24 >= p.from and hr + 24 <= p.to) then return i end
    end
    return 4
end

local function hourName(hr, short)
    local twelve = G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock")
    if not twelve then return short and tostring(hr) or string.format("%02d:00", hr) end
    local h12 = hr % 12 == 0 and 12 or hr % 12
    if short then return h12 .. (hr < 12 and "a" or "p") end
    return h12 .. (hr < 12 and " am" or " pm")
end

local SAMPLE_HOURS = { [7] = 900, [8] = 1500, [12] = 1200, [13] = 600, [17] = 600, [18] = 1800, [19] = 2400,
    [20] = 3600, [21] = 4800, [22] = 4200, [23] = 1800, [0] = 600 }

function P.when_read.build(env)
    local w, h, tone = env.w, env.h, env.tone
    local s = min(w / 546, h / 400)
    local px, fpx = scaler(s, env.ts)
    local c = card(env, s)
    -- always the month the Monthly page shows (its arrows change it)
    local vy, vm = A.viewMonth()
    local hours = {}
    if env.sample then
        for hr = 0, 23 do hours[hr] = SAMPLE_HOURS[hr] or 0 end
    else
        local st = statsFor(env)
        if st == false then
            return emptyState(env, c, s, "When you read", "No reading statistics",
                "Turn on KOReader's Reading statistics plugin.")
        end
        local src = st and D.monthStats(st, vy, vm).hours
        for hr = 0, 23 do hours[hr] = src and src[hr] or 0 end
    end
    local pad = px(28)
    local t_head = c:label("When you read", fpx(22), pad, px(22), { bold = true, caps = true, color = tone.accent })
    local span = A.monthTitle(vy, vm)
    local t_span = c:text(span, fpx(21), { bold = true, color = tone.muted })
    if pad + t_head.w + px(16) + t_span.w <= w - pad then
        c:put(t_span, w - pad, px(22) + t_head.base, "r", "base")
    end

    local total, parts, peak_hr = 0, { 0, 0, 0, 0 }, 0
    for hr = 0, 23 do
        total = total + hours[hr]
        local p = partOf(hr)
        parts[p] = parts[p] + hours[hr]
        if hours[hr] > hours[peak_hr] then peak_hr = hr end
    end
    local top = px(22) + t_head.h + px(16)
    if total <= 0 then
        local msg = "No reading in " .. span
        c:label(msg, fpx(24), w / 2, top + (h - top) / 2, { anchor = "c", valign = "mid", color = tone.muted, max_w = w - 2 * pad })
        return c
    end
    local peak_part = 1
    for i = 2, 4 do if parts[i] > parts[peak_part] then peak_part = i end end
    local share = floor(100 * parts[peak_part] / total + 0.5)

    -- the headline: "Evenings", "41% of your reading · most at 9 pm"
    local t_big = c:text(DAY_PARTS[peak_part].many, fpx(40), { bold = true, color = tone.fg, max_w = w - 2 * pad })
    local sub = share .. "% of your reading  \xC2\xB7  most at " .. hourName(peak_hr)
    local t_sub = c:text(sub, fpx(21), { bold = true, color = tone.muted })
    if t_sub.w > w - 2 * pad then
        t_sub = c:text(share .. "% of your reading", fpx(21), { bold = true, color = tone.muted, max_w = w - 2 * pad })
    end
    local tight = round(t_big.h * 0.12)
    c:put(t_big, pad - round(t_big.px * 0.03), top - tight)
    local y = top - tight + t_big.h - tight
    c:put(t_sub, pad, y)
    y = y + t_sub.h + px(10)

    -- the four parts along the bottom, when there is room for them
    local t_pn = c:text("Ag", fpx(19), { bold = true })
    local t_pv = c:text("0%", fpx(24), { bold = true })
    local parts_h = t_pn.h + t_pv.h
    local bottom = h - px(20)
    -- (only when every name fits its quarter of the width)
    local widest_part = c:text("Afternoon", fpx(19), { bold = true }).w
    local show_parts = (bottom - y) - parts_h - px(14) >= px(70) and widest_part <= (w - 2 * pad) / 4 - px(6)
    local hist_bottom = show_parts and (bottom - parts_h - px(14)) or bottom

    -- 24 bars, one per hour; the busiest part of the day in the first accent
    local t_hl = c:text("12a", fpx(18), { bold = true })
    local plot_bottom = hist_bottom - t_hl.h - px(6)
    local ph = plot_bottom - y
    if ph >= px(20) then
        local col_w = (w - 2 * pad) / 24
        local bar_w = max(2, floor(col_w * 0.66))
        local radius = min(floor(bar_w / 2), px(4))
        local top_v = 0
        for hr = 0, 23 do top_v = max(top_v, hours[hr]) end
        c:rect(pad, plot_bottom, w - 2 * pad, max(1, px(2)), A.mix(tone.track, tone.fg, 0.35))
        for hr = 0, 23 do
            local cx = pad + (hr + 0.5) * col_w
            local v = hours[hr]
            if v > 0 then
                local bh = max(max(2, px(4)), round(ph * v / top_v))
                local col = partOf(hr) == peak_part and tone.accent or tone.accent2
                local bx = floor(cx - bar_w / 2)
                local r = min(radius, floor(bh / 2))
                c:rrect(bx, plot_bottom - bh, bar_w, bh, r, col, tone.bg)
                if bh > r and r > 0 then c:rect(bx, plot_bottom - r, bar_w, r, col) end
            end
            if hr % 6 == 0 then
                c:label(hourName(hr, true), fpx(18), pad + hr * col_w, plot_bottom + px(6),
                    { bold = true, color = tone.label })
            end
        end
    end
    if show_parts then
        local cw = (w - 2 * pad) / 4
        local py = bottom - parts_h
        for i, p in ipairs(DAY_PARTS) do
            local x = pad + (i - 1) * cw
            local pct = floor(100 * parts[i] / total + 0.5)
            c:label(p.name, fpx(19), x, py, { bold = true, color = tone.label, max_w = cw - px(6) })
            c:label(pct .. "%", fpx(24), x, py + t_pn.h,
                { bold = true, color = i == peak_part and tone.accent or tone.fg })
        end
    end
    return c
end

-- ════════════════════════════════════════════════════════════════════════════
-- Page heading (dashboard only): small line over a big title, no card
-- ════════════════════════════════════════════════════════════════════════════

-- nav (optional): { prev = bool, next = bool, today = bool } puts big month
-- buttons on the right: a Today button (only when away from this month) and
-- two arrow buttons, with tap regions now / prev / next. A button that has
-- nowhere to go is drawn faded.
function P.heading(env, kicker, title, nav)
    local w, h = env.w, env.h
    local bg, fg, dark, accent = A.dashPage()
    local c = A.canvas{ w = w, h = h, plain = true }
    local s = h / 150
    local px, fpx = scaler(s, env.ts)
    local room = w
    local btn = {}
    if nav then
        -- as big as the heading allows: thumb-sized on a Kobo
        local bs = max(32, floor(min(h * 0.8, w * 0.11)))
        local gap = max(8, floor(bs * 0.2))
        local x = w - bs
        btn.next = { x = x, w = bs }
        x = x - gap - bs
        btn.prev = { x = x, w = bs }
        if nav.today then
            local t_today = c:text("Today", fpx(30), { bold = true })
            local tw = t_today.w + floor(bs * 0.7)
            x = x - floor(gap * 1.6) - tw
            btn.now = { x = x, w = tw }
        end
        btn.bs = bs
        room = x - px(24)
    end
    local t_k = kicker and c:text(kicker, fpx(24), { bold = true, caps = true, color = accent, max_w = room }) or nil
    local t_t = c:text(title, fpx(74), { bold = true, color = fg, max_w = room })
    local tight = round(t_t.h * 0.14)
    local total = (t_k and t_k.h or 0) + t_t.h - tight
    local y = floor((h - total) / 2)
    if t_k then c:put(t_k, 0, y); y = y + t_k.h - tight end
    c:put(t_t, -round(t_t.px * 0.03), y)
    if nav then
        local bs = btn.bs
        local by = floor((h - bs) / 2)
        local dim = A.mix(fg, bg, 0.7)
        local bw_ = max(3, floor(bs * 0.05))
        local function arrow(b, dir, on)
            local col = on and fg or dim
            c:frame(b.x, by, b.w, bs, floor(bs * 0.28), bw_, col, bg, bg)
            -- a thick chevron, drawn rather than typed, so it is bold at any size
            local cx, cy, a = b.x + b.w / 2, by + bs / 2, bs * 0.17
            local lw = max(3, bs * 0.085)
            local pts = (dir < 0) and { cx + a * 0.55, cy - a, cx - a * 0.45, cy, cx + a * 0.55, cy + a }
                or { cx - a * 0.55, cy - a, cx + a * 0.45, cy, cx - a * 0.55, cy + a }
            c:polyline(pts, lw, col, bg)
        end
        arrow(btn.prev, -1, nav.prev)
        arrow(btn.next, 1, nav.next)
        c:region("prev", btn.prev.x, by, btn.prev.w, bs, px(12))
        c:region("next", btn.next.x, by, btn.next.w, bs, px(12))
        if btn.now then
            -- "Today": the way back, in the colour of the selected tab
            local th = A.theme()
            local fill = A.shown(dark and th.gold or th.wine)
            local on_fill = A.shown(dark and th.ink or th.paper)
            local ph = floor(bs * 0.78)
            local py = floor((h - ph) / 2)
            c:rrect(btn.now.x, py, btn.now.w, ph, ph / 2, fill, bg)
            c:label("Today", fpx(30), btn.now.x + btn.now.w / 2, py + ph / 2,
                { bold = true, anchor = "c", valign = "mid", color = on_fill })
            c:region("now", btn.now.x, by, btn.now.w, bs, px(12))
        end
    end
    return c
end

return P
