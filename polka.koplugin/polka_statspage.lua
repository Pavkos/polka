-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Статистика.

Three views behind a segmented switch:
  Обзор     three big numbers, this week as bars, the weekly challenge, the
            last year as a calendar heatmap and a few records;
  Формуляр  the reader's library card: rank, and every finished book with
            its "ПРОЧИТАНО" stamp;
  Значки    thirty badges, one theme per row.
New stamps and badges are marked only here (a dot on the switch, "новый"
under a badge) and count as seen once their view is left.
]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")

local A = require("polka_achievements")
local Art = require("polka_art")
local Books = require("polka_books")
local Stats = require("polka_stats")
local UI = require("polka_ui")

local StatsPage = {}

local floor = math.floor

local function thisYear()
    return os.date("%Y")
end

local function goal()
    return tonumber(G_reader_settings:readSetting("polka_goal")) or 24
end

function StatsPage.editGoal(shell)
    UIManager:show(SpinWidget:new{
        title_text = "Цель на " .. thisYear() .. " год",
        info_text = "Сколько книг хотите прочитать за год",
        value = goal(),
        value_min = 1,
        value_max = 365,
        value_step = 1,
        value_hold_step = 10,
        ok_text = "Сохранить",
        cancel_text = "Отмена",
        callback = function(spin)
            G_reader_settings:saveSetting("polka_goal", spin.value)
            shell:refresh("ui")
        end,
    })
end

-- Shared pieces ------------------------------------------------------------------

-- Section title on the left, a quiet summary on the right.
local function header(cw, title, summary)
    local left = UI.text{ text = title, family = "sans_bold", size = 14, color = UI.C.text2 }
    local right = summary and UI.text{ text = summary, size = 14, color = UI.C.text2,
                                       max_width = cw - left:getSize().w - UI.px(20) }
    return UI.split(cw, left, right)
end

local function dot(color)
    local d = UI.px(7)
    return UI.canvas(d, d, function(bb, x, y, w) bb:paintCircle(x + floor(w / 2), y + floor(w / 2), floor(w / 2), color) end)
end

-- Обзор · Формуляр · Значки
StatsPage.VIEWS = {
    { id = "overview", label = "Обзор" },
    { id = "card", label = "Формуляр" },
    { id = "badges", label = "Значки" },
}

local function segments(shell, cw, dots)
    local active = shell.stats_view or "overview"
    local n = #StatsPage.VIEWS
    local seg_w = floor(cw / n)
    local w = seg_w * n
    local h = UI.px(34)
    local r = UI.px(8)
    local bw = math.max(1, UI.px(1))
    local active_i = 1
    for i, v in ipairs(StatsPage.VIEWS) do
        if v.id == active then active_i = i end
    end
    local frame = UI.canvas(w, h, function(bb, x, y)
        bb:paintRoundedRect(x, y, w, h, UI.C.ink, r)
        bb:paintRoundedRect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, UI.C.paper, r - bw)
        local sx = x + (active_i - 1) * seg_w
        if active_i == 1 then
            bb:paintRoundedRect(sx, y, seg_w, h, UI.C.ink, r)
            bb:paintRect(sx + seg_w - r, y, r, h, UI.C.ink)
        elseif active_i == n then
            bb:paintRoundedRect(sx, y, seg_w, h, UI.C.ink, r)
            bb:paintRect(sx, y, r, h, UI.C.ink)
        else
            bb:paintRect(sx, y, seg_w, h, UI.C.ink)
        end
        for i = 2, n do
            if i ~= active_i and i - 1 ~= active_i then
                bb:paintRect(x + (i - 1) * seg_w, y + UI.px(8), bw, h - 2 * UI.px(8), UI.C.line)
            end
        end
    end)
    local labels = HorizontalGroup:new{ align = "center" }
    for i, v in ipairs(StatsPage.VIEWS) do
        local on = i == active_i
        local label = HorizontalGroup:new{
            align = "center",
            UI.text{ text = v.label, size = 15, family = on and "sans_bold" or "sans", color = on and UI.C.paper or UI.C.ink },
        }
        if dots[v.id] and not on then
            table.insert(label, UI.hgap(UI.px(6)))
            table.insert(label, dot(UI.C.ink))
        end
        table.insert(labels, UI.tap(UI.center(seg_w, h, label), function() shell:setStatsView(v.id) end))
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, frame, labels }
end

