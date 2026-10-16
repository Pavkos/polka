-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Книги по Wi‑Fi.

While this screen is open, the Kindle serves a small upload page on the
local network. Scan the QR code (or type the address) on a phone or a
computer in the same Wi‑Fi, pick the files and a shelf, and the books land
in that folder of the library. Closing the screen, leaving the tab or
sleeping stops the server; on a Kindle its port is opened in the firewall
only while it runs (as KOReader's own SSH and HTTP plugins do).

The server is plain LuaSocket, non-blocking, polled from UIManager in small
steps, so the screen stays responsive during a big upload. Files are
written as ".name.part" and renamed when complete; names are cleaned and
never leave the books folder; only formats the library shows are accepted.
]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Books = require("polka_books")
local Tools = require("polka_tools")
local UI = require("polka_ui")

local Transfer = {}

Transfer.PORT = 8765
local MAX_SIZE = 500 * 1024 * 1024
local CHUNK = 64 * 1024
local IDLE_TIMEOUT = 60
local HEAD_TIMEOUT = 20   -- a request line and headers must arrive this fast
local MAX_CLIENTS = 8

local server = nil      -- { sock, clients, shell, busy, view, page, forms, key }
local received = {}     -- newest first: { name, shelf, size, done, failed, progress }
local last_refresh = 0
local part_count = 0

-- A short code in the address, new for every start: pages and uploads only
-- answer under /<code>, so nothing on the network can post to the Kindle
-- without the address shown on its screen.
local KEY_CHARS = "abcdefghjkmnpqrstuvwxyz23456789"
local key_count = 0
local function newKey()
    key_count = key_count + 1
    local hex = require("ffi/sha2").sha1(table.concat({ os.time(), os.clock(), key_count, tostring({}), tostring(newKey) }, "|"))
    local out = {}
    for i = 1, 5 do
        local n = tonumber(hex:sub(2 * i - 1, 2 * i), 16) % #KEY_CHARS + 1
        out[i] = KEY_CHARS:sub(n, n)
    end
    return table.concat(out)
end

-- Names, shelves and sizes are shared with the other tools.
local cleanName, uniquePath, shelfDir = Tools.cleanName, Tools.uniquePath, Tools.shelfDir
local sizeText = Tools.sizeText

-- Network ---------------------------------------------------------------------------

-- The address others reach the Kindle at: the local end of a route outwards
-- (nothing is sent: a UDP "connect" only picks the interface). No route —
-- Wi‑Fi off or not connected — gives nil.
function Transfer.localIP()
    local ok, ip = pcall(function()
        local socket = require("socket")
        local udp = socket.udp()
        udp:setpeername("192.0.2.1", 9) -- TEST-NET-1, never routed anywhere
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    if ok and type(ip) == "string" and ip ~= "0.0.0.0" and not ip:match("^127%.") then return ip end
    return nil
end

local function firewall(open)
    if not require("device"):isKindle() then return end
    local action = open and "-A" or "-D"
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", action, Transfer.PORT))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", action, Transfer.PORT))
end

-- HTTP ------------------------------------------------------------------------------

