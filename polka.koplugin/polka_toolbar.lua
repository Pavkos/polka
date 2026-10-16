-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the Kindle reading toolbar.

Opens on a tap at the top of the page. Two panels over the page, which
stays visible in between:

  top     ‹ Главная · book title · search · ⋮ (KOReader's menu)
          Шрифт · Оглавление · Закладка · Заметки
  bottom  chapter · "Стр. 45 из 320 · 14%"
          |◀ ━━━━●───|────|── ▶|   (tap the bar to jump, the ends jump by chapter)

A tap on the page between the panels closes it.
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Device = require("device")
local Screen = Device.screen

local Icons = require("polka_icons")
local UI = require("polka_ui")

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- Progress bar with chapter ticks and a knob; a tap picks a page.
local Slider = InputContainer:extend{
    width = 100,
    height = 40,
    page = 1,
    pages = 1,
    ticks = nil,
    on_pick = nil,
}

function Slider:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapSlider = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Slider:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Slider:knobRadius()
    return UI.px(9)
end

function Slider:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = self:knobRadius()
    local x0, span = x + r, self.width - 2 * r
    local cy = y + math.floor(self.height / 2)
    local track = math.max(2, UI.px(1))
    local fill = math.max(3, UI.px(2))
    bb:paintRect(x0, cy - math.floor(track / 2), span, track, UI.C.mid)
    local last = math.max(1, self.pages - 1)
    local tick_h = UI.px(10)
    for _, p in ipairs(self.ticks or {}) do
        if p > 1 and p <= self.pages then
            local tx = x0 + math.floor(span * (p - 1) / last + 0.5)
            bb:paintRect(tx, cy - math.floor(tick_h / 2), math.max(1, UI.px(1) - 1), tick_h, UI.C.mid)
        end
    end
    local kx = x0 + math.floor(span * (self.page - 1) / last + 0.5)
    bb:paintRect(x0, cy - math.floor(fill / 2), kx - x0, fill, UI.C.ink)
    bb:paintCircle(kx, cy, r, UI.C.paper)
    bb:paintCircle(kx, cy, r, UI.C.ink, math.max(2, UI.px(1)))
end

function Slider:onTapSlider(_, ges)
    local r = self:knobRadius()
    local span = math.max(1, self.width - 2 * r)
    local f = (ges.pos.x - self.dimen.x - r) / span
    f = math.max(0, math.min(1, f))
    local page = 1 + math.floor(f * (self.pages - 1) + 0.5)
    if self.on_pick then UI.safely(self.on_pick, page) end
    return true
end

local Toolbar = InputContainer:extend{
    name = "polka_toolbar",
    reader = nil,
}

function Toolbar:init()
    self.ui = self.reader.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:build()
end

function Toolbar:margin()
    return UI.px(16)
end

function Toolbar:title()
    local props = self.ui.doc_props or {}
    local title = require("polka_books").tidy(props.display_title or props.title)
    if not title or title == "" then
        title = (self.ui.document.file or ""):match("([^/]+)$") or ""
        title = title:gsub("%.[^.]+$", "")
    end
    return title
end

function Toolbar:pageInfo()
    local page = self.ui:getCurrentPage() or 1
    local pages = self.ui.document:getPageCount() or 1
    return page, math.max(1, pages)
end

function Toolbar:topPanel(W)
    local M = self:margin()
    local cw = W - 2 * M
    local row_h = UI.px(52)
    local back = UI.tap(UI.pad(HorizontalGroup:new{
        align = "center",
        Icons.widget("chev_left", UI.px(22)),
        UI.hgap(UI.px(2)),
        UI.text{ text = "Главная", size = 16 },
    }, { top = UI.px(10), bottom = UI.px(10), right = UI.px(16) }), function() self:goHome() end)
    local icon = UI.px(26)
    local function iconButton(name, cb)
        return UI.tap(UI.pad(Icons.widget(name, icon), { left = UI.px(14), top = UI.px(12), bottom = UI.px(12), right = UI.px(2) }), cb)
    end
    local actions = HorizontalGroup:new{
        align = "center",
        iconButton("search", function() self:search() end),
        iconButton("dots", function() self:koreaderMenu() end),
    }
    local side = math.max(back:getSize().w, actions:getSize().w)
    local title = UI.text{ text = self:title(), family = "sans_bold", size = 15,
                           max_width = math.max(UI.px(60), cw - 2 * side - UI.px(12)) }
    local row1 = OverlapGroup:new{
        dimen = Geom:new{ w = cw, h = row_h },
        LeftContainer:new{ dimen = Geom:new{ w = cw, h = row_h }, back },
        CenterContainer:new{ dimen = Geom:new{ w = cw, h = row_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = cw, h = row_h }, actions },
    }

    local bookmarked = false
    pcall(function() bookmarked = self.ui.bookmark:isPageBookmarked() end)
    local cells = {
        { aa = true, label = self.ui.rolling and "Шрифт" or "Вид",
          cb = function() self:closeThen(function() self.reader:openAa() end) end },
        { icon = "list", label = "Оглавление", cb = function() self:closeThen(function() self.ui.toc:onShowToc() end) end },
        { icon = bookmarked and "ribbon_filled" or "ribbon", label = bookmarked and "В закладках" or "Закладка",
          cb = function() self:toggleBookmark() end },
        { icon = "notes", label = "Заметки", cb = function() self:closeThen(function() self.ui.bookmark:onShowBookmark() end) end },
    }
    local cell_w = math.floor(W / #cells)
    local cell_h = UI.px(76)
    local glyph_box = UI.px(34)
    local row2 = HorizontalGroup:new{ align = "center" }
    for i, c in ipairs(cells) do
        local glyph
        if c.aa then
            glyph = UI.text{ text = "Aa", family = "serif", size = 22 }
        else
            glyph = Icons.widget(c.icon, UI.px(28))
        end
        local col = VerticalGroup:new{
            align = "center",
            UI.center(glyph_box * 2, glyph_box, glyph),
            UI.vgap(UI.px(5)),
            UI.text{ text = c.label, size = 13, color = UI.C.text2 },
        }
        local w = (i == #cells) and (W - cell_w * (#cells - 1)) or cell_w
        table.insert(row2, UI.tap(UI.center(w, cell_h, col), c.cb))
    end

    return FrameContainer:new{
        background = UI.C.paper,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            -- clock and battery, as on a Kindle when the toolbar is up
            UI.pad(UI.statusRow(cw, UI.px(26)), { left = M, right = M, top = UI.px(4) }),
            UI.pad(row1, { left = M, right = M }),
            UI.pad(UI.hline(cw, UI.C.line), { left = M }),
            row2,
            UI.hline(W, UI.C.ink, math.max(2, UI.px(1))),
        },
    }
end

function Toolbar:bottomPanel(W)
    local M = self:margin()
    local cw = W - 2 * M
    local page, pages = self:pageInfo()
    local pct = page / math.max(1, pages)
    if self.reader.footer and self.reader.footer.percent_finished then
        pct = self.reader.footer.percent_finished
    end
    local where = UI.tap(UI.text{ text = string.format("Стр. %d из %d · %s", page, pages, UI.percent(pct)), size = 14 },
        function() self:closeThen(function() self.ui.gotopage:onShowGotoDialog() end) end)
    local chapter = ""
    pcall(function() chapter = self.ui.toc:getTocTitleByPage(page) or "" end)
    local chapter_w = UI.text{ text = chapter, size = 14, color = UI.C.text2,
                               max_width = math.max(UI.px(40), cw - where:getSize().w - UI.px(20)) }
    local row1 = UI.split(cw, chapter_w, where, UI.px(30))

    local btn = UI.px(44)
    local ticks = {}
    pcall(function() ticks = self.ui.toc:getTocTicksFlattened() or {} end)
    local slider = Slider:new{
        width = cw - 2 * btn,
        height = btn,
        page = page,
        pages = pages,
        ticks = ticks,
        on_pick = function(p) self:jumpTo(p) end,
    }
    local row2 = HorizontalGroup:new{
        align = "center",
        UI.tap(UI.center(btn, btn, Icons.widget("first", UI.px(24))), function() self:chapterJump(-1) end),
        slider,
        UI.tap(UI.center(btn, btn, Icons.widget("last", UI.px(24))), function() self:chapterJump(1) end),
    }

    -- Third row, always the same height so the bar never moves under the
    -- finger: time left, or a way back after a jump.
    local row3_h = UI.px(40)
    local row3
    if self.origin_page and self.origin_page ~= page then
        row3 = UI.tap(UI.pill(HorizontalGroup:new{
            align = "center",
            Icons.widget("chev_left", UI.px(18)),
            UI.hgap(UI.px(4)),
            UI.text{ text = "Назад к стр. " .. self.origin_page, size = 14 },
        }, { hpad = UI.px(14), vpad = UI.px(5), radius = UI.px(16) }), function() self:goBack() end)
    else
        row3 = UI.text{ text = self:timeLine(page), size = 14, color = UI.C.text2, max_width = cw }
    end

    local vg = VerticalGroup:new{
        align = "left",
        UI.hline(W, UI.C.ink, math.max(2, UI.px(1))),
        UI.vgap(UI.px(10)),
        UI.pad(row1, { left = M, right = M }),
        UI.vgap(UI.px(4)),
        UI.pad(row2, { left = M, right = M }),
        UI.vgap(UI.px(2)),
        UI.center(W, row3_h, row3),
        UI.vgap(UI.px(12)),
    }
    return FrameContainer:new{ background = UI.C.paper, bordersize = 0, padding = 0, vg }
end

-- "Осталось в главе: 6 мин · в книге: 33 мин"
function Toolbar:timeLine(page)
    local reader = self.reader
    local chapter, learning = reader:secsLeft("chapter", page)
    if not chapter then
        return learning and "Определяем скорость чтения…" or ""
    end
    local book = reader:secsLeft("book", page)
    local text = "Осталось в главе: " .. reader.timeLeft(chapter)
    if book and book - chapter > 30 then
        text = text .. " · в книге: " .. reader.timeLeft(book)
    end
    return text
end

function Toolbar:build()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    local W, H = self.dimen.w, self.dimen.h
    self.top = self:topPanel(W)
    self.bottom = self:bottomPanel(W)
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        self.top,
        BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, self.bottom },
    }
