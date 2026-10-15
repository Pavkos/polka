--[[--
Polka: «Сайт» — the sync with the site, the part that lives in KOReader.

The sync itself runs in a forked process (polka_websync), so reading and the
shell never wait for the network. It starts by itself, never while a book is
open (the statistics plugin writes the pages read when the book is closed):
  - when Wi‑Fi connects;
  - a few seconds after a book is closed, if Wi‑Fi is on;
  - every half hour while Wi‑Fi is on;
  - when the «Сайт» row in Инструменты is tapped (or, without Wi‑Fi, as
    soon as it connects).
Never more often than every three minutes, except on a tap, and not while
«Книги по Wi‑Fi» is receiving books.

The site's address and the Kindle's key come from polka_web_config.lua in
the plugin's folder ({ url = "https://…", token = "…" }) and are kept in
KOReader's settings, so a later Polka without that file still syncs.
]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Sync = require("polka_websync")

local Web = {
    VERSION = "1.6.0",
    cfg = nil,          -- { url, token }
    pid = nil,          -- the sync running now
    started = nil,      -- when it started (os.time)
    text = nil,         -- its progress line
    pending = false,    -- asked for without Wi‑Fi: sync when it connects
    again = false,      -- asked for while one was running: sync once more after it
    last_try = 0,
    killed = false,
}

local MIN_GAP = 180     -- seconds between syncs that start by themselves
local PERIOD = 1800     -- while Wi‑Fi stays on
local STALL = 240       -- a sync whose progress line stays the same this long is stopped
local LIMIT = 2 * 3600  -- and any sync after this long (not counting sleep)
local POLL = 0.7

local inited = false
local scheduled = nil   -- the next automatic sync

-- Seconds that do not count while the Kindle sleeps.
local function mono()
    local time = require("ui/time")
    return time.to_s(time.monotonic())
end

-- Configuration ------------------------------------------------------------------

local function goodUrl(url)
    if url:match("^https://[%w%.%-]+") then return true end
    -- plain http only to this very device (tests)
    return url:match("^http://127%.0%.0%.1[:/]") or url:match("^http://localhost[:/]")
        or url == "http://127.0.0.1" or url == "http://localhost"
end

local function loadConfig(dir)
    local file = dir and (dir .. "/polka_web_config.lua")
    if file and lfs.attributes(file, "mode") == "file" then
        local ok, t = pcall(dofile, file)
        if ok and type(t) == "table" and type(t.url) == "string" and type(t.token) == "string"
                and t.token:match("^[%w_%-]+$") then
            local url = t.url:gsub("/+$", "")
            if goodUrl(url) then
                local saved = G_reader_settings:readSetting("polka_web")
                if type(saved) ~= "table" or saved.url ~= url or saved.token ~= t.token then
                    G_reader_settings:saveSetting("polka_web", { url = url, token = t.token })
                end
            else
                logger.warn("Polka web: polka_web_config.lua: the address must start with https://")
            end
        else
            logger.warn("Polka web: bad polka_web_config.lua:", t)
        end
    end
    local s = G_reader_settings:readSetting("polka_web")
    if type(s) == "table" and type(s.url) == "string" and type(s.token) == "string" and goodUrl(s.url) then
        return { url = s.url, token = s.token }
    end
end

function Web.configured()
    return Web.cfg ~= nil
end

-- What the last sync did (the forked process wrote it).
local function readLast()
    if lfs.attributes(Sync.STATE, "mode") ~= "file" then return nil end
    local ok, last = pcall(function()
        return require("luasettings"):open(Sync.STATE):readSetting("last")
    end)
    if ok and type(last) == "table" then return last end
end

-- The process of a sync started by an earlier KOReader (before a restart),
-- if it is still running.
local function otherPid()
    local f = io.open(Sync.LOCK, "r")
    if not f then return nil end
    local pid = tonumber(f:read("*l") or "")
    f:close()
    if pid and pid ~= Web.pid then
        local cmd = io.open("/proc/" .. pid .. "/cmdline", "rb")
        if cmd then
            local line = cmd:read("*a") or ""
            cmd:close()
            if line:find("reader.lua", 1, true) or line:find("luajit", 1, true) then return pid end
        end
    end
end

local function otherSync()
    if otherPid() then return true end
    -- nobody: whatever was left behind is stale
    if not Web.pid then
        os.remove(Sync.LOCK)
        os.remove(Sync.PROGRESS)
    end
    return false
end

local function wifiUpload()
    local Transfer = package.loaded["polka_transfer"]
    return Transfer and Transfer.running and Transfer.running()
end

-- The row on screen ----------------------------------------------------------------

-- Repaint the «Сайт» row if the list of tools is on screen.
function Web.refreshRow()
    local Shell = package.loaded["polka_shell"]
    local shell = Shell and Shell.current
    if not (shell and shell.shown and shell.tab == "tools" and not shell.tools_view) then return end
    local Tools = package.loaded["polka_tools"]
    local row = Tools and Tools.site_row
    local region = row and row.dimen and row.dimen.x and row.dimen:copy()
    shell:build()
    UIManager:setDirty(shell, "ui", region)
end

local function online()
    local NetworkMgr = require("ui/network/manager")
    local ok, yes = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok and yes and true or false
end

local function reading()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI and ReaderUI.instance ~= nil
end

local function clock(t)
    t = tonumber(t) or os.time()
    local now = os.date("*t")
    local d = os.date("*t", t)
    local hm = os.date("%H:%M", t)
    if d.year == now.year and d.yday == now.yday then return "в " .. hm end
    local y = os.date("*t", os.time() - 86400)
    if d.year == y.year and d.yday == y.yday then return "вчера в " .. hm end
    local UI = require("polka_ui")
    return string.format("%d %s в %s", d.day, UI.MONTHS_SHORT[d.month], hm)
end

local function books(n)
    return require("polka_ui").books(n)
end

-- "В 14:07: +2 книги на полке «Философия»"
local function arrived(at, got)
    local shelves, one, n = {}, nil, 0
    for _, b in ipairs(got) do
        local s = type(b.shelf) == "string" and b.shelf ~= "" and b.shelf or ""
        if not shelves[s] then
            shelves[s] = true
            n = n + 1
        end
        one = s
    end
    local where = (n == 1 and one ~= "") and string.format(" на полке «%s»", one) or ""
    local when = clock(at):gsub("^в ", "В "):gsub("^вчера", "Вчера")
    return string.format("%s: +%s%s", when, books(#got), where)
end

-- One line under «Сайт».
function Web.summary()
    if not Web.cfg then
        return "Нет файла настройки polka_web_config.lua"
    end
    if Web.pid then
        return Web.text or "Идёт обмен…"
    end
    if otherPid() then
        return "Идёт обмен (начат до перезапуска KOReader)…"
    end
    if Web.pending then
        return "Синхронизирую, когда включится Wi‑Fi"
    end
    local last = Web.last
    if not last then
        return online() and "Синхронизирую…" or "Синхронизирую, когда включится Wi‑Fi"
    end
    local got = type(last.downloaded) == "table" and last.downloaded or {}
    if not last.ok then
        local text = "Не получилось " .. clock(last.at) .. ": " .. tostring(last.error or "ошибка")
        if #got > 0 then
            text = text .. " · +" .. books(#got)
        elseif Web.last_ok then
            text = text .. " · данные от " .. clock(Web.last_ok):gsub("^в ", "")
        end
        return text
    end
    if #got > 0 and os.time() - (tonumber(last.at) or 0) < 3600 then
        return arrived(last.at, got)
    end
    local text = "Синхронизировано " .. clock(last.at)
    local waiting = tonumber(last.waiting) or 0
    if waiting > 0 then
        text = text .. " · " .. require("polka_ui").plural(waiting, "ждёт", "ждут", "ждут") .. " " .. books(waiting)
    end
    return text
end

-- Running a sync -------------------------------------------------------------------

local function finished()
    local started = Web.started or 0
    Web.pid = nil
    Web.text = nil
    os.remove(Sync.PROGRESS)
    os.remove(Sync.LOCK)
    local last = readLast()
    if Web.killed then
        Web.killed = false
        last = { at = os.time(), ok = false, error = "обмен завис, остановил его" }
    elseif not last or (tonumber(last.at) or 0) < started then
        last = { at = os.time(), ok = false, error = "обмен прервался" }
    end
    Web.last = last
    if last.ok then Web.last_ok = last.at end
    local got = type(last.downloaded) == "table" and #last.downloaded or 0
    local refreshed = false
    if got > 0 then
        -- New books on the shelves: everything that lists books looks again.
        local Books = require("polka_books")
        for _, b in ipairs(last.downloaded) do
            if type(b.path) == "string" then pcall(Books.invalidate, Books, b.path) end
        end
        local Shell = package.loaded["polka_shell"]
        local shell = Shell and Shell.current
        if shell and shell.shown then
            pcall(Books.scan, Books)
            shell:refresh("ui")
            refreshed = true
        end
    end
    if not refreshed then Web.refreshRow() end
    if Web.again then
        Web.again = false
        Web.request(4, true)
    end
end

local function poll()
    if not Web.pid then return end
    if ffiutil.isSubProcessDone(Web.pid) then
        return finished()
    end
    local f = io.open(Sync.PROGRESS, "r")
    if f then
        local text = f:read("*a")
        f:close()
        if text and text ~= "" and text ~= Web.text then
            Web.text = text
            Web.changed_at = mono()
            local now = mono()
            if now - (Web._painted or 0) >= 2 then
                Web._painted = now
                Web.refreshRow()
            elseif not Web._repaint then
                -- the last line must not wait for the next change
                Web._repaint = function()
                    Web._repaint = nil
                    Web._painted = mono()
                    if Web.pid then Web.refreshRow() end
                end
                UIManager:scheduleIn(2, Web._repaint)
            end
        end
    end
    local now = mono()
    if not Web.killed and (now - (Web.changed_at or now) > STALL or now - (Web.started_mono or now) > LIMIT) then
        logger.warn("Polka web: the sync is stuck, stopping it")
        Web.killed = true
        ffiutil.terminateSubProcess(Web.pid)
    end
    UIManager:scheduleIn(POLL, poll)
end

-- Starts a sync now (if none is running). Returns true when it started.
function Web.start()
    if not Web.cfg then return false end
    if Web.pid then
        Web.again = true
        return false
    end
    if otherSync() then return false end
    if not online() then
        Web.pending = true
        Web.refreshRow()
        return false
    end
    if wifiUpload() then
        Web.request(120, true) -- after the books from the phone
        return false
    end
    if scheduled then
        UIManager:unschedule(scheduled)
        scheduled = nil
    end
    local cfg = { url = Web.cfg.url, token = Web.cfg.token, version = Web.VERSION }
    local text = "Собираю, что изменилось…"
    local f = io.open(Sync.PROGRESS, "w")
    if f then
        f:write(text)
        f:close()
    end
    Web.started = os.time()
    local pid, err = ffiutil.runInSubProcess(function()
        require("polka_websync").main(cfg)
    end)
    if not pid then
        logger.warn("Polka web: cannot start the sync:", err)
        os.remove(Sync.PROGRESS)
        return false
    end
    local lock = io.open(Sync.LOCK, "w")
    if lock then
        lock:write(tostring(pid), "\n")
        lock:close()
    end
    Web.pid, Web.killed = pid, false
    Web.started_mono, Web.changed_at = mono(), mono()
    Web.pending = false
    Web.last_try = os.time()
    Web.text = text
    Web._painted = mono()
    Web.refreshRow()
    UIManager:scheduleIn(POLL, poll)
    return true
end

-- An automatic sync in `delay` seconds (or later, to keep MIN_GAP). With a
-- book open by then it waits for the book to be closed.
function Web.request(delay, no_gap)
    if not Web.cfg then return end
    local at = os.time() + (delay or 0)
    if not no_gap then at = math.max(at, Web.last_try + MIN_GAP) end
    if scheduled then UIManager:unschedule(scheduled) end
    scheduled = function()
        scheduled = nil
        if not reading() then Web.start() end
    end
    UIManager:scheduleIn(math.max(0, at - os.time()), scheduled)
end

-- The «Сайт» row was tapped.
function Web.tap()
    if not Web.cfg or Web.pid then return end
    if otherSync() then
        Web.refreshRow()
        return
    end
    if not online() then
        Web.pending = true
        Web.refreshRow()
        return
    end
    Web.start()
end

-- Events (forwarded by main.lua) -----------------------------------------------------

function Web.onNetworkConnected()
    if not Web.cfg then return end
    local asked = Web.pending
    Web.pending = false
    Web.request(6, asked) -- a tap asked for it: no minimum gap
end

function Web.onCloseDocument()
    if Web.cfg and online() then Web.request(4) end
end

local function tick()
    UIManager:scheduleIn(PERIOD, tick)
    if not Web.cfg or Web.pid or reading() or not online() then return end
    Web.request(0)
end

-- Called by every Polka instance; does its work once.
function Web.init(plugin_dir)
    if inited then return end
    inited = true
    Web.cfg = loadConfig(plugin_dir)
    if not Web.cfg then return end
    Web.last = readLast()
    if Web.last and Web.last.ok then Web.last_ok = Web.last.at end
    UIManager:scheduleIn(PERIOD, tick)
    if online() then Web.request(20) end
end

return Web
