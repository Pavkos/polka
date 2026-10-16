-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: design system.

Colors, fonts and the small set of primitives every screen is built from.
Everything is grayscale and calm on purpose: black text, two grays,
thin rules, no boxes unless they mean something.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FontList = require("fontlist")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = Device.screen

local UI = {}

UI.C = {
    ink = Blitbuffer.COLOR_BLACK,
    text2 = Blitbuffer.COLOR_GRAY_4,
    text3 = Blitbuffer.COLOR_GRAY_7,
    line = Blitbuffer.COLOR_LIGHT_GRAY,
    track = Blitbuffer.COLOR_GRAY_D,
    tint = Blitbuffer.COLOR_GRAY_E,
    paper = Blitbuffer.COLOR_WHITE,
    mid = Blitbuffer.COLOR_GRAY_9,
}

function UI.px(n)
    return Screen:scaleBySize(n)
end

-- Fonts -----------------------------------------------------------------

-- The Kindle's own fonts (/usr/java/lib/fonts): Bookerly, and Amazon Ember,
-- the font of the Kindle's menus and of its line under the page. Elsewhere,
-- or when a Kindle font has no Russian letters, the fonts KOReader bundles.
local FAMILIES = {
    serif = { "Bookerly-Regular.ttf", "NotoSerif-Regular.ttf" },
    serif_bold = { "Bookerly-Bold.ttf", "NotoSerif-Bold.ttf" },
    sans = { "Amazon-Ember-Regular.ttf", "NotoSans-Regular.ttf" },
    sans_bold = { "Amazon-Ember-Bold.ttf", "NotoSans-Bold.ttf" },
    mono = { "DroidSansMono.ttf" }, -- addresses to type
}
-- A bold face comes from the same family as the regular one (or a later one).
local BASE = { serif_bold = "serif", sans_bold = "sans" }
local CYRILLIC = { 0x0416, 0x044B, 0x0451 } -- Ж ы ё
local resolved, resolved_index = {}, {}

local function readsRussian(path)
    local ok, res = pcall(function()
        local face = Font:getFace(path, 12)
        if not face then return false end
        if not (face.ftsize and face.ftsize.hasGlyph) then return true end -- can't tell: trust the name
        for _, c in ipairs(CYRILLIC) do
            if not face.ftsize:hasGlyph(c) then return false end
        end
        return true
    end)
    return ok and res
end