-- Обзор ---------------------------------------------------------------------------

local function bigNumber(value, caption, w, cb)
    local group = VerticalGroup:new{
        align = "left",
        UI.text{ text = value, family = "serif_bold", size = 34, max_width = w },
        UI.vgap(UI.px(2)),
        UI.text{ text = caption, size = 14, color = UI.C.text2, max_width = w },
    }
    local box = UI.left(w, group)
    if cb then return UI.tap(box, cb) end
    return box
end

local function heroRow(shell, s, cw, finished)
    local col_w = floor(cw / 3)
    local today = s.today >= 60 and UI.duration(s.today, false) or "0 мин"
    local g = goal()
    return HorizontalGroup:new{
        align = "top",
        bigNumber(today, "сегодня", col_w),
        bigNumber(tostring(s.streak), UI.plural(s.streak, "день подряд", "дня подряд", "дней подряд"), col_w),
        bigNumber(string.format("%d из %d", finished, g), "книг за " .. thisYear() .. " год", cw - 2 * col_w,
            function() StatsPage.editGoal(shell) end),
    }
end

local function weekChart(s, cw, chart_h)
    local col_w = floor(cw / 7)
    local bar_w = floor(col_w * 0.46)
    local max_secs = 30 * 60
    for _, d in ipairs(s.week) do
        if d.secs > max_secs then max_secs = d.secs end
    end
    local row = HorizontalGroup:new{ align = "bottom" }
    for i, d in ipairs(s.week) do
        local h = 0
        if d.secs > 0 then
            h = math.max(UI.px(3), floor(chart_h * d.secs / max_secs + 0.5))
        end
        local bar = UI.canvas(bar_w, chart_h, function(bb, x, y, w, ch)
            bb:paintRect(x, y + ch - UI.px(1), w, UI.px(1), UI.C.line)
            if h > 0 then
                bb:paintRect(x, y + ch - h, w, h, d.is_today and UI.C.ink or UI.C.mid)
            end
        end)
        local value = d.secs >= 60 and tostring(floor(d.secs / 60 + 0.5)) or (d.future and "" or "·")
        local col = VerticalGroup:new{
            align = "center",
            UI.text{ text = value, size = 12, color = d.is_today and UI.C.ink or UI.C.text3,
                     family = d.is_today and "sans_bold" or "sans" },
            UI.vgap(UI.px(4)),
            bar,
            UI.vgap(UI.px(6)),
            UI.text{ text = UI.WEEKDAYS[i], size = 13, color = d.is_today and UI.C.ink or UI.C.text2,
                     family = d.is_today and "sans_bold" or "sans" },
        }
        table.insert(row, UI.center(col_w, nil, col))
    end
    return row
end

local function heatColor(secs)
    if secs < 60 then return UI.C.tint end
    if secs < 15 * 60 then return UI.C.line end
    if secs < 30 * 60 then return UI.C.mid end
    if secs < 60 * 60 then return UI.C.text2 end
    return UI.C.ink
end

