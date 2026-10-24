--[[
Critter remarks: SimpleUI 3.0's Tiny Critter peeks into each Dashboard page
and says something about that page's numbers ("3 books ahead of your goal
pace.", "47 unread books waiting.").

  * The critter, its moods and its speech bubble are SimpleUI's own (the
    critter you picked for the home screen, its bubble style, its text
    sizes and its mood), borrowed from simpleui.koplugin/modules/critter.
    Without SimpleUI 3.0's Tiny Critter none of this shows.
  * Each page keeps its remark for the day (redraws, the per-minute clock and
    turning back to the page keep it, with its numbers kept current). Tap the
    critter for another one. Remarks are dealt like the critter's own phrases:
    none comes round again before the others on that page have been seen.
  * Nothing moves and nothing runs on a timer.

Settings > Critter Remarks turns it off (stored as critter_peek).
]]

local A = ...
local D = A.D

local floor, max, min = math.floor, math.max, math.min

local C = {}
A.critter = C

local SUI_PREFIX = "simpleui_hs_"
local DECK_KEY = "readinglog_critter_deck_"

local function sui(name)
    local m = package.loaded[name]
    if m ~= nil then return m end
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

-- SimpleUI 3.0's critter files, or nil without them.
local function kit()
    local Sprite, Bubble, Assets = sui("modules/critter/sprite"), sui("modules/critter/bubble"), sui("modules/critter/assets")
    if type(Sprite) ~= "table" or type(Bubble) ~= "table" or type(Assets) ~= "table"
            or type(Bubble.build) ~= "function" or type(Assets.get) ~= "function" then
        return nil
    end
    return { Sprite = Sprite, Bubble = Bubble, Assets = Assets,
             Mood = sui("modules/critter/mood"), Store = sui("infra/sui_store"),
             Style = sui("features/sui_style"), Config = sui("infra/sui_config"),
             Deck = sui("infra/sui_deck") }
end

function C.available() return kit() ~= nil end
function C.enabled() return A.get("critter_peek", true) ~= false and C.available() end

-- ─── facts ───────────────────────────────────────────────────────────────────

local function n_(n, one, many) return A.plural(n, one, many) end
local suggestions, questFacts   -- below

local function mins(secs) return floor((secs or 0) / 60 + 0.5) end

local function short(s, n)
    s = tostring(s or "")
    n = n or 28
    if #s <= n then return s end
    return s:sub(1, n - 1):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "\xE2\x80\xA6"
end

local function q(s) return "\xE2\x80\x9C" .. short(s) .. "\xE2\x80\x9D" end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

local function hourText(hr)
    local h12 = hr % 12 == 0 and 12 or hr % 12
    return string.format("%d %s", h12, hr < 12 and "AM" or "PM")
end

-- ─── suggestions: books worth opening, worked out from the stats ─────────────
-- From the library (finished books' authors, series and genres; books on
-- hold; an unread pick) and from the books in progress (one that could be
-- done tonight; how much sooner a little more a day would finish one).
-- The library part is worked out once a day (and when the library changes);
-- the book chosen for each stays the same all day.

