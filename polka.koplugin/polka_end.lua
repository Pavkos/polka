-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the end of a book.

Instead of KOReader's «Вы достигли конца документа. Что требуется сделать
теперь?» — a page of its own: the «ПРОЧИТАНО» stamp (the book is marked as
read at once, with today's date, the way it goes into the формуляр; one tap
takes it back), how long the book took (time in it, days since its first
page, from the statistics), where the year's goal stands, and what to read
next: the next unread book in the same folder, with «Открыть». «В книгу»
goes back to the last page, «В библиотеку» to the shelves.
]]

local BookList = require("ui/widget/booklist")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local Art = require("polka_art")
local Books = require("polka_books")
local Covers = require("polka_covers")
local Icons = require("polka_icons")
local UI = require("polka_ui")

local End = InputContainer:extend{
    name = "polka_end",
    covers_fullscreen = true,
    plugin = nil,
}

-- Facts -----------------------------------------------------------------------------

-- Time spent in this book and when its first page was read (statistics).
local function bookTime(ui)
    local st = ui.statistics
    if not (st and st.settings and st.settings.is_enabled and st.id_curr_book) then return nil end
    pcall(st.insertDB, st) -- this session's pages too
    local DataStorage = require("datastorage")
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db, "mode") ~= "file" then return nil end
    local ok, secs, first = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db, "ro")
        local s, f = conn:rowexec(string.format(
            "SELECT coalesce(sum(duration), 0), min(start_time) FROM page_stat_data WHERE id_book = %d", tonumber(st.id_curr_book)))
        conn:close()
        return tonumber(s), tonumber(f)
    end)
    if not ok then
        logger.warn("Polka: end of book: statistics:", secs)
        return nil
    end
    return secs, first
end

