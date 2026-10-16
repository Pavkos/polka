-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: talking to the network without making anyone wait.

KOReader's HTTP calls block. Polka runs each one in a forked copy of
KOReader (as the site sync does): the copy makes the request, writes the
answer back through a pipe as JSON and exits, while the screen keeps
answering taps. The copy never touches the screen or KOReader's files.
]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")

local Net = {}

-- JSON ------------------------------------------------------------------------

local ok_rj, rapidjson = pcall(require, "rapidjson")

function Net.encode(t)
    if ok_rj then return rapidjson.encode(t) end
    return require("json").encode(t)
end

-- JSON null never reaches Lua code: it becomes nil.
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

function Net.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, t
    if ok_rj then ok, t = pcall(rapidjson.decode, s) else ok, t = pcall(require("json").decode, s) end
    if ok and type(t) == "table" then return denull(t) end
end

-- An empty Lua table goes out as {}; lists want [].
function Net.list(t)
    if ok_rj and rapidjson.array then return rapidjson.array(t) end
    return t
end

-- Checked HTTPS -------------------------------------------------------------------
--[[
KOReader's LuaSec checks nothing by itself (verify = "none"): anyone on the
network could pretend to be the site, read the Kindle's key and hand out an
update of their own. So every https request made here checks the server:
  - its certificate chain, against KOReader's own list of authorities
    (data/ca-bundle.crt in KOReader's folder) — by the TLS library, which
    breaks off the handshake when the chain does not hold;
  - that the certificate was issued for the site's name (subjectAltName
    dNSName entries; "*.example.com" stands for one left-most label only;
    the common name only when there is no subjectAltName at all).
Only then does the request go out. When the check fails nothing is sent:
the caller gets "polka-tls:clock" (the certificate is outside its dates —
on a Kindle, almost always its clock) or "polka-tls:peer", and the details
go to the log.
]]

Net.CAFILE = nil -- the authorities' file, once found (a test may set its own)

local function isFile(path)
    local lfs = require("libs/libkoreader-lfs")
    return path and lfs.attributes(path, "mode") == "file" and path or nil
end

--- KOReader's data/ca-bundle.crt, found from where KOReader is installed
-- (not from the current folder).
function Net.cafile()
    if Net.CAFILE then return Net.CAFILE end
    local ffiutil = require("ffi/util")
    local found
    -- the program that runs is KOReader's own luajit, in its folder
    local ok, exe = pcall(ffiutil.realpath, "/proc/self/exe")
    if ok and type(exe) == "string" then
        found = isFile(exe:gsub("/[^/]*$", "") .. "/data/ca-bundle.crt")
    end
    -- where KOReader's own LuaSec comes from: <koreader>/common/ssl/https.lua
    if not found and package.searchpath then
        local p = package.searchpath("ssl.https", package.path)
        local real = p and ffiutil.realpath(p)
        if real then found = isFile(real:gsub("/common/ssl/https%.lua$", "") .. "/data/ca-bundle.crt") end
    end
    found = found or isFile("/mnt/us/koreader/data/ca-bundle.crt")
    Net.CAFILE = found
    return found
end

