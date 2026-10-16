-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the place in a book, across the readers of one card.

When a book is closed after reading, Polka notes where the reader stopped,
in forms both kinds of readers understand: percent, the EPUB spine item
(0-based) and how far into it (frac), and KOReader's own xpointer. The next
sync sends these and brings back the places the card's other readers
(another Kindle, an Xteink) reached since. When a book is opened and another
reader got further in it later than this Kindle did, a small sheet offers to
go there: «Продолжить с места на Xteink?» — «Перейти» / «Остаться».

Everything lives in settings/polka_places.lua (written only here, in
KOReader itself; the sync process reads it):
  mine      book id -> the last place here { t, percent, spine, frac, xp }
  pending   book id -> true: not sent yet
  remote    book id -> the newest place from another reader
  declined  book id -> the time of a place the reader chose to ignore
Book ids are KOReader's partial MD5 of the file, the same on every reader.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Places = {
    FILE = DataStorage:getSettingsDir() .. "/polka_places.lua",
}

local store = nil

local function open()
    if not store then store = LuaSettings:open(Places.FILE) end
    return store
end

local function tbl(key)
    local s = open()
    local t = s:readSetting(key)
    if type(t) ~= "table" then
        t = {}
        s:saveSetting(key, t)
    end
    return t
end

local function flush()
    if store then pcall(store.flush, store) end
end

function Places.bookId(ui)
    local id = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    if type(id) ~= "string" or id == "" then
        id = ui.document and util.partialMD5(ui.document.file)
    end
    return id
end

-- Geometry of the book -------------------------------------------------------------

