-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the «Aa» panel.

Kindle's text settings on one sheet at the bottom of the page: font,
size, line spacing, margins, alignment and boldness. Every tap applies at
once, so the page above shows the result. "Все настройки" opens KOReader's
full panel for everything else.
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Icons = require("polka_icons")
local UI = require("polka_ui")

local Aa = InputContainer:extend{
    name = "polka_aa",
    reader = nil,
}

-- KOReader font sizes behind Kindle-like steps.
Aa.SIZES = { 14, 16, 18, 20, 22, 24, 27, 30, 34, 38 }
Aa.SPACING = {
    { value = 85, icon = "spacing1", label = "Плотный" },
    { value = 100, icon = "spacing2", label = "Обычный" },
    { value = 118, icon = "spacing3", label = "Свободный" },
}
-- Unscaled KOReader margins: side, top, bottom (the status line adds its own room).
Aa.MARGINS = {
    { h = 12, t = 12, b = 8, icon = "margins1", label = "Узкие" },
    { h = 30, t = 22, b = 12, icon = "margins2", label = "Обычные" },
    { h = 55, t = 32, b = 16, icon = "margins3", label = "Широкие" },
}
Aa.FONTS_SHOWN = 6

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Aa:init()
    self.ui = self.reader.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:build()
end

-- A choice button: rounded outline, inverted when selected.
local function choice(content_fn, w, h, active, cb)
    local fg = active and UI.C.paper or UI.C.ink
    local frame = FrameContainer:new{
        width = w,
        height = h,
        bordersize = active and 0 or math.max(1, UI.px(1) - 1),
        color = UI.C.mid,
        background = active and UI.C.ink or UI.C.paper,
        radius = UI.px(10),
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * UI.px(1), h = h - 2 * UI.px(1) },
            content_fn(fg, active and UI.C.ink or UI.C.paper),
        },
    }
    return UI.tap(frame, cb)
end

local function header(text, value)
    local left = UI.text{ text = text, family = "sans_bold", size = 14, color = UI.C.text2 }
    if not value then return left end
    return HorizontalGroup:new{ align = "center", left, UI.hgap(UI.px(8)),
        UI.text{ text = value, size = 14, color = UI.C.text3 } }
end