local function resolveFamily(family)
    if resolved[family] then return resolved[family] end
    local candidates = FAMILIES[family] or FAMILIES.sans
    local from = 1
    if BASE[family] then
        resolveFamily(BASE[family])
        from = resolved_index[BASE[family]] or 1
    end
    local ok, list = pcall(FontList.getFontList, FontList)
    if ok and type(list) == "table" then
        for i = from, #candidates - 1 do
            local name = candidates[i]
            for _, path in ipairs(list) do
                if path:sub(-#name - 1) == "/" .. name and readsRussian(path) then
                    resolved[family], resolved_index[family] = path, i
                    return path
                end
            end
        end
        -- the bundled font, found where KOReader keeps it
        local name = candidates[#candidates]
        for _, path in ipairs(list) do
            if path:sub(-#name - 1) == "/" .. name then
                resolved[family], resolved_index[family] = path, #candidates
                return path
            end
        end
    end
    resolved[family], resolved_index[family] = candidates[#candidates], #candidates
    return resolved[family]
end

function UI.face(family, size)
    local face = Font:getFace(resolveFamily(family), size)
    if not face then
        face = Font:getFace("cfont", size)
    end
    return face
end

function UI.hasBookerly()
    return resolveFamily("serif"):find("Bookerly", 1, true) ~= nil
end

-- Text ------------------------------------------------------------------

-- One line of text, truncated with an ellipsis when max_width is given.
function UI.text(o)
    return TextWidget:new{
        text = o.text or "",
        face = UI.face(o.family or "sans", o.size or 18),
        fgcolor = o.color or UI.C.ink,
        max_width = o.max_width,
        padding = o.padding or 0,
        bold = o.bold,
    }
end

-- One line in a line box of `lh` times its size (CSS line-height: 1.05 for the
-- big code, 1.1 for the card's number), the spare split above and below.
function UI.lineText(o, lh)
    local t = UI.text(o)
    local natural = t:getSize().h
    local h = math.floor(UI.px(o.size or 18) * lh + 0.5)
    t.forced_height = h
    t.forced_baseline = t._baseline_h - math.floor((natural - h) / 2)
    return t
end

-- Where a line's letters stand (from its top).
function UI.baseline(t)
    t:getSize()
    return t.forced_baseline or t._baseline_h
end

-- A paragraph; max_lines caps the height and ends with an ellipsis.
function UI.para(o)
    local face = UI.face(o.family or "sans", o.size or 18)
    local line_height = o.line_height or 0.18
    local height
    if o.max_lines then
        height = math.floor((1 + line_height) * face.size + 0.5) * o.max_lines
    end
    local tb = TextBoxWidget:new{
        text = o.text or "",
        face = face,
        width = o.width,
        height = height,
        height_adjust = height and true or nil,
        height_overflow_show_ellipsis = height and true or nil,
        alignment = o.align or "left",
        fgcolor = o.color or UI.C.ink,
        bgcolor = o.bgcolor or UI.C.paper,
        bold = o.bold,
        line_height = line_height,
    }
    return tb
end

-- A note as plain text: newer KOReader may keep notes as HTML.
function UI.plainNote(note)
    if type(note) ~= "string" then return nil end
    if note:find("<%a") then
        note = note:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n"):gsub("<(/?)%a[%w]*[^<>]*>", "")
        note = note:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " "):gsub("&amp;", "&")
        note = note:gsub("\n\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return note:find("%S") and note or nil
end

-- Layout ----------------------------------------------------------------

function UI.vgap(h) return VerticalSpan:new{ width = h } end
function UI.hgap(w) return HorizontalSpan:new{ width = w } end

function UI.hline(w, color, thickness)
    return LineWidget:new{
        dimen = Geom:new{ w = w, h = thickness or UI.px(1) },
        background = color or UI.C.line,
    }
end

-- Left-aligned content stretched to a fixed width.
function UI.left(w, widget)
    return LeftContainer:new{ dimen = Geom:new{ w = w, h = widget:getSize().h }, widget }
end

function UI.right(w, widget)
    return RightContainer:new{ dimen = Geom:new{ w = w, h = widget:getSize().h }, widget }
end

function UI.center(w, h, widget)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h or widget:getSize().h }, widget }
end

-- Two widgets on one line: one hugging the left edge, one the right edge.
function UI.split(w, left, right, h)
    h = h or math.max(left:getSize().h, right and right:getSize().h or 0)
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, left },
    }
    if right then
        table.insert(group, RightContainer:new{ dimen = Geom:new{ w = w, h = h }, right })
    end
    return group
end

function UI.pad(widget, o)
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = o.left or 0,
        padding_right = o.right or 0,
        padding_top = o.top or 0,
        padding_bottom = o.bottom or 0,
        background = o.background,
        widget,
    }
end

-- A rounded outline, used for chips and buttons.
function UI.pill(widget, o)
    o = o or {}
    return FrameContainer:new{
        bordersize = o.border or UI.px(1),
        color = o.border_color or UI.C.mid,
        background = o.background or UI.C.paper,
        radius = o.radius or UI.px(14),
        padding = 0,
        padding_left = o.hpad or UI.px(12),
        padding_right = o.hpad or UI.px(12),
        padding_top = o.vpad or UI.px(4),
        padding_bottom = o.vpad or UI.px(4),
        widget,
    }
end

-- Letters set apart, like a printed form ("К О Д", "Ч И Т А Т Е Л Ь С К И Й"),
-- each letter its own glyph so the spacing is exact on any font.
function UI.spaced(text, o)
    o = o or {}
    local size = o.size or 13
    local gap = o.spacing or math.max(1, math.floor(UI.px(size) * 0.08))
    local row = HorizontalGroup:new{ align = "center" }
    local first = true
    for ch in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if not first then table.insert(row, HorizontalSpan:new{ width = gap }) end
        if ch == " " then
            table.insert(row, HorizontalSpan:new{ width = math.floor(UI.px(size) * 0.3) })
        else
            table.insert(row, UI.text{ text = ch, size = size, family = o.family or "sans_bold", color = o.color or UI.C.ink })
        end
        first = false
    end
    return row
end

