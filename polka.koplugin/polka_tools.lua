-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Инструменты.

A short list, like the "More" page on a Kindle: quotes from every book,
books over Wi‑Fi, OPDS catalogs, Instapaper and the site. Each tool is its
own module, loaded the first time it is opened, and drawn inside the shell
under a "‹ Инструменты" line. A tool may define:
  build(shell, W, H)   the screen (required)
  summary()            one quiet line for this list
  leave(shell)         the tool is closed (stop servers, forget state)
  suspend(shell)       the device goes to sleep while the tool is open
  swipe(shell, dir)    left/right swipes inside the tool
«Сайт» is its own kind of row: before the Kindle is connected it says what
the site is for and has «Подключить»; once connected it shows how the sync
went and a round «sync now» button, and the row itself opens the Сайт page.
]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Books = require("polka_books")
local UI = require("polka_ui")

local Tools = {}

Tools.ITEMS = {
    { id = "quotes", title = "Цитаты", icon = 0xF10D, module = "polka_quotes",
      hint = "Выделения и заметки из всех книг" },
    { id = "transfer", title = "Книги по Wi‑Fi", icon = 0xF1EB, module = "polka_transfer",
      hint = "С телефона или компьютера, без кабеля" },
    { id = "opds", title = "OPDS-каталоги", icon = 0xF02D, module = "polka_opds",
      hint = "Библиотеки в сети: поиск и скачивание" },
    { id = "instapaper", title = "Instapaper", letter = "I", module = "polka_instapaper",
      hint = "Отложенные статьи — как книги" },
    { id = "site", title = "Сайт", icon = 0xF0AC, module = "polka_web", site = true,
      hint = "Статистика и цитаты в телефоне" },
}

local function item(id)
    for _, it in ipairs(Tools.ITEMS) do
        if it.id == id then return it end
    end
end

function Tools.module(id)
    local it = item(id)
    if not it or it.site then return nil end
    local ok, mod = pcall(require, it.module)
    if not ok then
        logger.err("Polka: cannot load", it.module, mod)
        return nil
    end
    return mod
end

-- "‹ Инструменты", then the tool's title with an optional widget on the right.
function Tools.header(shell, cw, title, right)
    local back = UI.tap(UI.pad(HorizontalGroup:new{
        align = "center",
        UI.text{ text = "‹  Инструменты", size = 15, color = UI.C.text2 },
    }, { top = UI.px(10), bottom = UI.px(6), right = UI.px(30) }), function() shell:closeTool() end)
    local name = UI.text{ text = title, family = "serif_bold", size = 26,
                          max_width = cw - (right and right:getSize().w + UI.px(16) or 0) }
    return VerticalGroup:new{
        align = "left",
        back,
        UI.split(cw, name, right, math.max(name:getSize().h, right and right:getSize().h or 0)),
    }
end

-- Page arrows "‹ 2 / 5 ›" for tools with long lists.
function Tools.pager(cw, h, page, pages, on_turn)
    local arrow = function(text, enabled, delta)
        return UI.tap(UI.center(UI.px(90), h, UI.text{ text = text, size = 22, color = enabled and UI.C.ink or UI.C.line }),
            enabled and function() on_turn(delta) end or function() end)
    end
    return UI.center(cw, h, HorizontalGroup:new{
        align = "center",
        arrow("‹", page > 1, -1),
        UI.center(UI.px(140), h, UI.text{ text = string.format("%d / %d", page, pages), size = 15, color = UI.C.text2 }),
        arrow("›", page < pages, 1),
    })
end

-- "‹ label ›" with arrows that may be disabled (pages of unknown count).
function Tools.pagerBar(cw, h, label, can_back, can_next, on_turn)
    local arrow = function(text, enabled, delta)
        return UI.tap(UI.center(UI.px(90), h, UI.text{ text = text, size = 22, color = enabled and UI.C.ink or UI.C.line }),
            enabled and function() on_turn(delta) end or function() end)
    end
    return UI.center(cw, h, HorizontalGroup:new{
        align = "center",
        arrow("‹", can_back, -1),
        UI.center(UI.px(140), h, UI.text{ text = label, size = 15, color = UI.C.text2 }),
        arrow("›", can_next, 1),
    })
end

-- Exact paging: fills the room with real rows, from items[from] on, and
-- returns the rows' group and the index of the first row left for the next page.
function Tools.fillPage(items, from, room, make)
    local vg = VerticalGroup:new{ align = "left" }
    local height, i = 0, from
    while items[i] do
        local w = make(items[i], i)
        local h = w:getSize().h
        if height + h > room and i > from then
            w:free()
            break
        end
        table.insert(vg, w)
        height = height + h
        i = i + 1
    end
    return vg, i