local function heatmap(s, cw)
    local weeks = s.heat.weeks
    local step = floor(cw / weeks)
    local gap = math.max(1, floor(step * 0.2))
    local cell = step - gap
    local grid_w = step * weeks - gap
    local grid_h = step * 7 - gap
    local cells = s.heat.cells
    local canvas = UI.canvas(grid_w, grid_h, function(bb, x, y)
        for w = 1, weeks do
            for d = 1, 7 do
                local c = cells[w][d]
                if not c.future then
                    bb:paintRect(x + (w - 1) * step, y + (d - 1) * step, cell, cell, heatColor(c.secs))
                end
            end
        end
    end)
    -- Month labels above the first column of each month. The newest month always
    -- has its label (moved left to fit at the right edge); an older one that would
    -- run into the label after it is left out.
    local probe = UI.text{ text = "Ag", size = 11 }
    local labels = OverlapGroup:new{ dimen = Geom:new{ w = grid_w, h = probe:getSize().h } }
    probe:free()
    local marks = {}
    local prev_month
    for w = 1, weeks do
        local month = tonumber(os.date("%m", cells[w][1].t))
        if prev_month and month ~= prev_month then
            local text = UI.text{ text = UI.MONTHS_SHORT[month], size = 11, color = UI.C.text3 }
            marks[#marks + 1] = { x = (w - 1) * step, text = text, w = text:getSize().w }
        end
        prev_month = month
    end
    local next_x = grid_w + UI.px(6)
    for i = #marks, 1, -1 do
        local m = marks[i]
        local x = math.max(0, math.min(m.x, grid_w - m.w))
        if i == #marks or x + m.w + UI.px(6) <= next_x then
            table.insert(labels, UI.pad(m.text, { left = x }))
            next_x = x
        else
            m.text:free()
        end
    end
    -- Legend.
    local legend = HorizontalGroup:new{ align = "center",
        UI.text{ text = "меньше", size = 11, color = UI.C.text3 }, UI.hgap(UI.px(6)) }
    for _, secs in ipairs({ 0, 10 * 60, 20 * 60, 45 * 60, 90 * 60 }) do
        table.insert(legend, UI.canvas(cell, cell, function(bb, x, y, w, h) bb:paintRect(x, y, w, h, heatColor(secs)) end))
        table.insert(legend, UI.hgap(math.max(2, gap)))
    end
    table.insert(legend, UI.hgap(UI.px(4)))
    table.insert(legend, UI.text{ text = "больше", size = 11, color = UI.C.text3 })
    return VerticalGroup:new{
        align = "left",
        labels,
        UI.vgap(UI.px(4)),
        canvas,
        UI.vgap(UI.px(8)),
        UI.right(grid_w, legend),
    }
end

local function dayLabel(key)
    if not key then return "—" end
    return A.formatDate(key) or key
end

local function tile(value, caption, w)
    return UI.left(w, VerticalGroup:new{
        align = "left",
        UI.text{ text = value, family = "serif_bold", size = 22, max_width = w - UI.px(8) },
        UI.vgap(UI.px(2)),
        UI.text{ text = caption, size = 13, color = UI.C.text2, max_width = w - UI.px(8) },
    })
end

local function noStats(cw)
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, UI.vgap(UI.px(40)))
    table.insert(vg, UI.para{ text = "Здесь появится ваша статистика: минуты за день, серии, год по дням и прочитанные книги.",
                              family = "serif_bold", size = 20, width = cw, align = "center" })
    table.insert(vg, UI.vgap(UI.px(12)))
    table.insert(vg, UI.para{ text = "Она собирается сама — достаточно почитать несколько минут.",
                              size = 16, width = cw, color = UI.C.text2, align = "center" })
    return vg
end

local STAMP_COLOR = UI.C.ink -- the ink texture itself makes it look stamped

