--[[--
Polka: Библиотека.

A grid of covers, one shelf (top-level folder) at a time or everything at
once. Shelf chips across the top, a sort switch and page arrows; swipe left
and right to turn pages.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Books = require("polka_books")
local Covers = require("polka_covers")
local UI = require("polka_ui")

local Library = {}

local LAYOUTS = {
    [6] = { cols = 3, rows = 2 },
    [9] = { cols = 3, rows = 3 },
    [12] = { cols = 4, rows = 3 },
}

local function chip(text, active, cb)
    local label = UI.text{
        text = text,
        size = 15,
        family = active and "sans_bold" or "sans",
        color = active and UI.C.paper or UI.C.ink,
    }
    return UI.tap(UI.pill(label, {
        background = active and UI.C.ink or UI.C.paper,
        border_color = active and UI.C.ink or UI.C.mid,
        hpad = UI.px(13), vpad = UI.px(5), radius = UI.px(16),
    }), cb)
end

local function shelfDialog(shell)
    local dialog
    local buttons = {}
    local function pick(name)
        UIManager:close(dialog)
        shell:openLibrary{ shelf = name }
    end
    table.insert(buttons, {{
        text = "Все книги" .. (shell.lib.shelf == "*" and "  ✓" or ""),
        callback = function() pick("*") end,
    }})
    for _, s in ipairs(Books.shelves or {}) do
        local id = s.name or ""
        table.insert(buttons, {{
            text = string.format("%s · %d%s", s.label, s.count, shell.lib.shelf == id and "  ✓" or ""),
            callback = function() pick(id) end,
        }})
    end
    dialog = ButtonDialog:new{ title = "Полки", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

local function sortDialog(shell)
    local dialog
    local buttons = {}
    for _, s in ipairs(Books.SORTS) do
        table.insert(buttons, {{
            text = s.label .. (shell.lib.sort == s.id and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                G_reader_settings:saveSetting("polka_sort", s.id)
                shell:openLibrary{ sort = s.id }
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = "Сортировка", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Chips that fit on one line; overflow goes into "Ещё".
local function chipsRow(shell, cw)
    local gap = UI.px(8)
    local current = shell.lib.shelf
    local items = { { id = "*", label = "Все" } }
    local active_item
    for _, s in ipairs(Books.shelves or {}) do
        local it = { id = s.name or "", label = s.label }
        if it.id == current then active_item = it end
        items[#items + 1] = it
    end
    local more = chip("Ещё  ▾", false, function() shelfDialog(shell) end)
    local more_w = more:getSize().w
    local function fit(list)
        local chips, used = {}, 0
        for i, it in ipairs(list) do
            local c = chip(it.label, it.id == current, function() shell:openLibrary{ shelf = it.id } end)
            local w = c:getSize().w
            local need = used + (#chips > 0 and gap or 0) + w
            local rest = #list - i
            if need + (rest > 0 and (gap + more_w) or 0) > cw then break end
            chips[#chips + 1] = { chip = c, item = it }
            used = need
        end
        return chips
    end
    -- Natural order; if the active shelf doesn't fit, pull it right after "Все".
    local chips = fit(items)
    if active_item then
        local visible = false
        for _, c in ipairs(chips) do
            if c.item == active_item then visible = true end
        end
        if not visible then
            for i = #items, 2, -1 do
                if items[i] == active_item then table.remove(items, i) end
            end
            table.insert(items, 2, active_item)
            chips = fit(items)
        end
    end
    local row = HorizontalGroup:new{ align = "center" }
    for i, c in ipairs(chips) do
        if i > 1 then table.insert(row, UI.hgap(gap)) end
        table.insert(row, c.chip)
    end
    if #chips < #items then
        if #chips > 0 then table.insert(row, UI.hgap(gap)) end
        table.insert(row, more)
    end
    return row
end

function Library.layout(shell)
    local n = tonumber(G_reader_settings:readSetting("polka_grid")) or 9
    return LAYOUTS[n] or LAYOUTS[9]
end

function Library.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end

    add(UI.vgap(UI.px(14)))
    add(chipsRow(shell, cw))
    add(UI.vgap(UI.px(12)))

    local items = Books:list(shell.lib.shelf, shell.lib.sort, shell.lib.query)
    local sort_label = "Недавние"
    for _, s in ipairs(Books.SORTS) do
        if s.id == shell.lib.sort then sort_label = s.label end
    end
    local sorter = UI.tap(UI.text{ text = sort_label .. "  ▾", size = 15, family = "sans_bold", color = UI.C.text2 },
        function() sortDialog(shell) end)
    local right
    if shell.lib.query then
        right = UI.tap(UI.pill(UI.text{ text = "«" .. shell.lib.query .. "»   ✕", size = 14 },
            { hpad = UI.px(10), vpad = UI.px(3), radius = UI.px(12) }),
            function() shell:openLibrary{ query = "" } end)
    else
        right = UI.text{ text = UI.books(#items), size = 15, color = UI.C.text2 }
    end
    add(UI.split(cw, sorter, right, UI.px(30)))
    add(UI.vgap(UI.px(14)))

    local lay = Library.layout(shell)
    local cols, rows = lay.cols, lay.rows
    local gap_x = UI.px(16)
    local gap_y = UI.px(16)
    local footer_h = UI.px(52)
    local cell_w = math.floor((cw - (cols - 1) * gap_x) / cols)
    local title_face_h = UI.text{ text = "Ag", size = 14 }:getSize().h
    local caption_h = UI.px(6) + UI.px(3) + UI.px(5) + title_face_h
    local avail = H - used - footer_h
    local cover_h = math.floor((avail - (rows - 1) * gap_y) / rows) - caption_h
    cover_h = math.min(cover_h, math.floor(cell_w * 1.5))
    local cover_w = math.min(cell_w, math.floor(cover_h / 1.5 + 0.5))
    local per_page = cols * rows
    local pages = math.max(1, math.ceil(#items / per_page))
    shell.lib.pages = pages
    if shell.lib.page > pages then shell.lib.page = pages end
    if shell.lib.page < 1 then shell.lib.page = 1 end

    if #items == 0 then
        local msg
        if shell.lib.query then
            msg = "Ничего не нашлось по запросу «" .. shell.lib.query .. "»."
        elseif Books.records and #Books.records == 0 then
            msg = "В папке " .. (Books.root or "") .. " пока нет книг. Папку можно поменять в настройках."
        else
            msg = "На этой полке пока пусто."
        end
        add(UI.vgap(UI.px(40)))
        add(UI.para{ text = msg, size = 17, color = UI.C.text2, width = cw, align = "center" })
        return UI.pad(vg, { left = M, right = M })
    end

    local first = (shell.lib.page - 1) * per_page + 1
    local grid = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, cols do
            local idx = first + (r - 1) * cols + (c - 1)
            local rec = items[idx]
            local cell
            if rec then
                Books:info(rec) -- progress only for the books on this page
                local fw = Covers.fittedWidth(rec, cover_w, cover_h)
                local bar
                if rec.status == "complete" then
                    bar = UI.bar(fw, UI.px(3), 1, UI.C.mid)
                elseif rec.percent and rec.percent > 0 then
                    bar = UI.bar(fw, UI.px(3), rec.percent)
                else
                    bar = UI.vgap(UI.px(3))
                end
                cell = VerticalGroup:new{
                    align = "center",
                    UI.center(cell_w, cover_h, Covers.widget(rec, cover_w, cover_h)),
                    UI.vgap(UI.px(6)),
                    bar,
                    UI.vgap(UI.px(5)),
                    UI.text{ text = rec.title or rec.name, size = 14, max_width = math.max(fw + UI.px(40), math.floor(cell_w * 0.9)) },
                }
                cell = UI.tap(cell, function() shell:openBook(rec.path) end, function() shell:bookActions(rec) end)
            else
                cell = UI.hgap(cell_w)
            end
            table.insert(row, cell)
            if c < cols then table.insert(row, UI.hgap(gap_x)) end
        end
        table.insert(grid, row)
        if r < rows then table.insert(grid, UI.vgap(gap_y)) end
    end
    add(grid)

    -- Warm the next page's covers while this one is being looked at.
    if shell.lib.page < pages then
        local upcoming = {}
        for i = first + per_page, math.min(#items, first + 2 * per_page - 1) do
            upcoming[#upcoming + 1] = items[i]
        end
        local i = 0
        shell:schedulePrefetch(function()
            i = i + 1
            if upcoming[i] then Covers.prefetch(upcoming[i], cover_w, cover_h) end
            return upcoming[i + 1] ~= nil
        end)
    end

    -- Footer: page arrows, pinned to the bottom.
    local spare = H - used - footer_h
    if spare > 0 then add(UI.vgap(spare)) end
    local arrow = function(text, enabled, cb)
        return UI.tap(UI.center(UI.px(90), footer_h,
            UI.text{ text = text, size = 22, color = enabled and UI.C.ink or UI.C.line }),
            enabled and cb or function() end)
    end
    local footer = HorizontalGroup:new{
        align = "center",
        arrow("‹", shell.lib.page > 1, function() Library.turn(shell, -1) end),
        UI.tap(UI.center(UI.px(140), footer_h, UI.text{ text = string.format("%d / %d", shell.lib.page, pages), size = 15, color = UI.C.text2 }),
            function() Library.jump(shell) end),
        arrow("›", shell.lib.page < pages, function() Library.turn(shell, 1) end),
    }
    add(UI.center(cw, footer_h, footer))

    return UI.pad(vg, { left = M, right = M })
end

function Library.jump(shell)
    local pages = shell.lib.pages or 1
    if pages < 2 then return end
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "Перейти на страницу",
        value = shell.lib.page,
        value_min = 1,
        value_max = pages,
        value_step = 1,
        value_hold_step = 5,
        ok_text = "Перейти",
        cancel_text = "Отмена",
        callback = function(spin)
            shell.lib.page = spin.value
            shell:refresh("ui")
        end,
    })
end

function Library.turn(shell, delta)
    local p = shell.lib.page + delta
    if p < 1 or p > (shell.lib.pages or 1) then return true end
    shell.lib.page = p
    shell:refresh("ui")
    return true
end

return Library