end

-- A rounded light square with a glyph (or a letter, for Instapaper's "I").
function Tools.badge(it, size)
    local glyph
    if it.letter then
        glyph = UI.text{ text = it.letter, family = "serif_bold", size = 25 }
    else
        glyph = UI.icon(it.icon, 22)
    end
    return UI.FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = UI.C.tint, radius = UI.px(9),
        UI.center(size, size, glyph),
    }
end

local function row(shell, cw, it)
    local icon_size = UI.px(52)
    local summary
    local mod = package.loaded[it.module]
    if not mod and it.site then
        local ok, m = pcall(require, it.module)
        mod = ok and m or nil
    end
    local connected = it.site and mod and mod.configured and mod.configured()
    if mod and mod.summary and (not it.site or connected) then
        local ok, s = pcall(mod.summary)
        if ok then summary = s end
    end
    -- on the right: «Подключить», the round «sync now», or a chevron
    local right
    if it.site and not connected then
        right = UI.pillButton("Подключить", function() require("polka_site").open(shell) end)
    elseif it.site then
        local Site = require("polka_site")
        right = UI.tap(Site.syncButton(UI.px(46), mod.pid ~= nil), function()
            if mod.online() then
                mod.tap()
            else
                require("polka_wifi").run("Нужен, чтобы синхронизировать.", function() mod.tap() end)
            end
        end)
    else
        right = require("polka_icons").widget("chev_right", UI.px(22), { stroke = math.max(2, UI.px(2)) })
    end
    local right_w = right:getSize().w
    local text_w = cw - icon_size - UI.px(16) - right_w - UI.px(12)
    local texts = VerticalGroup:new{
        align = "left",
        UI.text{ text = it.title, family = "serif_bold", size = 22, max_width = text_w },
        UI.vgap(UI.px(3)),
        UI.text{ text = summary or it.hint, size = 14.5, color = UI.C.text2, max_width = text_w },
    }
    local h = math.max(icon_size, texts:getSize().h, right:getSize().h) + UI.px(32)
    local left = HorizontalGroup:new{
        align = "center",
        Tools.badge(it, icon_size),
        UI.hgap(UI.px(16)),
        UI.left(text_w, texts),
    }
    local w = UI.tap(VerticalGroup:new{
        align = "left",
        UI.split(cw, left, right, h),
        UI.hline(cw),
    }, function()
        if it.site then
            require("polka_site").open(shell)
        else
            shell:openTool(it.id)
        end
    end)
    if it.site then Tools[it.id .. "_row"] = w end
    return w
end

function Tools.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    if shell.tools_view then
        local mod = Tools.module(shell.tools_view)
        if mod then return mod.build(shell, W, H) end
        shell.tools_view = nil
    end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, UI.vgap(UI.px(8)))
    for _, it in ipairs(Tools.ITEMS) do
        table.insert(vg, row(shell, cw, it))
    end
    return UI.pad(vg, { left = M, right = M })
end

local function call(shell, name, ...)
    if not shell.tools_view then return end
    local mod = package.loaded[(item(shell.tools_view) or {}).module or ""]
    if mod and mod[name] then return mod[name](shell, ...) end
end

function Tools.leave(shell) call(shell, "leave") end
function Tools.suspend(shell) call(shell, "suspend") end

function Tools.swipe(shell, dir)
    call(shell, "swipe", dir)
    return true
end

-- Files for the library (Wi‑Fi uploads, OPDS and Instapaper downloads) ---------

-- Cut a UTF-8 string to at most n bytes without splitting a character.
local function utf8Cut(s, n)
    if #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end -- the next byte starts a character
        cut = cut - 1
    end
    return s:sub(1, cut)
end

Tools.utf8Cut = utf8Cut