-- A round-ended outlined button ("Подключить", "Новый код"), 42 units high.
function UI.pillButton(text, callback, o)
    o = o or {}
    local h = UI.px(o.height or 42)
    local border = math.max(2, UI.px(2))
    local label = UI.text{ text = text, size = o.size or 15, family = "sans_bold",
                           color = o.filled and UI.C.paper or UI.C.ink }
    local w = label:getSize().w + 2 * UI.px(o.hpad or 18) + 2 * border
    local frame = FrameContainer:new{
        bordersize = border, color = UI.C.ink,
        background = o.filled and UI.C.ink or UI.C.paper,
        radius = o.radius or math.floor(h / 2), padding = 0, margin = 0,
        width = w, height = h,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border }, label },
    }
    if not callback then return frame end
    return UI.tap(frame, callback)
end

-- Interaction -------------------------------------------------------------

-- Wraps any widget and makes the whole area tappable (and long-pressable).
local Tap = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
}

function Tap:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapPolka = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldPolka = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

-- A failing action must never take KOReader down: log it and say so.
function UI.safely(fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
        logger.err("Polka:", err)
        local InfoMessage = require("ui/widget/infomessage")
        local UIManager = require("ui/uimanager")
        UIManager:show(InfoMessage:new{
            text = "Что-то пошло не так. Подробности — в crash.log.\n\n" .. tostring(err):match("^[^\n]*"),
            timeout = 6,
        })
    end
    return ok
end

-- A tap area inside another one (the round «sync now» on a row) also hears
-- the outer one's event on its way down: it answers only to its own taps.
local function mine(self, ges)
    return not (ges and ges.pos and self.dimen and self.dimen.x) or ges.pos:intersectWith(self.dimen)
end

function Tap:onTapPolka(_, ges)
    if self.callback and mine(self, ges) then
        UI.safely(self.callback)
        return true
    end
end

function Tap:onHoldPolka(_, ges)
    if self.hold_callback and mine(self, ges) then
        UI.safely(self.hold_callback)
        return true
    end
end

function UI.tap(widget, callback, hold_callback)
    return Tap:new{ callback = callback, hold_callback = hold_callback, widget }
end

-- Painted widgets -----------------------------------------------------------

-- Thin progress bar: light track, black fill.
local Bar = Widget:extend{
    width = 100,
    height = 4,
    percent = 0,
    track = nil,
    fill = nil,
}

function Bar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Bar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, self.track or UI.C.track)
    local p = math.max(0, math.min(1, self.percent or 0))
    local fw = math.floor(self.width * p + 0.5)
    if fw > 0 then
        bb:paintRect(x, y, fw, self.height, self.fill or UI.C.ink)
    end
end

function UI.bar(w, h, percent, fill)
    return Bar:new{ width = w, height = h, percent = percent, fill = fill }
end

-- On/off switch in the style of the Kindle settings.
local Switch = Widget:extend{
    on = false,
    width = 40,
    height = 22,
}

function Switch:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Switch:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local r = math.floor(self.height / 2)
    local bw = math.max(2, UI.px(1))
    if self.on then
        bb:paintRoundedRect(x, y, self.width, self.height, UI.C.ink, r)
    else
        bb:paintRoundedRect(x, y, self.width, self.height, UI.C.paper, r)
        bb:paintBorder(x, y, self.width, self.height, bw, UI.C.ink, r)
    end
    local inset = bw + UI.px(2)
    local kr = r - inset
    local cx = self.on and (x + self.width - inset - kr) or (x + inset + kr)
    bb:paintCircle(cx, y + r, kr, self.on and UI.C.paper or UI.C.ink)
end

function UI.switch(on)
    return Switch:new{ on = on, width = UI.px(40), height = UI.px(22) }
end

-- Battery glyph: outline, nub and a fill proportional to the level.
local Battery = Widget:extend{
    level = 100,
    width = 22,
    height = 11,
}

function Battery:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Battery:paintTo(bb, x, y)
    local bw = math.max(1, UI.px(1))
    local nub = math.max(2, UI.px(2))
    local body = self.width - nub
    bb:paintBorder(x, y, body, self.height, bw, UI.C.ink)
    bb:paintRect(x + body, y + math.floor(self.height / 3), nub, self.height - 2 * math.floor(self.height / 3), UI.C.ink)
    local inner = body - 4 * bw
    local fw = math.floor(inner * math.max(0, math.min(100, self.level)) / 100 + 0.5)
    if fw > 0 then
        bb:paintRect(x + 2 * bw, y + 2 * bw, fw, self.height - 4 * bw, UI.C.ink)
    end
