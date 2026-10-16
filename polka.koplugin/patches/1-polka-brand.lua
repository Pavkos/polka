-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Polka brand patch, version 1.7.0
--[[--
«Полка» instead of «KOReader» in KOReader's own menus and messages.

Polka copies this file into KOReader's patches folder (koreader/patches) and
keeps it up to date. It runs early at every start, before the language is
loaded, and from then on every time the language is (re)loaded rewrites the
loaded Russian translations: «KOReader'а» → «Полки», «KOReader'у»/«KOReader'е»
→ «Полке», «KOReader'ом» → «Полкой», and each bare «KOReader» in its right
case («перезапустите Полку», «объектов Полки», «Полка не найдёт»…). Where
KOReader means KOReader itself — its progress sync server, its wiki, other
devices running KOReader, the About box with its licence — it stays.

It also keeps KOReader's quick start guide from opening over Polka on the
very first start, and, right after Polka updated itself, puts the previous
Polka back if the new one does not even load.

It does nothing at all when plugins/polka.koplugin is not there (Polka was
removed) or Polka is switched off; every step is guarded.
]]

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then return end

-- Everything below runs guarded: a patch must never stop KOReader from starting.
local function main()
    local M = package.loaded["polka.brand"]
    if M then
        -- already running (the plugin loads this file too): just rewrite again
        pcall(M.rebrand)
        return
    end

    local function exists(path, mode)
        local ok, m = pcall(lfs.attributes, path, "mode")
        return ok and m == (mode or "file")
    end

    -- Where Polka is: KOReader's own plugins folder, or the data folder's.
    local function polkaDir()
        local dirs = {}
        local ok, DataStorage = pcall(require, "datastorage")
        if ok then dirs[#dirs + 1] = DataStorage:getDataDir() .. "/plugins" end
        local cwd = lfs.currentdir()
        if cwd then dirs[#dirs + 1] = cwd .. "/plugins" end
        for _, d in ipairs(dirs) do
            local p = d .. "/polka.koplugin"
            if exists(p .. "/main.lua") or exists(p .. "/.polka-update.lua") or exists(d .. "/.polka-update.lua") then
                return p, d
            end
        end
    end

    local plugin_dir, plugins = polkaDir()
    if not plugin_dir then return end

    M = {}
    package.loaded["polka.brand"] = M

    -- After an update: the new Polka must at least load, or the old one comes back.
    pcall(function()
        local marker = plugins .. "/.polka-update.lua"
        if not exists(marker) then return end
        local ok, m = pcall(dofile, marker)
        if not ok or type(m) ~= "table" or m.failed or tonumber(m.at) and os.time() - tonumber(m.at) > 2 * 86400 then return end
        local why
        local ok_meta, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
        if not ok_meta or type(meta) ~= "table" or meta.version ~= m.to then
            why = "meta"
        elseif not loadfile(plugin_dir .. "/main.lua") then
            why = "main"
        end
        if not why then return end
        local backup = plugins .. "/.polka-backup"
        if not exists(backup, "directory") then return end
        os.rename(plugin_dir, plugins .. "/.polka-failed")
        if not os.rename(backup, plugin_dir) then
            os.rename(plugins .. "/.polka-failed", plugin_dir)
            return
        end
        local f = io.open(marker, "w")
        if f then
            f:write(string.format("return { from = %q, to = %q, at = %q, failed = %q }\n",
                tostring(m.from), tostring(m.to), tostring(m.at), why))
            f:close()
        end
    end)

    -- The words -------------------------------------------------------------------------

    -- KOReader as KOReader: kept as it is.
    local PROTECT = {
        "сервер KOReader'а", "сервере KOReader'а", "вики KOReader'а", "пользователей KOReader'а",
        "где установлен KOReader",
    }
    -- Phrases where more than the name changes («Полка» is feminine).
    local PHRASES = {
        { "чтобы KOReader мог", "чтобы Полка могла" },
        { "KOReader сам выберет", "Полка сама выберет" },
        { "IP-адрес в KOReader", "IP-адрес в Полку" },
        { "документы в KOReader", "документы в Полке" },
        { "Создано в KOReader", "Создано в Полке" },
    }
    local SUFFIXES = {
        { "KOReader'ом", "Полкой" },
        { "KOReader'а", "Полки" },
        { "KOReader'у", "Полке" },
        { "KOReader'е", "Полке" },
    }
    -- A bare «KOReader» after these words is in the accusative, or the genitive.
    local ACCUSATIVE = { "настроить", "Перезапустить", "перезапустить", "Перезапустите", "перезапустите",
                         "обновить", "приведёт" }
    local GENITIVE = { "объектов", "инспектор", "запуске", "возможности" }

    local function plain(s)
        return (s:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"))
    end

    local function rename(s)
        if type(s) ~= "string" or not s:find("KOReader", 1, true) then return s end
        local kept = {}
        for i, p in ipairs(PROTECT) do
            s = s:gsub(plain(p), function()
                kept[i] = p
                return "\1" .. i .. "\1"
            end)
        end
        for _, p in ipairs(PHRASES) do s = s:gsub(plain(p[1]), p[2]) end
        for _, p in ipairs(SUFFIXES) do s = s:gsub(plain(p[1]), p[2]) end
        for _, w in ipairs(ACCUSATIVE) do s = s:gsub(plain(w .. " KOReader"), w .. " Полку") end
        for _, w in ipairs(GENITIVE) do s = s:gsub(plain(w .. " KOReader"), w .. " Полки") end
        s = s:gsub("KOReader", "Полка")
        s = s:gsub("\1(%d+)\1", function(i) return kept[tonumber(i)] end)
        return s
    end
    M.rename = rename

    -- A few of KOReader's Russian lines, in Polka's calmer words.
    local WORDS = {
        ["Searching dictionary for:\n%1"] = "Ищу в словаре:\n%1",
    }

    -- The About box («KOReader v… Средство просмотра документов…») is KOReader's
    -- own credit and licence notice: it stays.
    local function keep(msgid)
        return msgid == "" or msgid:find("^KOReader %%1\n\nA document viewer") ~= nil
    end

    local function walk(t)
        for msgid, v in pairs(t) do
            if type(msgid) == "string" and not keep(msgid) then
                if type(v) == "string" then
                    if v:find("KOReader", 1, true) then t[msgid] = rename(v) end
                elseif type(v) == "table" then
                    for k, s in pairs(v) do
                        if type(s) == "string" and s:find("KOReader", 1, true) then v[k] = rename(s) end
                    end
                end
            end
        end
    end

    local function disabled()
        if not G_reader_settings then return false end
        local d = G_reader_settings:readSetting("plugins_disabled")
        return type(d) == "table" and d.polka == true
    end

    function M.rebrand()
        if disabled() or not exists(plugin_dir .. "/main.lua") then return end
        local _ = require("gettext")
        if type(_.translation) == "table" then
            walk(_.translation)
            if tostring(_.current_lang or ""):match("^ru") then
                for msgid, text in pairs(WORDS) do
                    if _.translation[msgid] then _.translation[msgid] = text end
                end
            end
        end
        if type(_.context) == "table" then
            for _ctx, t in pairs(_.context) do
                if type(t) == "table" then walk(t) end
            end
        end
    end

    -- KOReader's quick start guide would open as a book over Polka on a first start.
    local function noGuide()
        if not G_reader_settings or disabled() or G_reader_settings:has("quickstart_shown_version") then return end
        local ok, v = pcall(function() return require("version"):getNormalizedCurrentVersion() end)
        if ok and tonumber(v) then G_reader_settings:saveSetting("quickstart_shown_version", tonumber(v)) end
    end

    pcall(function()
        local _ = require("gettext")
        local mt = getmetatable(_)
        local index = mt and mt.__index
        if type(index) ~= "table" or type(index.changeLang) ~= "function" then return end
        local orig = index.changeLang
        index.changeLang = function(...)
            local r = orig(...)
            pcall(M.rebrand)
            pcall(noGuide)
            return r
        end
        -- loaded from the plugin after the language: rewrite what is there now
        if _.current_lang and _.current_lang ~= "C" then pcall(M.rebrand) end
    end)
end

local ok, err = pcall(main)
if not ok then
    pcall(function() require("logger").warn("Polka brand patch:", err) end)
end
