-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: Сайт — connecting the Kindle to a reader's card, and the card's page.

«Подключить сайт»: the Kindle asks the site for a code and shows it large,
with a QR of the link that carries it; the reader confirms it on the phone
(a new card with a password, or the card they are logged in with) and the
Kindle, looking every 3 seconds while this page is open, receives its own
key, runs the first sync and shows the card's page.

«Сайт»: the card's number, how the sync went, «Синхронизировать сейчас»,
«Войти на сайт с телефона» (a one-time code instead of the password), the
site's address and «Отключить этот Kindle».

Every request runs in the background (polka_net), so the page keeps
answering taps; nothing pops up while the Kindle syncs.
]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Icons = require("polka_icons")
local Sheet = require("polka_sheet")
local UI = require("polka_ui")
local Web = require("polka_web")
local Wifi = require("polka_wifi")

local Site = {}

local PAIR_POLL = 3 -- seconds between looks at the code, while the page is open

-- Shared pieces --------------------------------------------------------------------

-- A list row: a title (and a quiet line under it) on the left, something on the right.
local function row(cw, title, sub, right, cb, pad)
    local right_w = right and right:getSize().w or 0
    local text_w = cw - right_w - (right and UI.px(16) or 0)
    local texts = VerticalGroup:new{
        align = "left",
        UI.text{ text = title, size = 19, family = "sans_bold", max_width = text_w },
    }
    if sub then
        table.insert(texts, UI.vgap(UI.px(3)))
        table.insert(texts, UI.text{ text = sub, size = 14.5, color = UI.C.text2, max_width = text_w })
    end
    local h = math.max(texts:getSize().h, right and right:getSize().h or 0) + 2 * UI.px(pad or 16)
    local line = UI.split(cw, texts, right, h)
    local w = VerticalGroup:new{ align = "left", line, UI.hline(cw) }
    if cb then return UI.tap(w, cb) end
    return w
end

local function chevron()
    return Icons.widget("chev_right", UI.px(22), { stroke = math.max(2, UI.px(2)) })
end

-- The round «sync now» button; black while a sync runs.
function Site.syncButton(size, busy)
    local border = math.max(2, UI.px(2))
    return UI.FrameContainer:new{
        bordersize = border, color = UI.C.ink, background = busy and UI.C.ink or UI.C.paper,
        radius = math.floor(size / 2), padding = 0, margin = 0,
        UI.center(size - 2 * border, size - 2 * border, UI.icon(0xF021, 20, busy and UI.C.paper or UI.C.ink)),
    }
end

local function syncNow()
    if Web.online() then
        Web.tap()
    else
        Wifi.run("Нужен, чтобы синхронизировать.", function() Web.tap() end)
    end
end

-- «Подключить сайт» -------------------------------------------------------------------

local function stopPairing(shell)
    local pair = shell.pair
    if not pair then return end
    if pair.timer then UIManager:unschedule(pair.timer) end
    if pair.handle then pair.handle:cancel() end
    pair.timer, pair.handle = nil, nil
    shell.pair = nil
end

local function onConnectPage(shell)
    return shell.shown and shell.page and shell.page.id == "connect"
end

-- Repaints only the dots, or the whole page.
local function repaint(shell, only_dots)
    if not onConnectPage(shell) then return end
    local region = only_dots and Site._dots and Site._dots.dimen and Site._dots.dimen.x and Site._dots.dimen:copy()
    shell:build()
    UIManager:setDirty(shell, "ui", region)
end

local schedulePoll

local function startPairing(shell)
    stopPairing(shell)
    local pair = { state = "asking", dots = 1 }
    shell.pair = pair
    local function ask()
        if shell.pair ~= pair then return end
        pair.state = "asking"
        repaint(shell)
        pair.handle = Web.pairStart(function(res)
            pair.handle = nil
            if shell.pair ~= pair then return end
            if res.error or not res.code or not res.poll then
                pair.state = res.error == "too_many" and "busy" or "error"
            else
                pair.state = "waiting"
                pair.code, pair.poll = tostring(res.code), res.poll
                pair.url, pair.site = res.url, res.site
                pair.until_t = os.time() + (tonumber(res.expires) or 900)
                schedulePoll(shell, pair)
            end
            repaint(shell)
        end)
    end
    if Web.online() then
        ask()
    else
        pair.state = "offline"
        Wifi.run("Нужен, чтобы подключить сайт.", ask)
    end
end