function Aa:fontButtons(cw)
    local reader = self.reader
    local faces = reader:fontChoices()
    -- «Шрифт книги»: for books with fonts of their own, as Kindle's "Publisher Font"
    local publisher = reader:alignmentAvailable() and reader:hasPublisherFonts()
    local publisher_on = publisher and reader:publisherFontsOn()
    local current = not publisher_on and reader:currentFont() or nil
    local slots = Aa.FONTS_SHOWN - (publisher and 1 or 0)
    local shown = {}
    local limit = #faces > slots and (slots - 1) or slots
    for i = 1, math.min(limit, #faces) do shown[i] = faces[i] end
    -- The current font is always one of the buttons.
    local found = false
    for _, f in ipairs(shown) do
        if f.name == current then found = true end
    end
    if not found and current then
        for _, f in ipairs(faces) do
            if f.name == current then
                shown[math.max(1, #shown)] = f
                break
            end
        end
    end
    local cols = 3
    local gap = UI.px(10)
    local bw = math.floor((cw - (cols - 1) * gap) / cols)
    local bh = UI.px(50)
    local items = {}
    if publisher then
        items[1] = choice(function(fg)
            return UI.text{ text = "Шрифт книги", size = 16, color = fg, max_width = bw - UI.px(16) }
        end, bw, bh, publisher_on, function() self:apply(function() reader:usePublisherFonts() end) end)
    end
    for _, f in ipairs(shown) do
        items[#items + 1] = choice(function(fg)
            local face = f.path and Font:getFace(f.path, 17) or UI.face("serif", 17)
            return TextWidget:new{ text = f.name, face = face, fgcolor = fg, max_width = bw - UI.px(16) }
        end, bw, bh, f.name == current, function() self:apply(function() reader:setFont(f.name) end) end)
    end
    if #faces > #shown then
        items[#items + 1] = choice(function(fg)
            return UI.text{ text = "Ещё…", size = 16, color = fg }
        end, bw, bh, false, function() self:allFonts(faces) end)
    end
    local grid = VerticalGroup:new{ align = "left" }
    for r = 0, math.ceil(#items / cols) - 1 do
        local row = HorizontalGroup:new{ align = "center" }
        for c = 1, cols do
            local it = items[r * cols + c]
            if it then
                if c > 1 then table.insert(row, UI.hgap(gap)) end
                table.insert(row, it)
            end
        end
        if r > 0 then table.insert(grid, UI.vgap(gap)) end
        table.insert(grid, row)
    end
    return grid
end

function Aa:sizeRow(cw)
    local reader = self.reader
    local size = reader:fontSize()
    local nearest, best = 1, math.huge
    for i, s in ipairs(Aa.SIZES) do
        if math.abs(s - size) < best then nearest, best = i, math.abs(s - size) end
    end
    local exact = Aa.SIZES[nearest] == size
    local btn = UI.px(56)
    local h = UI.px(50)
    local small = UI.tap(UI.center(btn, h, UI.text{ text = "A", family = "serif", size = 15 }),
        function() self:stepSize(-1) end)
    local big = UI.tap(UI.center(btn, h, UI.text{ text = "A", family = "serif", size = 26 }),
        function() self:stepSize(1) end)
    local n = #Aa.SIZES
    local cell = math.floor((cw - 2 * btn) / n)
    local row = HorizontalGroup:new{ align = "center", small }
    for i, s in ipairs(Aa.SIZES) do
        local r = UI.px(5) + math.floor((i - 1) * UI.px(4) / (n - 1))
        local active = i == nearest
        local dot = UI.canvas(cell, h, function(bb, x, y, w, hh)
            local cx, cy = x + math.floor(w / 2), y + math.floor(hh / 2)
            if active and exact then
                bb:paintCircle(cx, cy, r + UI.px(1), UI.C.ink)
            elseif active then
                bb:paintCircle(cx, cy, r + UI.px(1), UI.C.ink, math.max(2, UI.px(1)))
            else
                bb:paintCircle(cx, cy, r, UI.C.mid, math.max(1, UI.px(1) - 1))
            end
        end)
        table.insert(row, UI.tap(dot, function() self:apply(function() reader:setFontSize(s) end) end))
    end
    table.insert(row, big)
    return row, size
end

function Aa:stepSize(dir)
    local size = self.reader:fontSize()
    local target
    if dir < 0 then
        for i = #Aa.SIZES, 1, -1 do
            if Aa.SIZES[i] < size then target = Aa.SIZES[i] break end
        end
    else
        for _, s in ipairs(Aa.SIZES) do
            if s > size then target = s break end
        end
    end
    if target then
        self:apply(function() self.reader:setFontSize(target) end)
    end
end

-- Kindle's «Жирность»: five steps, from the font as drawn to quite bold.
-- Each dot is a ring drawn a little heavier than the one before.
function Aa:weightRow(w)
    local reader = self.reader
    local levels = reader.WEIGHTS
    local cur = reader:fontWeight()
    local nearest, best = 1, math.huge
    for i, v in ipairs(levels) do
        if math.abs(v - cur) < best then nearest, best = i, math.abs(v - cur) end
    end
    local exact = best < 0.01
    local h = UI.px(50)
    local btn = UI.px(40)
    local light = UI.tap(UI.center(btn, h, UI.text{ text = "A", family = "serif", size = 18 }),
        function() self:stepWeight(-1) end)
    local heavy = UI.tap(UI.center(btn, h, UI.text{ text = "A", family = "serif_bold", size = 18 }),
        function() self:stepWeight(1) end)
    local n = #levels
    local cell = math.floor((w - 2 * btn) / n)
    local r = UI.px(8)
    local row = HorizontalGroup:new{ align = "center", light }
    for i, v in ipairs(levels) do
        local active = i == nearest
        local ring = math.max(1, math.floor(UI.px(1) * (0.5 + 0.5 * i) + 0.5))
        local dot = UI.canvas(cell, h, function(bb, x, y, cw, ch)
            local cx, cy = x + math.floor(cw / 2), y + math.floor(ch / 2)
            if active and exact then
                bb:paintCircle(cx, cy, r + UI.px(1), UI.C.ink)
            elseif active then
                bb:paintCircle(cx, cy, r + UI.px(1), UI.C.ink, ring + math.max(1, UI.px(1)))
            else
                bb:paintCircle(cx, cy, r, UI.C.mid, ring)
            end
        end)
        table.insert(row, UI.tap(dot, function() self:apply(function() reader:setFontWeight(v) end) end))
    end
    table.insert(row, heavy)
    return row
end

function Aa:stepWeight(dir)
    local levels = self.reader.WEIGHTS
    local cur = self.reader:fontWeight()
    local target
    if dir < 0 then
        for i = #levels, 1, -1 do
            if levels[i] < cur - 0.01 then target = levels[i] break end
        end
    else
        for _, v in ipairs(levels) do
            if v > cur + 0.01 then target = v break end
        end
    end
    if target then
        self:apply(function() self.reader:setFontWeight(target) end)
    end
end

local function iconChoices(options, is_active, on_pick)
    local bw, bh = UI.px(62), UI.px(50)
    local gap = UI.px(8)
    local row = HorizontalGroup:new{ align = "center" }
    for i, o in ipairs(options) do
        if i > 1 then table.insert(row, UI.hgap(gap)) end
        local active = is_active(o)
        table.insert(row, choice(function(fg, bg)
            return Icons.widget(o.icon, UI.px(30), { color = fg, paper = bg })
        end, bw, bh, active, function() on_pick(o) end))
    end
    return row
end

function Aa:build()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    local reader = self.reader
    local W, H = self.dimen.w, self.dimen.h
    local M = UI.px(20)
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(vg, w) end

    -- Title row: KOReader's full panel and "Готово" on the right
    local more = UI.tap(UI.pad(UI.text{ text = "Все настройки  ›", size = 15, color = UI.C.text2 },
        { left = UI.px(16), right = UI.px(8), top = UI.px(8), bottom = UI.px(8) }), function() self:koreaderPanel() end)
    local done = UI.tap(UI.pad(UI.text{ text = "Готово", family = "sans_bold", size = 16 },
        { left = UI.px(16), top = UI.px(8), bottom = UI.px(8) }), function() self:close() end)
    add(UI.vgap(UI.px(8)))
    add(UI.split(cw, UI.text{ text = "Шрифт и вид", family = "sans_bold", size = 18 },
        HorizontalGroup:new{ align = "center", more, done }))
    add(UI.vgap(UI.px(10)))

    add(header("Шрифт"))
    add(UI.vgap(UI.px(8)))
    add(self:fontButtons(cw))
    add(UI.vgap(UI.px(16)))

    local size_row, size = self:sizeRow(cw)
    add(header("Размер", tostring(size)))
    add(size_row)
    add(UI.vgap(UI.px(10)))

    local spacing = reader:lineSpacing()
    local h_margin = reader:margins()
    local nearest_margin, best = nil, math.huge
    for _, m in ipairs(Aa.MARGINS) do
        if math.abs(m.h - h_margin) < best then nearest_margin, best = m, math.abs(m.h - h_margin) end
    end
    if best > 6 then nearest_margin = nil end
    local spacing_group = VerticalGroup:new{
        align = "left",
        header("Интервал"),
        UI.vgap(UI.px(8)),
        iconChoices(Aa.SPACING, function(o) return o.value == spacing end,
            function(o) self:apply(function() reader:setLineSpacing(o.value) end) end),
    }
    local margins_group = VerticalGroup:new{
        align = "left",
        header("Поля"),
        UI.vgap(UI.px(8)),
        iconChoices(Aa.MARGINS, function(o) return o == nearest_margin end,
            function(o) self:apply(function() reader:setMargins(o.h, o.t, o.b) end) end),
    }
    add(UI.split(cw, spacing_group, margins_group))
    add(UI.vgap(UI.px(16)))

    local weight_w = cw
    local align_group
    if reader:alignmentAvailable() then
        local align = reader:alignment()
        align_group = VerticalGroup:new{
            align = "left",
            header("Выравнивание"),
            UI.vgap(UI.px(8)),
            iconChoices({ { id = "justify", icon = "justify" }, { id = "left", icon = "ragged" } },
                function(o) return o.id == align end,
                function(o) self:apply(function() reader:setAlignment(o.id) end) end),
        }
        weight_w = math.min(UI.px(330), cw - align_group:getSize().w - UI.px(24))
    end
    local weight_group = VerticalGroup:new{
        align = "left",
        header("Жирность"),
        UI.vgap(UI.px(8)),
        self:weightRow(math.min(weight_w, UI.px(330))),
    }
    if align_group then
        add(UI.split(cw, align_group, weight_group))
    else
        add(weight_group)
    end
    add(UI.vgap(UI.px(18)))

    self.sheet = FrameContainer:new{
        background = UI.C.paper,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            UI.hline(W, UI.C.ink, math.max(2, UI.px(1))),
            UI.pad(vg, { left = M, right = M, top = UI.px(6) }),
        },
    }
    self[1] = BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, self.sheet }
end

-- Apply a change: the book re-renders underneath, then the panel shows the new state.
function Aa:apply(fn)
    UI.safely(fn)
    self:build()
    UIManager:setDirty(self, "ui")
end

function Aa:allFonts(faces)
    local Menu = require("ui/widget/menu")
    local reader = self.reader
    local current = reader:currentFont()
    local menu
    local items = {}
    for _, f in ipairs(faces) do
        items[#items + 1] = {
            text = f.name,
            mandatory = f.name == current and "✓" or nil,
            callback = function()
                self:apply(function() reader:setFont(f.name) end)
            end,
        }
    end
    menu = Menu:new{
        title = "Шрифты",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        is_enable_shortcut = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Aa:koreaderPanel()
    local ui = self.ui
    self:close()
    UIManager:nextTick(function()
        if ui.document then UI.safely(function() ui.config:onShowConfigMenu() end) end
    end)
end

function Aa:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Aa:close()
    UIManager:close(self, "ui")
end

function Aa:onCloseWidget()
    if self.reader.aa == self then
        self.reader.aa = nil
    end
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
end

function Aa:onTapOutside(_, ges)
    if inside(ges and ges.pos, self.sheet and self.sheet.dimen) then
        return true
    end
    self:close()
    return true
end

function Aa:onSwipeOutside(_, ges)
    if inside(ges and ges.pos, self.sheet and self.sheet.dimen) then
        return true
    end
    self:close()
    return true
end

function Aa:onHoldOutside()
    return true
end

function Aa:onSetDimensions()
    self:close()
end

return Aa
