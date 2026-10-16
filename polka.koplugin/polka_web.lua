-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: «Сайт» — the reader's card on the site, the part that lives in KOReader.

The Kindle is connected to a card (читательский билет) by a code: the
Kindle asks the site for one, shows it with a QR, the reader confirms it on
the phone, and the Kindle receives its own key (polka_site draws all that;
the requests are here). Up to five readers share a card: Kindles and Xteinks.

The sync itself runs in a forked process (polka_websync), so reading and the
shell never wait for the network. It starts by itself, never while a book is
open (the statistics plugin writes the pages read when the book is closed):
  - when Wi‑Fi connects;
  - a few seconds after a book is closed, if Wi‑Fi is on;
  - every half hour while Wi‑Fi is on;
  - on «Синхронизировать сейчас» (or, without Wi‑Fi, as soon as it connects).
Never more often than every three minutes, except on a tap, and not while
«Книги по Wi‑Fi» is receiving books.

The address and the key are kept in KOReader's settings ("polka_web":
{ url, token, card }). A polka_web_config.lua in the plugin's folder
({ url = "https://…", token = "…" }, the way Polka 1.6 was set up) is still
honoured, and a key the site no longer accepts (401) is forgotten quietly.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Net = require("polka_net")
local Sync = require("polka_websync")

local Web = {
    VERSION = "1.7.0",
    SERVER = "https://polka.ikorkod.workers.dev",
    cfg = nil,          -- { url, token } while connected
    pid = nil,          -- the sync running now
    started = nil,      -- when it started (os.time)
    text = nil,         -- its progress line
    pending = false,    -- asked for without Wi‑Fi: sync when it connects
    again = false,      -- asked for while one was running: sync once more after it
    last_try = 0,
    killed = false,
}

Net.VERSION = Web.VERSION

local MIN_GAP = 180     -- seconds between syncs that start by themselves
local PERIOD = 1800     -- while Wi‑Fi stays on
local STALL = 240       -- a sync whose progress line stays the same this long is stopped
local LIMIT = 2 * 3600  -- and any sync after this long (not counting sleep)
local POLL = 0.7

local inited = false
local ticking = false
local scheduled = nil   -- the next automatic sync

-- Seconds that do not count while the Kindle sleeps.
local function mono()
    local time = require("ui/time")
    return time.to_s(time.monotonic())
end

local function sha1(s)
    return require("ffi/sha2").sha1(s)
end

-- Configuration ------------------------------------------------------------------

local function goodUrl(url)
    if type(url) ~= "string" then return false end
    if url:match("^https://[%w%.%-]+") then return true end
    -- plain http only to this very device (tests)
    return url:match("^http://127%.0%.0%.1[:/]") or url:match("^http://localhost[:/]")
        or url == "http://127.0.0.1" or url == "http://localhost"
end

local function saved()
    local s = G_reader_settings:readSetting("polka_web")
    return type(s) == "table" and s or {}
end

local function save(t)
    G_reader_settings:saveSetting("polka_web", t)
    G_reader_settings:flush()
end

-- A key the site refused (401) is not taken again from polka_web_config.lua.
local function rejected(token)
    return token and G_reader_settings:readSetting("polka_web_rejected") == sha1(token)
end

local function loadConfig(dir)
    local file = dir and (dir .. "/polka_web_config.lua")
    if file and lfs.attributes(file, "mode") == "file" then
        local ok, t = pcall(dofile, file)
        if ok and type(t) == "table" and type(t.url) == "string" then
            local url = t.url:gsub("/+$", "")
            local token = type(t.token) == "string" and t.token:match("^[%w_%-]+$") and t.token or nil
            if goodUrl(url) then
                local s = saved()
                if token and not rejected(token) then
                    if s.url ~= url or s.token ~= token then
                        save({ url = url, token = token, card = s.token == token and s.card or nil })
                    end
                elseif not token and s.url ~= url then
                    -- only the address of the site: a key for another site does not go with it
                    save({ url = url })
                end
            else
                logger.warn("Polka web: polka_web_config.lua: the address must start with https://")
            end
        else
            logger.warn("Polka web: bad polka_web_config.lua:", t)
        end
    end
    local s = saved()
    if type(s.url) == "string" and type(s.token) == "string" and goodUrl(s.url) then
        return { url = s.url, token = s.token }
    end
