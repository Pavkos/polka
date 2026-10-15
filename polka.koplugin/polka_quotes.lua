--[[--
Polka: Цитаты — highlights and notes from every book.

The quotes come from the books' sidecars, read in the same pass as the
finished books (Books:finishInfo), so opening this screen costs nothing
extra. Newest first; filtered by one book, in the book's order. A tap shows
one quote large, with "Открыть в книге", "Копировать", "QR-код", "Удалить";
swipes flip through the list. Deleting edits the book's sidecar the way
KOReader's own annotation tools do (and flags it for KOReader to re-sort).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local DocSettings = require("docsettings")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local util = require("util")

local Books = require("polka_books")
local Tools = require("polka_tools")
local UI = require("polka_ui")

local Quotes = {}

local cache = nil -- { gen, list, books }

local function formatDate(datetime)
    local key = tostring(datetime or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
    return key and require("polka_achievements").formatDate(key) or nil
end

-- Every quote from the reading history: { q, book }, newest first, and the
-- books that have quotes: { path, title, authors, count }.
function Quotes.all()
    if cache and cache.gen == Books.generation then return cache.list, cache.books end
    local list, books = {}, {}
    for _, path in ipairs(Books.hist or {}) do
        local f = Books:finishInfo(path)
        if f.quotes and #f.quotes > 0 then
            local rec = Books:brief(Books:record(path))
            local book = { path = path, title = rec.title or rec.name, authors = rec.authors, count = #f.quotes }
            books[#books + 1] = book
            for _, q in ipairs(f.quotes) do
                list[#list + 1] = { q = q, book = book }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.q.datetime ~= b.q.datetime then return a.q.datetime > b.q.datetime end
        if a.book.path ~= b.book.path then return a.book.path < b.book.path end
        return a.q.order < b.q.order
    end)
    table.sort(books, function(a, b) return Books.sortKey(a.title) < Books.sortKey(b.title) end)
    cache = { gen = Books.generation, list = list, books = books }
    return list, books
end

function Quotes.summary()
    local list, books = Quotes.all()
    if #list == 0 then return nil end
    local n = #books
    local of_books = (n % 10 == 1 and n % 100 ~= 11) and "книги" or "книг" -- "из 1 книги", "из 5 книг"
    return string.format("%d %s из %d %s", #list, UI.plural(#list, "цитата", "цитаты", "цитат"), n, of_books)
end

-- The list as filtered now (by book, by words).
local function filtered(st)
    local all = Quotes.all()
    local out = {}
    local q = st.query and Books.sortKey(st.query) or nil
    for _, it in ipairs(all) do
        if not st.book or it.book.path == st.book then
            local ok = true
            if q then
                it.key = it.key or Books.sortKey(it.q.text .. " " .. (it.q.note or "") .. " " .. (it.book.title or "") .. " " .. (it.book.authors or ""))
                ok = it.key:find(q, 1, true) ~= nil
            end
            if ok then out[#out + 1] = it end
        end
    end
    if st.book then
        table.sort(out, function(a, b) return a.q.order < b.q.order end) -- the book's own order
    end
    return out
end

local function state(shell)
    shell.q = shell.q or { starts = { 1 }, page = 1, view = "list" }
    return shell.q
end

local function reset(shell, changes)
    local st = state(shell)
    for k, v in pairs(changes) do st[k] = v end
    st.starts, st.page, st.view = { 1 }, 1, "list"
    shell:refresh("ui")
end

-- Actions ---------------------------------------------------------------------

local function copy(it)
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(it.q.text)
        UIManager:show(Notification:new{ text = "Цитата скопирована" })
    end
end

local function showQR(it)
    local QRMessage = require("ui/widget/qrmessage")
    local text = it.q.text .. "\n\n— " .. (it.book.title or "") .. (it.book.authors and (", " .. it.book.authors) or "")
    local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.8)
    UIManager:show(QRMessage:new{ text = text, width = size, height = size })
end

local function samePos(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a.page == b.page and a.x == b.x and a.y == b.y
    end
    return tostring(a) == tostring(b)
end

-- A PDF may keep its highlights inside the file too ("Write highlights into
-- PDF"): only KOReader can take those out, from the open book.
local function writtenIntoPDF(path)
    if not path:lower():match("%.pdf$") then return false end
    local ok, ds = pcall(DocSettings.open, DocSettings, path)
    if ok and ds and ds:has("highlight_write_into_pdf") then return ds:isTrue("highlight_write_into_pdf") end
    return G_reader_settings:isTrue("highlight_write_into_pdf")
end

-- Removes the highlight from the book's sidecar (the book is closed while the
-- shell is up), matched by its text, time and both ends. Returns true when
-- it was there and is gone.
function Quotes.delete(it)
    local removed = false
    local ok, err = pcall(function()
        local ds = DocSettings:open(it.book.path)
        local anns = ds:readSetting("annotations")
        if type(anns) ~= "table" then return end
        for i = #anns, 1, -1 do
            local a = anns[i]
            if type(a) == "table" and a.text == it.q.text and (a.datetime or "") == it.q.datetime
                    and tostring(a.page) == tostring(it.q.page)
                    and samePos(a.pos0, it.q.pos0) and samePos(a.pos1, it.q.pos1) then
                table.remove(anns, i)
                removed = true
                break
            end
        end
        if removed then
            ds:saveSetting("annotations", anns)
            ds:flush()
        end
    end)
    if not ok then logger.warn("Polka: cannot delete quote:", err) end
    Books:invalidate(it.book.path)
    return ok and removed
end

local function openInBook(shell, it)
    local plugin = shell.plugin
    if plugin and plugin.openAt then
        plugin.openAt(it.book.path, it.q.page, it.q.pos0)
    else
        shell:openBook(it.book.path)
    end
end

local function confirmDelete(shell, it)
    if writtenIntoPDF(it.book.path) then
        UIManager:show(ConfirmBox:new{
            text = "Эта цитата записана и в сам PDF. Удалить её можно в книге: нажмите на выделение и выберите «Удалить».",
            ok_text = "Открыть в книге",
            cancel_text = "Отмена",
            ok_callback = function() openInBook(shell, it) end,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = "Удалить эту цитату из книги «" .. (it.book.title or "") .. "»?",
        ok_text = "Удалить",
        cancel_text = "Отмена",
        ok_callback = function()
            if not Quotes.delete(it) then
                UIManager:show(InfoMessage:new{ text = "Не получилось удалить цитату. Попробуйте удалить её в книге." })
            end
            local st = state(shell)
            st.view = "list"
            st.starts, st.page = { 1 }, 1
            if st.book then
                -- that book's last quote: back to all books
                local still = false
                for _, x in ipairs((Quotes.all())) do
                    if x.book.path == st.book then still = true break end
                end
                if not still then st.book = false end
            end
            shell:refresh("ui")
        end,
    })
end


local function pickBook(shell)
    local _, books = Quotes.all()
    local st = state(shell)
    local dialog
    local buttons = { {{ text = "Все книги" .. (st.book and "" or "  ✓"), callback = function()
        UIManager:close(dialog)
        reset(shell, { book = false })
    end }} }
    for _, b in ipairs(books) do
        table.insert(buttons, {{
            text = string.format("%s · %d%s", b.title, b.count, st.book == b.path and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                reset(shell, { book = b.path })
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = "Книги с цитатами", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

local function search(shell)
    local st = state(shell)
    local dialog
    dialog = InputDialog:new{
        title = "Поиск в цитатах",
        input = st.query or "",
        input_hint = "Слово из цитаты, заметки или книги",
        buttons = {{
            { text = "Отмена", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Найти", is_enter_default = true, callback = function()
                local q = util.trim(dialog:getInputText() or "")
                UIManager:close(dialog)
                reset(shell, { query = q ~= "" and q or false })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Drawing -----------------------------------------------------------------------

local function chip(text, active, cb)
    return UI.tap(UI.pill(UI.text{ text = text, size = 15, family = active and "sans_bold" or "sans",
                                   color = active and UI.C.paper or UI.C.ink, max_width = UI.px(260) },
        { background = active and UI.C.ink or UI.C.paper, border_color = active and UI.C.ink or UI.C.mid,
          hpad = UI.px(13), vpad = UI.px(5), radius = UI.px(16) }), cb)
end

local function card(shell, it, cw, index, by_book)
    local text_w = cw
    local quote = UI.para{ text = it.q.text, family = "serif", size = 16, width = text_w, max_lines = 7 }
    local vg = VerticalGroup:new{ align = "left", UI.vgap(UI.px(14)), quote }
    local note = UI.plainNote(it.q.note)
    if note then
        table.insert(vg, UI.vgap(UI.px(6)))
        table.insert(vg, UI.para{ text = "✎ " .. note, size = 14, color = UI.C.text2, width = text_w, max_lines = 3 })
    end
    local meta = {}
    if by_book then
        if it.q.chapter then meta[#meta + 1] = it.q.chapter end
    else
        meta[#meta + 1] = it.book.title
        if it.book.authors and it.book.authors ~= "" then meta[#meta + 1] = it.book.authors end
    end
    local date = formatDate(it.q.datetime)
    if date then meta[#meta + 1] = date end
    table.insert(vg, UI.vgap(UI.px(6)))
    table.insert(vg, UI.text{ text = table.concat(meta, " · "), size = 12, color = UI.C.text3, max_width = text_w })
    table.insert(vg, UI.vgap(UI.px(14)))
    table.insert(vg, UI.hline(cw))
    return UI.tap(vg, function()
        local st = state(shell)
        st.view, st.index = "one", index
        shell:refresh("ui")
    end, function()
        local dialog
        dialog = ButtonDialog:new{
            buttons = {
                {{ text = "Открыть в книге", callback = function() UIManager:close(dialog); openInBook(shell, it) end }},
                {{ text = "Копировать", callback = function() UIManager:close(dialog); copy(it) end },
                 { text = "QR-код", callback = function() UIManager:close(dialog); showQR(it) end }},
                {{ text = "Удалить", callback = function() UIManager:close(dialog); confirmDelete(shell, it) end }},
            },
        }
        UIManager:show(dialog)
    end)
end

local function listView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local list = filtered(st)
    local all = Quotes.all()
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    local count = (#list ~= #all) and string.format("%d из %d", #list, #all) or tostring(#all)
    add(Tools.header(shell, cw, "Цитаты", #all > 0 and UI.text{ text = count, size = 15, color = UI.C.text2 } or nil))
    add(UI.vgap(UI.px(10)))

    if #all == 0 then
        add(UI.vgap(UI.px(30)))
        add(UI.para{ text = "Здесь будут ваши выделения из всех книг.", family = "serif_bold", size = 20,
                     width = cw, align = "center" })
        add(UI.vgap(UI.px(10)))
        add(UI.para{ text = "В книге задержите палец на слове и протяните до конца фразы, потом нажмите «Выделить».",
                     size = 16, color = UI.C.text2, width = cw, align = "center" })
        return UI.pad(vg, { left = M, right = M })
    end

    local book_label = "Все книги"
    if st.book then
        for _, b in ipairs(select(2, Quotes.all())) do
            if b.path == st.book then book_label = b.title end
        end
    end
    local controls = HorizontalGroup:new{
        align = "center",
        chip(book_label .. "  ▾", st.book and true or false, function() pickBook(shell) end),
        UI.hgap(UI.px(8)),
        st.query and chip("«" .. st.query .. "»  ✕", true, function() reset(shell, { query = false }) end)
            or chip("Поиск", false, function() search(shell) end),
    }
    add(controls)
    add(UI.vgap(UI.px(6)))
    add(UI.hline(cw))

    local footer_h = UI.px(52)
    local room = H - used - footer_h
    local first = st.starts[st.page] or 1
    if #list == 0 then
        add(UI.vgap(UI.px(30)))
        add(UI.para{ text = "Ничего не нашлось.", size = 17, color = UI.C.text2, width = cw, align = "center" })
        return UI.pad(vg, { left = M, right = M })
    end
    -- Exact paging: fill this page with real cards; the next page starts
    -- where this one stopped.
    local i = first
    local height = 0
    while list[i] do
        local c = card(shell, list[i], cw, i, st.book ~= nil and st.book ~= false)
        local h = c:getSize().h
        if height + h > room and i > first then
            c:free()
            break
        end
        add(c)
        height = height + h
        i = i + 1
    end
    st.starts[st.page + 1] = list[i] and i or nil
    local spare = H - used - footer_h
    if spare > 0 then add(UI.vgap(spare)) end
    local has_next = list[i] ~= nil
    if st.page > 1 or has_next then
        local arrow = function(text, enabled, delta)
            return UI.tap(UI.center(UI.px(90), footer_h, UI.text{ text = text, size = 22, color = enabled and UI.C.ink or UI.C.line }),
                enabled and function() Quotes.turn(shell, delta) end or function() end)
        end
        add(UI.center(cw, footer_h, HorizontalGroup:new{
            align = "center",
            arrow("‹", st.page > 1, -1),
            UI.center(UI.px(140), footer_h, UI.text{ text = "стр. " .. st.page, size = 15, color = UI.C.text2 }),
            arrow("›", has_next, 1),
        }))
    end
    return UI.pad(vg, { left = M, right = M })
end

local function actionButton(icon, label, cb, w)
    local col = VerticalGroup:new{
        align = "center",
        UI.icon(icon, 20, UI.C.ink),
        UI.vgap(UI.px(6)),
        UI.text{ text = label, size = 13, color = UI.C.text2, max_width = w - UI.px(4) },
    }
    return UI.tap(UI.center(w, UI.px(70), col), cb)
end

local function oneView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local list = filtered(st)
    local it = list[st.index or 1]
    if not it then
        st.view = "list"
        return listView(shell, W, H)
    end
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(UI.tap(UI.pad(UI.text{ text = "‹  Цитаты", size = 15, color = UI.C.text2 },
        { top = UI.px(10), bottom = UI.px(6), right = UI.px(30) }), function()
        st.view = "list"
        shell:refresh("ui")
    end))
    add(UI.vgap(UI.px(16)))

    -- Bottom first: actions and the position, so the quote gets the rest.
    local col_w = math.floor(cw / 4)
    local actions = HorizontalGroup:new{
        align = "center",
        actionButton(0xF02D, "Открыть", function() openInBook(shell, it) end, col_w),
        actionButton(0xF0C5, "Копировать", function() copy(it) end, col_w),
        actionButton(0xF029, "QR-код", function() showQR(it) end, col_w),
        actionButton(0xF014, "Удалить", function() confirmDelete(shell, it) end, cw - 3 * col_w),
    }
    local footer_h = UI.px(52)
    local source = VerticalGroup:new{
        align = "left",
        UI.text{ text = (it.book.title or "") .. ((it.book.authors and it.book.authors ~= "") and (" — " .. it.book.authors) or ""),
                 size = 15, color = UI.C.text2, max_width = cw },
        UI.text{ text = table.concat((function()
            local parts = {}
            if it.q.chapter then parts[#parts + 1] = it.q.chapter end
            local d = formatDate(it.q.datetime)
            if d then parts[#parts + 1] = d end
            return parts
        end)(), " · "), size = 13, color = UI.C.text3, max_width = cw },
    }
    local note
    local note_text = UI.plainNote(it.q.note)
    if note_text then
        note = UI.FrameContainer:new{
            bordersize = 0, padding = UI.px(12), margin = 0, background = UI.C.tint, radius = UI.px(8),
            UI.para{ text = note_text, size = 15, width = cw - 2 * UI.px(12), bgcolor = UI.C.tint, max_lines = 6 },
        }
    end
    local below = source:getSize().h + UI.px(18) + actions:getSize().h + footer_h + (note and note:getSize().h + UI.px(16) or 0)
    local room = H - used - below - UI.px(16)
    local line_h = math.floor(1.18 * UI.face("serif", 21).size + 0.5)
    local quote = UI.para{ text = it.q.text, family = "serif", size = 21, width = cw,
                           max_lines = math.max(1, math.floor(room / line_h)) } -- shrinks to a short quote
    -- A short quote sits in the middle of the page, like a card.
    local block = VerticalGroup:new{ align = "left", quote }
    if note then
        table.insert(block, UI.vgap(UI.px(16)))
        table.insert(block, note)
    end
    table.insert(block, UI.vgap(UI.px(16)))
    table.insert(block, source)
    local spare = H - used - block:getSize().h - actions:getSize().h - footer_h - UI.px(2)
    local above = math.max(0, math.floor(spare * 0.4))
    if above > 0 then add(UI.vgap(above)) end
    add(block)
    if spare - above > 0 then add(UI.vgap(spare - above)) end
    add(UI.hline(cw))
    add(actions)
    add(Tools.pager(cw, footer_h, st.index, #list, function(delta) Quotes.flip(shell, delta) end))
    return UI.pad(vg, { left = M, right = M })
end

function Quotes.build(shell, W, H)
    local st = state(shell)
    if st.view == "one" then return oneView(shell, W, H) end
    return listView(shell, W, H)
end

function Quotes.turn(shell, delta)
    local st = state(shell)
    local p = st.page + delta
    if p < 1 or not st.starts[p] then return end
    st.page = p
    shell:refresh("ui")
end

function Quotes.flip(shell, delta)
    local st = state(shell)
    local n = #filtered(st)
    local i = (st.index or 1) + delta
    if i < 1 or i > n then return end
    st.index = i
    shell:refresh("ui")
end

function Quotes.swipe(shell, dir)
    local st = state(shell)
    local delta = dir == "west" and 1 or -1
    if st.view == "one" then
        Quotes.flip(shell, delta)
    else
        Quotes.turn(shell, delta)
    end
end

function Quotes.leave(shell)
    shell.q = nil
end

return Quotes
