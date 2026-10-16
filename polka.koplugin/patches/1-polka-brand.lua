-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Polka brand patch, version 1.7.0
--[[--
«Полка» as the name of the app in KOReader's own titles and messages.

Polka copies this file into KOReader's patches folder (koreader/patches) and
keeps it up to date. It runs early at every start, before the language is
loaded, and every time the language is (re)loaded it rewrites a short list of
Russian translations where KOReader is just the app's name: the file
browser's title, exit and restart («Выйти из Полки?», «Перезапустить Полку»,
«Пожалуйста, перезапустите Полку…») and a few messages about the app itself
(«Полка перезапускается…», «Работа Полки будет завершена»). Everything that
is about KOReader as such stays as it is: help and technical texts (CSS,
.sdr folders and metadata, settings and data folders, plugins, patches),
KOReader's own updates, earlier KOReader versions, its wiki, forum and sync
server, the About box with its licence.

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

    -- Where KOReader is just the app's name (English msgids). Nothing else is touched.
    local BRAND = {
        "KOReader",                                   -- the file browser's title
        "Exit KOReader",
        "Exit KOReader?",
        "Restart KOReader",
        "High memory usage: %1 MB\n\nExit KOReader?",
        "High memory usage: %1 MB\n\nRestart KOReader?",
        "High memory usage!\n\nKOReader is restarting…",
        "Caches cleared. Please restart KOReader.",
        "KOReader needs to be restarted to apply the new default settings.",
        "Please restart KOReader for the new language setting to take effect.",
        "Start-up of background extraction job failed.\nPlease restart KOReader or your device.",
        "Failed recognizing or parsing this file: unsupported or invalid document.\nKOReader will exit now.",
        "KOReader is currently waiting for connectivity. This may take up to 45s, so you may just want to try again later.",
    }
    -- «Полка» is feminine: the cases KOReader's Russian translation uses.
    local SUFFIXES = {
        { "KOReader'ом", "Полкой" },
        { "KOReader'а", "Полки" },
        { "KOReader'у", "Полке" },
        { "KOReader'е", "Полке" },
    }
    -- A bare «KOReader» after these words is in the accusative.
    local ACCUSATIVE = { "Перезапустить", "перезапустить", "Перезапустите", "перезапустите" }

    local function plain(s)
        return (s:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"))
    end

    local function rename(s)
        if type(s) ~= "string" or not s:find("KOReader", 1, true) then return s end
        for _, p in ipairs(SUFFIXES) do s = s:gsub(plain(p[1]), p[2]) end
        for _, w in ipairs(ACCUSATIVE) do s = s:gsub(plain(w .. " KOReader"), w .. " Полку") end
        return (s:gsub("KOReader", "Полка"))
    end
    M.rename = rename
    M.BRAND = BRAND

    -- A few of KOReader's Russian lines, in Polka's calmer words.
    local WORDS = {
        ["Searching dictionary for:\n%1"] = "Ищу в словаре:\n%1",
    }

    local function disabled()
        if not G_reader_settings then return false end
        local d = G_reader_settings:readSetting("plugins_disabled")
        return type(d) == "table" and d.polka == true
    end

    function M.rebrand()
        if disabled() or not exists(plugin_dir .. "/main.lua") then return end
        local _ = require("gettext")
        local t = _.translation
        if type(t) ~= "table" then return end
        for _i, msgid in ipairs(BRAND) do
            if type(t[msgid]) == "string" then t[msgid] = rename(t[msgid]) end
        end
        if tostring(_.current_lang or ""):match("^ru") then
            for msgid, text in pairs(WORDS) do
                if t[msgid] then t[msgid] = text end
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