end

function Web.configured()
    return Web.cfg ~= nil
end

-- The site's address (also before any card).
function Web.server()
    local s = saved()
    if goodUrl(s.url) then return s.url end
    return Web.SERVER
end

-- "polka.ikorkod.workers.dev"
function Web.host(url)
    return ((url or Web.server()):gsub("^%a+://", ""):gsub("/.*$", ""))
end

-- "https://host[:port]" of an address, in lower case, without a default port.
local function origin(url)
    if type(url) ~= "string" then return nil end
    local scheme, authority = url:match("^(%a[%w+.-]*)://([^/?#]+)")
    if not scheme or authority:find("@", 1, true) then return nil end
    scheme, authority = scheme:lower(), authority:lower()
    local host, port = authority:match("^(.-):(%d+)$")
    host = host or authority
    if (scheme == "https" and port == "443") or (scheme == "http" and port == "80") then port = nil end
    if host == "" then return nil end
    return scheme .. "://" .. host .. (port and (":" .. port) or "")
end

--- Is url on the site this Kindle talks to (the same scheme, host and port)?
-- An address from the site's answers is taken only then.
function Web.sameSite(url)
    local a = origin(url)
    return a ~= nil and a == origin(Web.server())
end

-- The number of the reader's card, once the site told it.
function Web.card()
    local c = tonumber(saved().card)
    return Web.cfg and c or nil
end

-- What the site knows this Kindle by: stable, but not the raw serial.
function Web.hw()
    local seed
    local f = io.open("/proc/usid", "r")
    if f then
        seed = f:read("*l")
        f:close()
    end
    if not seed or seed == "" then
        seed = G_reader_settings:readSetting("polka_device_seed")
        if type(seed) ~= "string" or seed == "" then
            seed = G_reader_settings:readSetting("device_id")
            if type(seed) ~= "string" or seed == "" then
                seed = sha1(table.concat({ os.time(), os.clock(), tostring({}), math.random() }, "|"))
            end
            G_reader_settings:saveSetting("polka_device_seed", seed)
        end
    end
    return "k-" .. require("ffi/sha2").sha256(seed):sub(1, 16)
end

local MODELS = {
    KindleBasic4 = "Kindle (2022)", KindleBasic5 = "Kindle (2024)", KindleBasic3 = "Kindle (2019)",
    KindlePaperWhite5 = "Kindle Paperwhite 5", KindlePaperWhite5SE = "Kindle Paperwhite 5 SE",
    KindlePaperWhite6 = "Kindle Paperwhite 6", KindlePaperWhite4 = "Kindle Paperwhite 4",
    KindleOasis3 = "Kindle Oasis 3", KindleScribe = "Kindle Scribe",
}

function Web.model()
    local m = Device.model or "Kindle"
    return MODELS[m] or m
end

function Web.koreader()
    local ok, v = pcall(function() return require("version"):getCurrentRevision() end)
    return ok and v or nil
end

-- What the last sync did (the forked process wrote it).
local function readLast()
    if lfs.attributes(Sync.STATE, "mode") ~= "file" then return nil end
    local ok, last = pcall(function()
        return require("luasettings"):open(Sync.STATE):readSetting("last")
    end)
    if ok and type(last) == "table" then return last end
end

-- The sync's own memory, except the checksums of the books (slow to redo):
-- a new card (or none) starts from nothing.
local function resetSyncState()
    pcall(function()
        local LuaSettings = require("luasettings")
        local old = LuaSettings:open(Sync.STATE)
        local md5 = old:readSetting("md5")
        os.remove(Sync.STATE)
        local fresh = LuaSettings:open(Sync.STATE)
        if md5 then fresh:saveSetting("md5", md5) end
        fresh:flush()
    end)
    Web.last, Web.last_ok = nil, nil
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

-- Repaint whatever shows the site: the «Сайт» row, or the Сайт page.
function Web.refreshRow()
    local Shell = package.loaded["polka_shell"]
    local shell = Shell and Shell.current
    if not (shell and shell.shown) then return end
    if shell.page and (shell.page.id == "site" or shell.page.id == "connect") then
        shell:refresh("ui")
        return
    end
    if not (shell.tab == "tools" and not shell.tools_view and not shell.page) then return end
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
Web.online = online

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
Web.clock = clock

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

