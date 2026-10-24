-- Modified by TK for Reading Log for SimpleUI, 2026 (from stevenzamora1/reading-log-simpleui).
--[[
Reading Log for Simple UI: shared code behind every Reading Log module.

This is the Reading Log card kit (the alm_* Bookshelf micro-modules) ported to
Simple UI's home screen modules. The cards are drawn exactly as before; only
the host changed. Everything that used to come from Bookshelf (where settings
are stored, the card colour, fonts, book records, goals, covers, opening a
book) now goes through host.lua, which talks to Simple UI and KOReader.

Ring designs and the idea of a tabbed reading dashboard: u/fishnoogz on
Reddit. Built for KOReader and Simple UI.

Parts, each loaded once and attached to the same table:
  init.lua      this file: store, theme, drawing, text, the Canvas widget
  host.lua      Simple UI / KOReader adapter (settings file, fonts, books,
                goals, covers, repaints, the clock tick)
  data.lua      reading stats, book lists, covers
  panels.lua    one builder per card (banner, continue reading, rings, ...)
  settings.lua  each card's options, and the dialogs (page editor, picks)
  modules.lua   turns each panel into a Simple UI module; the dashboard
  menus.lua     the options as Simple UI settings menu items

Why modules paint their own card: each card has its own colour, so it fills
its box with a rounded panel and draws on that.
]]

local A = { VERSION = "1.1.0", NAME = "Reading Log" }
A.HOST = "Simple UI"

A.dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt

-- ─── small utilities ─────────────────────────────────────────────────────────

