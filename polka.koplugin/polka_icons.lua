--[[--
Polka: thin line icons for the reading toolbar and the «Aa» panel.

Drawn with plain rectangles and circles, so they share one stroke width
and stay crisp on e-ink at any size. Every icon is a fixed-size widget.
]]

local UI = require("polka_ui")

local Icons = {}

local function stroke(size)
    return math.max(2, math.floor(size / 16 + 0.5))
end

-- A straight line of thickness t, stamped along its length.
local function line(bb, x1, y1, x2, y2, t, c)
    local dx, dy = x2 - x1, y2 - y1
    local n = math.max(math.abs(dx), math.abs(dy))
    local h = math.floor(t / 2)
    if n == 0 then
        bb:paintRect(x1 - h, y1 - h, t, t, c)
        return
    end
    for i = 0, n do
        local px = math.floor(x1 + dx * i / n + 0.5)
        local py = math.floor(y1 + dy * i / n + 0.5)
        bb:paintRect(px - h, py - h, t, t, c)
    end
end

local function hbar(bb, x, y, w, t, c)
    bb:paintRect(x, y - math.floor(t / 2), w, t, c)
end

local painters = {}

-- Table of contents: bullets and lines.
function painters.list(bb, x, y, s, c, t)
    local rows = 4
    local top, bottom = y + math.floor(s * 0.2), y + math.floor(s * 0.8)
    local step = (bottom - top) / (rows - 1)
    local dot = math.max(t + 1, math.floor(s * 0.11))
    for i = 0, rows - 1 do
        local ry = math.floor(top + i * step + 0.5)
        bb:paintRect(x + math.floor(s * 0.08), ry - math.floor(dot / 2), dot, dot, c)
        hbar(bb, x + math.floor(s * 0.3), ry, math.floor(s * 0.62), t, c)
    end
end

function painters.search(bb, x, y, s, c, t)
    local r = math.floor(s * 0.3)
    local cx, cy = x + math.floor(s * 0.42), y + math.floor(s * 0.42)
    bb:paintCircle(cx, cy, r, c, t)
    local o = math.floor(r * 0.72)
    line(bb, cx + o, cy + o, x + math.floor(s * 0.88), y + math.floor(s * 0.88), t + 1, c)
end

-- Vertical ellipsis: the "more" menu.
function painters.dots(bb, x, y, s, c, t)
    local r = math.max(2, math.floor(s * 0.075))
    local cx = x + math.floor(s / 2)
    for _, f in ipairs({ 0.2, 0.5, 0.8 }) do
        bb:paintCircle(cx, y + math.floor(s * f), r, c)
    end
end

-- Bookmark ribbon; filled when the page is bookmarked.
local function ribbon(bb, x, y, s, c, t, filled, paper)
    local x0, x1 = x + math.floor(s * 0.24), x + math.floor(s * 0.76)
    local y0, y1 = y + math.floor(s * 0.1), y + math.floor(s * 0.9)
    local notch = y + math.floor(s * 0.66)
    local mid = math.floor((x0 + x1) / 2)
    if filled then
        bb:paintRect(x0, y0, x1 - x0, y1 - y0, c)
        -- cut the V notch out of the bottom
        for ry = notch, y1 do
            local f = (ry - notch) / math.max(1, y1 - notch)
            local half = math.floor((x1 - x0) / 2 * f + 0.5)
            if half > 0 then
                bb:paintRect(mid - half, ry, 2 * half, 1, paper)
            end
        end
    else
        hbar(bb, x0, y0 + math.floor(t / 2), x1 - x0, t, c)
        bb:paintRect(x0, y0, t, y1 - y0, c)
        bb:paintRect(x1 - t, y0, t, y1 - y0, c)
        line(bb, x0 + math.floor(t / 2), y1 - 1, mid, notch, t, c)
        line(bb, x1 - math.ceil(t / 2), y1 - 1, mid, notch, t, c)
    end
end

function painters.ribbon(bb, x, y, s, c, t, o)
    ribbon(bb, x, y, s, c, t, false, o.paper)
end

function painters.ribbon_filled(bb, x, y, s, c, t, o)
    ribbon(bb, x, y, s, c, t, true, o.paper)
end

-- Notes: a sheet with a few lines of text.
function painters.notes(bb, x, y, s, c, t)
    local x0, y0 = x + math.floor(s * 0.2), y + math.floor(s * 0.1)
    local w, h = math.floor(s * 0.6), math.floor(s * 0.8)
    bb:paintBorder(x0, y0, w, h, t, c)
    for i, f in ipairs({ 0.32, 0.5, 0.68 }) do
        local lw = math.floor(w * (i == 3 and 0.35 or 0.55))
        hbar(bb, x0 + math.floor(w * 0.22), y + math.floor(s * f), lw, t, c)
    end
