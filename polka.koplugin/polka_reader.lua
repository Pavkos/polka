--[[--
Polka: reading like on a classic Kindle.

* The status line becomes Kindle's: "Осталось в главе: 12 мин" on the left,
  "42%" on the right. A tap on the left part cycles
  chapter time → book time → page → nothing.
* A tap on the top of the page opens Polka's Kindle toolbar instead of
  KOReader's menus; a tap on the bottom simply turns the page.
* The «Aa» panel (polka_aa) changes font, boldness, size, spacing, margins
  and alignment in a few taps.
* The screen flashes like a Kindle's: when a chapter starts (and on
  pictures), not every 6 pages — unless the user picked a rate.

Everything is done by patching *instances* of the current book's modules
(footer, menu, bottom menu, gestures): KOReader's classes and settings stay
untouched, and switching the mode off restores the stock behaviour at once.
Swiping down from the top still opens KOReader's own menu.
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local UI = require("polka_ui")

local Reader = {}
Reader.__index = Reader

Reader.FOOTER_MODES = { "chapter", "book", "page", "none" }

local FOOTER_FONT_SIZE = 12

-- KOReader's style tweak "Ignore publisher font families" (see setFont).
local FONT_TWEAK = "font_family_all_inherit"

-- Stock corner taps that make no sense in Kindle mode. Only the stock
-- defaults are skipped; anything the user assigned keeps working.
local PASS_THROUGH = {
    tap_top_left_corner = true,    -- KOReader: page flipping mode; Kindle: toolbar
    tap_left_bottom_corner = true, -- KOReader: frontlight toggle; Kindle: status line
}

function Reader.isOn()
    return G_reader_settings:nilOrTrue("polka_reader")
end

function Reader.new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui, saved = {}, active = false }, Reader)
end

-- Instance-level patching helpers: remember the instance's own value (most
-- often nil, i.e. the class method) and put it back on detach.
function Reader:patch(obj, key, value)
    if not obj then return end
    table.insert(self.saved, { obj = obj, key = key, value = rawget(obj, key) })
    obj[key] = value
end

function Reader:restorePatches()
    for i = #self.saved, 1, -1 do
        local s = self.saved[i]
        rawset(s.obj, s.key, s.value)
    end
    self.saved = {}
    self.gestures_patched = false
end

--- Turn the Kindle mode on for this book.
-- @bool runtime true when the book is already on screen (re-lays it out)
function Reader:attach(runtime)
    if self.active then return end
    self.active = true
    if not runtime then
        self:applyNewBookDefaults()
    end
    self:patchFooter()
    self:patchTaps()
    self:patchSelection()
    self:applyRefresh()
    if runtime then
        self:relayout()
    end
end

function Reader:detach()
    if not self.active then return end
    self.active = false
    self:closeOverlays()
    self:restoreRefresh()
    local footer = self.footer
    self:restorePatches()
    -- the quiet gestures (polka_quiet) may have sat on top of ours
    pcall(function() require("polka_quiet").patchGestures(self.ui) end)
    if footer then
        if self.footer_mode_before ~= nil then
            footer:applyFooterMode(self.footer_mode_before)
        end
        footer:updateFooterContainer()
        footer:resetLayout(true)
    end
    self.footer = nil
    self.footer_mode_before = nil
    self:relayout()
end

-- The footer height is part of the page margins: re-apply them.
function Reader:relayout()
    local typeset = self.ui.typeset
    if self.ui.rolling and typeset and typeset.unscaled_margins then
        self.ui:handleEvent(Event:new("SetPageMargins", typeset.unscaled_margins))
    end
    local footer = self.ui.view and self.ui.view.footer
    if footer and footer.onUpdateFooter then
        pcall(footer.onUpdateFooter, footer)
    end
    UIManager:setDirty(self.ui.dialog, "full")
end

function Reader:closeOverlays()
    if self.selection then
        local panel = self.selection
        self.selection = nil
        if panel.dismiss then panel.dismiss() else UIManager:close(panel) end
    end
    if self.toolbar then
        UIManager:close(self.toolbar)
        self.toolbar = nil
    end
    if self.aa then
        UIManager:close(self.aa)
        self.aa = nil
    end
end

-- Screen refresh -------------------------------------------------------------------

