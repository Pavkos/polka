-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: OPDS-каталоги.

Online libraries that speak OPDS (Project Gutenberg, Standard Ebooks,
a home calibre server...) browsed in Polka's own calm pages: sections,
books, search, a book card with its cover and description, and "Скачать"
straight onto a shelf.

The catalogs are KOReader's own list (read from its OPDS plugin settings,
never written) plus the ones added here, kept in "polka_opds". Feeds are
parsed with KOReader's XML lexer (luxl) the way its OPDS plugin does.
Network calls are blocking, as everywhere in KOReader; a small card tells
what is going on, with the bytes received for downloads.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Books = require("polka_books")
local Covers = require("polka_covers")
local Tools = require("polka_tools")
local UI = require("polka_ui")

local OPDS = {}

-- Catalogs -------------------------------------------------------------------------

-- KOReader's OPDS plugin starts with these until its list is edited there.
local KO_DEFAULTS = {
    { title = "Project Gutenberg", url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
    { title = "Standard Ebooks", url = "https://standardebooks.org/feeds/opds" },
    { title = "ManyBooks", url = "http://manybooks.net/opds/index.php" },
    { title = "Internet Archive", url = "https://bookserver.archive.org/" },
    { title = "textos.info (Spanish)", url = "https://www.textos.info/catalogo.atom" },
    { title = "Gallica (French)", url = "https://gallica.bnf.fr/opds" },
}

local ko_cache = { mtime = false, list = nil }

local function koCatalogs()
    local path = DataStorage:getSettingsDir() .. "/opds.lua"
    local mtime = lfs.attributes(path, "modification") or 0
    if ko_cache.list and ko_cache.mtime == mtime then return ko_cache.list end
    local ok, list = pcall(function()
        if mtime == 0 then return nil end
        return LuaSettings:open(path):readSetting("servers")
    end)
    if not ok or type(list) ~= "table" then list = KO_DEFAULTS end
    local out = {}
    for _, s in ipairs(list) do
        if type(s) == "table" and type(s.url) == "string" and s.url ~= "" then
            out[#out + 1] = { title = s.title or s.url, url = s.url, username = s.username, password = s.password, from_ko = true }
        end
    end
    ko_cache.mtime, ko_cache.list = mtime, out
    return out
end

local function ownCatalogs()
    local list = G_reader_settings:readSetting("polka_opds")
    return type(list) == "table" and list or {}
end

-- Polka's catalogs first, then KOReader's (the same address only once).
function OPDS.catalogs()
    local out, seen = {}, {}
    for i, c in ipairs(ownCatalogs()) do
        if type(c) == "table" and type(c.url) == "string" then
            out[#out + 1] = { title = c.title or c.url, url = c.url, username = c.username, password = c.password, own = i }
            seen[c.url] = true
        end
    end
    for _, c in ipairs(koCatalogs()) do
        if not seen[c.url] then
            out[#out + 1] = c
            seen[c.url] = true
        end
    end
    return out
end

local function host(url)
    return (tostring(url or ""):match("^%a[%w+.-]*://([^/?#]+)") or tostring(url or "")):gsub("^www%.", "")
end

-- XML ------------------------------------------------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'", nbsp = " " }

local function unescape(s)
    return (s:gsub("&(#?)([%w]+);", function(hash, name)
        if hash == "#" then
            local cp = name:sub(1, 1):lower() == "x" and tonumber(name:sub(2), 16) or tonumber(name)
            return cp and util.unicodeCodepointToUtf8(cp) or nil
        end
        return ENTITIES[name]
    end))
end

-- Elements that may repeat and are kept as lists.
local LISTS = { entry = true, link = true, author = true, Url = true }

local function readElement(lex, luxl, ffi)
    local node = {}
    local attr
    for event, offset, size in lex:Lexemes() do
        local txt = ffi.string(lex.buf + offset, size)
        if event == luxl.EVENT_START then
            if txt ~= "xml" then
                local child = readElement(lex, luxl, ffi)
                local name = txt:gsub("^atom:", "")
                if type(node) == "table" then
                    if LISTS[name] then
                        if type(node[name]) ~= "table" or node[name][1] == nil and next(node[name]) ~= nil then
                            node[name] = {}
                        end
                        table.insert(node[name], child)
                    else
                        node[name] = child
                    end
                end
            end
        elseif event == luxl.EVENT_ATTR_NAME then
            attr = unescape(txt)
        elseif event == luxl.EVENT_ATTR_VAL then
            if type(node) == "table" and attr then node[attr] = unescape(txt:sub(2)) end -- drop the marker
            attr = nil
        elseif event == luxl.EVENT_TEXT then
            node = unescape(txt)
        elseif event == luxl.EVENT_END then
            return node
        end
    end
    return node
end

-- Text that holds markup (descriptions) stays one text node for the lexer.
local function asText(s)
    return (s:gsub("[<>\"']", { ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }))
end

-- Every attribute value gets double quotes and a leading "x" (taken off
-- again when read): luxl drops a value's leading "?", "#", "&"... (so
-- href="?page=2" would lose its "?"), and the lexer of KOReader 2025.04 also
-- a leading non-ASCII word and single-quoted values altogether.
local function markAttributes(rest)
    return (rest:gsub("([%w:_%-%.]+)%s*=%s*([\"'])(.-)%2", function(name, _, value)
        return name .. '="x' .. value:gsub('"', "&quot;") .. '"'
    end))
end

function OPDS.parseXML(text)
    text = text:gsub("^\239\187\191", "")                  -- BOM
    text = text:gsub("^%s*<%?xml.-%?>", "")                  -- the declaration (single quotes upset old luxl)
    text = text:gsub("<%?xml%-stylesheet.-%?>", "")
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<!DOCTYPE[^>]*>", "")
    text = text:gsub("<!%[CDATA%[(.-)%]%]>", function(s)
        return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
    end)
    for _, tag in ipairs({ "content", "summary" }) do
        text = text:gsub("<" .. tag .. "%f[%s/][^<>]-/>", "")   -- empty ones say nothing
        text = text:gsub("<" .. tag .. "%f[%s>][^>]*>(.-)</" .. tag .. ">", function(inner)
            return "<" .. tag .. ">" .. asText(inner) .. "</" .. tag .. ">"
        end)
    end
    text = text:gsub("<([%a_][%w:_%-%.]*)(%s[^<>]*)>", function(name, rest)
        return "<" .. name .. markAttributes(rest) .. ">"
    end)
    text = text:gsub("<([%w:_%-]+)/>", "<%1 />")             -- luxl wants a space before "/>"
    text = text:gsub("<([bh]r)>", "<%1 />")
    local luxl = require("luxl")
    local ffi = require("ffi")
    local lex = luxl.new(text, #text)
    -- luxl reads through a bare pointer into the string: keep the string
    -- referenced until lexing is over (and no tail call, which would drop it).
    lex.polka_text = text
    local root = readElement(lex, luxl, ffi)
    lex.polka_text = nil
    return root
end

-- Feeds ------------------------------------------------------------------------------

local CATALOG = "application/atom%+xml"

local function plain(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        if type(v.div) == "string" then return v.div end
        if type(v[1]) == "string" then return v[1] end
    end
end

-- Plain text from a description that may hold HTML. Only real (ASCII-named)
-- tags go: "<с>" in a Russian title stays.
local BREAKS = { br = true, p = true, div = true, li = true, tr = true, h1 = true, h2 = true, h3 = true, h4 = true }
local function stripHTML(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("<(/?)(%a[%w]*)[^<>]*>", function(close, name)
        name = name:lower()
        if BREAKS[name] and (close == "/" or name == "br") then return "\n" end
        return ""
    end)
    s = unescape(s)
    s = s:gsub("\194\160", " "):gsub("[ \t\r]+", " "):gsub(" *\n *", "\n"):gsub("\n\n+", "\n")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

-- base: a URL string or, for many links of one feed, socket.url.parse() of it.
local function absolute(base, href)
    local ok, u = pcall(require("socket.url").absolute, base, href)
    return ok and u or href
end

-- The description of an entry, as plain text (worked out when first shown).
local function summaryOf(it)
    if it.summary == nil then
        it.summary = stripHTML(it.raw_summary) or false
        it.raw_summary = nil
    end
    return it.summary or nil
end
OPDS.summaryOf = summaryOf

local RANK = { epub = 1, fb2 = 2, ["fb2.zip"] = 2, fbz = 2, azw3 = 3, mobi = 4, pdf = 5, djvu = 6, djv = 6,
               cbz = 7, cbr = 7, docx = 8, odt = 8, rtf = 9, txt = 10, ["txt.zip"] = 10, htm = 11, html = 11 }
local LABEL = { ["fb2.zip"] = "FB2", fbz = "FB2", ["txt.zip"] = "TXT", htm = "HTML", djv = "DJVU" }

local function formatOf(ext) return LABEL[ext] or ext:upper() end

-- The file type of a download link: by its MIME type, else by its own name.
local function extFor(href, mime)
    local by_name
    local path = href:gsub("[?#].*$", ""):lower()
    local cand = path:match("%.([%w]+%.zip)$") or path:match("%.([%w]+)$")
    if cand and Books.isBookName("x." .. cand) then by_name = cand end
    if mime == "" or mime == "application/zip" or mime == "application/octet-stream" then return by_name end
    local ext = DocumentRegistry:mimeToExt(mime)
    if ext and Books.isBookName("x." .. ext) then return ext end
    return by_name
end

local function addAcquisition(it, href, mime, title, sample)
    mime = (mime or ""):match("^[^;%s]*") or ""
    local ext = extFor(href, mime)
    if not ext then return end
    for _, a in ipairs(it.acqs) do
        if a.href == href then return end
    end
    it.acqs[#it.acqs + 1] = { href = href, ext = ext, title = title, sample = sample, rank = (RANK[ext] or 50) + (sample and 100 or 0) }
end

local function entryOf(e, base)
    local it = { title = stripHTML(plain(e.title)) or "Без названия", acqs = {} }
    local names = {}
    for _, a in ipairs(type(e.author) == "table" and e.author or {}) do
        local n = stripHTML(type(a) == "table" and plain(a.name) or plain(a))
        if n then names[#names + 1] = n end
    end
    if #names > 0 then it.author = table.concat(names, ", ") end
    local raw = plain(e.content)
    if not (raw and raw:find("%S")) then raw = plain(e.summary) end
    it.raw_summary = raw
    for _, l in ipairs(type(e.link) == "table" and e.link or {}) do
        if type(l) == "table" and type(l.href) == "string" and l.href ~= "" then
            local href = absolute(base, l.href)
            local rel, ltype = l.rel or "", (l.type or ""):lower()
            if ltype:find(CATALOG) and (rel == "" or rel == "subsection" or rel == "http://opds-spec.org/subsection"
                    or rel:find("^http://opds%-spec%.org/sort/") or rel == "http://opds-spec.org/crawlable"
                    or rel == "alternate" and ltype:find("kind=navigation", 1, true)) then
                it.nav = it.nav or href
            elseif rel:find("^http://opds%-spec%.org/acquisition") then
                if rel:find("/borrow$") or rel:find("/buy$") or rel:find("/subscribe$") then
                    it.paid = true
                else
                    addAcquisition(it, href, ltype, l.title, rel:find("/sample$") ~= nil)
                end
            elseif rel == "http://opds-spec.org/image" or rel == "http://opds-spec.org/cover" or rel == "x-stanza-cover-image" then
                it.cover = href
            elseif rel == "http://opds-spec.org/image/thumbnail" or rel == "http://opds-spec.org/thumbnail"
                    or rel == "x-stanza-cover-image-thumbnail" then
                it.thumb = href
            elseif rel ~= "alternate" and ltype ~= "" and DocumentRegistry:hasProvider(nil, ltype:match("^[^;%s]*")) then
                addAcquisition(it, href, ltype, l.title)
            end
        end
    end
    table.sort(it.acqs, function(a, b) return a.rank < b.rank end)
    if #it.acqs > 0 then it.nav = nil end -- a book: its "alternate" pages are not sections
    return it
end

function OPDS.feedOf(t, base)
    local f = type(t) == "table" and t.feed
    if type(f) ~= "table" then return nil end
    local feed = { title = stripHTML(plain(f.title)), entries = {} }
    for _, l in ipairs(type(f.link) == "table" and f.link or {}) do
        if type(l) == "table" and type(l.href) == "string" then
            local rel, ltype = l.rel or "", (l.type or ""):lower()
            if rel == "next" and (ltype == "" or ltype:find(CATALOG)) then
                feed.next = absolute(base, l.href)
            elseif ltype:find("application/opensearchdescription%+xml") then
                feed.osd = absolute(base, l.href)
            elseif rel:find("search") and l.href:find("{searchTerms}", 1, true) then
                feed.template = absolute(base, l.href)
            end
        end
    end
    local ok, parsed = pcall(require("socket.url").parse, base)
    local entry_base = ok and type(parsed) == "table" and parsed or base
    for _, e in ipairs(type(f.entry) == "table" and f.entry or {}) do
        if type(e) == "table" then feed.entries[#feed.entries + 1] = entryOf(e, entry_base) end
    end
    return feed
end

-- Network ------------------------------------------------------------------------------

local ERRORS = {
    [401] = "Каталог просит логин и пароль.",
    [403] = "Нет доступа — проверьте логин и пароль.",
    [404] = "Такой страницы в каталоге нет.",
    [406] = "Каталог не отдаёт несжатые данные.",
    [410] = "Этой страницы в каталоге больше нет.",
}

local function errorText(code)
    if type(code) == "number" then
        return ERRORS[code] or string.format("Каталог ответил ошибкой %d.", code)
    end
    if code == "timeout" or code == "sink timeout" or code == "wantread" then
        return "Каталог не отвечает. Попробуйте ещё раз."
    end
    return "Нет связи с каталогом" .. (code and (" (" .. tostring(code) .. ")") or "") .. "."
end

local function origin(url)
    local scheme, rest = tostring(url or ""):lower():match("^(%a[%w+.-]*)://([^/?#]*)")
    return scheme and (scheme .. "://" .. rest:gsub("^.*@", "")) or nil
end

-- GET into a sink. Returns the HTTP code (or an error string), headers, status.
-- The catalog's login goes only to the catalog's own address.
local function request(url, cat, sink, block_timeout, total_timeout)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local login = cat and cat.username and cat.username ~= "" and origin(url) == origin(cat.url)
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = { ["Accept-Encoding"] = "identity" },
            sink = sink,
            user = login and cat.username or nil,
            password = login and (cat.password or "") or nil,
        })
    end)
    socketutil:reset_timeout()
    if not ok then return tostring(code) end
    return code, headers, status
end

local function fetchText(url, cat)
    local socketutil = require("socketutil")
    local chunks = {}
    local code = request(url, cat, socketutil.table_sink(chunks), socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if code ~= 200 then return nil, errorText(code) end
    return table.concat(chunks)
end

function OPDS.getFeed(url, cat)
    local text, err = fetchText(url, cat)
    if not text then return nil, err end
    local ok, t = pcall(OPDS.parseXML, text)
    local feed = ok and OPDS.feedOf(t, url)
    if not feed then
        if not ok then logger.warn("Polka: OPDS parse error:", t) end
        return nil, "Это не похоже на OPDS-каталог. Проверьте адрес."
    end
    return feed
end

-- The search address of a feed (nil: no search; nil, error: try again later).
local function searchTemplate(feed, cat)
    if feed.template then return feed.template end
    if not feed.osd then return nil end
    local text, err = fetchText(feed.osd, cat)
    if not text then return nil, err end
    local ok, t = pcall(OPDS.parseXML, text)
    local d = ok and type(t) == "table" and t.OpenSearchDescription
    local urls = type(d) == "table" and type(d.Url) == "table" and d.Url or {}
    local best
    for _, u in ipairs(urls) do
        if type(u) == "table" and type(u.template) == "string" and u.template:find("{searchTerms}", 1, true) then
            if (u.type or ""):find(CATALOG) then best = u.template break end
            best = best or u.template
        end
    end
    feed.template = best and absolute(feed.osd, best) or nil
    feed.osd = nil
    return feed.template
end

local function fillTemplate(template, words)
    local escape = require("socket.url").escape
    local s = template:gsub("{searchTerms}", (escape(words):gsub("%%", "%%%%")))
    s = s:gsub("{[%w:]+%?}", "")
    s = s:gsub("{startPage}", "1"):gsub("{startIndex}", "1"):gsub("{count}", "20"):gsub("{language}", "*")
    return s
end

-- Pictures: a thumbnail (or the cover), decoded and fitted into w x h.
local function fetchCover(url, cat, w, h)
    local socketutil = require("socketutil")
    local chunks = {}
    local code = request(url, cat, socketutil.table_sink(chunks), 3, 6)
    if code ~= 200 then return nil end
    local data = table.concat(chunks)
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb or type(bb) ~= "cdata" and type(bb) ~= "table" or not bb.getWidth then return nil end
    local bw, bh = bb:getWidth(), bb:getHeight()
    if bw < 2 or bh < 2 then bb:free() return nil end
    local scale = math.min(w / bw, h / bh)
    return RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(bw * scale)), math.max(1, math.floor(bh * scale)), true)
end

OPDS._fillTemplate = fillTemplate -- for tests

-- State --------------------------------------------------------------------------------

local function state(shell)
    shell.opds = shell.opds or { page = 1, starts = { 1 }, stack = {}, covers = {}, done = {} }
    return shell.opds
end

local function top(st) return st.stack[#st.stack] end

-- Books of a feed level (entries that can be downloaded), for flipping in the card.
local function bookEntries(level)
    local out = {}
    for i, e in ipairs(level.feed.entries) do
        if #e.acqs > 0 or e.paid and not e.nav then out[#out + 1] = i end
    end
    return out
end

-- The shelf downloads go to ("" is the books folder itself).
local function shelfChoice()
    local s = G_reader_settings:readSetting("polka_opds_shelf")
    return type(s) == "string" and s or ""
end

local function shelfPath(shelf)
    local root = (Books.root or Books.getRoot()):gsub("/+$", "")
    return shelf ~= "" and (root .. "/" .. shelf) or root
end

-- A connection is enough (a calibre server at home needs no internet).
-- With Wi‑Fi off, Polka asks in its own sheet, saying why («reason»).
local function online(fn, reason)
    require("polka_wifi").run(reason or "Нужен, чтобы открыть каталог.", fn)
end

-- Opens a feed (or a search) on top of the current one.
local function open(shell, cat, url, title)
    online(function()
        Tools.busy("Открываю " .. (title and ("«" .. title .. "»") or "каталог") .. "…")
        local feed, err = OPDS.getFeed(url, cat)
        Tools.idle()
        if not feed then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        local st = state(shell)
        table.insert(st.stack, { title = title or feed.title or host(url), url = url, feed = feed, cat = cat,
                                 starts = { 1 }, page = 1 })
        st.book = nil
        shell:refresh("ui")
    end)
end

-- The next page of the feed, appended to what is loaded. Calls done(true) when more came.
local function loadMore(shell, level, done)
    online(function()
        Tools.busy("Загружаю ещё…")
        local feed, err = OPDS.getFeed(level.feed.next, level.cat)
        Tools.idle()
        if not feed then
            UIManager:show(InfoMessage:new{ text = err })
            return done(false)
        end
        local before = #level.feed.entries
        for _, e in ipairs(feed.entries) do table.insert(level.feed.entries, e) end
        level.feed.next = feed.next ~= level.feed.next and feed.next or nil
        done(#level.feed.entries > before)
    end, "Нужен, чтобы загрузить ещё.")
end

-- Actions ------------------------------------------------------------------------------

local function editCatalog(shell, index)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local list = ownCatalogs()
    local c = index and list[index] or {}
    local dialog
    dialog = MultiInputDialog:new{
        title = index and "Каталог" or "Новый каталог",
        fields = {
            { description = "Название", text = c.title or "", hint = "Например, домашний calibre" },
            { description = "Адрес", text = c.url or "", hint = "https://…/opds" },
            { description = "Логин, если нужен", text = c.username or "", hint = "" },
            { description = "Пароль", text = c.password or "", hint = "", text_type = "password" },
        },
        buttons = {{
            { text = "Отмена", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Сохранить", is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local url = util.trim(f[2] or "")
                if url == "" then
                    UIManager:show(Notification:new{ text = "Нужен адрес каталога" })
                    return
                end
                if not url:match("^%a[%w+.-]*://") then url = "http://" .. url end
                local title = util.trim(f[1] or "")
                local entry = {
                    title = title ~= "" and title or host(url),
                    url = url,
                    username = util.trim(f[3] or "") ~= "" and util.trim(f[3]) or nil,
                    password = (f[4] or "") ~= "" and f[4] or nil,
                }
                list = ownCatalogs()
                if index and list[index] then list[index] = entry else table.insert(list, entry) end
                G_reader_settings:saveSetting("polka_opds", list)
                UIManager:close(dialog)
                shell:refresh("ui")
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function catalogActions(shell, cat)
    if not cat.own then
        UIManager:show(InfoMessage:new{
            text = "Этот каталог — из «Всех настроек» («Поиск» → «Каталог OPDS»). Изменить его можно там, а свои каталоги — добавить здесь.",
        })
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = cat.title,
        title_align = "center",
        buttons = {
            {{ text = "Изменить", callback = function() UIManager:close(dialog); editCatalog(shell, cat.own) end }},
            {{ text = "Удалить", callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = "Убрать каталог «" .. cat.title .. "» из Полки?",
                    ok_text = "Убрать",
                    cancel_text = "Отмена",
                    ok_callback = function()
                        local list = ownCatalogs()
                        table.remove(list, cat.own)
                        G_reader_settings:saveSetting("polka_opds", list)
                        shell:refresh("ui")
                    end,
                })
            end }},
        },
    }
    UIManager:show(dialog)
end

function OPDS.runSearch(shell, level, words)
    online(function()
        Tools.busy("Ищу…")
        local template, err = searchTemplate(level.feed, level.cat)
        Tools.idle()
        if not template then
            UIManager:show(InfoMessage:new{ text = err or "Этот каталог не умеет искать." })
            return
        end
        open(shell, level.cat, fillTemplate(template, words), "«" .. words .. "»")
    end, "Нужен, чтобы искать в каталоге.")
end

local function search(shell, level)
    local dialog
    dialog = InputDialog:new{
        title = "Поиск в каталоге",
        input_hint = "Автор или название",
        buttons = {{
            { text = "Отмена", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Найти", is_enter_default = true, callback = function()
                local words = util.trim(dialog:getInputText() or "")
                UIManager:close(dialog)
                if words ~= "" then OPDS.runSearch(shell, level, words) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- "Автор - Название.epub", as the library reads it back.
local function fileName(it, acq)
    local author = it.author and it.author:match("^[^,]+") or nil
    local base = author and (author .. " - " .. it.title) or it.title
    return Tools.cleanName(base:gsub("[/\\]", "-") .. "." .. acq.ext)
end

function OPDS.download(shell, it, acq)
    local st = state(shell)
    local level = top(st)
    online(function()
        local dir, shelf = Tools.shelfDir(shelfChoice())
        local name = fileName(it, acq)
        local part = dir .. "/." .. name .. ".part"
        local f = io.open(part, "wb")
        if not f then
            UIManager:show(InfoMessage:new{ text = "Нет доступа к папке с книгами." })
            return
        end
        local started = os.time()
        local got, last, closed, write_error, close_ok = 0, started, false, nil, true
        local label = "Скачиваю «" .. it.title .. "»"
        local function finish()
            if not closed then
                closed = true
                close_ok = f:close() and true or false
            end
        end
        local function sink(chunk)
            if not chunk then
                finish()
                return 1
            end
            local ok, werr = f:write(chunk)
            if not ok then
                write_error = werr or true
                return nil, "write"
            end
            got = got + #chunk
            local now = os.time()
            if now - started > 900 then return nil, "sink timeout" end -- a trickle must not hold KOReader forever
            if now - last >= 1 then
                last = now
                Tools.busy(label .. "\n" .. Tools.sizeText(got))
            end
            return 1
        end
        Tools.busy(label .. "…")
        local code, headers = request(acq.href, level and level.cat, sink, 15, 900)
        finish()
        Tools.idle()
        local ctype = type(headers) == "table" and (headers["content-type"] or ""):lower() or ""
        local problem
        if write_error or not close_ok then
            problem = "Не хватает места на Kindle — книга не сохранилась."
        elseif code ~= 200 then
            problem = errorText(code)
        elseif got == 0 then
            problem = "Каталог прислал пустой файл."
        elseif ctype:find("text/html", 1, true) and acq.ext ~= "html" and acq.ext ~= "htm" then
            problem = "Вместо книги пришла веб-страница — возможно, на сайте нужно войти."
        end
        if problem then
            os.remove(part)
            UIManager:show(InfoMessage:new{ text = problem })
            return
        end
        local path = Tools.uniquePath(dir, name)
        if not os.rename(part, path) then
            os.remove(part)
            UIManager:show(InfoMessage:new{ text = "Не удалось сохранить книгу." })
            return
        end
        st.done[acq.href] = path
        Books.generation = Books.generation + 1
        OPDS.new_books = true
        G_reader_settings:saveSetting("polka_opds_shelf", shelf)
        UIManager:show(Notification:new{ text = shelf ~= "" and ("Книга на полке «" .. shelf .. "»") or "Книга в библиотеке" })
        shell:refresh("ui")
    end, "Нужен, чтобы скачать книгу.")
end

-- Drawing ------------------------------------------------------------------------------

local function backLink(text, cb)
    return UI.tap(UI.pad(UI.text{ text = "‹  " .. text, size = 15, color = UI.C.text2, max_width = UI.px(420) },
        { top = UI.px(10), bottom = UI.px(6), right = UI.px(30) }), cb)
end

local function chip(text, active, cb)
    return UI.tap(UI.pill(UI.text{ text = text, size = 15, family = active and "sans_bold" or "sans",
                                   color = active and UI.C.paper or UI.C.ink, max_width = UI.px(300) },
        { background = active and UI.C.ink or UI.C.paper, border_color = active and UI.C.ink or UI.C.mid,
          hpad = UI.px(13), vpad = UI.px(5), radius = UI.px(16) }), cb)
end

local function button(text, filled, cb)
    return UI.tap(UI.pill(UI.text{ text = text, size = 16, family = "sans_bold", color = filled and UI.C.paper or UI.C.ink },
        { background = filled and UI.C.ink or UI.C.paper, border_color = UI.C.ink,
          hpad = UI.px(18), vpad = UI.px(9), radius = UI.px(18) }), cb)
end

-- Widgets in rows of at most w (buttons that wrap).
local function flow(w, widgets, gap)
    local vg = VerticalGroup:new{ align = "left" }
    local row, row_w = HorizontalGroup:new{ align = "center" }, 0
    for _, wd in ipairs(widgets) do
        local ww = wd:getSize().w
        if row_w > 0 and row_w + gap + ww > w then
            table.insert(vg, row)
            table.insert(vg, UI.vgap(gap))
            row, row_w = HorizontalGroup:new{ align = "center" }, 0
        end
        if row_w > 0 then
            table.insert(row, UI.hgap(gap))
            row_w = row_w + gap
        end
        table.insert(row, wd)
        row_w = row_w + ww
    end
    if row_w > 0 then table.insert(vg, row) end
    return vg
end

local fillPage, pager = Tools.fillPage, Tools.pagerBar

-- The list of catalogs.
local function catalogsView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    local add_link = UI.tap(UI.pad(UI.text{ text = "+ Добавить", size = 16, color = UI.C.ink },
        { left = UI.px(20), top = UI.px(8), bottom = UI.px(8) }), function() editCatalog(shell) end)
    add(Tools.header(shell, cw, "OPDS-каталоги", add_link))
    add(UI.vgap(UI.px(8)))

    local items = OPDS.catalogs()
    local footer_h = UI.px(52)
    local rows, next_i = fillPage(items, st.starts[st.page] or 1, H - used - footer_h, function(cat)
        local texts = VerticalGroup:new{
            align = "left",
            UI.text{ text = cat.title, family = "serif_bold", size = 19, max_width = cw - UI.px(40) },
            UI.vgap(UI.px(2)),
            UI.text{ text = host(cat.url) .. (cat.username and "  ·  со входом" or ""), size = 13, color = UI.C.text3,
                     max_width = cw - UI.px(40) },
        }
        local h = texts:getSize().h + UI.px(24)
        return UI.tap(VerticalGroup:new{
            align = "left",
            UI.split(cw, texts, UI.text{ text = "›", size = 22, color = UI.C.text2 }, h),
            UI.hline(cw),
        }, function() open(shell, cat, cat.url, cat.title) end, function() catalogActions(shell, cat) end)
    end)
    add(rows)
    st.starts[st.page + 1] = items[next_i] and next_i or nil
    if not items[next_i] then
        local note = UI.para{ text = "Каталоги из «Всех настроек» тоже здесь. Свой каталог можно изменить долгим нажатием.",
                              size = 13, color = UI.C.text3, width = cw }
        if used + UI.px(12) + note:getSize().h <= H - footer_h then
            add(UI.vgap(UI.px(12)))
            add(note)
        else
            note:free()
        end
    end
    if st.page > 1 or items[next_i] then
        local spare = H - used - footer_h
        if spare > 0 then add(UI.vgap(spare)) end
        add(pager(cw, footer_h, "стр. " .. st.page, st.page > 1, items[next_i] ~= nil, function(delta)
            OPDS.turn(shell, delta)
        end))
    end
    return UI.pad(vg, { left = M, right = M })
end

local function entryRow(shell, level, it, index, cw)
    local vg = VerticalGroup:new{ align = "left", UI.vgap(UI.px(12)) }
    local text_w = cw - UI.px(34)
    local is_book = #it.acqs > 0 or it.paid and not it.nav
    if is_book then
        table.insert(vg, UI.para{ text = it.title, family = "serif_bold", size = 17, width = text_w, max_lines = 2 })
        if it.author then
            table.insert(vg, UI.vgap(UI.px(2)))
            table.insert(vg, UI.text{ text = it.author, size = 14, color = UI.C.text2, max_width = text_w })
        end
        local formats, seen = {}, {}
        for _, a in ipairs(it.acqs) do
            local fmt = formatOf(a.ext)
            if not seen[fmt] and not a.sample then
                seen[fmt] = true
                formats[#formats + 1] = fmt
            end
        end
        if #formats == 0 then formats[1] = #it.acqs > 0 and "отрывок" or "только покупка" end
        table.insert(vg, UI.vgap(UI.px(4)))
        table.insert(vg, UI.text{ text = table.concat(formats, " · "), size = 12, color = UI.C.text3, max_width = text_w })
    else
        table.insert(vg, UI.text{ text = it.title, family = "serif", size = 19, max_width = text_w })
        local summary = summaryOf(it)
        local sub = summary and summary:gsub("\n", " ") or nil
        if sub then
            table.insert(vg, UI.vgap(UI.px(2)))
            table.insert(vg, UI.text{ text = sub, size = 13, color = UI.C.text3, max_width = text_w })
        end
    end
    table.insert(vg, UI.vgap(UI.px(12)))
    local h = vg:getSize().h
    local right = (it.nav or is_book) and UI.text{ text = "›", size = 22, color = UI.C.text2 } or nil
    return UI.tap(VerticalGroup:new{
        align = "left",
        UI.split(cw, vg, right, h),
        UI.hline(cw),
    }, function()
        if is_book then
            state(shell).book = index
            shell:refresh("ui")
        elseif it.nav then
            open(shell, level.cat, it.nav, it.title)
        end
    end)
end

local function backTitle(st)
    local prev = st.stack[#st.stack - 1]
    return prev and prev.title or "OPDS-каталоги"
end

local function goBack(shell)
    local st = state(shell)
    if st.book then
        st.book = nil
    else
        table.remove(st.stack)
    end
    shell:refresh("ui")
end

local function feedView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local level = top(st)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(backLink(backTitle(st), function() goBack(shell) end))
    add(UI.text{ text = level.title, family = "serif_bold", size = 26, max_width = cw })
    if level.feed.template or level.feed.osd then
        add(UI.vgap(UI.px(10)))
        add(chip("Поиск", false, function() search(shell, level) end))
    end
    add(UI.vgap(UI.px(6)))
    add(UI.hline(cw))
    local entries = level.feed.entries
    if #entries == 0 then
        add(UI.vgap(UI.px(30)))
        add(UI.para{ text = "Здесь пусто.", size = 17, color = UI.C.text2, width = cw, align = "center" })
        return UI.pad(vg, { left = M, right = M })
    end
    local footer_h = UI.px(52)
    local rows, next_i = fillPage(entries, level.starts[level.page] or 1, H - used - footer_h, function(it, i)
        return entryRow(shell, level, it, i, cw)
    end)
    add(rows)
    level.starts[level.page + 1] = entries[next_i] and next_i or nil
    level.last_shown = next_i - 1
    local more = entries[next_i] ~= nil or level.feed.next ~= nil
    if level.page > 1 or more then
        local spare = H - used - footer_h
        if spare > 0 then add(UI.vgap(spare)) end
        add(pager(cw, footer_h, "стр. " .. level.page, level.page > 1, more, function(delta) OPDS.turn(shell, delta) end))
    end
    return UI.pad(vg, { left = M, right = M })
end

local function coverBox(shell, st, level, it, w, h)
    local url = it.thumb or it.cover
    local bb = url and st.covers[url]
    if bb then return Covers.framed(bb) end
    if url and bb == nil then
        st.covers[url] = false -- asked once
        local function showing()
            return shell.opds == st and shell.shown and top(st) == level and st.book and level.feed.entries[st.book] == it
        end
        -- Only for a card that stays on screen a moment: flipping quickly
        -- through books does not wait for each picture (the fetch blocks).
        UIManager:scheduleIn(0.6, function()
            if not showing() then
                if shell.opds == st then st.covers[url] = nil end -- next time it is shown
                return
            end
            local ok, got = pcall(fetchCover, url, level.cat, w - 2, h - 2)
            if ok and got then
                if shell.opds ~= st then got:free() return end
                st.covers[url] = got
                if showing() then shell:refresh("ui") end
            end
        end)
    end
    return Covers.placeholder({ title = it.title, authors = it.author }, w, h)
end

local function bookView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local level = top(st)
    local it = level.feed.entries[st.book]
    if not it then
        st.book = nil
        return feedView(shell, W, H)
    end
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(backLink(level.title, function() goBack(shell) end))
    add(UI.vgap(UI.px(12)))

    local cover_w, cover_h = UI.px(116), UI.px(174)
    local text_w = cw - cover_w - UI.px(18)
    local info = VerticalGroup:new{
        align = "left",
        UI.para{ text = it.title, family = "serif_bold", size = 22, width = text_w, max_lines = 5 },
    }
    if it.author then
        table.insert(info, UI.vgap(UI.px(6)))
        table.insert(info, UI.para{ text = it.author, size = 16, color = UI.C.text2, width = text_w, max_lines = 2 })
    end
    add(HorizontalGroup:new{ align = "top", coverBox(shell, st, level, it, cover_w, cover_h), UI.hgap(UI.px(18)), info })
    add(UI.vgap(UI.px(18)))

    -- Bottom first: the shelf, the buttons and the position; the description gets the rest.
    local shelf = shelfChoice()
    local dir = shelfPath(shelf)
    local actions = {}
    local done_path
    for _, a in ipairs(it.acqs) do
        done_path = done_path or st.done[a.href]
    end
    local first = it.acqs[1]
    local existing = not done_path and first and lfs.attributes(dir .. "/" .. fileName(it, first)) and (dir .. "/" .. fileName(it, first)) or nil
    local ready = done_path or existing
    if ready then
        actions[#actions + 1] = button("Читать", true, function() shell:openBook(ready) end)
    end
    local counts = {}
    for _, a in ipairs(it.acqs) do
        local fmt = formatOf(a.ext)
        counts[fmt] = (counts[fmt] or 0) + 1
    end
    for i, a in ipairs(it.acqs) do
        local fmt = formatOf(a.ext)
        local label = fmt
        if a.sample then
            label = "Отрывок " .. fmt
        elseif counts[fmt] > 1 and a.title and a.title ~= "" then
            label = Tools.utf8Cut(util.trim(a.title), 24)
        end
        if i == 1 and not ready then label = "Скачать " .. label end
        actions[#actions + 1] = button(label, i == 1 and not ready, function() OPDS.download(shell, it, a) end)
        if #actions >= 6 then break end
    end
    local buttons = flow(cw, actions, UI.px(10))
    local status
    if ready then
        local root = (Books.root or Books.getRoot()):gsub("/+$", "")
        local where = ready:sub(#root + 2):match("^([^/]+)/")
        status = UI.text{ text = "✓ " .. (where and ("На полке «" .. where .. "»") or "В библиотеке"),
                          size = 15, family = "sans_bold", max_width = cw }
    elseif #it.acqs == 0 then
        status = UI.para{ text = "Эту книгу можно только купить на сайте каталога.", size = 15, color = UI.C.text2, width = cw }
    end
    local shelf_chip = #it.acqs == 0 and UI.vgap(0) or chip("Полка: " .. (shelf ~= "" and shelf or "без полки") .. "  ▾", false, function()
        Tools.pickShelf(shelf, function(value)
            G_reader_settings:saveSetting("polka_opds_shelf", value)
            shell:refresh("ui")
        end)
    end)
    local books = bookEntries(level)
    local pos = 1
    for k, i in ipairs(books) do
        if i == st.book then pos = k end
    end
    local footer_h = UI.px(52)
    local bottom_h = shelf_chip:getSize().h + UI.px(14) + buttons:getSize().h + footer_h
        + (status and status:getSize().h + UI.px(10) or 0) + UI.px(16)
    local room = H - used - bottom_h
    local summary = summaryOf(it)
    if summary and room > UI.px(40) then
        local line_h = math.floor(1.18 * UI.face("sans", 15).size + 0.5)
        add(UI.para{ text = summary, size = 15, color = UI.C.text2, width = cw,
                     max_lines = math.max(1, math.floor(room / line_h)) })
    end
    local spare = H - used - bottom_h + UI.px(16)
    if spare > 0 then add(UI.vgap(spare)) end
    if status then
        add(status)
        add(UI.vgap(UI.px(10)))
    end
    add(shelf_chip)
    add(UI.vgap(UI.px(14)))
    add(buttons)
    add(pager(cw, footer_h, string.format("%d / %d", pos, #books), pos > 1, pos < #books or level.feed.next ~= nil,
        function(delta) OPDS.flip(shell, delta) end))
    return UI.pad(vg, { left = M, right = M })
end

function OPDS.build(shell, W, H)
    local st = state(shell)
    local level = top(st)
    if not level then return catalogsView(shell, W, H) end
    if st.book then return bookView(shell, W, H) end
    return feedView(shell, W, H)
end

-- Paging ---------------------------------------------------------------------------------

function OPDS.turn(shell, delta)
    local st = state(shell)
    local level = top(st)
    local holder = level or st
    local p = holder.page + delta
    if p < 1 then return end
    if holder.starts[p] then
        holder.page = p
        return shell:refresh("ui")
    end
    if level and delta > 0 and level.feed.next then
        local start = #level.feed.entries + 1
        loadMore(shell, level, function(more)
            if more then
                level.starts[p] = level.starts[p] or start
                level.page = p
            end
            shell:refresh("ui")
        end)
    end
end

-- The previous or next book of the feed, in the book card.
function OPDS.flip(shell, delta)
    local st = state(shell)
    local level = top(st)
    if not level or not st.book then return end
    local books = bookEntries(level)
    local pos
    for k, i in ipairs(books) do
        if i == st.book then pos = k end
    end
    pos = (pos or 1) + delta
    if books[pos] then
        st.book = books[pos]
        return shell:refresh("ui")
    end
    if delta > 0 and level.feed.next then
        loadMore(shell, level, function(more)
            if more then
                local again = bookEntries(level)
                if again[pos] then st.book = again[pos] end
            end
            shell:refresh("ui")
        end)
    end
end

function OPDS.swipe(shell, dir)
    local delta = dir == "west" and 1 or -1
    if state(shell).book then
        OPDS.flip(shell, delta)
    else
        OPDS.turn(shell, delta)
    end
end

function OPDS.summary()
    local n = #OPDS.catalogs()
    return string.format("%d %s", n, UI.plural(n, "каталог", "каталога", "каталогов"))
end

function OPDS.leave(shell)
    local st = shell.opds
    shell.opds = nil
    if st then
        for _, bb in pairs(st.covers) do
            if bb then pcall(bb.free, bb) end
        end
    end
    if OPDS.new_books then
        OPDS.new_books = false
        Books:scan()
    end
end

return OPDS
