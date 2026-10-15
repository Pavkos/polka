--[[--
Polka: the shell.

A full-screen widget shown on top of KOReader's file manager: a status line,
tabs (Главная · Библиотека · Статистика), search and settings. Opening a
book closes it; closing the book brings it back.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local Books = require("polka_books")
local UI = require("polka_ui")
local Home = require("polka_home")
local Library = require("polka_library")
local StatsPage = require("polka_statspage")
local SettingsPage = require("polka_settingspage")
local Tools = require("polka_tools")

local Shell = InputContainer:extend{
    name = "polka_shell",
    covers_fullscreen = true,
    tab = "home",
    plugin = nil,
}

Shell.TABS = {
    { id = "home", label = "Главная" },
    { id = "library", label = "Библиотека" },
    { id = "stats", label = "Статистика" },
    { id = "tools", label = "Инструменты" },
}

-- Статистика has views of its own: overview, card (формуляр), badges.
Shell.stats_view = "overview"

function Shell:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        PolkaSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.lib = {
        shelf = "*",
        sort = G_reader_settings:readSetting("polka_sort") or "recent",
        page = 1,
        query = nil,
    }
    Books:scan()
    self:build()
end

-- Layout --------------------------------------------------------------------

function Shell:margin()
    return UI.px(18)
end

function Shell:statusWidget()
    local W = self.dimen.w
    local M = self:margin()
    return UI.pad(UI.statusRow(W - 2 * M), { left = M, right = M, top = UI.px(4) })
end

function Shell:tabsWidget()
    local W = self.dimen.w
    local M = self:margin()
    local tabs = HorizontalGroup:new{ align = "top" }
    local underline_h = UI.px(3)
    for _, t in ipairs(Shell.TABS) do
        local active = self.tab == t.id
        local label = UI.text{
            text = t.label,
            family = active and "sans_bold" or "sans",
            size = 17,
            color = active and UI.C.ink or UI.C.text2,
        }
        local lw = label:getSize().w
        local col = VerticalGroup:new{
            align = "left",
            UI.vgap(UI.px(8)),
            label,
            UI.vgap(UI.px(6)),
            active and UI.hline(lw, UI.C.ink, underline_h) or UI.vgap(underline_h),
        }
        table.insert(tabs, UI.tap(UI.pad(col, { right = UI.px(17) }), function() self:switchTab(t.id) end))
    end
    local icon_size = UI.px(28)
    local function iconButton(icon, active, cb, pad_right)
        local col = VerticalGroup:new{
            align = "center",
            UI.vgap(UI.px(10)),
            IconWidget:new{ icon = icon, width = icon_size, height = icon_size },
            UI.vgap(UI.px(7)),
            active and UI.hline(icon_size + UI.px(10), UI.C.ink, underline_h) or UI.vgap(underline_h),
        }
        return UI.tap(UI.pad(col, { left = UI.px(12), right = pad_right or 0 }), cb)
    end
    local icons = HorizontalGroup:new{
        align = "bottom",
        iconButton("appbar.search", false, function() self:search() end, UI.px(12)),
        iconButton("appbar.settings", self.tab == "settings", function() self:switchTab("settings") end),
    }
    -- Bottom-align both sides so the active underline sits on one line.
    local th, ih = tabs:getSize().h, icons:getSize().h
    if th < ih then
        tabs = VerticalGroup:new{ align = "left", UI.vgap(ih - th), tabs }
    elseif ih < th then
        icons = VerticalGroup:new{ align = "right", UI.vgap(th - ih), icons }
    end
    local h = math.max(th, ih)
    local row = UI.split(W - 2 * M, tabs, icons, h)
    return VerticalGroup:new{
        align = "left",
        UI.pad(row, { left = M, right = M }),
        UI.hline(W, UI.C.line, UI.px(1)),
    }
end

-- KOReader doesn't protect scheduled tasks and event handlers: an error
-- there would take it down. Log it instead.
local function guard(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logger.err("Polka:", label, err) end
    return ok
end

function Shell:buildTree(W, H)
    local status_holder = FrameContainer:new{ bordersize = 0, padding = 0, self:statusWidget() }
    local header = VerticalGroup:new{
        align = "left",
        status_holder,
        self:tabsWidget(),
    }
    local content_h = H - header:getSize().h
    local ok, content = pcall(function()
        if self.tab == "library" then
            return Library.build(self, W, content_h)
        elseif self.tab == "stats" then
            return StatsPage.build(self, W, content_h)
        elseif self.tab == "settings" then
            return SettingsPage.build(self, W, content_h)
        elseif self.tab == "tools" then
            return Tools.build(self, W, content_h)
        end
        return Home.build(self, W, content_h)
    end)
    if not ok then
        logger.err("Polka: failed to build", self.tab, content)
        content = UI.pad(UI.para{ text = "Не получилось показать этот экран.\n\n" .. tostring(content),
                                 width = W - 2 * self:margin(), size = 15, color = UI.C.text2 },
                         { left = self:margin(), right = self:margin(), top = UI.px(24) })
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = W,
        height = H,
        VerticalGroup:new{ align = "left", header, content },
    }, status_holder
end

-- Never leaves the shell without something to paint: the new tree is built
-- first, the old one freed only after.
function Shell:build()
    self:cancelPrefetch()
    local W, H = self.dimen.w, self.dimen.h
    local ok, tree, holder = pcall(self.buildTree, self, W, H)
    if not ok then
        logger.err("Polka: failed to build the shell:", tree)
        tree = FrameContainer:new{
            bordersize = 0, padding = 0, background = Blitbuffer.COLOR_WHITE, width = W, height = H,
            UI.pad(UI.para{ text = "Полка не смогла нарисовать экран. Подробности — в crash.log.",
                            width = W - 2 * self:margin(), size = 16 },
                   { left = self:margin(), right = self:margin(), top = UI.px(40) }),
        }
        holder = nil
    end
    if self[1] then self[1]:free() end
    self[1] = tree
    self.status_holder = holder
end

function Shell:onCoversArrived()
    if self.shown then
        self:build()
        UIManager:setDirty(self, "ui")
    end
end

function Shell:refresh(mode)
    self:build()
    UIManager:setDirty(self, mode or "ui")
    if self._first_flush then return end -- the delayed first flush will pick this up
    guard("cover extraction", Books.flushExtraction, Books, function() self:onCoversArrived() end)
end

-- Lifecycle -------------------------------------------------------------------

function Shell:onShow()
    self.shown = true
    Shell.current = self
    self:scheduleClock()
    -- Let the file manager underneath start its own cover extraction first
    -- (if it uses CoverBrowser); ours waits for it instead of killing it.
    self._first_flush = function()
        self._first_flush = nil
        if not self.shown then return end
        guard("cover extraction", Books.flushExtraction, Books, function() self:onCoversArrived() end)
    end
    UIManager:scheduleIn(3, self._first_flush)
    self:scheduleWarmup()
    UIManager:setDirty(self, "full")
    return true
end

-- Reads finished books' sidecars a few at a time while nothing else happens,
-- so the statistics screen opens without that wait.
function Shell:scheduleWarmup()
    self:cancelWarmup()
    local step
    step = function()
        self._warm = nil
        if not self.shown then return end
        local ok, more = pcall(Books.warmFinished, Books, 8)
        if not ok then
            logger.warn("Polka: warm-up:", more)
        elseif more then
            self._warm = step
            UIManager:scheduleIn(0.25, step)
        end
    end
    self._warm = step
    UIManager:scheduleIn(4, step)
end

function Shell:cancelWarmup()
    if self._warm then
        UIManager:unschedule(self._warm)
        self._warm = nil
    end
end

-- Idle work in small steps (cover prefetch): step() does one item and
-- returns true while more remain, so a tap is never kept waiting long.
-- Runs only while the shell is up; any rebuild cancels it.
function Shell:schedulePrefetch(step)
    self:cancelPrefetch()
    local run
    run = function()
        self._prefetch = nil
        if not self.shown then return end
        local ok, more = pcall(step)
        if not ok then
            logger.warn("Polka: prefetch:", more)
        elseif more then
            self._prefetch = run
            UIManager:scheduleIn(0.3, run)
        end
    end
    self._prefetch = run
    UIManager:scheduleIn(1.5, run)
end

function Shell:cancelPrefetch()
    if self._prefetch then
        UIManager:unschedule(self._prefetch)
        self._prefetch = nil
    end
end

function Shell:onCloseWidget()
    self:leaveView()
    self.shown = false
    if Shell.current == self then Shell.current = nil end
    self:cancelPrefetch()
    self:cancelWarmup()
    self:unscheduleClock()
    if self._first_flush then
        UIManager:unschedule(self._first_flush)
        self._first_flush = nil
    end
    Books:stopPolling()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    Books:freeCovers()
    -- Badge and stamp masks are small and kept (LRU) for the next time.
end

function Shell:close()
    UIManager:close(self, "full")
end

-- Opening a book from anywhere closes us together with the file manager.
function Shell:onShowingReader()
    self:leaveView()
    self.shown = false
    UIManager:close(self)
end

function Shell:onSetupShowReader()
    self:onShowingReader()
end

function Shell:scheduleClock()
    self:unscheduleClock()
    self._clock = function()
        if not self.shown then return end
        guard("clock", function()
            local holder = self.status_holder
            if holder and holder.dimen then
                local fresh = self:statusWidget()
                holder[1]:free()
                holder[1] = fresh
                UIManager:setDirty(self, "ui", holder.dimen)
            end
        end)
        self:scheduleClock()
    end
    local sec = tonumber(os.date("%S")) or 0
    UIManager:scheduleIn(60 - sec + 1, self._clock)
end

function Shell:unscheduleClock()
    if self._clock then
        UIManager:unschedule(self._clock)
        self._clock = nil
    end
end

function Shell:onResume()
    if not self.shown then return end
    guard("resume", function() Books:scan() end)
    self:refresh("full")
    self:scheduleClock()
end

function Shell:onSuspend()
    self:unscheduleClock()
    if self.tab == "tools" then guard("tools suspend", Tools.suspend, self) end
end

function Shell:onNetworkConnected() if self.shown then self:refresh("ui") end end
function Shell:onNetworkDisconnected() if self.shown then self:refresh("ui") end end

function Shell:onSetDimensions(dimen)
    self.dimen = Geom:new{ x = 0, y = 0, w = dimen.w, h = dimen.h }
    self.ges_events.PolkaSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self:refresh("full") -- build() can't throw, flushExtraction is guarded
end

-- Navigation ------------------------------------------------------------------

-- What was new on the view being left (stamps, badges) counts as seen now.
function Shell:leaveView()
    if self.tab == "stats" then
        guard("stats leave", StatsPage.leave, self)
    elseif self.tab == "tools" then
        guard("tools leave", Tools.leave, self)
        self.tools_view = nil -- coming back to the tab shows the list of tools
    end
end

function Shell:switchTab(id)
    if id == "tools" and self.tab == "tools" and self.tools_view then
        return self:closeTool() -- the active tab again: back to the list of tools
    end
    if self.tab == id and id ~= "library" then return end
    if id == "library" and self.tab == "library" then
        -- Tapping the active tab again resets filters, like Kindle's Library.
        self.lib.shelf, self.lib.query, self.lib.page = "*", nil, 1
    end
    self:leaveView()
    self.tab = id
    self:refresh("ui") -- partial e-ink update: quick, no black flash
end

-- Инструменты: nil is the list, otherwise one of Tools.ITEMS (with its own state).
function Shell:openTool(id)
    self:leaveView()
    self.tools_view = id
    self.tool_page = 1
    self:refresh("ui")
end

function Shell:closeTool()
    self:openTool(nil)
end

function Shell:setStatsView(view)
    if self.stats_view == view then return end
    self:leaveView()
    self.stats_view = view
    self.card_page = 1
    self:refresh("ui")
end

function Shell:onPolkaShow(tab)
    self:switchTab(tab or "home")
    return true
end

function Shell:openLibrary(opts)
    opts = opts or {}
    if opts.shelf ~= nil then self.lib.shelf = opts.shelf end
    if opts.sort then self.lib.sort = opts.sort end
    if opts.query ~= nil then self.lib.query = opts.query ~= "" and opts.query or nil end
    self.lib.page = opts.page or 1
    if self.tab ~= "library" then self:leaveView() end
    self.tab = "library"
    self:refresh("ui") -- partial e-ink update: quick, no black flash
end

function Shell:onPolkaSwipe(_, ges)
    UI.safely(function() self:_swipe(ges) end)
    return true
end

function Shell:_swipe(ges)
    local dir = ges and ges.direction
    if self.tab == "library" then
        if dir == "west" then return Library.turn(self, 1) end
        if dir == "east" then return Library.turn(self, -1) end
    end
    if self.tab == "stats" and self.stats_view == "card" and (self.card_pages or 1) > 1 then
        if dir == "west" then return StatsPage.turn(self, 1) end
        if dir == "east" then return StatsPage.turn(self, -1) end
    end
    if self.tab == "tools" and self.tools_view then
        -- Inside a tool, swipes page through its list (or do nothing).
        if dir == "west" or dir == "east" then return Tools.swipe(self, dir) end
    end
    if dir == "west" or dir == "east" then
        local order = { "home", "library", "stats", "tools" }
        for i, id in ipairs(order) do
            if id == self.tab then
                local j = i + (dir == "west" and 1 or -1)
                if order[j] then self:switchTab(order[j]) end
                return true
            end
        end
    end
    return true
end

function Shell:search()
    local dialog
    dialog = InputDialog:new{
        title = "Поиск в библиотеке",
        input = self.lib.query or "",
        input_hint = "Название или автор",
        buttons = {{
            {
                text = "Отмена",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "Найти",
                is_enter_default = true,
                callback = function()
                    local q = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    self:openLibrary{ query = q, shelf = "*" }
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Books -------------------------------------------------------------------------

function Shell:openBook(path)
    local fm = require("apps/filemanager/filemanager").instance
    if fm and filemanagerutil.openFile then
        filemanagerutil.openFile(fm, path) -- honours "ask before opening"
    elseif fm then
        fm:openFile(path) -- KOReader before 2026.03
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

function Shell:showInFolder(path)
    local fm = require("apps/filemanager/filemanager").instance
    self:close()
    if fm then
        local dir = util.splitFilePathName(path)
        fm.file_chooser:changeToPath(dir, path)
    end
end

function Shell:bookActions(rec)
    local dialog
    local function close() UIManager:close(dialog) end
    local function changed()
        Books:invalidate(rec.path)
        self:refresh("ui")
    end
    local ds_or_file = DocSettings:hasSidecarFile(rec.path) and DocSettings:open(rec.path) or rec.path
    local buttons = {
        filemanagerutil.genStatusButtonsRow(ds_or_file, function() close(); changed() end),
        {
            filemanagerutil.genBookInformationButton(ds_or_file, nil, close),
            filemanagerutil.genBookCoverButton(rec.path, nil, close),
        },
        {
            { text = "Показать в папке", callback = function() close(); self:showInFolder(rec.path) end },
            { text = "Читать", callback = function() close(); self:openBook(rec.path) end },
        },
    }
    local title = rec.title or rec.name
    if rec.authors and rec.authors ~= "" then title = title .. "\n" .. rec.authors end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- System actions used by the settings page ---------------------------------------

function Shell:exitKOReader(restart)
    self:close()
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new(restart and "Restart" or "Exit"))
    end)
end

function Shell:openKOReaderMenu()
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm.menu then
        fm.menu:onShowMenu()
    end
end

return Shell
