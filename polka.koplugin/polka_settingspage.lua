--[[--
Polka: Настройки.

The handful of KOReader settings people actually change, in plain Russian,
plus Polka's own options. Everything else is one tap away under
"Все настройки KOReader".
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local filemanagerutil = require("apps/filemanager/filemanagerutil")

local Books = require("polka_books")
local UI = require("polka_ui")

local SettingsPage = {}

local SLEEP_SCREENS = {
    { id = "cover", label = "Обложка книги" },
    { id = "readingprogress", label = "Прогресс чтения" },
    { id = "bookstatus", label = "Карточка книги" },
    { id = "random_image", label = "Картинка из папки" },
    { id = "disable", label = "Оставить экран как есть" },
}

-- KOReader's full refresh rate; -1 is its "Every chapter" (what a Kindle does).
local REFRESH = {
    { n = -1, label = "Как на Kindle — на новой главе", short = "Как на Kindle" },
    { n = 1, label = "Каждую страницу" },
    { n = 6, label = "Каждые 6 страниц" },
    { n = 12, label = "Каждые 12 страниц" },
    { n = 20, label = "Каждые 20 страниц" },
    { n = 0, label = "Никогда" },
}

local GRID = {
    { n = 6, label = "6 — крупно" },
    { n = 9, label = "9 — как на Kindle" },
    { n = 12, label = "12 — плотно" },
}

local function choose(title, options, current, on_pick)
    local dialog
    local buttons = {}
    for _, o in ipairs(options) do
        table.insert(buttons, {{
            text = o.label .. (o.value == current and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                on_pick(o.value)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

local function labelFor(options, value, fallback)
    for _, o in ipairs(options) do
        if o.value == value then return o.short or o.label end
    end
    return fallback
end

local function shortPath(p)
    if not p then return "" end
    p = p:gsub("^/mnt/us", ""):gsub("^/mnt/onboard", "")
    if p == "" then p = "/" end
    if #p > 28 then p = "…" .. p:sub(-26) end
    return p
end

function SettingsPage.build(shell, W, H)
    local M = shell:margin()
    local cw = W - 2 * M
    local row_h = UI.px(38)
    -- Rows are laid out in pages: one page in portrait; in landscape the
    -- rest goes to a second page. A section title stays with its first row.
    local items = {}
    local pending_title

    local function section(title, first)
        pending_title = VerticalGroup:new{
            align = "left",
            UI.vgap(first and UI.px(8) or UI.px(12)),
            UI.text{ text = title, family = "sans_bold", size = 14, color = UI.C.text2 },
        }
    end

    local function row(label, right, cb, hint)
        local left = UI.text{ text = label, size = 18, max_width = cw - UI.px(160) }
        if hint then
            left = VerticalGroup:new{ align = "left", left,
                UI.text{ text = hint, size = 13, color = UI.C.text3, max_width = cw - UI.px(120) } }
        end
        local line = UI.split(cw, left, right, math.max(row_h, left:getSize().h + UI.px(10)))
        local w = UI.tap(VerticalGroup:new{ align = "left", line, UI.hline(cw) }, cb)
        if pending_title then
            w = VerticalGroup:new{ align = "left", pending_title, w }
            pending_title = nil
        end
        items[#items + 1] = w
    end

    local function value(text)
        return UI.text{ text = text .. "   ›", size = 16, color = UI.C.text2, max_width = UI.px(260) }
    end

    local function nav()
        return UI.text{ text = "›", size = 18, color = UI.C.text2 }
    end

    -- Device
    section("Устройство", true)
    if Device:hasFrontlight() then
        row("Подсветка", nav(), function()
            if Device.showLightDialog then
                Device:showLightDialog()
            else
                UIManager:broadcastEvent(Event:new("ShowFlDialog"))
            end
        end)
    end
    local night = G_reader_settings:isTrue("night_mode")
    row("Ночной режим", UI.switch(night), function()
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
        shell:refresh("full")
    end)
    if Device:hasWifiToggle() then
        local on = NetworkMgr:isWifiOn()
        row("Wi‑Fi", UI.switch(on), function()
            local done = function()
                if shell.shown then shell:refresh("ui") end
            end
            if on then
                NetworkMgr:toggleWifiOff(done, true)
            else
                NetworkMgr:toggleWifiOn(done, false, true)
            end
        end)
    end
    -- Kindles with Special Offers keep their own sleep screen; KOReader hides
    -- this option there too.
    if not Device.supportsScreensaver or Device:supportsScreensaver() then
        local sleep_opts = {}
        for _, o in ipairs(SLEEP_SCREENS) do sleep_opts[#sleep_opts + 1] = { value = o.id, label = o.label } end
        local sleep = G_reader_settings:readSetting("screensaver_type") or "disable"
        row("Экран сна", value(labelFor(sleep_opts, sleep, "Другое")), function()
            choose("Экран сна", sleep_opts, sleep, function(v)
                G_reader_settings:saveSetting("screensaver_type", v)
                shell:refresh("ui")
            end)
        end)
    end
    local refresh_opts = {}
    for _, o in ipairs(REFRESH) do
        refresh_opts[#refresh_opts + 1] = { value = o.n, label = o.label, short = o.short }
    end
    -- Until a rate is picked, books in Kindle mode flash the Kindle way (polka_reader).
    local rate = G_reader_settings:readSetting("full_refresh_count")
    if rate == nil then
        local Reader = require("polka_reader")
        rate = Reader.isOn() and Reader.KINDLE_REFRESH or UIManager:getRefreshRate()
    end
    row("Обновление экрана", value(labelFor(refresh_opts, rate, "Каждые " .. tostring(rate))), function()
        choose("Полное обновление экрана (мигание)", refresh_opts, rate, function(v)
            UIManager:setRefreshRate(v) -- the night-mode rate stays as the user set it
            shell:refresh("ui")
        end)
    end)

    -- Reading
    section("Чтение")
    local kindle = G_reader_settings:nilOrTrue("polka_reader")
    row("Как на Kindle", UI.switch(kindle), function()
        G_reader_settings:saveSetting("polka_reader", not kindle)
        shell:refresh("ui")
    end, "Строка «Осталось в главе», тулбар сверху, «Aa»")
    if kindle then
        local sel = G_reader_settings:nilOrTrue("polka_selection_menu")
        row("Меню выделения", UI.switch(sel), function()
            G_reader_settings:saveSetting("polka_selection_menu", not sel)
            shell:refresh("ui")
        end)
    end

    -- Polka
    section("Полка")
    local autostart = G_reader_settings:nilOrTrue("polka_autostart")
    row("Открывать при запуске", UI.switch(autostart), function()
        G_reader_settings:saveSetting("polka_autostart", not autostart)
        shell:refresh("ui")
    end)
    row("Папка с книгами", value(shortPath(Books.root)), function()
        filemanagerutil.showChooseDialog("Папка с книгами:", function(path)
            G_reader_settings:saveSetting("polka_root", path)
            shell.lib.shelf, shell.lib.page = "*", 1
            Books:scan()
            shell:refresh("ui")
        end, G_reader_settings:readSetting("polka_root") or Books.root, Books.root)
    end)
    local grid_opts = {}
    for _, o in ipairs(GRID) do grid_opts[#grid_opts + 1] = { value = o.n, label = o.label } end
    local grid = tonumber(G_reader_settings:readSetting("polka_grid")) or 9
    row("Обложек на странице", value(tostring(grid)), function()
        choose("Обложек на странице", grid_opts, grid, function(v)
            G_reader_settings:saveSetting("polka_grid", v)
            shell.lib.page = 1
            shell:refresh("ui")
        end)
    end)
    local goal = tonumber(G_reader_settings:readSetting("polka_goal")) or 24
    row("Цель на год", value(UI.books(goal)), function()
        require("polka_statspage").editGoal(shell)
    end)

    -- KOReader
    section("KOReader")
    row("Все настройки KOReader", nav(), function() shell:openKOReaderMenu() end)
    row("Файлы и папки", nav(), function() shell:close() end)
    row("Перезапуск или выход", nav(), function()
        local dialog
        local buttons = {}
        if Device:canRestart() then
            table.insert(buttons, {{ text = "Перезапустить KOReader", callback = function()
                UIManager:close(dialog)
                shell:exitKOReader(true)
            end }})
        end
        table.insert(buttons, {{ text = Device:isKindle() and "Выйти в меню Kindle" or "Выйти из KOReader", callback = function()
            UIManager:close(dialog)
            shell:exitKOReader(false)
        end }})
        dialog = ButtonDialog:new{ title = "KOReader", title_align = "center", buttons = buttons }
        UIManager:show(dialog)
    end)

    local heights, total = {}, 0
    for i, w in ipairs(items) do
        heights[i] = w:getSize().h
        total = total + heights[i]
    end
    local vg = VerticalGroup:new{ align = "left" }
    if total <= H then
        shell.settings_page = nil
        for _, w in ipairs(items) do table.insert(vg, w) end
        return UI.pad(vg, { left = M, right = M }) -- everything fits (portrait)
    end
    -- Pages: where each starts, worked out from the heights.
    local footer_h = UI.px(48)
    local room = H - footer_h
    local starts, used = { 1 }, 0
    for i = 1, #items do
        if used + heights[i] > room and used > 0 then
            starts[#starts + 1] = i
            used = 0
        end
        used = used + heights[i]
    end
    local page = math.min(shell.settings_page or 1, #starts)
    shell.settings_page = page
    local last = (starts[page + 1] or (#items + 1)) - 1
    local shown = 0
    for i = starts[page], last do
        table.insert(vg, items[i])
        shown = shown + heights[i]
    end
    local spare = room - shown
    if spare > 0 then table.insert(vg, UI.vgap(spare)) end
    local Tools = require("polka_tools")
    table.insert(vg, Tools.pagerBar(cw, footer_h, string.format("%d / %d", page, #starts), page > 1, page < #starts,
        function(delta)
            shell.settings_page = page + delta
            shell:refresh("ui")
        end))
    return UI.pad(vg, { left = M, right = M })
end

return SettingsPage
