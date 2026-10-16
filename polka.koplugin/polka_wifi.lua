-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Wi‑Fi without KOReader's dialogs.

When something needs the network and Wi‑Fi is off, KOReader asks «Вы хотите
включить Wi‑Fi?» in a box, then shows «Включение Wi‑Fi…», «Поиск сетей…»,
«Подключение к сети…» one after another. Polka asks once, in its own sheet
(«Включить Wi‑Fi?» — why it is needed — «Включить» / «Не сейчас»), then
lets the Kindle join a network it already knows, quietly, and carries on by
itself. Only when no known network is around does it say so, and offers
KOReader's list of networks.

NetworkMgr is one shared object: its promptWifiOn (used only when KOReader
is set to ask before turning Wi‑Fi on, the default) is replaced. Someone
who chose "turn on without asking" or "ignore" in KOReader keeps that.
]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Sheet = require("polka_sheet")
local UI = require("polka_ui")

local Wifi = {
    reason = nil,   -- why the network is needed, for the next question
}

local CONNECT_TIMEOUT = 45
local AFTER = "Подключусь к знакомой сети и продолжу сам."

local function NetworkMgr()
    return require("ui/network/manager")
end

-- The Kindle joins a known network by itself once its Wi‑Fi is on.
local function canConnectQuietly()
    local nm = NetworkMgr()
    if Device:isKindle() then
        return Device:hasWifiRestore() and type(nm.restoreWifiAsync) == "function"
    end
    return Device:isEmulator() == true
end

local function connected()
    local nm = NetworkMgr()
    local ok, yes = pcall(nm.isConnected, nm)
    return ok and yes
end

-- What KOReader does once a connection is up (its connectivity check).
local function settle(broadcast)
    local nm = NetworkMgr()
    nm:queryNetworkState()
    nm.wifi_was_on = true
    G_reader_settings:makeTrue("wifi_was_on")
    pcall(function()
        local current = nm:getCurrentNetwork()
        if current and current.ssid then nm.lease_ssid = current.ssid end
    end)
    nm.pending_connection = false
    if broadcast then UIManager:broadcastEvent(Event:new("NetworkConnected")) end
end

--- Turns Wi‑Fi on and waits for a known network, quietly.
-- on_ok() when connected; on_fail() after CONNECT_TIMEOUT. Returns false
-- when this device cannot do it quietly (the caller uses KOReader's way).
function Wifi.connect(on_ok, on_fail)
    if not canConnectQuietly() then return false end
    local nm = NetworkMgr()
    if connected() then
        settle(false)
        if on_ok then on_ok() end
        return true
    end
    nm.pending_connection = true
    UIManager:broadcastEvent(Event:new("NetworkConnecting"))
    local broadcast = true
    if Device:isKindle() then
        nm:restoreWifiAsync()
    else
        -- the emulator's pretend Wi‑Fi announces itself
        broadcast = false
        nm:turnOnWifi(nil, false)
    end
    local started = os.time()
    local check
    check = function()
        if connected() then
            settle(broadcast)
            if on_ok then UI.safely(on_ok) end
            return
        end
        if os.time() - started >= CONNECT_TIMEOUT then
            nm.pending_connection = false
            logger.info("Polka Wi‑Fi: no known network")
            if on_fail then UI.safely(on_fail) end
            return
        end
        UIManager:scheduleIn(0.5, check)
    end
    UIManager:scheduleIn(0.5, check)
    return true
end

-- No known network nearby: say so, and offer KOReader's list.
local function failed(sheet, callback)
    sheet:update{
        title = "Не нашёл знакомую сеть",
        body = "Рядом нет сети Wi‑Fi, к которой Kindle уже подключался.",
        status = false,
        buttons = {
            { text = "Выбрать сеть", primary = true, callback = function()
                NetworkMgr():toggleWifiOn(callback, false, true)
            end },
            { text = "Закрыть" },
        },
    }
end

--- Polka's question «Включить Wi‑Fi?»; callback runs once connected.
function Wifi.ask(callback, reason)
    local sheet
    local body = reason and (reason .. " " .. AFTER) or AFTER
    sheet = Sheet:new{
        icon = "wifi",
        title = "Включить Wi‑Fi?",
        body = body,
        buttons = {
            { text = "Включить", primary = true, keep_open = true, callback = function()
                local quiet = Wifi.connect(function()
                    sheet:close()
                    if callback then callback() end
                end, function() failed(sheet, callback) end)
                if quiet then
                    sheet:update{ buttons = false, status = "Подключаюсь…" }
                else
                    sheet:close()
                    NetworkMgr():turnOnWifiAndWaitForConnection(callback)
                end
            end },
            { text = "Не сейчас" },
        },
    }
    sheet:show()
    return sheet
end

--- Runs fn now if connected, otherwise asks (with the reason) and runs it
-- once connected. The reason is a short sentence: «Нужен, чтобы открыть каталог.»
function Wifi.run(reason, fn)
    local nm = NetworkMgr()
    if not nm.runWhenConnected then return fn() end
    Wifi.reason = reason
    local ok, err = pcall(nm.runWhenConnected, nm, fn)
    Wifi.reason = nil
    if not ok then
        logger.warn("Polka Wi‑Fi:", err)
        error(err)
    end
end

--- The Wi‑Fi switch in Настройки: on — quietly (on_change each step), off — at once.
function Wifi.toggle(on, on_change)
    local nm = NetworkMgr()
    if on then
        local quiet = Wifi.connect(function()
            Wifi.connecting = false
            if on_change then on_change() end
        end, function()
            Wifi.connecting = false
            if on_change then on_change() end
            local sheet = Sheet:new{ icon = "wifi", title = "Включить Wi‑Fi?" }
            failed(sheet, on_change)
            sheet:show()
        end)
        if quiet then
            Wifi.connecting = true
            if on_change then on_change() end
        else
            nm:toggleWifiOn(on_change, false, true)
        end
    else
        Wifi.connecting = false
        nm:disableWifi(on_change, true)
    end
end

--- Takes over KOReader's question (once).
function Wifi.install()
    local nm = NetworkMgr()
    if nm._polka_prompt then return end
    nm._polka_prompt = nm.promptWifiOn
    nm.promptWifiOn = function(this, complete_callback)
        if this.pending_connection then
            return nm._polka_prompt(this, complete_callback)
        end
        local reason = Wifi.reason
        local ok, err = pcall(Wifi.ask, complete_callback, reason)
        if not ok then
            logger.warn("Polka Wi‑Fi: falling back to KOReader's question:", err)
            return nm._polka_prompt(this, complete_callback)
        end
    end
end

return Wifi
