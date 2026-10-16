-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: book covers.

A cover is the cached CoverBrowser thumbnail scaled to fit, with a hairline
frame; books without a cover get a quiet typeset placeholder instead.
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local Books = require("polka_books")
local UI = require("polka_ui")

local Covers = {}

local function placeholder(rec, w, h)
    local inner = w - 2 * UI.px(8)
    local title_size = math.max(10, math.min(22, math.floor(w / UI.px(10))))
    local group = VerticalGroup:new{
        align = "center",
        UI.para{ text = rec.title or rec.name, family = "serif_bold", size = title_size,
                 width = inner, align = "center", max_lines = 5, bgcolor = UI.C.tint },
    }
    if rec.authors and rec.authors ~= "" then
        table.insert(group, UI.vgap(UI.px(6)))
        table.insert(group, UI.para{ text = rec.authors, size = math.max(9, title_size - 4),
                                     width = inner, align = "center", color = UI.C.text2, max_lines = 2,
                                     bgcolor = UI.C.tint })
    end
    return FrameContainer:new{
        bordersize = UI.px(1),
        color = UI.C.line,
        background = UI.C.tint,
        padding = 0,
        width = w,
        height = h,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * UI.px(1), h = h - 2 * UI.px(1) }, group },
    }
end

-- Cover fitting into w x h, bottom-aligned (books stand on a shelf).
function Covers.widget(rec, w, h)
    local border = UI.px(1)
    local bb = Books:cover(rec.path, w - 2 * border, h - 2 * border)
    local content
    if bb then
        content = FrameContainer:new{
            bordersize = border,
            color = UI.C.line,
            padding = 0,
            ImageWidget:new{
                image = bb,
                image_disposable = false,
                width = bb:getWidth(),
                height = bb:getHeight(),
            },
        }
    else
        content = placeholder(rec, w, h)
    end
    return BottomContainer:new{ dimen = Geom:new{ w = w, h = h }, content }
end

-- A typeset cover for a book known only by title and author (OPDS, Instapaper).
function Covers.placeholder(info, w, h)
    return placeholder({ title = info.title, authors = info.authors }, w, h)
end

-- A decoded picture (already scaled to fit) with the same hairline frame.
function Covers.framed(bb)
    return FrameContainer:new{
        bordersize = UI.px(1),
        color = UI.C.line,
        padding = 0,
        ImageWidget:new{ image = bb, image_disposable = false, width = bb:getWidth(), height = bb:getHeight() },
    }
end

-- Decode and scale a cover ahead of time (same cache entry Covers.widget uses).
function Covers.prefetch(rec, w, h)
    local border = UI.px(1)
    Books:cover(rec.path, w - 2 * border, h - 2 * border)
end

-- Size actually occupied by the cover inside its w x h box (for drawing a
-- progress bar exactly under the image).
function Covers.fittedWidth(rec, w, h)
    local border = UI.px(1)
    local bb = Books:cover(rec.path, w - 2 * border, h - 2 * border)
    if bb then return bb:getWidth() + 2 * border end
    return w
end

return Covers