schedulePoll = function(shell, pair)
    if pair.timer then UIManager:unschedule(pair.timer) end
    pair.timer = function()
        pair.timer = nil
        if shell.pair ~= pair or pair.state ~= "waiting" or not onConnectPage(shell) then return end
        if os.time() >= (pair.until_t or 0) then
            pair.state = "expired"
            return repaint(shell)
        end
        pair.handle = Web.pairPoll(pair.poll, function(res)
            pair.handle = nil
            if shell.pair ~= pair or pair.state ~= "waiting" then return end
            if res.status == "ok" and type(res.token) == "string" then
                stopPairing(shell)
                Web.adopt(res.token, res.card, pair.site)
                if shell.shown then
                    -- the card's page, as the phone shows it too
                    shell.page = { id = "site", opts = {} }
                    shell:refresh("ui")
                end
                return
            elseif res.status == "expired" then
                pair.state = "expired"
                return repaint(shell)
            end
            -- still waiting (or a hiccup of the network): look again soon
            pair.dots = pair.dots % 3 + 1
            repaint(shell, true)
            schedulePoll(shell, pair)
        end)
    end
    UIManager:scheduleIn(PAIR_POLL, pair.timer)
end

-- "482 913" from "482913"
local function grouped(code)
    code = tostring(code or "")
    if #code == 6 then return code:sub(1, 3) .. " " .. code:sub(4) end
    return code
end

-- A numbered step: a ring with the number, then the words.
local function step(n, content, w)
    local d = UI.px(28)
    local bw = math.max(2, UI.px(2))
    local ring = OverlapGroup:new{
        dimen = Geom:new{ w = d, h = d },
        UI.canvas(d, d, function(bb, x, y)
            bb:paintCircle(x + math.floor(d / 2), y + math.floor(d / 2), math.floor(d / 2), UI.C.ink, bw)
        end),
        UI.center(d, d, UI.text{ text = tostring(n), size = 14, family = "sans_bold" }),
    }
    return HorizontalGroup:new{
        align = "top",
        ring,
        UI.hgap(UI.px(12)),
        content(w - d - UI.px(12)),
    }
end

local function dots(active)
    local d = UI.px(8)
    local gap = UI.px(5)
    local w = 3 * d + 2 * gap
    return UI.canvas(w, d, function(bb, x, y)
        for i = 1, 3 do
            local color = (i == active) and UI.C.mid or UI.C.ink
            bb:paintCircle(x + (i - 1) * (d + gap) + math.floor(d / 2), y + math.floor(d / 2), math.floor(d / 2), color)
        end
    end)
end

local STATUS = {
    asking = { "Получаю код…", nil },
    offline = { "Нужен Wi‑Fi", "Код появится, когда Kindle подключится" },
    waiting = { "Жду телефон…", "Код действует 15 минут" },
    expired = { "Код устарел", "Нажмите «Новый код»" },
    error = { "Не получилось получить код", "Нет связи с сайтом — попробуйте ещё раз" },
    busy = { "Слишком много кодов подряд", "Попробуйте через несколько минут" },
}