end

function painters.chev_left(bb, x, y, s, c, t)
    local tip, top, bottom = x + math.floor(s * 0.32), y + math.floor(s * 0.2), y + math.floor(s * 0.8)
    local back = x + math.floor(s * 0.62)
    line(bb, back, top, tip, y + math.floor(s / 2), t + 1, c)
    line(bb, tip, y + math.floor(s / 2), back, bottom, t + 1, c)
end

-- "To the start / end of the chapter": a bar and a chevron.
function painters.first(bb, x, y, s, c, t)
    local top, bottom, mid = y + math.floor(s * 0.22), y + math.floor(s * 0.78), y + math.floor(s / 2)
    bb:paintRect(x + math.floor(s * 0.22), top, t + 1, bottom - top, c)
    line(bb, x + math.floor(s * 0.72), top, x + math.floor(s * 0.4), mid, t + 1, c)
    line(bb, x + math.floor(s * 0.4), mid, x + math.floor(s * 0.72), bottom, t + 1, c)
end

function painters.last(bb, x, y, s, c, t)
    local top, bottom, mid = y + math.floor(s * 0.22), y + math.floor(s * 0.78), y + math.floor(s / 2)
    bb:paintRect(x + math.floor(s * 0.78) - t, top, t + 1, bottom - top, c)
    line(bb, x + math.floor(s * 0.28), top, x + math.floor(s * 0.6), mid, t + 1, c)
    line(bb, x + math.floor(s * 0.6), mid, x + math.floor(s * 0.28), bottom, t + 1, c)
end

-- Line spacing: three lines, closer or further apart.
local function spacing(bb, x, y, s, c, t, gap)
    local w = math.floor(s * 0.8)
    local x0 = x + math.floor((s - w) / 2)
    local g = math.floor(s * gap)
    local cy = y + math.floor(s / 2)
    for i = -1, 1 do
        hbar(bb, x0, cy + i * g, w, t, c)
    end
end
function painters.spacing1(bb, x, y, s, c, t) spacing(bb, x, y, s, c, t, 0.14) end
function painters.spacing2(bb, x, y, s, c, t) spacing(bb, x, y, s, c, t, 0.22) end
function painters.spacing3(bb, x, y, s, c, t) spacing(bb, x, y, s, c, t, 0.32) end

-- Margins: a page with text inset by a narrow, normal or wide margin.
local function margins(bb, x, y, s, c, t, inset)
    local pw, ph = math.floor(s * 0.72), math.floor(s * 0.9)
    local x0, y0 = x + math.floor((s - pw) / 2), y + math.floor((s - ph) / 2)
    bb:paintBorder(x0, y0, pw, ph, math.max(1, t - 1), c)
    local m = math.floor(pw * inset)
    local rows = 5
    local top, bottom = y0 + math.floor(ph * 0.2), y0 + math.floor(ph * 0.8)
    for i = 0, rows - 1 do
        local ry = math.floor(top + (bottom - top) * i / (rows - 1) + 0.5)
        hbar(bb, x0 + m, ry, pw - 2 * m, math.max(1, t - 1), c)
    end
end
function painters.margins1(bb, x, y, s, c, t) margins(bb, x, y, s, c, t, 0.12) end
function painters.margins2(bb, x, y, s, c, t) margins(bb, x, y, s, c, t, 0.22) end
function painters.margins3(bb, x, y, s, c, t) margins(bb, x, y, s, c, t, 0.32) end

-- Alignment: justified lines, or a ragged right edge.
local function align(bb, x, y, s, c, t, widths)
    local w = math.floor(s * 0.8)
    local x0 = x + math.floor((s - w) / 2)
    local top, bottom = y + math.floor(s * 0.22), y + math.floor(s * 0.78)
    for i, f in ipairs(widths) do
        local ry = math.floor(top + (bottom - top) * (i - 1) / (#widths - 1) + 0.5)
        hbar(bb, x0, ry, math.floor(w * f), t, c)
    end
end
function painters.justify(bb, x, y, s, c, t) align(bb, x, y, s, c, t, { 1, 1, 1, 0.6 }) end
function painters.ragged(bb, x, y, s, c, t) align(bb, x, y, s, c, t, { 1, 0.7, 0.9, 0.55 }) end

--- A square icon widget.
-- @tparam string name icon name (see painters above)
-- @tparam int size side in pixels
-- @tparam[opt] table o { color = ink, paper = background color behind the icon }
function Icons.widget(name, size, o)
    o = o or {}
    local color = o.color or UI.C.ink
    local paper = o.paper or UI.C.paper
    local painter = painters[name]
    local t = o.stroke or stroke(size)
    return UI.canvas(size, size, function(bb, x, y)
        if painter then painter(bb, x, y, size, color, t, { paper = paper }) end
    end)
end

return Icons