-- TLS 1.2 or newer; the second list is LuaSec's own, for a library that
-- does not know some of the names.
local OPTIONS = {
    { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1", "no_compression" },
    { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
}

local contexts = {} -- [cafile .. mode] = context, made once per process

-- The TLS context: "strict" fails the handshake on a bad chain; "explain"
-- lets it finish so that the reasons can be read (never used to send).
local function context(mode)
    local cafile = Net.cafile()
    if not cafile then return nil, "no data/ca-bundle.crt" end
    local key = cafile .. "|" .. mode
    if contexts[key] then return contexts[key] end
    local ssl = require("ssl")
    local ctx, err
    for _, options in ipairs(OPTIONS) do
        ctx, err = ssl.newcontext{
            mode = "client",
            protocol = "any",
            options = options,
            verify = { "peer", "fail_if_no_peer_cert" },
            verifyext = mode == "explain" and { "lsec_continue" } or nil,
            cafile = cafile,
        }
        if ctx then break end
    end
    if not ctx then return nil, err end
    contexts[key] = ctx
    return ctx
end

local function ipLiteral(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true)
end

--- Does a name from a certificate stand for host? RFC 6125: the same name,
-- or a wildcard that is the whole left-most label ("*.example.com" covers
-- "a.example.com", but not "example.com" nor "a.b.example.com").
function Net.nameMatches(pattern, host)
    if type(pattern) ~= "string" or type(host) ~= "string" or pattern == "" then return false end
    pattern = pattern:lower():gsub("%.$", "")
    host = host:lower():gsub("%.$", "")
    if pattern == host then return true end
    local rest = pattern:match("^%*%.(.+)$")
    if not rest or rest:find("*", 1, true) or not rest:find(".", 1, true) or ipLiteral(host) then
        return false
    end
    return host:match("^[^.]+%.(.+)$") == rest
end

--- Was this certificate (LuaSec x509) issued for host? Its subjectAltName
-- names when it has the extension; the common name only when it has none.
function Net.certCovers(cert, host)
    host = tostring(host or ""):lower():gsub("%.$", "")
    if host == "" then return false end
    local ok, ext = pcall(cert.extensions, cert)
    if not ok or type(ext) ~= "table" then return false end
    local san = ext["2.5.29.17"]
    if san ~= nil then
        if type(san) ~= "table" then return false end
        local list = ipLiteral(host) and san.iPAddress or san.dNSName
        for _, name in ipairs(type(list) == "table" and list or {}) do
            if ipLiteral(host) then
                if name == host then return true end
            elseif Net.nameMatches(name, host) then
                return true
            end
        end
        return false
    end
    if ipLiteral(host) then return false end
    local ok_s, subject = pcall(cert.subject, cert)
    local cn
    for _, e in ipairs(ok_s and type(subject) == "table" and subject or {}) do
        if type(e) == "table" and e.oid == "2.5.4.3" then cn = e.value end -- the last, most specific
    end
    return Net.nameMatches(cn, host)
end

-- Why the chain did not hold: a second handshake that is allowed to finish
-- so the reasons can be read; nothing is sent over it.
local function explain(addr, port, host, timeout)
    local socket = require("socket")
    local ssl = require("ssl")
    local ctx = context("explain")
    local tcp = ctx and socket.tcp()
    if not tcp then return "peer", "no second look" end
    tcp:settimeout(timeout)
    if not tcp:connect(addr, port) then
        tcp:close()
        return "peer", "no second connection"
    end
    local s = ssl.wrap(tcp, ctx)
    if not s then
        tcp:close()
        return "peer", "no second look"
    end
    if not ipLiteral(host) then s:sni(host) end
    s:settimeout(timeout)
    local reasons, clock = {}, false
    if s:dohandshake() then
        local verified, errs = s:getpeerverification()
        if not verified then
            for _, list in pairs(type(errs) == "table" and errs or { { tostring(errs) } }) do
                for _, m in ipairs(type(list) == "table" and list or { tostring(list) }) do
                    reasons[#reasons + 1] = tostring(m)
                    if tostring(m):find("not yet valid", 1, true) or tostring(m):find("expired", 1, true) then
                        clock = true
                    end
                end
            end
        end
    end
    s:close()
    return clock and "clock" or "peer", table.concat(reasons, "; ")
end

--- A LuaSocket `create` for an https request to host: connects, shakes hands
-- with a checked chain, checks the name, and only then lets the request go.
function Net.tlsCreate(host)
    local socket = require("socket")
    local ssl = require("ssl")
    local https = require("ssl.https")
    local function refuse(conn, kind, detail)
        logger.warn("Polka net: refused " .. host .. " (" .. kind .. "): " .. tostring(detail))
        pcall(function() conn.sock:close() end)
        socket.try(nil, "polka-tls:" .. kind)
    end
    return function()
        local conn = { sock = socket.try(socket.tcp()) }
        function conn:settimeout(...)
            return self.sock:settimeout(...)
        end
        function conn:connect(addr, port)
            local ok_c, err_c = self.sock:connect(addr, port)
            if not ok_c then
                self.sock:close()
                socket.try(nil, err_c)
            end
            local ctx, err = context("strict")
            if not ctx then refuse(self, "peer", "no TLS context: " .. tostring(err)) end
            local s, err_w = ssl.wrap(self.sock, ctx)
            if not s then refuse(self, "peer", "wrap: " .. tostring(err_w)) end
            self.sock = s
            if not ipLiteral(host) then s:sni(host) end
            s:settimeout(https.TIMEOUT)
            local ok_h, err_h = s:dohandshake()
            if not ok_h then
                if tostring(err_h):find("certificate verify failed", 1, true) then
                    s:close()
                    local kind, why = explain(addr, port, host, https.TIMEOUT)
                    refuse(self, kind, "certificate: " .. (why ~= "" and why or tostring(err_h)))
                end
                s:close()
                socket.try(nil, err_h) -- the network, not the certificate
            end
            local cert = s:getpeercertificate()
            if s:getpeerverification() ~= true or not cert then
                refuse(self, "peer", "no verified certificate")
            end
            if not Net.certCovers(cert, host) then
                refuse(self, "peer", "the certificate is not for this name")
            end
            -- checked: from here on the connection is the TLS one
            local mt = getmetatable(s).__index
            for name, method in pairs(mt) do
                if type(method) == "function" then
                    self[name] = function(c, ...) return method(c.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

-- HTTP (blocking: for the forked process) ---------------------------------------

Net.VERSION = "1"

--- One request. o: { url, method, json = table, body = string, ctype, token,
-- headers = { extra }, sink = ltn12 sink, timeouts = { block, total } }.
-- https is always checked (see above); redirects are not followed.
-- Returns the HTTP code (or nil), the body (unless a sink was given), an error.
function Net.request(o)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local url = require("socket.url")
    local chunks = {}
    local body = o.body
    local ctype = o.ctype
    if o.json ~= nil then
        local ok, enc = pcall(Net.encode, o.json)
        if not ok then return nil, nil, "encode" end
        body, ctype = enc, "application/json"
    end
    local headers = {
        ["Accept-Encoding"] = "identity",
        ["User-Agent"] = "Polka/" .. Net.VERSION .. " (KOReader)",
    }
    if o.token then headers["Authorization"] = "Bearer " .. o.token end
    for k, v in pairs(o.headers or {}) do headers[k] = v end
    if body then
        headers["Content-Type"] = ctype or "application/octet-stream"
        headers["Content-Length"] = tostring(#body)
    end
    local reqt = {
        url = o.url,
        method = o.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = o.sink or socketutil.table_sink(chunks),
        redirect = false, -- the site never redirects; nothing goes where it was not sent
    }
    local parsed = url.parse(o.url or "")
    if parsed and parsed.scheme == "https" then
        if not parsed.host or parsed.host == "" then return nil, nil, "bad url" end
        reqt.create = Net.tlsCreate(parsed.host:lower())
    end
    local t = o.timeouts or { 15, 60 }
    socketutil:set_timeout(t[1], t[2])
    local ok, code = pcall(function()
        return socket.skip(1, http.request(reqt))
    end)
    socketutil:reset_timeout()
    if not ok then return nil, nil, tostring(code) end
    if type(code) ~= "number" then return nil, nil, tostring(code) end
    return code, not o.sink and table.concat(chunks) or nil
end

--- What kind of failure a request's error is: "clock" (the site's certificate
-- is outside its dates: the Kindle's clock), "timeout" or "network".
function Net.errorKind(err)
    err = tostring(err or "")
    if err:find("polka-tls:clock", 1, true) then return "clock" end
    if err:find("timeout", 1, true) or err == "wantread" or err == "wantwrite" then return "timeout" end
    return "network"
end

-- On a line of its own (a status, a sheet).
Net.CLOCK = "Не удалось проверить сайт. Проверьте дату и время на Kindle."

--- What went wrong with a background request, in Russian (for messages).
function Net.why(err)
    if err == "timeout" then return "сайт не ответил вовремя" end
    if err == "network" then return "нет связи с сайтом" end
    if err == "clock" then return "не удалось проверить сайт — проверьте дату и время на Kindle" end
    if err == "unauthorized" then return "сайт не принял ключ" end
    if err == "too_many" then return "слишком много запросов подряд" end
    if err == "server" then return "сайт ответил ошибкой" end
    return "что-то пошло не так"
end

--- A JSON request; returns { status = code, data = decoded table } or { error = "..." }.
function Net.call(o)
    local code, body, err = Net.request(o)
    if not code then
        return { error = Net.errorKind(err) }
    end
    return { status = code, data = Net.decode(body) }
end

-- In the background ------------------------------------------------------------

local function closeFD(fd)
    pcall(function()
        local ffi = require("ffi")
        require("ffi/posix_h")
        ffi.C.close(fd)
    end)
end

local function mono()
    local time = require("ui/time")
    return time.to_s(time.monotonic())
end

--- Runs work() in a forked copy of KOReader; on_done(result) is called back
-- here with the table work() returned ({ error = ... } when it failed,
-- timed out or could not start). Returns a handle with :cancel().
function Net.async(work, on_done, timeout)
    timeout = timeout or 90
    local pid, fd = ffiutil.runInSubProcess(function(_, wfd)
        local ok, res = pcall(work)
        if not ok then res = { error = "crash", detail = tostring(res):sub(1, 300) } end
        if type(res) ~= "table" then res = { value = res } end
        local ok_enc, s = pcall(Net.encode, res)
        ffiutil.writeToFD(wfd, ok_enc and s or '{"error":"encode"}', true)
    end, true)
    if not pid then
        logger.warn("Polka net: cannot start:", fd)
        UIManager:nextTick(function() on_done({ error = "fork" }) end)
        return nil
    end
    local handle = { pid = pid }
    local started = mono()
    local poll
    local function finish(res)
        handle.done = true
        local ok, err = xpcall(on_done, debug.traceback, res)
        if not ok then logger.err("Polka net:", err) end
    end
    poll = function()
        if handle.cancelled then return end
        if ffiutil.isSubProcessDone(pid) then
            local data = ffiutil.readAllFromFD(fd)
            return finish(Net.decode(data) or { error = "empty" })
        end
        if mono() - started > timeout then
            ffiutil.terminateSubProcess(pid)
            closeFD(fd)
            handle.cancelled = true
            -- reap it later, it was just killed
            UIManager:scheduleIn(1, function() ffiutil.isSubProcessDone(pid) end)
            return finish({ error = "timeout" })
        end
        UIManager:scheduleIn(0.25, poll)
    end
    function handle:cancel()
        if self.done or self.cancelled then return end
        self.cancelled = true
        UIManager:unschedule(poll)
        ffiutil.terminateSubProcess(pid)
        closeFD(fd)
        UIManager:scheduleIn(1, function() ffiutil.isSubProcessDone(pid) end)
    end
    UIManager:scheduleIn(0.15, poll)
    return handle
end

return Net