end

function Toolbar:rebuild()
    self:build()
    UIManager:setDirty(self, "ui")
end

function Toolbar:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Toolbar:onCloseWidget()
    if self.reader.toolbar == self then
        self.reader.toolbar = nil
    end
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
end

function Toolbar:close()
    UIManager:close(self, "ui")
end

-- Close first, then open whatever comes next on top of the clean page.
function Toolbar:closeThen(fn)
    local ui = self.ui
    self:close()
    UIManager:nextTick(function()
        if ui.document then UI.safely(fn) end -- the book may have been closed meanwhile
    end)
end

-- Gestures that no button took.
function Toolbar:onTapOutside(_, ges)
    local pos = ges and ges.pos
    if inside(pos, self.top and self.top.dimen) or inside(pos, self.bottom and self.bottom.dimen) then
        return true -- panel background
    end
    self:close()
    return true
end

function Toolbar:onSwipeOutside()
    self:close()
    return true
end

function Toolbar:onHoldOutside()
    return true
end

function Toolbar:onSetDimensions()
    self:close()
end

-- Actions ---------------------------------------------------------------------

function Toolbar:goHome()
    local plugin = self.reader.plugin
    self:closeThen(function() plugin:onPolkaShow("home") end)
end

function Toolbar:search()
    self:closeThen(function() self.ui.search:onShowFulltextSearchInput() end)
end

function Toolbar:koreaderMenu()
    self:closeThen(function() self.ui.menu:onShowMenu() end)
end

function Toolbar:toggleBookmark()
    self.ui.bookmark:onToggleBookmark()
    self:rebuild()
end

function Toolbar:jumpTo(page)
    local cur = self.ui:getCurrentPage()
    if page == cur then return end
    if not self.origin_page then
        self.origin_page = cur
        self.ui.link:addCurrentLocationToStack()
    end
    self.ui:handleEvent(Event:new("GotoPage", page))
    self:rebuild()
end

function Toolbar:chapterJump(dir)
    local cur = self.ui:getCurrentPage()
    local page
    if dir > 0 then
        page = self.ui.toc:getNextChapter(cur)
    else
        page = self.ui.toc:getPreviousChapter(cur)
    end
    if page then self:jumpTo(page) end
end

function Toolbar:goBack()
    if not self.origin_page then return end
    self.origin_page = nil
    self.ui.link:onGoBackLink()
    self:rebuild()
end

return Toolbar
