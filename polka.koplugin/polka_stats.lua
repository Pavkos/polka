-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: reading statistics.

Reads the database written by KOReader's own statistics plugin
(settings/statistics.sqlite3) and turns it into the few numbers the
statistics screen shows. Read-only.

Speed: the database can hold years of page rows. Only the last year is
summed, per hour and book (an index range on start_time, integer buckets, no
date functions per row), all-time totals come from the per-book totals, and
the result is reused until the statistics change (new reading, sync, reset).
The same data feeds the reader's card and badges (polka_achievements).
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Stats = {}

local DAY = 86400
local MIN_SECS = 60 -- a day "counts" after one minute of reading

-- Last computation (day and hour numbers count from the epoch in local time):
-- {
--   off, sig, secs, pages, first_time,
--   days    = { [day]  = { secs, pages } },
--   hours   = { [hour] = secs },
--   daybook = { [day]  = { [id_book] = secs } },
--   books   = { [id_book] = { md5, pages, lang, secs, read_pages, highlights, notes } },
-- }
local cache = nil

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function Stats.available()
    return lfs.attributes(dbPath(), "mode") == "file"
end

function Stats.reset()
    cache = nil
end

-- Seconds east of UTC for the current local time (summer time included).
local function localOffset()
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    return os.difftime(now, os.time(utc))
end

