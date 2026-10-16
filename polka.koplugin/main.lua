-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka («Полка») — a calm, Kindle-like home for KOReader.

Shows its own home screen on top of the file manager at start-up and after a
book is closed: Главная (current book, recent books, shelves), Библиотека
(cover grid by shelf), Статистика, Инструменты (quotes, books over Wi‑Fi,
OPDS catalogs, Instapaper, the site) and simplified Настройки.

Shelves are the top-level folders of the books directory. Covers and
metadata come from KOReader's CoverBrowser cache, progress from each book's
sidecar, statistics from the Statistics plugin database. Polka never writes
to books; it only stores a few settings prefixed with "polka_".

Connected to a reader's card on the site (polka_web, polka_site), Polka keeps
it in sync: statistics, quotes and the place in each book go there, books
uploaded there come to the shelves. That runs in a separate process, in the
background.

Polka also keeps KOReader quiet (polka_quiet: no «Открытие файла…», no
toasts from stray touches, its own Wi‑Fi, restart and end-of-book screens)
and calls the device «Полка» (patches/1-polka-brand.lua).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Shell = require("polka_shell")
local UI = require("polka_ui")
local Web = require("polka_web")

local Polka = WidgetContainer:extend{
    name = "polka",
    is_doc_only = false,
}

-- Survive across FileManager/ReaderUI instances.
local state = {
    pending_tab = nil,       -- tab to open once the file manager is back
    simpleui_prompted = false,
    pending_jump = nil,      -- { file, page, pos0 }: a quote to show once its book is open
}