local function midnight(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 12, 0, 0
    return os.time(d)
end

local function daysSince(first)
    if not first then return nil end
    return math.max(1, math.floor((midnight(os.time()) - midnight(first)) / 86400 + 0.5))
end

-- Books finished this year, counting this one as it is marked now.
local function yearCount(path, marked)
    if not Books.hist then pcall(Books.loadHistory, Books) end
    local n, year = 0, tonumber(os.date("%Y"))
    local ok = pcall(function()
        for _, f in ipairs(Books:finished()) do
            if f.path ~= path and f.info.year == year then n = n + 1 end
        end
    end)
    if not ok then return nil end
    return n + (marked and 1 or 0)
end

-- The next book in the same folder that is not read yet (after this one, by name).
local function nextBook(path)
    local dir, name = util.splitFilePathName(path)
    dir = dir:gsub("/$", "")
    local names = {}
    local ok = pcall(function()
        for entry in lfs.dir(dir) do
            if entry:sub(1, 1) ~= "." and Books.isBookName(entry) and lfs.attributes(dir .. "/" .. entry, "mode") == "file" then
                names[#names + 1] = entry
            end
        end
    end)
    if not ok or #names < 2 then return nil end
    table.sort(names, function(a, b) return Books.sortKey(a) < Books.sortKey(b) end)
    local at = 1
    for i, n in ipairs(names) do
        if n == name then at = i end
    end
    if not Books.meta then pcall(Books.loadMeta, Books) end
    for k = 1, #names - 1 do
        local candidate = names[(at - 1 + k) % #names + 1]
        local p = dir .. "/" .. candidate
        local status, percent = "new", nil
        local okb, bi = pcall(BookList.getBookInfo, p)
        if okb and bi and bi.been_opened then
            status, percent = bi.status or "reading", bi.percent_finished
        end
        if status ~= "complete" then
            local rec = Books:brief(Books:record(p))
            rec.status, rec.percent = status, percent
            return rec
        end
    end
end

-- «Дальше на полке «Классика»», or in the books folder itself, or in another folder.
local function nextHeading(path)
    local root = (Books.root or Books.getRoot()):gsub("/+$", "")
    local rel = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or nil
    local shelf = rel and rel:match("^([^/]+)/")
    if shelf then return string.format("Дальше на полке «%s»", shelf) end
    if rel then return "Дальше в библиотеке" end
    local dir = util.splitFilePathName(path):gsub("/$", "")
    return string.format("Дальше в папке «%s»", dir:match("([^/]+)$") or dir)
end

local function upper(s)
    local ok, u = pcall(function() return require("ffi/utf8proc").uppercase_dumb(s) end)
    return ok and type(u) == "string" and u or s
end

-- "ВиМ": the initials of a title, for a book without a cover (short words small).
local function initials(title)
    local out = {}
    for word in tostring(title or ""):gmatch("[^%s%p]+") do
        local ch = word:match("^[%z\1-\127\194-\244][\128-\191]*")
        local letters = #word:gsub("[\128-\191]", "")
        if ch then out[#out + 1] = (#out == 0 or letters > 2) and upper(ch) or ch end
        if #out >= 3 then break end
    end
    return table.concat(out)
end

-- The screen ----------------------------------------------------------------------------

function End:init()
    self.ui = self.plugin.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        AnyTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        AnySwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        AnyHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local ui = self.ui
    self.path = ui.document.file
    local props = ui.doc_props or {}
    self.title = Books.tidy(props.display_title or props.title)
    if not self.title or self.title == "" then
        self.title = Books:brief(Books:record(self.path)).title
    end
    self.authors = type(props.authors) == "string" and Books.tidyAuthors(props.authors):gsub("\n", ", ") or nil
    -- the stamp goes on now; an already finished book keeps its day
    local summary = ui.doc_settings:readSetting("summary") or {}
    self.before = { status = summary.status, modified = summary.modified }
    if summary.status ~= "complete" then
        self:mark()
    else
        self.marked = true
    end
    self.secs, self.first = bookTime(ui)
    self.next = nextBook(self.path)
    self:build()
end

function End:mark()
    local ui = self.ui
    ui.status:markBook(true)
    self.marked = true
    Books:invalidate(self.path)
end

function End:unmark()
    local ui = self.ui
    local summary = ui.doc_settings:readSetting("summary") or {}
    summary.status = (self.before.status and self.before.status ~= "complete") and self.before.status or "reading"
    summary.modified = self.before.modified or os.date("%Y-%m-%d")
    ui.doc_settings:saveSetting("summary", summary)
    BookList.setBookInfoCacheProperty(self.path, "status", summary.status)
    self.marked = false
    Books:invalidate(self.path)
end

local function button(text, filled, w, h, cb, size)
    local border = math.max(2, UI.px(2))
    local label = UI.text{ text = text, size = size or 17, family = "sans_bold",
                           color = filled and UI.C.paper or UI.C.ink }
    w = w or (label:getSize().w + 2 * UI.px(20) + 2 * border)
    return UI.tap(UI.FrameContainer:new{
        bordersize = border, color = UI.C.ink, background = filled and UI.C.ink or UI.C.paper,
        radius = UI.px(10), padding = 0, margin = 0, width = w, height = h,
        UI.center(w - 2 * border, h - 2 * border, label),
    }, cb)
end

local function stat(value, caption, w)
    return UI.center(w, nil, VerticalGroup:new{
        align = "center",
        UI.text{ text = value, family = "serif_bold", size = 24, max_width = w - UI.px(8) },
        UI.vgap(UI.px(2)),
        UI.text{ text = caption, size = 14, color = UI.C.text2, max_width = w - UI.px(8) },
    })
end

-- The stamp, the book and its numbers, centred in width cw (stamp area W wide).
function End:topBlock(W, cw)
    local vg = VerticalGroup:new{ align = "center" }
    local function add(w) table.insert(vg, w) end
    -- the stamp, tilted a little to the left; the page keeps its place when it is taken off
    local date = os.date("%d.%m.%Y")
    local summary = self.ui.doc_settings:readSetting("summary") or {}
    local y, m, d = tostring(summary.modified or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if y then date = string.format("%s.%s.%s", d, m, y) end
    local stamp = Art.stamp({ "ПРОЧИТАНО", date }, { size = 32, angle = -5, big = true, seed = Art.seed(self.path) })
    local box_h = stamp.box_h
    add(UI.OverlapGroup:new{
        dimen = Geom:new{ w = W, h = box_h },
        self.marked and UI.center(W, box_h, stamp) or UI.vgap(box_h),
    })
    add(UI.vgap(UI.px(22 + 10)))
    add(UI.para{ text = self.title or "", family = "serif_bold", size = 34, width = cw, align = "center",
                 max_lines = 3, line_height = 0.15 })
    if self.authors and self.authors ~= "" then
        add(UI.vgap(UI.px(10)))
        add(UI.text{ text = self.authors, size = 17, color = UI.C.text2, max_width = cw })
    end
    add(UI.vgap(UI.px(10 + 22)))

    -- time in the book · days since its first page · the year's goal
    local col = math.floor(cw / 3)
    local goal = tonumber(G_reader_settings:readSetting("polka_goal")) or 24
    local done = yearCount(self.path, self.marked)
    local days = daysSince(self.first)
    local row = HorizontalGroup:new{
        align = "top",
        stat(self.secs and self.secs >= 60 and UI.duration(self.secs) or "—", "в книге", col),
        stat(days and string.format("%d %s", days, UI.plural(days, "день", "дня", "дней")) or "—", "с первой страницы", col),
        stat(done and string.format("%d из %d", done, goal) or "—", "цель на год", cw - 2 * col),
    }
    add(UI.hline(cw))
    add(UI.vgap(UI.px(18)))
    add(row)
    add(UI.vgap(UI.px(18)))
    add(UI.hline(cw))
    add(UI.vgap(UI.px(10)))
    -- «Штамп уже в формуляре · Отменить»
    local quiet = self.marked and "Штамп уже в формуляре · " or "Штамп снят · "
    local action = self.marked and "Отменить" or "Вернуть"
    local link = UI.text{ text = action, size = 14.5, family = "sans_bold" }
    local lw = link:getSize().w
    local underlined = VerticalGroup:new{ align = "left", link, UI.hline(lw, UI.C.ink, math.max(1, UI.px(1))) }
    add(UI.tap(HorizontalGroup:new{
        align = "top",
        UI.text{ text = quiet, size = 14.5, color = UI.C.text2 },
        underlined,
    }, function() self:toggleStamp() end))
    return vg
end

-- What to read next, and the shelves, bw wide.
function End:bottomBlock(bw)
    local bottom = VerticalGroup:new{ align = "left" }
    if self.next then
        table.insert(bottom, UI.text{ text = nextHeading(self.next.path), size = 14, family = "sans_bold", max_width = bw })
        table.insert(bottom, UI.vgap(UI.px(14)))
        local cover_w, cover_h = UI.px(50), UI.px(72)
        local cover
        if self.next.has_cover and Books:cover(self.next.path, cover_w - 2, cover_h - 2) then
            cover = Covers.widget(self.next, cover_w, cover_h)
        else
            local border = math.max(1, UI.px(1.5))
            cover = UI.FrameContainer:new{
                bordersize = border, color = UI.C.ink, background = UI.C.tint, radius = UI.px(3),
                padding = 0, margin = 0, width = cover_w, height = cover_h,
                VerticalGroup:new{
                    align = "center",
                    UI.vgap(cover_h - 2 * border - UI.px(20)),
                    UI.center(cover_w - 2 * border, UI.px(14), UI.text{ text = initials(self.next.title), family = "serif_bold",
                        size = 9, max_width = cover_w - 2 * border - UI.px(4), color = UI.C.ink }),
                },
            }
        end
        local open = button("Открыть", true, nil, UI.px(44), function() self:openNext() end, 16)
        local text_w = bw - cover_w - UI.px(16) - open:getSize().w - UI.px(16)
        local state
        if self.next.status == "reading" and self.next.percent and self.next.percent > 0 then
            state = string.format("%d %%", math.floor(self.next.percent * 100 + 0.5))
        else
            state = "не начата"
        end
        local who = (self.next.authors and self.next.authors ~= "") and (self.next.authors .. " · " .. state) or state
        local texts = VerticalGroup:new{
            align = "left",
            UI.text{ text = self.next.title or self.next.name, family = "serif_bold", size = 20, max_width = text_w },
            UI.vgap(UI.px(2)),
            UI.text{ text = who, size = 14.5, color = UI.C.text2, max_width = text_w },
        }
        local left = HorizontalGroup:new{ align = "center", cover, UI.hgap(UI.px(16)), texts }
        table.insert(bottom, UI.split(bw, left, open, math.max(cover_h, open:getSize().h)))
        table.insert(bottom, UI.vgap(UI.px(18)))
        table.insert(bottom, UI.hline(bw))
        table.insert(bottom, UI.vgap(UI.px(14)))
    end
    table.insert(bottom, button("В библиотеку", false, bw, UI.px(50), function() self:toLibrary() end))
    return bottom
end

function End:build()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    local W, H = self.dimen.w, self.dimen.h
    local head = VerticalGroup:new{ align = "left" }
    table.insert(head, UI.pad(UI.statusRow(W - 2 * UI.px(18)), { left = UI.px(18), right = UI.px(18), top = UI.px(4) }))
    -- ‹ В книгу
    local back = UI.tap(UI.pad(HorizontalGroup:new{
        align = "center",
        Icons.widget("chev_left", UI.px(22), { stroke = math.max(2, UI.px(2)) }),
        UI.hgap(UI.px(4)),
        UI.text{ text = "В книгу", size = 16 },
    }, { left = UI.px(14), right = UI.px(24), top = UI.px(8), bottom = UI.px(8) }), function() self:close() end)
    table.insert(head, UI.left(W, back))
    local head_h = head:getSize().h
    local M = UI.px(32)
    local top_gap, bottom_pad = UI.px(26 + 6), UI.px(30)

    local top = self:topBlock(W, W - 2 * UI.px(40))
    local bottom = self:bottomBlock(W - 2 * M)
    local stacked = head_h + top_gap + top:getSize().h + UI.px(16) + bottom:getSize().h + bottom_pad
    local vg = VerticalGroup:new{ align = "center", head }
    if stacked <= H then
        -- as in the mockup: the book at the top, what is next at the bottom
        table.insert(vg, UI.vgap(top_gap))
        table.insert(vg, top)
        table.insert(vg, UI.vgap(H - stacked + UI.px(16)))
        table.insert(vg, UI.pad(bottom, { left = M, right = M }))
    else
        -- too low a screen (turned on its side): the book on the left, what is next on the right
        top:free()
        bottom:free()
        local lw = math.floor(W * 0.56)
        local rw = W - lw
        top = self:topBlock(lw, lw - 2 * UI.px(32))
        bottom = self:bottomBlock(rw - 2 * M)
        local room = H - head_h
        local th, bh = top:getSize().h, bottom:getSize().h
        table.insert(vg, HorizontalGroup:new{
            align = "top",
            UI.pad(top, { top = math.max(UI.px(12), math.floor((room - th) / 2)) }),
            UI.pad(bottom, { left = M, right = M, top = math.max(0, math.floor((room - bh) / 2)) }),
        })
    end
    self[1] = UI.FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.C.paper, width = W, height = H,
        vg,
    }
end

function End:toggleStamp()
    if self.marked then self:unmark() else self:mark() end
    self:build()
    UIManager:setDirty(self, "ui")
end

function End:close()
    UIManager:close(self, "full")
end

function End:toLibrary()
    local plugin = self.plugin
    self:close()
    UIManager:nextTick(function() plugin:onPolkaShow("library") end)
end

function End:openNext()
    local ui, path = self.ui, self.next and self.next.path
    if not path then return end
    self:close()
    UIManager:nextTick(function()
        if ui.document then require("apps/filemanager/filemanagerutil").openFile(ui, path) end
    end)
end

-- Taps between the buttons, swipes and holds stay here.
function End:onAnyTap() return true end
function End:onAnySwipe() return true end
function End:onAnyHold() return true end

function End:onCloseWidget()
    if self.plugin and self.plugin._end == self then self.plugin._end = nil end
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
end

function End:onSetDimensions()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:build()
    UIManager:setDirty(self, "full")
end

local M = {}

function M.show(plugin)
    if plugin._end then return end
    local w = End:new{ plugin = plugin }
    plugin._end = w
    UIManager:show(w, "full")
end

M.End = End

return M