local function midnight(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

-- Monday of the week containing t (local time).
local function weekStart(t)
    local m = midnight(t)
    local wday = tonumber(os.date("%w", m)) -- 0 = Sunday
    local offset = (wday + 6) % 7
    return midnight(m - offset * DAY + 3600 * 12)
end

-- Step one calendar day without DST surprises.
local function nextDay(t)
    return midnight(t + DAY + 3600 * 12)
end

local WINDOW_DAYS = 372 -- the heatmap's 53 weeks and a little more
Stats.WINDOW_DAYS = WINDOW_DAYS
Stats.MIN_SECS = MIN_SECS

-- Re-reads the statistics when they changed since the last time: the
-- per-book totals and the newest page row are a cheap fingerprint of any
-- new reading, a sync from another device or a reset.
local function refresh()
    local off = math.floor(localOffset())
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(dbPath(), "ro")
    local ok, err = pcall(function()
        local n_books, secs, pages = conn:rowexec(
            "SELECT count(*), coalesce(sum(total_read_time), 0), coalesce(sum(total_read_pages), 0) FROM book")
        local last_row = conn:rowexec("SELECT coalesce(max(rowid), 0) FROM page_stat_data")
        local sig = table.concat({ os.date("%Y-%m-%d"), off, tostring(n_books), tostring(secs), tostring(pages), tostring(last_row) }, ":")
        if cache and cache.sig == sig then return end
        local c = {
            off = off, sig = sig, secs = tonumber(secs) or 0, pages = tonumber(pages) or 0,
            days = {}, hours = {}, daybook = {}, books = {},
        }
        local res, n = conn:exec(string.format([[
            SELECT (start_time + %d) / 3600 AS h, id_book, sum(duration), count(*)
            FROM page_stat_data WHERE start_time > %d GROUP BY h, id_book
        ]], off, os.time() - WINDOW_DAYS * DAY))
        if res and n and n > 0 then
            local H, B, S, P = res[1], res[2], res[3], res[4]
            local days, hours, daybook = c.days, c.hours, c.daybook
            for i = 1, n do
                local h = tonumber(H[i])
                local b = tonumber(B[i]) or 0
                local s = tonumber(S[i]) or 0
                local p = tonumber(P[i]) or 0
                local d = math.floor(h / 24)
                local day = days[d]
                if not day then
                    day = { secs = 0, pages = 0 }
                    days[d] = day
                end
                day.secs = day.secs + s
                day.pages = day.pages + p
                hours[h] = (hours[h] or 0) + s
                local per_book = daybook[d]
                if not per_book then
                    per_book = {}
                    daybook[d] = per_book
                end
                per_book[b] = (per_book[b] or 0) + s
            end
        end
        res, n = conn:exec("SELECT id, md5, pages, language, total_read_time, total_read_pages, highlights, notes FROM book")
        if res and n and n > 0 then
            for i = 1, n do
                c.books[tonumber(res[1][i])] = {
                    md5 = res[2][i],
                    pages = tonumber(res[3][i]) or 0,
                    lang = res[4][i],
                    secs = tonumber(res[5][i]) or 0,
                    read_pages = tonumber(res[6][i]) or 0,
                    highlights = tonumber(res[7][i]) or 0,
                    notes = tonumber(res[8][i]) or 0,
                }
            end
        end
        c.first_time = tonumber((conn:rowexec("SELECT min(start_time) FROM page_stat_data")))
        cache = c
    end)
    conn:close()
    if not ok then
        cache = nil
        error(err)
    end
    return cache
end

function Stats.compute()
    if not Stats.available() then return nil end
    local ok, res = pcall(Stats._compute)
    if not ok then
        logger.warn("Polka: statistics query failed:", res)
        cache = nil
        return nil
    end
    return res
end

function Stats._compute()
    local c = refresh()
    local off = c.off
    local days = c.days
    local now = os.time()
    local today = midnight(now)

    -- t is a local midnight; half a day of slack keeps summer-time days on the
    -- same bucket when the current offset differs by an hour.
    local function dayOf(t) return math.floor((t + off + DAY / 2) / DAY) end
    local function secsOn(t)
        local d = days[dayOf(t)]
        return d and d.secs or 0
    end

    local s = {
        today = secsOn(today),
        total_secs = c.secs,
        total_pages = c.pages,
        raw = c, -- for polka_achievements; treat as read-only
        today_day = dayOf(today),
    }

    -- This week, Monday..Sunday.
    local ws = weekStart(now)
    s.week = {}
    s.week_total = 0
    local t = ws
    for i = 1, 7 do
        local secs = secsOn(t)
        s.week[i] = { secs = secs, is_today = (t == today), future = t > today }
        s.week_total = s.week_total + secs
        t = nextDay(t)
    end
    local days_so_far = math.floor((today - ws) / DAY + 0.5) + 1
    s.week_avg = s.week_total / math.max(1, days_so_far)

    -- Current streak: ends today, or yesterday if today hasn't been read yet.
    local streak = 0
    local d = dayOf(today)
    if not days[d] or days[d].secs < MIN_SECS then d = d - 1 end
    while days[d] and days[d].secs >= MIN_SECS do
        streak = streak + 1
        d = d - 1
    end
    s.streak = streak

    -- Best streak and best day over the last year.
    local first = dayOf(today) - WINDOW_DAYS
    local keys = {}
    local best_day, best_secs = nil, 0
    for k, v in pairs(days) do
        if k >= first then
            if v.secs >= MIN_SECS then keys[#keys + 1] = k end
            if v.secs > best_secs then best_secs, best_day = v.secs, k end
        end
    end
    table.sort(keys)
    local best_streak, run, prev = 0, 0, nil
    for _, k in ipairs(keys) do
        run = (prev and k == prev + 1) and run + 1 or 1
        prev = k
        if run > best_streak then best_streak = run end
    end
    s.best_streak = best_streak
    s.read_days = keys -- sorted day numbers with at least a minute of reading
    s.best_day = best_day and os.date("!%Y-%m-%d", best_day * DAY) or nil
    s.best_day_secs = best_secs

    -- Heatmap: the last 53 weeks, Monday-based columns, ending this week.
    local weeks = 53
    local start = weekStart(now)
    for _ = 1, weeks - 1 do
        start = weekStart(start - 3 * DAY)
    end
    s.heat = { weeks = weeks, start = start, cells = {} }
    local read_days, year_secs = 0, 0
    t = start
    for w = 1, weeks do
        s.heat.cells[w] = {}
        for wd = 1, 7 do
            local secs = secsOn(t)
            s.heat.cells[w][wd] = { secs = secs, future = t > today, t = t }
            if t <= today then
                if secs >= MIN_SECS then read_days = read_days + 1 end
                year_secs = year_secs + secs
            end
            t = nextDay(t)
        end
    end
    s.heat.read_days = read_days
    s.heat.secs = year_secs

    -- Pace: pages per hour over the last 30 days (fall back to all time).
    local p_secs, p_pages = 0, 0
    local last_day = dayOf(today)
    for dd = last_day - 29, last_day do
        local v = days[dd]
        if v then p_secs, p_pages = p_secs + v.secs, p_pages + v.pages end
    end
    if p_secs < 3600 then p_secs, p_pages = c.secs, c.pages end
    s.pages_per_hour = p_secs > 0 and (p_pages / (p_secs / 3600)) or 0
    return s
end

return Stats