function A.log(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger then logger.warn("[almanac]", ...) end
end

-- A line in KOReader's own log (crash.log on a Kobo), for the few events
-- worth being able to look up afterwards.
function A.note(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger then logger.info("[almanac]", ...) end
end

-- Counters shown in Look and colours > Diagnostics. Since this session started.
A.counts = { views = 0, flashes = 0, reinks = 0, narrowed = 0, clipped = 0, cleans = 0 }
function A.count(name) A.counts[name] = (A.counts[name] or 0) + 1 end

function A.round(n) return floor(n + 0.5) end
function A.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Text from book metadata or typed by the reader can carry bytes the text
-- shaper chokes on (a C-level crash no pcall catches); see host.lua.
function A.safe(s)
    if type(s) ~= "string" then s = s == nil and "" or tostring(s) end
    return A.host.safeText(s)
end

function A.upper(s)
    s = A.safe(s)
    local ok, U = pcall(require, "ffi/utf8proc")
    if ok and U and U.uppercase_dumb then
        local ok2, r = pcall(U.uppercase_dumb, s)
        if ok2 and type(r) == "string" then return r end
    end
    return s:upper()
end

function A.screen() return require("device").screen end

-- ─── settings store ──────────────────────────────────────────────────────────
-- Reading Log keeps its settings in a file of its own,
-- settings/readinglog.lua (see host.lua). On the first run, settings saved by
-- the Bookshelf version are copied in.

function A.get(key, default)
    local ok, v = pcall(A.host.get, key)
    if ok and v ~= nil then return v end
    return default
end

function A.set(key, value)
    pcall(A.host.set, key, value)
    A.epoch = (A.epoch or 0) + 1
end

A.epoch = 0

-- ─── theme ───────────────────────────────────────────────────────────────────
-- Colour e-ink (Kaleido) shows about a third of the saturation of a phone
-- screen, sixteen levels per channel, and it is dark: a deep tinted fill
-- comes out as a muddy grey, and anything flat that is not one of those
-- sixteen levels is dithered into grain. Big dark areas are also where
-- ghosting shows most. So a theme is one surface colour (white, cream or
-- true black), colour is kept for accents, and every flat colour here is a
-- multiple of 17 per channel (an exact panel level, so no grain).
--
-- A theme: surface (the card), tint (a second, slightly different card),
-- fg (ink), border, page / page_fg (what the Dashboard paints behind its
-- cards), accent (the accent it starts with).
-- The two accents are the reader's: any two of A.ACCENTS. Each has a `deep`
-- form for light surfaces and a `bright` one for dark, and names the partner
-- that is used when no second accent has been chosen.

A.ACCENTS = {
    red     = { label = "Red",     deep = { 204, 34, 51 },  bright = { 255, 102, 102 }, pair = "blue" },
    orange  = { label = "Orange",  deep = { 221, 102, 0 },  bright = { 255, 170, 51 },  pair = "teal" },
    gold    = { label = "Gold",    deep = { 170, 119, 0 },  bright = { 255, 204, 51 },  pair = "red" },
    lime    = { label = "Lime",    deep = { 102, 153, 0 },  bright = { 187, 238, 68 },  pair = "purple" },
    green   = { label = "Green",   deep = { 17, 136, 68 },  bright = { 102, 221, 119 }, pair = "orange" },
    teal    = { label = "Teal",    deep = { 0, 136, 136 },  bright = { 85, 221, 221 },  pair = "orange" },
    sky     = { label = "Sky",     deep = { 0, 136, 204 },  bright = { 102, 204, 255 }, pair = "pink" },
    blue    = { label = "Blue",    deep = { 34, 102, 204 }, bright = { 102, 170, 255 }, pair = "red" },
    purple  = { label = "Purple",  deep = { 119, 68, 187 }, bright = { 187, 153, 255 }, pair = "gold" },
    magenta = { label = "Magenta", deep = { 187, 34, 153 }, bright = { 255, 119, 221 }, pair = "teal" },
    pink    = { label = "Pink",    deep = { 204, 51, 119 }, bright = { 255, 136, 187 }, pair = "sky" },
    brown   = { label = "Brown",   deep = { 136, 85, 34 },  bright = { 221, 170, 119 }, pair = "teal" },
    -- Black (added by Reading Log for SimpleUI): black on light cards; on
    -- dark cards black wouldn't show, so it turns white there.
    black   = { label = "Black",   deep = { 0, 0, 0 },      bright = { 255, 255, 255 }, pair = "red" },
}
A.ACCENT_ORDER = { "red", "orange", "gold", "lime", "green", "teal", "sky", "blue", "purple", "magenta", "pink", "brown", "black" }

local WHITE, BLACK = { 255, 255, 255 }, { 0, 0, 0 }

A.THEMES = {
    white = { label = "White", accent = "red",
              surface = WHITE, tint = { 238, 238, 238 }, fg = BLACK, border = BLACK,
              page = WHITE, page_fg = BLACK },
    dark  = { label = "Dark", accent = "gold",
              surface = BLACK, tint = { 34, 34, 34 }, fg = WHITE, border = { 119, 119, 119 }, thin = true,
              page = BLACK, page_fg = WHITE },
    paper = { label = "Paper", accent = "orange",
              surface = { 255, 238, 204 }, tint = { 238, 221, 170 }, fg = { 34, 17, 0 }, border = { 68, 51, 34 },
              page = { 255, 238, 204 }, page_fg = { 34, 17, 0 } },
}
-- Themes from 1.9.0: softer colour families (on a black-and-white screen
-- they show as light greys).
A.THEMES.forest = { label = "Forest", accent = "green",
    surface = { 236, 243, 228 }, tint = { 218, 232, 204 }, fg = { 22, 44, 22 }, border = { 62, 96, 52 },
    page = { 236, 243, 228 }, page_fg = { 22, 44, 22 } }
A.THEMES.latte = { label = "Latte", accent = "brown",
    surface = { 247, 236, 222 }, tint = { 234, 216, 194 }, fg = { 58, 34, 18 }, border = { 122, 84, 52 },
    page = { 247, 236, 222 }, page_fg = { 58, 34, 18 } }
A.THEMES.night_sky = { label = "Night sky", accent = "sky",
    surface = { 18, 24, 40 }, tint = { 34, 42, 64 }, fg = { 232, 236, 248 }, border = { 92, 104, 140 }, thin = true,
    page = { 18, 24, 40 }, page_fg = { 232, 236, 248 } }
A.THEME_ORDER = { "white", "dark", "paper", "forest", "latte", "night_sky" }

-- How progress and charts are drawn (1.9.0).
A.PROGRESS_STYLES = { { "rings", "Rings" }, { "bars", "Bars" }, { "dots", "Dots" }, { "blocks", "Pixel blocks" },
    { "moons", "Moons" }, { "batteries", "Batteries" } }
A.CHART_STYLES = { { "bars", "Bars" }, { "line", "Line" }, { "stems", "Dots on stems" } }
local function pick(list, v, default)
    for _, o in ipairs(list) do if o[1] == v then return v end end
    return default
end
function A.progressStyle() return pick(A.PROGRESS_STYLES, A.get("progress_style", "rings"), "rings") end
function A.chartStyle() return pick(A.CHART_STYLES, A.get("chart_style", "bars"), "bars") end

-- Card looks (1.10.0): pictures instead of a card's usual chart.
A.LOOKS = {
    goal = { label = "Year goal", options = { { "number", "Number" }, { "stars", "Constellation" }, { "trail", "Critter trail" } } },
    challenge = { label = "Monthly challenge", options = { { "ring", "Ring" }, { "hourglass", "Hourglass" } } },
    week = { label = "This week", options = { { "bars", "Chart" }, { "weather", "Weather" } } },
    year_time = { label = "Time read by month", options = { { "chart", "Chart" }, { "stump", "Tree rings" } } },
    streak = { label = "Streak", options = { { "ring", "Ring" }, { "fire", "Campfire" } } },
}
A.LOOK_ORDER = { "goal", "challenge", "week", "year_time", "streak" }
-- the sets: several looks at once
A.LOOK_SETS = {
    { "night", "Night sky", { progress_style = "moons", look_goal = "stars", look_challenge = "hourglass" } },
    { "trail", "Trail", { look_goal = "trail", look_week = "weather", look_year_time = "stump", look_streak = "fire" } },
}
function A.look(card)
    local def = A.LOOKS[card]
    if not def then return nil end
    return pick(def.options, A.get("look_" .. card, def.options[1][1]), def.options[1][1])
end

A.DEFAULT_THEME = "white"
-- names from earlier versions
local THEME_ALIAS = { noir = "dark" }

-- The four card styles of every theme. Earlier versions stored "plum" and
-- "wine"; those now mean the two plain styles.
A.TONES = { "ink", "paper", "tint", "tint2" }
local TONE_LABELS = { ink = "Plain", paper = "Plain, accents swapped", tint = "Tinted", tint2 = "Tinted, accents swapped" }
local TONE_ALIAS = { plum = "ink", wine = "paper" }

function A.toneKey(name)
    name = TONE_ALIAS[name] or name
    if not TONE_LABELS[name] then name = "ink" end
    return name
end

function A.toneLabel(key) return TONE_LABELS[A.toneKey(key)] end

function A.themeId()
    local id = A.get("theme", A.DEFAULT_THEME)
    id = THEME_ALIAS[id] or id
    if not A.THEMES[id] then id = A.DEFAULT_THEME end
    return id
end

-- The two accent families in use: the reader's picks, else the theme's own
-- first accent and that accent's partner.
function A.accentIds()
    local th = A.THEMES[A.themeId()]
    local a = A.get("accent", nil)
    if not A.ACCENTS[a] then a = th.accent end
    local b = A.get("accent2", nil)
    if not A.ACCENTS[b] then b = A.ACCENTS[a].pair end
    return a, b
end

-- The current theme, with the handful of colours the Dashboard's own
-- furniture uses: gold (accent on a dark page), wine (accent on a light
-- page), ink and paper.
function A.theme()
    local th = A.THEMES[A.themeId()]
    local fam = A.ACCENTS[(A.accentIds())]
    return { label = th.label, page = th.page, page_fg = th.page_fg,
             gold = fam.bright, wine = fam.deep, ink = BLACK, paper = WHITE }
end

function A.mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

function A.luma(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end

function A.night()
    local Screen = A.screen()
    return Screen.night_mode and true or false
end

function A.inverted(c) return { 255 - c[1], 255 - c[2], 255 - c[3] } end

-- How the page will LOOK: dark when the page colour is dark, and dark when
-- night mode turns a light page over.
function A.pageLooksDark()
    local bg = A.pageColors()
    return (A.luma(bg) < 128) ~= A.night()
end

-- Colour to paint so that it LOOKS like `rgb` on a canvas that is not
-- pre-inverted (the dashboard's own tab bar and headings).
function A.shown(rgb)
    if A.night() then return A.inverted(rgb) end
    return rgb
end

-- One card style: colours worked out from a surface, its ink and the two
-- accents. `fixed` = looks the same day and night (see Canvas).
local function buildTone(name, bg, fg, border, thin)
    local dark = A.luma(bg) < 128
    local id1, id2 = A.accentIds()
    local a1 = dark and A.ACCENTS[id1].bright or A.ACCENTS[id1].deep
    local a2 = dark and A.ACCENTS[id2].bright or A.ACCENTS[id2].deep
    if name == "paper" or name == "tint2" then a1, a2 = a2, a1 end
    return {
        name = name, dark = dark, fixed = true,
        bg = bg, fg = fg, muted = A.mix(bg, fg, dark and 0.8 or 0.72),
        -- chart and calendar labels (months, days, axis figures): darker
        -- than muted, so small bold letters stay crisp on e-ink
        label = A.mix(bg, fg, dark and 0.88 or 0.82),
        accent = a1, accent2 = a2,
        track = A.mix(bg, fg, dark and 0.24 or 0.15),
        border = border, border_thin = thin,
        btn = a1, btn_fg = (A.luma(a1) > 140) and BLACK or WHITE,
        soft = A.mix(bg, fg, 0.12),
        series = { a1, a2, fg },
    }
end

-- A card style in the theme's own colours: what the Dashboard's cards use.
function A.tone(name)
    name = A.toneKey(name)
    local th = A.THEMES[A.themeId()]
    local tinted = (name == "tint" or name == "tint2")
    return buildTone(name, tinted and th.tint or th.surface, th.fg, th.border, th.thin)
end

-- A card style for a card on its own on a Simple UI screen: it takes Simple
-- UI's own background and ink and draws no frame of its own, so the card sits
-- on the page like Simple UI's own modules (its Frame and Background options
-- still apply around it). Only the accents come from the theme. Tinted styles
-- keep a soft, frameless panel. Colours are kept as they should LOOK; the
-- canvas pre-inverts them at night like every other card.
function A.nativeTone(name)
    name = A.toneKey(name)
    local bg, fg = A.pageColors()
    if A.night() then bg, fg = A.inverted(bg), A.inverted(fg) end
    local tinted = (name == "tint" or name == "tint2")
    if tinted then bg = A.mix(bg, fg, A.luma(bg) < 128 and 0.12 or 0.07) end
    local t = buildTone(name, bg, fg, nil, nil)
    t.native, t.panel = true, tinted
    return t
end

-- Whether cards on their own take Simple UI's look (the default) or the
-- theme's framed cards.
function A.standaloneNative()
    return A.get("standalone", "native") ~= "framed"
end

-- The colour of the page the panel sits on (Simple UI's background), the ink
-- Simple UI draws on it, and its muted ink. Read at render time.
function A.pageColors()
    local ok, bg, fg, muted = pcall(A.host.pageColors)
    if ok and bg then return bg, fg, muted end
    return { 0xFF, 0xFF, 0xFF }, { 0, 0, 0 }, { 0x77, 0x77, 0x77 }
end

-- What the Dashboard paints behind and between its cards, as colours to
-- PAINT (night mode already allowed for): bg, fg, whether it will look dark,
-- an accent for headings, and `look` = the page colour as it should look when
-- the theme sets one (nil when the page is Simple UI's own background).
function A.dashPage()
    local th = A.theme()
    if th.page then
        local dark = A.luma(th.page) < 128
        return A.shown(th.page), A.shown(th.page_fg), dark, A.shown(dark and th.gold or th.wine), th.page
    end
    local bg, fg = A.pageColors()
    local dark = A.pageLooksDark()
    return bg, fg, dark, A.shown(dark and th.gold or A.mix(th.gold, { 0, 0, 0 }, 0.42)), nil
end

-- ─── colours → Blitbuffer ────────────────────────────────────────────────────
-- Colours live as {r,g,b}. They become Blitbuffer colours at the last moment:
-- real colour on a colour screen, Rec.601 grey otherwise.

local _colcache, _colmode, _colcount = {}, nil, 0

function A.color(rgb, inv)
    local Blitbuffer = require("ffi/blitbuffer")
    local Screen = A.screen()
    local is_color = Screen.isColorEnabled and Screen:isColorEnabled() or false
    -- Edge blending makes many one-off shades; start over now and then.
    if _colmode ~= is_color or _colcount > 8192 then _colcache, _colmode, _colcount = {}, is_color, 0 end
    local r = A.clamp(floor(rgb[1] + 0.5), 0, 255)
    local g = A.clamp(floor(rgb[2] + 0.5), 0, 255)
    local b = A.clamp(floor(rgb[3] + 0.5), 0, 255)
    if inv then r, g, b = 255 - r, 255 - g, 255 - b end
    local key = r * 65536 + g * 256 + b
    local c = _colcache[key]
    if c then return c end
    if is_color and Blitbuffer.ColorRGB32 then
        c = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    else
        c = Blitbuffer.Color8(floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5))
    end
    _colcache[key] = c
    _colcount = _colcount + 1
    return c
end

-- paintRect flattens a colour to grey; paintRectRGB32 keeps it. Same choice
-- KOReader's own FrameContainer makes.
local function fillRect(bb, x, y, w, h, c)
    if w <= 0 or h <= 0 then return end
    local Blitbuffer = require("ffi/blitbuffer")
    if bb.paintRectRGB32 and Blitbuffer.isColor8 and not Blitbuffer.isColor8(c) then
        bb:paintRectRGB32(x, y, w, h, c)
    else
        bb:paintRect(x, y, w, h, c)
    end
end
A.fillRect = fillRect

-- One pixel, only if it is inside the bitmap. Blitbuffer's own setPixel does
-- no bounds check (rect fills and blits do), so a shape that hangs over the
-- edge of what it is painted into would otherwise write into whatever memory
-- sits beside the bitmap. bw, bh = the bitmap's size, read once per shape.
local function plot(bb, bw, bh, x, y, c)
    if x >= 0 and y >= 0 and x < bw and y < bh then
        bb:setPixel(x, y, c)
    else
        A.counts.clipped = A.counts.clipped + 1
        if A._oob then A._oob(x, y, bw, bh) end
    end
end

-- ─── drawing primitives ──────────────────────────────────────────────────────
-- All take {r,g,b} colours plus `inv` (see Canvas: night-mode compensation).
-- Edges are anti-aliased by mixing with the colour known to be underneath
-- (`under`), never by reading pixels back, so they behave the same whichever
-- way the device implements night mode.

local G = {}
A.G = G

function G.rect(bb, x, y, w, h, rgb, inv)
    fillRect(bb, floor(x), floor(y), floor(w), floor(h), A.color(rgb, inv))
end

-- Filled rounded rectangle. `under` = colour behind it, for the corner edges.
function G.rrect(bb, x, y, w, h, r, rgb, under, inv)
    x, y, w, h = floor(x), floor(y), floor(w), floor(h)
    if w <= 0 or h <= 0 then return end
    r = floor(min(r or 0, w / 2, h / 2))
    local c = A.color(rgb, inv)
    if r < 1 then fillRect(bb, x, y, w, h, c) return end
    local bw, bh = bb:getWidth(), bb:getHeight()
    fillRect(bb, x, y + r, w, h - 2 * r, c)
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = r - sqrt(max(0, r * r - dy * dy))
        local full = ceil(inset)
        local cov = full - inset
        local yt, yb = y + i, y + h - 1 - i
        local span = w - 2 * full
        if span > 0 then
            fillRect(bb, x + full, yt, span, 1, c)
            fillRect(bb, x + full, yb, span, 1, c)
        end
        if under and cov > 0.02 and full >= 1 then
            local e = A.color(A.mix(under, rgb, cov), inv)
            plot(bb, bw, bh, x + full - 1, yt, e)
            plot(bb, bw, bh, x + w - full, yt, e)
            plot(bb, bw, bh, x + full - 1, yb, e)
            plot(bb, bw, bh, x + w - full, yb, e)
        end
    end
end

-- Outlined rounded rectangle: border colour outside, fill inside.
function G.frame(bb, x, y, w, h, r, bw, border, fill, under, inv)
    G.rrect(bb, x, y, w, h, r, border, under, inv)
    G.rrect(bb, x + bw, y + bw, w - 2 * bw, h - 2 * bw, max(0, r - bw), fill, border, inv)
end

function G.disc(bb, cx, cy, r, rgb, under, inv)
    if not (r > 0 and r < 4096 and cx == cx and cy == cy) then return end
    local c = A.color(rgb, inv)
    local bw, bh = bb:getWidth(), bb:getHeight()
    local x0, x1 = floor(cx - r - 1), ceil(cx + r + 1)
    for py = floor(cy - r - 1), ceil(cy + r + 1) do
        local dy = py + 0.5 - cy
        for px = x0, x1 do
            local dx = px + 0.5 - cx
            local cov = r + 0.5 - sqrt(dx * dx + dy * dy)
            if cov >= 1 then
                plot(bb, bw, bh, px, py, c)
            elseif cov > 0 and under then
                plot(bb, bw, bh, px, py, A.color(A.mix(under, rgb, cov), inv))
            end
        end
    end
end

-- Progress ring: a full track with an arc of `frac` drawn clockwise from
-- 12 o'clock, round caps at both ends. R = outer radius, t = thickness.
-- A thick line through points { x1, y1, x2, y2, ... } (a curve is just many
-- short segments). Each pixel's coverage is its distance from the nearest
-- segment, kept in a scratch buffer as the largest over all segments, so
-- joints and overlaps come out smooth instead of doubling up at the edges.
-- Everything is clipped to the bitmap first.
function G.polyline(bb, pts, lw, rgb, under, inv)
    local n = floor(#pts / 2)
    if n < 2 or not (lw > 0 and lw < 200) then return end
    local bw, bh = bb:getWidth(), bb:getHeight()
    local r = lw / 2
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, 2 * n, 2 do
        local x, y = pts[i], pts[i + 1]
        if x ~= x or y ~= y then return end -- NaN: nothing sensible to draw
        if x < minx then minx = x end
        if x > maxx then maxx = x end
        if y < miny then miny = y end
        if y > maxy then maxy = y end
    end
    local x0, x1 = max(0, floor(minx - r - 1)), min(bw - 1, ceil(maxx + r + 1))
    local y0, y1 = max(0, floor(miny - r - 1)), min(bh - 1, ceil(maxy + r + 1))
    if x1 < x0 or y1 < y0 then return end
    local W, H = x1 - x0 + 1, y1 - y0 + 1
    if W * H > 8000000 then return end
    local ffi = require("ffi")
    local cov = ffi.new("uint8_t[?]", W * H)
    local touched, nt = {}, 0 -- every pixel given any coverage, to compose only those
    for i = 1, 2 * n - 2, 2 do
        local ax, ay, bx2, by2 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local dx, dy = bx2 - ax, by2 - ay
        local len2 = dx * dx + dy * dy
        local sx0 = max(x0, floor(min(ax, bx2) - r - 1))
        local sx1 = min(x1, ceil(max(ax, bx2) + r + 1))
        local sy0 = max(y0, floor(min(ay, by2) - r - 1))
        local sy1 = min(y1, ceil(max(ay, by2) + r + 1))
        for py = sy0, sy1 do
            local cy = py + 0.5
            local row = (py - y0) * W - x0
            for px = sx0, sx1 do
                local cx = px + 0.5
                local t = 0
                if len2 > 0 then
                    t = ((cx - ax) * dx + (cy - ay) * dy) / len2
                    if t < 0 then t = 0 elseif t > 1 then t = 1 end
                end
                local ex, ey = ax + t * dx - cx, ay + t * dy - cy
                local c = r + 0.5 - sqrt(ex * ex + ey * ey)
                if c > 0 then
                    local v = (c >= 1) and 255 or floor(c * 255)
                    local idx = row + px
                    local old = cov[idx]
                    if v > old then
                        if old == 0 then nt = nt + 1; touched[nt] = idx end
                        cov[idx] = v
                    end
                end
            end
        end
    end
    local solid = A.color(rgb, inv)
    for i = 1, nt do
        local idx = touched[i]
        local v = cov[idx]
        local py = y0 + floor(idx / W)
        local px = x0 + idx % W
        if v == 255 then
            plot(bb, bw, bh, px, py, solid)
        elseif under then
            plot(bb, bw, bh, px, py, A.color(A.mix(under, rgb, v / 255), inv))
        elseif v >= 128 then
            plot(bb, bw, bh, px, py, solid)
        end
    end
end

function G.ring(bb, cx, cy, R, t, frac, track, fill, under, inv)
    if not (R > 0 and R < 4096 and t > 0 and cx == cx and cy == cy) then return end
    frac = tonumber(frac) or 0
    if frac ~= frac then frac = 0 end
    frac = A.clamp(frac, 0, 1)
    local pi2 = 2 * math.pi
    local theta = frac * pi2
    local rm, cap = R - t / 2, t / 2
    local ex, ey = cx + rm * math.sin(theta), cy - rm * math.cos(theta)
    local sx, sy = cx, cy - rm
    local c_track, c_fill = A.color(track, inv), A.color(fill, inv)
    local bw, bh = bb:getWidth(), bb:getHeight()
    local atan2 = math.atan2
    local full = frac >= 0.999
    for py = floor(cy - R - 1), ceil(cy + R + 1) do
        local dy = py + 0.5 - cy
        local ro = (R + 1) * (R + 1) - dy * dy
        if ro > 0 then
            local half = sqrt(ro)
            local ri = (R - t - 1)
            local hole = (ri > 0 and ri * ri - dy * dy > 0) and sqrt(ri * ri - dy * dy) or 0
            for px = floor(cx - half), ceil(cx + half) do
                local dx = px + 0.5 - cx
                if dx > hole or dx < -hole or hole == 0 then
                    local d = sqrt(dx * dx + dy * dy)
                    local cov = min(R + 0.5 - d, d - (R - t) + 0.5)
                    if cov > 0 then
                        if cov > 1 then cov = 1 end
                        -- how much of this pixel belongs to the filled arc
                        local f
                        if full then
                            f = 1
                        else
                            local a = atan2(dx, -dy)
                            if a < 0 then a = a + pi2 end
                            if a <= theta then
                                f = 1
                            else
                                local d1 = cap + 0.5 - sqrt((px + 0.5 - sx) ^ 2 + (py + 0.5 - sy) ^ 2)
                                local d2 = cap + 0.5 - sqrt((px + 0.5 - ex) ^ 2 + (py + 0.5 - ey) ^ 2)
                                f = max(0, min(1, max(d1, d2)))
                            end
                        end
                        if cov >= 1 and f >= 1 then
                            plot(bb, bw, bh, px, py, c_fill)
                        elseif cov >= 1 and f <= 0 then
                            plot(bb, bw, bh, px, py, c_track)
                        else
                            local base = A.mix(track, fill, f)
                            if under and cov < 1 then base = A.mix(under, base, cov) end
                            plot(bb, bw, bh, px, py, A.color(base, inv))
                        end
                    end
                end
            end
        end
    end
end

-- Progress as dots or pixel blocks around the same circle: n marks clockwise
-- from 12 o'clock, the first frac * n in `fill`.
function G.ringDots(bb, cx, cy, R, t, frac, track, fill, under, inv, square)
    if not (R > 0 and R < 4096 and t > 0 and cx == cx and cy == cy) then return end
    frac = A.clamp(tonumber(frac) or 0, 0, 1)
    if frac ~= frac then frac = 0 end
    local rm = R - t / 2
    local n = max(8, min(40, floor(2 * math.pi * rm / (t * (square and 1.35 or 1.5)))))
    local lit = floor(frac * n + 0.5)
    if frac > 0 and lit == 0 then lit = 1 end
    for i = 0, n - 1 do
        local a = i / n * 2 * math.pi
        local x, y = cx + rm * math.sin(a), cy - rm * math.cos(a)
        local col = (i < lit) and fill or track
        if square then
            local sz = max(2, floor(t * 0.86))
            G.rrect(bb, floor(x - sz / 2 + 0.5), floor(y - sz / 2 + 0.5), sz, sz, 0, col, under, inv)
        else
            G.disc(bb, x, y, max(1, t * 0.44), col, under, inv)
        end
    end
end

-- Rings sharing one centre drawn as bars, in the square the outer ring fills:
-- stacked in the middle, or one bar under the middle (where a ring's own
-- figure usually sits).
function G.ringBars(bb, ox, oy, g, under, inv)
    local list = {}
    for i, r in ipairs(g.list) do list[i] = r end
    table.sort(list, function(a, b) return a.R > b.R end)
    local n = #list
    if n == 0 then return end
    local R = list[1].R
    local w = floor(2 * R)
    local x = floor(ox + g.cx - R)
    local bh = max(3, min(floor(list[1].t * 0.9), floor(2 * R * 0.62 / (n * 1.45))))
    local gap = max(2, floor(bh * 0.45))
    local total = n * bh + (n - 1) * gap
    local y0 = (n == 1) and floor(oy + g.cy + R * 0.42) or floor(oy + g.cy - total / 2)
    for i, r in ipairs(list) do
        local y = y0 + (i - 1) * (bh + gap)
        G.rrect(bb, x, y, w, bh, bh / 2, r.track, under, inv)
        local f = A.clamp(tonumber(r.frac) or 0, 0, 1)
        if f ~= f then f = 0 end
        if f > 0 then G.rrect(bb, x, y, max(bh, floor(w * f + 0.5)), bh, bh / 2, r.fill, under, inv) end
    end
    -- the campfire under the bars
    local room = oy + g.cy + R - (y0 + total)
    if room > 12 and g.fire and G.campfire then
        G.campfire(bb, ox + g.cx, y0 + total + room * 0.95, min(room * 0.9, w * 0.4), g.fire.level, g.fire.o, under, inv)
    end
end

-- ─── picture shapes (1.10.0) ─────────────────────────────────────────────────
-- Moons, batteries, an hourglass, weather, a tree stump, stars and a campfire.
-- Shapes with smooth edges are worked out pixel by pixel once and kept as
-- rows of single-colour runs (keyed by everything that changes them), then
-- repainted from those: the home screen redraws far more often than the
-- numbers change. Flat shapes are filled polygons with a smooth outline.

local _runs, _runs_n = {}, 0

-- Runs of the w x h box at x0, y0: pix(px, py) -> r, g, b, coverage (0..1)
-- for each pixel centre; uncovered pixels are skipped, partly covered ones
-- blended onto `under`.
local function shapeRows(key, x0, y0, w, h, under, pix)
    local hit = _runs[key]
    if hit then return hit end
    local rows = {}
    for j = 0, h - 1 do
        local row, cur = {}, nil
        for i = 0, w - 1 do
            local r, g, b, cov = pix(x0 + i + 0.5, y0 + j + 0.5)
            if r and cov > 0.01 then
                if cov < 1 then
                    r = under[1] + (r - under[1]) * cov
                    g = under[2] + (g - under[2]) * cov
                    b = under[3] + (b - under[3]) * cov
                end
                local k = floor(r + 0.5) * 65536 + floor(g + 0.5) * 256 + floor(b + 0.5)
                if cur and cur.k == k and cur.x + cur.n == i then
                    cur.n = cur.n + 1
                else
                    cur = { x = i, n = 1, k = k }
                    row[#row + 1] = cur
                end
            else
                cur = nil
            end
        end
        rows[j] = row
    end
    hit = { rows = rows, h = h }
    if _runs_n >= 96 then _runs, _runs_n = {}, 0 end
    _runs[key] = hit
    _runs_n = _runs_n + 1
    return hit
end

local function paintRows(bb, shape, x, y, inv)
    local rgb = { 0, 0, 0 }
    local bw, bh = bb:getWidth(), bb:getHeight()
    for j = 0, shape.h - 1 do
        local py = y + j
        if py >= 0 and py < bh then
            for _, run in ipairs(shape.rows[j]) do
                local px, n = x + run.x, run.n
                if px < 0 then n = n + px; px = 0 end
                if px + n > bw then n = bw - px end
                if n > 0 then
                    rgb[1], rgb[2], rgb[3] = floor(run.k / 65536), floor(run.k / 256) % 256, run.k % 256
                    fillRect(bb, px, py, n, 1, A.color(rgb, inv))
                end
            end
        end
    end
end

local function ckey(c) return c and (floor(c[1]) .. "," .. floor(c[2]) .. "," .. floor(c[3])) or "-" end
local function mix3(a, b, t) return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t end
local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end

-- A filled polygon (even-odd), sharp-edged; pts = { x1, y1, x2, y2, ... }.
function G.poly(bb, pts, rgb, inv)
    local n = floor(#pts / 2)
    if n < 3 then return end
    local miny, maxy = math.huge, -math.huge
    for i = 2, 2 * n, 2 do
        if pts[i] < miny then miny = pts[i] end
        if pts[i] > maxy then maxy = pts[i] end
    end
    local c = A.color(rgb, inv)
    local bw, bh = bb:getWidth(), bb:getHeight()
    for py = max(0, floor(miny)), min(bh - 1, ceil(maxy)) do
        local yc = py + 0.5
        local xs = {}
        for i = 1, n do
            local x1, y1 = pts[2 * i - 1], pts[2 * i]
            local j = (i % n) + 1
            local x2, y2 = pts[2 * j - 1], pts[2 * j]
            if (y1 <= yc and y2 > yc) or (y2 <= yc and y1 > yc) then
                xs[#xs + 1] = x1 + (yc - y1) * (x2 - x1) / (y2 - y1)
            end
        end
        table.sort(xs)
        for k = 1, #xs - 1, 2 do
            local a, b = max(0, floor(xs[k] + 0.5)), min(bw, floor(xs[k + 1] + 0.5))
            if b > a then fillRect(bb, a, py, b - a, 1, c) end
        end
    end
end

-- A polygon filled, with a smooth outline of width lw in `line`.
local function shape(bb, pts, fill, line, lw, under, inv)
    if fill then G.poly(bb, pts, fill, inv) end
    if line and lw and lw > 0 then
        local closed = {}
        for i = 1, #pts do closed[i] = pts[i] end
        closed[#closed + 1], closed[#closed + 2] = pts[1], pts[2]
        G.polyline(bb, closed, lw, line, under, inv)
    end
end
G.shape = shape

-- A moon of radius R lit `frac` of the way from new to full, the lit side
-- growing from the right like a waxing moon. o = { lit, dark, line }
function G.moon(bb, cx, cy, R, frac, o, under, inv)
    if not (R > 2 and R < 2048 and cx == cx and cy == cy) then return end
    frac = clamp01(tonumber(frac) or 0)
    if frac ~= frac then frac = 0 end
    local t = max(1, R * 0.07)
    local lit, dark, line = o.lit, o.dark, o.line
    local ox, oy = floor(cx - R - 1), floor(cy - R - 1)
    local size = ceil(2 * R + 3)
    local fx, fy = cx - ox, cy - oy
    local cosv = math.cos(math.pi * frac)
    local key = table.concat({ "moon", floor(R * 10), floor(frac * 1000), ckey(lit), ckey(dark), ckey(line), ckey(under),
        floor((cx - floor(cx)) * 10), floor((cy - floor(cy)) * 10) }, "|")
    local runs = shapeRows(key, 0, 0, size, size, under, function(px, py)
        local dx, dy = px - fx, py - fy
        local d = sqrt(dx * dx + dy * dy)
        local cov = clamp01(R + 0.5 - d)
        if cov <= 0 then return nil end
        local half = sqrt(max(0, R * R - dy * dy))
        local k
        if frac >= 0.999 then k = 1 elseif frac <= 0.001 then k = 0 else k = clamp01(dx - half * cosv + 0.5) end
        local r, g, b = mix3(dark, lit, k)
        local kl = clamp01(d - (R - t) + 0.5)
        if kl > 0 then r, g, b = r + (line[1] - r) * kl, g + (line[2] - g) * kl, b + (line[3] - b) * kl end
        return r, g, b, cov
    end)
    paintRows(bb, runs, ox, oy, inv)
end

-- A battery standing up in the box x, y, w, h: five cells, lit from the
-- bottom, a lightning bolt when full. o = { fill, track, line, bolt }
function G.battery(bb, x, y, w, h, frac, o, under, inv)
    if w < 6 or h < 10 then return end
    frac = clamp01(tonumber(frac) or 0)
    if frac ~= frac then frac = 0 end
    local nub_h = max(2, floor(h * 0.08))
    local nub_w = max(3, floor(w * 0.42))
    local lw = max(2, floor(w * 0.09))
    local r = max(2, floor(w * 0.16))
    G.rrect(bb, x + floor((w - nub_w) / 2), y, nub_w, nub_h + r, max(1, floor(nub_h / 2)), o.line, under, inv)
    G.frame(bb, x, y + nub_h, w, h - nub_h, r, lw, o.line, under, under, inv)
    local pad = lw + max(1, floor(w * 0.06))
    local ix, iy, iw, ih = x + pad, y + nub_h + pad, w - 2 * pad, h - nub_h - 2 * pad
    local cells, gap = 5, max(1, floor(ih * 0.04))
    local ch = (ih - (cells - 1) * gap) / cells
    local lit = floor(frac * cells + 0.5)
    if frac > 0 and lit == 0 then lit = 1 end
    for i = 1, cells do
        local cy0 = floor(iy + ih - i * ch - (i - 1) * gap + 0.5)
        G.rrect(bb, ix, cy0, iw, floor(ch + 0.5), max(1, floor(ch / 5)), (i <= lit) and o.fill or o.track, under, inv)
    end
    if frac >= 1 then
        local cx, cy = x + w / 2, y + nub_h + (h - nub_h) / 2
        local s = min(iw, ih) * 0.42
        local pts = { cx + s * 0.15, cy - s * 1.2, cx - s * 0.55, cy + s * 0.1, cx - s * 0.02, cy + s * 0.1,
                      cx - s * 0.18, cy + s * 1.2, cx + s * 0.55, cy - s * 0.12, cx + s * 0.02, cy - s * 0.12 }
        shape(bb, pts, o.bolt, o.line, max(1, floor(w * 0.04)), o.fill, inv)
    end
end

-- An hourglass in the box centred on cx, cy: `frac` of the sand has run to
-- the bottom. o = { frame, glass, sand, inside }
function G.hourglass(bb, cx, cy, w, h, frac, o, under, inv)
    if w < 10 or h < 16 then return end
    frac = clamp01(tonumber(frac) or 0)
    if frac ~= frac then frac = 0 end
    local cap = max(3, floor(h * 0.065))
    local x0, x1 = cx - w / 2, cx + w / 2
    local yt, yb = cy - h / 2 + cap, cy + h / 2 - cap
    local hw = w * 0.4                       -- half the bulb's width
    local neck = max(1, w * 0.045)
    local ym = cy
    local H = ym - yt
    local lw = max(1, floor(w * 0.035))
    -- glass
    local top = { cx - hw, yt, cx + hw, yt, cx + neck, ym, cx - neck, ym }
    local bot = { cx - neck, ym, cx + neck, ym, cx + hw, yb, cx - hw, yb }
    shape(bb, top, o.inside, nil, 0, under, inv)
    shape(bb, bot, o.inside, nil, 0, under, inv)
    -- sand left on top: a level that leaves (1 - frac) of the bulb's area
    local rest = 1 - frac
    if rest > 0.001 then
        local hs = H * sqrt(rest)
        local ws = neck + (hw - neck) * hs / H
        G.poly(bb, { cx - neck, ym, cx + neck, ym, cx + ws, ym - hs, cx - ws, ym - hs }, o.sand, inv)
    end
    -- the heap below, and the trickle between while it runs
    if frac > 0.001 then
        local hb = H * 0.92 * sqrt(frac)
        local wb = hw * min(1, 0.35 + 0.65 * sqrt(frac))
        G.poly(bb, { cx - wb, yb, cx + wb, yb, cx + wb * 0.25, yb - hb, cx - wb * 0.25, yb - hb }, o.sand, inv)
        if frac < 0.999 then
            G.rect(bb, floor(cx - max(1, lw / 2)), ym, max(1, lw), floor(yb - hb - ym), o.sand, inv)
        end
    end
    shape(bb, top, nil, o.glass, lw, under, inv)
    shape(bb, bot, nil, o.glass, lw, under, inv)
    -- frame: top and bottom plates and two posts
    local post = max(2, floor(w * 0.05))
    G.rrect(bb, x0, cy - h / 2, w, cap, max(1, floor(cap / 3)), o.frame, under, inv)
    G.rrect(bb, x0, cy + h / 2 - cap, w, cap, max(1, floor(cap / 3)), o.frame, under, inv)
    G.rect(bb, x0 + post, yt, post, yb - yt, o.frame, inv)
    G.rect(bb, x1 - 2 * post, yt, post, yb - yt, o.frame, inv)
end

-- Weather for a day, an icon of radius r: "sun", "partly" (sun behind a
-- cloud), "cloud", "rain" or "none" (a day still to come).
-- o = { sun, cloud, line, rain, faint }
local function cloud(bb, cx, cy, r, fill, line, under, inv)
    local lw = max(1, r * 0.09)
    local parts = { { -0.38, 0.12, 0.36 }, { 0.02, -0.12, 0.48 }, { 0.42, 0.14, 0.32 } }
    for _, p in ipairs(parts) do G.disc(bb, cx + p[1] * r, cy + p[2] * r, p[3] * r + lw, line, under, inv) end
    G.rrect(bb, cx - 0.74 * r - lw, cy + 0.06 * r - lw, 1.48 * r + 2 * lw, 0.42 * r + 2 * lw, 0.21 * r + lw, line, under, inv)
    for _, p in ipairs(parts) do G.disc(bb, cx + p[1] * r, cy + p[2] * r, p[3] * r, fill, line, inv) end
    G.rrect(bb, cx - 0.74 * r, cy + 0.06 * r, 1.48 * r, 0.42 * r, 0.21 * r, fill, line, inv)
end
local function sun(bb, cx, cy, r, col, line, under, inv)
    local lw = max(2, r * 0.13)
    local edge = max(1, r * 0.07)
    local ray = { mix3(col, line, 0.45) }
    for i = 0, 7 do
        local a = i * math.pi / 4
        local s, c = math.sin(a), math.cos(a)
        G.polyline(bb, { cx + c * r * 0.68, cy + s * r * 0.68, cx + c * r * 0.98, cy + s * r * 0.98 }, lw, ray, under, inv)
    end
    -- an outline, so it shows on a black-and-white screen too
    G.disc(bb, cx, cy, r * 0.48 + edge, line, under, inv)
    G.disc(bb, cx, cy, r * 0.48, col, line, inv)
end
function G.weather(bb, cx, cy, r, kind, o, under, inv)
    if r < 4 then return end
    if kind == "sun" then
        sun(bb, cx, cy, r, o.sun, o.line, under, inv)
    elseif kind == "partly" then
        sun(bb, cx + r * 0.28, cy - r * 0.28, r * 0.72, o.sun, o.line, under, inv)
        cloud(bb, cx - r * 0.08, cy + r * 0.18, r * 0.82, o.cloud, o.line, under, inv)
    elseif kind == "cloud" then
        cloud(bb, cx, cy, r * 0.95, o.cloud, o.line, under, inv)
    elseif kind == "rain" then
        cloud(bb, cx, cy - r * 0.22, r * 0.9, o.cloud, o.line, under, inv)
        local lw = max(1, r * 0.1)
        for i = -1, 1 do
            local x = cx + i * r * 0.36
            G.polyline(bb, { x + r * 0.08, cy + r * 0.38, x - r * 0.08, cy + r * 0.78 }, lw, o.rain, under, inv)
        end
    else
        G.disc(bb, cx, cy, max(1.5, r * 0.12), o.faint, under, inv)
    end
end

-- A tree stump seen from above: one growth ring per month, as wide as that
-- month's reading; `best` (a month) shaded in the accent.
-- o = { bark, wood, ring, best, pith }
function G.stump(bb, cx, cy, R, values, best, o, under, inv)
    if R < 8 then return end
    local n = #values
    local bark = max(2, floor(R * 0.09))
    local inner = R - bark
    local pith = max(1.5, R * 0.05)
    -- ring widths: the square root of the month's figure, never less than a
    -- hairline, so a quiet month is still a ring
    local widths, sum = {}, 0
    for i = 1, n do
        widths[i] = sqrt(max(0, values[i] or 0)) + 0.06
        sum = sum + widths[i]
    end
    G.disc(bb, cx, cy, R, o.bark, under, inv)
    G.disc(bb, cx, cy, inner, o.wood, o.bark, inv)
    if n == 0 or sum <= 0 then return end
    local avail = inner - pith - 1
    local radii, r = {}, pith
    for i = 1, n do
        r = r + avail * widths[i] / sum
        radii[i] = r
    end
    if best and radii[best] then
        G.disc(bb, cx, cy, radii[best], o.best, o.wood, inv)
        G.disc(bb, cx, cy, best > 1 and radii[best - 1] or pith, o.wood, o.best, inv)
    end
    local lw = max(1, R * 0.018)
    for i = 1, n do
        G.ring(bb, cx, cy, radii[i] + lw / 2, lw, 1, o.ring, o.ring, o.wood, inv)
    end
    G.disc(bb, cx, cy, pith, o.pith, o.wood, inv)
    -- two cracks from the middle
    local clw = max(1, R * 0.02)
    G.polyline(bb, { cx + R * 0.05, cy - R * 0.02, cx + R * 0.32, cy - R * 0.1, cx + R * 0.5, cy - R * 0.06 }, clw, o.ring, o.wood, inv)
    G.polyline(bb, { cx - R * 0.04, cy + R * 0.05, cx - R * 0.2, cy + R * 0.34 }, clw, o.ring, o.wood, inv)
end

-- A four-pointed sparkle star of radius r.
function G.star(bb, cx, cy, r, fill, line, under, inv)
    if r < 1.5 then return G.disc(bb, cx, cy, max(1, r), fill, under, inv) end
    local pts = {}
    for i = 0, 7 do
        local a = -math.pi / 2 + i * math.pi / 4
        local rr = (i % 2 == 0) and r or r * 0.34
        pts[#pts + 1], pts[#pts + 2] = cx + math.cos(a) * rr, cy + math.sin(a) * rr
    end
    shape(bb, pts, fill, line, line and max(1, r * 0.1) or 0, under, inv)
end

-- A campfire on the ground at cx, by (the bottom), `size` tall: flames as
-- big as `level` (0..1), embers and a wisp of smoke at 0.
-- o = { log, log_line, flame, core, ember, smoke }
function G.campfire(bb, cx, by, size, level, o, under, inv)
    if size < 10 then return end
    level = clamp01(tonumber(level) or 0)
    local lw = max(2, size * 0.11)
    local lx = size * 0.42
    local base = by - size * 0.14
    local function logs()
        G.polyline(bb, { cx - lx, by - size * 0.05, cx + lx, by - size * 0.2 }, lw + 2, o.log_line, under, inv)
        G.polyline(bb, { cx - lx, by - size * 0.2, cx + lx, by - size * 0.05 }, lw + 2, o.log_line, under, inv)
        G.polyline(bb, { cx - lx, by - size * 0.05, cx + lx, by - size * 0.2 }, lw, o.log, under, inv)
        G.polyline(bb, { cx - lx, by - size * 0.2, cx + lx, by - size * 0.05 }, lw, o.log, under, inv)
    end
    if level <= 0.001 then
        logs()
        for i = -1, 1 do G.disc(bb, cx + i * size * 0.13, base - size * 0.04, max(1.5, size * 0.05), o.ember, under, inv) end
        G.polyline(bb, { cx, base - size * 0.14, cx - size * 0.08, base - size * 0.34, cx + size * 0.06, base - size * 0.51,
            cx - size * 0.04, base - size * 0.68 }, max(1, size * 0.04), o.smoke, under, inv)
        return
    end
    -- flames: a teardrop each, the middle one tallest, behind the logs
    local edge = { mix3(o.flame, o.log_line, 0.5) }
    local function flame(fx, fh, fw, col, outline)
        local pts = {}
        local steps = 14
        for i = 0, steps do
            local a = math.pi + math.pi * i / steps
            pts[#pts + 1], pts[#pts + 2] = fx + math.cos(a) * fw, base - math.sin(a) * fw * 0.5
        end
        pts[#pts + 1], pts[#pts + 2] = fx + fw * 0.6, base - fh * 0.5
        pts[#pts + 1], pts[#pts + 2] = fx + fw * 0.05, base - fh
        pts[#pts + 1], pts[#pts + 2] = fx - fw * 0.55, base - fh * 0.55
        shape(bb, pts, col, outline and edge or nil, outline and max(1, size * 0.025) or 0, under, inv)
    end
    local s = 0.35 + 0.65 * level
    local H, W = size * 0.78 * s, size * 0.2 * (0.6 + 0.4 * s)
    flame(cx - W * 0.9, H * 0.62, W * 0.8, o.flame, true)
    flame(cx + W * 0.95, H * 0.7, W * 0.8, o.flame, true)
    flame(cx, H, W * 1.1, o.flame, true)
    flame(cx, H * 0.55, W * 0.6, o.core, false)
    logs()
end

local function groupFire(bb, g, cx, by, size, under, inv)
    if g.fire and G.campfire then G.campfire(bb, cx, by, size, g.fire.level, g.fire.o, under, inv) end
end
-- Rings sharing one centre as moons: the outer ring a big moon, the others
-- small moons beside it. A moon is as full as its ring. Light colours, so a
-- figure written over a single moon stays readable.
function G.ringMoons(bb, ox, oy, g, under, inv)
    local list = {}
    for i, r in ipairs(g.list) do list[i] = r end
    table.sort(list, function(a, b) return a.R > b.R end)
    local n = #list
    if n == 0 then return end
    local R = list[1].R
    local cx, cy = ox + g.cx, oy + g.cy
    local function colours(r)
        local ink = r.fill
        -- the lit side glows: lighter than the card on a dark card
        local lit = (A.luma(under) < 128) and A.mix(ink, { 255, 255, 255 }, 0.4) or A.mix(under, ink, 0.55)
        return { lit = lit, dark = r.track, line = A.mix(ink, { 0, 0, 0 }, 0.25) }
    end
    if n == 1 and not g.fire then
        G.moon(bb, cx, cy, R * 0.92, list[1].frac, colours(list[1]), under, inv)
        return
    end
    G.moon(bb, cx - R * 0.26, cy - R * 0.22, R * 0.7, list[1].frac, colours(list[1]), under, inv)
    local spots = { { 0.62, 0.42 }, { 0.12, 0.74 }, { 0.72, -0.4 } }
    for i = 2, min(n, 4) do
        local sp = spots[i - 1]
        G.moon(bb, cx + R * sp[1], cy + R * sp[2], R * 0.27, list[i].frac, colours(list[i]), under, inv)
    end
    -- a campfire in the free corner, bottom left
    groupFire(bb, g, cx - R * 0.62, cy + R * 0.98, R * 0.62, under, inv)
end

-- Rings sharing one centre as batteries standing side by side in the square
-- the outer ring fills.
function G.ringBatteries(bb, ox, oy, g, under, inv)
    local list = {}
    for i, r in ipairs(g.list) do list[i] = r end
    table.sort(list, function(a, b) return a.R > b.R end)
    local n = #list
    if n == 0 then return end
    local R = list[1].R
    local side = 2 * R
    local slots = n + (g.fire and 1 or 0)
    local gap = max(2, floor(side * 0.06))
    local bw = min(floor(side * 0.42), floor((side - (slots - 1) * gap) / slots))
    local bh = floor(side * 0.92)
    local total = slots * bw + (slots - 1) * gap
    local x = floor(ox + g.cx - total / 2)
    local y = floor(oy + g.cy - bh / 2)
    for i, r in ipairs(list) do
        G.battery(bb, x + (i - 1) * (bw + gap), y, bw, bh, r.frac, {
            fill = r.fill, track = r.track, line = A.mix(r.fill, { 0, 0, 0 }, 0.35), bolt = { 255, 214, 60 },
        }, under, inv)
    end
    -- the campfire in the last place, standing on the same ground
    groupFire(bb, g, x + n * (bw + gap) + bw / 2, y + bh, min(bw * 1.25, bh * 0.5), under, inv)
end

-- ─── fonts and text ──────────────────────────────────────────────────────────
-- Everything here is sized in real pixels, derived from the panel's size.
-- KOReader's Font:getFace takes a size that it scales for the screen itself
-- (ceil(size * scale)), so convert back before asking.

local function dp(px)
    local Screen = A.screen()
    local scale = Screen:scaleBySize(1000000) / 1000000
    return max(1, (px - 0.5) / scale)
end

function A.face(px, o)
    o = o or {}
    px = max(8, floor(px + 0.5))
    -- (asked of Font:getFace as KOReader has it, before Simple UI's Global
    -- Text Size scales it: the cards are drawn to fit their box)
    if o.symbol then
        -- icon glyphs: KOReader's bundled Nerd Font symbols
        local Font = require("ui/font")
        local getFace = A.host.nativeGetFace() or Font.getFace
        local ok, face = pcall(getFace, Font, "symbols", dp(px))
        if ok and face then return face, false end
    end
    if o.serif then
        local Font = require("ui/font")
        local name = o.bold and "NotoSerif-Bold.ttf" or (o.italic and "NotoSerif-Italic.ttf" or "NotoSerif-Regular.ttf")
        local getFace = A.host.nativeGetFace() or Font.getFace
        local ok, face = pcall(getFace, Font, name, dp(px))
        if ok and face then return face, false end
    end
    local ok, face, bold = pcall(A.host.face, dp(px), o)
    if ok and face then return face, bold end
    local Font = require("ui/font")
    return Font:getFace(o.bold and "tfont" or "cfont", dp(px)), false
end

-- Single-line text that keeps a colour ink a colour (see colourtext.lua).
local function textClass()
    return A.host.textClass()
end

-- Wrapped text that composites over whatever is behind it. KOReader's
-- TextBoxWidget paints an opaque box in a flattened grey, which shows as a
-- slab on a coloured card; this renders black-on-white once and uses that
-- bitmap as the coverage mask for the ink (the approach Bookshelf's own
-- TransparentTextBox takes, extended to keep a colour ink a colour).
local _MText
local function mtextClass()
    if _MText then return _MText end
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Blitbuffer = require("ffi/blitbuffer")
    _MText = TextBoxWidget:extend{ ink = nil }
    function _MText:init()
        self.ink = self.fgcolor or Blitbuffer.COLOR_BLACK
        self.fgcolor = Blitbuffer.COLOR_BLACK
        self.bgcolor = Blitbuffer.COLOR_WHITE
        TextBoxWidget.init(self)
    end
    function _MText:paintTo(bb, x, y)
        local m = self._bb
        if not m then return TextBoxWidget.paintTo(self, bb, x, y) end
        if self.dimen then self.dimen.x, self.dimen.y = x, y end
        local w, h = m:getWidth(), m:getHeight()
        m:invertRect(0, 0, w, h)
        local ok
        if bb.colorblitFromRGB32 and Blitbuffer.isColor8 and not Blitbuffer.isColor8(self.ink) then
            ok = pcall(bb.colorblitFromRGB32, bb, m, x, y, 0, 0, w, h, self.ink)
        else
            ok = pcall(bb.colorblitFrom, bb, m, x, y, 0, 0, w, h, self.ink)
        end
        m:invertRect(0, 0, w, h)
        if not ok then TextBoxWidget.paintTo(self, bb, x, y) end
    end
    return _MText
end

-- ─── Canvas ──────────────────────────────────────────────────────────────────
-- One card. Things are placed at absolute pixel positions inside it, which
-- keeps layout and tap regions in the same coordinates.
--
-- Night mode: KOReader inverts the whole screen. A dark card would come out
-- pale, so a dark-toned canvas paints every colour pre-inverted and ends up
-- looking the same as by day. (The light "paper" card switches to a dark
-- variant at night for the same reason; see A.tone.) Covers are inverted
-- once more after they are drawn, so they keep their real colours.

local _Canvas
local function canvasClass()
    if _Canvas then return _Canvas end
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local C = Widget:extend{ w = 0, h = 0 }

    function C:init()
        self.ops = {}
        self.regions = {}
        self.owned = {}
        self.dimen = Geom:new{ w = self.w, h = self.h }
        local Screen = A.screen()
        -- Night mode inverts the screen. Cards meant to look the same day and
        -- night (every dark card, and every card of the newer themes) are
        -- painted pre-inverted.
        local tone = self.tone
        self.inv = (Screen.night_mode and tone and (tone.dark or tone.fixed)) and true or false
        -- Colour that sits under this canvas, in the canvas's own colour
        -- space. `page` = the Dashboard's page colour as it should LOOK, when
        -- this card is on one; otherwise Simple UI's background.
        if self.page then
            self.under = self.inv and self.page or A.shown(self.page)
        else
            local page_bg = A.pageColors()
            self.under = self.inv and { 255 - page_bg[1], 255 - page_bg[2], 255 - page_bg[3] } or page_bg
        end
    end

    function C:getSize() return Geom:new{ w = self.w, h = self.h } end

    function C:col(rgb) return A.color(rgb, self.inv) end

    function C:op(fn) self.ops[#self.ops + 1] = fn end

    function C:rect(x, y, w, h, rgb)
        local inv = self.inv
        self:op(function(bb, ox, oy) G.rect(bb, ox + x, oy + y, w, h, rgb, inv) end)
    end

    function C:rrect(x, y, w, h, r, rgb, under)
        local inv = self.inv
        under = under or (self.tone and self.tone.bg) or self.under
        self:op(function(bb, ox, oy) G.rrect(bb, ox + x, oy + y, w, h, r, rgb, under, inv) end)
    end

    function C:frame(x, y, w, h, r, bw, border, fill, under)
        local inv = self.inv
        under = under or (self.tone and self.tone.bg) or self.under
        self:op(function(bb, ox, oy) G.frame(bb, ox + x, oy + y, w, h, r, bw, border, fill, under, inv) end)
    end

    function C:disc(cx, cy, r, rgb, under)
        -- the dot in the middle of rings drawn as bars has no place there
        if self._rings and self._rings[cx .. ":" .. cy] then return end
        local inv = self.inv
        under = under or (self.tone and self.tone.bg) or self.under
        self:op(function(bb, ox, oy) G.disc(bb, ox + cx, oy + cy, r, rgb, under, inv) end)
    end

    function C:ring(cx, cy, R, t, frac, track, fill)
        local inv = self.inv
        local under = (self.tone and self.tone.bg) or self.under
        local style = A.progressStyle()
        if style == "bars" or style == "moons" or style == "batteries" then
            -- rings sharing a centre become one set of bars, moons or batteries
            self._rings = self._rings or {}
            local key = cx .. ":" .. cy
            local g = self._rings[key]
            if not g then
                g = { cx = cx, cy = cy, list = {} }
                self._rings[key] = g
                local draw = (style == "moons" and G.ringMoons) or (style == "batteries" and G.ringBatteries) or G.ringBars
                self:op(function(bb, ox, oy) draw(bb, ox, oy, g, under, inv) end)
            end
            g.list[#g.list + 1] = { R = R, t = t, frac = frac, track = track, fill = fill }
            return
        elseif style == "dots" or style == "blocks" then
            local square = style == "blocks"
            self:op(function(bb, ox, oy) G.ringDots(bb, ox + cx, oy + cy, R, t, frac, track, fill, under, inv, square) end)
            return
        end
        self:op(function(bb, ox, oy) G.ring(bb, ox + cx, oy + cy, R, t, frac, track, fill, under, inv) end)
    end

    -- A line through points { x1, y1, x2, y2, ... } in canvas coordinates.
    function C:polyline(pts, lw, rgb, under)
        local inv = self.inv
        under = under or (self.tone and self.tone.bg) or self.under
        self:op(function(bb, ox, oy)
            local moved = {}
            for i = 1, #pts, 2 do moved[i], moved[i + 1] = pts[i] + ox, pts[i + 1] + oy end
            G.polyline(bb, moved, lw, rgb, under, inv)
        end)
    end

    -- A single line of text. Returns { widget, w, h, base } without placing it.
    function C:text(str, px, o)
        o = o or {}
        local face, bold = A.face(px, o)
        local rgb = o.color or (self.tone and self.tone.fg) or { 0, 0, 0 }
        local txt = o.caps and A.upper(str) or A.safe(str)
        local tw = textClass():new{
            text = txt, face = face, bold = bold and true or false,
            fgcolor = self:col(rgb),
            max_width = o.max_w and max(8, floor(o.max_w)) or nil,
        }
        local sz = tw:getSize()
        self.owned[#self.owned + 1] = tw
        return { widget = tw, w = sz.w, h = sz.h, base = tw:getBaseline() or sz.h, px = px }
    end

    -- Wrapped text, at most `lines` lines (ellipsis after that).
    function C:textbox(str, px, width, lines, o)
        o = o or {}
        local face, bold = A.face(px, o)
        local rgb = o.color or (self.tone and self.tone.fg) or { 0, 0, 0 }
        local lh = o.line_height or 0.18
        local line_px = floor((1 + lh) * face.size + 0.5)
        local tb = mtextClass():new{
            text = o.caps and A.upper(str) or A.safe(str),
            face = face, bold = bold and true or false,
            width = max(20, floor(width)),
            height = lines and (line_px * lines) or nil,
            height_adjust = lines and true or nil,
            height_overflow_show_ellipsis = lines and true or nil,
            line_height = lh,
            alignment = o.align or "left",
            fgcolor = self:col(rgb),
        }
        local sz = tb:getSize()
        self.owned[#self.owned + 1] = tb
        return { widget = tb, w = sz.w, h = sz.h, base = sz.h, px = px, box = true }
    end

    -- Place a text. anchor: "l" (default), "c", "r" relative to x.
    -- valign: "top" (default), "base" (y is the baseline), "mid" (y is the centre).
    function C:put(t, x, y, anchor, valign)
        if anchor == "r" then x = x - t.w elseif anchor == "c" then x = x - t.w / 2 end
        if valign == "base" then y = y - t.base elseif valign == "mid" then y = y - t.h / 2 end
        x, y = floor(x + 0.5), floor(y + 0.5)
        local w = t.widget
        self:op(function(bb, ox, oy) w:paintTo(bb, ox + x, oy + y) end)
        return x, y
    end

    -- Create and place in one go. Returns the text record.
    function C:label(str, px, x, y, o)
        o = o or {}
        local t = self:text(str, px, o)
        self:put(t, x, y, o.anchor, o.valign)
        return t
    end

    -- A book cover, cropped to fill w x h. `fp` may be nil (placeholder).
    -- o = { title = (shown when there is no cover), edge = border colour,
    --       border = width or false, top = crop from the top, not the middle }
    function C:cover(fp, x, y, w, h, o)
        o = o or {}
        x, y, w, h = floor(x), floor(y), floor(w), floor(h)
        if w < 4 or h < 2 then return end
        local tone = self.tone or A.tone("ink")
        local src = fp and A.D and A.D.cover(fp, w, h, o.top and "top" or nil) or nil
        local inv = self.inv
        local bw = o.border == false and 0 or max(1, floor((o.border or 1)))
        local edge = o.edge or tone.muted
        local title
        if not src and o.title and w >= 40 then
            title = self:textbox(o.title, max(9, floor(w / 8)), w - floor(w / 6), 4,
                { bold = true, color = tone.fg, align = "center" })
        end
        self:op(function(bb, ox, oy)
            local X, Y = ox + x, oy + y
            if src then
                local sw, sh = src:getWidth(), src:getHeight()
                local sx = max(0, floor((sw - w) / 2))
                local sy = o.top and 0 or max(0, floor((sh - h) / 2))
                local Screen = A.screen()
                if Screen.sw_dithering and bb.ditherblitFrom then
                    bb:ditherblitFrom(src, X, Y, sx, sy, min(w, sw), min(h, sh))
                else
                    bb:blitFrom(src, X, Y, sx, sy, min(w, sw), min(h, sh))
                end
                -- keep the cover's real colours when the screen is inverted
                if Screen.night_mode then bb:invertRect(X, Y, min(w, sw), min(h, sh)) end
            else
                G.rect(bb, X, Y, w, h, tone.track, inv)
                if title then
                    title.widget:paintTo(bb, X + floor((w - title.w) / 2), Y + floor((h - title.h) / 2))
                end
            end
            if bw > 0 then
                local c = A.color(edge, inv)
                fillRect(bb, X, Y, w, bw, c)
                fillRect(bb, X, Y + h - bw, w, bw, c)
                fillRect(bb, X, Y, bw, h, c)
                fillRect(bb, X + w - bw, Y, bw, h, c)
            end
        end)
    end

    function C:region(id, x, y, w, h, pad)
        pad = pad or 0
        self.regions[#self.regions + 1] = {
            id = id, x = floor(x - pad), y = floor(y - pad), w = floor(w + 2 * pad), h = floor(h + 2 * pad),
        }
    end

    -- Nest another canvas at (x, y). Its tap regions come along, prefixed.
    function C:sub(child, x, y, prefix)
        x, y = floor(x), floor(y)
        self.owned[#self.owned + 1] = child
        self:op(function(bb, ox, oy) child:paintTo(bb, ox + x, oy + y, true) end)
        for _, r in ipairs(child.regions) do
            self.regions[#self.regions + 1] = {
                id = (prefix or "") .. r.id, x = r.x + x, y = r.y + y, w = r.w, h = r.h,
            }
        end
    end

    function C:paintTo(bb, x, y, nested)
        local w, h = self.w, self.h
        self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
        local px, py, pw, ph = x, y, w, h
        -- `bleed`: let the panel run to the edges of an offscreen buffer it is
        -- centred in with a small inset (a host that paints modules that way).
        -- Simple UI does not, so this stays off; kept for the shared layout code.
        if self.bleed and not nested then
            local Screen = A.screen()
            local bw, bh = bb:getWidth(), bb:getHeight()
            local slack = Screen:scaleBySize(48)
            if (bw < Screen:getWidth() or bh < Screen:getHeight())
                    and bw - w >= 0 and bh - h >= 0 and bw - w <= slack and bh - h <= slack
                    and x == floor((bw - w) / 2) and y == floor((bh - h) / 2) then
                px, py, pw, ph = 0, 0, bw, bh
            end
        end
        if self.fill then G.rect(bb, px, py, pw, ph, self.fill, false) end
        local tone = self.tone
        if tone and not self.plain then
            local r = self.radius or 0
            if tone.border and (self.border_w or 0) > 0 then
                G.frame(bb, px, py, pw, ph, r, self.border_w, tone.border, tone.bg, self.under, self.inv)
            else
                G.rrect(bb, px, py, pw, ph, r, tone.bg, self.under, self.inv)
            end
        end
        for i = 1, #self.ops do self.ops[i](bb, x, y) end
    end

    function C:free()
        for _, wdg in ipairs(self.owned) do
            if wdg.free then pcall(wdg.free, wdg) end
        end
        self.owned, self.ops = {}, {}
    end

    _Canvas = C
    return C
end

--- A.canvas{ w=, h=, tone="ink"|table|nil, radius=, border_w=, bleed=bool, plain=bool }
function A.canvas(o)
    local tone = o.tone
    if type(tone) == "string" then tone = A.tone(tone) end
    return canvasClass():new{
        w = max(1, floor(o.w)), h = max(1, floor(o.h)), tone = tone,
        radius = o.radius, border_w = o.border_w, bleed = o.bleed, plain = o.plain, page = o.page,
        fill = o.fill,
    }
end

-- ─── formatting helpers ──────────────────────────────────────────────────────

function A.fmtMinutes(mins)
    mins = max(0, floor((tonumber(mins) or 0) + 0.5))
    local h, m = floor(mins / 60), mins % 60
    if h > 0 and m > 0 then return string.format("%d h %d m", h, m) end
    if h > 0 then return string.format("%d h", h) end
    return string.format("%d m", m)
end

-- 14894 -> "14,894"
function A.thousands(n)
    local str = tostring(floor((tonumber(n) or 0) + 0.5))
    local sign, digits = str:match("^(-?)(%d+)$")
    if not digits then return str end
    digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. digits
end

function A.plural(n, one, many)
    if n == 1 then return string.format("%d %s", n, one) end
    return string.format("%d %s", n, many)
end

-- Day/month names in the interface language (os.date gives English).
function A.date(fmt, t)
    local s = os.date(fmt, t)
    local ok, r = pcall(A.host.localizeDate, s)
    if ok and type(r) == "string" then return r end
    return s
end

-- Days since the epoch for a local calendar date, anchored at noon so a DST
-- shift cannot move the boundary.
function A.dayNumber(y, m, d)
    return floor(os.time{ year = y, month = m, day = d, hour = 12 } / 86400)
end

function A.parseYmd(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

function A.todayYmd()
    local t = os.date("*t")
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day), t
end

-- ─── load the other parts ────────────────────────────────────────────────────

local function part(name)
    local chunk, err = loadfile(A.dir .. "/" .. name .. ".lua")
    if not chunk then error("almanac: cannot load " .. name .. ".lua: " .. tostring(err)) end
    return chunk(A)
end

part("host")
part("data")
part("panels")
part("settings")
part("modules")
part("menus")
part("critter")

A.note(A.NAME .. " for " .. A.HOST, A.VERSION, "loaded from", A.dir)

return A
