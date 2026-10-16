-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Instapaper.

Saved articles become books: each one is downloaded as a clean HTML page
onto the "Instapaper" shelf, and articles read to the end go to the
Instapaper archive by themselves the next time the list is refreshed
(progress of the others is sent too).

Instapaper's Full API (v1): OAuth 1.0a with HMAC-SHA1, signed with
KOReader's own ffi/sha2. Connecting needs a consumer key and secret, made in
a minute at instapaper.com/developers/applications/create ("Owner Only"),
plus the Instapaper login once: the keys can be typed on a phone (a page
served by the Kindle, as for "Книги по Wi‑Fi") or on the Kindle. Only the
keys and the access token are kept ("polka_instapaper"), never the password.

The shelf keeps a small hidden index (.polka_instapaper.lua): which file is
which article, and what was already sent back.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Books = require("polka_books")
local Tools = require("polka_tools")
local UI = require("polka_ui")

local Instapaper = {}

Instapaper.API = "https://www.instapaper.com/api/1/"
Instapaper.CREATE_URL = "https://www.instapaper.com/developers/applications/create"
Instapaper.SHELF = "Instapaper"
local LIST_LIMIT = 100

-- OAuth 1.0a ---------------------------------------------------------------------------

local function pct(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local nonce_count = 0
local function nonce()
    nonce_count = nonce_count + 1
    return require("ffi/sha2").sha1(table.concat({ os.time(), os.clock(), nonce_count, tostring({}) }, "|")):sub(1, 32)
end

-- The Authorization header for a request (params: the form fields sent).
function Instapaper.authHeader(method, url, params, key, secret, token, token_secret, timestamp, once)
    local sha2 = require("ffi/sha2")
    local oauth = {
        oauth_consumer_key = key,
        oauth_nonce = once or nonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp = tostring(timestamp or os.time()),
        oauth_version = "1.0",
    }
    if token then oauth.oauth_token = token end
    local all = {}
    for k, v in pairs(params) do all[#all + 1] = { pct(k), pct(v) } end
    for k, v in pairs(oauth) do all[#all + 1] = { pct(k), pct(v) } end
    table.sort(all, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    local norm = {}
    for i, kv in ipairs(all) do norm[i] = kv[1] .. "=" .. kv[2] end
    local base = method:upper() .. "&" .. pct(url) .. "&" .. pct(table.concat(norm, "&"))
    local signing_key = pct(secret) .. "&" .. pct(token_secret or "")
    oauth.oauth_signature = sha2.bin_to_base64(sha2.hex_to_bin(sha2.hmac(sha2.sha1, signing_key, base)))
    local parts = {}
    for k, v in pairs(oauth) do parts[#parts + 1] = k .. '="' .. pct(v) .. '"' end
    table.sort(parts)
    return "OAuth " .. table.concat(parts, ", ")
end

-- API ------------------------------------------------------------------------------------

local ERRORS = {
    [1040] = "Instapaper просит подождать: слишком много запросов. Попробуйте через несколько минут.",
    [1041] = "Для этого нужна подписка Instapaper Premium.",
    [1042] = "Instapaper отключил это приложение. Создайте новый ключ.",
    [1220] = "Этот сайт не даёт Instapaper сохранять статьи текстом.",
    [1221] = "Этот сайт не даёт Instapaper сохранять статьи текстом.",
    [1241] = "Такой статьи в Instapaper уже нет.",
    [1500] = "У Instapaper что-то сломалось. Попробуйте позже.",
    [1550] = "Instapaper не смог подготовить текст этой статьи.",
}

local function decode(body)
    local ok, j = pcall(function() return require("json").decode(body) end)
    return ok and type(j) == "table" and j or nil
end

local function errorCode(body)
    local j = type(body) == "string" and body:sub(1, 1):match("[%[{]") and decode(body)
    local e = j and (j[1] or j)
    return type(e) == "table" and tonumber(e.error_code) or nil, e
end

-- In Russian; Instapaper's and the socket's own (English) words go to the log only.
local function apiError(code, body)
    local ecode, e = errorCode(body)
    if ecode then
        if not ERRORS[ecode] then
            logger.warn("Polka: Instapaper error", ecode, type(e) == "table" and e.message or "")
        end
        return ERRORS[ecode] or string.format("Instapaper ответил ошибкой %d.", ecode)
    end
    if code == 401 or code == 403 then return "Instapaper не принял ключ, секрет или пароль." end
    if type(code) ~= "number" then
        logger.warn("Polka: Instapaper: network error:", code)
        local kind = require("polka_net").errorKind(code)
        if kind == "clock" then return "Не удалось проверить Instapaper. Проверьте дату и время на Kindle." end
        if kind == "timeout" then return "Instapaper не отвечает. Попробуйте ещё раз." end
        return "Нет связи с Instapaper. Проверьте Wi‑Fi."
    end
    return string.format("Instapaper ответил ошибкой %d.", code)
end

-- A signed POST. Returns the HTTP code (or an error string) and the body.
local function call(path, params, acc)
    local url = Instapaper.API .. path
    local auth = Instapaper.authHeader("POST", url, params, acc.key, acc.secret, acc.token, acc.token_secret)
    local fields = {}
    for k, v in pairs(params) do fields[#fields + 1] = pct(k) .. "=" .. pct(v) end
    local body = table.concat(fields, "&")
    local socketutil = require("socketutil")
    -- https checked like the site's: the login and the keys go only to Instapaper
    local code, resp, err = require("polka_net").request{
        url = url,
        method = "POST",
        body = body,
        ctype = "application/x-www-form-urlencoded",
        headers = { ["Authorization"] = auth },
        timeouts = { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT },
    }
    if not code then return tostring(err), "" end
    return code, resp or ""
end

local function urldecode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function Instapaper.account()
    local a = G_reader_settings:readSetting("polka_instapaper")
    if type(a) == "table" and a.token and a.token_secret and a.key and a.secret then return a end
end

-- xAuth: the login is exchanged for an access token once.
function Instapaper.login(key, secret, user, password)
    local code, body = call("oauth/access_token",
        { x_auth_username = user, x_auth_password = password or "", x_auth_mode = "client_auth" },
        { key = key, secret = secret })
    if code ~= 200 then return nil, apiError(code, body) end
    local token = body:match("oauth_token=([^&%s]+)")
    local token_secret = body:match("oauth_token_secret=([^&%s]+)")
    if not token or not token_secret then return nil, "Instapaper ответил непонятно. Проверьте ключ и секрет." end
    local acc = { key = key, secret = secret, token = urldecode(token), token_secret = urldecode(token_secret), user = user }
    G_reader_settings:saveSetting("polka_instapaper", acc)
    return acc
end

local function str(v) return type(v) == "string" and v ~= "" and v or nil end

-- Unread articles, newest first: { id, title, url, description, time, progress }.
function Instapaper.list(acc)
    local code, body = call("bookmarks/list", { limit = tostring(LIST_LIMIT), folder_id = "unread" }, acc)
    if code ~= 200 then return nil, apiError(code, body) end
    local j = decode(body)
    if not j then return nil, "Instapaper ответил непонятно." end
    local items = type(j.bookmarks) == "table" and j.bookmarks or j
    local out = {}
    for _, b in ipairs(items) do
        local id = type(b) == "table" and tonumber(b.bookmark_id)
        if id and (b.type == nil or b.type == "bookmark") then
            out[#out + 1] = {
                id = string.format("%d", id),
                title = str(b.title) or str(b.url) or "Без названия",
                url = str(b.url),
                description = str(b.description),
                time = tonumber(b.time),
                progress = tonumber(b.progress) or 0,
            }
        end
    end
    table.sort(out, function(a, b) return (a.time or 0) > (b.time or 0) end)
    return out
end

function Instapaper.text(acc, id)
    local code, body = call("bookmarks/get_text", { bookmark_id = id }, acc)
    if code ~= 200 then return nil, apiError(code, body) end
    return body
end

function Instapaper.archive(acc, id)
    local code, body = call("bookmarks/archive", { bookmark_id = id }, acc)
    if code ~= 200 then
        if errorCode(body) == 1241 then return true end -- deleted in Instapaper meanwhile: nothing to archive
        return false, apiError(code, body)
    end
    return true
end

function Instapaper.sendProgress(acc, id, progress)
    local code = call("bookmarks/update_read_progress",
        { bookmark_id = id, progress = string.format("%.4f", progress), progress_timestamp = tostring(os.time()) }, acc)
    return code == 200
end

-- The shelf and its index -------------------------------------------------------------------

local function shelfPath()
    return ((Books.root or Books.getRoot()):gsub("/+$", "")) .. "/" .. Instapaper.SHELF
end

local function openIndex()
    local dir = shelfPath()
    local ok, s = pcall(LuaSettings.open, LuaSettings, dir .. "/.polka_instapaper.lua")
    if not ok then return nil, dir end
    return s, dir
end

local function indexItems(s)
    local items = s and s:readSetting("items")
    return type(items) == "table" and items or {}
end

local function host(url)
    return (tostring(url or ""):match("^%a[%w+.-]*://([^/?#:]+)") or ""):gsub("^www%.", "")
end

local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- A page KOReader opens like a book: title and site in its head.
function Instapaper.articleHTML(it, html)
    local body = html:match("<[Bb][Oo][Dd][Yy][^>]*>(.*)</[Bb][Oo][Dd][Yy]>") or html
    body = body:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
    body = body:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", "")
    local site = host(it.url)
    local head = ""
    if not body:find("<[Hh]1") then
        head = "<h1>" .. esc(it.title) .. "</h1>\n" .. (site ~= "" and ("<p><small>" .. esc(site) .. "</small></p>\n") or "")
    end
    return table.concat({
        '<!DOCTYPE html>\n<html><head><meta charset="utf-8">',
        "<title>", esc(it.title), "</title>",
        site ~= "" and ('<meta name="author" content="' .. esc(site) .. '">') or "",
        "</head>\n<body>\n", head, body, "\n</body></html>\n",
    })
end

-- "site - Title.html": the library shows the title, with the site as the author.
local function fileName(it)
    local site = host(it.url)
    local base = (site ~= "" and (site .. " - ") or "") .. it.title
    return Tools.cleanName(base:gsub("[/\\]", "-") .. ".html") -- "A/B" in a title is not a folder
end

-- Downloads one article; returns its path or nil, error.
function Instapaper.download(acc, it, s)
    local html, err = Instapaper.text(acc, it.id)
    if not html then return nil, err end
    local dir = Tools.shelfDir(Instapaper.SHELF)
    local items = indexItems(s)
    local old = items[it.id]
    local name = old and old.file and lfs.attributes(dir .. "/" .. old.file) and old.file or nil
    local path = name and (dir .. "/" .. name) or Tools.uniquePath(dir, fileName(it))
    local part = dir .. "/.instapaper-" .. it.id .. ".part"
    local f = io.open(part, "wb")
    if not f then return nil, "Нет доступа к папке с книгами." end
    local wrote = f:write(Instapaper.articleHTML(it, html))
    local closed = f:close()
    if not wrote or not closed then
        os.remove(part)
        return nil, "Не хватает места на Kindle — статья не сохранилась."
    end
    if name then os.remove(path) end
    if not os.rename(part, path) then
        os.remove(part)
        return nil, "Не удалось сохранить статью."
    end
    items[it.id] = { file = path:match("([^/]+)$"), title = it.title, progress = it.progress or 0 }
    if s then s:saveSetting("items", items) end
    return path
end

-- What the reader did with the downloaded articles goes back to Instapaper:
-- read to the end (or marked finished) -> archived; otherwise the progress.
function Instapaper.sync(acc, s, dir)
    local items = indexItems(s)
    local archived, changed = 0, false
    for id, item in pairs(items) do
        if type(item) == "table" and not item.archived and item.file then
            local path = dir .. "/" .. item.file
            if lfs.attributes(path, "mode") == "file" then
                local f = Books:finishInfo(path)
                local percent = f.percent or 0
                if f.status == "complete" or percent >= 0.98 then
                    if Instapaper.archive(acc, id) then
                        item.archived, changed = true, true
                        archived = archived + 1
                    end
                elseif percent > (item.progress or 0) + 0.01 then
                    if Instapaper.sendProgress(acc, id, percent) then
                        item.progress, changed = percent, true
                    end
                end
            end
        end
    end
    if changed and s then s:saveSetting("items", items) end
    return archived
end

local function flushIndex(s, dir)
    if s and lfs.attributes(dir, "mode") == "directory" then pcall(s.flush, s) end
end

-- State --------------------------------------------------------------------------------------

local function state(shell)
    shell.instapaper = shell.instapaper or { page = 1, starts = { 1 } }
    return shell.instapaper
end

-- With Wi‑Fi off, Polka asks in its own sheet, saying why («reason»).
local function online(fn, reason)
    require("polka_wifi").run(reason or "Нужен, чтобы получить статьи.", fn)
end

-- The shelf's index, opened once per visit to the screen.
local function index(st)
    if not st.index then st.index, st.index_dir = openIndex() end
    return st.index, st.index_dir
end

-- Refresh: send back what was read, then the list of unread articles.
local function load(shell)
    local st = state(shell)
    local acc = Instapaper.account()
    if not acc then return end
    st.auto_loaded = true
    online(function()
        st.loading = true
        Tools.busy("Обновляю Instapaper…")
        local s, dir = index(st)
        local archived = 0
        local ok, err = pcall(function() archived = Instapaper.sync(acc, s, dir) end)
        if not ok then logger.warn("Polka: Instapaper sync:", err) end
        flushIndex(s, dir)
        local list, lerr = Instapaper.list(acc)
        Tools.idle()
        st.loading = false
        if list then
            st.items, st.error = list, nil
            st.page, st.starts = 1, { 1 }
            if archived > 0 then
                UIManager:show(Notification:new{ text = string.format("В архив Instapaper: %d %s", archived,
                    UI.plural(archived, "прочитанная статья", "прочитанные статьи", "прочитанных статей")) })
            end
        else
            st.error = lerr -- a first failure keeps the list unknown, not empty
        end
        if shell.shown then shell:refresh("ui") end
    end)
end

local function downloadOne(shell, it, open_after)
    local acc = Instapaper.account()
    if not acc then return end
    online(function()
        Tools.busy("Скачиваю «" .. it.title .. "»…")
        local s, dir = index(state(shell))
        local path, err = Instapaper.download(acc, it, s)
        flushIndex(s, dir)
        Tools.idle()
        if not path then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        Books.generation = Books.generation + 1
        Instapaper.new_books = true
        if open_after then
            shell:openBook(path)
        else
            shell:refresh("ui")
        end
    end, "Нужен, чтобы скачать статью.")
end

local function downloadAll(shell, list)
    local acc = Instapaper.account()
    if not acc or #list == 0 then return end
    online(function()
        local s, dir = index(state(shell))
        local done, failed = 0, nil
        for i, it in ipairs(list) do
            Tools.busy(string.format("Скачиваю статьи: %d из %d", i, #list))
            local path, err = Instapaper.download(acc, it, s)
            if path then done = done + 1 else failed = failed or err end
        end
        flushIndex(s, dir)
        Tools.idle()
        if done > 0 then
            Books.generation = Books.generation + 1
            Instapaper.new_books = true
        end
        if failed then
            UIManager:show(InfoMessage:new{ text = string.format("Скачано %d из %d.\n%s", done, #list, failed) })
        else
            UIManager:show(Notification:new{ text = string.format("На полке «%s»: %d %s", Instapaper.SHELF, done,
                UI.plural(done, "статья", "статьи", "статей")) })
        end
        shell:refresh("ui")
    end, "Нужен, чтобы скачать статьи.")
end

local function connected(shell)
    local st = state(shell)
    st.mode, st.items, st.error, st.phone_error = nil, nil, nil, nil
    if shell.shown then shell:refresh("ui") end
end

local function trim(s) return util.trim(tostring(s or "")) end

local function enterHere(shell)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = "Instapaper",
        fields = {
            { description = "Consumer Key", text = "", hint = "" },
            { description = "Consumer Secret", text = "", hint = "" },
            { description = "Email или имя в Instapaper", text = "", hint = "" },
            { description = "Пароль, если есть", text = "", hint = "", text_type = "password" },
        },
        buttons = {{
            { text = "Отмена", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Подключить", is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local key, secret, user = trim(f[1]), trim(f[2]), trim(f[3])
                if key == "" or secret == "" or user == "" then
                    UIManager:show(Notification:new{ text = "Нужны ключ, секрет и email" })
                    return
                end
                UIManager:close(dialog)
                online(function()
                    Tools.busy("Подключаю Instapaper…")
                    local acc, err = Instapaper.login(key, secret, user, f[4] or "")
                    Tools.idle()
                    if not acc then
                        UIManager:show(InfoMessage:new{ text = err })
                        return
                    end
                    connected(shell)
                end, "Нужен, чтобы подключить Instapaper.")
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The page a phone gets while "На телефоне" is shown.
local PAGE = [[<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Полка · Instapaper</title>
<style>
:root{--ink:#111;--muted:#666;--paper:#fafaf7}
*{box-sizing:border-box}
body{margin:0;font:16px/1.45 Georgia,"Times New Roman",serif;color:var(--ink);background:var(--paper)}
main{max-width:560px;margin:0 auto;padding:28px 18px 60px}
h1{font-size:30px;margin:0 0 4px}
p{font-family:-apple-system,system-ui,sans-serif;font-size:15px;color:var(--muted);margin:0 0 18px}
a{color:var(--ink)}
label{display:block;font:600 13px -apple-system,system-ui,sans-serif;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin:16px 0 6px}
input{width:100%;font:17px -apple-system,system-ui,sans-serif;padding:12px;border:1px solid #bbb;border-radius:10px;background:#fff;color:var(--ink)}
button{margin-top:22px;width:100%;font:600 17px -apple-system,system-ui,sans-serif;padding:14px;border:0;border-radius:12px;background:var(--ink);color:#fff}
button:disabled{background:#999}
#msg{margin-top:18px;font-size:16px;color:var(--ink)}
</style></head><body><main>
<h1>Instapaper</h1>
<p>Ключ и секрет — со страницы <a href="__CREATE__">instapaper.com/developers/applications/create</a> (название любое, «Owner Only»). Пароль Kindle не сохраняет: он нужен один раз, чтобы получить доступ.</p>
<label for="k">Consumer Key</label><input id="k" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">
<label for="s">Consumer Secret</label><input id="s" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">
<label for="u">Email или имя в Instapaper</label><input id="u" type="email" autocomplete="username" autocapitalize="off">
<label for="p">Пароль, если есть</label><input id="p" type="password" autocomplete="current-password">
<button id="go">Подключить Kindle</button>
<p id="msg"></p>
<p style="font-size:13px;margin-top:28px">Страница идёт с Kindle по вашей сети Wi‑Fi без шифрования — подключайте дома, а не в общественной сети.</p>
</main><script>
var $=function(id){return document.getElementById(id)};
$("go").onclick=function(){
 var b=$("go"),m=$("msg");b.disabled=true;m.textContent="Подключаю…";
 var x=new XMLHttpRequest();x.open("POST","__BASE__/instapaper");
 x.setRequestHeader("Content-Type","application/x-www-form-urlencoded");
 x.onload=function(){var r={};try{r=JSON.parse(x.responseText)}catch(e){}
  m.textContent=r.message||"Ошибка";b.disabled=!!r.ok};
 x.onerror=function(){m.textContent="Нет связи с Kindle — экран «Instapaper» должен быть открыт.";b.disabled=false};
 x.send(new URLSearchParams({key:$("k").value.trim(),secret:$("s").value.trim(),user:$("u").value.trim(),password:$("p").value}).toString())}
</script></body></html>]]

local function phonePage()
    return (PAGE:gsub("__CREATE__", Instapaper.CREATE_URL))
end

local function phoneForm(shell)
    return function(fields)
        local key, secret, user = trim(fields.key), trim(fields.secret), trim(fields.user)
        if key == "" or secret == "" or user == "" then
            return 400, false, "Заполните ключ, секрет и email."
        end
        Tools.busy("Подключаю Instapaper…")
        local acc, err = Instapaper.login(key, secret, user, fields.password or "")
        Tools.idle()
        local st = state(shell)
        if not acc then
            st.phone_error = err
            UIManager:nextTick(function() if shell.shown then shell:refresh("ui") end end)
            return 200, false, err
        end
        UIManager:nextTick(function() connected(shell) end)
        return 200, true, "Готово: Kindle подключён к Instapaper. Страницу можно закрыть."
    end
end

-- Drawing ------------------------------------------------------------------------------------

local function button(text, filled, cb)
    return UI.tap(UI.pill(UI.text{ text = text, size = 16, family = "sans_bold", color = filled and UI.C.paper or UI.C.ink },
        { background = filled and UI.C.ink or UI.C.paper, border_color = UI.C.ink,
          hpad = UI.px(18), vpad = UI.px(9), radius = UI.px(18) }), cb)
end

local function step(cw, n, content)
    local num_w = UI.px(34)
    return HorizontalGroup:new{
        align = "top",
        UI.left(num_w, UI.text{ text = tostring(n), family = "serif_bold", size = 22 }),
        content,
    }
end

local function setupView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(vg, w) end
    add(Tools.header(shell, cw, "Instapaper"))
    add(UI.vgap(UI.px(12)))
    add(UI.para{ text = "Отложенные статьи — как книги: они скачиваются на полку «Instapaper», а дочитанные сами уходят в архив Instapaper.",
                 size = 16, width = cw })
    add(UI.vgap(UI.px(22)))
    add(UI.text{ text = "Подключение — один раз", family = "sans_bold", size = 14, color = UI.C.text2 })
    add(UI.vgap(UI.px(12)))
    local text_w = cw - UI.px(34)
    local qr_size = UI.px(118)
    local QRWidget = require("ui/widget/qrwidget")
    local first = VerticalGroup:new{
        align = "left",
        UI.para{ text = "На телефоне или компьютере откройте", size = 15, width = text_w - qr_size - UI.px(14) },
        UI.para{ text = "instapaper.com/developers/applications/create", family = "sans_bold", size = 15,
                 width = text_w - qr_size - UI.px(14) },
        UI.vgap(UI.px(6)),
        UI.para{ text = "и создайте приложение с любым названием. Оставьте «Owner Only» — сразу появятся Consumer Key и Consumer Secret.",
                 size = 14, color = UI.C.text2, width = text_w - qr_size - UI.px(14) },
    }
    add(step(cw, 1, HorizontalGroup:new{
        align = "top",
        first,
        UI.hgap(UI.px(14)),
        QRWidget:new{ text = Instapaper.CREATE_URL, width = qr_size, height = qr_size },
    }))
    add(UI.vgap(UI.px(20)))
    add(step(cw, 2, VerticalGroup:new{
        align = "left",
        UI.para{ text = "Перенесите ключи и логин Instapaper на Kindle — удобнее всего с телефона:", size = 15, width = text_w },
        UI.vgap(UI.px(12)),
        HorizontalGroup:new{
            align = "center",
            button("С телефона", true, function()
                state(shell).mode = "phone"
                shell:refresh("ui")
            end),
            UI.hgap(UI.px(10)),
            button("Ввести здесь", false, function() enterHere(shell) end),
        },
    }))
    add(UI.vgap(UI.px(20)))
    add(UI.para{ text = "Пароль на Kindle не хранится: он нужен один раз, чтобы получить доступ.", size = 13,
                 color = UI.C.text3, width = cw })
    return UI.pad(vg, { left = M, right = M })
end

local function phoneView(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local vg = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(vg, w) end
    add(UI.tap(UI.pad(UI.text{ text = "‹  Instapaper", size = 15, color = UI.C.text2 },
        { top = UI.px(10), bottom = UI.px(6), right = UI.px(30) }), function()
        st.mode = nil
        shell:refresh("ui")
    end))
    add(UI.text{ text = "Ключи с телефона", family = "serif_bold", size = 26, max_width = cw })
    add(UI.vgap(UI.px(18)))
    local Transfer = require("polka_transfer")
    local ip = Transfer.localIP()
    if not ip then
        Transfer.stop()
        add(UI.para{ text = "Нужен Wi‑Fi: Kindle и телефон должны быть в одной сети.", size = 17, width = cw, color = UI.C.text2 })
        add(UI.vgap(UI.px(22)))
        local Wifi = require("polka_wifi")
        add(button(Wifi.connecting and "Подключаюсь…" or "Включить Wi‑Fi", true, function()
            if Wifi.connecting then return end
            Wifi.toggle(true, function() if shell.shown then shell:refresh("ui") end end)
        end))
        return UI.pad(vg, { left = M, right = M })
    end
    local ok, err = Transfer.start(shell, "instapaper", { page = phonePage, forms = { ["/instapaper"] = phoneForm(shell) } })
    if not ok then
        add(UI.para{ text = Transfer.portProblem(err), size = 16, width = cw, color = UI.C.text2 })
        return UI.pad(vg, { left = M, right = M })
    end
    local url = Transfer.url(ip)
    local qr_size = UI.px(170)
    local text_w = cw - qr_size - UI.px(20)
    add(HorizontalGroup:new{
        align = "center",
        require("ui/widget/qrwidget"):new{ text = url, width = qr_size, height = qr_size },
        UI.hgap(UI.px(20)),
        VerticalGroup:new{
            align = "left",
            UI.para{ text = "Откройте на телефоне в той же сети Wi‑Fi:", size = 15, color = UI.C.text2, width = text_w },
            UI.vgap(UI.px(8)),
            UI.para{ text = url, family = "sans_bold", size = 18, width = text_w },
            UI.vgap(UI.px(8)),
            UI.para{ text = "и вставьте ключ, секрет и логин Instapaper.", size = 15, color = UI.C.text2, width = text_w },
        },
    })
    add(UI.vgap(UI.px(24)))
    add(UI.hline(cw))
    add(UI.vgap(UI.px(14)))
    if st.phone_error then
        add(UI.para{ text = st.phone_error, size = 16, width = cw })
        add(UI.vgap(UI.px(6)))
        add(UI.para{ text = "Исправьте на телефоне и нажмите «Подключить Kindle» ещё раз.", size = 14, color = UI.C.text3, width = cw })
    else
        add(UI.para{ text = "Жду ключи…", size = 16, color = UI.C.text2, width = cw })
    end
    return UI.pad(vg, { left = M, right = M })
end

local function articleRow(shell, it, cw, s, dir)
    local items = indexItems(s)
    local local_item = items[it.id]
    local path = local_item and local_item.file and (dir .. "/" .. local_item.file)
    if path and lfs.attributes(path, "mode") ~= "file" then path = nil end
    local status
    if path then
        local f = Books:finishInfo(path)
        if f.status == "complete" or (f.percent or 0) >= 0.98 then
            status = "✓ прочитано"
        elseif (f.percent or 0) > 0 then
            status = UI.percent(f.percent)
        else
            status = "на Kindle"
        end
    end
    local text_w = cw - UI.px(120)
    local meta = {}
    local site = host(it.url)
    if site ~= "" then meta[#meta + 1] = site end
    if it.time then
        local d = os.date("*t", it.time)
        meta[#meta + 1] = string.format("%d %s", d.day, UI.MONTHS_SHORT[d.month])
    end
    local texts = VerticalGroup:new{
        align = "left",
        UI.vgap(UI.px(12)),
        UI.para{ text = it.title, family = "serif_bold", size = 17, width = text_w, max_lines = 2 },
        UI.vgap(UI.px(3)),
        UI.text{ text = table.concat(meta, " · "), size = 13, color = UI.C.text3, max_width = text_w },
        UI.vgap(UI.px(12)),
    }
    local right
    if status then
        right = UI.text{ text = status, size = 14, family = "sans_bold", color = UI.C.ink }
    else
        right = UI.text{ text = "Скачать", size = 14, color = UI.C.text2 }
    end
    return UI.tap(VerticalGroup:new{
        align = "left",
        UI.split(cw, texts, right, texts:getSize().h),
        UI.hline(cw),
    }, function()
        if path then
            shell:openBook(path)
        else
            downloadOne(shell, it, false)
        end
    end, function()
        local dialog
        local buttons = {
            {{ text = path and "Читать" or "Скачать и читать", callback = function()
                UIManager:close(dialog)
                if path then shell:openBook(path) else downloadOne(shell, it, true) end
            end }},
        }
        if path then
            table.insert(buttons, {{ text = "Скачать заново", callback = function()
                UIManager:close(dialog)
                downloadOne(shell, it, false)
            end }})
        end
        table.insert(buttons, {{ text = "В архив Instapaper", callback = function()
            UIManager:close(dialog)
            local acc = Instapaper.account()
            if not acc then return end
            online(function()
                Tools.busy("Отправляю в архив…")
                local ok, err = Instapaper.archive(acc, it.id)
                Tools.idle()
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err })
                    return
                end
                local st = state(shell)
                for i, x in ipairs(st.items or {}) do
                    if x.id == it.id then table.remove(st.items, i) break end
                end
                if local_item then
                    local_item.archived = true
                    s:saveSetting("items", items)
                    flushIndex(s, dir)
                end
                st.starts = { 1 }
                st.page = 1
                shell:refresh("ui")
            end, "Нужен, чтобы отправить статью в архив.")
        end }})
        dialog = ButtonDialog:new{ title = it.title, title_align = "center", buttons = buttons }
        UIManager:show(dialog)
    end)
end

local function accountActions(shell, acc)
    local dialog
    dialog = ButtonDialog:new{
        title = acc.user or "Instapaper",
        title_align = "center",
        buttons = {
            {{ text = "Обновить", callback = function() UIManager:close(dialog); load(shell) end }},
            {{ text = "Отключить Instapaper", callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = "Отключить Instapaper? Скачанные статьи останутся на полке.",
                    ok_text = "Отключить",
                    cancel_text = "Отмена",
                    ok_callback = function()
                        G_reader_settings:delSetting("polka_instapaper")
                        shell.instapaper = nil
                        shell:refresh("ui")
                    end,
                })
            end }},
        },
    }
    UIManager:show(dialog)
end

local function listView(shell, W, H, acc)
    local M = shell:margin()
    local cw = W - 2 * M
    local st = state(shell)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    local refresh_link = UI.tap(UI.pad(UI.text{ text = "Обновить", size = 16, color = UI.C.ink },
        { left = UI.px(20), top = UI.px(8), bottom = UI.px(8) }), function() load(shell) end)
    add(Tools.header(shell, cw, "Instapaper", refresh_link))
    if not st.items then
        if not st.loading and not st.auto_loaded then
            st.auto_loaded = true -- once per visit; afterwards «Обновить» or «Повторить»
            UIManager:nextTick(function() load(shell) end)
        end
        add(UI.vgap(UI.px(30)))
        if st.error then
            add(UI.para{ text = st.error, size = 17, width = cw, align = "center" })
            add(UI.vgap(UI.px(18)))
            add(UI.center(cw, nil, button("Повторить", true, function() load(shell) end)))
        else
            add(UI.para{ text = "Загружаю статьи…", size = 17, color = UI.C.text2, width = cw, align = "center" })
        end
        return UI.pad(vg, { left = M, right = M })
    end
    local items = st.items
    local s, dir = index(st)
    local known = indexItems(s)
    local missing = {}
    for _, it in ipairs(items) do
        local x = known[it.id]
        if not (x and x.file and lfs.attributes(dir .. "/" .. x.file, "mode") == "file") then
            missing[#missing + 1] = it
        end
    end
    local count = #items == 0 and "нет непрочитанных" or string.format("%d %s", #items,
        UI.plural(#items, "непрочитанная статья", "непрочитанные статьи", "непрочитанных статей"))
    add(UI.tap(UI.pad(UI.text{ text = (acc.user or "Instapaper") .. "  ·  " .. count .. "  ▾", size = 14, color = UI.C.text2,
                               max_width = cw }, { top = UI.px(4), bottom = UI.px(4) }),
        function() accountActions(shell, acc) end))
    if st.error then
        add(UI.vgap(UI.px(8)))
        add(UI.para{ text = st.error, size = 15, width = cw })
    end
    if #missing > 0 then
        add(UI.vgap(UI.px(12)))
        add(button(string.format("Скачать %s", #missing == #items and ("все — " .. #missing) or ("новые — " .. #missing)), true,
            function() downloadAll(shell, missing) end))
    end
    add(UI.vgap(UI.px(10)))
    add(UI.hline(cw))
    if #items == 0 then
        add(UI.vgap(UI.px(30)))
        add(UI.para{ text = "Все статьи прочитаны.", family = "serif_bold", size = 20, width = cw, align = "center" })
        add(UI.vgap(UI.px(8)))
        add(UI.para{ text = "Сохраняйте новые в Instapaper — с телефона или из браузера — и нажмите «Обновить».",
                     size = 15, color = UI.C.text2, width = cw, align = "center" })
        return UI.pad(vg, { left = M, right = M })
    end
    local footer_h = UI.px(52)
    local rows, next_i = Tools.fillPage(items, st.starts[st.page] or 1, H - used - footer_h, function(it)
        return articleRow(shell, it, cw, s, dir)
    end)
    add(rows)
    st.starts[st.page + 1] = items[next_i] and next_i or nil
    if st.page > 1 or items[next_i] then
        local spare = H - used - footer_h
        if spare > 0 then add(UI.vgap(spare)) end
        add(Tools.pagerBar(cw, footer_h, "стр. " .. st.page, st.page > 1, items[next_i] ~= nil, function(delta)
            Instapaper.turn(shell, delta)
        end))
    end
    return UI.pad(vg, { left = M, right = M })
end

function Instapaper.build(shell, W, H)
    local st = state(shell)
    local acc = Instapaper.account()
    if st.mode == "phone" and not acc then return phoneView(shell, W, H) end
    if require("polka_transfer").owner() == "instapaper" then require("polka_transfer").stop() end
    if not acc then return setupView(shell, W, H) end
    return listView(shell, W, H, acc)
end

function Instapaper.turn(shell, delta)
    local st = state(shell)
    local p = st.page + delta
    if p < 1 or not st.starts[p] then return end
    st.page = p
    shell:refresh("ui")
end

function Instapaper.swipe(shell, dir)
    Instapaper.turn(shell, dir == "west" and 1 or -1)
end

function Instapaper.summary()
    local acc = Instapaper.account()
    if not acc then return nil end
    return "Подключено" .. (acc.user and (": " .. acc.user) or "")
end

function Instapaper.leave(shell)
    local Transfer = require("polka_transfer")
    if Transfer.owner() == "instapaper" then Transfer.stop() end
    shell.instapaper = nil
    if Instapaper.new_books then
        Instapaper.new_books = false
        Books:scan()
    end
end

function Instapaper.suspend(shell)
    local Transfer = require("polka_transfer")
    if Transfer.owner() == "instapaper" then Transfer.stop() end
end

return Instapaper
