-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the sync with the site — the part that runs in a separate process.

Polka (polka_web) forks KOReader for this, so nothing here may touch the
screen or KOReader's files: it reads the statistics database, the books
folder, the books' sidecars and the places file (polka_places), talks to the
site, saves books the site has for the Kindle, and writes what it did to its
own file (settings/polka_web.lua), which nothing else writes. While it runs,
one line of progress sits in settings/polka_web_progress.txt and the process
id in settings/polka_web.lock.

The order of a sync:
  1. a short hello (device, reader's card, where this Kindle stopped in the
     books read since the last sync) — the site answers with what it has:
     the number of the card, the fingerprint of its book list, its newest
     session, the books uploaded for the Kindle, and the places the card's
     other readers reached since the last time (a 401 here means the key
     was taken back on the site: polka_web forgets it);
  2. what changed since the last time, in posts of a few hundred KB:
       stat_books  the books the new sessions belong to
       progress    status, percent, date finished of the books in the history
       sessions    reading sessions built from the statistics plugin's page rows
       highlights  every highlight and note of a book whose sidecar changed
       books       the list of book files (when a file or a title changed)
     (everything, when the site's answer shows it lost what it had);
  3. the books uploaded on the site are saved to their shelves;
  4. the covers the site asks for.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Sync = {}

Sync.STATE = DataStorage:getSettingsDir() .. "/polka_web.lua"
Sync.PROGRESS = DataStorage:getSettingsDir() .. "/polka_web_progress.txt"
Sync.LOCK = DataStorage:getSettingsDir() .. "/polka_web.lock"

local SESSION_GAP = 600        -- a pause longer than this starts a new session
local OPEN_WINDOW = 6 * 3600   -- sessions that ended this recently may still grow
local POST_BYTES = 250000      -- about this much per post (a free Worker has ~10 ms of CPU)
local LIST_PER_POST = 250      -- books of the library list per post
local MAX_COVERS = 150         -- covers sent in one sync…
local COVER_SECONDS = 150      -- …and the time they may take
local COVER_BATCH = 50         -- the site asks for at most this many at a time
local MAX_COVER_BYTES = 1500000
local COVER_H = 640            -- bigger covers are scaled down to this height
local MAX_PIXELS = 12000000    -- bigger images are not decoded (memory)
local MAX_ENTRY = 8 * 1024 * 1024
local MAX_FB2 = 30 * 1024 * 1024

-- JSON ------------------------------------------------------------------------

local ok_rj, rapidjson = pcall(require, "rapidjson")
local function encode(t)
    if ok_rj then return rapidjson.encode(t) end
    return require("json").encode(t)
end
-- JSON null must not reach Lua code or the state file: it becomes nil.
local function denull(t)
    for k, v in pairs(t) do
        if ok_rj and v == rapidjson.null then
            t[k] = nil
        elseif type(v) == "table" then
            denull(v)
        end
    end
    return t
end
local function decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, t
    if ok_rj then ok, t = pcall(rapidjson.decode, s) else ok, t = pcall(require("json").decode, s) end
    if ok and type(t) == "table" then return denull(t) end
end
-- An empty Lua table would go out as {}; the site wants [] for lists (and
-- takes {} as an empty list too, in case this is not available).
local function list(t)
    if ok_rj and rapidjson.array then return rapidjson.array(t) end
    return t
end

local function sha1(s)
    return require("ffi/sha2").sha1(s)
end

local function plural(n, one, few, many)
    return require("polka_ui").plural(n, one, few, many)
end

local function str(v)
    return type(v) == "string" and v or nil
end

-- One line for «Сайт» in Инструменты (read by polka_web while we run; it
-- also tells polka_web we are alive, so long steps say how far they got).
local function progress(text)
    local f = io.open(Sync.PROGRESS, "w")
    if f then
        f:write(text)
        f:close()
    end
end

-- HTTP --------------------------------------------------------------------------

local function request(cfg, method, path, body, ctype, sink, timeouts)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local chunks = {}
    local headers = {
        ["Authorization"] = "Bearer " .. cfg.token,
        ["Accept-Encoding"] = "identity",
        ["User-Agent"] = "Polka/" .. (cfg.version or "1") .. " (KOReader)",
    }
    if body then
        headers["Content-Type"] = ctype or "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    socketutil:set_timeout(timeouts and timeouts[1] or 15, timeouts and timeouts[2] or 120)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = cfg.url .. path,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = sink or socketutil.table_sink(chunks),
        })
    end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    return code, table.concat(chunks)
end

local function netError(code, err)
    if code == 401 or code == 403 then return "сайт не принял ключ Kindle" end
    if code == 413 then return "слишком много данных за раз" end
    if type(code) == "number" then return string.format("сайт ответил ошибкой %d", code) end
    local e = tostring(code or err or "")
    if e:find("timeout") then return "сайт не ответил вовремя" end
    return "нет связи с сайтом"
