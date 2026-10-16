-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: KOReader, quietly.

What KOReader shows that nobody asked for, and what Polka does about it
(all in memory: nothing here is written to KOReader's settings, so taking
Polka away gives KOReader back exactly as it was):

  «Открытие файла «…».» on every book      the message is made invisible
  toasts after gestures («Подсветка        not shown (until a mask is chosen in
    включена.», «Размер шрифта: 22»)       KOReader's settings); the gestures
                                          themselves work as before
  the loading bar at the top left          not drawn (unless switched on)
  «Вы хотите включить Wi‑Fi?» …            Polka's sheet (polka_wifi)
  «Изменение вступит в силу …»             Polka's sheet, then the splash
  «Выйти из Полки?»                        Polka's sheet
  the end-of-book dialog                   Polka's end-of-book screen (polka_end)

And the device calls itself «Полка»: patches/1-polka-brand.lua, copied into
KOReader's patches folder, renames KOReader in its menus and messages from
the next start (and right away for what is shown from now on).
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Quiet = {}

local installed = false

local function guard(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logger.warn("Polka quiet:", label, err) end
    return ok
end

-- «Открытие файла» ------------------------------------------------------------------

local opening_prefix = nil

local function openingPrefix()
    if opening_prefix == nil then
        local _ = require("gettext")
        local msg = _("Opening file '%1'.")
        opening_prefix = type(msg) == "string" and msg:match("^(.-)%%1") or false
    end
    return opening_prefix or nil
end

local function quietOpening()
    local InfoMessage = require("ui/widget/infomessage")
    local orig_init = InfoMessage.init
    InfoMessage.init = function(self, ...)
        if not self.invisible and tonumber(self.timeout) == 0 and type(self.text) == "string" then
            local prefix = openingPrefix()
            if prefix and prefix ~= "" and self.text:sub(1, #prefix) == prefix then
                -- the page stays as it is until the book is there
                self.invisible = true
            end
        end
        return orig_init(self, ...)
    end
end

-- Toasts and the loading bar ------------------------------------------------------------

local function quietToasts()
    local Notification = require("ui/widget/notification")
    local orig_notify = Notification.notify
    Notification.notify = function(self, arg, source, refresh_after)
        if G_reader_settings:hasNot("notification_sources_to_show_mask") then
            local src = source or self.notify_source
            if src == Notification.SOURCE_DISPATCHER then return false end
        end
        return orig_notify(self, arg, source, refresh_after)
    end
end

local function quietLoadingBar()
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    local orig = ReaderRolling.showEngineProgress
    ReaderRolling.showEngineProgress = function(self, percent)
        if G_reader_settings:hasNot("cre_show_progress") then return end
        return orig(self, percent)
    end
end

-- Restart and exit --------------------------------------------------------------------

--- Restarts with the splash on screen instead of the frozen last page.
function Quiet.restart()
    guard("splash", function() require("polka_splash").show() end)
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
end

function Quiet.askRestart(message_text)
    local Sheet = require("polka_sheet")
    Sheet:new{
        title = "Нужен перезапуск",
        body = message_text or "Изменение вступит в силу после перезапуска.",
        buttons = {
            { text = "Перезапустить", primary = true, callback = Quiet.restart },
            { text = "Позже" },
        },
    }:show()
end

local function ownRestart()
    if not Device:canRestart() then return end
    UIManager.event_handlers.Restart = function(message_text)
        local ok = guard("restart sheet", Quiet.askRestart, message_text)
        if not ok then UIManager:broadcastEvent(Event:new("Restart")) end
    end
end

local function isExitConfirm(widget)
    if type(widget) ~= "table" or type(widget.text) ~= "string" or not widget.ok_callback then return false end
    local _ = require("gettext")
    return widget.text == _("Exit KOReader?")
end

function Quiet.askExit(widget)
    local Sheet = require("polka_sheet")
    Sheet:new{
        title = "Выйти из Полки?",
        body = Device:isKindle() and "Вернётесь на экран Kindle." or nil,
        buttons = {
            { text = "Выйти", primary = true, callback = function() widget.ok_callback() end },
            { text = "Остаться", callback = function()
                if widget.cancel_callback then widget.cancel_callback() end
            end },
        },
    }:show()
end

local function ownExitConfirm()
    local orig_show = UIManager.show
    UIManager.show = function(self, widget, ...)
        if isExitConfirm(widget) then
            local ok = guard("exit sheet", Quiet.askExit, widget)
            if ok then return end
        end
        return orig_show(self, widget, ...)
    end
end

-- End of the book ------------------------------------------------------------------------

local function patchEndOfBook(plugin)
    local ui = plugin.ui
    local status = ui and ui.status
    if not status or rawget(status, "_polka_end") then return end
    local orig = status.onEndOfBook
    if type(orig) ~= "function" then return end
    rawset(status, "_polka_end", true)
    status.onEndOfBook = function(this, ...)
        local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
        local QuickStart = package.loaded["ui/quickstart"]
        local is_guide = QuickStart and G_reader_settings:readSetting("lastfile") == QuickStart.quickstart_filename
        if action ~= "pop-up" or is_guide then return orig(this, ...) end
        local top = UIManager:getTopmostVisibleWidget() or {}
        if top.name == "polka_end" then return true end
        local ok, err = pcall(function() require("polka_end").show(plugin) end)
        if not ok then
            logger.warn("Polka: end of book:", err)
            return orig(this, ...)
        end
        return true
    end
end

-- «Полка» instead of «KOReader» --------------------------------------------------------------

Quiet.BRAND_PATCH = "1-polka-brand.lua"

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Copies the brand patch into KOReader's patches folder when it is missing
-- or older; returns the path of the plugin's own copy.
function Quiet.installBrandPatch(plugin_dir)
    local src = plugin_dir .. "/patches/" .. Quiet.BRAND_PATCH
    local mine = readFile(src)
    if not mine then return nil end
    local dir = DataStorage:getDataDir() .. "/patches"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local dst = dir .. "/" .. Quiet.BRAND_PATCH
    if readFile(dst) ~= mine then
        local tmp = dst .. ".new"
        local f = io.open(tmp, "wb")
        if f then
            local ok = f:write(mine)
            f:close()
            if ok and os.rename(tmp, dst) then
                logger.info("Polka: brand patch installed:", dst)
            else
                os.remove(tmp)
            end
        end
    end
    return src
end

-- What the patch would have done at start-up, done now (first run after
-- installing, or with patches switched off): strings shown from now on.
local function brandNow(src)
    if package.loaded["polka.brand"] then return end
    local ok, err = pcall(dofile, src)
    if not ok then logger.warn("Polka: brand:", err) end
end

-- Install ----------------------------------------------------------------------------------

function Quiet.install(plugin)
    if not installed then
        installed = true
        guard("wifi", function() require("polka_wifi").install() end)
        guard("opening", quietOpening)
        guard("toasts", quietToasts)
        guard("loading bar", quietLoadingBar)
        guard("restart", ownRestart)
        guard("exit", ownExitConfirm)
        guard("brand", function()
            local src = Quiet.installBrandPatch(plugin.path)
            if src then brandNow(src) end
        end)
        guard("update", function() require("polka_update").init(plugin.path) end)
        -- a launcher on the Kindle's screen gets this version's script (after an update)
        UIManager:scheduleIn(20, function() guard("launcher", require("polka_launcher").refresh) end)
    end
end

function Quiet.onReaderReady(plugin)
    guard("end of book", patchEndOfBook, plugin)
end

return Quiet
