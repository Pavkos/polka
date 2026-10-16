-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the sheet.

Every question Polka asks comes up from the bottom of the screen, under a
black rule, the way the «Aa» panel does: a title (with an icon or a quiet
note on its right), a few calm lines, and one or two big buttons. The page
above stays as it was. Used for Wi‑Fi, updates, the restart, the code for
the site, the place from another reader, and the like.

  Sheet:new{
      icon = "wifi", title = "Включить Wi‑Fi?", note = "у вас 1.7",
      body = "…", bullets = { "…" }, small = "…", big = "193 752", qr = "https://…",
      status = "Подключаюсь…",       -- replaces the buttons while something runs
      buttons = { { text = "Включить", primary = true, callback = fn }, { text = "Не сейчас", callback = fn } },
      dismissable = true, on_dismiss = fn,   -- a tap above the sheet closes it
  }
  sheet:show()  sheet:update{ status = "…" }  sheet:close()
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Icons = require("polka_icons")
local UI = require("polka_ui")

local Sheet = InputContainer:extend{
    name = "polka_sheet",
    icon = nil,
    title = nil,
    title_size = 27,
    note = nil,
    body = nil,
    bullets = nil,
    small = nil,
    big = nil,
    qr = nil,
    status = nil,
    buttons = nil,
    gap = 14,
    pad_top = 28,
    pad_bottom = 32,
    dismissable = true,
    on_dismiss = nil,
}

-- A big rounded button, filled (primary) or outlined, as in the mockups.
function Sheet.button(text, primary, w, callback)
    local h = UI.px(52)
    local border = math.max(2, UI.px(2))
    local label = UI.text{ text = text, size = 17, family = "sans_bold",
                           color = primary and UI.C.paper or UI.C.ink, max_width = w - UI.px(16) }
    local frame = UI.FrameContainer:new{
        bordersize = border, color = UI.C.ink,
        background = primary and UI.C.ink or UI.C.paper,
        radius = UI.px(10), padding = 0, margin = 0,
        width = w, height = h,
        UI.center(w - 2 * border, h - 2 * border, label),
    }
    return UI.tap(frame, callback)
end

-- Buttons sharing a row: each as wide as its label plus an equal share of the rest.
local function buttonRow(buttons, cw, sheet)
    local gap = UI.px(12)
    local n = #buttons
    local natural, total = {}, 0
    for i, b in ipairs(buttons) do
        local t = UI.text{ text = b.text, size = 17, family = "sans_bold" }
        natural[i] = t:getSize().w + UI.px(36)
        t:free()
        total = total + natural[i]
    end
    local spare = math.max(0, cw - total - gap * (n - 1))
    local row = HorizontalGroup:new{ align = "center" }
    local used = 0
    for i, b in ipairs(buttons) do
        local w = i == n and (cw - used - gap * (n - 1)) or math.floor(natural[i] + spare / n)
        used = used + w
        if i > 1 then table.insert(row, UI.hgap(gap)) end
        table.insert(row, Sheet.button(b.text, b.primary, w, function()
            if b.keep_open then
                if b.callback then b.callback(sheet) end
            else
                sheet:close()
                if b.callback then b.callback(sheet) end
            end
        end))
    end
    return row
end

-- "482 913": digits set apart like on a printed card (letter-spacing), in a
-- line box as tight as the mockups' (line-height 1.05).
function Sheet.spacedDigits(text, size, spacing)
    local px = UI.px(size)
    local row = HorizontalGroup:new{ align = "center" }
    local first = true
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if ch == " " then
            table.insert(row, UI.hgap(math.floor(px * 0.26 + 0.5) + spacing))
        else
            if not first then table.insert(row, UI.hgap(spacing)) end
            table.insert(row, UI.lineText({ text = ch, size = size, family = "sans_bold" }, 1.05))
        end
        first = false
    end
    return row
end

-- A QR code with a white margin and a hairline frame.
function Sheet.qrBox(text, size)
    local QRWidget = require("ui/widget/qrwidget")
    local border = math.max(1, UI.px(1))
    local inner = size - 2 * border
    local pad = math.floor(inner * 0.06)
    local qr = QRWidget:new{ text = text, width = inner - 2 * pad, height = inner - 2 * pad }
    return UI.FrameContainer:new{
        bordersize = border, color = UI.C.line, background = UI.C.paper, padding = 0, margin = 0,
        UI.center(inner, inner, qr),
    }
end

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