local function stampDate(key)
    local y, m, d = tostring(key or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return string.format("%s.%s.%s", d, m, y)
end

-- The week as seven segments: black for a day that counts, outlined today.
local function daySegments(ch, w)
    local gap = UI.px(4)
    local seg = floor((w - 6 * gap) / 7)
    local h = UI.px(7)
    local bw = math.max(1, UI.px(1))
    local bar = UI.canvas(seg * 7 + gap * 6, h, function(bb, x, y)
        for i, day in ipairs(ch.days) do
            local sx = x + (i - 1) * (seg + gap)
            local color = UI.C.track
            if day.ok then
                color = UI.C.ink
            elseif not day.counts then
                color = UI.C.tint
            elseif not day.future then
                color = UI.C.line
            end
            bb:paintRect(sx, y, seg, h, color)
            if day.today and not day.ok then bb:paintBorder(sx, y, seg, h, bw, UI.C.text2) end
        end
    end)
    local labels = HorizontalGroup:new{ align = "top" }
    for i, day in ipairs(ch.days) do
        table.insert(labels, UI.center(seg, nil, UI.text{
            text = UI.WEEKDAYS[i], size = 11,
            family = day.today and "sans_bold" or "sans",
            color = day.today and UI.C.ink or (day.counts and UI.C.text3 or UI.C.line),
        }))
        if i < 7 then table.insert(labels, UI.hgap(gap)) end
    end
    return VerticalGroup:new{ align = "left", bar, UI.vgap(UI.px(3)), labels }
end

local function challengeValue(ch, v)
    if ch.unit == "time" then return UI.duration(v) end
    return tostring(floor(v))
end

local function challengeStrip(ch, cw)
    local vg = VerticalGroup:new{ align = "left" }
    local note
    if ch.done then
        note = ch.streak > 1 and string.format("%d %s подряд", ch.streak, UI.plural(ch.streak, "неделя", "недели", "недель"))
            or "выполнено"
    else
        note = string.format("осталось %d %s", ch.days_left, UI.plural(ch.days_left, "день", "дня", "дней"))
    end
    table.insert(vg, header(cw, "Вызов недели", note))
    table.insert(vg, UI.vgap(UI.px(6)))
    local right_w = UI.px(128)
    local left_w = cw - right_w
    local left = VerticalGroup:new{ align = "left" }
    table.insert(left, UI.text{ text = ch.title, family = "serif_bold", size = 19, max_width = left_w - UI.px(8) })
    if ch.hint then
        table.insert(left, UI.text{ text = ch.hint, size = 13, color = UI.C.text2, max_width = left_w - UI.px(8) })
    end
    if ch.days then
        table.insert(left, UI.vgap(UI.px(8)))
        table.insert(left, daySegments(ch, left_w - UI.px(16)))
    elseif not ch.binary then
        table.insert(left, UI.vgap(UI.px(10)))
        table.insert(left, UI.bar(left_w - UI.px(16), UI.px(5), math.min(1, ch.value / math.max(1, ch.target))))
    end
    local right
    if ch.done then
        right = Art.stamp({ "ЗАЧТЕНО", stampDate(ch.done_day) or "" },
            { size = 11, seed = Art.seed("week" .. tostring(ch.done_day)), color = STAMP_COLOR })
    elseif not ch.binary then
        right = VerticalGroup:new{
            align = "right",
            UI.text{ text = challengeValue(ch, math.min(ch.value, ch.target)), family = "serif_bold", size = ch.unit == "time" and 19 or 24 },
            UI.text{ text = "из " .. challengeValue(ch, ch.target), size = 13, color = UI.C.text2 },
        }
    end
    local lh = left:getSize().h
    local row = HorizontalGroup:new{ align = "center", UI.left(left_w, left) }
    if right then
        local rh = math.max(lh, right:getSize().h)
        table.insert(row, UI.right(right_w, UI.center(right:getSize().w, rh, right)))
    end
    table.insert(vg, row)
    return vg
end

local function overview(shell, s, model, cw, H)
    if not s or (s.total_secs or 0) < 60 then return noStats(cw) end
    local vg = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(vg, w) end
    local finished = Books:finishedThisYear()

    add(UI.vgap(UI.px(12)))
    add(heroRow(shell, s, cw, finished))
    add(UI.vgap(UI.px(10)))
    add(UI.bar(cw, UI.px(4), math.min(1, finished / goal())))

    add(UI.vgap(UI.px(20)))
    add(header(cw, "Эта неделя", string.format("%s · в среднем %s в день", UI.duration(s.week_total), UI.duration(s.week_avg))))
    add(UI.vgap(UI.px(8)))
    add(weekChart(s, cw, UI.px(62)))

    local ch = model and model.challenge
    if ch then
        add(UI.vgap(UI.px(20)))
        add(challengeStrip(ch, cw))
    end

    add(UI.vgap(UI.px(20)))
    add(header(cw, "Последний год", string.format("%d %s с книгой · %s", s.heat.read_days,
        UI.plural(s.heat.read_days, "день", "дня", "дней"), UI.duration(s.heat.secs, true))))
    add(UI.vgap(UI.px(8)))
    add(heatmap(s, cw))

    add(UI.vgap(UI.px(18)))
    add(header(cw, "Рекорды за год", string.format("всего %s · %s стр.", UI.duration(s.total_secs, true), UI.number(s.total_pages))))
    add(UI.vgap(UI.px(8)))
    local col_w = floor(cw / 3)
    add(HorizontalGroup:new{
        align = "top",
        tile(s.best_day and UI.duration(s.best_day_secs) or "—", s.best_day and ("лучший день, " .. dayLabel(s.best_day)) or "лучший день", col_w),
        tile(string.format("%d %s", s.best_streak, UI.plural(s.best_streak, "день", "дня", "дней")), "самая длинная серия", col_w),
        tile(string.format("≈ %d стр./ч", floor(s.pages_per_hour + 0.5)), "скорость за месяц", cw - 2 * col_w),
    })
    return vg
end

-- Формуляр -------------------------------------------------------------------------

-- "Ч И Т А Т Е Л Ь С К И Й": letters apart, like a printed form.
local function spaced(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch == " " and "   " or ch
    end
    return table.concat(out, "\226\128\137") -- thin space
end

local function vline(h)
    return UI.canvas(math.max(1, UI.px(1)), h, function(bb, x, y, w, hh) bb:paintRect(x, y, w, hh, UI.C.line) end)
end

-- Lays a stamp over its cell without growing the row: real stamps run over the rules.
local Overflow = Widget:extend{ w = 0, h = 0 }

function Overflow:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function Overflow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local child = self[1]
    local sz = child:getSize()
    child:paintTo(bb, x + floor((self.w - sz.w) / 2), y + floor((self.h - sz.h) / 2))
end

function Overflow:free()
    if self[1] and self[1].free then self[1]:free() end
end

local function rankBlock(model, cw)
    local vg = VerticalGroup:new{ align = "left" }
    local rank, nxt = model.rank, model.next_rank
    local seen = A.cardSeen()
    local promoted = seen ~= nil and A.rankFor(seen).n < rank.n
    local name = UI.text{ text = rank.name, family = "serif_bold", size = 26, max_width = cw - UI.px(150) }
    local line = HorizontalGroup:new{ align = "center", name }
    if promoted then
        table.insert(line, UI.hgap(UI.px(12)))
        table.insert(line, UI.pill(UI.text{ text = "новое звание", size = 12, family = "sans_bold", color = UI.C.paper },
            { background = UI.C.ink, border_color = UI.C.ink, hpad = UI.px(8), vpad = UI.px(2), radius = UI.px(10) }))
    end
    table.insert(vg, line)
    local facts = {}
    if model.since then
        facts[#facts + 1] = "читатель с " .. (A.formatDate(os.date("%Y-%m-%d", model.since), true) or "")
    end
    facts[#facts + 1] = UI.books(model.count)
    if model.total_pages > 0 then facts[#facts + 1] = UI.number(model.total_pages) .. " стр." end
    if model.total_secs >= 3600 then facts[#facts + 1] = UI.number(floor(model.total_secs / 3600)) .. " ч" end
    table.insert(vg, UI.vgap(UI.px(2)))
    table.insert(vg, UI.text{ text = table.concat(facts, " · "), size = 14, color = UI.C.text2, max_width = cw })
    if nxt then
        local left = nxt.n - model.count
        table.insert(vg, UI.vgap(UI.px(10)))
        table.insert(vg, UI.split(cw,
            UI.text{ text = string.format("до звания «%s»", nxt.name), size = 14, color = UI.C.text2, max_width = cw - UI.px(140) },
            UI.text{ text = string.format("ещё %s", UI.books(left)), size = 14, family = "sans_bold", color = UI.C.text2 }))
        table.insert(vg, UI.vgap(UI.px(6)))
        table.insert(vg, UI.bar(cw, UI.px(3), (model.count - model.rank.n) / math.max(1, nxt.n - model.rank.n)))
    end
    return vg
end

local function card(shell, model, cw, H)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(UI.vgap(UI.px(10)))
    add(rankBlock(model, cw))
    add(UI.vgap(UI.px(18)))

    -- The card: a ruled form with three columns.
    local border = math.max(1, UI.px(1))
    local inner = cw - 2 * border
    local num_w = UI.px(46)
    local stamp_size = 11
    local probe = Art.stamp({ "ПРОЧИТАНО", "00.00.0000" }, { size = stamp_size, angle = 0, seed = 7 })
    local stamp_w = probe:getSize().w + UI.px(22)
    local text_w = inner - num_w - stamp_w - 2 * border
    local pad = UI.px(10)
    local title_h = UI.text{ text = "Ag", family = "serif", size = 17 }:getSize().h
    local author_h = UI.text{ text = "Ag", size = 13 }:getSize().h
    local row_h = math.max(title_h + author_h + UI.px(12), probe:getSize().h)

    local head_text = UI.text{ text = spaced("ЧИТАТЕЛЬСКИЙ ФОРМУЛЯР"), family = "serif_bold", size = 14 }
    local head = UI.center(inner, head_text:getSize().h + UI.px(20), head_text)
    local colhead_h = UI.text{ text = "Ag", size = 11 }:getSize().h + UI.px(8)
    local function colhead(text, w, align)
        local t = UI.text{ text = text, size = 11, family = "sans_bold", color = UI.C.text3, max_width = w - UI.px(8) }
        if align == "left" then return UI.left(w, UI.pad(t, { left = UI.px(10) })) end
        return UI.center(w, colhead_h, t)
    end
    local colheads = HorizontalGroup:new{
        align = "center",
        colhead("№", num_w), vline(colhead_h),
        UI.center(text_w, colhead_h, UI.left(text_w, UI.pad(UI.text{ text = "КНИГА", size = 11, family = "sans_bold", color = UI.C.text3 }, { left = pad }))),
        vline(colhead_h),
        colhead("ОТМЕТКА", stamp_w),
    }
    local fixed = head:getSize().h + colhead_h + 2 * border + UI.px(3) * 2
    local footer_h = UI.px(52)
    local avail = H - used - fixed - footer_h - UI.px(8)
    local per_page = math.max(1, floor(avail / (row_h + border)))
    local total = model.count
    local pages = math.max(1, math.ceil(total / per_page))
    shell.card_pages = pages
    shell.card_page = math.max(1, math.min(shell.card_page or 1, pages))
    local first = (shell.card_page - 1) * per_page + 1
    local unseen = A.cardSeen() and A.unseenStamps(model) or 0

    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, head)
    table.insert(body, UI.hline(inner, UI.C.ink, border))
    table.insert(body, UI.vgap(UI.px(3)))
    table.insert(body, UI.hline(inner, UI.C.ink, border))
    table.insert(body, colheads)
    table.insert(body, UI.hline(inner, UI.C.line, border))

    if total == 0 then
        local msg = UI.para{
            text = "Здесь будут штампы о прочитанных книгах. Книга отмечается прочитанной в конце чтения или долгим нажатием на обложку → «Прочитано».",
            size = 15, color = UI.C.text2, width = text_w - 2 * pad, align = "center",
        }
        local rows_h = math.max(msg:getSize().h + 2 * pad, math.min(per_page, 3) * (row_h + border))
        table.insert(body, HorizontalGroup:new{
            align = "top",
            UI.hgap(num_w), vline(rows_h),
            UI.center(text_w, rows_h, msg),
            vline(rows_h), UI.hgap(stamp_w),
        })
        table.insert(body, UI.hline(inner, UI.C.line, border))
        for _ = 1, per_page - math.ceil(rows_h / (row_h + border)) do
            table.insert(body, HorizontalGroup:new{
                align = "top",
                UI.hgap(num_w), vline(row_h), UI.hgap(text_w), vline(row_h), UI.hgap(stamp_w),
            })
            table.insert(body, UI.hline(inner, UI.C.line, border))
        end
    else
        for i = first, math.min(total, first + per_page - 1) do
            local e = model.finished[i]
            local rec = Books:brief(Books:record(e.path))
            local number = total - i + 1
            local num = UI.text{ text = tostring(number), family = "serif", size = 15, color = UI.C.text2 }
            local num_cell = UI.center(num_w, row_h, num)
            if i <= unseen then
                num_cell = UI.center(num_w, row_h, HorizontalGroup:new{ align = "center", dot(UI.C.ink), UI.hgap(UI.px(4)), num })
            end
            local text = VerticalGroup:new{
                align = "left",
                UI.text{ text = rec.title or rec.name, family = "serif", size = 17, max_width = text_w - 2 * pad },
                UI.text{ text = (rec.authors and rec.authors ~= "") and rec.authors or "—", size = 13, color = UI.C.text2,
                         max_width = text_w - 2 * pad },
            }
            local lines = { "ПРОЧИТАНО" }
            local sd = stampDate(e.date)
            if sd then lines[2] = sd end
            local stamp = Art.stamp(lines, { size = stamp_size, seed = Art.seed(e.path), color = STAMP_COLOR })
            local row = HorizontalGroup:new{
                align = "center",
                num_cell, vline(row_h),
                UI.left(text_w, UI.pad(text, { left = pad })),
                vline(row_h),
                Overflow:new{ w = stamp_w, h = row_h, stamp },
            }
            table.insert(body, UI.tap(row, function() shell:bookActions(Books:info(Books:record(e.path))) end))
            table.insert(body, UI.hline(inner, UI.C.line, border))
        end
        for _ = math.min(total, first + per_page - 1) - first + 2, per_page do
            table.insert(body, HorizontalGroup:new{
                align = "top",
                UI.hgap(num_w), vline(row_h), UI.hgap(text_w), vline(row_h), UI.hgap(stamp_w),
            })
            table.insert(body, UI.hline(inner, UI.C.line, border))
        end
    end
    add(UI.FrameContainer:new{
        bordersize = border, color = UI.C.ink, padding = 0, margin = 0, background = UI.C.paper,
        body,
    })

    -- Pager, pinned to the bottom.
    local spare = H - used - footer_h
    if spare > 0 then add(UI.vgap(spare)) end
    if pages > 1 then
        local arrow = function(text, enabled, cb)
            return UI.tap(UI.center(UI.px(90), footer_h,
                UI.text{ text = text, size = 22, color = enabled and UI.C.ink or UI.C.line }),
                enabled and cb or function() end)
        end
        add(UI.center(cw, footer_h, HorizontalGroup:new{
            align = "center",
            arrow("‹", shell.card_page > 1, function() StatsPage.turn(shell, -1) end),
            UI.center(UI.px(140), footer_h, UI.text{ text = string.format("%d / %d", shell.card_page, pages), size = 15, color = UI.C.text2 }),
            arrow("›", shell.card_page < pages, function() StatsPage.turn(shell, 1) end),
        }))
    end
    return vg
end

function StatsPage.turn(shell, delta)
    local p = (shell.card_page or 1) + delta
    if p < 1 or p > (shell.card_pages or 1) then return true end
    shell.card_page = p
    shell:refresh("ui")
    return true
end

-- Значки ------------------------------------------------------------------------------

local function badgeCell(b, w, units, title_h, sub_h, fresh)
    local medal = Art.medallion{ units = units, earned = b.earned, progress = b.progress,
                                 num = b.num, cap = b.cap, icon = b.icon }
    local sub, sub_bold, sub_color
    if b.earned then
        if fresh then
            sub, sub_bold, sub_color = "новый", true, UI.C.ink
        else
            sub, sub_color = A.formatDate(b.date) or "получен", UI.C.text2
        end
    elseif b.num or b.id == "goal" or b.id == "author" or b.id == "shelves" or b.id == "marginalia" then
        local value = b.value
        if b.id == "pages1k" or b.id == "pages10k" then
            sub = string.format("%s из %s", UI.number(value), UI.number(b.target))
        else
            sub = string.format("%d из %d", math.min(value, b.target), b.target)
        end
        sub_color = UI.C.text3
    else
        sub, sub_color = b.hint, UI.C.text3
    end
    return VerticalGroup:new{
        align = "center",
        UI.center(w, medal:getSize().h, medal),
        UI.vgap(UI.px(6)),
        UI.center(w, title_h, UI.text{ text = b.title, size = 12, family = b.earned and "sans_bold" or "sans",
                                       color = b.earned and UI.C.ink or UI.C.text2, max_width = w - UI.px(6) }),
        UI.center(w, sub_h, UI.text{ text = sub or "", size = 11, family = sub_bold and "sans_bold" or "sans",
                                     color = sub_color, max_width = w - UI.px(6) }),
    }
end

local function badges(shell, model, cw, H)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(UI.vgap(UI.px(14)))
    add(header(cw, "Значки", string.format("получено %d из %d", model.earned, #model.badges)))
    add(UI.vgap(UI.px(14)))

    -- New badges stay marked until the view is left.
    shell._fresh_badges = shell._fresh_badges or {}
    for _, b in ipairs(model.badges) do
        if b.earned and not b.seen and model.badges_viewed then shell._fresh_badges[b.id] = true end
    end

    local cols = A.ROW
    local rows = math.ceil(#model.badges / cols)
    local cell_w = floor(cw / cols)
    local title_h = UI.text{ text = "Ag", size = 12 }:getSize().h
    local sub_h = UI.text{ text = "Ag", size = 11 }:getSize().h
    local row_gap = UI.px(12)
    local text_h = UI.px(6) + title_h + sub_h
    local avail = H - used - UI.px(6)
    local per_row = floor((avail - (rows - 1) * row_gap) / rows)
    local medal_px = math.max(UI.px(36), math.min(per_row - text_h, floor(cell_w * 0.46), UI.px(48)))
    local units = floor(medal_px * 100 / UI.px(100))
    local grid = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, cols do
            local b = model.badges[(r - 1) * cols + c]
            if b then
                table.insert(row, badgeCell(b, cell_w, units, title_h, sub_h, shell._fresh_badges[b.id]))
            end
        end
        table.insert(grid, row)
        if r < rows then table.insert(grid, UI.vgap(row_gap)) end
    end
    add(grid)
    return vg
end

-- Build -----------------------------------------------------------------------------------

function StatsPage.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local view = shell.stats_view or "overview"
    local s = Stats.compute()
    local ok, model = pcall(A.compute, s)
    if not ok then
        logger.warn("Polka: achievements failed:", model)
        model = nil
    end
    shell._ach_model = model

    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(UI.vgap(UI.px(12)))
    add(segments(shell, cw, {
        card = model and A.unseenStamps(model) > 0,
        badges = model and A.unseenBadges(model) > 0,
    }))
    add(UI.vgap(UI.px(4)))
    local rest = H - used
    local content
    if view == "card" and model then
        content = card(shell, model, cw, rest)
    elseif view == "badges" and model then
        content = badges(shell, model, cw, rest)
    else
        content = overview(shell, s, model, cw, rest)
    end
    add(content)
    return UI.pad(vg, { left = M, right = M })
end

-- Called by the shell when the user leaves a view: what was new is now seen.
function StatsPage.leave(shell)
    local model = shell._ach_model
    if not model then return end
    local view = shell.stats_view or "overview"
    if view == "badges" then
        A.markBadgesSeen(model)
        shell._fresh_badges = nil
    elseif view == "card" then
        A.markCardSeen(model)
    end
end

return StatsPage