-- A file or folder name that is safe on the Kindle's FAT storage and never
-- leaves its folder.
function Tools.cleanName(name)
    name = tostring(name or "")
    name = name:gsub("^.*[/\\]", "")              -- no folders
    name = name:gsub("[%c<>:\"|%?%*]", "_")       -- nothing FAT or the shell dislikes
    name = name:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #name > 180 then
        local ext = name:match("(%.[%w]+%.[zZ][iI][pP])$") or name:match("(%.[%w]+)$") or ""
        name = utf8Cut(name:sub(1, #name - #ext), 180 - #ext):gsub("[%s%.]+$", "") .. ext
    end
    return name
end

-- dir/name, or dir/name (2).ext when that is taken.
function Tools.uniquePath(dir, name)
    local path = dir .. "/" .. name
    if not lfs.attributes(path) then return path end
    local base, ext = name:match("^(.-)(%.[%w]+%.[zZ][iI][pP])$")
    if not base then base, ext = name:match("^(.*)(%.[%w]+)$") end
    if not base then base, ext = name, "" end
    for i = 2, 99 do
        path = string.format("%s/%s (%d)%s", dir, base, i, ext)
        if not lfs.attributes(path) then return path end
    end
    return string.format("%s/%s %d%s", dir, base, os.time(), ext)
end

-- Names of the shelves (top-level folders with books).
function Tools.shelves()
    local out = {}
    for _, s in ipairs(Books.shelves or {}) do
        if s.name then out[#out + 1] = s.name end
    end
    return out
end

-- The folder of a shelf: an existing one, a new one (created), or the books
-- folder itself for "" ("Без полки"). Returns the folder and the shelf name used.
function Tools.shelfDir(shelf)
    local root = (Books.root or Books.getRoot()):gsub("/+$", "")
    shelf = Tools.cleanName(shelf)
    if shelf == "" then return root, "" end
    local dir = root .. "/" .. shelf
    if lfs.attributes(dir, "mode") ~= "directory" then
        if not lfs.mkdir(dir) then return root, "" end
    end
    return dir, shelf
end

-- "Полка для книг": the shelves, "Без полки" and "Новая полка…".
function Tools.pickShelf(current, on_pick)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local dialog
    local function choice(text, value)
        return {{ text = text .. (value == (current or "") and "  ✓" or ""), callback = function()
            UIManager:close(dialog)
            on_pick(value)
        end }}
    end
    local buttons = {}
    for _, name in ipairs(Tools.shelves()) do buttons[#buttons + 1] = choice(name, name) end
    buttons[#buttons + 1] = choice("Без полки", "")
    buttons[#buttons + 1] = {{ text = "Новая полка…", callback = function()
        UIManager:close(dialog)
        local input
        input = InputDialog:new{
            title = "Новая полка",
            input_hint = "Название",
            buttons = {{
                { text = "Отмена", id = "close", callback = function() UIManager:close(input) end },
                { text = "Создать", is_enter_default = true, callback = function()
                    local name = Tools.cleanName(input:getInputText())
                    UIManager:close(input)
                    if name ~= "" then on_pick(name) end
                end },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end }}
    dialog = ButtonDialog:new{ title = "Полка для книг", title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function Tools.sizeText(bytes)
    bytes = bytes or 0
    if bytes >= 1024 * 1024 then
        return (string.format("%.1f МБ", bytes / 1048576):gsub("%.", ","))
    end
    return string.format("%d КБ", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

-- Waiting for the network -------------------------------------------------------
-- KOReader talks to the network in blocking calls; meanwhile a small card says
-- what is going on (updated by the caller, e.g. with bytes received) and is
-- painted at once. Taps made while waiting are dropped afterwards.

local Busy = nil

function Tools.busy(text)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local W, H = Screen:getWidth(), Screen:getHeight()
    local text_w = math.min(W - 2 * UI.px(60), UI.px(380))
    local card = UI.FrameContainer:new{
        bordersize = math.max(1, UI.px(1)), color = UI.C.ink, background = UI.C.paper,
        radius = UI.px(10), padding = UI.px(18), margin = 0,
        UI.para{ text = text, size = 17, width = text_w, align = "center" },
    }
    local size = card:getSize()
    local x, y = math.floor((W - size.w) / 2), math.floor((H - size.h) / 2)
    local widget = require("ui/widget/container/widgetcontainer"):new{
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        UI.OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, UI.pad(card, { left = x, top = y }) },
    }
    local region = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    if Busy then
        -- the old card's area is repainted too, in case the new one is smaller
        region = region:combine(Busy.region)
        UIManager:close(Busy.widget)
    end
    Busy = { widget = widget, region = region }
    UIManager:show(widget, "ui", region)
    UIManager:forceRePaint()
end

function Tools.idle()
    if not Busy then return end
    local UIManager = require("ui/uimanager")
    UIManager:close(Busy.widget, "ui", Busy.region)
    Busy = nil
    local input = require("device").input
    if input and input.inhibitInputUntil then pcall(input.inhibitInputUntil, input, true) end
end

-- Geometry helper for tools drawing their own widgets.
Tools.Geom = Geom

return Tools
