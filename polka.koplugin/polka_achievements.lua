--[[--
Polka: the reader's card (формуляр), badges and the weekly challenge.

Everything is derived from what KOReader already keeps: finished books and
the day they were finished come from the books' sidecars (Books:finished),
reading time from the statistics database (polka_stats, last year in memory).
Polka itself only remembers, in its own settings:
  polka_badges     earned badges, the day each was earned, and which were seen;
  polka_challenge  this week's challenge and how many were completed;
  polka_card_seen  how many stamps the card had when it was last looked at.
Badges stay earned even when the reading behind them drops out of the
one-year window. Nothing here runs while reading: only when the statistics
screen is built.
]]

local Books = require("polka_books")
local UI = require("polka_ui")

local A = {}

local DAY = 86400

-- Ranks by the number of finished books.
A.RANKS = {
    { n = 0, name = "Новый читатель" },
    { n = 1, name = "Абонент" },
    { n = 5, name = "Постоянный читатель" },
    { n = 10, name = "Завсегдатай" },
    { n = 25, name = "Книгочей" },
    { n = 50, name = "Библиофил" },
    { n = 100, name = "Почётный читатель" },
    { n = 200, name = "Хранитель фонда" },
}

function A.rankFor(count)
    local cur, nxt = A.RANKS[1], A.RANKS[2]
    for i, r in ipairs(A.RANKS) do
        if count >= r.n then cur, nxt = r, A.RANKS[i + 1] end
    end
    return cur, nxt
end

-- Days -------------------------------------------------------------------------

-- Day numbers count days since the epoch in local time (as in polka_stats).
local function dayKey(d)
    return os.date("!%Y-%m-%d", d * DAY)
end