-- Opens a book at a quote (from the quotes screen).
function Polka.openAt(path, page, pos0)
    state.pending_jump = { file = path, page = page, pos0 = pos0, at = os.time() }
    if Shell.current then
        Shell.current:openBook(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

local function otherShells()
    local ok, PluginLoader = pcall(require, "pluginloader")
    local found = {}
    if ok and PluginLoader.enabled_plugins then
        for _, p in ipairs(PluginLoader.enabled_plugins) do
            if type(p.name) == "string" and p.name:match("^simpleui") then
                found[#found + 1] = p.name
            end
        end
    end
    return found
end

function Polka:onDispatcherRegisterActions()
    Dispatcher:registerAction("polka_home", {
        category = "none", event = "PolkaShow", arg = "home", title = "Полка: главная", general = true,
    })
    Dispatcher:registerAction("polka_library", {
        category = "none", event = "PolkaShow", arg = "library", title = "Полка: библиотека", general = true,
    })
    Dispatcher:registerAction("polka_stats", {
        category = "none", event = "PolkaShow", arg = "stats", title = "Полка: статистика", general = true,
    })
end

function Polka:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local ok, err = pcall(Web.init, self.path)
    if not ok then logger.err("Polka: site sync:", err) end
    ok, err = pcall(function() require("polka_quiet").install(self) end)
    if not ok then logger.err("Polka: quiet:", err) end

    if self.ui.document then
        -- Inside a book: reading like on a Kindle (status line, toolbar, «Aa»).
        local Reader = require("polka_reader")
        self.reader = Reader.new(self)
        if Reader.isOn() then
            local ok, err = pcall(self.reader.attach, self.reader)
            if not ok then
                logger.err("Polka: reading mode failed:", err)
                pcall(self.reader.detach, self.reader)
            end
        end
        return
    end

    self:hookHomeButton()

    local others = otherShells()
    if #others > 0 then
        if not state.simpleui_prompted then
            state.simpleui_prompted = true
            UIManager:nextTick(function() self:promptDisableOthers(others) end)
        end
        if not state.pending_tab then return end
    end

    local tab = state.pending_tab
    state.pending_tab = nil
    if tab or G_reader_settings:nilOrTrue("polka_autostart") then
        UIManager:nextTick(function() self:showShell(tab) end)
    end
end

-- The house icon in the file manager title bar (and the Home key) bring you
-- back here instead of jumping to the home folder.
function Polka:hookHomeButton()
    local fm = self.ui
    local orig = fm.onHome
    local plugin = self
    fm.onHome = function(fm_self, ...)
        if G_reader_settings:nilOrTrue("polka_autostart") or Shell.current then
            -- Newer KOReader: FileChooser:onHome suspends repaints before
            -- forwarding here; the stock handler resumes them first, so do we.
            if UIManager.setSuspendRepaints then
                UIManager:setSuspendRepaints(false)
            end
            plugin:showShell("home")
            return true
        end
        return orig(fm_self, ...)
    end
end

function Polka:onReaderReady()
    if self.reader then self.reader:patchGestures() end
    pcall(function() require("polka_quiet").onReaderReady(self) end)
    local Places = require("polka_places")
    UI.safely(Places.opened, self.ui)
    local jump = state.pending_jump
    state.pending_jump = nil
    local doc = self.ui and self.ui.document
    if not (jump and doc and doc.file == jump.file) then
        -- another reader got further in this book later: offer to go there
        local ui = self.ui
        UIManager:scheduleIn(1, function()
            if ui.document then UI.safely(Places.offer, ui) end
        end)
    end
    -- (an open that was cancelled — "Open this file?" → Cancel — must not
    -- make the same book jump much later)
    if jump and doc and doc.file == jump.file and os.time() - (jump.at or 0) < 120 then
        local ui = self.ui
        UIManager:nextTick(function()
            if not ui.document then return end
            UI.safely(function()
                -- the place it was read up to stays reachable with "back", as from a bookmark
                if ui.link and ui.link.addCurrentLocationToStack then ui.link:addCurrentLocationToStack() end
                if ui.rolling and type(jump.page) == "string" then
                    ui:handleEvent(Event:new("GotoXPointer", jump.page, jump.pos0))
                elseif ui.paging and tonumber(jump.page) then
                    ui:handleEvent(Event:new("GotoPage", tonumber(jump.page)))
                end
            end)
        end)
    end
end

-- The book is being closed: take the toolbar or the «Aa» panel with it.
-- (By CloseWidget time ui.document is already gone, so test self.reader.)
function Polka:onCloseDocument()
    if self.reader then self.reader:onClose() end
    if self.ui and self.ui.document then
        local ok, err = pcall(require("polka_places").record, self.ui)
        if not ok then logger.warn("Polka: place:", err) end
    end
    pcall(Web.onCloseDocument)
end

-- If the file manager goes away for any reason other than opening a book
-- (Exit from KOReader's own menu, restart...), take the shell with it:
-- alone on screen it would keep KOReader from quitting.
function Polka:onCloseWidget()
    if self._heal then
        UIManager:unschedule(self._heal)
        self._heal = nil
    end
    if self.reader then
        self.reader:onClose()
        return
    end
    local shell = Shell.current
    if shell and shell.shown then
        shell.shown = false
        UIManager:close(shell)
    end
end

-- When Wi‑Fi comes or goes, the Kindle's own status bar may draw its icon
-- (sometimes the clock) over KOReader. Repaint a little later, twice, to
-- wipe it: the screen KOReader shows is redrawn, nothing else changes.
function Polka:healScreen()
    if not Device:isKindle() then return end
    if self._heal then UIManager:unschedule(self._heal) end
    local runs = 0
    self._heal = function()
        runs = runs + 1
        UIManager:setDirty("all", "ui")
        if runs < 2 then
            UIManager:scheduleIn(3, self._heal)
        else
            self._heal = nil
        end
    end
    UIManager:scheduleIn(1.5, self._heal)
end

function Polka:onNetworkConnected()
    self:healScreen()
    pcall(Web.onNetworkConnected)
    pcall(function() require("polka_update").onNetworkConnected() end)
    local Site = package.loaded["polka_site"]
    if Site then pcall(Site.onNetworkConnected) end
end
function Polka:onNetworkDisconnected() self:healScreen() end

-- Night mode on or off: KOReader re-reads its screen refresh rate, the
-- Kindle way of flashing has to be put back. (Never consumes the event.)
function Polka:onToggleNightMode()
    if self.reader then self.reader:onNightModeChanged() end
end
Polka.onSetNightMode = Polka.onToggleNightMode

-- The file manager re-lays itself out after a rotation; follow it.
function Polka:onSetDimensions()
    if self.reader then
        self.reader:closeOverlays()
        return
    end
    local shell = Shell.current
    if shell and shell.shown then
        UIManager:nextTick(function()
            local size = Device.screen:getSize()
            if shell.shown and (size.w ~= shell.dimen.w or size.h ~= shell.dimen.h) then
                shell:onSetDimensions(size)
            end
        end)
    end
end

function Polka:showShell(tab)
    local FileManager = require("apps/filemanager/filemanager")
    if Shell.current and Shell.current.shown then
        if tab and Shell.current.tab ~= tab then
            Shell.current:switchTab(tab)
        end
        return
    end
    if FileManager.instance ~= self.ui then
        return -- this file manager is already gone
    end
    local ok, shell_or_err = pcall(Shell.new, Shell, { plugin = self, tab = tab or "home" })
    if not ok then
        logger.err("Polka: cannot open the shell:", shell_or_err)
        UIManager:show(InfoMessage:new{ text = "Полка не смогла открыться:\n" .. tostring(shell_or_err) })
        return
    end
    UIManager:show(shell_or_err)
end

function Polka:onPolkaShow(tab)
    tab = tab or "home"
    if self.ui.document then
        state.pending_tab = tab
        self.ui:onHome() -- closes the book; the file manager comes back and we show up on top
    else
        UIManager:nextTick(function() self:showShell(tab) end)
    end
    return true
end

function Polka:promptDisableOthers(names)
    UIManager:show(ConfirmBox:new{
        text = "Включён SimpleUI — две оболочки сразу будут мешать друг другу.\n\n"
            .. "Выключить его и перезапустить? Вернуть можно в «Прочие инструменты → Управление плагинами».",
        ok_text = "Выключить и перезапустить",
        cancel_text = "Не сейчас",
        ok_callback = function()
            local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
            for _, name in ipairs(names) do
                disabled[name] = true
            end
            G_reader_settings:saveSetting("plugins_disabled", disabled)
            local start_with = G_reader_settings:readSetting("start_with")
            if type(start_with) == "string" and start_with:find("simpleui", 1, true) then
                G_reader_settings:saveSetting("start_with", "filemanager")
            end
            G_reader_settings:flush()
            if Device:canRestart() then
                require("polka_quiet").restart()
            else
                UIManager:show(InfoMessage:new{ text = "Готово. Перезапустите Полку." })
            end
        end,
    })
end

function Polka:addToMainMenu(menu_items)
    if self.ui.document then
        local Reader = require("polka_reader")
        menu_items.polka = {
            text = "Полка",
            sorting_hint = "main",
            sub_item_table = {
                {
                    text = "На главную",
                    callback = function(touchmenu_instance)
                        if touchmenu_instance then touchmenu_instance:closeMenu() end
                        UIManager:nextTick(function() self:onPolkaShow("home") end)
                    end,
                },
                {
                    text = "Чтение как на Kindle",
                    help_text = "Нижняя строка «Осталось в главе», тулбар по тапу сверху страницы, панель «Aa». Свайп вниз от верхнего края по-прежнему открывает полное меню.",
                    checked_func = function() return Reader.isOn() end,
                    callback = function()
                        local on = not Reader.isOn()
                        G_reader_settings:saveSetting("polka_reader", on)
                        if self.reader then
                            require("polka_ui").safely(function()
                                if on then
                                    self.reader:attach(true)
                                else
                                    self.reader:detach()
                                end
                            end)
                        end
                    end,
                },
                {
                    text = "Меню выделения как на Kindle",
                    help_text = "Небольшая панель рядом с выделенным текстом: Выделить, Заметка, Копировать, Словарь. Остальное — под «Ещё».",
                    enabled_func = function() return Reader.isOn() end,
                    checked_func = function() return Reader.isOn() and Reader.selectionMenuOn() end,
                    callback = function()
                        G_reader_settings:saveSetting("polka_selection_menu", not Reader.selectionMenuOn())
                    end,
                },
            },
        }
    else
        menu_items.polka = {
            text = "Полка",
            sorting_hint = "main",
            callback = function() UIManager:nextTick(function() self:showShell("home") end) end,
        }
    end
end

return Polka