-- One line about the sync (under «Сайт», and on the Сайт page; `short`: for
-- the narrower row in Инструменты).
function Web.summary(short)
    if not Web.cfg then
        return "Статистика и цитаты в телефоне"
    end
    if Web.pid then
        return Web.text or "Идёт обмен…"
    end
    if otherPid() then
        return "Идёт обмен (начат до перезапуска)…"
    end
    if Web.pending then
        return "Синхронизирую, когда включится Wi‑Fi"
    end
    local last = Web.last
    if not last then
        return online() and "Синхронизирую…" or "Синхронизирую, когда включится Wi‑Fi"
    end
    local got = type(last.downloaded) == "table" and last.downloaded or {}
    if not last.ok and last.later then
        -- the site's daily budget: everything waits, the next try comes by itself
        return "Синхронизирую позже" .. (#got > 0 and (" · +" .. books(#got)) or "")
    end
    if not last.ok and last.clock then
        return short and "Проверьте дату и время на Kindle" or Net.CLOCK
    end
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

-- Forgetting the key -----------------------------------------------------------------

--- The Kindle is no longer connected (unlinked here, or on the site: 401).
-- Quiet: the «Сайт» row simply offers to connect again.
function Web.forget(reason)
    local s = saved()
    if s.token then
        -- the same key in polka_web_config.lua must not come back on the next start
        G_reader_settings:saveSetting("polka_web_rejected", sha1(s.token))
    end
    logger.info("Polka web: forgetting the key:", reason)
    save({ url = goodUrl(s.url) and s.url or nil })
    Web.cfg = nil
    Web.pending, Web.again = false, false
    if scheduled then
        UIManager:unschedule(scheduled)
        scheduled = nil
    end
    resetSyncState()
    pcall(function() require("polka_places").reset() end)
    Web.refreshRow()
end

--- A key from pairing: this Kindle now belongs to card `card`. `url` (the
-- site's own idea of its address) is kept only when it is the very site the
-- Kindle asked; any other address is ignored.
function Web.adopt(token, card, url)
    if url ~= nil and not (goodUrl(url) and Web.sameSite(url)) then
        logger.warn("Polka web: the site named another address, ignored:", tostring(url))
        url = nil
    end
    url = url and url:gsub("/+$", "") or Web.server()
    G_reader_settings:delSetting("polka_web_rejected")
    save({ url = url, token = token, card = tonumber(card) })
    Web.cfg = { url = url, token = token }
    resetSyncState()
    pcall(function() require("polka_places").reset() end)
    Web.ensureTick()
    Web.request(1, true) -- the first sync, now
end

-- Running a sync -------------------------------------------------------------------

-- What a finished sync learnt, if it was made with the key we have now.
local function remember(last)
    if type(last) ~= "table" or not Web.cfg or last.token_hash ~= sha1(Web.cfg.token) then return end
    if last.unauthorized then
        Web.forget("the site does not know this key any more")
        return true
    end
    if last.card then
        local s = saved()
        if tonumber(s.card) ~= tonumber(last.card) and s.token == Web.cfg.token then
            s.card = tonumber(last.card)
            save(s)
        end
    end
    pcall(function() require("polka_places").merge(last) end)
end

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
    if remember(last) then return end
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
    elseif last.later then
        Web.request(0) -- when the site said it would take more (see Web.request)
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
    local cfg = { url = Web.cfg.url, token = Web.cfg.token, version = Web.VERSION,
                  places = require("polka_places").FILE }
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

-- When the site asked to come back (429: its budget for the day is spent).
local function retryAt()
    local last = Web.last
    return type(last) == "table" and last.later and tonumber(last.retry_at) or 0
end

-- An automatic sync in `delay` seconds (or later, to keep MIN_GAP, and not
-- before the time the site asked for). With a book open by then it waits
-- for the book to be closed. `no_gap`: the reader asked for it.
function Web.request(delay, no_gap)
    if not Web.cfg then return end
    local at = os.time() + (delay or 0)
    if not no_gap then at = math.max(at, Web.last_try + MIN_GAP, retryAt()) end
    if scheduled then UIManager:unschedule(scheduled) end
    scheduled = function()
        scheduled = nil
        if not reading() then Web.start() end
    end
    UIManager:scheduleIn(math.max(0, at - os.time()), scheduled)
end

-- «Синхронизировать сейчас» (the round button).
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

-- Requests of the card (in the background) -----------------------------------------

local function post(path, body, token)
    return { url = Web.server() .. path, method = "POST", json = body or {}, token = token, timeouts = { 15, 30 } }
end

--- Asks the site for a pairing code: on_done({ code, poll, url, expires, site } or { error }).
function Web.pairStart(on_done)
    local body = { kind = "kindle", hw = Web.hw(), model = Web.model(), polka = Web.VERSION, koreader = Web.koreader() }
    local req = post("/api/pair/start", body)
    return Net.async(function()
        local r = Net.call(req)
        if r.error then return r end
        if r.status ~= 200 or type(r.data) ~= "table" or not r.data.code then
            return { error = r.status == 429 and "too_many" or "server", status = r.status }
        end
        return r.data
    end, on_done, 40)
end

--- One look at whether the phone confirmed the code: { status = "pending"|"ok"|"expired", token, card }.
function Web.pairPoll(poll_ticket, on_done)
    local req = post("/api/pair/poll", { poll = poll_ticket })
    return Net.async(function()
        local r = Net.call(req)
        if r.error then return r end
        if r.status ~= 200 or type(r.data) ~= "table" then return { error = "server", status = r.status } end
        return r.data
    end, on_done, 30)
end

-- A call with the key; a 401 forgets it.
local function keyed(path, on_done)
    if not Web.cfg then
        UIManager:nextTick(function() on_done({ error = "unauthorized" }) end)
        return
    end
    local token = Web.cfg.token
    local req = { url = Web.cfg.url .. path, method = "POST", json = {}, token = token, timeouts = { 15, 30 } }
    return Net.async(function()
        local r = Net.call(req)
        if r.error then return r end
        if r.status == 401 then return { error = "unauthorized" } end
        if r.status == 403 and type(r.data) == "table" and r.data.error == "too_new" then
            -- a Kindle added to a card that had a reader already: codes after a day
            return { error = "too_new", wait = tonumber(r.data.wait) }
        end
        if r.status ~= 200 or type(r.data) ~= "table" then
            return { error = r.status == 429 and "too_many" or "server", status = r.status }
        end
        return r.data
    end, function(res)
        if res.error == "unauthorized" and Web.cfg and Web.cfg.token == token then
            Web.forget("401 on " .. path)
        end
        on_done(res)
    end, 40)
end

--- A one-time code to log in on the site: { code, expires, card } or { error }.
function Web.loginCode(on_done)
    return keyed("/api/device/login-code", function(res)
        if res.card and Web.cfg then
            local s = saved()
            if tonumber(s.card) ~= tonumber(res.card) then
                s.card = tonumber(res.card)
                save(s)
            end
        end
        on_done(res)
    end)
end

--- The Kindle leaves its card: on success the key is forgotten here too.
function Web.unlink(on_done)
    return keyed("/api/device/unlink", function(res)
        if res.ok then Web.forget("unlinked from the Kindle") end
        on_done(res)
    end)
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

function Web.ensureTick()
    if ticking then return end
    ticking = true
    UIManager:scheduleIn(PERIOD, tick)
end

-- Called by every Polka instance; does its work once.
function Web.init(plugin_dir)
    if inited then return end
    inited = true
    Web.plugin_dir = plugin_dir
    -- the version is the one in _meta.lua (the one a release changes)
    local ok_meta, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
    if ok_meta and type(meta) == "table" and type(meta.version) == "string" then
        Web.VERSION, Net.VERSION = meta.version, meta.version
    end
    Web.cfg = loadConfig(plugin_dir)
    if not Web.cfg then return end
    Web.last = readLast()
    if Web.last and Web.last.ok then Web.last_ok = Web.last.at end
    -- a sync that finished while KOReader was away
    if remember(Web.last) then return end
    Web.ensureTick()
    if online() then Web.request(20) end
end

return Web
