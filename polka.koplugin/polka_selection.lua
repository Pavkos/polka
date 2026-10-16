-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the selection panel, as on a Kindle.

When text is selected, KOReader shows a two-column menu of a dozen buttons.
Instead, a small card appears next to the selection:
  Выделить · Заметка · Копировать · Словарь · Ещё
and a tap on an existing highlight gives
  (its note) · Заметка · Копировать · Стиль · Удалить · Ещё
"Ещё" opens KOReader's own menu, with everything in it.

The actions are KOReader's own: the new-selection buttons are taken from
ReaderHighlight's button table and their callbacks are called as they are,
so they behave exactly like in the installed KOReader version ("Словарь"
looks the word up the way newer versions do, keeping the selection tied to
the dictionary window). Nothing here changes KOReader's classes:
polka_reader patches the open book's ReaderHighlight instance and puts it
back when the Kindle mode is off.

A tap outside the card closes it; a hold or a swipe outside closes it and
goes on to the book (a new selection, a page turn), like on a Kindle.
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("util")
local Screen = Device.screen

local UI = require("polka_ui")

local Selection = {}

local Panel = InputContainer:extend{
    name = "polka_selection",
    actions = nil,   -- { { icon, label, callback, enabled } }
    note = nil,      -- note text shown above the buttons (existing highlight)
    boxes = nil,     -- screen boxes of the selection, to stand next to it
    on_outside = nil,
    on_note = nil,
}

function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    local W = self.dimen.w
    local margin = UI.px(14)
    local border = math.max(1, UI.px(1))
    local inner = W - 2 * margin - 2 * border
    local n = #self.actions
    local sep = math.max(1, UI.px(1))
    local avail = inner - sep * (n - 1) -- the separators take their share of the width
    local cell_w = math.floor(avail / n)
    local cell_h = UI.px(68)
    local row = HorizontalGroup:new{ align = "center" }
    for i, a in ipairs(self.actions) do
        local w = (i == n) and (avail - cell_w * (n - 1)) or cell_w
        local col = VerticalGroup:new{
            align = "center",
            UI.icon(a.icon, 20, a.enabled == false and UI.C.line or UI.C.ink),
            UI.vgap(UI.px(6)),
            UI.text{ text = a.label, size = 13, color = a.enabled == false and UI.C.line or UI.C.text2, max_width = w - UI.px(4) },
        }
        local cell = UI.center(w, cell_h, col)
        if a.enabled ~= false then
            local cb = a.callback
            cell = UI.tap(cell, function() cb() end)
        end
        table.insert(row, cell)
        if i < n then
            table.insert(row, UI.canvas(sep, cell_h, function(bb, x, y, cw, ch)
                bb:paintRect(x, y + UI.px(16), cw, ch - UI.px(32), UI.C.line)
            end))
        end
    end
    local content = VerticalGroup:new{ align = "left" }
    if self.note then
        local note = UI.para{ text = "✎ " .. self.note, size = 15, color = UI.C.ink, width = inner - 2 * UI.px(14), max_lines = 4 }
        local note_box = UI.pad(note, { left = UI.px(14), right = UI.px(14), top = UI.px(12), bottom = UI.px(10) })
        if self.on_note then
            local cb = self.on_note
            note_box = UI.tap(note_box, function() cb() end)
        end
        table.insert(content, note_box)
        table.insert(content, UI.hline(inner, UI.C.line))
    end
    table.insert(content, row)
    self.card = UI.FrameContainer:new{
        bordersize = border,
        color = UI.C.ink,
        background = UI.C.paper,
        radius = UI.px(8),
        padding = 0,
        margin = 0,
        content,
    }
    local size = self.card:getSize()
    local card_h = size.h
    -- Below the selection if it fits, otherwise above it, otherwise at the bottom.
    local gap = UI.px(10)
    local H = self.dimen.h
    local y = H - card_h - UI.px(24)
    local boxes = self.boxes
    if boxes and #boxes > 0 then
        local y0, y1 = math.huge, -math.huge
        for _, b in ipairs(boxes) do
            if b.y < y0 then y0 = b.y end
            if b.y + b.h > y1 then y1 = b.y + b.h end
        end
        if y1 + gap + card_h <= H - UI.px(8) then
            y = y1 + gap
        elseif y0 - gap - card_h >= UI.px(8) then
            y = y0 - gap - card_h
        end
    end
    self.card_x = math.floor((W - size.w) / 2)
    self.card_y = math.max(UI.px(8), y)
    -- The refresh region is exactly the card.
    self.card_dimen = Geom:new{ x = self.card_x, y = self.card_y, w = size.w, h = size.h }
    self[1] = UI.OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        UI.pad(self.card, { left = self.card_x, top = self.card_y }),
    }
end

local function inside(pos, d)
    return pos and d and pos.x >= d.x and pos.x < d.x + d.w and pos.y >= d.y and pos.y < d.y + d.h
end

-- Closes the card, then hands the gesture to the book on the next tick (the
-- card is gone by then, so the book gets it as if the card had not been there).
function Panel:passOn(ges)
    if self.on_outside then UI.safely(self.on_outside) end
    if ges then
        UIManager:nextTick(function() UIManager:sendEvent(Event:new("Gesture", ges)) end)
    end
end

-- Buttons get their taps first (children before the container); what is
-- left here either fell between buttons or outside the card.
function Panel:onTapOutside(_, ges)
    if inside(ges and ges.pos, self.card_dimen) then return true end
    if self.on_outside then UI.safely(self.on_outside) end
    return true
end

function Panel:onHoldOutside(_, ges)
    if inside(ges and ges.pos, self.card_dimen) then return true end
    self:passOn(ges) -- a hold elsewhere starts a new selection
    return true
