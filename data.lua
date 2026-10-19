-- Modified by TK for SimpleUI, 2026 (ported from stevenzamora1/reading-log).
--[[
Reading Log data: everything the cards show, read from where KOReader and
Bookshelf already keep it.

  reading list    ReadHistory + each book's sidecar (via Bookshelf's repository)
  finished books  same, counted the way Bookshelf's own Reading goals card does
  reading stats   statistics.sqlite3, opened read-only
  covers          CoverBrowser's cache (via Bookshelf's repository)
  collections     KOReader's ReadCollection

Nothing here writes to any of those. Slow reads (the statistics scans, the
year's finished books) run off the paint path: the card shows what it has,
the query runs on the next tick, and the card redraws when it lands.
]]

local A = ...
local D = {}
A.D = D

local floor, max, min = math.floor, math.max, math.min

local function repo()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok and type(Repo) == "table" then return Repo end
    return nil
end

local function lfs()
    local ok, m = pcall(require, "libs/libkoreader-lfs")
    return ok and m or nil
end

function D.fileExists(fp)
    local l = lfs()
    if not (l and type(fp) == "string") then return false end
    return l.attributes(fp, "mode") == "file"
end

-- ─── deferred, cached reads ──────────────────────────────────────────────────
-- slot(refresh) returns: a table (data), false (looked, nothing there) or nil
-- (first load still running). When stale it hands back what it has and
-- recomputes in the background, then calls every waiting refresh once.

local _slots = {}