local function keyDay(key, off)
    local y, m, d = tostring(key or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    return math.floor((t + off) / DAY)
end

local function weekday(d) return (d + 3) % 7 end -- 0 = Monday … 6 = Sunday
local function weekStart(d) return d - weekday(d) end

function A.dayKey(d) return dayKey(d) end

local function localOffset()
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    return math.floor(os.difftime(now, os.time(utc)))
end

-- Settings ---------------------------------------------------------------------

local function readTable(key)
    local t = G_reader_settings:readSetting(key)
    return type(t) == "table" and t or {}
end

-- Text helpers -------------------------------------------------------------------

local function isRussian(lang)
    local low = lang:lower()
    return low:match("^%s*ru") ~= nil or lang:find("рус", 1, true) ~= nil
        or lang:find("Рус", 1, true) ~= nil or lang:find("РУС", 1, true) ~= nil
end

local NO_LANG = { und = true, ["n/a"] = true, zxx = true, mul = true, unknown = true }

local function knownLang(lang)
    return type(lang) == "string" and lang:match("%S") ~= nil and not NO_LANG[lang:lower()]
end

-- "Лев Николаевич Толстой", "Толстой Л. Н." -> word sets like { толстой, лев }
-- that can be compared by inclusion. Only the first author counts. Initials
-- are dropped, and a patronymic only in the middle of three or more words
-- (so that "Адам Мицкевич" keeps its surname).
local function authorWords(authors)
    if type(authors) ~= "string" then return nil end
    local first = authors:match("^[^\n,;&]+") or authors
    first = Books.sortKey(first)
    local list = {}
    for w in first:gmatch("[^%s%.%-]+") do
        if #w:gsub("[\128-\191]", "") > 2 then list[#list + 1] = w end -- characters, not bytes
    end
    local words = {}
    for i, w in ipairs(list) do
        local patronymic = #list >= 3 and i > 1 and i < #list
            and (w:sub(-6) == "вич" or w:sub(-6) == "вна" or w:sub(-8) == "ична")
        if not patronymic then words[w] = true end
    end
    if next(words) == nil then return nil end
    return words
end

local function subset(a, b)
    for w in pairs(a) do
        if not b[w] then return false end
    end
    return true
end

function A.formatDate(key, with_year)
    local y, m, d = tostring(key or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    local s = string.format("%d %s", tonumber(d), UI.MONTHS_GEN[tonumber(m)])
    if with_year or y ~= os.date("%Y") then s = s .. " " .. y end
    return s
end

-- Badges -------------------------------------------------------------------------
--
-- Each badge: id, title, hint (how to get it), and either num + cap (shown on
-- the medallion) or icon (a code point of KOReader's symbols font).
-- eval(ctx) returns value, target, and the day it was first met (a day
-- number, or false when met but the day is unknown).

local SUN, MOON, COFFEE, CLONE, FLAG = 0xF185, 0xF186, 0xF0F4, 0xF24D, 0xF024
local GLOBE, USER, SHELVES, BOLT, PENCIL = 0xF0AC, 0xF007, 0xF009, 0xF0E7, 0xF040
local HOURGLASS, CALENDAR, CUBE, TARGET = 0xF254, 0xF073, 0xF1B2, 0xF140

local function streakBadge(id, n, title, cap)
    return {
        id = id, title = title, hint = string.format("%d %s подряд", n, UI.plural(n, "день", "дня", "дней")),
        num = tostring(n), cap = cap,
        eval = function(ctx) return ctx.best_streak, n, ctx.streak_reach[n] end,
    }
end

local function crossing(list, before, target)
    -- list: ascending { day, amount }; returns the first day the running total reaches target.
    if before >= target then return false end
    local sum = before
    for _, e in ipairs(list) do
        sum = sum + e[2]
        if sum >= target then return e[1] end
    end
    return nil
end

local function hoursBadge(id, n, title, cap)
    return {
        id = id, title = title, hint = string.format("%d %s чтения", n, UI.plural(n, "час", "часа", "часов")),
        num = tostring(n), cap = cap,
        eval = function(ctx)
            local target = n * 3600
            local value = ctx.total_secs
            local day = value >= target and crossing(ctx.day_secs, ctx.secs_before, target) or nil
            return math.floor(value / 3600), n, day
        end,
    }
end

local function booksBadge(id, n, title, cap)
    return {
        id = id, title = title, hint = n == 1 and "первая прочитанная книга" or UI.books(n),
        num = tostring(n), cap = cap,
        eval = function(ctx)
            local e = ctx.fin_asc[n]
            if not e then return ctx.count, n, nil end
            return ctx.count, n, e.day or false
        end,
    }
end

local function pagesBadge(id, n, title, num)
    return {
        id = id, title = title, hint = UI.number(n) .. " страниц", num = num, cap = "стр.",
        eval = function(ctx)
            local value = ctx.total_pages
            local day = value >= n and crossing(ctx.day_pages, ctx.pages_before, n) or nil
            return value, n, day
        end,
    }
end

local function firstDay(t, pred)
    -- t: { [day] = x }; returns the smallest day where pred(x, day) holds.
    local best
    for d, x in pairs(t) do
        if (not best or d < best) and pred(x, d) then best = d end
    end
    return best
end

local function flag(day)
    return day and 1 or 0, 1, day
end

local BADGES = {
    -- Streaks
    streakBadge("streak3", 3, "Три дня", "дня"),
    streakBadge("streak7", 7, "Неделя", "дней"),
    {
        id = "weeks12", title = "12 недель", hint = "каждую неделю", num = "12", cap = "недель",
        eval = function(ctx) return ctx.best_weeks, 12, ctx.weeks_reach end,
    },
    streakBadge("streak30", 30, "Месяц подряд", "дней"),
    streakBadge("streak100", 100, "Сто дней", "дней"),
    -- Time
    hoursBadge("hours1", 1, "Первый час", "час"),
    hoursBadge("hours24", 24, "Сутки с книгой", "часа"),
    hoursBadge("hours100", 100, "Сто часов", "часов"),
    {
        id = "day2h", title = "Запоем", hint = "2 часа за день", icon = HOURGLASS,
        eval = function(ctx)
            return ctx.best_day_secs, 7200, firstDay(ctx.days, function(v) return v.secs >= 7200 end)
        end,
    },
    {
        id = "week10h", title = "Книжная неделя", hint = "10 ч за неделю", icon = CALENDAR,
        eval = function(ctx) return ctx.best_week_secs, 36000, ctx.week10h_day end,
    },
    -- Finished books
    booksBadge("books1", 1, "Первый штамп", "книга"),
    booksBadge("books5", 5, "Пять книг", "книг"),
    booksBadge("books10", 10, "Десять книг", "книг"),
    booksBadge("books25", 25, "Двадцать пять", "книг"),
    booksBadge("books50", 50, "Полсотни", "книг"),
    -- Volume and goals
    pagesBadge("pages1k", 1000, "Тысяча страниц", "1000"),
    pagesBadge("pages10k", 10000, "Десять тысяч", "10 тыс."),
    {
        id = "day100p", title = "Сто страниц", hint = "100 страниц за день", num = "100", cap = "за день",
        eval = function(ctx)
            return ctx.best_day_pages, 100, firstDay(ctx.days, function(v) return v.pages >= 100 end)
        end,
    },
    {
        id = "brick", title = "Кирпич", hint = "от 1000 страниц", icon = CUBE,
        eval = function(ctx)
            local best, day = 0, nil
            for _, e in ipairs(ctx.fin_asc) do
                local p = e.info.pages or 0
                if p > best then best = p end
                if p >= 1000 and day == nil then day = e.day or false end
            end
            return best, 1000, day
        end,
    },
    {
        id = "goal", title = "Цель года", icon = TARGET,
        hint_fn = function(ctx) return UI.books(ctx.goal) end,
        eval = function(ctx)
            local n, day = 0, nil
            for _, e in ipairs(ctx.fin_asc) do
                if e.info.year == ctx.year then
                    n = n + 1
                    if n == ctx.goal then day = e.day or false end
                end
            end
            return n, ctx.goal, day
        end,
    },
    -- Habits
    {
        id = "early", title = "Ранняя пташка", hint = "до 7 утра", icon = SUN,
        eval = function(ctx) return flag(ctx.early_day) end,
    },
    {
        id = "night", title = "Ночная смена", hint = "после полуночи", icon = MOON,
        eval = function(ctx) return flag(ctx.night_day) end,
    },
    {
        id = "weekend", title = "Выходные", hint = "по часу в сб и вс", icon = COFFEE,
        eval = function(ctx)
            return flag(firstDay(ctx.days, function(v, d)
                if weekday(d) ~= 6 or v.secs < 3600 then return false end
                local sat = ctx.days[d - 1]
                return sat ~= nil and sat.secs >= 3600
            end))
        end,
    },
    {
        id = "twobooks", title = "Две книги сразу", hint = "обе за один день", icon = CLONE,
        eval = function(ctx)
            return flag(firstDay(ctx.daybook, function(per_book)
                local n = 0
                for _, secs in pairs(per_book) do
                    if secs >= 600 then n = n + 1 end
                end
                return n >= 2
            end))
        end,
    },
    {
        id = "challenge", title = "Вызов принят", hint = "вызов недели", icon = FLAG,
        eval = function(ctx)
            local ch = ctx.challenge_state
            local done = tonumber(ch.done) or 0
            if done < 1 then return 0, 1, nil end
            return 1, 1, keyDay(ch.first_done, ctx.off) or false
        end,
    },
    -- Variety
    {
        id = "polyglot", title = "Полиглот", hint = "не на русском", icon = GLOBE,
        eval = function(ctx)
            for _, e in ipairs(ctx.fin_asc) do
                local lang = e.info.lang
                if not knownLang(lang) and e.info.md5 and ctx.by_md5[e.info.md5] then
                    lang = ctx.by_md5[e.info.md5].lang
                end
                if knownLang(lang) and not isRussian(lang) then return 1, 1, e.day or false end
            end
            return 0, 1, nil
        end,
    },
    {
        id = "author", title = "Любимый автор", hint = "3 книги одного автора", icon = USER,
        eval = function(ctx)
            local by_word, best, day = {}, 0, nil -- word -> groups that contain it
            for _, e in ipairs(ctx.fin_asc) do
                local words = authorWords(e.info.authors or Books:brief(Books:record(e.path)).authors)
                if words then
                    local g
                    for w in pairs(words) do
                        for _, cand in ipairs(by_word[w] or {}) do
                            if subset(cand.words, words) or subset(words, cand.words) then
                                g = cand
                                break
                            end
                        end
                        if g then break end
                    end
                    if not g then
                        g = { words = words, n = 0 }
                        for w in pairs(words) do
                            by_word[w] = by_word[w] or {}
                            table.insert(by_word[w], g)
                        end
                    end
                    g.n = g.n + 1
                    if g.n > best then best = g.n end
                    if g.n == 3 and day == nil then day = e.day or false end
                end
            end
            return best, 3, day
        end,
    },
    {
        id = "shelves", title = "Пять полок", hint = "книги с пяти полок", icon = SHELVES,
        eval = function(ctx)
            local seen, n, day = {}, 0, nil
            for _, e in ipairs(ctx.fin_asc) do
                local rec = Books.by_path[e.path]
                local shelf = rec and rec.shelf
                if shelf and not seen[shelf] then
                    seen[shelf] = true
                    n = n + 1
                    if n == 5 then day = e.day or false end
                end
            end
            return n, 5, day
        end,
    },
    {
        id = "swallow", title = "Залпом", hint = "книга за 3 дня", icon = BOLT,
        eval = function(ctx)
            for _, e in ipairs(ctx.fin_asc) do
                local span = e.info.md5 and ctx.book_span[e.info.md5]
                if span and span.secs >= 3600 and span.last - span.first <= 2
                        and span.first > ctx.window_start + 2 then
                    return 1, 1, e.day or span.last
                end
            end
            return 0, 1, nil
        end,
    },
    {
        id = "marginalia", title = "Маргиналии", hint = "10 выделений", icon = PENCIL,
        eval = function(ctx) return ctx.marks, 10, false end,
    },
}
A.BADGES = BADGES
A.ROW = 5 -- badges per row: one theme per row

-- Weekly challenge ------------------------------------------------------------------
--
-- One per calendar week (Monday to Sunday), picked on the first look at the
-- statistics that week and kept until Sunday. Targets follow the last four
-- weeks of reading, so a challenge is a nudge, not a wall.

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

local function sumDays(ctx, from, to, field)
    local s = 0
    for d = from, to do
        local v = ctx.days[d]
        if v then s = s + v[field] end
    end
    return s
end

local function countDays(ctx, from, to, min_secs)
    local n = 0
    for d = from, to do
        local v = ctx.days[d]
        if v and v.secs >= min_secs then n = n + 1 end
    end
    return n
end

local function morningSecs(ctx, d)
    local s = 0
    for h = d * 24 + 5, d * 24 + 9 do s = s + (ctx.hours[h] or 0) end
    return s
end

-- Books read this week that had a break of a month or more before it.
local function returnedBooks(ctx, ws)
    local before, recent, now = {}, {}, {}
    for d, per_book in pairs(ctx.daybook) do
        for id, secs in pairs(per_book) do
            if d < ws - 30 then
                before[id] = true
            elseif d < ws then
                recent[id] = true
            elseif d <= ws + 6 then
                now[id] = (now[id] or 0) + secs
            end
        end
    end
    return before, recent, now
end

local function hoursTitle(secs)
    local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60 + 0.5)
    if m == 0 then
        return string.format("%d %s чтения за неделю", h, UI.plural(h, "час", "часа", "часов"))
    end
    return UI.duration(secs) .. " за неделю"
end

A.CHALLENGES = {
    {
        id = "days15", kind = "days", min_secs = 900,
        make = function(p)
            local t = clamp(math.floor(p.avg_days15 + 0.5) + 1, 3, 7)
            return t, t == 7 and "Каждый день по 15 минут"
                or string.format("%d %s по 15 минут", t, UI.plural(t, "день", "дня", "дней"))
        end,
        progress = function(ctx, ws) return countDays(ctx, ws, ws + 6, 900) end,
    },
    {
        id = "hours", unit = "time",
        make = function(p)
            local t = clamp(math.ceil(p.avg_week_secs * 1.2 / 1800) * 1800, 3600, 12 * 3600)
            return t, hoursTitle(t)
        end,
        progress = function(ctx, ws) return sumDays(ctx, ws, ws + 6, "secs") end,
    },
    {
        id = "longday", unit = "time",
        make = function(p)
            local t = p.best_day_prev >= 5400 and 5400 or (p.best_day_prev >= 2700 and 3600 or 1800)
            local titles = { [1800] = "Полчаса с книгой за один день", [3600] = "Час с книгой за один день",
                             [5400] = "Полтора часа за один день" }
            return t, titles[t]
        end,
        progress = function(ctx, ws)
            local best = 0
            for d = ws, ws + 6 do
                local v = ctx.days[d]
                if v and v.secs > best then best = v.secs end
            end
            return best
        end,
    },
    {
        id = "weekend", kind = "weekend", min_secs = 1800,
        make = function() return 2, "По 30 минут в субботу и воскресенье" end,
        progress = function(ctx, ws) return countDays(ctx, ws + 5, ws + 6, 1800) end,
    },
    {
        id = "pages", unit = "pages",
        eligible = function(p) return p.avg_week_pages >= 20 end,
        make = function(p)
            local t = clamp(math.floor(p.avg_week_pages * 1.2 / 10 + 0.5) * 10, 50, 1500)
            return t, string.format("%d %s за неделю", t, UI.plural(t, "страница", "страницы", "страниц"))
        end,
        progress = function(ctx, ws) return sumDays(ctx, ws, ws + 6, "pages") end,
    },
    {
        id = "morning", kind = "morning",
        make = function() return 3, "Три утра с книгой", "по 10 минут до 10 часов" end,
        progress = function(ctx, ws)
            local n = 0
            for d = ws, ws + 6 do
                if morningSecs(ctx, d) >= 600 then n = n + 1 end
            end
            return n
        end,
    },
    {
        id = "finish",
        eligible = function(p) return p.current_pct and p.current_pct >= 0.5 end,
        make = function() return 1, "Дочитать книгу" end,
        live_hint = function(ctx)
            local cur = ctx.current
            if not cur or cur.status == "complete" or not cur.percent then return nil end
            local left = math.max(1, math.floor((1 - cur.percent) * 100 + 0.5))
            return string.format("например, «%s» — осталось %d %%", cur.title or cur.name or "", left)
        end,
        progress = function(ctx, ws)
            for _, e in ipairs(ctx.fin_asc) do
                if e.day and e.day >= ws and e.day <= ws + 6 then return 1 end
            end
            return 0
        end,
    },
    {
        id = "comeback",
        eligible = function(p) return p.returnable > 0 end,
        make = function() return 1, "Вернуться к отложенной книге", "15 минут с книгой, которую не открывали месяц" end,
        progress = function(ctx, ws)
            local before, recent, now = returnedBooks(ctx, ws)
            for id, secs in pairs(now) do
                if secs >= 900 and before[id] and not recent[id] then return 1 end
            end
            return 0
        end,
    },
    {
        id = "streak7", kind = "days", min_secs = 600,
        eligible = function(p) return p.avg_days15 >= 5 end,
        make = function() return 7, "Ни дня без книги", "по 10 минут каждый день" end,
        progress = function(ctx, ws) return countDays(ctx, ws, ws + 6, 600) end,
    },
}

local function challengeById(id)
    for _, c in ipairs(A.CHALLENGES) do
        if c.id == id then return c end
    end
end

-- What the last four weeks looked like, for choosing this week's targets.
local function recentPace(ctx, ws)
    local p = {
        avg_days15 = countDays(ctx, ws - 28, ws - 1, 900) / 4,
        avg_week_secs = sumDays(ctx, ws - 28, ws - 1, "secs") / 4,
        avg_week_pages = sumDays(ctx, ws - 28, ws - 1, "pages") / 4,
        best_day_prev = 0,
        returnable = 0,
    }
    for d = ws - 28, ws - 1 do
        local v = ctx.days[d]
        if v and v.secs > p.best_day_prev then p.best_day_prev = v.secs end
    end
    local before, recent = returnedBooks(ctx, ws)
    for id in pairs(before) do
        if not recent[id] then p.returnable = p.returnable + 1 end
    end
    local cur = ctx.current
    if cur and cur.status ~= "complete" then p.current_pct = cur.percent end
    return p
end

local function pickChallenge(ctx, ws, last_id)
    local p = recentPace(ctx, ws)
    local pool = {}
    for _, c in ipairs(A.CHALLENGES) do
        if c.id ~= last_id and (not c.eligible or c.eligible(p)) then pool[#pool + 1] = c end
    end
    -- Stable for the week, different from week to week (Knuth's multiplicative hash).
    local week_number = math.floor(ws / 7)
    local h = (week_number * 2654435761) % 4294967296
    local c = pool[math.floor(h / 65536) % #pool + 1]
    local target, title, hint = c.make(p)
    return { id = c.id, target = target, title = title, hint = hint }
end

-- Updates polka_challenge: closes the previous week (if its challenge was met
-- after the last look, it still counts), picks this week's, records success.
local function updateChallenge(ctx)
    local st = readTable("polka_challenge")
    local ws = weekStart(ctx.today)
    local changed = false
    local function succeed(week, day)
        st.done = (tonumber(st.done) or 0) + 1
        st.streak = (st.last == week - 7) and (tonumber(st.streak) or 0) + 1 or 1
        st.last = week
        st.first_done = st.first_done or dayKey(day)
        st.done_day = dayKey(day)
        st.completed = true
        changed = true
    end
    local current = challengeById(st.id)
    if st.week ~= ws or not current or type(st.target) ~= "number" then
        -- A new week: the last one still counts if it was met after the last look.
        if current and type(st.week) == "number" and st.week < ws and not st.completed
                and st.week >= ctx.window_start and current.progress(ctx, st.week) >= (tonumber(st.target) or 1) then
            succeed(st.week, math.min(st.week + 6, ctx.today))
        end
        local pick = pickChallenge(ctx, ws, st.id)
        st.week, st.id, st.target, st.title, st.hint = ws, pick.id, pick.target, pick.title, pick.hint
        st.completed, st.done_day = false, nil
        current = challengeById(st.id)
        changed = true
    end
    local c = current
    local value = c.progress(ctx, ws)
    if value >= st.target and not st.completed then succeed(ws, ctx.today) end
    if changed then G_reader_settings:saveSetting("polka_challenge", st) end
    ctx.challenge_state = st
    -- Weeks in a row: still alive while last week's challenge was met.
    local streak = (st.last == ws or st.last == ws - 7) and (tonumber(st.streak) or 0) or 0

    local days
    if c.kind then
        days = {}
        for i = 0, 6 do
            local d = ws + i
            local ok
            if c.kind == "morning" then
                ok = morningSecs(ctx, d) >= 600
            else
                local v = ctx.days[d]
                ok = v ~= nil and v.secs >= (c.min_secs or 900)
            end
            local counts = c.kind ~= "weekend" or i >= 5
            days[i + 1] = { ok = ok, today = d == ctx.today, future = d > ctx.today, counts = counts }
        end
    end
    local hint = st.hint
    if c.live_hint then
        local ok, live = pcall(c.live_hint, ctx)
        if ok and live then hint = live end
    end
    return {
        id = st.id, title = st.title or "", hint = hint, target = st.target, value = value,
        unit = c.unit, kind = c.kind, days = days, done = st.completed and true or false,
        binary = st.target == 1 and not c.unit,
        days_left = ws + 6 - ctx.today + 1, total_done = tonumber(st.done) or 0, streak = streak,
        done_day = st.completed and st.done_day or nil,
    }
end

-- The model ---------------------------------------------------------------------------

-- The last model and what it was computed from; page turns and view
-- switches reuse it.
local last = nil

function A.reset()
    last = nil
end

-- s: the result of Stats.compute() (may be nil without statistics).
function A.compute(s)
    local off = s and s.raw and s.raw.off or localOffset()
    local today = s and s.today_day or math.floor((os.time() + off) / DAY)
    local goal = tonumber(G_reader_settings:readSetting("polka_goal")) or 24
    local key = table.concat({ s and s.raw and s.raw.sig or "-", Books.generation, goal, today }, "|")
    if last and last.key == key then return last.model end
    local model = A._compute(s, off, today, goal)
    last = { key = key, model = model }
    return model
end

function A._compute(s, off, today, goal)
    local c = s and s.raw

    -- Finished books, oldest first, with day numbers.
    local finished = Books:finished()
    local fin_asc = {}
    for i = #finished, 1, -1 do
        local e = finished[i]
        e.day = e.date and keyDay(e.date, off) or nil
        fin_asc[#fin_asc + 1] = e
    end

    local ctx = {
        off = off, today = today, goal = goal, year = tonumber(os.date("%Y")),
        count = #finished, fin_asc = fin_asc,
        window_start = today - (s and require("polka_stats").WINDOW_DAYS or 372),
        days = c and c.days or {}, hours = c and c.hours or {}, daybook = c and c.daybook or {},
        total_secs = c and c.secs or 0, total_pages = c and c.pages or 0,
        best_day_secs = s and s.best_day_secs or 0,
        current = Books:current(),
        by_md5 = {}, book_span = {},
    }

    -- Streaks: the first day each length was reached.
    ctx.streak_reach, ctx.best_streak = {}, 0
    local run, prev = 0, nil
    local weeks = {}
    for _, d in ipairs(s and s.read_days or {}) do
        run = (prev and d == prev + 1) and run + 1 or 1
        prev = d
        if run > ctx.best_streak then ctx.best_streak = run end
        if (run == 3 or run == 7 or run == 30 or run == 100) and not ctx.streak_reach[run] then
            ctx.streak_reach[run] = d
        end
        local w = weekStart(d)
        if weeks[#weeks] ~= w then weeks[#weeks + 1] = w end
    end
    -- Weeks in a row with any reading.
    ctx.best_weeks = 0
    local wrun, wprev = 0, nil
    for _, w in ipairs(weeks) do
        wrun = (wprev and w == wprev + 7) and wrun + 1 or 1
        wprev = w
        if wrun > ctx.best_weeks then ctx.best_weeks = wrun end
        if wrun == 12 and not ctx.weeks_reach then ctx.weeks_reach = w end
    end
    if ctx.weeks_reach then
        -- The first reading day of that twelfth week.
        for _, d in ipairs(s.read_days) do
            if d >= ctx.weeks_reach then
                ctx.weeks_reach = d
                break
            end
        end
    end

    -- Days in order, running totals, weekly totals.
    local order = {}
    for d in pairs(ctx.days) do order[#order + 1] = d end
    table.sort(order)
    ctx.day_secs, ctx.day_pages = {}, {}
    local win_secs, win_pages = 0, 0
    local week_sum, week_of = 0, nil
    ctx.best_week_secs, ctx.best_day_pages = 0, 0
    for _, d in ipairs(order) do
        local v = ctx.days[d]
        ctx.day_secs[#ctx.day_secs + 1] = { d, v.secs }
        ctx.day_pages[#ctx.day_pages + 1] = { d, v.pages }
        win_secs, win_pages = win_secs + v.secs, win_pages + v.pages
        if v.pages > ctx.best_day_pages then ctx.best_day_pages = v.pages end
        local w = weekStart(d)
        if w ~= week_of then week_of, week_sum = w, 0 end
        week_sum = week_sum + v.secs
        if week_sum > ctx.best_week_secs then ctx.best_week_secs = week_sum end
        if week_sum >= 36000 and not ctx.week10h_day then ctx.week10h_day = d end
    end
    ctx.secs_before = math.max(0, ctx.total_secs - win_secs)
    ctx.pages_before = math.max(0, ctx.total_pages - win_pages)

    -- Early and late reading, from hourly totals.
    local early, night = {}, {}
    for h, secs in pairs(ctx.hours) do
        local hour, d = h % 24, math.floor(h / 24)
        if hour >= 4 and hour < 7 then
            early[d] = (early[d] or 0) + secs
        elseif hour < 4 then
            night[d] = (night[d] or 0) + secs
        end
    end
    ctx.early_day = firstDay(early, function(x) return x >= 600 end)
    ctx.night_day = firstDay(night, function(x) return x >= 600 end)

    -- Books in the statistics: by checksum, and the days each was read.
    ctx.marks = 0
    local by_id = {}
    for id, b in pairs(c and c.books or {}) do
        if b.md5 then ctx.by_md5[b.md5] = b end
        by_id[id] = b
        ctx.marks = ctx.marks + (b.highlights or 0) + (b.notes or 0)
    end
    local wanted = {}
    for _, e in ipairs(fin_asc) do
        if e.info.md5 then wanted[e.info.md5] = true end
    end
    for d, per_book in pairs(ctx.daybook) do
        for id, secs in pairs(per_book) do
            local b = by_id[id]
            if b and b.md5 and wanted[b.md5] and secs >= 60 then
                local span = ctx.book_span[b.md5]
                if not span then
                    span = { first = d, last = d, secs = 0 }
                    ctx.book_span[b.md5] = span
                end
                if d < span.first then span.first = d end
                if d > span.last then span.last = d end
                span.secs = span.secs + secs
            end
        end
    end

    -- Weekly challenge (needs statistics).
    local challenge
    if c then
        challenge = updateChallenge(ctx)
    end
    ctx.challenge_state = ctx.challenge_state or readTable("polka_challenge")

    -- Badges.
    local store = readTable("polka_badges")
    local store_changed = false
    local badges, earned = {}, 0
    for _, def in ipairs(BADGES) do
        local ok, value, target, day = pcall(def.eval, ctx)
        if not ok then
            require("logger").warn("Polka: badge", def.id, value)
            value, target, day = 0, 1, nil
        end
        value, target = tonumber(value) or 0, tonumber(target) or 1
        local met = value >= target and target > 0
        local saved = store[def.id]
        if met and type(saved) ~= "table" then
            saved = { d = day and dayKey(day) or nil, t = dayKey(today) }
            store[def.id] = saved
            store_changed = true
        end
        local b = {
            id = def.id, title = def.title, num = def.num, cap = def.cap, icon = def.icon,
            hint = def.hint_fn and def.hint_fn(ctx) or def.hint,
            value = value, target = target,
            earned = type(saved) == "table",
            date = type(saved) == "table" and saved.d or nil,
            seen = type(saved) == "table" and saved.s and true or false,
        }
        b.progress = b.earned and 1 or math.max(0, math.min(1, value / math.max(1, target)))
        if b.earned then earned = earned + 1 end
        badges[#badges + 1] = b
    end
    if store_changed then G_reader_settings:saveSetting("polka_badges", store) end

    local rank, next_rank = A.rankFor(#finished)
    local viewed = store._viewed == true -- false until the badges were looked at once
    return {
        finished = finished,
        count = #finished,
        rank = rank,
        next_rank = next_rank,
        since = c and c.first_time or nil,
        total_secs = ctx.total_secs,
        total_pages = ctx.total_pages,
        badges = badges,
        badges_viewed = viewed,
        earned = earned,
        challenge = challenge,
        today = today,
    }
end

-- "Seen" marks: what was new stays marked until the view is left. -------------------

function A.unseenBadges(model)
    local n = 0
    for _, b in ipairs(model.badges) do
        if b.earned and not b.seen then n = n + 1 end
    end
    return n
end

-- Stamps on the card when it was last looked at; nil if never.
function A.cardSeen()
    return tonumber(G_reader_settings:readSetting("polka_card_seen"))
end

function A.unseenStamps(model)
    return math.max(0, model.count - (A.cardSeen() or 0))
end

function A.markBadgesSeen(model)
    local store = readTable("polka_badges")
    local changed = not store._viewed
    store._viewed = true
    for _, b in ipairs(model.badges) do
        local saved = store[b.id]
        if b.earned and type(saved) == "table" and not saved.s then
            saved.s = true
            changed = true
        end
    end
    if changed then G_reader_settings:saveSetting("polka_badges", store) end
    last = nil -- the seen marks are part of the model
end

function A.markCardSeen(model)
    if A.cardSeen() ~= model.count then
        G_reader_settings:saveSetting("polka_card_seen", model.count)
    end
end

return A