-- A Kindle turns pages without flashing and cleans the screen with a flash
-- when a chapter starts (and on pictures). KOReader by default flashes every
-- 6 pages. As long as the user hasn't picked a rate (in KOReader's menu or
-- in Polka's Настройки), a book in Kindle mode gets the Kindle way: KOReader's
-- own "Every chapter" mode, set in memory only. Nothing is saved; the rate
-- KOReader would use comes back when the book closes or the mode is off.
Reader.KINDLE_REFRESH = -1

function Reader.kindleRefresh()
    return G_reader_settings:hasNot("full_refresh_count")
end

function Reader:applyRefresh()
    if not self.active or not self.ui.rolling then return end
    self.refresh_wanted = true
    if not Reader.kindleRefresh() then return end
    if G_reader_settings:isTrue("night_mode") and G_reader_settings:has("night_full_refresh_count") then
        return -- a night rate of the user's own
    end
    self.refresh_applied = true
    UIManager.FULL_REFRESH_COUNT = Reader.KINDLE_REFRESH
end

function Reader:restoreRefresh()
    self.refresh_wanted = nil
    if not self.refresh_applied then return end
    self.refresh_applied = nil
    local day, night = UIManager:getRefreshRate()
    UIManager.FULL_REFRESH_COUNT = G_reader_settings:isTrue("night_mode") and night or day
end

-- Toggling night mode makes KOReader set its own rate again.
function Reader:onNightModeChanged()
    if self.refresh_wanted then
        self.refresh_applied = nil
        self:applyRefresh()
    end
end

-- Selection panel ------------------------------------------------------------------

function Reader.selectionMenuOn()
    return G_reader_settings:nilOrTrue("polka_selection_menu")
end

-- KOReader's menu after a selection, and its dialog for a tapped highlight,
-- give way to Polka's small card (polka_selection). The setting is read at
-- each use, so switching it off takes effect at once.
function Reader:patchSelection()
    local hl = self.ui.highlight
    if not hl then return end
    local me = self
    local orig_menu = hl.onShowHighlightMenu
    local orig_note_or_dialog = hl.showHighlightNoteOrDialog
    local orig_dialog = hl.showHighlightDialog
    if type(orig_menu) ~= "function" or type(orig_note_or_dialog) ~= "function" or type(orig_dialog) ~= "function" then
        return -- an unknown KOReader: leave its menus alone
    end
    self:patch(hl, "onShowHighlightMenu", function(this, index, ...)
        if index or not this.selected_text or not Reader.selectionMenuOn() then
            return orig_menu(this, index, ...)
        end
        local ok, err = pcall(require("polka_selection").showNew, me, this, orig_menu)
        if not ok then
            logger.warn("Polka: selection panel:", err)
            return orig_menu(this, index, ...)
        end
        return true
    end)
    self:patch(hl, "showHighlightNoteOrDialog", function(this, index, ...)
        if not Reader.selectionMenuOn() then return orig_note_or_dialog(this, index, ...) end
        local ok, err = pcall(require("polka_selection").showExisting, me, this, index, orig_dialog)
        if not ok then
            logger.warn("Polka: highlight panel:", err)
            return orig_note_or_dialog(this, index, ...)
        end
        return true
    end)
end

-- Status line --------------------------------------------------------------------