function Sheet:build()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    local W, H = self.dimen.w, self.dimen.h
    local M = UI.px(32)
    local cw = W - 2 * M
    local gap = UI.px(self.gap)
    local vg = VerticalGroup:new{ align = "left" }
    local function add(w)
        if #vg > 0 then table.insert(vg, UI.vgap(gap)) end
        table.insert(vg, w)
    end

    if self.title then
        local line = HorizontalGroup:new{ align = "center" }
        if self.icon then
            table.insert(line, Icons.widget(self.icon, UI.px(30), { stroke = math.max(2, UI.px(2)) }))
            table.insert(line, UI.hgap(UI.px(14)))
        end
        local note = self.note and UI.text{ text = self.note, size = 14, color = UI.C.text2 } or nil
        local room = cw - (self.icon and UI.px(44) or 0) - (note and note:getSize().w + UI.px(16) or 0)
        local title = UI.text{ text = self.title, family = "serif_bold", size = self.title_size }
        if title:getSize().w > room then
            -- a long title wraps instead of losing its end
            title:free()
            title = UI.para{ text = self.title, family = "serif_bold", size = self.title_size, width = room, line_height = 0.1 }
        end
        table.insert(line, title)
        add(note and UI.split(cw, line, note) or line)
    end
    if self.big then
        add(Sheet.spacedDigits(self.big, 70, UI.px(6)))
    end
    if self.body then
        add(UI.para{ text = self.body, size = 17, width = cw, line_height = 0.4 })
    end
    if self.qr then
        add(UI.center(cw, nil, Sheet.qrBox(self.qr, math.min(UI.px(260), cw))))
    end
    if self.bullets and #self.bullets > 0 then
        local list = VerticalGroup:new{ align = "left" }
        local dash = UI.text{ text = "—", size = 17 }
        local dash_w = dash:getSize().w
        dash:free()
        for i, b in ipairs(self.bullets) do
            if i > 1 then table.insert(list, UI.vgap(UI.px(10))) end
            table.insert(list, HorizontalGroup:new{
                align = "top",
                UI.text{ text = "—", size = 17 },
                UI.hgap(UI.px(12)),
                UI.para{ text = b, size = 17, width = cw - dash_w - UI.px(12), line_height = 0.35 },
            })
        end
        add(list)
    end
    if self.small then
        add(UI.para{ text = self.small, size = 14.5, color = UI.C.text2, width = cw, line_height = 0.3 })
    end
    if self.status then
        if #vg > 0 then table.insert(vg, UI.vgap(UI.px(8))) end
        add(UI.para{ text = self.status, size = 17, family = "sans_bold", width = cw, line_height = 0.3 })
    end
    if self.buttons and #self.buttons > 0 then
        if #vg > 0 then table.insert(vg, UI.vgap(UI.px(8))) end
        add(buttonRow(self.buttons, cw, self))
    end

    self.frame = UI.FrameContainer:new{
        background = UI.C.paper, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            UI.hline(W, UI.C.ink, math.max(2, UI.px(2))),
            UI.pad(vg, { left = M, right = M, top = UI.px(self.pad_top), bottom = UI.px(self.pad_bottom) }),
        },
    }
    local fh = self.frame:getSize().h
    self.region = Geom:new{ x = 0, y = H - fh, w = W, h = fh }
    self[1] = BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, self.frame }
end

function Sheet:show()
    UIManager:show(self, "ui", self.region)
    return self
end

-- Changes some fields and repaints (the page above too, if the sheet got shorter).
function Sheet:update(fields)
    if self.closed then return end
    local old = self.region
    for k, v in pairs(fields) do
        if v == false then self[k] = nil else self[k] = v end
    end
    self:build()
    if old and self.region.h < old.h then
        UIManager:setDirty("all", "ui", old)
    else
        UIManager:setDirty(self, "ui", self.region)
    end
end

function Sheet:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "ui", self.region)
end

function Sheet:dismiss()
    if self.closed then return end
    self:close()
    if self.on_dismiss then UI.safely(self.on_dismiss) end
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Sheet:onTapOutside(_, ges)
    if inside(ges and ges.pos, self.region) then return true end
    if self.dismissable then self:dismiss() end
    return true
end

function Sheet:onHoldOutside() return true end
function Sheet:onSwipeOutside() return true end

function Sheet:onCloseWidget()
    self.closed = true
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
end

-- The device was turned: the sheet is laid out again for the new screen.
function Sheet:onSetDimensions()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self:build()
    UIManager:setDirty("all", "ui")
end

return Sheet