-- o.ttl   seconds a result stays fresh (default 60)
-- o.key   optional function: the result is also stale once key() changes
-- o.sig   optional function(value) -> string: waiting cards are only asked
--         to redraw when this changes, so a recheck that finds nothing new
--         does not repaint the screen
local function deferred(name, o, compute)
    local s = { at = 0, value = nil, busy = false, waiters = {}, key = nil, sig = nil }
    _slots[name] = s
    local ttl = o.ttl or 60
    local function run()
        local key = o.key and o.key() or nil
        local ok, v = pcall(compute)
        if not ok then A.log(name, "failed:", v) end
        local first = s.value == nil
        s.value = (ok and v) or false
        s.at, s.key = os.time(), key
        local sig = (o.sig and s.value) and o.sig(s.value) or tostring(s.value)
        local changed = first or sig ~= s.sig or not o.sig
        s.sig = sig
        return changed
    end
    return function(refresh, sync)
        local now = os.time()
        if s.value ~= nil and now - s.at < ttl and (not o.key or o.key() == s.key) then
            return s.value
        end
        if sync then run() return s.value end
        if refresh then
            local seen = false
            for _, r in ipairs(s.waiters) do if r == refresh then seen = true break end end
            if not seen then s.waiters[#s.waiters + 1] = refresh end
        end
        if not s.busy then
            s.busy = true
            require("ui/uimanager"):scheduleIn(0, function()
                local changed = run()
                s.busy = false
                local ws = s.waiters
                s.waiters = {}
                if changed then
                    for _, r in ipairs(ws) do pcall(r) end
                end
            end)
        end
        return s.value
    end
end

-- Drop everything cached (after a setting changed, or on request).
function D.invalidate()
    for _, s in pairs(_slots) do s.at = 0 end
    D._reading = nil
end

-- ─── per-book facts ──────────────────────────────────────────────────────────

local _info = {}

-- Title / author / genres for a file, from CoverBrowser's cache.
function D.info(fp)
    local c = _info[fp]
    if c then return c end
    local rec
    local Repo = repo()
    if Repo and Repo.buildBookMeta then
        local ok, r = pcall(Repo.buildBookMeta, fp, { want_cover = false })
        if ok and type(r) == "table" then rec = r end
    end
    local name = (fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", "")
    c = {
        title = (rec and rec.title and rec.title ~= "" and rec.title) or name,
        author = rec and (rec.author or (rec.authors and rec.authors[1])) or nil,
        genres = rec and type(rec.genres) == "table" and rec.genres or {},
        cover_path = rec and rec.cover_image_path or nil,
        series = rec and rec.series_name or nil,
    }
    _info[fp] = c
    return c
end

-- pct (0..1), status ("reading" | "finished" | "on_hold" | nil), pages, opened
function D.progress(fp)
    local Repo = repo()
    if not Repo then return nil end
    if Repo.progressFor then
        local ok, pct, status, _, pages, opened = pcall(Repo.progressFor, fp)
        if ok then return pct, status, pages, opened end
    end
    if Repo.readProgress then
        local ok, pct, status, _, pages = pcall(Repo.readProgress, fp)
        if ok then return pct, status, pages, true end
    end
    return nil
end

-- "YYYY-MM-DD" a book was marked finished, or nil.
function D.finishedOn(fp)
    local Repo = repo()
    if Repo and Repo.finishedOn then
        local ok, d = pcall(Repo.finishedOn, fp)
        if ok and d ~= nil then return d end
        if ok then return nil end
    end
    local ok, d = pcall(function()
        local ds = require("docsettings"):open(fp)
        local summary = ds:readSetting("summary")
        return type(summary) == "table" and summary.modified or nil
    end)
    return ok and d or nil
end

local function ymOf(d)
    if type(d) == "string" then
        local y, m, dd = d:match("^(%d%d%d%d)%-(%d%d)%-?(%d?%d?)")
        if y then return tonumber(y), tonumber(m), tonumber(dd) end
        return nil
    end
    if type(d) == "number" then
        local t = os.date("*t", d)
        return t.year, t.month, t.day
    end
    if type(d) == "table" and tonumber(d.year) then
        return tonumber(d.year), tonumber(d.month), tonumber(d.day)
    end
    return nil
end

local function history()
    local ok, rh = pcall(require, "readhistory")
    if ok and rh and type(rh.hist) == "table" then return rh.hist end
    return {}
end

-- ─── currently reading ───────────────────────────────────────────────────────
-- Newest first. A book counts while its status is "reading", or it has no
-- status yet but has been started and not finished.

local READING_TTL = 20
local READING_SCAN = 80

function D.reading(limit)
    limit = limit or 5
    local want = max(limit, 10) -- one scan serves every card (and the day counts)
    local now = os.time()
    local c = D._reading
    if c and now - c.at < READING_TTL and c.epoch == A.epoch and c.limit >= limit then
        if #c.list <= limit then return c.list end
        local cut = {}
        for i = 1, limit do cut[i] = c.list[i] end
        return cut
    end
    local list, seen = {}, {}
    local hist = history()
    local Repo = repo()
    for i = 1, min(#hist, READING_SCAN) do
        local fp = hist[i] and hist[i].file
        if fp and not seen[fp] and D.fileExists(fp) then
            seen[fp] = true
            local pct, status, pages = D.progress(fp)
            pct = tonumber(pct)
            local in_progress = status == "reading"
                or (status == nil and pct and pct > 0 and pct < 0.995)
            if in_progress then
                local info = D.info(fp)
                local item = {
                    fp = fp, title = info.title, author = info.author,
                    pct = pct or 0, pages = tonumber(pages),
                }
                if Repo and Repo.enrichStats then
                    local probe = { filepath = fp, book_pct = item.pct }
                    pcall(Repo.enrichStats, probe)
                    item.left_min = tonumber(probe.book_time_left_minutes)
                end
                list[#list + 1] = item
                if #list >= want then break end
            end
        end
    end
    D._reading = { at = now, list = list, epoch = A.epoch, limit = want }
    if #list <= limit then return list end
    local cut = {}
    for i = 1, limit do cut[i] = list[i] end
    return cut
end

-- ─── finished this year ──────────────────────────────────────────────────────
-- Same rule as Bookshelf's Reading goals card, so the two always agree: a
-- book counts in the year it was MARKED finished (the sidecar's
-- summary.modified); the date it was last opened stands in when there is none.

-- The first month the Monthly page can go back to: twelve before this one.
local BACK_MONTHS = 12
D.BACK_MONTHS = BACK_MONTHS

local function ymKey(y, m) return string.format("%04d-%02d", y, m) end
D.ymKey = ymKey

local function computeYear()
    local t = os.date("*t")
    local year_start = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
    local back_start = os.time{ year = t.year, month = t.month - BACK_MONTHS, day = 1, hour = 0, min = 0, sec = 0 }
    local since = math.min(year_start, back_start)
    local first_key = os.date("%Y-%m", back_start)
    local months = {}
    for m = 1, 12 do months[m] = {} end
    -- every month back to back_start, this year's and last year's: "YYYY-MM" -> books
    local recent = {}
    local list, seen = {}, {}
    -- one read-only connection for correcting finish dates (see D.realFinish)
    local fixer = D.finishFixer and D.finishFixer() or nil
    for _, entry in ipairs(history()) do
        local fp = entry.file
        if fp and not seen[fp] and (entry.time or 0) >= since then
            seen[fp] = true
            local _, status, pages = D.progress(fp)
            if status == "finished" then
                local y, m, d = ymOf(D.finishedOn(fp))
                if not y then
                    local et = os.date("*t", entry.time or 0)
                    y, m, d = et.year, et.month, et.day
                end
                -- KOReader re-stamps the finished date whenever a finished
                -- book is marked finished again (a page turn past the end on
                -- reopening it). Pull it back to the last day of real
                -- reading on or before that date.
                if y and m and fixer then
                    local fy, fm, fd = fixer.fix(fp, y, m, d or 1)
                    if fy then y, m, d = fy, fm, fd end
                end
                if y and m and m >= 1 and m <= 12 then
                    local info = D.info(fp)
                    local item = { fp = fp, year = y, month = m, day = d or 1, title = info.title,
                        author = info.author, genres = info.genres, pages = tonumber(pages) or 0 }
                    local key = ymKey(y, m)
                    if key >= first_key then
                        recent[key] = recent[key] or {}
                        recent[key][#recent[key] + 1] = item
                    end
                    if y == t.year then
                        months[m][#months[m] + 1] = item
                        list[#list + 1] = item
                    end
                end
            end
        end
    end
    if fixer then fixer.close() end
    for _, l in pairs(recent) do table.sort(l, function(a, b) return a.day > b.day end) end
    local function byDay(a, b)
        if a.month ~= b.month then return a.month > b.month end
        return a.day > b.day
    end
    table.sort(list, byDay) -- newest first
    for m = 1, 12 do table.sort(months[m], function(a, b) return a.day > b.day end) end

    local tally, order = {}, {}
    for _, it in ipairs(list) do
        local counted = {}
        for _, g in ipairs(it.genres or {}) do
            g = type(g) == "string" and g:match("^%s*(.-)%s*$") or nil
            if g and g ~= "" and not counted[g] then
                counted[g] = true
                if not tally[g] then tally[g] = 0; order[#order + 1] = g end
                tally[g] = tally[g] + 1
            end
        end
    end
    local genres = {}
    for _, g in ipairs(order) do genres[#genres + 1] = { name = g, n = tally[g] } end
    table.sort(genres, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)

    return { year = t.year, month = t.month, months = months, list = list,
             total = #list, genres = genres, recent = recent }
end

D.year = deferred("year", {
    ttl = 60,
    sig = function(v)
        local parts = { v.year, v.total }
        for m = 1, 12 do parts[#parts + 1] = #v.months[m] end
        parts[#parts + 1] = v.list[1] and v.list[1].fp or ""
        local keys = {}
        for k, l in pairs(v.recent or {}) do keys[#keys + 1] = k .. "=" .. #l end
        table.sort(keys)
        parts[#parts + 1] = table.concat(keys, ";")
        return table.concat(parts, ",")
    end,
}, computeYear)

-- Yearly target + books read elsewhere: Bookshelf's Reading goals settings,
-- read (and written, from this card's settings) under the same keys, so
-- changing the goal in either place changes both.
local KEY_YEARLY = "micromodule_reading_goal_yearly"
local KEY_OTHER  = "micromodule_reading_goal_other_books"

local function bsStore()
    local ok, S = pcall(require, "lib/bookshelf_settings_store")
    return ok and S or nil
end

function D.yearGoal()
    local S = bsStore()
    local target, other = 24, 0
    if S then
        local ok, v = pcall(S.read, KEY_YEARLY, 24)
        if ok and tonumber(v) then target = max(1, floor(tonumber(v))) end
        local ok2, o = pcall(S.read, KEY_OTHER)
        if ok2 and type(o) == "table" and tonumber(o.year) == os.date("*t").year then
            other = max(0, floor(tonumber(o.n) or 0))
        end
    end
    return target, other
end

function D.setYearGoal(target)
    local S = bsStore()
    if S and tonumber(target) and tonumber(target) > 0 then
        pcall(S.save, KEY_YEARLY, floor(tonumber(target)))
        A.epoch = A.epoch + 1
    end
end

function D.setOtherBooks(n)
    local S = bsStore()
    if S and tonumber(n) and tonumber(n) >= 0 then
        pcall(S.save, KEY_OTHER, { year = os.date("*t").year, n = floor(tonumber(n)) })
        A.epoch = A.epoch + 1
    end
end

-- Daily minutes target, also shared with the Reading goals card.
function D.dailyMinutesGoal()
    local S = bsStore()
    if S then
        local ok, v = pcall(S.read, "micromodule_reading_goal_daily", 30)
        if ok and tonumber(v) then return max(1, floor(tonumber(v))) end
    end
    return 30
end

-- ─── reading statistics ──────────────────────────────────────────────────────

-- Thirteen months, so the Monthly page can go back a year.
local WINDOW_DAYS = 400

local function statsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

-- First day of the week, 1 = Sunday .. 7 = Saturday. Follows the statistics
-- plugin's calendar setting unless overridden in Look and colours.
function D.weekStart()
    local v = tonumber(A.get("week_start"))
    if v and v >= 1 and v <= 7 then return v end
    local st = G_reader_settings and G_reader_settings:readSetting("statistics")
    v = type(st) == "table" and tonumber(st.calendar_start_day_of_week) or nil
    if v and v >= 1 and v <= 7 then return v end
    return 2
end

local function ymdAt(t) return os.date("%Y-%m-%d", t) end

-- The statistics plugin only writes while a book is open, so the file's
-- modification time says whether there is anything new to read. Sitting on
-- the home screen, the per-minute clock redraw then costs one stat() here
-- rather than two scans of the database.
local function statsKey()
    local l = lfs()
    if not l then return os.date("%Y-%m-%d") end
    local path = statsPath()
    -- With write-ahead logging on (KOReader's default where the storage
    -- allows it) new rows land in the -wal file first.
    return table.concat({
        tostring(l.attributes(path, "modification") or 0),
        tostring(l.attributes(path .. "-wal", "modification") or 0),
        tostring(l.attributes(path .. "-wal", "size") or 0),
        os.date("%Y-%m-%d"),
    }, "@")
end

-- ─── real reading days ───────────────────────────────────────────────────────
-- A day only counts as a reading day for a book when something was actually
-- read: at least READ_MIN_SECS seconds or READ_MIN_PAGES different pages.
-- Opening a finished book for a few seconds is not reading it.
local READ_MIN_SECS, READ_MIN_PAGES = 60, 2
D.READ_MIN_SECS, D.READ_MIN_PAGES = READ_MIN_SECS, READ_MIN_PAGES

local SQL_BOOK_DAYS =
    "SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d,"
    .. " sum(duration), count(DISTINCT page), min(start_time)"
    .. " FROM page_stat_data WHERE id_book = ? GROUP BY d ORDER BY d"

-- Opens the statistics database read-only and returns
--   { days(fp) -> list of { ymd=, secs=, pages=, first= } (real reading days,
--                 oldest first; nil when the book isn't in the statistics),
--     all_secs(fp) -> total seconds including token opens,
--     fix(fp, y, m, d) -> corrected y, m, d or nil,
--     close() }
-- or nil without a statistics database.
function D.finishFixer()
    local l = lfs()
    local path = statsPath()
    if not (l and l.attributes(path, "mode") == "file") then return nil end
    local conn, q_id, q_days, broken
    local function open()
        if conn or broken then return conn ~= nil end
        local ok = pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            conn = SQ3.open(path, "ro")
            conn:exec("PRAGMA busy_timeout=200;")
            q_id = conn:prepare("SELECT id FROM book WHERE md5 = ? ORDER BY last_open DESC LIMIT 1")
            q_days = conn:prepare(SQL_BOOK_DAYS)
        end)
        if not ok then
            broken = true
            if conn then pcall(conn.close, conn) end
            conn = nil
        end
        return conn ~= nil
    end
    -- per-book days survive between runs until the statistics change
    local key = statsKey()
    if D._days_key ~= key then D._days_key, D._days_cache = key, {} end
    local cache = D._days_cache
    local F = {}
    local function load(fp)
        local c = cache[fp]
        if c ~= nil then return c end
        c = false
        if not open() then return c end
        pcall(function()
            local md5 = D.bookMd5 and D.bookMd5(fp)
            local row = md5 and q_id:reset():bind(md5):step()
            local id = row and tonumber(row[1])
            if not id then return end
            local real, total = {}, 0
            local r = q_days:reset():bind(id):step()
            while r do
                local secs, pages = tonumber(r[2]) or 0, tonumber(r[3]) or 0
                total = total + secs
                if secs >= READ_MIN_SECS or pages >= READ_MIN_PAGES then
                    real[#real + 1] = { ymd = r[1], secs = secs, pages = pages, first = tonumber(r[4]) }
                end
                r = q_days:step()
            end
            c = { real = real, total = total }
        end)
        cache[fp] = c
        return c
    end
    function F.days(fp) local c = load(fp); return c and c.real or nil end
    function F.all_secs(fp) local c = load(fp); return c and c.total or 0 end
    function F.fix(fp, y, m, d)
        local c = load(fp)
        if not c or #c.real == 0 then return nil end
        local stamped = string.format("%04d-%02d-%02d", y, m, d or 1)
        local last
        for _, day in ipairs(c.real) do
            if day.ymd <= stamped then last = day.ymd else break end
        end
        -- nothing read on or before that date: keep the date as saved
        if not last or last == stamped then return nil end
        local ly, lm, ld = last:match("^(%d+)%-(%d+)%-(%d+)$")
        return tonumber(ly), tonumber(lm), tonumber(ld)
    end
    function F.close()
        if not conn then return end
        pcall(function() q_id:close(); q_days:close() end)
        pcall(conn.close, conn)
        conn = nil
    end
    return F
end


-- Raw read: per-day pages/seconds for the recent window, and the day number
-- of every day with any reading (for streaks).
local function loadStats()
    local l = lfs()
    local path = statsPath()
    if not (l and l.attributes(path, "mode") == "file") then return false end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path, "ro")
    local days, all_days, hours = {}, {}, {}
    local ok, err = pcall(function()
        conn:exec("PRAGMA busy_timeout=200;")
        -- The recent window, and never less than this year so far (the
        -- year chart adds up every month since January).
        local t = os.date("*t")
        local jan1 = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
        local since = math.min(os.time() - WINDOW_DAYS * 86400, jan1)
        -- Same shape as the statistics plugin's own per-day query (page_stat
        -- rescales pages to the book's current pagination); falls back to
        -- the raw table on a database old enough not to have the view.
        local function window(tbl)
            local stmt = conn:prepare(
                "SELECT dates, count(*), sum(sum_duration) FROM ("
                .. " SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS dates,"
                .. " sum(duration) AS sum_duration FROM " .. tbl
                .. " WHERE start_time >= ? GROUP BY id_book, page, dates)"
                .. " GROUP BY dates ORDER BY dates")
            local row = stmt:reset():bind(since):step()
            while row do
                days[row[1]] = { pages = tonumber(row[2]) or 0, secs = tonumber(row[3]) or 0 }
                row = stmt:step()
            end
            stmt:close()
        end
        if not pcall(window, "page_stat") then
            days = {}
            window("page_stat_data")
        end
        local stmt = conn:prepare(
            "SELECT DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')"
            .. " FROM page_stat_data ORDER BY 1")
        local row = stmt:step()
        while row do
            all_days[#all_days + 1] = row[1]
            row = stmt:step()
        end
        stmt:close()
        -- The time of day the reading happened, hour by hour, for every day
        -- in the window (the When you read card adds up whichever span it shows).
        stmt = conn:prepare(
            "SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'),"
            .. " CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)"
            .. " FROM page_stat_data WHERE start_time >= ? GROUP BY 1, 2")
        row = stmt:reset():bind(since):step()
        while row do
            local d, hr, secs = row[1], tonumber(row[2]), tonumber(row[3]) or 0
            if d and hr and hr >= 0 and hr <= 23 then
                local rec = hours[d]
                if not rec then rec = {}; hours[d] = rec end
                rec[hr] = (rec[hr] or 0) + secs
            end
            row = stmt:step()
        end
        stmt:close()
    end)
    conn:close()
    if not ok then error(err) end
    local nums = {}
    for _, d in ipairs(all_days) do
        local y, m, dd = A.parseYmd(d)
        if y then nums[#nums + 1] = A.dayNumber(y, m, dd) end
    end
    return { days = days, nums = nums, hours = hours }
end

local rawStats = deferred("stats", {
    ttl = 900, key = statsKey,
    sig = function(v)
        local last = v.nums[#v.nums] or 0
        local today = v.days[os.date("%Y-%m-%d")]
        return table.concat({ #v.nums, last, today and today.pages or 0, today and today.secs or 0 }, ",")
    end,
}, loadStats)

-- Today, this week and the streaks, worked out from the raw read.
local function deriveStats(raw)
    local days, nums = raw.days, raw.nums
    local t = os.date("*t")
    local today_n = A.dayNumber(t.year, t.month, t.day)
    local best, run = 0, 0
    for i, n in ipairs(nums) do
        if i > 1 and n == nums[i - 1] + 1 then run = run + 1 else run = 1 end
        if run > best then best = run end
    end
    local streak = 0
    if #nums > 0 and (nums[#nums] == today_n or nums[#nums] == today_n - 1) then
        streak = 1
        for i = #nums - 1, 1, -1 do
            if nums[i] == nums[i + 1] - 1 then streak = streak + 1 else break end
        end
    end
    local ws = D.weekStart()
    local back = (t.wday - ws) % 7
    local week = {}
    local wp, wsx = 0, 0
    for i = 0, 6 do
        local dt = os.time{ year = t.year, month = t.month, day = t.day - back + i, hour = 12 }
        local key = ymdAt(dt)
        local rec = days[key] or { pages = 0, secs = 0 }
        week[i + 1] = { key = key, pages = rec.pages, secs = rec.secs,
            wday = tonumber(os.date("%w", dt)) + 1, today = (i == back), future = (i > back) }
        wp, wsx = wp + rec.pages, wsx + rec.secs
    end
    local today = days[ymdAt(os.time())] or { pages = 0, secs = 0 }
    -- this year, month by month
    local month_pages, month_secs = {}, {}
    for m = 1, 12 do month_pages[m], month_secs[m] = 0, 0 end
    local prefix = string.format("%04d-", t.year)
    for key, rec in pairs(days) do
        if key:sub(1, 5) == prefix then
            local m = tonumber(key:sub(6, 7))
            if m and month_pages[m] then
                month_pages[m] = month_pages[m] + (rec.pages or 0)
                month_secs[m] = month_secs[m] + (rec.secs or 0)
            end
        end
    end
    -- the hour of day the reading happened: this month, the last 30 days, this year
    local hours = { month = {}, days30 = {}, year = {} }
    for _, k in pairs(hours) do for hr = 0, 23 do k[hr] = 0 end end
    local month_prefix = string.format("%04d-%02d-", t.year, t.month)
    local cut30 = ymdAt(os.time{ year = t.year, month = t.month, day = t.day - 29, hour = 12 })
    for key, rec in pairs(raw.hours or {}) do
        local in_year = key:sub(1, 5) == prefix
        local in_month = key:sub(1, 8) == month_prefix
        local in_30 = key >= cut30
        for hr, secs in pairs(rec) do
            if in_year then hours.year[hr] = hours.year[hr] + secs end
            if in_month then hours.month[hr] = hours.month[hr] + secs end
            if in_30 then hours.days30[hr] = hours.days30[hr] + secs end
        end
    end
    return {
        days = days, today = today, streak = streak, best = best,
        week = week, week_pages = wp, week_secs = wsx,
        month_pages = month_pages, month_secs = month_secs,
        hours = hours, hours_by_day = raw.hours or {},
    }
end

local _derived
--- Reading figures: a table, false (no statistics database) or nil (loading).
function D.stats(refresh, sync)
    local raw = rawStats(refresh, sync)
    if not raw then return raw end
    local stamp = os.date("%Y-%m-%d") .. ":" .. tostring(D.weekStart())
    if not (_derived and _derived.raw == raw and _derived.stamp == stamp) then
        _derived = { raw = raw, stamp = stamp, value = deriveStats(raw) }
    end
    return _derived.value
end

-- ─── any one month ───────────────────────────────────────────────────────────

--- The books finished in month m of year y (newest first), from the twelve
--- months the Monthly page can show. nil while loading.
function D.finishedIn(refresh, y, m)
    local yr = D.year(refresh)
    if not yr then return nil end
    return (yr.recent or {})[ymKey(y, m)] or {}
end

--- A month's reading from the statistics: days in it, the days so far (all
--- of them for a past month), pages and seconds per day, the totals, and the
--- seconds read in each hour of the day.
function D.monthStats(st, y, m)
    local now = os.date("*t")
    local n_days = tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0, hour = 12 })) or 30
    local current = (y == now.year and m == now.month)
    local out = { year = y, month = m, n_days = n_days, current = current,
        elapsed = current and min(now.day, n_days) or n_days, days = {}, pages = 0, secs = 0, hours = {} }
    for hr = 0, 23 do out.hours[hr] = 0 end
    if type(st) ~= "table" then return out end
    local prefix = ymKey(y, m) .. "-"
    for d = 1, n_days do
        local rec = st.days and st.days[prefix .. string.format("%02d", d)]
        if rec then
            out.days[d] = rec
            out.pages, out.secs = out.pages + (rec.pages or 0), out.secs + (rec.secs or 0)
        end
    end
    for key, rec in pairs(st.hours_by_day or {}) do
        if key:sub(1, 8) == prefix then
            for hr, secs in pairs(rec) do out.hours[hr] = out.hours[hr] + secs end
        end
    end
    return out
end

-- ─── how long each finished book took ───────────────────────────────────────
-- For every book finished this year: the reading time KOReader's statistics
-- recorded for it, the days it was read on, and how many calendar days it
-- took from the first session to the day it was marked finished. One pass
-- over the database for the whole list. Books are matched the way the
-- statistics plugin matches them: by the partial MD5 kept in the sidecar
-- (worked out from the file when the sidecar lacks it); when one MD5 has two
-- rows, the one opened last is the one being read into.

local _md5_cache = {}
local function bookMd5(fp)
    if _md5_cache[fp] then return _md5_cache[fp] end
    local md5
    pcall(function()
        md5 = require("docsettings"):open(fp):readSetting("partial_md5_checksum")
    end)
    if not md5 then
        pcall(function() md5 = require("util").partialMD5(fp) end)
    end
    _md5_cache[fp] = md5
    return md5
end

D.bookMd5 = bookMd5

local function computeLengths()
    local yr = D.year(nil, true)
    -- this year's books and the twelve months before
    local list, seen = {}, {}
    for _, it in ipairs(yr and yr.list or {}) do seen[it.fp] = true; list[#list + 1] = it end
    for _, l in pairs(yr and yr.recent or {}) do
        for _, it in ipairs(l) do
            if not seen[it.fp] then seen[it.fp] = true; list[#list + 1] = it end
        end
    end
    local F = D.finishFixer()
    if not F then return false end
    local out = {}
    local ok, err = pcall(function()
        for _, it in ipairs(list) do
            local days = F.days(it.fp)
            if days then
                -- the reading up to the (corrected) finish day; token opens
                -- and any rereading afterwards don't stretch the book
                local end_ymd = string.format("%04d-%02d-%02d", it.year or yr.year, it.month, it.day or 1)
                local secs, read_days, first = 0, 0, nil
                for _, day in ipairs(days) do
                    if day.ymd <= end_ymd then
                        secs = secs + day.secs
                        read_days = read_days + 1
                        first = first or day.first
                    end
                end
                if read_days == 0 then
                    -- all of it after the saved date: count everything, as before
                    secs = F.all_secs(it.fp)
                    read_days = #days
                    first = days[1] and days[1].first
                end
                local span
                if first then
                    local ft = os.date("*t", first)
                    local start_n = A.dayNumber(ft.year, ft.month, ft.day)
                    local end_n = A.dayNumber(it.year or yr.year, it.month, it.day or 1)
                    span = max(1, end_n - start_n + 1)
                end
                out[it.fp] = { secs = secs, read_days = read_days, span = span or read_days }
            end
        end
    end)
    F.close()
    if not ok then error(err) end
    return out
end

local rawLengths = deferred("lengths", {
    ttl = 900,
    key = function() return statsKey() .. "|" .. A.epoch end,
    sig = function(v)
        local n, secs = 0, 0
        for _, rec in pairs(v) do n = n + 1; secs = secs + (rec.secs or 0) end
        return n .. ":" .. secs
    end,
}, computeLengths)

--- The books finished this year (or, with month, in that month: of `year`,
--- this year when nil), each with secs / span / read_days, longest first by
--- `by` ("time" or "days"). nil while loading, false without a statistics
--- database.
function D.longest(refresh, month, by, year)
    local yr = D.year(refresh)
    if not yr then return nil end
    local lengths = rawLengths(refresh)
    if lengths == nil then return nil end
    if lengths == false then return false end
    local rows = {}
    local src = yr.list or {}
    if month then src = (yr.recent or {})[ymKey(year or yr.year, month)] or {} end
    for _, it in ipairs(src) do
        local rec = lengths[it.fp]
        if rec and (rec.secs > 0 or (rec.span or 0) > 0) then
            rows[#rows + 1] = { fp = it.fp, title = it.title, author = it.author, month = it.month, day = it.day,
                secs = rec.secs, span = rec.span or 0, read_days = rec.read_days }
        end
    end
    local function key(r) if by == "days" then return r.span, r.secs end return r.secs, r.span end
    table.sort(rows, function(a, b)
        local a1, a2 = key(a)
        local b1, b2 = key(b)
        if a1 ~= b1 then return a1 > b1 end
        if a2 ~= b2 then return a2 > b2 end
        return (a.title or "") < (b.title or "")
    end)
    return rows
end

-- ─── when each book in progress was started ─────────────────────────────────
-- The first session the statistics recorded for each book on the Continue
-- reading list, and the reading time recorded for it so far, so the card can
-- say "4 days of reading, 2 h 14 m".

local STARTED_LIST = 10

local function readingKey()
    local fps = {}
    for _, it in ipairs(D.reading(STARTED_LIST)) do fps[#fps + 1] = it.fp end
    return table.concat(fps, "\n")
end

local function computeStarted()
    local l = lfs()
    local path = statsPath()
    if not (l and l.attributes(path, "mode") == "file") then return false end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path, "ro")
    local out = {}
    local ok, err = pcall(function()
        conn:exec("PRAGMA busy_timeout=200;")
        local q_id = conn:prepare("SELECT id FROM book WHERE md5 = ? ORDER BY last_open DESC LIMIT 1")
        local q_first = conn:prepare("SELECT min(start_time), sum(duration) FROM page_stat_data WHERE id_book = ?")
        for _, it in ipairs(D.reading(STARTED_LIST)) do
            local md5 = bookMd5(it.fp)
            local row = md5 and q_id:reset():bind(md5):step()
            local id = row and tonumber(row[1])
            local r = id and q_first:reset():bind(id):step()
            local first = r and tonumber(r[1])
            if first then out[it.fp] = { first = first, secs = tonumber(r[2]) or 0 } end
        end
        q_id:close(); q_first:close()
    end)
    conn:close()
    if not ok then error(err) end
    return out
end

local rawStarted = deferred("started", {
    ttl = 900,
    key = function() return statsKey() .. "|" .. readingKey() end,
    sig = function(v)
        local parts = {}
        for fp, t in pairs(v) do parts[#parts + 1] = fp .. "=" .. t.first .. ":" .. t.secs end
        table.sort(parts)
        return table.concat(parts, ",")
    end,
}, computeStarted)

--- How many days this book has been on the go (1 = started today), when it
--- was started, and the seconds spent reading it so far. nil when the
--- statistics have no session for it (or are still loading).
function D.dayOfBook(refresh, fp)
    local v = rawStarted(refresh)
    local rec = type(v) == "table" and v[fp]
    if not rec then return nil end
    local ft, t = os.date("*t", rec.first), os.date("*t")
    local n = A.dayNumber(t.year, t.month, t.day) - A.dayNumber(ft.year, ft.month, ft.day) + 1
    return max(1, n), rec.first, rec.secs
end

-- ─── collections ─────────────────────────────────────────────────────────────

function D.collections()
    local ok, RC = pcall(require, "readcollection")
    if not (ok and RC and type(RC.coll) == "table") then return {} end
    local names = {}
    for name in pairs(RC.coll) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names, RC.default_collection_name
end

function D.collectionLabel(name)
    local ok, RC = pcall(require, "readcollection")
    if ok and RC and name == RC.default_collection_name then return "Favorites" end
    return name
end

-- Files of a collection in the reader's own order.
function D.collection(name)
    local ok, RC = pcall(require, "readcollection")
    if not (ok and RC and type(RC.coll) == "table" and type(RC.coll[name]) == "table") then return nil end
    local items = {}
    for fp, item in pairs(RC.coll[name]) do
        items[#items + 1] = { fp = fp, order = type(item) == "table" and tonumber(item.order) or 0 }
    end
    table.sort(items, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.fp < b.fp
    end)
    local out = {}
    for _, it in ipairs(items) do out[#out + 1] = it.fp end
    return out
end

function D.inCollection(name, fp)
    local ok, RC = pcall(require, "readcollection")
    if not (ok and RC and type(RC.coll) == "table" and type(RC.coll[name]) == "table") then return false end
    return RC.coll[name][fp] ~= nil
end

-- ─── covers ──────────────────────────────────────────────────────────────────
-- Scaled covers are kept here, keyed by file and size, so a redraw does not
-- go back to the database. The cache only ever DROPS its reference to an old
-- cover (never frees it): a card still on screen may be holding that bitmap,
-- and Blitbuffer frees the memory itself once nothing refers to it. Same
-- policy as Bookshelf's own scaled-cover cache.

local _covers, _cover_order, _cover_bytes = {}, {}, 0
local COVER_BUDGET = 12 * 1024 * 1024
local _cover_miss = {}

local function bbBytes(bb)
    local ok, n = pcall(function() return tonumber(bb.stride) * bb:getHeight() end)
    return ok and n or 0
end

local function fetchCover(fp)
    local info = D.info(fp)
    local l = lfs()
    if info.cover_path and l and l.attributes(info.cover_path, "mode") == "file" then
        local ok, bb = pcall(function()
            return require("ui/renderimage"):renderImageFile(info.cover_path, false)
        end)
        if ok and bb then return bb end
    end
    local Repo = repo()
    if Repo and Repo.getCoverBB then
        local ok, bb = pcall(Repo.getCoverBB, fp)
        if ok and bb then return bb end
    end
    return nil
end

--- A bitmap at least w x h, scaled so the cover fills that box (the caller
--- crops the overhang). nil when the book has no cover.
function D.cover(fp, w, h)
    if type(fp) ~= "string" or w < 2 or h < 2 then return nil end
    local key = fp .. "\0" .. w .. "x" .. h
    local hit = _covers[key]
    if hit then return hit end
    local miss = _cover_miss[fp]
    if miss and os.time() - miss < 120 then return nil end
    local src = fetchCover(fp)
    if not src then
        _cover_miss[fp] = os.time()
        return nil
    end
    local ok, scaled = pcall(function()
        local sw, sh = src:getWidth(), src:getHeight()
        local k = max(w / sw, h / sh)
        local tw, th = max(w, floor(sw * k + 0.5)), max(h, floor(sh * k + 0.5))
        return require("ui/renderimage"):scaleBlitBuffer(src, tw, th)
    end)
    if not ok or not scaled then
        _cover_miss[fp] = os.time()
        return nil
    end
    _covers[key] = scaled
    _cover_order[#_cover_order + 1] = key
    _cover_bytes = _cover_bytes + bbBytes(scaled)
    while _cover_bytes > COVER_BUDGET and #_cover_order > 1 do
        local old = table.remove(_cover_order, 1)
        local bb = _covers[old]
        if bb then _cover_bytes = _cover_bytes - bbBytes(bb) end
        _covers[old] = nil
    end
    return scaled
end

-- ─── actions ─────────────────────────────────────────────────────────────────

function D.openBook(ctx, fp)
    if not D.fileExists(fp) then
        pcall(function()
            require("ui/uimanager"):show(require("ui/widget/notification"):new{
                text = "That file is no longer on the device",
            })
        end)
        return
    end
    local bw = ctx and ctx.bw
    if bw and type(bw._openBook) == "function" then
        bw:_openBook({ filepath = fp })
    else
        require("apps/reader/readerui"):showReader(fp)
    end
end

function D.showDetails(ctx, fp)
    local bw = ctx and ctx.bw
    local Repo = repo()
    if bw and type(bw._showBookDetail) == "function" and Repo and Repo.buildBook then
        local ok, book = pcall(Repo.buildBook, fp)
        if ok and book then
            bw:_showBookDetail(book)
            return
        end
    end
    D.openBook(ctx, fp)
end

-- Run a KOReader action by its dispatcher name.
function D.dispatch(name)
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher then pcall(Dispatcher.execute, Dispatcher, { [name] = true }) end
end

-- Is a plugin with this name loaded? (FileManager or Reader instance.)
function D.hasPlugin(name)
    for _, mod in ipairs{ "apps/filemanager/filemanager", "apps/reader/readerui" } do
        local ok, UI = pcall(require, mod)
        if ok and UI and UI.instance and UI.instance[name] then return true end
    end
    return false
end

return D
