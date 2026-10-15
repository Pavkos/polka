--[[--
Polka: library data.

Scans the books folder (top-level folders become shelves), and merges what
KOReader already knows about each book: metadata and covers from the
CoverBrowser cache, progress and status from the book's sidecar, and
reading history. Nothing here writes to the books themselves.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local ReadHistory = require("readhistory")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local ok_bl, BookList = pcall(require, "ui/widget/booklist")
if not ok_bl then BookList = nil end

local Books = {
    records = nil,      -- array of book records from the last scan
    by_path = {},       -- path -> record
    shelves = nil,      -- array of { name, count, label }
    root = nil,
    meta = nil,         -- path -> { title, authors, has_cover }
    cover_cache = {},   -- "path|WxH" -> bb or false
    cover_keys = {},    -- insertion order, for eviction
    pending = {},       -- path -> cover specs waiting for extraction
    requested = {},     -- path -> true once extraction was asked this session
    generation = 0,     -- bumped whenever books or their sidecars may have changed
}

local BOOK_EXT = {
    epub = true, fb2 = true, fbz = true, fb3 = true, mobi = true, azw = true, azw3 = true, prc = true,
    pdf = true, djvu = true, djv = true, cbz = true, cbr = true, cb7 = true, cbt = true,
    rtf = true, txt = true, md = true, docx = true, doc = true, odt = true, chm = true, pdb = true,
    xps = true, oxps = true, htm = true, html = true, htmlz = true,
}
-- Zipped single books KOReader opens directly ("name.fb2.zip").
local ZIPPED = { fb2 = true, epub = true, txt = true, rtf = true, md = true, htm = true, html = true }

-- Folders that never hold books on a Kindle/KOReader setup.
local SKIP_DIRS = {
    koreader = true, system = true, extensions = true, dictionaries = true, fonts = true,
    screensavers = true, linkss = true, linkfonts = true, mrpackages = true, kual = true,
    libkh = true, usbnet = true, backups = true, audible = true, ["lost+found"] = true,
    ["$recycle.bin"] = true, ["system volume information"] = true, voice = true,
}

local function currentYear()
    return tonumber(os.date("%Y"))
end

-- Helpers -------------------------------------------------------------------

local function isDir(p)
    return p and lfs.attributes(p, "mode") == "directory"
end

-- util.stringLower appeared after KOReader 2025.04; the same thing by hand there.
local lower = util.stringLower or function(s)
    return require("ffi/utf8proc").lowercase(util.fixUtf8(s, "?"))
end

local function sortKey(s)
    s = lower(s or "") or ""
    return (s:gsub("ё", "е"))
end

function Books.sortKey(s) return sortKey(s) end

-- A book by its name alone (also used for files sent over Wi‑Fi or downloaded).
function Books.isBookName(name)
    local lname = tostring(name or ""):lower()
    local ext = lname:match("%.([%w]+)$")
    if not ext then return false end
    if ext == "zip" then
        local inner = lname:match("%.([%w]+)%.zip$")
        if not (inner and ZIPPED[inner]) then return false end
    elseif not BOOK_EXT[ext] then
        return false
    end
    return DocumentRegistry:hasProvider(lname)
end

local function isBookFile(name, path)
    return Books.isBookName(name) and DocumentRegistry:hasProvider(path)
end

-- "Автор - Название.fb2.zip" -> "Автор", "Название"
local function parseFilename(name)
    -- "x.fb2.zip" loses both, "x.epub" one; "Толстой Л.Н. - …" keeps its dots
    local base = name:match("^(.-)%.[%w]+%.[zZ][iI][pP]$") or name:match("^(.*)%.[^%.]+$") or name
    base = base:gsub("_", " ")
    local author, title = base:match("^(.-)%s+[%-–—]%s+(.+)$")
    if author and title and #author > 0 then
        return title, author
    end
    return base, nil
end

-- Root folder ---------------------------------------------------------------

local function isStorageRoot(p)
    if not p then return true end
    p = p:gsub("/+$", "")
    return p == "" or p == "/mnt/us" or p == "/mnt/onboard" or p == "/mnt/ext1" or p == "/storage/emulated/0"
end

function Books.getRoot()
    local root = G_reader_settings:readSetting("polka_root")
    if isDir(root) then return root end
    local home = G_reader_settings:readSetting("home_dir")
    if isDir(home) and not isStorageRoot(home) then return home end
    for _, p in ipairs({ "/mnt/us/Books", "/mnt/us/books", "/mnt/us/documents", "/mnt/onboard/Books" }) do
        if isDir(p) then return p end
    end
    if isDir(home) then return home end
    return Device.home_dir or lfs.currentdir()
end

-- Scanning ------------------------------------------------------------------

-- Directories walked by the last scan with their modification times. When
-- none changed, the previous walk is reused (adding or removing a file
-- changes its folder's time), which keeps reopening the shell cheap.
function Books:dirsUnchanged(root)
    if self._scan_root ~= root or not self._dirs or not self.records then return false end
    for dir, mtime in pairs(self._dirs) do
        if lfs.attributes(dir, "modification") ~= mtime then return false end
    end
    return true
end

function Books:scan()
    local root = Books.getRoot():gsub("/+$", "")
    self.root = root
    self.generation = self.generation + 1
    if self:dirsUnchanged(root) then
        for _, rec in pairs(self.by_path) do -- includes history books outside the root
            rec._info, rec._progress = nil, nil
        end
        self:loadMeta()
        self:loadHistory()
        return self.records
    end
    local records, by_path = {}, {}
    local counts, order = {}, {}
    local dirs = {}

    local function walk(dir, mtime, shelf, depth)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        dirs[dir] = mtime
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if depth < 6 and not name:match("%.sdr$") and not SKIP_DIRS[name:lower()] then
                        walk(path, attr.modification, shelf or name, depth + 1)
                    end
                elseif attr and attr.mode == "file" and isBookFile(name, path) then
                    local rec = {
                        path = path, name = name, dir = dir, shelf = shelf,
                        mtime = attr.modification or 0,
                    }
                    records[#records + 1] = rec
                    by_path[path] = rec
                    local key = shelf or ""
                    if not counts[key] then
                        counts[key] = 0
                        order[#order + 1] = key
                    end
                    counts[key] = counts[key] + 1
                end
            end
        end
    end
    walk(root, lfs.attributes(root, "modification"), nil, 0)

    local shelves = {}
    for _, key in ipairs(order) do
        shelves[#shelves + 1] = {
            name = key ~= "" and key or nil,
            label = key ~= "" and key or "Без полки",
            count = counts[key],
        }
    end
    table.sort(shelves, function(a, b)
        if (a.name == nil) ~= (b.name == nil) then return a.name ~= nil end
        return sortKey(a.label) < sortKey(b.label)
    end)

    self.records, self.by_path, self.shelves = records, by_path, shelves
    self._scan_root, self._dirs = root, dirs
    self:loadMeta()
    self:loadHistory()
    return records
end

-- Metadata ------------------------------------------------------------------

function Books:bim()
    if self._bim == nil then
        local ok, BIM = pcall(require, "bookinfomanager")
        self._bim = ok and BIM or false
    end
    return self._bim or nil
end

-- One query for the whole cache instead of one per book. Rows of books whose
-- extraction was interrupted are remembered too (see requestExtraction).
function Books:loadMeta()
    local meta, tries = {}, {}
    local BIM = self:bim()
    if BIM then
        local ok, err = pcall(function()
            BIM:openDbConnection()
            local res, n = BIM.db_conn:exec(
                "SELECT directory, filename, title, authors, has_cover, ignore_meta, in_progress, series, series_index, language FROM bookinfo")
            if res and n and n > 0 then
                for i = 1, n do
                    local path = (res[1][i] or "") .. (res[2][i] or "")
                    local in_progress = tonumber(res[7][i]) or 0
                    if in_progress > 0 then
                        tries[path] = in_progress
                    elseif res[6][i] ~= "Y" then
                        -- (series and language are for the site sync, polka_websync)
                        meta[path] = { title = res[3][i], authors = res[4][i], has_cover = res[5][i] == "Y",
                                       series = res[8][i], series_index = tonumber(res[9][i]), lang = res[10][i] }
                    else
                        meta[path] = { has_cover = res[5][i] == "Y" }
                    end
                end
            end
        end)
        if not ok then logger.warn("Polka: cannot read cover cache:", err) end
    end
    self.meta, self.tries = meta, tries
end

function Books:loadHistory()
    pcall(ReadHistory.reload, ReadHistory)
    local last_read, hist = {}, {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        if item.file and not item.dim and lfs.attributes(item.file, "mode") == "file" then
            if not last_read[item.file] then
                last_read[item.file] = item.time
                hist[#hist + 1] = item.file
            end
        end
    end
    self.last_read, self.hist = last_read, hist
end

-- Returns a record for any path (even outside the books folder).
function Books:record(path)
    local rec = self.by_path[path]
    if not rec then
        local dir, name = util.splitFilePathName(path)
        rec = { path = path, name = name, dir = dir:gsub("/$", ""), mtime = lfs.attributes(path, "modification") or 0 }
        self.by_path[path] = rec
    end
    return rec
end

-- Title, authors and sort keys from the CoverBrowser cache or the file name.
-- Cheap: no file is opened.
function Books:brief(rec)
    if not rec._info then
        local m = self.meta and self.meta[rec.path]
        local title, authors = m and m.title, m and m.authors
        if not title or title == "" then
            local ftitle, fauthor = parseFilename(rec.name)
            title = ftitle
            authors = (authors and authors ~= "") and authors or fauthor
        end
        if authors then
            authors = authors:gsub("\n", ", ")
        end
        rec.title, rec.authors = title, authors
        rec.key_title = sortKey(title)
        rec.key_author = authors and authors ~= "" and sortKey(authors) or "\255"
        rec.key_name = sortKey(rec.name)
        rec.has_cover = m and m.has_cover
        rec.last_read = self.last_read and self.last_read[rec.path]
        rec._info = true
    end
    return rec
end

-- brief() plus status and progress from the book's sidecar. The sidecar is read
-- once per KOReader session (KOReader's own BookList cache, which KOReader
-- updates itself when a book is closed), so call it for books on screen.
function Books:info(rec)
    self:brief(rec)
    if not rec._progress then
        local status, percent = "new", nil
        if BookList then
            local ok, bi = pcall(BookList.getBookInfo, rec.path)
            if ok and bi and bi.been_opened then
                status = bi.status or "reading"
                percent = bi.percent_finished
            end
        elseif DocSettings:hasSidecarFile(rec.path) then
            local ds = DocSettings:open(rec.path)
            local summary = ds:readSetting("summary")
            status = summary and summary.status or "reading"
            percent = ds:readSetting("percent_finished")
        end
        if status == "complete" then percent = 1 end
        rec.status, rec.percent = status, percent
        rec._progress = true
    end
    return rec
end

-- Forget cached progress (after a status change, or when coming back from a book).
function Books:invalidate(path)
    self.generation = self.generation + 1
    -- FAT keeps file times to 2 s: a quick second change could look unchanged.
    if path and self._finish then self._finish[path] = nil end
    local rec = path and self.by_path[path]
    if rec then
        rec._progress = nil
    end
    if BookList and path then pcall(BookList.resetBookInfoCache, path) end
end

-- Current and recent books ----------------------------------------------------

function Books:current()
    local hist = self.hist or {}
    for _, path in ipairs(hist) do
        local rec = self:info(self:record(path))
        if rec.status ~= "complete" then return rec end
    end
    if hist[1] then return self:info(self:record(hist[1])) end
end

function Books:recent(limit, exclude)
    local out = {}
    for _, path in ipairs(self.hist or {}) do
        if path ~= exclude then
            out[#out + 1] = self:info(self:record(path))
            if #out >= limit then break end
        end
    end
    return out
end

-- Library listing -----------------------------------------------------------

Books.SORTS = {
    { id = "recent", label = "Недавние" },
    { id = "title", label = "Название" },
    { id = "author", label = "Автор" },
    { id = "added", label = "Новые файлы" },
    { id = "progress", label = "Прогресс" },
}

function Books:list(shelf, sort_id, query)
    local out = {}
    local q = query and query ~= "" and sortKey(query) or nil
    for _, rec in ipairs(self.records or {}) do
        if shelf == nil or shelf == "*" or rec.shelf == shelf or (shelf == "" and rec.shelf == nil) then
            self:brief(rec)
            if not q or rec.key_title:find(q, 1, true) or rec.key_author:find(q, 1, true)
                    or rec.key_name:find(q, 1, true) then
                out[#out + 1] = rec
            end
        end
    end
    local function byTitle(a, b)
        if a.key_title ~= b.key_title then return a.key_title < b.key_title end
        return a.path < b.path
    end
    if sort_id == "title" then
        table.sort(out, byTitle)
    elseif sort_id == "author" then
        table.sort(out, function(a, b)
            if a.key_author ~= b.key_author then return a.key_author < b.key_author end
            return byTitle(a, b)
        end)
    elseif sort_id == "added" then
        table.sort(out, function(a, b)
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return byTitle(a, b)
        end)
    elseif sort_id == "progress" then
        for _, rec in ipairs(out) do self:info(rec) end -- needs every sidecar (once per session)
        local rank = { reading = 1, abandoned = 2, new = 3, complete = 4 }
        table.sort(out, function(a, b)
            local ra, rb = rank[a.status] or 3, rank[b.status] or 3
            if ra ~= rb then return ra < rb end
            if ra == 1 and (a.percent or 0) ~= (b.percent or 0) then return (a.percent or 0) > (b.percent or 0) end
            return byTitle(a, b)
        end)
    else -- recent: read books by last opening, then the rest by date added
        table.sort(out, function(a, b)
            local ta, tb = a.last_read, b.last_read
            if ta and tb then return ta > tb end
            if ta or tb then return ta ~= nil end
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return byTitle(a, b)
        end)
    end
    return out
end

-- What the book's sidecar says about its status, when it was last set (for
-- finished books: the day it was finished), its language, size, checksum
-- and its highlights (for the quotes screen). Parsed once and kept until
-- the sidecar file changes.
function Books:finishInfo(path)
    self._finish = self._finish or {}
    local sidecar = DocSettings:findSidecarFile(path)
    local mtime = sidecar and lfs.attributes(sidecar, "modification")
    local c = self._finish[path]
    if not c or c.mtime ~= mtime then
        c = { mtime = mtime }
        if sidecar then
            local ok, ds = pcall(DocSettings.open, DocSettings, path)
            if ok and ds then
                local summary = ds:readSetting("summary")
                c.status = type(summary) == "table" and summary.status or nil
                c.percent = tonumber(ds:readSetting("percent_finished"))
                local modified = type(summary) == "table" and summary.modified
                c.date = type(modified) == "string" and modified:match("^%d%d%d%d%-%d%d%-%d%d") or nil
                c.year = c.date and tonumber(c.date:sub(1, 4))
                local props = ds:readSetting("doc_props")
                if type(props) == "table" then
                    c.lang = type(props.language) == "string" and props.language or nil
                    c.authors = type(props.authors) == "string" and props.authors or nil
                end
                local stats = ds:readSetting("stats")
                c.pages = tonumber(ds:readSetting("doc_pages")) or (type(stats) == "table" and tonumber(stats.pages)) or nil
                c.md5 = ds:readSetting("partial_md5_checksum")
                c.quotes = Books.quotesFrom(ds:readSetting("annotations"))
            end
        end
        self._finish[path] = c
    end
    return c
end

-- Highlights (with their notes) from a sidecar's "annotations"; page
-- bookmarks without text are not quotes.
function Books.quotesFrom(annotations)
    if type(annotations) ~= "table" then return nil end
    local out = {}
    for i, a in ipairs(annotations) do
        if type(a) == "table" and a.drawer and type(a.text) == "string" and a.text:match("%S") then
            out[#out + 1] = {
                text = a.text,
                note = type(a.note) == "string" and a.note:match("%S") and a.note or nil,
                chapter = type(a.chapter) == "string" and a.chapter or nil,
                datetime = type(a.datetime) == "string" and a.datetime or "",
                page = a.page, pos0 = a.pos0, pos1 = a.pos1, pageno = tonumber(a.pageno),
                order = i,
            }
        end
    end
    return out
end

-- Every book from the reading history marked as finished, the most recently
-- finished first: { path, date = "YYYY-MM-DD" or nil, info = finishInfo }.
-- Checked again only when books may have changed (a new scan, a status change).
function Books:finished()
    if self._fin_list and self._fin_gen == self.generation then
        return self._fin_list
    end
    local out = {}
    for i, path in ipairs(self.hist or {}) do
        local f = self:finishInfo(path)
        if f.status == "complete" then
            out[#out + 1] = { path = path, date = f.date, info = f, order = i }
        end
    end
    table.sort(out, function(a, b)
        if a.date ~= b.date then
            if a.date and b.date then return a.date > b.date end
            return a.date ~= nil
        end
        return a.order < b.order -- same day: the one opened last first
    end)
    self._fin_list, self._fin_gen = out, self.generation
    return out
end

-- How many books were marked as read this year.
function Books:finishedThisYear()
    local n, year = 0, currentYear()
    for _, f in ipairs(self:finished()) do
        if f.info.year == year then n = n + 1 end
    end
    return n
end

-- Idle work: reads a few more history sidecars ahead of the statistics
-- screen. Returns true while some remain.
function Books:warmFinished(count)
    local hist = self.hist or {}
    if self._warm_gen ~= self.generation then
        self._warm_gen, self._warm_pos = self.generation, 1
    end
    local last = math.min(#hist, self._warm_pos + count - 1)
    for i = self._warm_pos, last do
        self:finishInfo(hist[i])
    end
    self._warm_pos = last + 1
    return self._warm_pos <= #hist
end

-- Statistics for one book (reading time and pages from the statistics plugin).
function Books:readingStats(rec)
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db, "mode") ~= "file" then return nil end
    self._md5 = self._md5 or {}
    local md5 = self._md5[rec.path]
    if not md5 then
        md5 = util.partialMD5(rec.path)
        if not md5 then return nil end
        self._md5[rec.path] = md5
    end
    local ok, res = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db, "ro")
        local stmt = conn:prepare("SELECT total_read_time, total_read_pages, pages FROM book WHERE md5 = ? ORDER BY last_open DESC LIMIT 1")
        local row = stmt:bind(md5):step()
        local r
        if row then
            r = { time = tonumber(row[1]) or 0, pages_read = tonumber(row[2]) or 0, pages = tonumber(row[3]) or 0 }
        end
        stmt:close()
        conn:close()
        return r
    end)
    if ok then return res end
end

-- Estimated time to finish, from this book's own reading pace.
function Books:timeLeft(rec)
    local pct = rec.percent
    if not pct or pct <= 0 or pct >= 1 then return nil end
    local s = self:readingStats(rec)
    if not s or s.pages_read < 5 or s.time <= 0 or s.pages <= 0 then return nil end
    local per_page = s.time / s.pages_read
    return math.max(60, (1 - pct) * s.pages * per_page)
end

-- Covers --------------------------------------------------------------------

local MAX_COVERS = 48

-- Least-recently-used order of cache keys (at most MAX_COVERS, so linear scans are fine).
local function touch(self, key)
    local keys = self.cover_keys
    for i = #keys, 1, -1 do
        if keys[i] == key then
            table.remove(keys, i)
            break
        end
    end
    keys[#keys + 1] = key
end

-- Cached covers are only forgotten here, never freed: a widget on screen may
-- still be drawing one. Their GC finalizer frees them; freeCovers() frees the
-- rest once the shell (and every widget using them) is gone.
function Books:cacheCover(key, bb)
    self.cover_cache[key] = bb
    touch(self, key)
    while #self.cover_keys > MAX_COVERS do
        local old = table.remove(self.cover_keys, 1)
        self.cover_cache[old] = nil
    end
end

function Books:dropCovers(path)
    local prefix = path .. "|"
    local keys = self.cover_keys
    for i = #keys, 1, -1 do
        if keys[i]:sub(1, #prefix) == prefix then
            self.cover_cache[keys[i]] = nil
            table.remove(keys, i)
        end
    end
end

-- Returns a blitbuffer that fits w x h (aspect kept), or nil (use a placeholder).
-- A cached thumbnail smaller than w x h is simply scaled up: re-extracting it
-- in the background could be interrupted when the book is opened.
function Books:cover(path, w, h)
    local key = path .. "|" .. w .. "x" .. h
    local cached = self.cover_cache[key]
    if cached ~= nil then
        touch(self, key)
        return cached or nil
    end
    local BIM = self:bim()
    if not BIM then return nil end
    local ok, info = pcall(BIM.getBookInfo, BIM, path, true)
    if not ok then
        logger.warn("Polka: getBookInfo failed for", path, info)
        return nil
    end
    if not info then
        self:requestExtraction(path, w, h)
        return nil
    end
    if info.cover_bb and info.ignore_cover ~= "Y" then
        local cw, ch = BIM.getCachedCoverSize(info.cover_w, info.cover_h, w, h)
        local bb = RenderImage:scaleBlitBuffer(info.cover_bb, cw, ch, true)
        self:cacheCover(key, bb)
        return bb
    end
    if info.cover_bb then info.cover_bb:free() end
    self:cacheCover(key, false)
    return nil
end

-- CoverBrowser gives up on a book after 3 interrupted attempts (opening a
-- book stops its background job). Polka leaves the last attempt to it.
function Books:requestExtraction(path, w, h)
    if self.requested[path] then return end
    if self.tries and (self.tries[path] or 0) >= 2 then return end
    local cur = self.pending[path]
    if not cur or cur.max_cover_w < w then
        self.pending[path] = { max_cover_w = w, max_cover_h = h }
    end
end

-- Hands queued books to CoverBrowser's background extractor, then polls the
-- cache and calls on_update() when new covers arrive.
function Books:flushExtraction(on_update)
    local BIM = self:bim()
    if not BIM or not next(self.pending) then return end
    -- Never interrupt an extraction already running (CoverBrowser's or ours):
    -- books interrupted three times end up marked as unreadable.
    if BIM:isExtractingInBackground() then
        if not self._retry then
            self._retry = function()
                self._retry = nil
                local ok_retry, err = pcall(self.flushExtraction, self, on_update)
                if not ok_retry then logger.warn("Polka: cover extraction:", err) end
            end
            UIManager:scheduleIn(3, self._retry)
        end
        return
    end
    local files = {}
    for path, specs in pairs(self.pending) do
        files[#files + 1] = { filepath = path, cover_specs = specs }
        self.requested[path] = true
    end
    self.pending = {}
    if #files == 0 then return end
    local ok, started = pcall(BIM.extractInBackground, BIM, files)
    if not ok or started == false then -- error, or the subprocess could not be forked
        for _, f in ipairs(files) do self.requested[f.filepath] = nil end
        return
    end
    local waiting = {}
    for _, f in ipairs(files) do waiting[f.filepath] = true end
    self._polls = self._polls or {}
    local tries = 0
    local poll
    local step
    poll = function()
        local ok_poll, err = pcall(step)
        if not ok_poll then logger.warn("Polka: cover poll:", err) end
    end
    step = function()
        self._polls[poll] = nil
        tries = tries + 1
        local got = false
        for p in pairs(waiting) do
            local ok2, info = pcall(BIM.getBookInfo, BIM, p, false)
            if ok2 and info then
                waiting[p] = nil
                got = true
                self:dropCovers(p)
                if self.meta then
                    self.meta[p] = { title = info.title, authors = info.authors, has_cover = info.has_cover == "Y",
                                     series = info.series, series_index = tonumber(info.series_index), lang = info.language }
                end
                local rec = self.by_path[p]
                if rec then rec._info = nil end
            end
        end
        if got and on_update then
            local ok3, err3 = pcall(on_update)
            if not ok3 then logger.warn("Polka: cover update:", err3) end
        end
        if next(waiting) then
            if tries < 40 then
                self._polls[poll] = true
                UIManager:scheduleIn(1.5, poll)
            else
                -- Gave up (interrupted or very slow): allow asking again later.
                for p in pairs(waiting) do self.requested[p] = nil end
            end
        end
    end
    self._polls[poll] = true
    UIManager:scheduleIn(1.5, poll)
end

function Books:stopPolling()
    for poll in pairs(self._polls or {}) do
        UIManager:unschedule(poll)
    end
    self._polls = {}
    if self._retry then
        UIManager:unschedule(self._retry)
        self._retry = nil
    end
    -- Books still being extracted may be asked for again next time.
    self.requested = {}
end

-- Only call once nothing on screen uses the covers any more.
function Books:freeCovers()
    for k, bb in pairs(self.cover_cache) do
        if bb then bb:free() end
        self.cover_cache[k] = nil
    end
    self.cover_keys = {}
end

return Books