-- Where spine item n (1-based, crengine's DocFragment[n]) starts and ends,
-- in document pixels and in pages.
local function fragment(doc, n)
    local xs = string.format("/body/DocFragment[%d]", n)
    local xe = string.format("/body/DocFragment[%d]", n + 1)
    local ok, res = pcall(function()
        if doc.isXPointerInDocument and not doc:isXPointerInDocument(xs) then return nil end
        local f = {
            pos0 = doc:getPosFromXPointer(xs),
            page0 = doc:getPageFromXPointer(xs),
        }
        if not doc.isXPointerInDocument or doc:isXPointerInDocument(xe) then
            local okn, pos1 = pcall(doc.getPosFromXPointer, doc, xe)
            if okn and pos1 and pos1 > f.pos0 then
                f.pos1 = pos1
                f.page1 = doc:getPageFromXPointer(xe)
            end
        end
        f.pos1 = f.pos1 or doc.info.doc_height
        f.page1 = f.page1 or (doc:getPageCount() + 1)
        return f
    end)
    if ok then return res end
end

--- Where the reader is now: { percent, spine, frac, xp, page, pages }.
function Places.here(ui)
    local doc = ui.document
    if not doc then return nil end
    local p = {}
    local ok, err = pcall(function()
        if ui.rolling then
            p.xp = ui.rolling:getBookLocation() or doc:getXPointer()
            p.percent = ui.rolling:getLastPercent()
            p.page = ui.rolling.current_page or doc:getCurrentPage()
            p.pages = doc:getPageCount()
            local n = type(p.xp) == "string" and tonumber(p.xp:match("^/body/DocFragment%[(%d+)%]"))
            if n then
                local f = fragment(doc, n)
                local cur = doc:getPosFromXPointer(p.xp)
                if f and cur and f.pos1 > f.pos0 then
                    p.spine = n - 1
                    p.frac = math.max(0, math.min(1, (cur - f.pos0) / (f.pos1 - f.pos0)))
                end
            end
        elseif ui.paging then
            p.percent = ui.paging:getLastPercent()
            p.page = ui.paging.current_page
            p.pages = doc:getPageCount()
        end
    end)
    if not ok then logger.warn("Polka places: here:", err) end
    if not p.percent then return nil end
    p.percent = math.max(0, math.min(1, p.percent))
    if not p.spine then p.spine, p.frac = 0, p.percent end
    return p
end

-- The page a place from another reader means in this book.
local function targetPage(ui, r)
    local doc = ui.document
    local pages = doc:getPageCount()
    if ui.rolling and r.spine and r.frac and r.spine >= 0 then
        local f = fragment(doc, r.spine + 1)
        if f and f.page1 > f.page0 then
            return math.max(1, math.min(pages, f.page0 + math.floor(r.frac * (f.page1 - f.page0))))
        end
    end
    return math.max(1, math.min(pages, math.floor((r.percent or 0) * pages + 0.5)))
end

-- Recording ------------------------------------------------------------------------

--- The book has just been opened: remember where it opened, and since when
-- this Kindle had been there (the book's settings were last written then).
function Places.opened(ui)
    ui._polka_place = {
        start = Places.here(ui),
        since = 0,
    }
    local ok, sidecar = pcall(DocSettings.findSidecarFile, DocSettings, ui.document.file)
    if ok and sidecar then
        ui._polka_place.since = lfs.attributes(sidecar, "modification") or 0
    end
end

--- The book is being closed: if the reader moved, that is the new place here.
function Places.record(ui)
    local info = ui._polka_place
    local here = Places.here(ui)
    if not here then return end
    local moved = true
    local start = info and (info.jumped or info.start)
    if start and start.xp and here.xp then
        moved = start.xp ~= here.xp
    elseif start then
        moved = math.abs((start.percent or 0) - here.percent) > 0.0005
    end
    if not moved then return end
    local id = Places.bookId(ui)
    if not id then return end
    tbl("mine")[id] = {
        t = os.time(), percent = here.percent, spine = here.spine, frac = here.frac, xp = here.xp,
    }
    tbl("pending")[id] = true
    flush()
end

--- What a finished sync brought (polka_web): sent places stop being pending,
-- places of the other readers are kept (the newest per book).
function Places.merge(last)
    if type(last) ~= "table" then return end
    local changed = false
    local mine, pending, remote = tbl("mine"), tbl("pending"), tbl("remote")
    if type(last.positions_sent) == "table" then
        for id, t in pairs(last.positions_sent) do
            local m = mine[id]
            if pending[id] and (not m or (tonumber(m.t) or 0) <= (tonumber(t) or 0)) then
                pending[id] = nil
                changed = true
            end
        end
    end
    if type(last.positions) == "table" then
        for _, p in ipairs(last.positions) do
            if type(p) == "table" and type(p.id) == "string" and tonumber(p.t) then
                local cur = remote[p.id]
                if not cur or (tonumber(cur.t) or 0) < p.t then
                    remote[p.id] = p
                    changed = true
                end
            end
        end
    end
    if changed then flush() end
end

--- A new card, or none: the other readers' places no longer apply.
function Places.reset()
    local s = open()
    s:saveSetting("remote", {})
    s:saveSetting("declined", {})
    s:flush()
end

-- Offering a newer place ------------------------------------------------------------

local function readerName(kind)
    if kind == "xteink" then return "Xteink" end
    if kind == "kindle" then return "другом Kindle" end
    return "другой читалке"
end

local function pct(p)
    return string.format("%d %%", math.floor((p or 0) * 100 + 0.5))
end

--- Goes to a place from another reader (the place here stays reachable with "back").
function Places.go(ui, r)
    local doc = ui.document
    if not doc then return end
    if ui.link and ui.link.addCurrentLocationToStack then ui.link:addCurrentLocationToStack() end
    local done = false
    if ui.rolling then
        if r.kind == "kindle" and type(r.xp) == "string" and r.xp ~= ""
                and (not doc.isXPointerInDocument or doc:isXPointerInDocument(r.xp)) then
            ui:handleEvent(Event:new("GotoXPointer", r.xp))
            done = true
        elseif r.spine and r.frac then
            local f = fragment(doc, r.spine + 1)
            if f then
                if ui.view and ui.view.view_mode ~= "page" and ui.rolling._gotoPos then
                    ui.rolling:_gotoPos(math.floor(f.pos0 + r.frac * (f.pos1 - f.pos0)))
                    ui.rolling.xpointer = doc:getXPointer()
                else
                    local page = math.max(1, f.page0 + math.floor(r.frac * (f.page1 - f.page0)))
                    ui:handleEvent(Event:new("GotoPage", math.min(page, doc:getPageCount())))
                end
                done = true
            end
        end
        if not done and r.percent then
            ui:handleEvent(Event:new("GotoPercent", r.percent * 100))
            done = true
        end
    elseif ui.paging and r.percent then
        local pages = doc:getPageCount()
        ui:handleEvent(Event:new("GotoPage", math.max(1, math.min(pages, math.floor(r.percent * pages + 0.5)))))
        done = true
    end
    if done and ui._polka_place then
        -- going there is not reading: the place here changes only once the reader moves on
        ui._polka_place.jumped = Places.here(ui)
    end
end

--- Called once the book is on screen: offers a newer place from another reader.
function Places.offer(ui)
    local Web = require("polka_web")
    if not Web.configured() or not ui.document then return end
    local id = Places.bookId(ui)
    local r = id and tbl("remote")[id]
    if type(r) ~= "table" or not tonumber(r.t) then return end
    local declined = tonumber(tbl("declined")[id])
    if declined and declined >= r.t then return end
    local mine = tbl("mine")[id]
    local info = ui._polka_place or {}
    local local_t = math.max(mine and tonumber(mine.t) or 0, info.since or 0)
    if r.t <= local_t + 30 then return end
    local here = Places.here(ui)
    -- where that is in this book, as this Kindle lays it out
    local page = targetPage(ui, r)
    local pages = ui.document:getPageCount()
    local there = (pages and pages > 0) and page / pages or (r.percent or 0)
    if here and (math.abs(here.percent - there) < 0.003 or (here.page and here.page == page)) then return end
    local Sheet = require("polka_sheet")
    local function decline()
        tbl("declined")[id] = r.t
        flush()
    end
    Sheet:new{
        title = "Продолжить с места на " .. readerName(r.kind) .. "?",
        body = string.format("Там — %s, стр. %d. Здесь — %s.", pct(there), page, here and pct(here.percent) or "начало"),
        buttons = {
            { text = "Перейти", primary = true, callback = function()
                decline() -- asked and answered
                require("polka_ui").safely(Places.go, ui, r)
            end },
            { text = "Остаться", callback = decline },
        },
        on_dismiss = decline,
    }:show()
end

return Places
