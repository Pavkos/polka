-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: «Полка» on the Kindle's own screen.

A jailbroken Kindle lists every .sh in /mnt/us/documents as a book and runs
it when tapped (scriptlets; KPM installs KOReader's own launcher that way).
Polka's launcher (kindle/polka.sh) paints Polka's splash (kindle/splash-*.png)
and starts KOReader without its «Starting KOReader . . .». It is copied there
only on request (О Полке → «Полка на экране Kindle» → «Добавить»), with the
real paths filled in, and removed the same way.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Launcher = {
    NAME = "polka.sh",
    MARK = "The «Полка» launcher",
}

local function documents()
    local dir = os.getenv("POLKA_TEST_DOCUMENTS") -- for tests on a computer
    if dir then return dir end
    if require("device"):isKindle() then return "/mnt/us/documents" end
end

local function absolute(path)
    if path:sub(1, 1) ~= "/" then path = lfs.currentdir() .. "/" .. path end
    return (path:gsub("/%./", "/"):gsub("//+", "/"))
end

local function pluginDir()
    local Web = require("polka_web")
    return Web.plugin_dir and absolute(Web.plugin_dir)
end

local function target()
    local dir = documents()
    return dir and (dir .. "/" .. Launcher.NAME)
end

function Launcher.possible()
    local dir = documents()
    return dir ~= nil and lfs.attributes(dir, "mode") == "directory" and pluginDir() ~= nil
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function Launcher.installed()
    local s = target() and read(target())
    return s ~= nil and s:find(Launcher.MARK, 1, true) ~= nil
end

-- KOReader's own folder (koreader.sh): where it runs from, as koreader.sh starts it there.
local function koreaderDir(plugin_dir)
    local cwd = lfs.currentdir()
    if cwd and lfs.attributes(cwd .. "/koreader.sh", "mode") == "file" then return absolute(cwd) end
    return (plugin_dir:gsub("/plugins/[^/]+$", ""))
end

--- The launcher with this Kindle's paths in it.
function Launcher.script()
    local dir = pluginDir()
    local s = dir and read(dir .. "/kindle/polka.sh")
    if not s then return nil end
    local koreader = koreaderDir(dir)
    s = s:gsub("@@POLKA_DIR@@", (dir:gsub("%%", "%%%%"))):gsub("@@KOREADER_DIR@@", (koreader:gsub("%%", "%%%%")))
    return s
end

function Launcher.install()
    local s = Launcher.script()
    local path = target()
    if not (s and path) then return false end
    local tmp = path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(s)
    f:close()
    if not ok or not os.rename(tmp, path) then
        os.remove(tmp)
        logger.warn("Polka: cannot add the launcher to", path)
        return false
    end
    return true
end

-- Only our own file goes (never someone else's polka.sh).
function Launcher.remove()
    if Launcher.installed() then os.remove(target()) end
end

--- After an update: a launcher already there gets the new version.
function Launcher.refresh()
    if not Launcher.possible() or not Launcher.installed() then return end
    local s = Launcher.script()
    if s and read(target()) ~= s then Launcher.install() end
end

return Launcher
