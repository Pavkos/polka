-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: О Полке — what this is, what it stands on, where its source lives.

Opened from Настройки («Версия»). Shows the version, the KOReader it runs
on, the licence (AGPL‑3.0: Polka is free software, as KOReader is), the
address of the source, «Проверить обновления» and «Сообщить об ошибке»
(a QR code of the page for reports, to open on a phone).
]]

local VerticalGroup = require("ui/widget/verticalgroup")

local Icons = require("polka_icons")
local UI = require("polka_ui")

local About = {
    -- Where Polka's source lives on GitHub: "owner/repo". The one place to change it.
    REPO = "OWNER/polka",
}

function About.sourceUrl()
    return "https://github.com/" .. About.REPO
end

function About.issuesUrl()
    return About.sourceUrl() .. "/issues"
end

local function koreaderVersion()
    local ok, v = pcall(function() return require("version"):getShortVersion() end)
    v = ok and v or require("polka_web").koreader() or ""
    return (tostring(v):gsub("^v", ""):match("^[%d%.]+") or v)
end

local function row(cw, title, right, cb, sub)
    local right_w = right and right:getSize().w or 0
    local text_w = cw - right_w - (right and UI.px(12) or 0)
    local left = UI.text{ text = title, size = 18, max_width = text_w }
    if sub then
        left = VerticalGroup:new{
            align = "left",
            left,
            UI.vgap(UI.px(2)),
            UI.text{ text = sub, size = 14, color = UI.C.text2, max_width = text_w },
        }
    end
    local h = math.max(left:getSize().h, right and right:getSize().h or 0) + 2 * UI.px(15)
    local w = VerticalGroup:new{ align = "left", UI.split(cw, left, right, h), UI.hline(cw) }
    if cb then return UI.tap(w, cb) end
    return w
end

local function value(text, cw)
    return UI.text{ text = text, size = 15, color = UI.C.text2, max_width = math.floor(cw * 0.6) }
end

local function chevron()
    return Icons.widget("chev_right", UI.px(22), { stroke = math.max(2, UI.px(2)) })
end

function About.reportBug()
    local Sheet = require("polka_sheet")
    Sheet:new{
        title = "Сообщить об ошибке",
        body = "Наведите камеру телефона на код — откроется страница для ошибок.",
        qr = About.issuesUrl(),
        small = (About.issuesUrl():gsub("^https://", "")),
        buttons = { { text = "Готово" } },
    }:show()
end

function About.pageTitle()
    return "О Полке"
end

function About.buildPage(shell, id, W, H)
    local Update = require("polka_update")
    local M = UI.px(32)
    local cw = W - 2 * M
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(w)
        table.insert(vg, w)
        used = used + w:getSize().h
    end
    -- the sign, the name and what it is
    local head = VerticalGroup:new{
        align = "center",
        Icons.widget("shelf", UI.px(84), { height = UI.px(64), stroke = math.max(2, UI.px(2.8)), plain = true }),
        UI.vgap(UI.px(8)),
        UI.text{ text = "Полка " .. Update.short(Update.current()), family = "serif_bold", size = 38 },
        UI.vgap(UI.px(8)),
        UI.text{ text = "Оболочка для KOReader на Kindle", size = 16, color = UI.C.text2 },
    }
    add(UI.vgap(UI.px(34)))
    add(UI.center(W, nil, head))
    add(UI.vgap(UI.px(26)))
    add(UI.hline(W))

    local list = VerticalGroup:new{ align = "left" }
    table.insert(list, row(cw, "Основано на KOReader", value(koreaderVersion(), cw)))
    table.insert(list, row(cw, "Лицензия", value("AGPL‑3.0 · свободная программа", cw)))
    table.insert(list, row(cw, "Исходники", value("github.com/" .. About.REPO, cw)))
    table.insert(list, row(cw, "Проверить обновления", chevron(), function()
        Update.checkNow(function()
            if shell.shown and shell.page and shell.page.id == "about" then shell:refresh("ui") end
        end)
    end, Update.hint))
    table.insert(list, row(cw, "Сообщить об ошибке", chevron(), About.reportBug, "QR-код на страницу для ошибок"))
    local Launcher = require("polka_launcher")
    if Launcher.possible() then
        local installed = Launcher.installed()
        table.insert(list, row(cw, "Полка на экране Kindle",
            UI.pillButton(installed and "Убрать" or "Добавить", function()
                if installed then Launcher.remove() else Launcher.install() end
                shell:refresh("ui")
            end),
            nil, installed and "Значок «Полка» есть в библиотеке Kindle" or "Значок для запуска из библиотеки Kindle"))
    end
    add(UI.pad(list, { left = M, right = M }))

    local note = UI.para{ text = "Полка — независимый проект. Не связана с Amazon и командой KOReader.",
                          size = 13.5, color = UI.C.text2, width = cw, align = "center" }
    local spare = H - used - note:getSize().h - UI.px(28)
    if spare > 0 then add(UI.vgap(spare)) end
    add(UI.pad(note, { left = M, right = M }))
    return vg
end

return About
