-- SPDX-License-Identifier: AGPL-3.0-or-later
--[[--
Polka: the splash — books on a shelf, «Полка», «Открываю библиотеку…».

The same picture the Kindle launcher shows (kindle/splash-*.png, made from
the same drawing) is painted here before Polka restarts, so the screen does
not sit frozen on the last page while KOReader starts again.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local Icons = require("polka_icons")
local UI = require("polka_ui")

local Splash = {}

-- The launcher's own picture for this screen, if there is one.
local function picture(W, H)
    local Web = require("polka_web")
    local dir = Web.plugin_dir
    local path = dir and string.format("%s/kindle/splash-%dx%d.png", dir, W, H)
    if not path or require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then return nil end
    local ImageWidget = require("ui/widget/imagewidget")
    return ImageWidget:new{ file = path, width = W, height = H, file_do_cache = false }
end

function Splash.widget(line)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local img = not line and picture(W, H)
    if img then
        return WidgetContainer:new{
            name = "polka_splash",
            dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
            covers_fullscreen = true,
            img,
        }
    end
    local logo_w = UI.px(148)
    local logo = Icons.widget("shelf", logo_w, { height = UI.px(112), stroke = math.max(2, UI.px(3.5)) })
    local word = UI.text{ text = "Полка", family = "serif_bold", size = 76 }
    local group = VerticalGroup:new{ align = "center", logo, UI.vgap(UI.px(22)), word }
    local note = UI.text{ text = line or "Открываю библиотеку…", size = 16, color = UI.C.text2 }
    local note_h = note:getSize().h
    local gh = group:getSize().h
    local top = math.floor((H - gh) / 2)
    local bottom_y = H - UI.px(64) - note_h
    local tree = UI.FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.C.paper, width = W, height = H,
        UI.OverlapGroup:new{
            dimen = Geom:new{ w = W, h = H },
            UI.pad(UI.center(W, gh, group), { top = top }),
            UI.pad(UI.center(W, note_h, note), { top = bottom_y }),
        },
    }
    return WidgetContainer:new{
        name = "polka_splash",
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        covers_fullscreen = true,
        tree,
    }
end

--- Shows the splash at once (and leaves it there: what comes next replaces it).
function Splash.show(line)
    local w = Splash.widget(line)
    UIManager:show(w, "full")
    UIManager:forceRePaint()
    return w
end

return Splash