end

function UI.battery(level)
    return Battery:new{ level = level, width = UI.px(22), height = UI.px(11) }
end

-- Generic painter: a widget of fixed size whose paint function is given.
local Canvas = Widget:extend{
    width = 0,
    height = 0,
    painter = nil,
}

function Canvas:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Canvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.painter then self.painter(bb, x, y, self.width, self.height) end
end

function UI.canvas(w, h, painter)
    return Canvas:new{ width = w, height = h, painter = painter }
end

-- Kindle's status line: Wi‑Fi on the left, the clock in the middle,
-- battery on the right.
function UI.statusRow(w, h)
    local IconWidget = require("ui/widget/iconwidget")
    local NetworkMgr = require("ui/network/manager")
    local datetime = require("datetime")
    h = h or UI.px(30)
    local left
    if Device:hasWifiToggle() and NetworkMgr:isWifiOn() then
        left = IconWidget:new{ icon = "wifi.open.100", width = UI.px(18), height = UI.px(18) }
    else
        left = UI.text{ text = "", size = 13 }
    end
    local clock = UI.text{ text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
                           size = 14, family = "sans_bold" }
    local right = HorizontalGroup:new{ align = "center" }
    local powerd = Device:getPowerDevice()
    if Device:hasBattery() and powerd then
        local ok, level = pcall(powerd.getCapacity, powerd)
        level = ok and tonumber(level) or nil
        if level then
            local charging = false
            pcall(function() charging = powerd:isCharging() end)
            table.insert(right, UI.text{ text = string.format(charging and "%d %% ⚡" or "%d %%", level), size = 13, color = UI.C.text2 })
            table.insert(right, UI.hgap(UI.px(6)))
            table.insert(right, UI.battery(level))
        end
    end
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, left },
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, clock },
        RightContainer:new{ dimen = Geom:new{ w = w, h = h }, right },
    }
    return row
end

-- An icon from KOReader's symbols font (Font Awesome code points).
function UI.icon(codepoint, size, color)
    return TextWidget:new{
        text = require("util").unicodeCodepointToUtf8(codepoint),
        face = Font:getFace("nerdfonts/symbols.ttf", size or 18),
        fgcolor = color or UI.C.ink,
        padding = 0,
    }
end

-- Section header: "Недавние ............ Все ›"
function UI.sectionHeader(w, title, action_text, action_cb)
    local left = UI.text{ text = title, family = "sans_bold", size = 14, color = UI.C.text2 }
    local right
    if action_text then
        right = UI.tap(UI.pad(UI.text{ text = action_text .. "  ›", size = 15, color = UI.C.text2 },
            { left = UI.px(16), top = UI.px(4), bottom = UI.px(4) }), action_cb)
    end
    return UI.split(w, left, right)
end

-- Russian plural forms: plural(5, "книга", "книги", "книг") -> "книг"
function UI.plural(n, one, few, many)
    n = math.abs(math.floor(n or 0))
    local n10, n100 = n % 10, n % 100
    if n10 == 1 and n100 ~= 11 then return one end
    if n10 >= 2 and n10 <= 4 and (n100 < 10 or n100 >= 20) then return few end
    return many
end

function UI.books(n)
    return string.format("%d %s", n, UI.plural(n, "книга", "книги", "книг"))
end

-- 3725 s -> "1 ч 2 мин", 600 -> "10 мин"
function UI.duration(secs, short)
    secs = math.floor(secs or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then
        if short or m == 0 then return string.format("%d ч", h) end
        return string.format("%d ч %d мин", h, m)
    end
    return string.format("%d мин", m)
end

-- Thin space thousands separator: 12345 -> "12 345"
function UI.number(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

UI.MONTHS_GEN = { "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря" }
UI.MONTHS_SHORT = { "янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек" }
UI.WEEKDAYS = { "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс" }

-- Containers re-exported so screens need a single require.
UI.HorizontalGroup = HorizontalGroup
UI.VerticalGroup = VerticalGroup
UI.FrameContainer = FrameContainer
UI.OverlapGroup = OverlapGroup
UI.Geom = Geom

return UI