end

-- A post the site answered with {"ok": true, …}; anything else (an error, a
-- Wi‑Fi login page answering for the site) is a failure.
local function postJSON(cfg, path, payload)
    local ok_enc, body = pcall(encode, payload)
    if not ok_enc then
        logger.warn("Polka web: cannot encode a post:", body)
        return nil, "не удалось собрать данные"
    end
    local code, resp = request(cfg, "POST", path, body)
    if code ~= 200 then return nil, netError(code, resp), code end
    local t = decode(resp)
    if type(t) ~= "table" or t.ok ~= true then
        return nil, "отвечает не сайт (нужен вход в сеть Wi‑Fi?)", code
    end
    return t
end

-- The books folder ----------------------------------------------------------------

local SKIP_DIRS = {
    koreader = true, system = true, extensions = true, dictionaries = true, fonts = true,
    screensavers = true, linkss = true, linkfonts = true, mrpackages = true, kual = true,
    libkh = true, usbnet = true, backups = true, audible = true, ["lost+found"] = true,
    ["$recycle.bin"] = true, ["system volume information"] = true, voice = true,
}

-- Every book file under root: { path, rel, name, shelf, size, mtime, ext }.
function Sync.scan(root)
    local Books = require("polka_books")
    local out = {}
    local function walk(dir, shelf, depth)
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if depth < 6 and not name:match("%.sdr$") and not SKIP_DIRS[name:lower()] then
                        walk(path, shelf or name, depth + 1)
                    end
                elseif attr and attr.mode == "file" and Books.isBookName(name) then
                    local lname = name:lower()
                    out[#out + 1] = {
                        path = path, rel = path:sub(#root + 2), name = name, shelf = shelf,
                        size = attr.size, mtime = attr.modification,
                        ext = lname:match("%.([%w]+)%.zip$") or lname:match("%.([%w]+)$"),
                    }
                end
            end
        end
    end
    walk(root, nil, 0)
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

-- KOReader's checksum of a book (statistics and sidecars use the same),
-- remembered by path, size and time so each file is read once.
function Sync.identify(files, cache)
    local fresh = {}
    for i, f in ipairs(files) do
        local c = cache[f.path]
        if type(c) == "table" and c.s == f.size and c.m == f.mtime and c.h then
            f.md5 = c.h
        else
            if i % 25 == 0 then progress(string.format("Проверяю книги: %d из %d…", i, #files)) end
            f.md5 = util.partialMD5(f.path)
        end
        if f.md5 then fresh[f.path] = { s = f.size, m = f.mtime, h = f.md5 } end
    end
    return fresh
end

-- Titles and authors from the CoverBrowser cache, as KOReader read them
-- before the fork (polka_books). The cache itself is not opened here: KOReader
-- keeps it open, and SQLite must not use a file across fork() in two processes.
local function bookInfo()
    local meta = require("polka_books").meta
    return type(meta) == "table" and meta or {}
end

local function fromName(name)
    local base = name:match("^(.-)%.[%w]+%.[zZ][iI][pP]$") or name:match("^(.*)%.[^%.]+$") or name
    base = base:gsub("_", " ")
    local author, title = base:match("^(.-)%s+[%-–—]%s+(.+)$")
    if author and title and #author > 0 then return title, author end
    return base, nil
end

local function clean(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("\n", ", "):gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

-- The list of book files as the site stores it, and its fingerprint.
function Sync.library(files)
    local info = bookInfo()
    local out, lines = {}, {}
    for _, f in ipairs(files) do
        if f.md5 then
            local i = info[f.path] or {}
            local title, authors = clean(i.title), clean(i.authors)
            if not title then
                local t, a = fromName(f.name)
                title = t
                authors = authors or a
            end
            local series = clean(i.series)
            if series and i.series_index then series = string.format("%s #%s", series, i.series_index) end
            local item = {
                id = f.md5, md5 = f.md5, path = f.rel, shelf = f.shelf, title = title, authors = authors,
                series = series, lang = clean(i.lang), fmt = f.ext, size = f.size, mtime = f.mtime,
            }
            out[#out + 1] = item
            lines[#lines + 1] = table.concat({ item.id, item.path, item.title or "", item.authors or "",
                                               item.series or "", item.size or 0 }, "|")
        end
    end
    return out, sha1(table.concat(lines, "\n"))
end

-- Reading sessions ------------------------------------------------------------------

-- Page rows since `from` grouped into sessions; returns the sessions, the
-- books they belong to, and where to start next time.
function Sync.sessions(from)
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return {}, {}, from end
    local sessions, books = {}, {}
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local ok_q, res, n = pcall(conn.exec, conn, string.format([[
            SELECT b.md5, b.title, b.authors, b.pages, b.language, p.page, p.start_time, p.duration, p.total_pages
            FROM page_stat_data p JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= %d AND b.md5 IS NOT NULL AND b.md5 != ''
            ORDER BY p.id_book, p.start_time]], math.floor(tonumber(from) or 0)))
        conn:close()
        if not ok_q then error(res) end
        if not res or not n or n == 0 then return end
        local cur, pages_seen
        local function close()
            if cur then
                local p = 0
                for _ in pairs(pages_seen) do p = p + 1 end
                cur.p = p
                sessions[#sessions + 1] = cur
            end
        end
        for i = 1, n do
            local md5 = res[1][i]
            local page, start, dur, total = tonumber(res[6][i]) or 0, tonumber(res[7][i]) or 0, tonumber(res[8][i]) or 0, tonumber(res[9][i])
            if not books[md5] then
                books[md5] = { id = md5, title = clean(res[2][i]), authors = clean(res[3][i]), pages = tonumber(res[4][i]), lang = res[5][i] }
            end
            if not cur or cur.b ~= md5 or start - cur.e > SESSION_GAP then
                close()
                cur = { b = md5, s = start, e = start + dur, sec = 0, fp = page, lp = page, tp = total }
                pages_seen = {}
            end
            cur.sec = cur.sec + dur
            if start + dur > cur.e then cur.e = start + dur end
            if page < cur.fp then cur.fp = page end
            if page > cur.lp then cur.lp = page end
            cur.tp = total or cur.tp
            pages_seen[page] = true
        end
        close()
    end)
    if not ok then
        logger.warn("Polka web: statistics:", err)
        return {}, {}, from
    end
    -- Next time start from the oldest session that may still grow, and never
    -- in the middle of a session (that would send its second half as a new one).
    local now = os.time()
    local open_from, last_end
    for _, s in ipairs(sessions) do
        if s.e > now - OPEN_WINDOW and (not open_from or s.s < open_from) then open_from = s.s end
        if not last_end or s.e > last_end then last_end = s.e end
    end
    local next_from = open_from or (last_end and last_end + 1) or from
    local moved
    repeat
        moved = false
        for _, s in ipairs(sessions) do
            if s.s < next_from and s.e >= next_from then
                next_from, moved = s.s, true
            end
        end
    until not moved
    local book_list = {}
    for _, b in pairs(books) do book_list[#book_list + 1] = b end
    return sessions, book_list, next_from
end

-- Progress and highlights of the books in the history ---------------------------------

-- The reading history, read from its file (ReadHistory itself may write it).
local function history()
    local ok, hist = pcall(dofile, DataStorage:getDataDir() .. "/history.lua")
    if ok and type(hist) == "table" then return hist end
    return {}
end

-- Where a highlight starts, the same on every run (a PDF's is a table).
local function anchor(q)
    local p = q.pos0 or q.page
    if type(p) == "table" then
        return string.format("%s:%s:%s", tostring(p.page), tostring(p.x), tostring(p.y))
    end
    return tostring(p or "")
end

-- Rows for the books whose status or place changed since `sent` (id -> mark),
-- every highlight of the books whose sidecar changed since `hl_seen`.
function Sync.history(by_path, sent, hl_seen)
    local Books = require("polka_books")
    local rows, marks, highlights, hl_now = {}, {}, {}, {}
    local done = {}
    local hist = history()
    for k, item in ipairs(hist) do
        local path = type(item) == "table" and str(item.file)
        if path and not done[path] and lfs.attributes(path, "mode") == "file" then
            done[path] = true
            if k % 20 == 0 then progress(string.format("Читаю заметки: %d из %d…", k, #hist)) end
            local sidecar = DocSettings:findSidecarFile(path)
            if sidecar then
                local ok, f = pcall(Books.finishInfo, Books, path)
                if ok and f then
                    local id = f.md5 or (by_path[path] and by_path[path].md5)
                    if id then
                        local row = {
                            id = id, status = f.status or "reading", percent = f.percent,
                            finished = f.status == "complete" and f.date or nil,
                            last_open = tonumber(item.time), pages = f.pages,
                        }
                        local mark = table.concat({ row.status, tostring(row.percent), row.finished or "",
                                                    tostring(row.last_open), tostring(row.pages) }, "|")
                        marks[id] = mark
                        if sent[id] ~= mark then rows[#rows + 1] = row end
                        local mtime = lfs.attributes(sidecar, "modification")
                        hl_now[path] = mtime
                        if hl_seen[path] ~= mtime then
                            local items = {}
                            for _, q in ipairs(f.quotes or {}) do
                                items[#items + 1] = {
                                    id = sha1(table.concat({ id, q.datetime or "", anchor(q), q.text }, "|")):sub(1, 20),
                                    text = q.text, note = q.note, chapter = q.chapter, page = q.pageno, at = q.datetime,
                                }
                            end
                            highlights[#highlights + 1] = { b = id, items = items }
                        end
                    end
                end
            end
        end
    end
    return rows, marks, highlights, hl_now
end

-- What the reader's card shows on the Kindle: goal, challenge, rank.
function Sync.card()
    local out = { goal = tonumber(G_reader_settings:readSetting("polka_goal")) or 24 }
    local ok, model = pcall(function()
        local Books = require("polka_books")
        if not Books.hist then Books:loadHistory() end
        local Stats = require("polka_stats")
        return require("polka_achievements").compute(Stats.compute())
    end)
    if ok and type(model) == "table" then
        local c = model.challenge
        if type(c) == "table" then
            out.challenge = { title = c.title, hint = c.hint, value = c.value, target = c.target,
                              unit = c.unit, done = c.done, binary = c.binary }
        end
        if type(model.rank) == "table" then out.rank = model.rank.name end
        out.badges = model.earned
        out.badges_total = type(model.badges) == "table" and #model.badges or nil
    elseif not ok then
        logger.warn("Polka web: card:", model)
    end
    return out
end

-- Covers ----------------------------------------------------------------------------

local function imageType(data)
    if data:sub(1, 2) == "\255\216" then return "image/jpeg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
    if data:sub(1, 3) == "GIF" then return "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "image/webp" end
end

-- Width and height of a JPEG from its frame header (no decoding).
local function jpegSize(data)
    local i, n = 3, #data
    while i + 8 <= n do
        if data:byte(i) ~= 0xFF then return nil end
        local marker = data:byte(i + 1)
        if marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
            i = i + 2
        else
            local len = data:byte(i + 2) * 256 + data:byte(i + 3)
            if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local h = data:byte(i + 5) * 256 + data:byte(i + 6)
                local w = data:byte(i + 7) * 256 + data:byte(i + 8)
                return w, h
            end
            i = i + 2 + len
        end
    end
end

local function resolve(base_dir, href)
    href = href:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    local parts = {}
    for part in (base_dir .. href):gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end

-- An entry of an archive, unless it is too big to hold in memory.
local function extract(arc, key)
    local e = arc.entries and arc.entries[key]
    if not e or tonumber(e.size or 0) > MAX_ENTRY then return nil end
    return arc:extractToMemory(key)
end

-- The cover image stored in an EPUB, as it is (in colour).
local function epubCover(path)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(path) then return nil end
    local ok, data = pcall(function()
        for _ in arc:iterate() do end -- index the entries
        local container = extract(arc, "META-INF/container.xml")
        local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
        local opf = opf_path and extract(arc, opf_path)
        if not opf then return nil end
        local dir = opf_path:match("^(.*/)") or ""
        local items = {}
        for tag in opf:gmatch("<[%w:]*item%s[^>]*>") do
            items[#items + 1] = {
                id = tag:match('%sid%s*=%s*"([^"]*)"'), href = tag:match('href%s*=%s*"([^"]*)"'),
                media = tag:match('media%-type%s*=%s*"([^"]*)"') or "", props = tag:match('properties%s*=%s*"([^"]*)"') or "",
            }
        end
        local href
        for _, it in ipairs(items) do
            if (" " .. it.props .. " "):find(" cover%-image ") then href = it.href break end
        end
        if not href then
            local cover_id
            for tag in opf:gmatch("<[%w:]*meta%s[^>]*>") do
                if tag:match('name%s*=%s*"cover"') then cover_id = tag:match('content%s*=%s*"([^"]*)"') end
            end
            for _, it in ipairs(items) do
                if cover_id and it.id == cover_id then href = it.href break end
            end
        end
        if not href then
            for _, it in ipairs(items) do
                if it.media:match("^image/") and ((it.id or ""):lower():find("cover") or (it.href or ""):lower():find("cover")) then
                    href = it.href
                    break
                end
            end
        end
        if not href then return nil end
        return extract(arc, resolve(dir, href))
    end)
    arc:close()
    if ok then return data end
end

-- The cover inside an FB2 (base64 in a <binary>); a zipped FB2 is unpacked first.
local function fb2Cover(path, zipped)
    local text
    if zipped then
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        if not arc:open(path) then return nil end
        pcall(function()
            for entry in arc:iterate() do
                if entry.mode == "file" and entry.path:lower():match("%.fb2$") then
                    if tonumber(entry.size or 0) <= MAX_FB2 then text = arc:extractToMemory(entry.path) end
                    break
                end
            end
        end)
        arc:close()
    else
        if (lfs.attributes(path, "size") or 0) > MAX_FB2 then return nil end
        local f = io.open(path, "rb")
        if not f then return nil end
        text = f:read("*a")
        f:close()
    end
    if not text then return nil end
    local cover = text:match("<[%w:]*coverpage>(.-)</[%w:]*coverpage>")
    local id = cover and cover:match('href%s*=%s*"#([^"]+)"')
    if not id then return nil end
    local b64 = text:match('<binary[^>]-id%s*=%s*"' .. id:gsub("%p", "%%%0") .. '"[^>]*>(.-)</binary>')
    if not b64 then return nil end
    return require("ffi/sha2").base64_to_bin((b64:gsub("%s+", "")))
end

-- A JPEG taller than COVER_H, scaled down (a 2000-pixel cover is 1 MB and
-- the site shows it 300 pixels wide); anything else as it is.
local function shrink(data)
    if imageType(data) ~= "image/jpeg" then return data end
    local w, h = jpegSize(data)
    if not w or not h or w * h > MAX_PIXELS then return nil end -- too big to decode here
    if h <= COVER_H then return data end
    local tmp = DataStorage:getSettingsDir() .. "/polka_web_cover.jpg"
    local ok, small = pcall(function()
        local Jpeg = require("ffi/jpeg")
        local bb = Jpeg.openDocumentFromMem(data, true)
        local tw = math.max(1, math.floor(bb:getWidth() * COVER_H / bb:getHeight() + 0.5))
        local scaled = require("ui/renderimage"):scaleBlitBuffer(bb, tw, COVER_H, true)
        scaled:writeJPG(tmp, 82)
        scaled:free()
        local out = util.readFromFile(tmp, "rb")
        os.remove(tmp)
        return out
    end)
    if ok and small and #small > 0 and #small < #data then return small end
    if not ok then logger.warn("Polka web: shrinking a cover:", small) end
    return data
end

function Sync.cover(file)
    local data
    if file.ext == "epub" then data = epubCover(file.path)
    elseif file.ext == "fb2" or file.ext == "fbz" then
        data = fb2Cover(file.path, file.ext == "fbz" or file.name:lower():match("%.zip$"))
    end
    if data and imageType(data) then data = shrink(data) end
    -- (no cover for other formats: the thumbnails KOReader keeps are small and
    -- grey, and live in a database this process must not open)
    if data and imageType(data) and #data <= MAX_COVER_BYTES then return data end
end

-- Books from the site ---------------------------------------------------------------

-- Downloads one book next to its shelf as a hidden file; returns that file
-- and the shelf folder, or nil and why ("later": the site does not have the
-- file in this part of the world yet, or the connection broke).
local function saveBook(cfg, it, on_bytes)
    local Tools = require("polka_tools")
    local ffiutil = require("ffi/util")
    local dir = Tools.shelfDir(str(it.shelf) or "")
    local part = dir .. "/.polka-site-" .. it.id .. ".part"
    os.remove(part)
    local total = 0
    for n = 0, (tonumber(it.parts) or 1) - 1 do
        local fh = io.open(part, "ab")
        if not fh then return nil, "нет доступа к папке с книгами" end
        local write_err
        local function sink(chunk)
            if chunk then
                if not fh:write(chunk) then
                    write_err = true
                    return nil, "write"
                end
                total = total + #chunk
                on_bytes(total)
            end
            return 1
        end
        local code = request(cfg, "GET", "/api/device/file/" .. it.id .. "/" .. n, nil, nil, sink, { 20, 600 })
        -- on the card for real before the site is told it may forget the file
        if not write_err and not fh:flush() then write_err = true end
        if not write_err then pcall(ffiutil.fsyncOpenedFile, fh) end
        if not fh:close() then write_err = true end
        if write_err then
            os.remove(part)
            return nil, "не хватает места на Kindle"
        end
        if code ~= 200 then
            os.remove(part)
            return nil, (code == 503 or type(code) ~= "number") and "later" or "download"
        end
    end
    if tonumber(it.size) and lfs.attributes(part, "size") ~= tonumber(it.size) then
        os.remove(part)
        return nil, "later"
    end
    return part, nil, dir
end

-- The shelf of a path inside the books folder ("" for none).
local function shelfOf(root, path)
    local rel = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or nil
    return rel and rel:match("^([^/]+)/") or ""
end

-- The whole sync ------------------------------------------------------------------------

local function timezone()
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    return os.difftime(now, os.time(utc))
end

-- Everything that changed, as posts of about POST_BYTES; the library list in
-- parts of its own, the last part with every id in it.
local function posts(ctx)
    local out = {}
    local cur, size
    local function add(field, item, bytes)
        if not cur or (size + bytes > POST_BYTES and size > 0) then
            cur, size = { v = 1 }, 0
            out[#out + 1] = cur
        end
        cur[field] = cur[field] or {}
        table.insert(cur[field], item)
        size = size + bytes
    end
    for _, b in ipairs(ctx.stat_books) do add("stat_books", b, 200) end
    for _, p in ipairs(ctx.progress) do add("progress", p, 150) end
    for _, s in ipairs(ctx.sessions) do add("sessions", s, 110) end
    for _, g in ipairs(ctx.highlights) do
        local bytes = 60
        for _, q in ipairs(g.items) do
            bytes = bytes + 120 + #q.text + #(q.note or "") + #(q.chapter or "")
        end
        add("highlights", { b = g.b, items = list(g.items) }, bytes)
    end
    for _, p in ipairs(out) do
        for _, k in ipairs({ "stat_books", "progress", "sessions", "highlights" }) do
            if p[k] then p[k] = list(p[k]) end
        end
    end
    if ctx.send_list then
        local n = #ctx.lib
        local parts = math.max(1, math.ceil(n / LIST_PER_POST))
        for p = 1, parts do
            local chunk = {}
            for i = (p - 1) * LIST_PER_POST + 1, math.min(n, p * LIST_PER_POST) do chunk[#chunk + 1] = ctx.lib[i] end
            local books = { hash = ctx.lib_hash, part = p, parts = parts, list = list(chunk) }
            if p == parts and parts > 1 then
                local ids = {}
                for _, b in ipairs(ctx.lib) do ids[#ids + 1] = b.id end
                books.ids = list(ids)
            end
            out[#out + 1] = { v = 1, books = books }
        end
    end
    return out
end

-- What changed since the last sync (`full`: everything, for a site that lost it).
local function collect(state, root, full)
    local files = Sync.scan(root)
    local md5_cache = Sync.identify(files, state:readSetting("md5") or {})
    local by_path, by_id = {}, {}
    for _, f in ipairs(files) do
        by_path[f.path] = f
        if f.md5 then by_id[f.md5] = f end
    end
    local lib, lib_hash = Sync.library(files)
    local stats_from = full and 0 or tonumber(state:readSetting("stats_from")) or 0
    local sessions, stat_books, next_from = Sync.sessions(stats_from)
    local progress_rows, marks, highlights, hl_now = Sync.history(by_path,
        full and {} or (state:readSetting("prog") or {}), full and {} or (state:readSetting("hl") or {}))
    local nq, newest = 0, 0
    for _, g in ipairs(highlights) do nq = nq + #g.items end
    for _, s in ipairs(sessions) do if s.s > newest then newest = s.s end end
    return {
        by_path = by_path, by_id = by_id, md5_cache = md5_cache,
        lib = lib, lib_hash = lib_hash, send_list = full or lib_hash ~= state:readSetting("books_hash"),
        sessions = sessions, stat_books = stat_books, next_from = next_from, newest = newest,
        progress = progress_rows, marks = marks, highlights = highlights, hl_now = hl_now, quotes = nq,
    }
end

-- Places in books reached here since the last sync (polka_places keeps them;
-- this process only reads its file).
local function pendingPlaces(path)
    local out, sent = {}, {}
    if not path or lfs.attributes(path, "mode") ~= "file" then return out, sent end
    local ok, err = pcall(function()
        local s = LuaSettings:open(path)
        local mine = s:readSetting("mine") or {}
        for id in pairs(s:readSetting("pending") or {}) do
            local p = mine[id]
            if type(p) == "table" and tonumber(p.t) then
                out[#out + 1] = { id = id, t = math.floor(p.t), percent = tonumber(p.percent),
                                  spine = tonumber(p.spine), frac = tonumber(p.frac), xp = str(p.xp) }
                sent[id] = math.floor(p.t)
            end
        end
    end)
    if not ok then logger.warn("Polka web: places:", err) end
    return out, sent
end

-- Places from the card's other readers, as much as is worth keeping.
local function remotePlaces(list)
    local out = {}
    for _, p in ipairs(type(list) == "table" and list or {}) do
        if type(p) == "table" and type(p.id) == "string" and tonumber(p.t) then
            out[#out + 1] = {
                id = p.id, device = str(p.device), kind = str(p.kind), t = tonumber(p.t),
                percent = tonumber(p.percent), spine = tonumber(p.spine), frac = tonumber(p.frac),
                xp = str(p.xp), cp = str(p.cp),
            }
        end
        if #out >= 50 then break end
    end
    return out
end

function Sync.run(cfg)
    local started = os.time()
    local state = LuaSettings:open(Sync.STATE)
    local result = { at = started, ok = false, token_hash = sha1(cfg.token) }
    local function finish()
        result.took = os.time() - started
        state:saveSetting("last", result)
        state:flush()
        return result
    end

    progress("Собираю, что изменилось…")
    local Books = require("polka_books")
    local root = Books.getRoot():gsub("/+$", "")

    -- 1. Hello: what the site has; where this Kindle stopped in its books and
    --    where the card's other readers did.
    local places, places_sent = pendingPlaces(cfg.places)
    local hello, err, code = postJSON(cfg, "/api/device/sync", {
        v = 1,
        device = {
            model = require("device").model, koreader = require("version"):getCurrentRevision(),
            polka = cfg.version, root = root, tz = timezone(),
        },
        settings = Sync.card(),
        no_cover = list(state:readSetting("no_cover") or {}),
        positions_since = tonumber(state:readSetting("positions_since")) or 0,
        positions = #places > 0 and list(places) or nil,
    })
    if not hello then
        result.error = err
        result.unauthorized = code == 401 or nil
        return finish()
    end
    state:saveSetting("no_cover", {})
    result.card = tonumber(hello.card)
    if tonumber(hello.time) then
        state:saveSetting("positions_since", math.floor(hello.time))
        result.positions = remotePlaces(hello.positions)
        result.positions_time = math.floor(hello.time)
        result.positions_sent = places_sent
    end
    state:flush()
    local latest = hello

    -- 2. What changed — or everything, if the site lost what it had (a new
    --    database, or one restored from an earlier day).
    local saved_hash = state:readSetting("books_hash")
    local sent_max = tonumber(state:readSetting("sent_max")) or 0
    local full = (saved_hash ~= nil and hello.books_hash ~= saved_hash)
        or (sent_max > 0 and (tonumber(hello.sessions_max) or 0) < sent_max)
    if full then logger.info("Polka web: the site does not have all our data, sending everything") end
    local ctx = collect(state, root, full)
    local list_posts = posts(ctx)
    local done_text
    if ctx.quotes > 0 then
        done_text = string.format("Отправил %d %s", ctx.quotes, plural(ctx.quotes, "цитату", "цитаты", "цитат"))
    else
        done_text = "Отправил статистику"
    end
    local data_err
    for k, payload in ipairs(list_posts) do
        local what = ctx.quotes > 0 and string.format("Отправляю %d %s", ctx.quotes, plural(ctx.quotes, "цитату", "цитаты", "цитат"))
                     or "Отправляю статистику"
        progress(#list_posts > 1 and string.format("%s… %d из %d", what, k, #list_posts) or what .. "…")
        local resp, data_code
        resp, data_err, data_code = postJSON(cfg, "/api/device/sync", payload)
        if not resp then
            if data_code == 401 then
                result.unauthorized = true
                result.error = data_err
                return finish()
            end
            break
        end
        latest = resp
    end
    if not data_err then
        -- Everything above is on the site now.
        state:saveSetting("stats_from", ctx.next_from)
        state:saveSetting("sent_max", math.max(sent_max, ctx.newest))
        state:saveSetting("hl", ctx.hl_now)
        state:saveSetting("prog", ctx.marks)
        state:saveSetting("books_hash", ctx.lib_hash)
        result.sent = { sessions = #ctx.sessions, highlights = ctx.quotes, books = ctx.send_list and #ctx.lib or 0 }
    else
        done_text = "Не всё отправил"
    end
    state:saveSetting("md5", ctx.md5_cache)
    state:flush()

    -- 3. Books uploaded on the site (even when the statistics did not go through).
    local inbox = type(latest.inbox) == "table" and latest.inbox or {}
    local unacked = state:readSetting("unacked") or {}
    local got, delivered = {}, 0
    for k, it in ipairs(inbox) do
        if type(it) == "table" and type(it.id) == "string" then
            local prefix = string.format("%s · скачиваю книгу %d из %d", done_text, k, #inbox)
            progress(prefix)
            local path, md5
            local before = unacked[it.id]
            if type(before) == "table" and before.path and lfs.attributes(before.path, "mode") == "file" then
                path, md5 = before.path, before.md5 -- saved last time, the site did not hear about it
            else
                local size = tonumber(it.size) or 0
                local shown = -1
                local part, why, dir = saveBook(cfg, it, function(bytes)
                    local pct = size > 0 and math.floor(bytes * 100 / size) or 0
                    if pct >= shown + 5 then
                        shown = pct
                        progress(string.format("%s · %d %%", prefix, pct))
                    end
                end)
                if part then
                    md5 = util.partialMD5(part)
                    local same = md5 and ctx.by_id[md5]
                    if same then
                        os.remove(part) -- this very book is already on the Kindle
                        path = same.path
                    else
                        local Tools = require("polka_tools")
                        path = Tools.uniquePath(dir, Tools.cleanName(str(it.name) or (it.id .. ".epub")))
                        if os.rename(part, path) then
                            pcall(require("ffi/util").fsyncDirectory, path)
                        else
                            os.remove(part)
                            path, why = nil, "не удалось сохранить файл"
                        end
                    end
                end
                if not path then
                    if why ~= "later" and why ~= "download" then
                        postJSON(cfg, "/api/device/ack", { id = it.id, ok = false, error = why })
                    end
                else
                    local attr = lfs.attributes(path) or {}
                    if md5 then
                        ctx.md5_cache[path] = { s = attr.size, m = attr.modification, h = md5 }
                        local name = path:match("([^/]+)$")
                        local lname = name:lower()
                        ctx.by_id[md5] = ctx.by_id[md5] or { path = path, md5 = md5, name = name,
                            ext = lname:match("%.([%w]+)%.zip$") or lname:match("%.([%w]+)$") }
                    end
                    got[#got + 1] = { title = str(it.title) or str(it.name) or "книга", shelf = shelfOf(root, path), path = path }
                    unacked[it.id] = { path = path, md5 = md5 }
                end
            end
            if path then
                delivered = delivered + 1
                local rel = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or path
                if postJSON(cfg, "/api/device/ack", { id = it.id, ok = true, path = rel, md5 = md5, shelf = shelfOf(root, path) }) then
                    unacked[it.id] = nil
                end
            end
        end
    end
    for id in pairs(unacked) do
        local still = false
        for _, it in ipairs(inbox) do if type(it) == "table" and it.id == id then still = true end end
        if not still then unacked[id] = nil end -- delivered, cancelled or removed on the site
    end
    state:saveSetting("unacked", unacked)
    state:saveSetting("md5", ctx.md5_cache)
    state:flush()
    result.downloaded = got
    result.waiting = math.max(0, (tonumber(latest.waiting) or #inbox) - delivered)

    -- 4. Covers the site does not have yet, a batch at a time.
    local queue = (not data_err and type(latest.need_covers) == "table") and latest.need_covers or {}
    local asked, no_cover, covers = {}, {}, 0
    local deadline = os.time() + COVER_SECONDS
    while #queue > 0 and covers < MAX_COVERS and os.time() < deadline do
        local fresh, stop = 0, false
        for _, id in ipairs(queue) do
            if covers >= MAX_COVERS or os.time() >= deadline then break end
            if type(id) == "string" and not asked[id] then
                asked[id] = true
                fresh = fresh + 1
                local f = ctx.by_id[id]
                local ok, data = true, nil
                if f and f.name then
                    progress(string.format("%s · отправляю обложки: %d", done_text, covers + 1))
                    ok, data = pcall(Sync.cover, f)
                end
                if ok and data then
                    local code, body = request(cfg, "PUT", "/api/device/cover/" .. id, data, imageType(data), nil, { 15, 120 })
                    local t = code == 200 and decode(body)
                    if t and t.ok == true then
                        covers = covers + 1
                    elseif code == 400 then
                        no_cover[#no_cover + 1] = id -- the site did not take it as an image
                    else
                        stop = true -- the site cannot store covers now (or is not the site)
                        break
                    end
                elseif ok then
                    no_cover[#no_cover + 1] = id -- no cover in this book, or the file is not here
                else
                    logger.warn("Polka web: cover of", f.path, data)
                end
            end
        end
        if stop or fresh == 0 or #queue < COVER_BATCH or covers >= MAX_COVERS or os.time() >= deadline then break end
        local more = postJSON(cfg, "/api/device/sync", { v = 1, no_cover = list(no_cover) })
        if not more then break end
        no_cover = {}
        queue = type(more.need_covers) == "table" and more.need_covers or {}
    end
    state:saveSetting("no_cover", no_cover)
    result.covers = covers

    result.ok = not data_err
    result.error = data_err
    return finish()
end

-- This process is a copy of KOReader: let go of what KOReader had open (a
-- Wi‑Fi upload page's sockets, databases…) and never write KOReader's files.
local function detach()
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int close(int fd);")
        local fds = {}
        for name in lfs.dir("/proc/self/fd") do
            local n = tonumber(name)
            if n and n > 2 then fds[#fds + 1] = n end
        end
        for _, n in ipairs(fds) do ffi.C.close(n) end
    end)
    if G_reader_settings then G_reader_settings.flush = function() end end
    pcall(function() require("readhistory")._flush = function() end end)
end

-- The forked process starts here; whatever happens, it leaves a result.
function Sync.main(cfg)
    detach()
    local ok, err = xpcall(Sync.run, debug.traceback, cfg)
    if not ok then
        logger.err("Polka web: sync failed:", err)
        pcall(function()
            local state = LuaSettings:open(Sync.STATE)
            state:saveSetting("last", { at = os.time(), ok = false, error = "что-то пошло не так (подробности в crash.log)" })
            state:flush()
        end)
    end
    os.remove(Sync.PROGRESS)
    os.remove(Sync.LOCK)
end

return Sync