local function dayIndex(list, salt)
    if #list == 0 then return nil end
    local n = tonumber(os.date("%j")) or 1
    for i = 1, #salt do n = n + salt:byte(i) end
    return list[n % #list + 1]
end

local function tally(books, field)
    local t, order = {}, {}
    for _, b in ipairs(books) do
        if b.status == "finished" then
            for _, v in ipairs(b[field] or {}) do
                local k = v:lower()
                if not t[k] then t[k] = { name = v, n = 0 }; order[#order + 1] = k end
                t[k].n = t[k].n + 1
            end
        end
    end
    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = t[k] end
    table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    return out
end

local function librarySuggestions(lib)
    local books = lib.books or {}
    local sug = {}
    -- an author you finish, with a book of theirs not started yet
    for _, a in ipairs(tally(books, "authors")) do
        local cands = D.pickCandidates(books, { authors = { a.name } })
        if #cands > 0 then
            sug.author = { name = a.name, n = a.n, book = dayIndex(cands, "author" .. a.name) }
            break
        end
    end
    -- the next book of a series you've finished a book of
    local done_series = {}
    for _, b in ipairs(books) do
        if b.status == "finished" and b.series then done_series[b.series:lower()] = b.series end
    end
    local next_in = {}
    for _, c in ipairs(D.pickCandidates(books, {})) do
        if c.series and done_series[c.series:lower()] then next_in[#next_in + 1] = c end
    end
    if #next_in > 0 then
        local b = dayIndex(next_in, "series")
        sug.series = { name = b.series, num = b.num, book = b }
    end
    -- a genre you finish, with a book in it not started yet
    for _, g in ipairs(tally(books, "genres")) do
        if g.n >= 2 then
            local cands = D.pickCandidates(books, { genres = { g.name } })
            if #cands > 0 then
                sug.genre = { name = g.name, n = g.n, book = dayIndex(cands, "genre" .. g.name) }
                break
            end
        end
    end
    -- a book on hold
    local held = {}
    for _, b in ipairs(books) do if b.status == "on_hold" then held[#held + 1] = b end end
    if #held > 0 then
        local b = dayIndex(held, "hold")
        local pct = D.progress(b.fp)
        sug.hold = { book = b, pct = tonumber(pct) }
    end
    -- anything not started yet
    local any = D.pickCandidates(books, {})
    if #any > 0 then sug.pick = { book = dayIndex(any, "pick") } end
    return sug
end

suggestions = function(f)
    if f.lib and f.lib.books then
        local key = os.date("%Y-%m-%d") .. "|" .. f.lib.total .. "|" .. (f.lib.counts.finished or 0)
            .. "|" .. (f.lib.counts.on_hold or 0)
        local c = A.state.critter_sug
        if not (c and c.key == key) then
            local ok, v = pcall(librarySuggestions, f.lib)
            c = { key = key, value = ok and v or {} }
            A.state.critter_sug = c
        end
        f.sug = c.value
    else
        f.sug = {}
    end
    -- from the books in progress and your usual day
    local avg_min = f.avg_secs and f.avg_secs / 60 or nil
    for _, b in ipairs(f.reading or {}) do
        if b.left_min and b.left_min > 0 and avg_min and avg_min >= 5 then
            if not f.sug.tonight and b.left_min <= avg_min * 1.5 then
                f.sug.tonight = { book = b, left = b.left_min, usual = avg_min }
            end
            if not f.sug.boost then
                local now_days = math.ceil(b.left_min / avg_min)
                local more_days = math.ceil(b.left_min / (avg_min + 10))
                if now_days - more_days >= 2 then
                    f.sug.boost = { book = b, now_days = now_days, more_days = more_days }
                end
            end
        end
    end
end

-- ReadMastery quests (ReadMastery Quests patch 1.0.6+, Quests (Enhanced) on):
-- today's daily quests still open, and a "finish N books" quest one book short
-- near the end of its week or month.
questFacts = function(f)
    local Q = rawget(_G, "ReadMasteryQuests")
    if type(Q) ~= "table" or type(Q.enabled) ~= "function" or not Q.enabled() then return end
    if type(Q.daily) == "function" then
        local ok, list = pcall(Q.daily)
        if ok and type(list) == "table" then
            for i = #list, 1, -1 do
                local q = list[i]
                if not q.done then f.quest_daily = q break end
            end
        end
    end
    if type(Q.open) == "function" then
        local ok, list = pcall(Q.open)
        if ok and type(list) == "table" then
            for _, q in ipairs(list) do
                local window = ({ weekly = 2, monthly = 5 })[q.period]
                if q.type == "books_finished" and q.need - q.have == 1 and window and q.days_left <= window then
                    f.quest_book = q
                    break
                end
            end
        end
    end
end

-- Everything the remarks read, gathered once per build. Missing pieces stay nil.
local function facts(refresh)
    local f = { t = os.date("*t") }
    local t = f.t
    local ok_st, st = pcall(D.stats, refresh)
    if ok_st and type(st) == "table" then
        f.st = st
        f.today_secs, f.today_pages = st.today.secs or 0, st.today.pages or 0
        f.streak, f.best = st.streak or 0, st.best or 0
        local ok_avg, avg = pcall(D.recentAverage, st)
        if ok_avg and avg then f.avg_secs, f.avg_pages = avg.secs, avg.pages end
        -- last week, the same days so far as this week
        local lw_pages, tw_pages = 0, st.week_pages or 0
        for i = 1, 7 do
            local d = st.week[i]
            local y, m, dd = A.parseYmd(d and d.key)
            if y and not d.future then
                local key = os.date("%Y-%m-%d", os.time{ year = y, month = m, day = dd - 7, hour = 12 })
                local rec = st.days[key]
                lw_pages = lw_pages + (rec and rec.pages or 0)
            end
        end
        f.week_pages, f.last_week_pages = tw_pages, lw_pages
        -- months of this year
        local best_m, best_p, done_m, sum_p = nil, 0, 0, 0
        for m = 1, t.month - 1 do
            local p = st.month_pages[m] or 0
            if p > best_p then best_m, best_p = m, p end
            if p > 0 then done_m, sum_p = done_m + 1, sum_p + p end
        end
        f.month_pages = st.month_pages[t.month] or 0
        f.best_month, f.best_month_pages = best_m, best_p
        f.month_avg = done_m > 0 and sum_p / done_m or nil
        f.prev_month_pages = t.month > 1 and (st.month_pages[t.month - 1] or 0) or nil
        -- favourite hour over the last 30 days
        local top_hr, top_s, total = nil, 0, 0
        for hr = 0, 23 do
            local s = st.hours and st.hours.days30 and st.hours.days30[hr] or 0
            total = total + s
            if s > top_s then top_hr, top_s = hr, s end
        end
        if total > 3600 then f.fav_hour, f.fav_share = top_hr, top_s / total end
    end
    local ok_goal, goal_min = pcall(D.dailyMinutesGoal)
    f.goal_min = ok_goal and goal_min or nil
    local ok_yr, yr = pcall(D.year, refresh)
    if ok_yr and type(yr) == "table" then
        local ok_p, pace = pcall(D.yearPace, yr)
        if ok_p and pace then
            f.year_done, f.year_goal, f.year_projected = pace.done, pace.goal, pace.projected
            local doy = tonumber(os.date("%j")) or 1
            local diy = tonumber(os.date("%j", os.time{ year = t.year, month = 12, day = 31, hour = 12 })) or 365
            if pace.goal and pace.goal > 0 then f.year_expected = pace.goal * doy / diy end
        end
        local ok_f, fin = pcall(D.finishedIn, refresh, t.year, t.month)
        if ok_f and type(fin) == "table" then f.month_books = #fin end
    end
    local ok_lib, lib = pcall(D.library, refresh)
    if ok_lib and type(lib) == "table" and lib.counts then f.lib = lib end
    local ok_r, reading = pcall(D.reading, 5)
    if ok_r and type(reading) == "table" then
        f.reading = reading
        local close
        for _, b in ipairs(reading) do
            if (b.pct or 0) >= 0.5 and (not close or b.pct > close.pct) then close = b end
        end
        f.closest = close
    end
    f.days_in_month = tonumber(os.date("%d", os.time{ year = t.year, month = t.month + 1, day = 0, hour = 12 })) or 30
    f.month_left = f.days_in_month - t.day + 1
    pcall(suggestions, f)
    pcall(questFacts, f)
    return f
end

-- ─── remarks ─────────────────────────────────────────────────────────────────
-- { id, when(f), mood, text(f), sub(f)? }, by page kind. A page's pool is
-- what fits right now; one is dealt per day.

local R = {}

R.today = {
    { id = "t_goal_done", mood = "party",
      when = function(f) return f.goal_min and f.today_secs and mins(f.today_secs) >= f.goal_min end,
      text = function() return "Daily goal done." end,
      sub = function(f) return string.format("%s today. Anything now is a bonus.", A.fmtMinutes(mins(f.today_secs))) end },
    { id = "t_goal_near", mood = "cheer",
      when = function(f) return f.goal_min and f.today_secs and f.today_secs > 0 and mins(f.today_secs) < f.goal_min end,
      text = function(f) return string.format("%s to your daily goal.", A.fmtMinutes(f.goal_min - mins(f.today_secs))) end,
      sub = function() return "One more chapter should do it." end },
    { id = "t_above_usual", mood = "surprised",
      when = function(f) return f.avg_secs and f.avg_secs > 300 and (f.today_secs or 0) > 1.5 * f.avg_secs end,
      text = function(f) return string.format("%s today.", A.fmtMinutes(mins(f.today_secs))) end,
      sub = function(f) return string.format("Your usual is %s. Who are you?", A.fmtMinutes(mins(f.avg_secs))) end },
    { id = "t_streak_save", mood = "curious",
      when = function(f) return (f.streak or 0) >= 2 and (f.today_secs or 0) == 0 end,
      text = function(f) return string.format("Your %d-day streak needs a page today.", f.streak) end,
      sub = function() return "Just one. I'll wait." end },
    { id = "t_streak_best", mood = "party",
      when = function(f) return (f.streak or 0) >= 3 and f.streak >= (f.best or 0) end,
      text = function(f) return string.format("%d days in a row.", f.streak) end,
      sub = function() return "Your longest streak ever. Keep it going." end },
    { id = "t_streak_near_best", mood = "playful",
      when = function(f) return (f.streak or 0) >= 3 and f.best and f.best > f.streak and f.best - f.streak <= 3 end,
      text = function(f) return string.format("%s to beat your best streak.", n_(f.best - f.streak + 1, "day", "days")) end,
      sub = function(f) return string.format("Best so far: %d days.", f.best) end },
    { id = "t_closest", mood = "curious",
      when = function(f) return f.closest ~= nil end,
      text = function(f) return string.format("%s is %d%% done.", q(f.closest.title), floor(f.closest.pct * 100)) end,
      sub = function(f)
          return f.closest.left_min and string.format("About %s to the end.", A.fmtMinutes(f.closest.left_min))
              or "The end is in sight."
      end },
    { id = "t_week_up", mood = "cheer",
      when = function(f) return f.week_pages and f.last_week_pages and f.last_week_pages > 0 and f.week_pages > f.last_week_pages end,
      text = function(f) return string.format("%s this week.", n_(f.week_pages, "page", "pages")) end,
      sub = function(f) return string.format("%d more than this time last week.", f.week_pages - f.last_week_pages) end },
    { id = "t_quiet", mood = "sleepy",
      when = function(f) return (f.today_secs or 0) == 0 and (f.streak or 0) < 2 end,
      text = function() return "Quiet day so far." end,
      sub = function() return "Even ten minutes counts." end },
}

R.yearly = {
    { id = "y_goal_done", mood = "party",
      when = function(f) return f.year_goal and f.year_done and f.year_done >= f.year_goal end,
      text = function(f) return string.format("%d of %d. Goal reached!", f.year_done, f.year_goal) end,
      sub = function() return "Everything now is extra credit." end },
    { id = "y_ahead", mood = "cheer",
      when = function(f) return f.year_expected and f.year_done and f.year_done < (f.year_goal or 0) and f.year_done - f.year_expected >= 1 end,
      text = function(f) return string.format("%s ahead of your goal pace.", n_(floor(f.year_done - f.year_expected), "book", "books")) end,
      sub = function() return "Smug looks good on you." end },
    { id = "y_behind", mood = "curious",
      when = function(f) return f.year_expected and f.year_done and f.year_expected - f.year_done >= 1 end,
      text = function(f) return string.format("%s behind your goal pace.", n_(floor(f.year_expected - f.year_done + 0.5), "book", "books")) end,
      sub = function(f)
          return f.closest and string.format("Finishing %s would help.", q(f.closest.title)) or "A short one would catch you up."
      end },
    { id = "y_projected", mood = "happy",
      when = function(f) return f.year_projected and f.year_projected > 0 end,
      text = function(f) return string.format("At this rate: %s this year.", n_(f.year_projected, "book", "books")) end,
      sub = function(f) return f.year_goal and string.format("Your goal is %d.", f.year_goal) or nil end },
    { id = "y_best_month", mood = "love",
      when = function(f) return f.best_month ~= nil and f.best_month_pages > 0 end,
      text = function(f) return string.format("%s is your best month so far.", MONTHS[f.best_month]) end,
      sub = function(f) return string.format("%s read.", n_(f.best_month_pages, "page", "pages")) end },
    { id = "y_this_month_top", mood = "party",
      when = function(f) return f.best_month_pages and f.month_pages > f.best_month_pages and f.best_month_pages > 0 end,
      text = function(f) return string.format("%s is beating every month this year.", MONTHS[f.t.month]) end,
      sub = function(f) return string.format("%s and counting.", n_(f.month_pages, "page", "pages")) end },
}

R.monthly = {
    { id = "m_books", mood = "cheer",
      when = function(f) return (f.month_books or 0) > 0 end,
      text = function(f) return string.format("%s finished in %s.", n_(f.month_books, "book", "books"), MONTHS[f.t.month]) end,
      sub = function(f) return string.format("%s left in the month.", n_(f.month_left, "day", "days")) end },
    { id = "m_vs_last", mood = "happy",
      when = function(f) return f.prev_month_pages and f.prev_month_pages > 0 and f.month_pages > f.prev_month_pages end,
      text = function(f) return string.format("Already past %s.", MONTHS[f.t.month == 1 and 12 or f.t.month - 1]) end,
      sub = function(f) return string.format("%d pages more, with %s to go.", f.month_pages - f.prev_month_pages, n_(f.month_left, "day", "days")) end },
    { id = "m_vs_avg", mood = "curious",
      when = function(f) return f.month_avg and f.month_pages < f.month_avg and f.month_left <= 10 end,
      text = function(f) return string.format("%d pages to an average month.", floor(f.month_avg - f.month_pages + 0.5)) end,
      sub = function(f) return string.format("%s left. Doable.", n_(f.month_left, "day", "days")) end },
    { id = "m_end_book", mood = "playful",
      when = function(f) return f.month_left <= 5 and f.closest ~= nil end,
      text = function(f) return string.format("%s left in %s.", n_(f.month_left, "day", "days"), MONTHS[f.t.month]) end,
      sub = function(f) return string.format("Finish %s before it's over?", q(f.closest.title)) end },
    { id = "m_pages", mood = "happy",
      when = function(f) return (f.month_pages or 0) > 0 end,
      text = function(f) return string.format("%s so far this month.", n_(f.month_pages, "page", "pages")) end,
      sub = function(f) return f.days_in_month and string.format("Day %d of %d.", f.t.day, f.days_in_month) or nil end },
}

R.trends = {
    { id = "r_streak_best", mood = "party",
      when = function(f) return (f.streak or 0) >= 3 and f.streak >= (f.best or 0) end,
      text = function(f) return string.format("A %d-day streak. Your best yet.", f.streak) end,
      sub = function() return "Every day is a new record now." end },
    { id = "r_streak_gap", mood = "playful",
      when = function(f) return (f.streak or 0) >= 1 and f.best and f.best > f.streak end,
      text = function(f) return string.format("%s to beat your best of %d.", n_(f.best - f.streak + 1, "day", "days"), f.best) end,
      sub = function() return "No pressure. Some pressure." end },
    { id = "r_fav_hour", mood = "curious",
      when = function(f) return f.fav_hour ~= nil end,
      text = function(f) return string.format("You read most around %s.", hourText(f.fav_hour)) end,
      sub = function(f) return string.format("%d%% of the last 30 days' reading.", floor(f.fav_share * 100 + 0.5)) end },
    { id = "r_week_trend", mood = "cheer",
      when = function(f) return f.week_pages and f.last_week_pages and f.last_week_pages > 0 end,
      text = function(f)
          local d = f.week_pages - f.last_week_pages
          if d >= 0 then return string.format("Up %s on last week.", n_(d, "page", "pages")) end
          return string.format("Down %s on last week.", n_(-d, "page", "pages"))
      end,
      sub = function(f) return f.week_pages >= f.last_week_pages and "The trend is your friend." or "There's still time to catch up." end },
    { id = "r_avg", mood = "happy",
      when = function(f) return f.avg_pages and f.avg_pages >= 1 end,
      text = function(f) return string.format("About %d pages a day lately.", floor(f.avg_pages + 0.5)) end,
      sub = function(f) return f.avg_secs and string.format("Roughly %s a day.", A.fmtMinutes(mins(f.avg_secs))) or nil end },
}

R.library = {
    { id = "l_unread", mood = "curious",
      when = function(f) return f.lib and (f.lib.counts.unread or 0) > 0 end,
      text = function(f) return string.format("%s waiting to be opened.", n_(f.lib.counts.unread, "book", "books")) end,
      sub = function() return "They can hear you, you know." end },
    { id = "l_share", mood = "happy",
      when = function(f) return f.lib and f.lib.total > 0 and (f.lib.counts.finished or 0) > 0 end,
      text = function(f) return string.format("%d%% of your library read.", floor(100 * f.lib.counts.finished / f.lib.total + 0.5)) end,
      sub = function(f) return string.format("%d of %d.", f.lib.counts.finished, f.lib.total) end },
    { id = "l_juggling", mood = "surprised",
      when = function(f) return f.lib and (f.lib.counts.reading or 0) >= 3 end,
      text = function(f) return string.format("%d books on the go at once.", f.lib.counts.reading) end,
      sub = function(f) return f.closest and string.format("%s is closest to done.", q(f.closest.title)) or "Bold." end },
    { id = "l_on_hold", mood = "shy",
      when = function(f) return f.lib and (f.lib.counts.on_hold or 0) > 0 end,
      text = function(f) return string.format("%s on hold.", n_(f.lib.counts.on_hold, "book", "books")) end,
      sub = function() return "Time to pick one back up?" end },
    { id = "l_closest", mood = "cheer",
      when = function(f) return f.closest ~= nil end,
      text = function(f) return string.format("Next to finish: %s.", q(f.closest.title)) end,
      sub = function(f) return string.format("%d%% done already.", floor(f.closest.pct * 100)) end },
}

-- ─── suggestions (remarks with a book: a tap offers to open it) ─────────────
local TAP = "Tap me."
local function bookOf(get) return function(f) local b = get(f); return b and b.fp or nil end end
local S_ = {
    author = { id = "s_author", mood = "love",
        when = function(f) return f.sug and f.sug.author end,
        text = function(f) return string.format("You've finished %s by %s.", n_(f.sug.author.n, "book", "books"), short(f.sug.author.name, 22)) end,
        sub = function(f) return string.format("%s is waiting. %s", q(f.sug.author.book.title), TAP) end,
        fp = bookOf(function(f) return f.sug.author.book end) },
    series = { id = "s_series", mood = "curious",
        when = function(f) return f.sug and f.sug.series end,
        text = function(f) return string.format("Next in %s:", short(f.sug.series.name, 26)) end,
        sub = function(f) return string.format("%s. %s", q(f.sug.series.book.title), TAP) end,
        fp = bookOf(function(f) return f.sug.series.book end) },
    genre = { id = "s_genre", mood = "playful",
        when = function(f) return f.sug and f.sug.genre end,
        text = function(f) return string.format("You keep finishing %s.", short(f.sug.genre.name, 20):lower()) end,
        sub = function(f) return string.format("Try %s? %s", q(f.sug.genre.book.title), TAP) end,
        fp = bookOf(function(f) return f.sug.genre.book end) },
    hold = { id = "s_hold", mood = "shy",
        when = function(f) return f.sug and f.sug.hold end,
        text = function(f) return string.format("Pick %s back up?", q(f.sug.hold.book.title)) end,
        sub = function(f)
            local pct = f.sug.hold.pct
            return (pct and pct > 0) and string.format("You were %d%% in. %s", floor(pct * 100), TAP) or TAP
        end,
        fp = bookOf(function(f) return f.sug.hold.book end) },
    pick = { id = "s_pick", mood = "curious",
        when = function(f) return f.sug and f.sug.pick end,
        text = function() return "Something new?" end,
        sub = function(f) return string.format("%s, never opened. %s", q(f.sug.pick.book.title), TAP) end,
        fp = bookOf(function(f) return f.sug.pick.book end) },
    tonight = { id = "s_tonight", mood = "cheer",
        when = function(f) return f.sug and f.sug.tonight end,
        text = function(f) return string.format("%s could be done today.", q(f.sug.tonight.book.title)) end,
        sub = function(f) return string.format("About %s left. Your usual day is %s.",
            A.fmtMinutes(f.sug.tonight.left), A.fmtMinutes(f.sug.tonight.usual)) end,
        fp = bookOf(function(f) return f.sug.tonight.book end) },
    boost = { id = "s_boost", mood = "curious",
        when = function(f) return f.sug and f.sug.boost end,
        text = function(f) return string.format("10 more minutes a day finishes %s %s sooner.",
            q(f.sug.boost.book.title), n_(f.sug.boost.now_days - f.sug.boost.more_days, "day", "days")) end,
        sub = function(f) return string.format("%s days instead of %d. %s", f.sug.boost.more_days, f.sug.boost.now_days, TAP) end,
        fp = bookOf(function(f) return f.sug.boost.book end) },
    hour = { id = "s_hour", mood = "playful",
        when = function(f) return f.fav_hour and f.t.hour < f.fav_hour and (f.today_secs or 0) < 600 end,
        text = function(f) return string.format("Your best reading time is around %s.", hourText(f.fav_hour)) end,
        sub = function() return "Save a few chapters for it?" end },
    quest_daily = { id = "s_quest_daily", mood = "cheer",
        when = function(f) return f.quest_daily ~= nil end,
        text = function(f)
            local qd = f.quest_daily
            if qd.have > 0 then return string.format("Quest: %s, %d of %d %s.", qd.title, qd.have, qd.need, qd.unit) end
            return string.format("Today's quest: %s.", qd.title)
        end,
        sub = function(f)
            if f.closest then return string.format("%s would do it. %s", q(f.closest.title), TAP) end
            return string.format("+%d XP in it for you.", f.quest_daily.reward_xp or 0)
        end,
        fp = bookOf(function(f) return f.closest end) },
    quest_book = { id = "s_quest_book", mood = "playful",
        when = function(f) return f.quest_book ~= nil and f.closest ~= nil end,
        text = function(f) return string.format("%s needs one more book.", f.quest_book.title) end,
        sub = function(f) return string.format("%s is %d%% done. %s", q(f.closest.title), floor(f.closest.pct * 100), TAP) end,
        fp = bookOf(function(f) return f.closest end) },
}
local function addAll(list, names) for _, n in ipairs(names) do list[#list + 1] = S_[n] end end
addAll(R.today,   { "tonight", "boost", "hour", "hold", "quest_daily" })
addAll(R.yearly,  { "author", "series", "quest_book" })
addAll(R.monthly, { "tonight", "quest_book", "genre" })
addAll(R.trends,  { "boost", "hour", "quest_daily" })
addAll(R.library, { "author", "series", "genre", "hold", "pick" })

-- ─── more ways to say each remark ────────────────────────────────────────────
-- VARIANTS[id]: other wordings of a remark (its own wording above is the
-- first); one is dealt with the remark, so a page's lines don't repeat word
-- for word before every wording has had its turn. TIERS[id][tier]: what a
-- critter in that mood says instead (SimpleUI's mood: grumpy, meh, okay,
-- happy, radiant), like the home screen critter's lines.

local function s(text) return function() return text end end

local VARIANTS = {
    s_author = {
        { mood = "happy", text = function(f) return string.format("More %s?", short(f.sug.author.name, 24)) end,
          sub = function(f) return string.format("%s is on your shelf. %s", q(f.sug.author.book.title), TAP) end },
    },
    s_series = {
        { mood = "playful", text = function(f) return string.format("%s isn't over yet.", short(f.sug.series.name, 26)) end,
          sub = function(f) return string.format("%s is next. %s", q(f.sug.series.book.title), TAP) end },
    },
    s_genre = {
        { mood = "curious", text = function(f) return string.format("Another %s book?", short(f.sug.genre.name, 20):lower()) end,
          sub = function(f) return string.format("%s fits. %s", q(f.sug.genre.book.title), TAP) end },
    },
    s_hold = {
        { mood = "curious", text = function(f) return string.format("%s misses you.", q(f.sug.hold.book.title)) end,
          sub = function() return TAP end },
    },
    s_pick = {
        { mood = "playful", text = function(f) return string.format("Judge %s by its cover?", q(f.sug.pick.book.title)) end,
          sub = function() return TAP end },
    },
    s_tonight = {
        { mood = "party", text = function(f) return string.format("Finish %s today?", q(f.sug.tonight.book.title)) end,
          sub = function(f) return string.format("%s to go. %s", A.fmtMinutes(f.sug.tonight.left), TAP) end },
    },
    s_boost = {
        { mood = "cheer", text = function(f) return string.format("%s in %d days, or %d.", q(f.sug.boost.book.title), f.sug.boost.now_days, f.sug.boost.more_days) end,
          sub = function() return "The second one takes 10 more minutes a day." end },
    },
    t_goal_done = {
        { mood = "cheer", text = s("Goal: done. You: brilliant."),
          sub = function(f) return string.format("%s read today.", A.fmtMinutes(mins(f.today_secs))) end },
        { mood = "love", text = function(f) return string.format("%s today. Goal met.", A.fmtMinutes(mins(f.today_secs))) end,
          sub = s("The rest of the day is yours.") },
    },
    t_goal_near = {
        { mood = "curious", text = function(f) return string.format("Only %s left for today's goal.", A.fmtMinutes(f.goal_min - mins(f.today_secs))) end,
          sub = s("A short sitting would do it.") },
        { mood = "playful", text = function(f) return string.format("%s in. %s to go.", A.fmtMinutes(mins(f.today_secs)), A.fmtMinutes(f.goal_min - mins(f.today_secs))) end,
          sub = s("So close I can taste it.") },
    },
    t_above_usual = {
        { mood = "party", text = s("Big reading day!"),
          sub = function(f) return string.format("%s, against a usual %s.", A.fmtMinutes(mins(f.today_secs)), A.fmtMinutes(mins(f.avg_secs))) end },
        { mood = "cheer", text = function(f) return string.format("%s and counting.", A.fmtMinutes(mins(f.today_secs))) end,
          sub = s("Somebody found a good book.") },
    },
    t_streak_save = {
        { mood = "shy", text = s("Not a page yet today."),
          sub = function(f) return string.format("Your %d-day streak is watching.", f.streak) end },
        { mood = "playful", text = function(f) return string.format("Day %d of the streak is waiting.", f.streak + 1) end,
          sub = s("A page is all it takes.") },
    },
    t_streak_best = {
        { mood = "cheer", text = function(f) return string.format("Day %d. A new record.", f.streak) end,
          sub = s("Every day from here is a new best.") },
        { mood = "love", text = s("Your best streak ever, still going."),
          sub = function(f) return string.format("%d days and counting.", f.streak) end },
    },
    t_streak_near_best = {
        { mood = "curious", text = function(f) return string.format("Your best streak is %d days.", f.best) end,
          sub = function(f) return string.format("You're on %d. Getting close…", f.streak) end },
        { mood = "cheer", text = s("A record streak is in reach."),
          sub = function(f) return string.format("%s more and it's yours.", n_(f.best - f.streak + 1, "day", "days")) end },
    },
    t_closest = {
        { mood = "playful", text = function(f) return string.format("%s: %d%% there.", q(f.closest.title), floor(f.closest.pct * 100)) end,
          sub = s("The ending won't read itself.") },
        { mood = "cheer", text = function(f) return string.format("Nearly through %s.", q(f.closest.title)) end,
          sub = function(f)
              return f.closest.left_min and string.format("%s to go.", A.fmtMinutes(f.closest.left_min)) or "Almost there."
          end },
    },
    t_week_up = {
        { mood = "happy", text = s("A better week than last."),
          sub = function(f) return string.format("%d pages ahead so far.", f.week_pages - f.last_week_pages) end },
        { mood = "party", text = function(f) return string.format("%d pages this week already.", f.week_pages) end,
          sub = s("Last week can't keep up.") },
    },
    t_quiet = {
        { mood = "curious", text = s("No reading yet today."),
          sub = s("A chapter before bed?") },
        { mood = "shy", text = s("I've been waiting all day."),
          sub = s("Just saying.") },
    },
    y_goal_done = {
        { mood = "love", text = s("Year goal reached!"),
          sub = function(f) return string.format("%d books. Raise the bar?", f.year_done) end },
        { mood = "cheer", text = function(f) return string.format("%d books. You did it.", f.year_done) end,
          sub = s("Every book now is a bonus.") },
    },
    y_ahead = {
        { mood = "party", text = s("Ahead of schedule."),
          sub = function(f) return string.format("%s ahead of your goal pace.", n_(floor(f.year_done - f.year_expected), "book", "books")) end },
        { mood = "happy", text = function(f) return string.format("%d books in, ahead of the plan.", f.year_done) end,
          sub = s("Keep this up and the goal falls early.") },
    },
    y_behind = {
        { mood = "shy", text = s("A little behind this year."),
          sub = function(f) return string.format("About %s. Plenty of time.", n_(floor(f.year_expected - f.year_done + 0.5), "book", "books")) end },
        { mood = "playful", text = function(f) return string.format("Goal: %d. So far: %d.", f.year_goal, f.year_done) end,
          sub = s("Catch-up season starts now.") },
    },
    y_projected = {
        { mood = "curious", text = function(f) return string.format("On course for about %d books.", f.year_projected) end,
          sub = s("If nothing changes. Things change.") },
        { mood = "cheer", text = s("Where this year is heading:"),
          sub = function(f) return string.format("%s by December.", n_(f.year_projected, "book", "books")) end },
    },
    y_best_month = {
        { mood = "happy", text = function(f) return string.format("Best month so far: %s.", MONTHS[f.best_month]) end,
          sub = function(f) return string.format("%d pages. Beat it?", f.best_month_pages) end },
        { mood = "curious", text = function(f) return string.format("%s still holds the record.", MONTHS[f.best_month]) end,
          sub = function(f) return string.format("%s.", n_(f.best_month_pages, "page", "pages")) end },
    },
    y_this_month_top = {
        { mood = "cheer", text = s("A record month!"),
          sub = function(f) return string.format("%d pages in %s so far.", f.month_pages, MONTHS[f.t.month]) end },
        { mood = "love", text = function(f) return string.format("%s is your best month this year.", MONTHS[f.t.month]) end,
          sub = s("And it isn't over yet.") },
    },
    m_books = {
        { mood = "happy", text = function(f) return string.format("%s done this month.", n_(f.month_books, "book", "books")) end,
          sub = function(f) return string.format("%s to add another.", n_(f.month_left, "day", "days")) end },
        { mood = "love", text = function(f) return string.format("%s shelved in %s.", n_(f.month_books, "book", "books"), MONTHS[f.t.month]) end,
          sub = s("Nice work.") },
    },
    m_vs_last = {
        { mood = "cheer", text = function(f) return string.format("Already beat %s.", MONTHS[f.t.month == 1 and 12 or f.t.month - 1]) end,
          sub = s("Everything from here is extra.") },
        { mood = "party", text = s("This month is winning."),
          sub = function(f) return string.format("%d pages past last month.", f.month_pages - f.prev_month_pages) end },
    },
    m_vs_avg = {
        { mood = "shy", text = s("A quieter month."),
          sub = function(f) return string.format("%d pages short of your usual.", floor(f.month_avg - f.month_pages + 0.5)) end },
        { mood = "playful", text = function(f) return string.format("%s to catch an average month.", n_(f.month_left, "day", "days")) end,
          sub = function(f) return string.format("%d pages should do it.", floor(f.month_avg - f.month_pages + 0.5)) end },
    },
    m_end_book = {
        { mood = "curious", text = function(f) return string.format("%s ends soon.", MONTHS[f.t.month]) end,
          sub = function(f) return string.format("Room for %s?", q(f.closest.title)) end },
        { mood = "cheer", text = function(f) return string.format("Finish %s this month?", q(f.closest.title)) end,
          sub = function(f) return string.format("%d%% done, %s left.", floor(f.closest.pct * 100), n_(f.month_left, "day", "days")) end },
    },
    m_pages = {
        { mood = "cheer", text = function(f) return string.format("%d pages in %s.", f.month_pages, MONTHS[f.t.month]) end,
          sub = s("Not bad at all.") },
        { mood = "curious", text = function(f) return string.format("About %d pages a day this month.", floor(f.month_pages / math.max(1, f.t.day) + 0.5)) end,
          sub = function(f) return string.format("%d so far.", f.month_pages) end },
    },
    r_streak_best = {
        { mood = "cheer", text = function(f) return string.format("%d days. Never been longer.", f.streak) end,
          sub = s("Look at you go.") },
        { mood = "love", text = s("Your longest streak yet."),
          sub = function(f) return string.format("Day %d.", f.streak) end },
    },
    r_streak_gap = {
        { mood = "curious", text = function(f) return string.format("Best streak: %d. Now: %d.", f.best, f.streak) end,
          sub = s("The gap is closing.") },
        { mood = "cheer", text = function(f) return string.format("%s to a new record.", n_(f.best - f.streak + 1, "day", "days")) end,
          sub = s("One day at a time.") },
    },
    r_fav_hour = {
        { mood = "playful", text = function(f) return string.format("%s is your reading hour.", hourText(f.fav_hour)) end,
          sub = s("Same time tomorrow?") },
        { mood = "sleepy", text = function(f) return string.format("Lately you read most at %s.", hourText(f.fav_hour)) end,
          sub = s("I've noticed. I notice things.") },
    },
    r_week_trend = {
        { mood = "curious", text = function(f) return string.format("This week: %d pages. Last week: %d.", f.week_pages, f.last_week_pages) end,
          sub = function(f) return f.week_pages >= f.last_week_pages and "Ahead so far." or "Behind, for now." end },
        { mood = "playful", text = function(f) return f.week_pages >= f.last_week_pages and "This week is out-reading last week." or "Last week is winning. For now." end,
          sub = function(f) return string.format("%s difference.", n_(math.abs(f.week_pages - f.last_week_pages), "page", "pages")) end },
    },
    r_avg = {
        { mood = "curious", text = function(f) return string.format("Lately: %d pages a day.", floor(f.avg_pages + 0.5)) end,
          sub = s("Steady does it.") },
        { mood = "cheer", text = function(f) return string.format("%s a day, give or take.", A.fmtMinutes(mins(f.avg_secs or 0))) end,
          sub = s("That adds up fast.") },
    },
    l_unread = {
        { mood = "shy", text = function(f) return string.format("%d books still waiting.", f.lib.counts.unread) end,
          sub = s("I hear them whispering.") },
        { mood = "playful", text = function(f) return string.format("%s never opened.", n_(f.lib.counts.unread, "book", "books")) end,
          sub = s("Pick one at random?") },
    },
    l_share = {
        { mood = "curious", text = function(f) return string.format("%d of %d books read.", f.lib.counts.finished, f.lib.total) end,
          sub = s("The shelves await.") },
        { mood = "cheer", text = function(f) return string.format("%d%% of the library, done.", floor(100 * f.lib.counts.finished / f.lib.total + 0.5)) end,
          sub = s("One book at a time.") },
    },
    l_juggling = {
        { mood = "playful", text = function(f) return string.format("Reading %d books at once?", f.lib.counts.reading) end,
          sub = s("Show-off.") },
        { mood = "curious", text = function(f) return string.format("%d books on the go.", f.lib.counts.reading) end,
          sub = s("Which one is the favourite?") },
    },
    l_on_hold = {
        { mood = "curious", text = function(f) return string.format("%s waiting on hold.", n_(f.lib.counts.on_hold, "book", "books")) end,
          sub = s("Still interested?") },
        { mood = "sleepy", text = s("Some books are napping."),
          sub = function(f) return string.format("%d on hold.", f.lib.counts.on_hold) end },
    },
    l_closest = {
        { mood = "happy", text = function(f) return string.format("%s is %d%% done.", q(f.closest.title), floor(f.closest.pct * 100)) end,
          sub = s("Closest to the finish.") },
        { mood = "playful", text = s("Next up for the done pile:"),
          sub = function(f) return q(f.closest.title) end },
    },
}

-- A grumpy critter grumbles, a radiant one gushes, a meh one yawns.
local TIERS = {
    t_goal_done = { grumpy = { mood = "grumpy", text = s("Goal done. Fine. Well done."), sub = s("Don't let it go to your head.") },
                    radiant = { mood = "party", text = s("GOAL DONE! Unstoppable!"), sub = s("I'm so proud I could burst.") } },
    t_goal_near = { meh = { mood = "sleepy", text = s("Almost at the goal."), sub = s("Wake me when you're there.") } },
    t_streak_save = { grumpy = { mood = "grumpy", text = s("No reading today? Really?"),
                                 sub = function(f) return string.format("%d days, about to vanish.", f.streak) end } },
    t_streak_best = { radiant = { mood = "party", text = function(f) return string.format("%d DAYS! A legend is born!", f.streak) end } },
    t_quiet = { grumpy = { mood = "grumpy", text = s("Nothing read today."), sub = s("I'm not mad. I'm disappointed.") },
                radiant = { mood = "love", text = s("A quiet day."), sub = s("We'll read later. I believe in us.") } },
    y_goal_done = { grumpy = { mood = "grumpy", text = s("Goal reached. Show-off."), sub = s("Fine. Impressive.") } },
    y_ahead = { meh = { mood = "sleepy", text = s("Ahead of pace."), sub = s("Must be nice. I'm tired.") } },
    y_behind = { grumpy = { mood = "grumpy", text = s("Behind on the year goal."), sub = s("Don't look at me.") },
                 radiant = { mood = "love", text = s("A bit behind. No worries!"), sub = s("We've got months. We've got this.") } },
    m_vs_avg = { grumpy = { mood = "grumpy", text = s("Slow month."), sub = s("I've seen faster snails.") } },
    l_unread = { grumpy = { mood = "grumpy", text = function(f) return string.format("%d unread. Still buying more?", f.lib.counts.unread) end },
                 radiant = { mood = "love", text = function(f) return string.format("%d adventures waiting!", f.lib.counts.unread) end } },
    l_juggling = { grumpy = { mood = "grumpy", text = function(f) return string.format("%d books at once. Pick one.", f.lib.counts.reading) end } },
    r_streak_gap = { meh = { mood = "sleepy", text = function(f) return string.format("Best streak: %d.", f.best) end, sub = s("Records are tiring.") } },
}

-- Pages the reader made: anything from the general pools.
-- Remarks about a book in progress: tapping the bubble opens that book.
local CLOSEST_FP = function(f) return f.closest and f.closest.fp or nil end
for _, kind in ipairs({ "today", "yearly", "monthly", "library" }) do
    for _, r in ipairs(R[kind]) do
        if (r.id == "t_closest" or r.id == "y_behind" or r.id == "m_end_book" or r.id == "l_closest") and not r.fp then
            r.fp = CLOSEST_FP
        end
    end
end

R.custom = {}
do
    local seen = {}
    for _, kind in ipairs({ "today", "yearly", "library" }) do
        for _, r in ipairs(R[kind]) do
            if not seen[r.id] then seen[r.id] = true; R.custom[#R.custom + 1] = r end
        end
    end
end

local function poolFor(page)
    local id = page and page.id
    if R[id] then return R[id], id end
    return R.custom, "custom"
end

-- ─── picking ─────────────────────────────────────────────────────────────────
-- A.state.critter[kind] = { day, id }: the remark a page shows today.

local function eligible(pool, f)
    local ids, by = {}, {}
    for _, r in ipairs(pool) do
        local ok, yes = pcall(r.when, f)
        if ok and yes then ids[#ids + 1] = r.id; by[r.id] = r end
    end
    return ids, by
end

local function deal(kind, ids, skip)
    local k = kit()
    if k and k.Deck and type(k.Deck.pick) == "function" then
        -- the whole pool goes to the deck, so its cycle stays whole; the
        -- one on show now is dealt past once
        for _ = 1, 2 do
            local ok, id = pcall(k.Deck.pick, DECK_KEY .. kind, ids)
            if not ok or not id then break end
            if id ~= skip or #ids == 1 then return id end
        end
    end
    local list = {}
    for _, id in ipairs(ids) do if id ~= skip or #ids == 1 then list[#list + 1] = id end end
    return list[math.random(#list)]
end

-- The remark for `page` now: { text, sub, mood }, or nil when nothing fits.
-- SimpleUI's mood tier of the critter, nil without it.
local function moodTier()
    local Mood = sui("modules/critter/mood")
    if type(Mood) ~= "table" or type(Mood.read) ~= "function" or type(Mood.tier) ~= "function" then return nil end
    local ok, tier = pcall(function() return Mood.tier(Mood.read().score) end)
    return ok and tier or nil
end

-- The wording to use for remark `r`: 1 = its own, 2.. = VARIANTS[r.id], dealt
-- from a deck of their own so each comes round before any repeats.
local function dealWording(kind, r)
    local n = 1 + #(VARIANTS[r.id] or {})
    if n == 1 then return 1 end
    local list = {}
    for i = 1, n do list[i] = tostring(i) end
    local k = kit()
    if k and k.Deck and type(k.Deck.pick) == "function" then
        local ok, v = pcall(k.Deck.pick, DECK_KEY .. kind .. "_" .. r.id, list)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return math.random(n)
end

local function render(line, f)
    local ok_t, text = pcall(line.text, f)
    if not ok_t or type(text) ~= "string" or text == "" then return nil end
    local sub
    if line.sub then
        local ok_s, sv = pcall(line.sub, f)
        if ok_s and type(sv) == "string" and sv ~= "" then sub = sv end
    end
    return { text = text, sub = sub, mood = line.mood }
end

-- The remark for `page` now: { text, sub, mood }, or nil when nothing fits.
local function remark(page, refresh, advance, want_book)
    local pool, kind = poolFor(page)
    local f = facts(refresh)
    local ids, by = eligible(pool, f)
    if want_book then
        -- only the remarks that suggest a book
        local only = {}
        for _, id in ipairs(ids) do if by[id].fp then only[#only + 1] = id end end
        if #only > 0 then ids = only end
    end
    if #ids == 0 then return nil end
    A.state.critter = A.state.critter or {}
    local cur = A.state.critter[kind]
    local today = os.date("%Y-%m-%d")
    if advance or not (cur and cur.day == today and by[cur.id]) then
        local id = deal(kind, ids, cur and cur.id)
        cur = { day = today, id = id, v = dealWording(kind, by[id]) }
        A.state.critter[kind] = cur
    end
    local r = by[cur.id]
    -- a critter in a strong mood says it its own way; else the dealt wording
    local tier = moodTier()
    local line = (tier and TIERS[r.id] and TIERS[r.id][tier]) and {
        mood = TIERS[r.id][tier].mood,
        text = TIERS[r.id][tier].text,
        sub = TIERS[r.id][tier].sub,   -- its own line or none, as on the home screen
    } or nil
    if not line and (cur.v or 1) > 1 then line = (VARIANTS[r.id] or {})[cur.v - 1] end
    local out = (line and render(line, f)) or render(r, f)
    -- only a line that names the book (in quotes) opens it on a tap
    local names_book = out and ((out.text .. (out.sub or "")):find("\xE2\x80\x9C", 1, true) ~= nil)
    if out and r.fp and names_book then
        local ok, fp = pcall(r.fp, f)
        if ok and type(fp) == "string" then out.fp = fp end
    end
    if out then
        A.state.critter_fp = A.state.critter_fp or {}
        A.state.critter_fp[(page and page.id) or "?"] = out.fp
    end
    return out
end

--- Tapping the bubble of a remark about a book: opens that book.
function C.open(page, ctx)
    local fp = A.state.critter_fp and A.state.critter_fp[(page and page.id) or "?"]
    if type(fp) == "string" then
        D.openBook(ctx, fp)
        return true
    end
    return false
end

--- Tapping the critter: another remark for that page.
function C.next(page, refresh)
    remark(page, refresh, true)
    C._moveOn(page)   -- and a new spot (defined with the drawing, below)
    A.state.critter_rev = (A.state.critter_rev or 0) + 1   -- the kept tab is stale (main.lua dashKey)
end

-- ─── drawing ─────────────────────────────────────────────────────────────────

local function pfx(ctx) return (ctx and ctx.pfx) or SUI_PREFIX end

-- The critter's sprite for `mood` (SimpleUI's grumpy mood wins over a cheerful
-- line, as on the home screen).
local function moodFor(k, mood)
    if k.Mood and type(k.Mood.read) == "function" and type(k.Mood.tier) == "function" then
        local ok, tier = pcall(function() return k.Mood.tier(k.Mood.read().score) end)
        if ok and tier == "grumpy" and (mood == "party" or mood == "cheer" or mood == "love") then return "grumpy" end
        if ok and tier == "meh" and mood == "party" then return "happy" end
    end
    return mood
end

-- Faces for the bubble: SimpleUI's critter text styles, else Reading Log's.
local function faces(k, ctx, scale)
    local ok, msg, msg_b, det, det_b = pcall(function()
        local styles = k.Config.resolveTextStyles(ctx and ctx.sui, "critter", { "message", "detail" })
        local S = k.Style
        local mfs = max(8, floor(S.FS_BODY * scale * styles.message.scale))
        local dfs = max(7, floor(S.FS_DETAIL * scale * styles.detail.scale))
        local a, ab = S.getTextFace(styles.message, mfs)
        local b, bb = S.getTextFace(styles.detail, dfs)
        return a, ab, b, bb
    end)
    if ok and msg and det then return msg, msg_b, det, det_b end
    local h = floor(22 * scale)
    local a, ab = A.face(h, { bold = true })
    local b, bb = A.face(floor(h * 0.85))
    return a, ab, b, bb
end

--- Draws the critter at the right of the box (x, y, w, h) of canvas `c`, with
--- its bubble to its left, and a tap region `region`. Returns true when drawn.
--- `max_w`: the widest the critter and its bubble may be. In a wider box they
--- take a spot of their own in it, which changes each day and with each tap
--- (after the title, the middle, the far end): the critter wanders.
local SPOTS = { "end", "start", "middle" }

local function spotFor(page)
    local id = (page and page.id) or "?"
    A.state.critter_spot = A.state.critter_spot or {}
    local cur = A.state.critter_spot[id]
    local today = os.date("%Y-%m-%d")
    if not cur or cur.day ~= today then
        -- a different spot each day, not the same on every page
        local n = tonumber(os.date("%j")) or 1
        for i = 1, #id do n = n + id:byte(i) end
        cur = { day = today, i = n % #SPOTS + 1 }
        A.state.critter_spot[id] = cur
    end
    return SPOTS[cur.i]
end

local function moveOn(page)
    spotFor(page)
    local cur = A.state.critter_spot[(page and page.id) or "?"]
    cur.i = cur.i % #SPOTS + 1
end

C._moveOn = moveOn

-- Height of `text` wrapped to `width` in `face` (SimpleUI's own text box, as
-- the bubble draws it), cached: nil when it can't be measured.
local _heights = {}
local function textHeight(face, bold, text, width)
    if not (face and text) then return 0 end
    local key = table.concat({ tostring(face), tostring(bold), width, text }, "|")
    local v = _heights[key]
    if v then return v end
    local UI = sui("infra/sui_core")
    if type(UI) ~= "table" or type(UI.makeTextBox) ~= "function" then return nil end
    local ok, box = pcall(UI.makeTextBox, { text = text, face = face, bold = bold, width = width })
    if not ok or not box then return nil end
    v = box:getSize().h
    pcall(box.free, box)
    if #_heights > 200 then _heights = {} end
    _heights[key] = v
    return v
end

-- Whether `r` fits whole (nothing cut short) in a bubble `bw` wide and `h`
-- tall, the way SimpleUI's bubble lays it out: the main line, a small gap,
-- the second line, inside its frame. Unmeasurable counts as fitting.
local function fits(k, r, bw, h, scale, style, unit, mf, mb, df, db)
    local _b, _p, reach, frame = k.Bubble.metrics(scale, true, style, unit)
    local text_w = bw - reach - frame
    if text_w <= 20 then return false end
    local mh, ml = textHeight(mf, mb, r.text, text_w), textHeight(mf, mb, "Xg", text_w)
    if not (mh and ml) then return true end
    if mh > 2 * ml + 1 then return false end   -- the bubble shows 2 lines of each at most
    local used = mh + frame
    if r.sub then
        local dh, dl = textHeight(df, db, r.sub, text_w), textHeight(df, db, "Xg", text_w)
        if not (dh and dl) then return true end
        if dh > 2 * dl + 1 then return false end
        used = used + dh + A.screen():scaleBySize(2) * scale
    end
    return used <= h
end

function C.draw(c, x, y, w, h, page, ctx, region, max_w)
    if not C.enabled() then return false end
    local area_x, area_w = x, w
    local k = kit()
    local r = remark(page, ctx and ctx.refresh)
    if not r then return false end
    local p = pfx(ctx)
    local Screen = A.screen()
    local scale = h / Screen:scaleBySize(104)
    local entry = k.Assets.get(k.Store and k.Store:get(p .. "critter_pick") or nil)
    if not entry then return false end
    local path = k.Assets.imagePath(entry, moodFor(k, r.mood) or "neutral")
    if not path then return false end
    local cap = (max_w and max_w < w) and max_w or w
    local sprite = k.Sprite:new{ path = path, max_w = floor(cap * 0.3), max_h = h }
    local sw, sh = sprite.dimen.w, sprite.dimen.h
    if sw <= 0 or sh <= 0 then return false end
    local gap = max(4, floor(Screen:scaleBySize(6) * scale))
    local style = k.Store and k.Store:get(p .. "critter_bubble_style") or nil
    if style ~= "smooth" then style = "pixel" end
    local unit = sprite.pixel or max(1, Screen:scaleBySize(2))
    -- text no smaller than 80% of the home screen critter's, even in a
    -- low heading (the bubble then shows fewer lines)
    local mf, mb, df, db = faces(k, ctx, max(scale, 0.8))
    -- Long text: the bubble grows, up to all the room in the row, before
    -- anything is cut short.
    local group_w = cap
    if cap < w then
        for _, cand in ipairs({ cap, floor((cap + w) / 2), w }) do
            group_w = cand
            if fits(k, r, cand - sw - gap, h, scale, style, unit, mf, mb, df, db) then break end
        end
    end
    if group_w < w then
        local spot, free = spotFor(page), w - group_w
        x = x + (spot == "end" and free or (spot == "middle" and floor(free / 2) or 0))
    end
    w = group_w
    local bubble_w = w - sw - gap
    if bubble_w < k.Bubble.minWidth(scale, true, style, unit) then return false end
    local ok_b, bubble = pcall(k.Bubble.build, {
        w = bubble_w, h = h, side = "right",
        message = r.text, detail = r.sub,
        msg_face = mf, msg_bold = mb, det_face = df, det_bold = db,
        scale = scale, style = style, unit = unit,
    })
    if not ok_b or not bubble then return false end
    local bs = bubble:getSize()
    local bx = x + w - sw - gap - bs.w
    local by = y + floor((h - bs.h) / 2)
    local sx, sy = x + w - sw, y + h - sh
    c.owned[#c.owned + 1] = bubble
    c:op(function(bb, ox, oy)
        bubble:paintTo(bb, ox + bx, oy + by)
        sprite:paintTo(bb, ox + sx, oy + sy)
    end)
    -- the whole group: a tap opens the conversation (C.talk)
    if region then c:region(region, bx, y, x + w - bx, h) end
    local id = (page and page.id) or "?"
    -- the band it can wander in, so a redraw covers just that (modules.lua)
    A.state.critter_box = A.state.critter_box or {}
    A.state.critter_box[id] = { x = area_x, y = y, w = area_w, h = h }
    -- what the conversation needs to open over it
    A.state.critter_geo = A.state.critter_geo or {}
    A.state.critter_geo[id] = {
        canvas = c, bubble = { x = bx, y = by, w = bs.w, h = bs.h }, sprite = { x = sx, y = sy, w = sw, h = sh },
        style = style, unit = unit, scale = scale, faces = { message = mf, message_bold = mb, answer = df },
    }
    return true
end

-- ─── the conversation (a tap): SimpleUI's critter talk window ───────────────
-- Over a remark about a book: Open it / Another suggestion / Say something
-- else. Over any other remark: Suggest a book / Not now / Say something else.
-- `redraw()` repaints the critter's band after the remark changed.

local function absRect(geo, rect)
    local d = geo.canvas and geo.canvas.dimen
    if not (d and d.x and d.y) then return nil end
    local Geom = require("ui/geometry")
    return Geom:new{ x = d.x + rect.x, y = d.y + rect.y, w = rect.w, h = rect.h }
end

local function hasBookRemark(page, refresh)
    local pool = poolFor(page)
    local f = facts(refresh)
    for _, r in ipairs(pool) do
        if r.fp then
            local ok, yes = pcall(r.when, f)
            if ok and yes then return true end
        end
    end
    return false
end

--- Opens the conversation for `page`; returns false when it can't (then the
--- caller just shows another remark).
function C.talk(page, ctx, redraw)
    local id = (page and page.id) or "?"
    local geo = A.state.critter_geo and A.state.critter_geo[id]
    local TalkWindow = sui("modules/critter/talk_window")
    if not (geo and type(TalkWindow) == "table" and type(TalkWindow.open) == "function") then return false end
    local anchor = absRect(geo, geo.bubble)
    if not anchor then return false end
    local fp = A.state.critter_fp and A.state.critter_fp[id]
    local refresh = ctx and ctx.refresh
    local function another(book)
        remark(page, refresh, true, book)
        moveOn(page)
        A.state.critter_rev = (A.state.critter_rev or 0) + 1
        if redraw then redraw() end
    end
    local opener, options
    if fp then
        opener = nil   -- the bubble already says which book
        options = {
            { text = "Open it", on_pick = function() D.openBook(ctx, fp) end },
            { text = "Another suggestion", on_pick = function() another(true) end },
        }
    else
        local can_suggest = hasBookRemark(page, refresh)
        opener = can_suggest and "Want me to suggest a book?" or nil
        options = {}
        if can_suggest then
            options[#options + 1] = { text = "Suggest a book", on_pick = function() another(true) end }
        end
        options[#options + 1] = { text = "Not now", on_pick = function() end }
    end
    local ok = pcall(TalkWindow.open, {
        opener = opener,
        options = options,
        other = { text = "Say something else\xE2\x80\xA6", on_pick = function() another(false) end },
        anchor = anchor,
        side = "right",
        critter_rect = absRect(geo, geo.sprite),
        style = geo.style, unit = geo.unit, scale = geo.scale, faces = geo.faces,
    })
    return ok
end

return C