end

function Panel:onSwipeOutside(_, ges)
    self:passOn(ges) -- a swipe turns the page
    return true
end

-- Helpers ------------------------------------------------------------------------

local function screenBoxes(hl, index)
    local boxes
    if index then
        local ok, b = pcall(hl.getHighlightVisibleBoxes, hl, index)
        boxes = ok and b or nil
    elseif hl.selected_text then
        boxes = hl.selected_text.sboxes or hl.selected_text.pboxes
    end
    if not boxes then return nil end
    if hl.ui.paging then
        local page
        if index then
            local item = hl.ui.annotation.annotations[index]
            page = item and item.pos0 and item.pos0.page
        else
            page = hl.selected_text.pos0 and hl.selected_text.pos0.page
        end
        local out = {}
        for _, b in ipairs(boxes) do
            local s = page and hl.view:pageToScreenTransform(page, b)
            if s then out[#out + 1] = s end
        end
        return out
    end
    return boxes
end

-- A button from KOReader's own table for the selection menu, or nil.
local function stock(hl, key)
    local fn = hl._highlight_buttons and hl._highlight_buttons[key]
    if type(fn) ~= "function" then return nil end
    local ok, b = pcall(fn, hl)
    if ok and type(b) == "table" and type(b.callback) == "function" then return b end
end

local function copyText(text)
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(util.cleanupSelectedText(text or ""))
        UIManager:show(Notification:new{ text = "Скопировано" })
    end
end

-- The dictionary for the selection, handing the selection to the dictionary
-- window (as newer KOReader versions do): it is cleared when the window
-- closes, and the window's own "Выделить" works. Returns false if it could
-- not look up (the caller then uses KOReader's own button).
local function lookupDict(hl)
    if hl.highlightFromHoldPos then hl:highlightFromHoldPos() end
    local st = hl.selected_text
    if not st or type(st.text) ~= "string" or not (hl.ui.dictionary and hl.ui.dictionary.onLookupWord) then
        return false
    end
    local boxes = st.sboxes or st.pboxes
    local word_boxes
    if boxes then
        word_boxes = {}
        local page = type(st.pos0) == "table" and st.pos0.page or nil
        for i, box in ipairs(boxes) do
            word_boxes[i] = hl.view:pageToScreenTransform(page, box)
        end
    end
    hl.ui.dictionary:onLookupWord(util.cleanupSelectedText(st.text), false, word_boxes, hl)
    return true
end

-- Public -------------------------------------------------------------------------

-- New selection. orig_menu(hl) shows KOReader's own menu ("Ещё").
function Selection.showNew(reader, hl, orig_menu)
    local panel
    local function close()
        if panel then
            UIManager:close(panel, "ui", panel.card_dimen)
            if hl.highlight_dialog == panel then hl.highlight_dialog = nil end
            if reader.selection == panel then reader.selection = nil end
            panel = nil
        end
    end
    local function fromStock(key, icon, label, own)
        local b = stock(hl, key)
        if not b then return nil end
        return { icon = icon, label = label, enabled = b.enabled ~= false, callback = function()
            close()
            if own then
                local ok, done = pcall(own, hl)
                if ok and done then return end
            end
            b.callback()
        end }
    end
    local actions = {}
    for _, a in ipairs({
        fromStock("02_highlight", 0xF1FC, "Выделить"),
        fromStock("04_add_note", 0xF24A, "Заметка"),
        fromStock("03_copy", 0xF0C5, "Копировать"),
        fromStock("06_dictionary", 0xF02D, "Словарь", lookupDict),
    }) do
        if a then actions[#actions + 1] = a end
    end
    actions[#actions + 1] = { icon = 0xF141, label = "Ещё", callback = function()
        close()
        orig_menu(hl)
    end }
    local function dismiss()
        close()
        if hl.hold_pos then hl:clear() end
    end
    panel = Panel:new{
        actions = actions,
        boxes = screenBoxes(hl),
        on_outside = dismiss,
    }
    panel.dismiss = dismiss
    hl.highlight_dialog = panel -- KOReader's own code closes it like its menu
    reader.selection = panel
    UIManager:show(panel, "[ui]", panel.card_dimen)
end

-- Tap on an existing highlight. orig_dialog(hl, index) is KOReader's own
-- highlight dialog ("Ещё": boundaries, colour, details…).
function Selection.showExisting(reader, hl, index, orig_dialog)
    local item = hl.ui.annotation and hl.ui.annotation.annotations[index]
    if not item then return orig_dialog(hl, index) end
    local panel
    local function close()
        if panel then
            UIManager:close(panel, "ui", panel.card_dimen)
            if reader.selection == panel then reader.selection = nil end
            panel = nil
        end
    end
    local function act(fn)
        return function()
            close()
            fn()
        end
    end
    local actions = {
        { icon = 0xF24A, label = "Заметка", callback = act(function() hl:editNote(index) end) },
        { icon = 0xF0C5, label = "Копировать", callback = act(function() copyText(item.text) end) },
        { icon = 0xF0CD, label = "Стиль", callback = act(function() hl:editHighlightStyle(index) end) },
        { icon = 0xF014, label = "Удалить", callback = act(function() hl:deleteHighlight(index) end) },
        { icon = 0xF141, label = "Ещё", callback = act(function() orig_dialog(hl, index) end) },
    }
    local note = UI.plainNote(item.note)
    panel = Panel:new{
        actions = actions,
        note = note,
        on_note = note and act(function() hl:editNote(index) end) or nil,
        boxes = screenBoxes(hl, index),
        on_outside = close,
    }
    panel.dismiss = close
    reader.selection = panel
    UIManager:show(panel, "[ui]", panel.card_dimen)
end

Selection.Panel = Panel

return Selection