local function connectView(shell, W, H)
    local M = UI.px(32)
    local cw = W - 2 * M
    local pair = shell.pair
    if not pair then
        startPairing(shell)
        pair = shell.pair
    elseif pair.state == "waiting" and not pair.timer and not pair.handle then
        schedulePoll(shell, pair) -- back from sleep
    end
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    add(UI.vgap(UI.px(30)))
    add(UI.spaced("КОД", { size = 13, color = UI.C.text2 }))
    add(UI.vgap(UI.px(4)))
    local code_h = math.floor(UI.px(70) * 1.05 + 0.5) -- the line box of the code (spacedDigits)
    if pair.code and pair.state ~= "expired" then
        add(Sheet.spacedDigits(grouped(pair.code), 70, UI.px(6)))
    else
        add(UI.vgap(code_h))
    end
    add(UI.vgap(UI.px(28)))

    local qr_size = UI.px(196)
    local qr
    if pair.url and pair.state == "waiting" then
        qr = Sheet.qrBox(pair.url, qr_size)
    else
        -- the frame waits for the code
        local b = math.max(1, UI.px(1))
        qr = UI.FrameContainer:new{
            bordersize = b, color = UI.C.line, background = UI.C.paper, padding = 0, margin = 0,
            UI.canvas(qr_size - 2 * b, qr_size - 2 * b),
        }
    end
    local col_w = cw - qr_size - UI.px(28)
    local host = Web.host(pair.site or Web.server())
    local steps = VerticalGroup:new{
        align = "left",
        UI.vgap(UI.px(4)),
        step(1, function(w) return UI.para{ text = "Наведите камеру телефона на QR-код", size = 17, width = w, line_height = 0.35 } end, col_w),
        UI.vgap(UI.px(18)),
        step(2, function(w)
            return VerticalGroup:new{
                align = "left",
                UI.para{ text = "Или откройте сайт и введите код:", size = 17, width = w, line_height = 0.35 },
                UI.vgap(UI.px(4)),
                UI.text{ text = host .. "/k", family = "mono", size = 14.5, max_width = w },
            }
        end, col_w),
        UI.vgap(UI.px(18)),
        step(3, function(w) return UI.para{ text = "Придумайте пароль. Kindle подключится сам", size = 17, width = w, line_height = 0.35 } end, col_w),
    }
    add(HorizontalGroup:new{ align = "top", qr, UI.hgap(UI.px(28)), steps })

    -- The line at the bottom: what is going on, and «Новый код».
    local s = STATUS[pair.state] or STATUS.asking
    local texts = VerticalGroup:new{
        align = "left",
        UI.text{ text = s[1], size = 17, family = "sans_bold", max_width = cw - UI.px(220) },
    }
    if s[2] then
        table.insert(texts, UI.vgap(UI.px(2)))
        table.insert(texts, UI.text{ text = s[2], size = 14, color = UI.C.text2, max_width = cw - UI.px(220) })
    end
    local busy = pair.state == "waiting" or pair.state == "asking"
    local left = HorizontalGroup:new{ align = "center" }
    if busy then
        Site._dots = UI.FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, dots(pair.dots or 3) }
        table.insert(left, Site._dots)
        table.insert(left, UI.hgap(UI.px(16)))
    else
        Site._dots = nil
    end
    table.insert(left, texts)
    local new_code = UI.pillButton("Новый код", function() startPairing(shell) end)
    local bar_h = math.max(left:getSize().h, new_code:getSize().h)
    local bar = VerticalGroup:new{
        align = "left",
        UI.hline(cw),
        UI.vgap(UI.px(20)),
        UI.split(cw, left, new_code, bar_h),
        UI.vgap(UI.px(30)),
    }
    local spare = H - used - bar:getSize().h
    if spare > 0 then add(UI.vgap(spare)) end
    add(bar)
    return UI.pad(vg, { left = M, right = M })
end

-- «Сайт» -----------------------------------------------------------------------------

function Site.loginCode()
    local sheet
    sheet = Sheet:new{
        title = "Вход на сайт",
        status = "Получаю код…",
        buttons = { { text = "Закрыть" } },
    }
    sheet:show()
    local function ask()
        Web.loginCode(function(res)
            if sheet.closed then return end
            if res.error == "unauthorized" then
                sheet:close()
                return
            end
            if res.error or not res.code then
                sheet:update{ status = res.error == "too_many" and "Слишком много кодов подряд. Попробуйте позже."
                                         or "Не получилось: нет связи с сайтом. Попробуйте ещё раз." }
                return
            end
            local mins = math.max(1, math.floor((tonumber(res.expires) or 600) / 60 + 0.5))
            sheet:update{
                status = false,
                big = grouped(res.code),
                small = string.format("Откройте %s, нажмите «Войти кодом с Kindle» и введите этот код. Он действует %d %s.",
                    Web.host(), mins, UI.plural(mins, "минуту", "минуты", "минут")),
                buttons = { { text = "Готово" } },
            }
        end)
    end
    if Web.online() then
        ask()
    else
        Wifi.run("Нужен, чтобы получить код.", ask)
    end
end

function Site.confirmUnlink(shell)
    local sheet
    sheet = Sheet:new{
        title = "Отключить этот Kindle?",
        body = "Что уже на сайте — останется. Подключить снова можно в любой момент.",
        buttons = {
            { text = "Отключить", primary = true, keep_open = true, callback = function()
                local function go()
                    sheet:update{ buttons = false, status = "Отключаю…" }
                    Web.unlink(function(res)
                        if res.ok or res.error == "unauthorized" then
                            sheet:close()
                            if shell.shown and shell.page and shell.page.id == "site" then shell:closePage() end
                            return
                        end
                        sheet:update{
                            status = "Не получилось: нет связи с сайтом. Попробуйте позже.",
                            buttons = { { text = "Закрыть" } },
                        }
                    end)
                end
                if Web.online() then go() else Wifi.run("Нужен, чтобы отключить Kindle от сайта.", go) end
            end },
            { text = "Отмена" },
        },
    }
    sheet:show()
end