local function urldecode(s)
    s = (s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parseQuery(q)
    local out = {}
    for pair in (q or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k then out[urldecode(k)] = urldecode(v) end
    end
    return out
end

local function htmlEscape(s)
    return (tostring(s):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

local function jsonEscape(s)
    return (tostring(s):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end))
end

local STATUS = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found", [413] = "Payload Too Large",
                 [415] = "Unsupported Media Type", [500] = "Internal Server Error", [507] = "Insufficient Storage" }

local function response(code, ctype, body)
    return string.format("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s",
        code, STATUS[code] or "OK", ctype, #body, body)
end

local function jsonResponse(code, ok, message, name)
    return response(code, "application/json; charset=utf-8",
        string.format('{"ok":%s,"message":"%s","name":"%s"}', ok and "true" or "false", jsonEscape(message or ""), jsonEscape(name or "")))
end

-- Extensions the page lets you pick (the server checks every name again).
local PICK = ".epub,.fb2,.fbz,.fb3,.zip,.mobi,.azw,.azw3,.prc,.pdf,.djvu,.djv,.cbz,.cbr,.cb7,.cbt,.rtf,.txt,.md,.docx,.doc,.odt,.chm,.pdb,.xps,.oxps,.htm,.html,.htmlz"

local PAGE = [[<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Полка · Kindle</title>
<style>
:root{--ink:#111;--muted:#666;--line:#ddd;--paper:#fafaf7}
*{box-sizing:border-box}
body{margin:0;font:16px/1.45 Georgia,"Times New Roman",serif;color:var(--ink);background:var(--paper)}
main{max-width:560px;margin:0 auto;padding:28px 18px 60px}
h1{font-size:30px;margin:0 0 4px}
p.sub{margin:0 0 24px;color:var(--muted);font-family:-apple-system,system-ui,sans-serif;font-size:15px}
label{display:block;font:600 13px -apple-system,system-ui,sans-serif;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin:18px 0 8px}
select,input[type=text]{width:100%;font:17px -apple-system,system-ui,sans-serif;padding:12px;border:1px solid #bbb;border-radius:10px;background:#fff;color:var(--ink)}
.drop{margin-top:8px;border:2px dashed #bbb;border-radius:14px;padding:28px 16px;text-align:center;background:#fff;font-family:-apple-system,system-ui,sans-serif;color:var(--muted);cursor:pointer}
.drop.over{border-color:var(--ink);color:var(--ink)}
.drop strong{display:block;color:var(--ink);font-size:18px;margin-bottom:4px}
button{margin-top:18px;width:100%;font:600 17px -apple-system,system-ui,sans-serif;padding:14px;border:0;border-radius:12px;background:var(--ink);color:#fff}
button:disabled{background:#999}
ul{list-style:none;padding:0;margin:22px 0 0;font-family:-apple-system,system-ui,sans-serif;font-size:15px}
li{padding:10px 0;border-bottom:1px solid var(--line)}
li .n{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
li .s{color:var(--muted);font-size:13px}
.bar{height:4px;background:var(--line);border-radius:2px;margin-top:6px;overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--ink)}
#new{display:none;margin-top:8px}
</style></head><body><main>
<h1>Полка</h1>
<p class="sub">Книги отправятся на Kindle по Wi‑Fi. Не закрывайте экран «Книги по Wi‑Fi» на Kindle, пока идёт загрузка.</p>
<label for="shelf">Полка</label>
<select id="shelf">__OPTIONS__<option value="__new__">Новая полка…</option></select>
<input id="new" type="text" placeholder="Название новой полки">
<label>Файлы</label>
<div class="drop" id="drop"><strong>Выбрать книги</strong>EPUB, FB2, PDF, MOBI, DJVU, CBZ…<br>или перетащите сюда</div>
<input id="files" type="file" multiple hidden accept="__PICK__">
<button id="go" disabled>Отправить на Kindle</button>
<ul id="list"></ul>
</main><script>
var EXT="__PICK__".split(","),MAX=__MAX__,queue=[],busy=false,picked=[];
var $=function(id){return document.getElementById(id)};
var shelf=$("shelf"),neu=$("new");
shelf.onchange=function(){neu.style.display=shelf.value=="__new__"?"block":"none";if(shelf.value=="__new__")neu.focus()};
$("drop").onclick=function(){$("files").click()};
function pick(fs){picked=Array.prototype.slice.call(fs);$("go").disabled=!picked.length;
 $("drop").querySelector("strong").textContent=picked.length?("Выбрано: "+picked.length):"Выбрать книги"}
$("files").onchange=function(){pick(this.files)};
["dragenter","dragover"].forEach(function(e){$("drop").addEventListener(e,function(ev){ev.preventDefault();$("drop").classList.add("over")})});
["dragleave","drop"].forEach(function(e){$("drop").addEventListener(e,function(ev){ev.preventDefault();$("drop").classList.remove("over")})});
$("drop").addEventListener("drop",function(ev){pick(ev.dataTransfer.files)});
function size(b){return b>1048576?(b/1048576).toFixed(1).replace(".",",")+" МБ":Math.max(1,Math.round(b/1024))+" КБ"}
function ok(name){var n=name.toLowerCase();return EXT.some(function(e){return n.slice(-e.length)==e})}
$("go").onclick=function(){
 var s=shelf.value=="__new__"?neu.value.trim():shelf.value;
 picked.forEach(function(f){var li=document.createElement("li");
  li.innerHTML='<span class="n"></span><span class="s"></span><div class="bar"><i></i></div>';
  li.querySelector(".n").textContent=f.name;$("list").appendChild(li);
  if(!ok(f.name)){li.querySelector(".s").textContent="это не книга — пропущено";return}
  if(f.size>MAX){li.querySelector(".s").textContent=size(f.size)+" · слишком большой файл";return}
  li.querySelector(".s").textContent=size(f.size)+" · ждёт";queue.push({f:f,s:s,li:li})});
 picked=[];pick([]);$("files").value="";next()};
function next(){if(busy||!queue.length)return;busy=true;var it=queue.shift(),x=new XMLHttpRequest();
 x.open("POST","__BASE__/upload?name="+encodeURIComponent(it.f.name)+"&shelf="+encodeURIComponent(it.s));
 x.upload.onprogress=function(e){if(e.lengthComputable){it.li.querySelector("i").style.width=(e.loaded/e.total*100)+"%";
  it.li.querySelector(".s").textContent=size(it.f.size)+" · "+Math.round(e.loaded/e.total*100)+" %"}};
 x.onload=function(){var r={};try{r=JSON.parse(x.responseText)}catch(e){}
  it.li.querySelector(".s").textContent=size(it.f.size)+" · "+(r.ok?"на Kindle ✓":(r.message||"ошибка"));
  it.li.querySelector("i").style.width=r.ok?"100%":"0";busy=false;next()};
 x.onerror=function(){it.li.querySelector(".s").textContent="нет связи с Kindle";busy=false;next()};
 x.send(it.f)}
</script></body></html>]]

local function page()
    local opts = { '<option value="">Без полки</option>' }
    local last = G_reader_settings:readSetting("polka_transfer_shelf")
    for _, name in ipairs(Tools.shelves()) do
        opts[#opts + 1] = string.format('<option value="%s"%s>%s</option>', htmlEscape(name),
            name == last and " selected" or "", htmlEscape(name))
    end
    local values = { __OPTIONS__ = table.concat(opts), __PICK__ = PICK, __MAX__ = tostring(MAX_SIZE) }
    return (PAGE:gsub("__[A-Z]+__", function(key) return values[key] end))
end

local WRONG = [[<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Полка</title></head><body style="font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:560px;margin:0 auto;padding:28px 18px">
<h1 style="font-family:Georgia,serif">Полка</h1><p>Откройте адрес с экрана Kindle целиком — в конце у него короткий код.</p></body></html>]]

-- Connections -----------------------------------------------------------------------

local function closeClient(c, keep_file)
    if c.file then
        c.file:close()
        c.file = nil
        if not keep_file and c.part then os.remove(c.part) end
    end
    if c.entry and not c.entry.done and not c.entry.failed then
        c.entry.failed = true
        c.entry.progress = nil
        Transfer.changed = true
    end
    pcall(c.sock.close, c.sock)
    c.closed = true
end

local function reply(c, data)
    c.out, c.out_pos, c.state = data, 1, "send"
end

-- A refused upload: read (and drop) what the browser is already sending, so
-- that it gets the answer instead of a broken connection. A client waiting
-- for "100 Continue" sends nothing more, and a huge body is not worth it.
local function refuse(c, code, message, len, expect)
    local data = jsonResponse(code, false, message)
    if expect or not len or len > MAX_SIZE then return reply(c, data) end
    c.pending, c.remaining = data, len - #c.buf
    c.buf, c.state = "", "drain"
    if c.remaining <= 0 then reply(c, data) end
end

local NO_SPACE = "на Kindle не хватает места"

local function onUploadComplete(c)
    local closed = c.file:close()
    c.file = nil
    if not closed or lfs.attributes(c.part, "size") ~= c.total then
        os.remove(c.part)
        c.entry.failed, c.entry.progress = true, nil
        Transfer.changed = true
        return reply(c, jsonResponse(507, false, NO_SPACE))
    end
    local final = uniquePath(c.dir, c.name)
    if not os.rename(c.part, final) then
        os.remove(c.part)
        c.entry.failed, c.entry.progress = true, nil
        Transfer.changed = true
        return reply(c, jsonResponse(500, false, "не удалось сохранить файл"))
    end
    c.entry.done, c.entry.progress = true, nil
    c.entry.name = final:match("([^/]+)$")
    if c.shelf ~= "" then G_reader_settings:saveSetting("polka_transfer_shelf", c.shelf) end
    Books.generation = Books.generation + 1
    Transfer.changed, Transfer.new_books = true, true
    reply(c, jsonResponse(200, true, "ok", c.entry.name))
end

-- Content-Length as a plain number of bytes, or nil.
local function contentLength(headers)
    local v = headers["content-length"]
    return v and v:match("^%s*%d+%s*$") and tonumber(v) or nil
end

-- The phone is sent the answer once the rest of the body is read (dropped).
local function failWhileReceiving(c, code, message, result)
    if c.file then
        c.file:close()
        c.file = nil
    end
    os.remove(c.part)
    c.entry.failed, c.entry.progress = true, nil
    Transfer.changed = true
    c.pending = jsonResponse(code, false, message)
    if result == "done" or c.remaining <= 0 then
        reply(c, c.pending)
    elseif result == "closed" then
        closeClient(c)
    else
        c.state = "drain"
    end
end

local function startUpload(c, query, headers)
    local len = contentLength(headers)
    local expect = (headers["expect"] or ""):lower():find("100-continue", 1, true) ~= nil
    local name = cleanName(query.name)
    if not len then return refuse(c, 400, "нет размера файла", nil, expect) end
    if len == 0 then return refuse(c, 400, "пустой файл", 0, expect) end
    if not Books.isBookName(name) then
        local ext = name:match("%.([%w]+)$")
        return refuse(c, 415, "это не книга: " .. (ext and ("." .. ext) or "без расширения"), len, expect)
    end
    if len > MAX_SIZE then return refuse(c, 413, "слишком большой файл", len, expect) end
    local dir, shelf = shelfDir(query.shelf)
    c.dir, c.shelf, c.name = dir, shelf, name
    part_count = part_count + 1
    c.part = string.format("%s/.%s.%d.part", dir, name, part_count) -- two uploads of one name do not mix
    local f = io.open(c.part, "wb")
    if not f then return refuse(c, 500, "нет доступа к папке", len, expect) end
    c.file, c.remaining, c.total = f, len, len
    c.entry = { name = name, shelf = shelf, size = len, progress = 0 }
    table.insert(received, 1, c.entry)
    Transfer.changed = true
    c.state = "body"
    if expect then pcall(c.sock.send, c.sock, "HTTP/1.1 100 Continue\r\n\r\n") end
    if #c.buf > 0 then
        local piece = c.buf:sub(1, c.remaining)
        local wrote = c.file:write(piece)
        c.remaining = c.remaining - #piece
        c.buf = ""
        if not wrote then return failWhileReceiving(c, 507, NO_SPACE) end
    end
    if c.remaining <= 0 then onUploadComplete(c) end
end

-- A small form posted by a page of another tool (e.g. Instapaper keys): read
-- whole, then handler(fields) returns code, ok, message for the page.
local function finishForm(c)
    local fields = parseQuery(table.concat(c.parts))
    c.parts = nil
    local ok, code, success, message = pcall(c.handler, fields)
    if not ok then
        logger.warn("Polka: transfer form:", code)
        return reply(c, jsonResponse(500, false, "ошибка на Kindle"))
    end
    reply(c, jsonResponse(code or 200, success, message))
end

local function startForm(c, handler, headers)
    local len = contentLength(headers)
    if not len then return reply(c, jsonResponse(400, false, "нет данных")) end
    if len > 65536 then return reply(c, jsonResponse(413, false, "слишком много данных")) end
    c.state, c.handler, c.parts = "form", handler, {}
    local first = c.buf:sub(1, len)
    if #first > 0 then c.parts[1] = first end
    c.remaining, c.buf = len - #first, ""
    if c.remaining <= 0 then finishForm(c) end
end

local function onHead(c)
    local head, rest = c.buf:match("^(.-)\r\n\r\n(.*)$")
    local method, target = head:match("^(%u+)%s+(%S+)")
    local headers = {}
    for line in head:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    c.buf = rest
    local full, query = (target or "/"):match("^([^?]*)%??(.*)$")
    local path = full and full:match("^/" .. server.key .. "(/?[^/]*)$")
    if not path then
        return reply(c, response(404, "text/html; charset=utf-8", method == "GET" and WRONG or ""))
    end
    if method == "GET" and (path == "" or path == "/") then
        local html = server.page and server.page() or page()
        return reply(c, response(200, "text/html; charset=utf-8", (html:gsub("__BASE__", "/" .. server.key))))
    elseif method == "POST" and path == "/upload" and server.view == "transfer" then
        return startUpload(c, parseQuery(query), headers)
    elseif method == "POST" and server.forms[path] then
        return startForm(c, server.forms[path], headers)
    end
    reply(c, response(404, "text/plain; charset=utf-8", "Не найдено"))
end

-- Reads up to 512 KB of a request body; sink(data) takes each piece.
local function readBody(c, now, sink)
    for _ = 1, 8 do
        local want = math.min(CHUNK, c.remaining)
        local data, err, partial = c.sock:receive(want)
        local got = data or partial
        if got and #got > 0 then
            sink(got)
            c.remaining = c.remaining - #got
            c.seen = now
        end
        if c.remaining <= 0 then return "done" end
        if err == "closed" then return "closed" end
        if not got or #got < want then return end
    end
end

local function serve(c, now)
    if c.state == "head" then
        local data, err, partial = c.sock:receive(8192)
        local got = data or partial
        if got and #got > 0 then
            c.buf = c.buf .. got
            c.seen = now
        end
        if c.buf:find("\r\n\r\n", 1, true) then
            onHead(c)
        elseif #c.buf > 32768 then
            reply(c, response(400, "text/plain", "Bad Request"))
        elseif err == "closed" or now - c.started > HEAD_TIMEOUT then
            closeClient(c)
        end
    elseif c.state == "body" then
        local result = readBody(c, now, function(got)
            if not c.write_error and not c.file:write(got) then c.write_error = true end
        end)
        c.entry.progress = 1 - c.remaining / c.total
        if c.write_error then
            failWhileReceiving(c, 507, NO_SPACE, result)
        elseif result == "done" then
            onUploadComplete(c)
        elseif result == "closed" then
            closeClient(c)
        end
    elseif c.state == "drain" then
        local result = readBody(c, now, function() end)
        if result == "done" then
            reply(c, c.pending)
        elseif result == "closed" then
            closeClient(c)
        end
    elseif c.state == "form" then
        local result = readBody(c, now, function(got) table.insert(c.parts, got) end)
        if result == "done" then
            finishForm(c)
        elseif result == "closed" then
            closeClient(c)
        end
    end
    if c.state == "send" and not c.closed then
        local sent, err, last = c.sock:send(c.out, c.out_pos)
        local upto = sent or last
        if upto then c.out_pos = upto + 1 end
        if c.out_pos > #c.out or err == "closed" then
            closeClient(c, true)
        end
    end
    if not c.closed and now - c.seen > IDLE_TIMEOUT then closeClient(c) end
end

local function onScreen(shell)
    return shell and shell.shown and shell.tab == "tools" and server and shell.tools_view == server.view
end

local function poll()
    if not server then return end
    local shell = server.shell
    -- The screen went away without telling us (a book opened, KOReader
    -- closing...): nothing should keep listening behind it.
    if not onScreen(shell) then
        Transfer.stop()
        return
    end
    local ok, err = pcall(function()
        local now = os.time()
        for _ = 1, 4 do
            if #server.clients >= MAX_CLIENTS then break end -- the rest wait in the queue
            local s = server.sock:accept()
            if not s then break end
            s:settimeout(0)
            table.insert(server.clients, { sock = s, buf = "", state = "head", seen = now, started = now })
        end
        local busy = false
        for i = #server.clients, 1, -1 do
            local c = server.clients[i]
            serve(c, now)
            if c.closed then
                table.remove(server.clients, i)
            elseif c.state == "body" or c.state == "drain" or c.state == "form" then
                busy = true
            end
        end
        server.busy = busy
    end)
    if not ok then logger.warn("Polka: transfer:", err) end
    if not server then return end
    local delay = server.busy and 0.02 or 0.25
    -- Show progress now and then (e-ink: not on every chunk).
    local now = os.time()
    if server.view == "transfer" and (Transfer.changed or server.busy) and now - last_refresh >= 3 then
        last_refresh = now
        Transfer.changed = false
        shell:refresh("ui") -- may stop the server (Wi‑Fi gone)
    end
    if server then UIManager:scheduleIn(delay, poll) end
end

-- Starts serving for a tool's screen: "transfer" (the upload page) or
-- another tool with opts.page() for "/" and opts.forms[path] = handler.
-- The server stops by itself once that screen is no longer shown.
function Transfer.start(shell, view, opts)
    view = view or "transfer"
    if server and server.view ~= view then Transfer.stop() end
    if server then
        server.shell = shell
        return true
    end
    local socket = require("socket")
    local sock, err = socket.bind("*", Transfer.PORT)
    if not sock then
        logger.warn("Polka: transfer: cannot listen:", err)
        return false, err
    end
    sock:settimeout(0)
    firewall(true)
    server = { sock = sock, clients = {}, shell = shell, view = view, key = newKey(),
               page = opts and opts.page, forms = opts and opts.forms or {} }
    UIManager:scheduleIn(0.25, poll)
    return true
end

function Transfer.stop()
    if not server then return end
    UIManager:unschedule(poll)
    for _, c in ipairs(server.clients) do closeClient(c) end
    pcall(server.sock.close, server.sock)
    server = nil
    firewall(false)
end

function Transfer.running()
    return server ~= nil
end

-- The tool the server runs for, or nil.
function Transfer.owner()
    return server and server.view
end

-- The address to show (with this run's code), or nil when not running.
function Transfer.url(ip)
    return server and string.format("http://%s:%d/%s", ip, Transfer.PORT, server.key) or nil
end

-- Exposed for other tools' pages.
Transfer.htmlEscape = htmlEscape

-- Screen --------------------------------------------------------------------------------

function Transfer.summary()
    local n = 0
    for _, e in ipairs(received) do
        if e.done then n = n + 1 end
    end
    if n == 0 then return nil end
    return string.format("Получено за сеанс: %s", UI.books(n))
end

local function button(text, callback, filled)
    return UI.tap(UI.pill(UI.text{ text = text, size = 17, family = "sans_bold", color = filled and UI.C.paper or UI.C.ink },
        { background = filled and UI.C.ink or UI.C.paper, border_color = UI.C.ink,
          hpad = UI.px(24), vpad = UI.px(10), radius = UI.px(20) }), callback)
end

function Transfer.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(Tools.header(shell, cw, "Книги по Wi‑Fi"))
    add(UI.vgap(UI.px(18)))

    local ip = Transfer.localIP()
    if not ip then
        Transfer.stop()
        add(UI.para{ text = "Нужен Wi‑Fi: Kindle и телефон (или компьютер) должны быть в одной сети.",
                     size = 17, width = cw, color = UI.C.text2 })
        add(UI.vgap(UI.px(22)))
        local Wifi = require("polka_wifi")
        add(button(Wifi.connecting and "Подключаюсь…" or "Включить Wi‑Fi", function()
            if Wifi.connecting then return end
            Wifi.toggle(true, function()
                if shell.shown then shell:refresh("ui") end
            end)
        end, true))
        return UI.pad(vg, { left = M, right = M })
    end

    local ok, err = Transfer.start(shell)
    if not ok then
        add(UI.para{ text = "Не получилось открыть порт " .. Transfer.PORT .. ": " .. tostring(err),
                     size = 16, width = cw, color = UI.C.text2 })
        return UI.pad(vg, { left = M, right = M })
    end

    local url = Transfer.url(ip)
    local qr_size = UI.px(170)
    local QRWidget = require("ui/widget/qrwidget")
    local qr = QRWidget:new{ text = url, width = qr_size, height = qr_size }
    local text_w = cw - qr_size - UI.px(20)
    local info = VerticalGroup:new{
        align = "left",
        UI.para{ text = "Откройте на телефоне или компьютере в той же сети Wi‑Fi:", size = 15, color = UI.C.text2, width = text_w },
        UI.vgap(UI.px(8)),
        UI.para{ text = url, family = "sans_bold", size = 18, width = text_w },
        UI.vgap(UI.px(8)),
        UI.para{ text = "или наведите камеру на код.", size = 15, color = UI.C.text2, width = text_w },
    }
    add(HorizontalGroup:new{ align = "center", UI.center(qr_size, nil, qr), UI.hgap(UI.px(20)), info })
    add(UI.vgap(UI.px(22)))
    add(UI.hline(cw))
    add(UI.vgap(UI.px(12)))

    local done = 0
    for _, e in ipairs(received) do
        if e.done then done = done + 1 end
    end
    add(UI.split(cw, UI.text{ text = "Получено", family = "sans_bold", size = 14, color = UI.C.text2 },
        done > 0 and UI.text{ text = UI.books(done), size = 14, color = UI.C.text2 } or nil))
    add(UI.vgap(UI.px(8)))
    if #received == 0 then
        add(UI.para{ text = "Пока ничего. На странице загрузки можно выбрать полку или создать новую — книги появятся в Библиотеке.",
                     size = 15, color = UI.C.text3, width = cw })
    end
    local stop_h = UI.px(76)
    for _, e in ipairs(received) do
        if used + UI.px(56) > H - stop_h then break end
        local status
        if e.done then
            status = "✓"
        elseif e.failed then
            status = "не загрузилась"
        elseif e.progress then
            status = string.format("%d %%", math.floor(e.progress * 100))
        end
        -- "Медленная книга" / "EPUB · 3,0 МБ · Новая полка"
        local base, ext = e.name:match("^(.-)%.([%w]+%.[zZ][iI][pP])$")
        if not base then base, ext = e.name:match("^(.-)%.([%w]+)$") end
        local meta = { (ext or ""):upper(), sizeText(e.size) }
        if e.shelf ~= "" then meta[#meta + 1] = e.shelf end
        if meta[1] == "" then table.remove(meta, 1) end
        local line = UI.split(cw,
            VerticalGroup:new{
                align = "left",
                UI.text{ text = (base and base ~= "") and base or e.name, size = 16, max_width = cw - UI.px(130) },
                UI.vgap(UI.px(2)),
                UI.text{ text = table.concat(meta, " · "), size = 12, color = UI.C.text3, max_width = cw - UI.px(130) },
            },
            UI.text{ text = status or "", size = 15, family = "sans_bold", color = e.failed and UI.C.text2 or UI.C.ink })
        add(UI.pad(line, { top = UI.px(6), bottom = UI.px(6) }))
    end
    local spare = H - used - stop_h
    if spare > 0 then add(UI.vgap(spare)) end
    add(UI.center(cw, stop_h, button("Готово", function() shell:closeTool() end)))
    return UI.pad(vg, { left = M, right = M })
end

function Transfer.leave(shell)
    Transfer.stop()
    if Transfer.new_books then
        Transfer.new_books = false
        Books:scan()
    end
end

function Transfer.suspend(shell)
    Transfer.stop()
end

return Transfer
