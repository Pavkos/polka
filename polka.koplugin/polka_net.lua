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

-- HTTP (blocking: for the forked process) ---------------------------------------

Net.VERSION = "1"

--- One request. o: { url, method, json = table, body = string, ctype, token,
-- sink = ltn12 sink, timeouts = { block, total } }.
-- Returns the HTTP code (or nil), the body (unless a sink was given), an error.
function Net.request(o)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
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
    if body then
        headers["Content-Type"] = ctype or "application/octet-stream"
        headers["Content-Length"] = tostring(#body)
    end
    local t = o.timeouts or { 15, 60 }
    socketutil:set_timeout(t[1], t[2])
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = o.url,
            method = o.method or (body and "POST" or "GET"),
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = o.sink or socketutil.table_sink(chunks),
        })
    end)
    socketutil:reset_timeout()
    if not ok then return nil, nil, tostring(code) end
    if type(code) ~= "number" then return nil, nil, tostring(code) end
    return code, not o.sink and table.concat(chunks) or nil
end

--- What went wrong with a background request, in Russian (for messages).
function Net.why(err)
    if err == "timeout" then return "сайт не ответил вовремя" end
    if err == "network" then return "нет связи с сайтом" end
    if err == "unauthorized" then return "сайт не принял ключ" end
    if err == "too_many" then return "слишком много запросов подряд" end
    if err == "server" then return "сайт ответил ошибкой" end
    return "что-то пошло не так"
end

--- A JSON request; returns { status = code, data = decoded table } or { error = "..." }.
function Net.call(o)
    local code, body, err = Net.request(o)
    if not code then
        return { error = (tostring(err):find("timeout") and "timeout") or "network" }
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