-- The reader's card: a double frame, like a library ticket.
local function ticket(cw)
    local card = Web.card()
    local outer_b, gap, inner_b = math.max(1, UI.px(1)), UI.px(4), math.max(2, UI.px(2))
    local inner_w = cw - 2 * (outer_b + gap) -- the inner frame, its line included
    local pad_x, pad_y = UI.px(22), UI.px(20)
    local content_w = inner_w - 2 * inner_b - 2 * pad_x
    local label = UI.text{ text = "Подключено", size = 15, family = "sans_bold" }
    local status = HorizontalGroup:new{
        align = "center",
        Icons.widget("check", UI.px(18), { stroke = math.max(2, UI.px(2.6)) }),
        UI.hgap(UI.px(6)),
        label,
    }
    local number = UI.lineText({ text = "№ " .. (card and tostring(card) or "—"), family = "serif_bold", size = 46,
                                 max_width = content_w - status:getSize().w - UI.px(12) }, 1.1)
    -- «Подключено» stands on the number's baseline
    local drop = math.max(0, UI.baseline(number) - UI.baseline(label))
    local nh = math.max(number:getSize().h, drop + status:getSize().h)
    local body = VerticalGroup:new{
        align = "left",
        UI.spaced("ЧИТАТЕЛЬСКИЙ БИЛЕТ", { size = 13, color = UI.C.text2 }),
        UI.vgap(UI.px(6)),
        OverlapGroup:new{
            dimen = Geom:new{ w = content_w, h = nh },
            number,
            UI.right(content_w, VerticalGroup:new{ align = "right", UI.vgap(drop), status }),
        },
        UI.vgap(UI.px(6)),
        UI.text{ text = Web.summary(), size = 15, color = UI.C.text2, max_width = content_w },
    }
    local inner = UI.FrameContainer:new{
        bordersize = inner_b, color = UI.C.ink, background = UI.C.paper, radius = UI.px(4),
        padding = 0, padding_left = pad_x, padding_right = pad_x, padding_top = pad_y, padding_bottom = pad_y,
        margin = 0, width = inner_w,
        body,
    }
    -- the thin line around it, 4 apart: a library card
    return UI.FrameContainer:new{
        bordersize = outer_b, color = UI.C.ink, background = UI.C.paper, radius = UI.px(8),
        padding = gap, margin = 0,
        inner,
    }
end

local function siteView(shell, W, H)
    if not Web.configured() then
        -- disconnected meanwhile (here, or on the site): back to «Подключить»
        UIManager:nextTick(function()
            if shell.shown and shell.page and shell.page.id == "site" then shell:closePage() end
        end)
    end
    local M = UI.px(32)
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, UI.vgap(UI.px(28)))
    table.insert(vg, ticket(cw))
    table.insert(vg, UI.vgap(UI.px(18)))
    local sync_btn = UI.tap(Site.syncButton(UI.px(52), Web.pid ~= nil), syncNow)
    table.insert(vg, row(cw, "Синхронизировать сейчас", "Сама — при Wi‑Fi и после книги", sync_btn, nil))
    table.insert(vg, row(cw, "Войти на сайт с телефона", "Покажу код — пароль не нужен", chevron(),
        function() Site.loginCode() end))
    table.insert(vg, row(cw, "Адрес", nil, UI.text{ text = Web.host(), size = 15, color = UI.C.text2,
        max_width = cw - UI.px(120) }, nil, 18))
    table.insert(vg, row(cw, "Отключить этот Kindle", "Что уже на сайте — останется", chevron(),
        function() Site.confirmUnlink(shell) end))
    return UI.pad(vg, { left = M, right = M })
end

-- Wi‑Fi came on while the page waited for it: the code now.
function Site.onNetworkConnected()
    local Shell = package.loaded["polka_shell"]
    local shell = Shell and Shell.current
    local pair = shell and shell.pair
    if pair and pair.state == "offline" and onConnectPage(shell) then startPairing(shell) end
end

-- Page hooks (polka_shell) -------------------------------------------------------------

function Site.pageTitle(shell, id)
    return id == "connect" and "Подключить сайт" or "Сайт"
end

function Site.buildPage(shell, id, W, H)
    if id == "connect" then return connectView(shell, W, H) end
    return siteView(shell, W, H)
end

function Site.leavePage(shell, id)
    if id == "connect" then stopPairing(shell) end
end

function Site.suspendPage(shell, id)
    -- no looking at the code while the Kindle sleeps (it starts again on wake)
    local pair = shell.pair
    if id == "connect" and pair then
        if pair.timer then UIManager:unschedule(pair.timer) end
        if pair.handle then pair.handle:cancel() end
        pair.timer, pair.handle = nil, nil
    end
end

-- From the list of tools: the card's page, or connecting.
function Site.open(shell)
    shell:openPage(Web.configured() and "site" or "connect")
end

return Site