function Reader:patchFooter()
    local view = self.ui.view
    local footer = view and view.footer
    -- Reflowable books only (PDF pages keep KOReader's own status bar), and
    -- not when the user switched KOReader's status bar off completely.
    if not footer or not self.ui.rolling or not footer.footer_content
        or (footer.settings and footer.settings.disabled) then
        return
    end
    self.footer = footer
    local me = self
    self:patch(footer, "getHeight", function()
        local h = me:footerHeight()
        if me._margin_b then
            -- KOReader adds this to the book's bottom margin. Like on a Kindle,
            -- the line sits inside that margin instead, a small gap above it.
            return math.max(0, h + UI.px(6) - me._margin_b)
        end
        return h
    end)
    self:patch(footer, "paintTo", function(_, bb, x, y) me:paintFooter(bb, x, y) end)
    self:patch(footer, "TapFooter", function(this, ges)
        if this.view.flipping_visible then
            -- page flipping mode: the whole line acts as a progress bar
            if ges and ges.pos then
                me.ui:handleEvent(Event:new("GotoPercentage", ges.pos.x / Screen:getWidth()))
                this:onUpdateFooter(true)
            end
            return true
        end
        local ok, handled = pcall(me.onFooterTap, me, ges)
        if not ok then
            logger.warn("Polka: status line tap:", handled)
            return
        end
        return handled
    end)
    -- The page always keeps room for the line, even with KOReader's
    -- "Overlap status bar" on (the menu can flip that flag at any time,
    -- so it is ignored here rather than changed).
    local typeset = self.ui.typeset
    if typeset then
        local class_margins = typeset.onSetPageMargins
        self:patch(typeset, "onSetPageMargins", function(this, margins, cb)
            local saved = rawget(footer, "reclaim_height")
            footer.reclaim_height = false
            me._margin_b = type(margins) == "table" and Screen:scaleBySize(tonumber(margins[4]) or 0) or 0
            local ok, res = pcall(class_margins, this, margins, cb)
            me._margin_b = nil
            footer.reclaim_height = saved
            if not ok then error(res) end
            return res
        end)
    end
    if not view.footer_visible then
        -- Our line lives where KOReader's status bar is: make it "visible"
        -- for this book (the user's saved choice is left alone).
        self.footer_mode_before = footer.mode
        footer:applyFooterMode(footer.mode_list and footer.mode_list.page_progress or 1)
    end
end

function Reader:footerFace()
    return UI.face("sans", FOOTER_FONT_SIZE)
end

function Reader:footerTextHeight()
    if not self._footer_th then
        local probe = TextWidget:new{ text = "Ag", face = self:footerFace() }
        self._footer_th = probe:getSize().h
        probe:free()
    end
    return self._footer_th
end

-- Above the line the book's own bottom margin gives the gap; below it a
-- little air before the screen edge, as on a Kindle.
function Reader:footerPads()
    return 0, UI.px(7)
end

function Reader:footerHeight()
    local top, bottom = self:footerPads()
    return self:footerTextHeight() + top + bottom
end

function Reader:footerMode()
    local mode = G_reader_settings:readSetting("polka_footer_mode") or "chapter"
    for _, m in ipairs(Reader.FOOTER_MODES) do
        if m == mode then return mode end
    end
    return "chapter"
end

-- The line is aligned with the text column, like on a Kindle.
function Reader:footerMargins()
    local m = self.ui.typeset and self.ui.typeset.unscaled_margins
    local min = UI.px(6)
    if not m then return min, min end
    return math.max(min, Screen:scaleBySize(m[1] or 0)), math.max(min, Screen:scaleBySize(m[3] or 0))
end

-- 75 s -> "1 мин", 3725 s -> "1 ч 2 мин"
function Reader.timeLeft(secs)
    if secs < 60 then return "меньше минуты" end
    local mins = math.floor(secs / 60 + 0.5)
    if mins < 60 then return string.format("%d мин", mins) end
    local h, m = math.floor(mins / 60), mins % 60
    if m == 0 then return string.format("%d ч", h) end
    return string.format("%d ч %d мин", h, m)
end

-- Average seconds per page: this book first (once there is enough of it),
-- otherwise the reader's usual pace over the last two months.
function Reader:secsPerPage()
    local st = self.ui.statistics
    local enabled = st and st.settings and st.settings.is_enabled
    if enabled and st.avg_time and st.avg_time == st.avg_time and st.avg_time > 0 then
        local pages = (st.book_read_pages or 0) + (st.mem_read_pages or 0)
        if pages >= 5 then return st.avg_time end
    end
    if self._global_spp == nil then
        self._global_spp = Reader.globalSecsPerPage() or false
    end
    if self._global_spp then return self._global_spp end
    return nil, enabled
end

function Reader.globalSecsPerPage()
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return end
    local ok, res = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local since = os.time() - 60 * 86400
        local r = conn:exec("SELECT sum(duration), count(*) FROM page_stat_data WHERE start_time > " .. since .. ";")
        conn:close()
        if not r or not r[1] then return end
        local secs, n = tonumber(r[1][1]), tonumber(r[2][1])
        if secs and n and n >= 20 and secs > 0 then return secs / n end
    end)
    if ok then return res end
    logger.warn("Polka: reading speed query failed:", res)
end

-- Seconds left to the end of the chapter ("chapter") or the book ("book").
-- Returns nil (and whether the statistics plugin is still learning) when
-- the reading speed is not known yet.
function Reader:secsLeft(mode, pageno)
    local spp, learning = self:secsPerPage()
    if not spp then return nil, learning end
    local doc = self.ui.document
    local left_pages
    if mode == "chapter" then
        left_pages = self.ui.toc and self.ui.toc:getChapterPagesLeft(pageno, true)
    end
    if not left_pages then
        left_pages = doc:getTotalPagesLeft(pageno) or 0
    end
    return (left_pages + 1) * spp
end

function Reader:footerTexts(mode)
    local footer = self.footer
    local doc = self.ui.document
    local pageno = footer and footer.pageno
    if not pageno then return "", "" end
    local pages = (footer.pages and footer.pages > 0) and footer.pages or doc:getPageCount()
    local pct = footer.percent_finished or (pageno / math.max(1, pages))
    local right = string.format("%d%%", math.floor(pct * 100))
    if mode == "page" then
        return string.format("Стр. %d из %d", pageno, pages), right
    end
    local secs, learning = self:secsLeft(mode, pageno)
    if not secs then
        if learning then return "Определяем скорость чтения…", right end
        return string.format("Стр. %d из %d", pageno, pages), right
    end
    local label = mode == "chapter" and "Осталось в главе: " or "Осталось в книге: "
    return label .. Reader.timeLeft(secs), right
end

function Reader:footerRegion()
    local fh = self:footerHeight()
    return Geom:new{ x = 0, y = Screen:getHeight() - fh, w = Screen:getWidth(), h = fh }
end

function Reader:paintFooter(bb, x, y)
    -- Painted on every page turn from inside KOReader: never let it throw.
    local ok, err = pcall(self._paintFooter, self, bb, x, y)
    if not ok and not self._paint_error_logged then
        self._paint_error_logged = true
        logger.warn("Polka: status line:", err)
    end
end

function Reader:_paintFooter(bb, x, y)
    local region = self:footerRegion()
    local top = y + region.y
    -- KOReader uses this as the refresh area of its own footer updates.
    if self.footer and self.footer.footer_content then
        self.footer.footer_content.dimen = Geom:new{ x = x, y = top, w = region.w, h = region.h }
    end
    bb:paintRect(x, top, region.w, region.h, Blitbuffer.COLOR_WHITE)
    local mode = self:footerMode()
    if mode == "none" then return end
    local left, right = self:footerTexts(mode)
    local ml, mr = self:footerMargins()
    local face = self:footerFace()
    local rw = TextWidget:new{ text = right, face = face, fgcolor = UI.C.text2 }
    local rsize = rw:getSize()
    local lw = TextWidget:new{ text = left, face = face, fgcolor = UI.C.text2,
                               max_width = math.max(UI.px(40), region.w - ml - mr - rsize.w - UI.px(24)) }
    local pad_top = self:footerPads()
    lw:paintTo(bb, x + ml, top + pad_top)
    rw:paintTo(bb, x + region.w - mr - rsize.w, top + pad_top)
    lw:free()
    rw:free()
end

function Reader:repaintFooter()
    local footer = self.footer
    if not footer then return end
    local region = self:footerRegion()
    local top = UIManager:getTopmostVisibleWidget() or {}
    if top.name == "ReaderUI" then
        UIManager:widgetRepaint(footer, 0, 0)
        UIManager:setDirty(nil, "ui", region)
    else
        UIManager:setDirty(self.ui.dialog, "ui", region)
    end
end

function Reader:onFooterTap(ges)
    -- Only the line itself, left part, cycles; the rest of the bottom
    -- (including the last line of text above it) turns the page.
    -- The line is short; the finger gets a slightly taller strip.
    local zone_top = Screen:getHeight() - math.max(self:footerHeight(), UI.px(30))
    if ges and ges.pos and (ges.pos.x > Screen:getWidth() * 0.6 or ges.pos.y < zone_top) then
        return
    end
    local modes = Reader.FOOTER_MODES
    local cur = self:footerMode()
    local idx = 1
    for i, m in ipairs(modes) do
        if m == cur then idx = i end
    end
    G_reader_settings:saveSetting("polka_footer_mode", modes[idx % #modes + 1])
    self:repaintFooter()
    return true
end

-- Taps --------------------------------------------------------------------------

function Reader:patchTaps()
    local me = self
    -- Top of the page: the Kindle toolbar. (Swipe down still opens KOReader's menu.)
    self:patch(self.ui.menu, "onTapShowMenu", function()
        UI.safely(function() me:openToolbar() end)
        return true
    end)
    -- Bottom of the page: no menu, the tap falls through to the page turn zones.
    self:patch(self.ui.config, "onTapShowConfigMenu", function() return nil end)
    self:patchGestures()
end

-- The Gestures plugin may be created after Polka: also called on ReaderReady.
function Reader:patchGestures()
    local gestures = self.ui.gestures
    if not self.active or self.gestures_patched or not gestures or not gestures.gestureAction then
        return
    end
    self.gestures_patched = true
    local me = self
    local class_action = gestures.gestureAction
    self:patch(gestures, "gestureAction", function(this, action, ges)
        if me.active and PASS_THROUGH[action] and this.defaults and this.defaults[action] ~= nil
            and util.tableEquals(this.gestures and this.gestures[action], this.defaults[action]) then
            return nil
        end
        return class_action(this, action, ges)
    end)
end

function Reader:openToolbar()
    if self.toolbar then return end
    local Toolbar = require("polka_toolbar")
    self.toolbar = Toolbar:new{ reader = self }
    UIManager:show(self.toolbar)
end

function Reader:openAa()
    if self.aa then return end
    if not self.ui.rolling then
        -- PDF and comics: KOReader's own panel (zoom, crop, contrast...)
        self.ui.config:onShowConfigMenu()
        return
    end
    local Aa = require("polka_aa")
    self.aa = Aa:new{ reader = self }
    UIManager:show(self.aa)
end

-- Text settings used by the «Aa» panel.
--
-- A change applies to the open book (KOReader keeps it in the book's own
-- settings, as usual) and is remembered by Polka in "polka_text", which is
-- applied to books opened for the first time while the Kindle mode is on.
-- KOReader's own defaults (cre_font, copt_*, global style tweaks) are never
-- touched, so switching Polka off leaves KOReader exactly as it was.

function Reader.textPrefs()
    local t = G_reader_settings:readSetting("polka_text")
    return type(t) == "table" and t or {}
end

function Reader.saveTextPref(key, value)
    local t = Reader.textPrefs()
    t[key] = value
    G_reader_settings:saveSetting("polka_text", t)
end

-- Called before KOReader reads the book's settings: a book that was never
-- opened has none, so it starts with the text settings last chosen in «Aa».
function Reader:applyNewBookDefaults()
    local ds = self.ui.doc_settings
    if not ds or not self.ui.rolling then return end
    for _, key in ipairs({ "last_xpointer", "doc_props", "font_face", "copt_font_size", "copt_h_page_margins" }) do
        if ds:has(key) then return end -- opened before: the book keeps its own settings
    end
    local p = Reader.textPrefs()
    if type(p.font) == "string" then ds:saveSetting("font_face", p.font) end
    if tonumber(p.size) then ds:saveSetting("copt_font_size", tonumber(p.size)) end
    if tonumber(p.spacing) then ds:saveSetting("copt_line_spacing", tonumber(p.spacing)) end
    if type(p.margins) == "table" and tonumber(p.margins[1]) and tonumber(p.margins[2]) and tonumber(p.margins[3]) then
        local h, t, b = tonumber(p.margins[1]), tonumber(p.margins[2]), tonumber(p.margins[3])
        ds:saveSetting("copt_h_page_margins", { h, h })
        ds:saveSetting("copt_t_page_margin", t)
        ds:saveSetting("copt_b_page_margin", b)
        ds:saveSetting("copt_sync_t_b_page_margins", 0)
    end
    if tonumber(p.weight) then ds:saveSetting("copt_font_base_weight", tonumber(p.weight)) end
    local tweaks = {}
    if p.align == "left" then
        tweaks.text_align_most_left = true
    elseif p.align == "justify" then
        tweaks.text_align_most_justify = true
    end
    -- a font picked in «Aa» is the font of the whole book, as on a Kindle
    if type(p.font) == "string" then tweaks[FONT_TWEAK] = true end
    if next(tweaks) then ds:saveSetting("style_tweaks", tweaks) end
end

function Reader:docLanguage()
    local props = self.ui.doc_props or {}
    local lang = type(props.language) == "string" and props.language:lower():match("^(%a%a)")
    return lang or "ru"
end

-- Fonts crengine knows, Kindle favourites first. Each: { name, path }.
local PREFERRED = {
    "bookerly", "literata", "caecilia", "palatino", "baskerville", "georgia", "charis",
    "noto serif", "freeserif", "futura", "helvetica", "amazon ember", "noto sans", "freesans",
}

-- Fonts made for other scripts, for code or for symbols, not for reading a novel.
local SCRIPT_FONTS = { "arabic", "naskh", "bengali", "devanagari", "cjk", "hebrew", "thai", "symbol",
                       "dingbat", "emoji", "kufi", "nerd", "mono", "courier" }

function Reader.isScriptFont(name)
    local lname = name:lower()
    for _, s in ipairs(SCRIPT_FONTS) do
        if lname:find(s, 1, true) then return true end
    end
    return false
end

-- Computed once per book: the font list doesn't change while reading.
function Reader:fontChoices()
    if self._fonts then return self._fonts end
    local FontList = require("fontlist")
    pcall(FontList.getFontList, FontList)
    local by_name = {}
    for path, infos in pairs(FontList.fontinfo or {}) do
        local info = type(infos) == "table" and infos[1]
        if info and info.name and not info.mono and not info.ui and not Reader.isScriptFont(info.name) then
            local cur = by_name[info.name]
            local regular = not info.bold and not info.italic
            if not cur or (regular and not cur.regular) then
                by_name[info.name] = { name = info.name, path = path, regular = regular, langs = info.langs }
            end
        end
    end
    local faces = {}
    -- Only fonts crengine itself registered (as ReaderFont lists them).
    local ok, list = pcall(function() return require("document/credocument"):engineInit().getFontFaces() end)
    if ok and type(list) == "table" then
        for _, name in ipairs(list) do
            if by_name[name] then faces[#faces + 1] = by_name[name] end
        end
    end
    if #faces == 0 then
        for _, f in pairs(by_name) do faces[#faces + 1] = f end
    end
    -- Drop fonts that cannot show the book's language (Kindle's Futura has no Cyrillic).
    local lang = self:docLanguage()
    local readable = {}
    for _, f in ipairs(faces) do
        if not f.langs or next(f.langs) == nil or f.langs[lang] then
            readable[#readable + 1] = f
        end
    end
    if #readable >= 2 then faces = readable end
    local function rank(f)
        local lname = f.name:lower()
        for i, p in ipairs(PREFERRED) do
            if lname:sub(1, #p) == p then return i end
        end
        return #PREFERRED + 1
    end
    table.sort(faces, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    self._fonts = faces
    return faces
end

function Reader:currentFont()
    return self.ui.font and self.ui.font.font_face
end

-- Like on a Kindle, the font picked in «Aa» is the font of the whole book:
-- KOReader's style tweak "Ignore publisher font families" for this book
-- (only its own list of tweaks changes). «Шрифт книги» brings the
-- publisher's fonts back, for books that bring their own.

function Reader:hasPublisherFonts()
    local ok, list = pcall(function() return self.ui.document:getEmbeddedFontList() end)
    return ok and type(list) == "table" and next(list) ~= nil
end

function Reader:publisherFontsOn()
    local st = self.ui.styletweak
    if not (st and st.isTweakEnabled and self:alignmentAvailable()) then return true end
    return not st:isTweakEnabled(FONT_TWEAK)
end

-- Returns true when the book's tweaks changed (the caller re-renders).
function Reader:setPublisherFontsTweak(on)
    if not self:alignmentAvailable() or self:publisherFontsOn() == on then return false end
    local st = self.ui.styletweak
    local doc, global = st.doc_tweaks, st.global_tweaks
    if on then
        if global[FONT_TWEAK] then doc[FONT_TWEAK] = false else doc[FONT_TWEAK] = nil end
    else
        if global[FONT_TWEAK] then doc[FONT_TWEAK] = nil else doc[FONT_TWEAK] = true end
    end
    return true
end

function Reader:setFont(name)
    local ui = self.ui
    -- font and stylesheet together: one re-rendering instead of two
    ui:handleEvent(Event:new("BatchedUpdate"))
    local ok, err = pcall(function()
        if self:setPublisherFontsTweak(false) then ui.styletweak:updateCssText(true) end
        ui:handleEvent(Event:new("SetFont", name))
    end)
    ui:handleEvent(Event:new("BatchedUpdateDone"))
    if not ok then error(err) end
    Reader.saveTextPref("font", name)
end

function Reader:usePublisherFonts()
    if self:setPublisherFontsTweak(true) then
        self.ui.styletweak:updateCssText(true)
    end
end

-- Kindle's five levels of boldness, as KOReader's font weight (+1 is
-- "Medium" made from the regular face; none goes as far as Bold).
Reader.WEIGHTS = { 0, 0.375, 0.75, 1.125, 1.5 }

function Reader:fontWeight()
    return tonumber(self:configurable().font_base_weight) or 0
end

function Reader:setFontWeight(w)
    self.ui:handleEvent(Event:new("SetFontBaseWeight", w))
    Reader.saveTextPref("weight", w)
end

function Reader:configurable()
    return self.ui.document.configurable
end

function Reader:fontSize()
    return self:configurable().font_size or 22
end

function Reader:setFontSize(size)
    self.ui:handleEvent(Event:new("SetFontSize", size))
    Reader.saveTextPref("size", size)
end

function Reader:lineSpacing()
    return self:configurable().line_spacing or 100
end

function Reader:setLineSpacing(pct)
    self.ui:handleEvent(Event:new("SetLineSpace", pct))
    Reader.saveTextPref("spacing", pct)
end

function Reader:margins()
    local m = self.ui.typeset and self.ui.typeset.unscaled_margins
    if m then return m[1], m[2], m[4] end
    local cfg = self:configurable()
    return cfg.h_page_margins and cfg.h_page_margins[1] or 10, cfg.t_page_margin or 15, cfg.b_page_margin or 15
end

-- One re-render instead of three: set everything, then apply once.
function Reader:setMargins(h, t, b)
    local typeset = self.ui.typeset
    local cfg = self:configurable()
    cfg.h_page_margins = { h, h }
    cfg.t_page_margin = t
    cfg.b_page_margin = b
    cfg.sync_t_b_page_margins = 0
    typeset.sync_t_b_page_margins = false
    typeset.unscaled_margins = { h, t, h, b }
    self.ui:handleEvent(Event:new("SetPageMargins", typeset.unscaled_margins))
    Reader.saveTextPref("margins", { h, t, b })
end

local LEFT_TWEAKS = { "text_align_most_left", "text_align_all_left" }

-- Style tweaks can be switched off per book; then alignment can't be set here.
function Reader:alignmentAvailable()
    local st = self.ui.styletweak
    return st ~= nil and st.enabled ~= false and st.global_tweaks ~= nil and st.doc_tweaks ~= nil
end

function Reader:alignment()
    local st = self.ui.styletweak
    if st and st.isTweakEnabled then
        for _, id in ipairs(LEFT_TWEAKS) do
            if st:isTweakEnabled(id) then return "left" end
        end
    end
    return "justify"
end

-- Per book, with KOReader's own style tweaks "Left align most text" /
-- "Justify most text": only this book's tweak list changes.
function Reader:setAlignment(mode)
    local st = self.ui.styletweak
    if not st or not st.global_tweaks or not st.doc_tweaks then return end
    local doc, global = st.doc_tweaks, st.global_tweaks
    -- A tweak enabled in KOReader's defaults is switched off for this book only.
    local function off(id)
        if global[id] then doc[id] = false else doc[id] = nil end
    end
    for _, id in ipairs(LEFT_TWEAKS) do off(id) end
    if mode == "left" then
        off("text_align_most_justify")
        doc.text_align_most_left = true
    elseif global.text_align_most_justify then
        doc.text_align_most_justify = nil -- KOReader's default already justifies
    else
        -- also over a book whose own styling is ragged
        doc.text_align_most_justify = true
    end
    st:updateCssText(true)
    Reader.saveTextPref("align", mode)
end

-- Lifecycle -------------------------------------------------------------------

function Reader:onClose()
    self:closeOverlays()
    self:restoreRefresh()
end

return Reader
