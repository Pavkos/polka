-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Главная.

What you're reading (big), what you read recently (a row of covers) and your
shelves (the folders of the books directory). Sized to the screen: shelves
take whatever room is left.
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Books = require("polka_books")
local Covers = require("polka_covers")
local UI = require("polka_ui")

local Home = {}

local function progressLine(rec)
    if rec.status == "complete" then
        return "Прочитано"
    end
    if not rec.percent or rec.percent <= 0 then
        return "Ещё не начата"
    end
    local text = UI.percent(rec.percent)
    local left = Books:timeLeft(rec)
    if left then
        text = text .. " · осталось ≈ " .. UI.duration(left)
    end
    return text
end

local function currentCard(shell, rec, cw, max_h)
    local cover_w = math.floor(cw * 0.27)
    local cover_h = math.floor(cover_w * 1.5)
    if max_h and cover_h > max_h then
        cover_h = max_h
        cover_w = math.floor(cover_h / 1.5)
    end
    local gap = UI.px(18)
    local tw = cw - cover_w - gap

    local top = VerticalGroup:new{
        align = "left",
        UI.para{ text = rec.title or rec.name, family = "serif_bold", size = 22, width = tw, max_lines = 3, line_height = 0.12 },
        UI.vgap(UI.px(8)),
    }
    if rec.authors and rec.authors ~= "" then
        table.insert(top, UI.text{ text = rec.authors, size = 16, color = UI.C.text2, max_width = tw })
    end

    local button = UI.pill(UI.text{ text = "Читать", family = "sans_bold", size = 16 },
        { border = UI.px(2), border_color = UI.C.ink, hpad = UI.px(26), vpad = UI.px(7), radius = UI.px(8) })
    local bottom = VerticalGroup:new{
        align = "left",
        UI.bar(tw, UI.px(5), rec.percent or 0),
        UI.vgap(UI.px(8)),
        UI.text{ text = progressLine(rec), size = 15, color = UI.C.text2, max_width = tw },
        UI.vgap(UI.px(16)),
        button,
    }
    local right = OverlapGroup:new{
        dimen = Geom:new{ w = tw, h = cover_h },
        TopContainer:new{ dimen = Geom:new{ w = tw, h = cover_h }, top },
        BottomContainer:new{ dimen = Geom:new{ w = tw, h = cover_h }, UI.left(tw, bottom) },
    }
    local row = HorizontalGroup:new{
        align = "top",
        Covers.widget(rec, cover_w, cover_h),
        UI.hgap(gap),
        right,
    }
    return UI.tap(row, function() shell:openBook(rec.path) end, function() shell:bookActions(rec) end)
end

local function emptyCard(shell, cw)
    local group = VerticalGroup:new{
        align = "left",
        UI.para{ text = "Здесь будет книга, которую вы читаете", family = "serif_bold", size = 22, width = cw },
        UI.vgap(UI.px(8)),
        UI.para{ text = "Выберите что-нибудь в библиотеке — Полка запомнит, где вы остановились.",
                 size = 16, color = UI.C.text2, width = cw },
        UI.vgap(UI.px(18)),
        UI.tap(UI.pill(UI.text{ text = "Открыть библиотеку", family = "sans_bold", size = 16 },
            { border = UI.px(2), border_color = UI.C.ink, hpad = UI.px(22), vpad = UI.px(7), radius = UI.px(8) }),
            function() shell:openLibrary{ shelf = "*" } end),
    }
    return group
end

local function coverRow(shell, recs, cw, n, max_h)
    local gap = UI.px(16)
    local w = math.floor((cw - (n - 1) * gap) / n)
    local h = math.floor(w * 1.5)
    if max_h and h > max_h then
        h = max_h
    end
    local row = HorizontalGroup:new{ align = "top" }
    for i, rec in ipairs(recs) do
        local col = VerticalGroup:new{ align = "center", Covers.widget(rec, w, h), UI.vgap(UI.px(6)) }
        local fw = Covers.fittedWidth(rec, w, h)
        if rec.status == "complete" then
            table.insert(col, UI.bar(fw, UI.px(3), 1, UI.C.mid))
        elseif rec.percent and rec.percent > 0 then
            table.insert(col, UI.bar(fw, UI.px(3), rec.percent))
        else
            table.insert(col, UI.vgap(UI.px(3)))
        end
        table.insert(row, UI.tap(col, function() shell:openBook(rec.path) end, function() shell:bookActions(rec) end))
        if i < #recs then table.insert(row, UI.hgap(gap)) end
    end
    return row
end

local function shelfCell(shell, shelf, w, row_h)
    local count = UI.text{ text = tostring(shelf.count), size = 15, color = UI.C.text3 }
    local name = UI.text{ text = shelf.label, size = 17, max_width = w - count:getSize().w - UI.px(18) }
    local line = UI.split(w, name, count, row_h)
    return UI.tap(VerticalGroup:new{ align = "left", line, UI.hline(w) },
        function() shell:openLibrary{ shelf = shelf.name or "" } end)
end

-- Shelves in two columns, filled top to bottom like a book index.
local function shelfGrid(shell, shelves, cw, row_h, rows)
    local gap = UI.px(28)
    local w = math.floor((cw - gap) / 2)
    local grid = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        local a, b = shelves[r], shelves[r + rows]
        table.insert(row, a and shelfCell(shell, a, w, row_h) or UI.hgap(w))
        table.insert(row, UI.hgap(gap))
        if b then table.insert(row, shelfCell(shell, b, w, row_h)) end
        table.insert(grid, row)
    end
    return grid
end

function Home.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end

    add(UI.vgap(UI.px(16)))
    local cur = Books:current()
    if cur then
        add(UI.sectionHeader(cw, "Продолжить чтение"))
        add(UI.vgap(UI.px(10)))
        add(currentCard(shell, cur, cw, math.floor(H * 0.36)))
    else
        add(emptyCard(shell, cw))
    end

    local n = cw > UI.px(520) and 5 or 4
    local recent = Books:recent(n, cur and cur.path)
    if #recent > 0 then
        add(UI.vgap(UI.px(24)))
        add(UI.sectionHeader(cw, "Недавние", "Все", function() shell:openLibrary{ shelf = "*", sort = "recent" } end))
        add(UI.vgap(UI.px(8)))
        add(coverRow(shell, recent, cw, n, math.floor(H * 0.25)))
    end

    local shelves = Books.shelves or {}
    if #shelves > 0 then
        add(UI.vgap(UI.px(24)))
        add(UI.sectionHeader(cw, "Полки", "Все книги", function() shell:openLibrary{ shelf = "*" } end))
        add(UI.vgap(UI.px(2)))
        local row_h = UI.px(40)
        local room = H - used - UI.px(10)
        local rows_fit = math.floor(room / (row_h + UI.px(1)))
        local rows_needed = math.ceil(#shelves / 2)
        if rows_fit >= rows_needed then
            add(shelfGrid(shell, shelves, cw, row_h, rows_needed))
        elseif rows_fit > 0 then
            -- Not everything fits: show what does, the last cell leads to the library.
            local visible = {}
            local cells = rows_fit * 2 - 1
            for i = 1, cells do visible[i] = shelves[i] end
            local rest = #shelves - cells
            visible[#visible + 1] = {
                label = string.format("Ещё %d %s", rest, UI.plural(rest, "полка", "полки", "полок")),
                count = "›", name = "*",
            }
            add(shelfGrid(shell, visible, cw, row_h, rows_fit))
        end
    end

    return UI.pad(vg, { left = M, right = M })
end

return Home
