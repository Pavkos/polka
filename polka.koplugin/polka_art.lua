-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: painted details for the reader's card and badges.

Badge medallions (antialiased discs and progress rings) and rubber stamps
("ПРОЧИТАНО", "ЗАЧТЕНО"): each is rendered once into a small alpha mask —
a stamp tilted and inked unevenly like a real one — and afterwards painted
with a single blit. The masks are small and kept between visits (LRU).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local bit = require("bit")
local ffi = require("ffi")
local util = require("util")

local UI = require("polka_ui")

local Art = {}

local floor, sqrt, atan2, min, max = math.floor, math.sqrt, math.atan2, math.min, math.max
local TWO_PI = 2 * math.pi

-- Mask cache ------------------------------------------------------------------

local cache, order = {}, {}
local MAX_MASKS = 64 -- about 1.5 MB at most

local function remember(key, bb)
    cache[key] = bb
    order[#order + 1] = key
    if #order > MAX_MASKS then
        -- Forgotten, not freed: a widget on screen may still paint it (GC frees it).
        cache[table.remove(order, 1)] = nil
    end
    return bb
end

-- A cache hit moves the mask to the fresh end, so the badge rings used on
-- every visit are not pushed out by a long run of new stamps.
local function cached(key)
    local bb = cache[key]
    if bb and order[#order] ~= key then
        for i = #order, 1, -1 do
            if order[i] == key then
                table.remove(order, i)
                break
            end
        end
        order[#order + 1] = key
    end
    return bb
end

-- Only when nothing on screen uses the masks.
function Art.free()
    for k, bb in pairs(cache) do
        bb:free()
        cache[k] = nil
    end
    order = {}
end

local function newMask(w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8) -- zero-filled: transparent
    return bb, ffi.cast("uint8_t*", bb.data), tonumber(bb.stride)
end

-- Discs and rings ---------------------------------------------------------------

local function disc(d)
    local key = "disc" .. d
    if cached(key) then return cache[key] end
    local bb, p, stride = newMask(d, d)
    local r = d / 2
    for y = 0, d - 1 do
        local dy = y + 0.5 - r
        for x = 0, d - 1 do
            local dx = x + 0.5 - r
            local a = r - sqrt(dx * dx + dy * dy) + 0.5
            if a > 0 then p[y * stride + x] = a >= 1 and 255 or floor(a * 255) end
        end
    end
    return remember(key, bb)
end

-- A ring of the given thickness; frac < 1 draws only an arc, clockwise from 12 o'clock.
local function ring(d, thick, frac)
    frac = max(0, min(1, frac or 1))
    local key = string.format("ring%d:%d:%.2f", d, thick, frac)
    if cached(key) then return cache[key] end
    local bb, p, stride = newMask(d, d)
    local r_out = d / 2
    local r_in = r_out - thick
    local limit = frac * TWO_PI
    for y = 0, d - 1 do
        local dy = y + 0.5 - r_out
        for x = 0, d - 1 do
            local dx = x + 0.5 - r_out
            local dist = sqrt(dx * dx + dy * dy)
            local a = min(r_out - dist + 0.5, dist - r_in + 0.5, 1)
            if a > 0 and frac < 1 then
                local ang = atan2(dx, -dy)
                if ang < 0 then ang = ang + TWO_PI end
                if ang <= limit then
                    a = a * min(1, ang * dist + 0.5, (limit - ang) * dist + 0.5)
                else
                    a = a * max(0, 0.5 - min((TWO_PI - ang) * dist, (ang - limit) * dist))
                end
            end
            if a > 0 then p[y * stride + x] = floor(a * 255) end
        end
    end
    return remember(key, bb)
end

-- Medallion -------------------------------------------------------------------------
--
-- Earned: a black enamel disc with a thin inner ring and a white number or
-- symbol. Not yet: a light outline, the progress as a darker arc, gray content.

local Medallion = Widget:extend{
    units = 46,      -- diameter before screen scaling (like font sizes)
    earned = false,
    progress = 0,
    num = nil, cap = nil, icon = nil,
}

local function fitText(text, family, units, max_w, color)
    local t
    repeat
        if t then t:free() end
        t = TextWidget:new{ text = text, face = UI.face(family, units), fgcolor = color, padding = 0 }
        units = units - 1
    until t:getSize().w <= max_w or units < 6
    return t
end

function Medallion:init()
    self.d = UI.px(self.units)
    local d, u = self.d, self.units
    local fg = self.earned and UI.C.paper or UI.C.mid
    self.parts = {}
    if self.icon then
        local t = TextWidget:new{
            text = util.unicodeCodepointToUtf8(self.icon),
            face = Font:getFace("nerdfonts/symbols.ttf", floor(u * 0.40)),
            fgcolor = fg, padding = 0,
        }
        self.parts[1] = t
    else
        self.parts[1] = fitText(self.num or "", "serif_bold", floor(u * 0.36), floor(d * 0.70), fg)
        if self.cap then
            self.parts[2] = fitText(self.cap, "sans", max(7, floor(u * 0.15)), floor(d * 0.70), fg)
        end
    end
end

function Medallion:getSize()
    return Geom:new{ w = self.d, h = self.d }
end

function Medallion:paintTo(bb, x, y)
    local d = self.d
    self.dimen = Geom:new{ x = x, y = y, w = d, h = d }
    if self.earned then
        bb:colorblitFrom(disc(d), x, y, 0, 0, d, d, UI.C.ink)
        local inset = max(3, floor(d * 0.07))
        local inner = d - 2 * inset
        bb:colorblitFrom(ring(inner, max(1, UI.px(1)), 1), x + inset, y + inset, 0, 0, inner, inner, UI.C.paper)
    else
        bb:colorblitFrom(ring(d, max(2, UI.px(2)), 1), x, y, 0, 0, d, d, UI.C.line)
        if self.progress > 0.02 then
            local frac = floor(self.progress * 50 + 0.5) / 50 -- a few dozen masks at most
            bb:colorblitFrom(ring(d, max(3, UI.px(4)), frac), x, y, 0, 0, d, d, UI.C.text2)
        end
    end
    local a, b = self.parts[1], self.parts[2]
    local ah = a:getSize().h
    local bh = b and b:getSize().h or 0
    -- Number and caption overlap a little: font boxes carry generous line gaps.
    local overlap = b and floor(bh * 0.30) or 0
    local top = y + floor((d - (ah + bh - overlap)) / 2)
    if self.icon then top = top + floor(d * 0.02) end
    a:paintTo(bb, x + floor((d - a:getSize().w) / 2), top)
    if b then
        b:paintTo(bb, x + floor((d - b:getSize().w) / 2), top + ah - overlap)
    end
end

function Medallion:free()
    for _, t in ipairs(self.parts or {}) do t:free() end
    self.parts = {}
end

function Art.medallion(o)
    return Medallion:new(o)
end

-- Rubber stamps ------------------------------------------------------------------------

local function xorshift(seed)
    local h = bit.tobit(seed ~= 0 and seed or 0x2545F491)
    return function()
        h = bit.bxor(h, bit.lshift(h, 13))
        h = bit.bxor(h, bit.rshift(h, 17))
        h = bit.bxor(h, bit.lshift(h, 5))
        return bit.band(h, 0xFFFF) / 65536
    end
end

-- A stable small number from a string (for each book's own tilt and ink).
function Art.seed(s)
    local h = 5381
    for i = 1, #s do
        h = bit.tobit(bit.bxor(h * 33, s:byte(i)))
    end
    return h
end

-- lines: { "ПРОЧИТАНО", "08.03.2026" }; o: { size = font units, angle = degrees, seed = n,
-- big = true for the large stamp at the end of a book (as in its mockup): crisp ink,
-- rounded corners, the thick line inside and the thin one around it, letters set apart }
local boxes = {} -- key -> the stamp's size before the tilt: { w, h, frame }

local function stampMask(lines, o)
    local key = string.format("stamp%s:%d:%d:%d:%s", table.concat(lines, "|"), o.size, o.angle, o.seed, o.big and "b" or "")
    if cached(key) then return cache[key], boxes[key] end
    local WHITE = Blitbuffer.Color8(255)
    local pad_x, pad_top, pad_bottom = UI.px(8), UI.px(2), UI.px(2)
    local bw1, gap, bw2 = max(2, UI.px(2)), max(2, UI.px(2)), max(1, UI.px(1))
    local spacing, line_gap = {}, 0
    if o.big then
        pad_x, pad_top, pad_bottom = UI.px(26), UI.px(10), UI.px(8)
        bw1, gap, bw2 = max(1, UI.px(1.5)), max(2, UI.px(3)), max(2, UI.px(3))
        spacing, line_gap = { 0.16, 0.08 }, UI.px(2)
    end
    local frame = bw1 + gap + bw2
    local texts, tw, th = {}, 0, 0
    for i, line in ipairs(lines) do
        local size = i == 1 and o.size or max(7, floor(o.size * (o.big and 0.5 or 0.86)))
        local face = UI.face("sans_bold", size)
        local sp = spacing[i] and floor(UI.px(size) * spacing[i] + 0.5) or 0
        local glyphs, w, h = {}, 0, 0
        local chunks = { line }
        if sp > 0 then
            chunks = {}
            for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chunks[#chunks + 1] = ch end
        end
        for _, ch in ipairs(chunks) do
            local t = TextWidget:new{ text = ch, padding = 0, fgcolor = WHITE, face = face }
            local sz = t:getSize()
            if #glyphs > 0 then w = w + sp end
            glyphs[#glyphs + 1] = { t = t, w = sz.w }
            w, h = w + sz.w, max(h, sz.h)
        end
        texts[i] = { glyphs = glyphs, w = w, h = h, sp = sp }
        tw, th = max(tw, w), th + h + (i > 1 and line_gap or 0)
    end
    local sw = tw + 2 * (pad_x + frame)
    local sh = th + 2 * frame + pad_top + pad_bottom
    -- One transparent pixel around the stamp spares bounds checks below.
    local src, sp, ss = newMask(sw + 2, sh + 2)
    local function rect(x, y, w, h) src:paintRect(x + 1, y + 1, w, h, WHITE) end
    local function box(off, bw)
        rect(off, off, sw - 2 * off, bw)
        rect(off, sh - off - bw, sw - 2 * off, bw)
        rect(off, off, bw, sh - 2 * off)
        rect(sw - off - bw, off, bw, sh - 2 * off)
    end
    if o.big then
        local r2 = UI.px(6)
        src:paintBorder(1, 1, sw, sh, bw1, WHITE, r2 + gap + bw1)
        src:paintBorder(1 + bw1 + gap, 1 + bw1 + gap, sw - 2 * (bw1 + gap), sh - 2 * (bw1 + gap), bw2, WHITE, r2)
    else
        box(0, bw1)
        box(bw1 + gap, bw2)
    end
    local ty = frame + pad_top
    for i, e in ipairs(texts) do
        if i > 1 then ty = ty + line_gap end
        local x = floor((sw - e.w) / 2)
        for _, g in ipairs(e.glyphs) do
            g.t:paintTo(src, x + 1, ty + 1)
            x = x + g.w + e.sp
            g.t:free()
        end
        ty = ty + e.h
    end

    -- Tilt (bilinear sampling) and uneven ink: soft blotches, grain and a
    -- pressure gradient across the stamp.
    local rad = math.rad(o.angle)
    local ca, sa = math.cos(rad), math.sin(rad)
    local rw = math.ceil(math.abs(sw * ca) + math.abs(sh * sa)) + 2
    local rh = math.ceil(math.abs(sw * sa) + math.abs(sh * ca)) + 2
    local dst, dp, ds = newMask(rw, rh)
    local rnd = xorshift(o.seed)
    local cell = max(5, UI.px(8))
    local gw, gh = math.ceil(rw / cell) + 2, math.ceil(rh / cell) + 2
    local grid = {}
    for i = 0, gw * gh - 1 do grid[i] = rnd() end
    local grain = {}
    for i = 0, 250 do grain[i] = 0.82 + 0.18 * rnd() end
    local gdx, gdy = rnd() - 0.5, rnd() - 0.5 -- direction of the pressure gradient
    local glen = sqrt(gdx * gdx + gdy * gdy) + 1e-6
    local half = max(rw, rh) / 2
    gdx, gdy = gdx / glen / half, gdy / glen / half
    local cxs, cys, cxd, cyd = sw / 2 + 0.5, sh / 2 + 0.5, rw / 2, rh / 2 -- +1 margin, -0.5 pixel centers
    local inv_cell = 1 / cell
    for oy = 0, rh - 1 do
        local dy = oy + 0.5 - cyd
        local base_x, base_y = sa * dy + cxs, ca * dy + cys
        local gy = oy * inv_cell
        local iy = floor(gy)
        local ty2 = gy - iy
        local row = iy * gw
        for ox = 0, rw - 1 do
            local dx = ox + 0.5 - cxd
            local sx = ca * dx + base_x
            local sy = -sa * dx + base_y
            local x0, y0 = floor(sx), floor(sy)
            if x0 >= 0 and y0 >= 0 and x0 <= sw and y0 <= sh then
                local fx, fy = sx - x0, sy - y0
                local i0 = y0 * ss + x0
                local v = (sp[i0] * (1 - fx) + sp[i0 + 1] * fx) * (1 - fy)
                        + (sp[i0 + ss] * (1 - fx) + sp[i0 + ss + 1] * fx) * fy
                if v > 0 and o.big then
                    dp[oy * ds + ox] = v >= 255 and 255 or floor(v)
                elseif v > 0 then
                    local gx = ox * inv_cell
                    local ix = floor(gx)
                    local tx = gx - ix
                    local i1 = row + ix
                    local n = (grid[i1] * (1 - tx) + grid[i1 + 1] * tx) * (1 - ty2)
                            + (grid[i1 + gw] * (1 - tx) + grid[i1 + gw + 1] * tx) * ty2
                    local pressure = 0.86 + 0.14 * (dx * gdx + dy * gdy)
                    v = v * (0.42 + 0.58 * n * n) * pressure * grain[(ox * 31 + oy * 17) % 251] * 1.25
                    if v > 0 then dp[oy * ds + ox] = v >= 255 and 255 or floor(v) end
                end
            end
        end
    end
    src:free()
    boxes[key] = { w = sw, h = sh, frame = bw1 + gap }
    return remember(key, dst), boxes[key]
end

local Stamp = Widget:extend{
    lines = nil,
    size = 12,
    angle = -4,
    seed = 1,
    color = nil,
    big = false,
}

function Stamp:init()
    local box
    self.mask, box = stampMask(self.lines, { size = self.size, angle = self.angle, seed = self.seed, big = self.big })
    self.w, self.h = self.mask:getWidth(), self.mask:getHeight()
    -- before the tilt, without the thin line around it (what a page lays out)
    self.box_h = box and (box.h - 2 * box.frame) or self.h
end

function Stamp:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function Stamp:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    bb:colorblitFrom(self.mask, x, y, 0, 0, self.w, self.h, self.color or UI.C.ink)
end

-- A stamp; the same seed always gives the same tilt and ink.
function Art.stamp(lines, o)
    o = o or {}
    local seed = o.seed or Art.seed(table.concat(lines))
    local angle = o.angle
    if not angle then
        -- 2..7 degrees, mostly tilted to the left, the way a right hand stamps.
        local spread = o.spread or 6
        angle = 2 + seed % spread
        if seed % 10 < 7 then angle = -angle end
    end
    return Stamp:new{ lines = lines, size = o.size or 12, angle = angle, seed = seed, color = o.color, big = o.big }
end

return Art
