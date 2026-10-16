-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: updating itself.

The site says which Polka is the newest (GET <site>/api/plugin/latest:
version, url, sha256, size, notes). Polka asks quietly, at most once a day
and only when Wi‑Fi is already on, and when «Проверить обновления» is
tapped. A newer version shows in Настройки («Версия: 1.7 · есть 1.8»);
the sheet lists what is new, and «Обновить»:

  1. downloads the zip (in the background) and checks its size and SHA-256;
  2. unpacks it next to the plugin (same file system) and checks that it is
     the announced version, with a main.lua;
  3. moves the current folder aside as a backup, puts the new one in its
     place (keeping polka_web_config.lua), and restarts;
  4. after the restart the new Polka removes the backup. If it does not
     even load, the brand patch (outside the plugin) puts the backup back.
Any failure before the restart leaves everything as it was and says so,
quietly, in the sheet.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Net = require("polka_net")

local Update = {
    plugin_dir = nil,
    checking = false,
    hint = nil,         -- a line for «Проверить обновления» after a check
}

local DAY = 86400

-- Versions --------------------------------------------------------------------------------

local function parse(v)
    local a, b, c = tostring(v or ""):match("^v?(%d+)%.(%d+)%.?(%d*)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) or 0 }
end

--- true when version a is newer than b
function Update.newer(a, b)
    local x, y = parse(a), parse(b)
    if not x or not y then return false end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

-- "1.7.0" -> "1.7", "1.8.1" stays
function Update.short(v)
    v = tostring(v or "")
    return (v:gsub("^v", ""):gsub("%.0$", ""))
end

function Update.current()
    return require("polka_web").VERSION
end

-- KOReader older than the release needs (koreader_min "2024.11")?
local function koreaderTooOld(min)
    if type(min) ~= "string" then return false end
    local my = require("polka_web").koreader() or ""
    local y1, m1 = my:match("(%d%d%d%d)%.(%d%d)")
    local y2, m2 = min:match("(%d%d%d%d)%.(%d%d)")
    if not (y1 and y2) then return false end
    return tonumber(y1) * 100 + tonumber(m1) < tonumber(y2) * 100 + tonumber(m2)
end

local function state()
    local s = G_reader_settings:readSetting("polka_update")
    return type(s) == "table" and s or {}
end

--- The newer release, if there is one this KOReader can take.
function Update.available()
    local latest = state().latest
    if type(latest) ~= "table" or not latest.version then return nil end
    if not Update.newer(latest.version, Update.current()) then return nil end
    if koreaderTooOld(latest.koreader_min) then return nil end
    return latest
end

-- Asking the site ------------------------------------------------------------------------------

local function reading()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI and ReaderUI.instance ~= nil
end

local function goodRelease(d)
    return type(d) == "table" and parse(d.version) and type(d.url) == "string"
        and (d.url:match("^https://") or d.url:match("^http://127%.0%.0%.1[:/]") or d.url:match("^http://localhost[:/]"))
        and type(d.sha256) == "string" and d.sha256:match("^%x+$") and #d.sha256 == 64
end

--- Asks the site for the newest release; on_done(release or nil, error).
function Update.check(on_done)
    if Update.checking then return end
    Update.checking = true
    local url = require("polka_web").server() .. "/api/plugin/latest"
    Net.async(function()
        return Net.call{ url = url, method = "GET", timeouts = { 10, 20 } }
    end, function(res)
        Update.checking = false
        local s = state()
        s.checked = os.time()
        local release, err
        if res.error then
            err = "нет связи с сайтом"
        elseif res.status == 200 and goodRelease(res.data) then
            local d = res.data
            local notes = {}
            for i, n in ipairs(type(d.notes) == "table" and d.notes or {}) do
                if i > 8 then break end
                notes[#notes + 1] = tostring(n)
            end
            s.latest = { version = d.version, url = d.url, sha256 = d.sha256:lower(), size = tonumber(d.size),
                         notes = notes, koreader_min = type(d.koreader_min) == "string" and d.koreader_min or nil }
        elseif res.status == 503 or res.status == 404 then
            err = nil -- no releases to read right now: nothing new
        else
            err = "сайт ответил ошибкой"
        end
        G_reader_settings:saveSetting("polka_update", s)
        if not err then release = Update.available() end
        if on_done then on_done(release, err) end
    end, 40)
end

--- Quietly, at most once a day, with Wi‑Fi already on, not while reading.
function Update.maybeCheck()
    if reading() or not require("polka_web").online() then return end
    if os.time() - (tonumber(state().checked) or 0) < DAY then return end
    Update.check(function(release)
        if release then
            -- the «Версия» row shows it the next time Настройки is drawn
            local Shell = package.loaded["polka_shell"]
            local shell = Shell and Shell.current
            if shell and shell.shown and shell.tab == "settings" and not shell.page then shell:refresh("ui") end
        end
    end)
end

function Update.onNetworkConnected()
    UIManager:scheduleIn(30, Update.maybeCheck)
end

-- Installing --------------------------------------------------------------------------------------

local function workDir()
    return Update.plugin_dir:gsub("/[^/]+$", "") .. "/.polka-update"
end

local function backupDir()
    return Update.plugin_dir:gsub("/[^/]+$", "") .. "/.polka-backup"
end

local function markerPath()
    return Update.plugin_dir:gsub("/[^/]+$", "") .. "/.polka-update.lua"
end

local function purge(path)
    if lfs.attributes(path, "mode") == "directory" then
        pcall(ffiutil.purgeDir, path)
    elseif lfs.attributes(path, "mode") then
        os.remove(path)
    end
end

local function writeMarker(t)
    local f = io.open(markerPath(), "w")
    if not f then return false end
    f:write("return {\n")
    for k, v in pairs(t) do
        f:write(string.format("    %s = %q,\n", k, tostring(v)))
    end
    f:write("}\n")
    f:close()
    return true
end

-- In the background: download, check, unpack, check again. Returns
-- { ok = true, dir = "<unpacked polka.koplugin>" } or { error = "<why>" }.
local function prepare(release, work)
    local sha2 = require("ffi/sha2")
    purge(work)
    lfs.mkdir(work)
    local zip = work .. "/polka-" .. release.version .. ".zip"
    local f = io.open(zip, "wb")
    if not f then return { error = "нет места для обновления" } end
    local hasher = sha2.sha256()
    local size, write_err = 0, false
    local function sink(chunk)
        if chunk then
            if not f:write(chunk) then
                write_err = true
                return nil, "write"
            end
            hasher(chunk)
            size = size + #chunk
        end
        return 1
    end
    local code = Net.request{ url = release.url, method = "GET", sink = sink, timeouts = { 20, 300 } }
    f:close()
    if write_err then return { error = "не хватает места на Kindle" } end
    if code ~= 200 then return { error = "не удалось скачать" } end
    if release.size and size ~= release.size then return { error = "файл скачался не целиком" } end
    if hasher() ~= release.sha256 then return { error = "файл повреждён" } end
    -- unpack: one folder polka.koplugin/ and nothing outside it
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(zip) then return { error = "архив не читается" } end
    local dest = work .. "/new"
    lfs.mkdir(dest)
    local ok_all, why = true, nil
    local files = {}
    for entry in arc:iterate() do
        local p = entry.path or ""
        if p:find("%.%.") or p:sub(1, 1) == "/" or not p:match("^polka%.koplugin/") then
            ok_all, why = false, "в архиве лишнее"
            break
        end
        if entry.mode == "file" then files[#files + 1] = p end
    end
    for _, p in ipairs(ok_all and files or {}) do
        local target = dest .. "/" .. p
        -- its folders first
        local acc = dest
        for part in p:match("^(.*)/[^/]+$"):gmatch("[^/]+") do
            acc = acc .. "/" .. part
            lfs.mkdir(acc)
        end
        if not arc:extractToPath(p, target) then
            ok_all, why = false, "архив не распаковался"
            break
        end
    end
    arc:close()
    if not ok_all then return { error = why } end
    local dir = dest .. "/polka.koplugin"
    if lfs.attributes(dir .. "/main.lua", "mode") ~= "file" then return { error = "в архиве нет Полки" } end
    local ok_meta, meta = pcall(dofile, dir .. "/_meta.lua")
    if not ok_meta or type(meta) ~= "table" or meta.version ~= release.version then
        return { error = "в архиве не та версия" }
    end
    local ok_main, err_main = loadfile(dir .. "/main.lua")
    if not ok_main then return { error = "новая версия не читается", detail = tostring(err_main) } end
    os.remove(zip)
    return { ok = true, dir = dir }
end

-- Moves the new folder into place, keeping the old one as a backup.
local function swap(new_dir, release)
    local here = Update.plugin_dir
    local backup = backupDir()
    purge(backup)
    local cfg = here .. "/polka_web_config.lua"
    if lfs.attributes(cfg, "mode") == "file" then
        local data = io.open(cfg, "rb")
        if data then
            local s = data:read("*a")
            data:close()
            local out = io.open(new_dir .. "/polka_web_config.lua", "wb")
            if not out then return false, "не удалось перенести настройку сайта" end
            out:write(s)
            out:close()
        end
    end
    if not writeMarker{ from = Update.current(), to = release.version, at = os.time() } then
        return false, "нет доступа к папке плагинов"
    end
    if not os.rename(here, backup) then
        os.remove(markerPath())
        return false, "не удалось заменить файлы"
    end
    if not os.rename(new_dir, here) then
        os.rename(backup, here)
        os.remove(markerPath())
        return false, "не удалось заменить файлы"
    end
    pcall(ffiutil.fsyncDirectory, here)
    purge(workDir())
    return true
end

--- «Обновить»: the sheet shows how it goes; the restart comes by itself.
function Update.install(sheet, release)
    local Wifi = require("polka_wifi")
    local function fail(why)
        logger.warn("Polka update:", why)
        purge(workDir())
        sheet:update{
            status = "Не получилось обновить: " .. why .. ". Полка осталась как была.",
            small = false,
            buttons = { { text = "Закрыть" } },
        }
    end
    local function go()
        sheet:update{ buttons = false, status = "Скачиваю…" }
        local work = workDir()
        Net.async(function() return prepare(release, work) end, function(res)
            if not res.ok then return fail(res.error or "что-то пошло не так") end
            sheet:update{ status = "Ставлю…" }
            UIManager:nextTick(function()
                local ok, why = swap(res.dir, release)
                if not ok then return fail(why) end
                G_reader_settings:flush()
                sheet:close()
                require("polka_quiet").restart()
            end)
        end, 600)
    end
    if require("polka_web").online() then
        go()
    else
        Wifi.run("Нужен, чтобы скачать обновление.", go)
    end
end

--- The sheet: «Полка 1.8 · у вас 1.7», what is new, «Обновить» / «Позже».
function Update.showSheet(release)
    release = release or Update.available()
    if not release then return end
    local Sheet = require("polka_sheet")
    local sheet
    sheet = Sheet:new{
        title = "Полка " .. Update.short(release.version),
        title_size = 28,
        note = "у вас " .. Update.short(Update.current()),
        bullets = release.notes,
        small = "Скачается по Wi‑Fi, потом перезапуск. Книги и настройки останутся.",
        gap = 18,
        pad_top = 26,
        pad_bottom = 30,
        buttons = {
            { text = "Обновить", primary = true, keep_open = true, callback = function() Update.install(sheet, release) end },
            { text = "Позже" },
        },
    }
    sheet:show()
    return sheet
end

--- «Проверить обновления» (О Полке): the result in the row, the sheet if there is news.
function Update.checkNow(on_change)
    local Wifi = require("polka_wifi")
    local function go()
        Update.hint = "Проверяю…"
        if on_change then on_change() end
        Update.check(function(release, err)
            if release then
                Update.hint = nil
                Update.showSheet(release)
            elseif err then
                Update.hint = "Не получилось проверить: " .. err
            else
                Update.hint = "У вас последняя версия"
            end
            if on_change then on_change() end
        end)
    end
    if require("polka_web").online() then go() else Wifi.run("Нужен, чтобы проверить обновления.", go) end
end

-- After a restart ------------------------------------------------------------------------------------

function Update.init(plugin_dir)
    Update.plugin_dir = plugin_dir
    local marker = markerPath()
    if lfs.attributes(marker, "mode") == "file" then
        local ok, m = pcall(dofile, marker)
        os.remove(marker)
        if ok and type(m) == "table" then
            if m.to == Update.current() then
                logger.info("Polka: updated from", m.from, "to", m.to)
                purge(backupDir())
            elseif m.failed then
                -- the new version did not load; the brand patch put this one back
                Update.hint = "Обновление не встало, Полка осталась как была"
                purge(plugin_dir:gsub("/[^/]+$", "") .. "/.polka-failed")
            end
        end
    end
    purge(workDir())
    UIManager:scheduleIn(60, Update.maybeCheck)
end

return Update
