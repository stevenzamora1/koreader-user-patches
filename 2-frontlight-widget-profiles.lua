--[[
FrontLight Widget — Night Mode & Light Profiles
Version 1.1.0

Original patch (v1.0.x) by peterboda236:
  https://github.com/peterboda236/koreader-user-patches
v1.1.0 changes by stevenzamora1:
  https://github.com/stevenzamora1/koreader-user-patches

Extends KOReader's built-in Frontlight dialog (without modifying the base
widget file) with a "Profiles" section:

      Night mode · Profile 1 · Profile 2
      Profile 3  · Profile 4 · Profile 5

  - Tap a profile to apply its brightness, warmth (on natural-light
    devices) and night-mode state. The profile matching the current
    light is shown highlighted, and so is "Night mode" while it is on.
  - Tap an empty (grey) slot to save the current light into it.
  - Long-press a saved profile to rename it, overwrite it with the
    current light, or delete it.

Every saved profile is also a KOReader action named "Light profile: <name>",
so it can be assigned to a gesture, a hotkey, a profile, the quick menu, or
any plugin that lists system actions (in the gesture manager, look under
"Screen and lights").

Profiles are stored via G_reader_settings as "frontlight_profile_<n>"
({ name, brightness, warmth, night_mode }); the action for slot <n> is
also called "frontlight_profile_<n>", so renaming a profile keeps its
shortcuts working.
--]]

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrontLightWidget = require("ui/widget/frontlightwidget")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext") -- KOReader's own translations, for the words it already knows

-- Don't hook everything a second time if a copy of this patch was already loaded.
if FrontLightWidget._light_profiles_patch then
    return
end
FrontLightWidget._light_profiles_patch = true

local PROFILE_COUNT = 5
local COLUMNS = 3 -- buttons per row (night mode + 5 profiles = 2 rows)
local SETTING_PREFIX = "frontlight_profile_" -- .. n: where a profile is stored
local ACTION_PREFIX = "frontlight_profile_" -- .. n: the id of its shortcut action
local APPLY_EVENT = "ApplyFrontlightProfile" -- what that action sends

-- --- texts KOReader has no translation for (en / hu, English when one is missing) ---
local STRINGS = {
    en = {
        profiles   = "Profiles",
        profile    = "Profile",
        save_title = "Save current frontlight settings?",
        name_hint  = "Profile name",
        now        = "now",
        no_profile = "No profile saved for this button.",
        action     = "Light profile: %s",
    },
    hu = {
        profiles   = "Profilok",
        profile    = "Profil",
        save_title = "Elmentem az aktuális Kijelzővilágítás beállítást?",
        name_hint  = "Profil neve",
        now        = "most",
        no_profile = "Nincs elmentett profil ehhez a gombhoz.",
    },
}
local L = STRINGS.en
do
    local lang = G_reader_settings:readSetting("language") or "en"
    local translated = STRINGS[lang] or STRINGS[lang:sub(1, 2)]
    if translated and translated ~= STRINGS.en then
        L = setmetatable(translated, { __index = STRINGS.en })
    end
end

-- --- stored profiles ---

local function readProfile(index)
    local profile = G_reader_settings:readSetting(SETTING_PREFIX .. index)
    if type(profile) == "table" and tonumber(profile.brightness) then
        return profile
    end
end

local function getProfileName(index, profile)
    local name = profile and profile.name
    if type(name) == "string" and name ~= "" then
        return name
    end
    return L.profile .. " " .. index
end

-- profile: { name, brightness, warmth, night_mode }, or nil to delete the slot
local function writeProfile(index, profile)
    local key = SETTING_PREFIX .. index
    if profile then
        G_reader_settings:saveSetting(key, profile)
        G_reader_settings:saveSetting(key .. "_name", profile.name) -- (only read by v1.0.x of this patch)
    else
        G_reader_settings:delSetting(key)
        G_reader_settings:delSetting(key .. "_name")
    end
end

-- --- the light itself ---

-- The current light, in the same shape as a stored profile.
local function getCurrentLight()
    local powerd = Device:getPowerDevice()
    return {
        brightness = powerd:frontlightIntensity(), -- 0 when the frontlight is toggled off
        warmth = Device:hasNaturalLight() and powerd:frontlightWarmth() or nil,
        night_mode = G_reader_settings:isTrue("night_mode"),
    }
end

-- (a value missing on either side is not compared)
local function isSameLight(a, b)
    return tonumber(a.brightness) == tonumber(b.brightness)
        and (a.warmth == nil or b.warmth == nil or a.warmth == b.warmth)
        and (a.night_mode == nil or b.night_mode == nil or a.night_mode == b.night_mode)
end

-- One line per value, with the same numbers as the dialog shows:
--   Brightness: 40 (now 25)
--   Warmth: 6
--   Night mode: off
-- `now` (optional) is the light to compare with: a value is only repeated where it differs.
local function describeLight(light, now)
    local powerd = Device:getPowerDevice()
    local function warmth(l)
        return l and l.warmth and powerd:toNativeWarmth(l.warmth)
    end
    local function onOff(l)
        if l and l.night_mode ~= nil then
            return l.night_mode and _("on") or _("off")
        end
    end
    local lines = {}
    local function add(label, value, now_value)
        if value == nil then return end
        local line = label .. ": " .. tostring(value)
        if now_value ~= nil and now_value ~= value then
            line = line .. " (" .. L.now .. " " .. tostring(now_value) .. ")"
        end
        table.insert(lines, line)
    end
    add(_("Brightness"), tonumber(light.brightness), now and now.brightness)
    if Device:hasNaturalLight() then
        add(_("Warmth"), warmth(light), warmth(now))
    end
    add(_("Night mode"), onOff(light), onOff(now))
    return table.concat(lines, "\n")
end

local open_dialog -- the Frontlight dialog currently on screen, if any
local refreshDialog -- defined with the dialog code below

-- Applies a stored profile. Works with or without the Frontlight dialog being open.
-- from_shortcut: called by a gesture/button rather than from the dialog, so tell the user what happened.
local function applyProfile(index, from_shortcut)
    local Notification = require("ui/widget/notification")
    local profile = readProfile(index)
    if not profile then
        if from_shortcut then
            Notification:notify(L.no_profile)
        end
        return false
    end

    if Device:hasFrontlight() then
        local powerd = Device:getPowerDevice()
        local brightness = tonumber(profile.brightness)
        if brightness <= powerd.fl_min then
            powerd:turnOffFrontlight()
        else
            powerd:setIntensity(brightness)
        end
        if profile.warmth and Device:hasNaturalLight() then
            powerd:setWarmth(profile.warmth)
        end
        -- Register this as an "interactive" frontlight change, so that KOReader restores
        -- this state after a suspend/resume instead of the one from before the profile.
        powerd:updateResumeFrontlightState()
    end

    if profile.night_mode ~= nil and profile.night_mode ~= G_reader_settings:isTrue("night_mode") then
        -- Let KOReader do the switch itself: besides flipping the screen and the setting, it also
        -- resets the book renderer's cache and uses the night-mode full refresh rate.
        UIManager:broadcastEvent(Event:new("SetNightMode", profile.night_mode))
    end

    if open_dialog then
        refreshDialog(open_dialog)
    end
    if from_shortcut then
        Notification:notify(L.action:format(getProfileName(index, profile)))
    end
    return true
end

-- --- shortcuts: one KOReader action per saved profile ---

-- (Re)registers our actions, so their list and titles always match the saved profiles.
local function syncActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher.registerAction then
        logger.warn("light-profiles: no Dispatcher, profiles won't be available as actions")
        return
    end
    if Dispatcher.removeAction then
        for i = 1, PROFILE_COUNT do
            Dispatcher:removeAction(ACTION_PREFIX .. i)
        end
    end
    for i = 1, PROFILE_COUNT do
        local profile = readProfile(i)
        if profile then
            Dispatcher:registerAction(ACTION_PREFIX .. i, {
                category = "none", -- a plain action, no value to pick
                event = APPLY_EVENT,
                arg = i,
                title = L.action:format(getProfileName(i, profile)),
                screen = true, -- listed under "Screen and lights"
            })
        end
    end
end

-- Done once the UI is up rather than right now, so that this patch doesn't make KOReader
-- load its file manager and reader modules earlier than it normally would.
UIManager:nextTick(function()
    -- DeviceListener is the part of KOReader (alive in both the file manager and the reader)
    -- that handles the built-in frontlight actions: ours are handled in the same place.
    local DeviceListener = require("device/devicelistener")
    DeviceListener["on" .. APPLY_EVENT] = function(_self, index)
        applyProfile(index, true)
        return true
    end
    syncActions()
end)

-- --- the Frontlight dialog ---

-- Shows a button as saved (black) or empty (grey), and highlighted (inverted) or not.
local function setButtonState(button, text, saved, highlighted)
    button.preselect = highlighted -- (what Button:init() reads)
    if button.text ~= text or button.enabled ~= saved then
        button.text = text
        button.enabled = saved
        -- Rebuild it, as Button:setText() does: a new text may need another font size to fit.
        button.label_widget:free()
        button:init()
    else
        button.frame.invert = highlighted
    end
end

local function refreshButtons(dialog)
    if not dialog.profile_buttons then return end
    local current = getCurrentLight()
    for i, button in ipairs(dialog.profile_buttons) do
        local profile = readProfile(i)
        setButtonState(button, getProfileName(i, profile), profile ~= nil,
            profile ~= nil and isSameLight(profile, current))
    end
    setButtonState(dialog.nm_button, dialog.nm_button.text, true, current.night_mode)
end

-- Makes the dialog show the light as it is now, after we changed it behind its back.
refreshDialog = function(dialog)
    if not dialog.updateBrightnessWidgets then
        -- Older KOReader: no way to update the dialog in place, reopen it instead.
        UIManager:close(dialog)
        UIManager:show(FrontLightWidget:new{})
        return
    end
    local powerd = dialog.powerd
    dialog.fl.cur = powerd:frontlightIntensity()
    dialog:updateBrightnessWidgets()
    if dialog.has_nl and dialog.nl_progress then
        -- (same steps as FrontLightWidget:setWarmth())
        local nl = dialog.nl
        nl.cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
        dialog.nl_progress:setPosition(math.floor(nl.cur / nl.stride), dialog.nl_progress.default_position)
        dialog.nl_level:setText(tostring(nl.cur))
        dialog.nl_minus:enableDisable(nl.cur ~= nl.min)
        dialog.nl_plus:enableDisable(nl.cur ~= nl.max)
    end
    dialog:update() -- repaints, and refreshes our buttons (see below)
end

-- Save / rename / overwrite / delete dialog for one slot.
local function showProfileDialog(dialog, index)
    local InputDialog = require("ui/widget/inputdialog")
    local profile = readProfile(index)
    local current = getCurrentLight()
    local input_dialog

    local function finish(new_profile)
        writeProfile(index, new_profile)
        UIManager:close(input_dialog)
        syncActions()
        if open_dialog == dialog then -- (still on screen)
            dialog:update()
        end
    end
    local function getTypedName()
        local name = input_dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
        return name ~= "" and name or getProfileName(index)
    end
    local cancel_button = {
        text = _("Cancel"),
        id = "close",
        callback = function()
            UIManager:close(input_dialog)
        end,
    }
    local save_button = {
        text = profile and _("Overwrite") or _("Save"),
        id = "save",
        is_enter_default = true,
        callback = function()
            current.name = getTypedName()
            finish(current)
        end,
    }

    local title, description, buttons
    if profile then
        title = getProfileName(index, profile)
        description = describeLight(profile, current)
        buttons = {
            {
                cancel_button,
                {
                    text = _("Delete"),
                    id = "delete",
                    callback = function()
                        finish(nil)
                    end,
                },
            },
            {
                {
                    text = _("Rename"),
                    id = "rename",
                    callback = function()
                        profile.name = getTypedName()
                        finish(profile)
                    end,
                },
                save_button,
            },
        }
    else
        title = L.save_title
        description = describeLight(current)
        buttons = { { cancel_button, save_button } }
    end

    input_dialog = InputDialog:new{
        title = title,
        description = description,
        input = getProfileName(index, profile),
        input_hint = L.name_hint,
        buttons = buttons,
    }
    -- No onShowKeyboard(): the keyboard only appears when the field is tapped, so the
    -- release of the long-press that opened this dialog can't land on a key.
    UIManager:show(input_dialog)
end

-- Builds the "Profiles" section and adds it at the bottom of the dialog.
local function addProfileSection(self)
    -- self.frame[1] is the VerticalGroup holding the title bar and the brightness/warmth controls.
    local frame_group = self.frame[1]
    local base_height = self.frame:getSize().h

    -- What each button does: night mode first, then the profiles.
    local specs = {
        {
            text = _("Night mode"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ToggleNightMode"))
                self:update()
            end,
        },
    }
    for i = 1, PROFILE_COUNT do
        local function edit()
            showProfileDialog(self, i)
        end
        table.insert(specs, {
            text = getProfileName(i, readProfile(i)),
            callback = function()
                if readProfile(i) then
                    applyProfile(i)
                else
                    edit() -- nothing to apply yet: offer to save
                end
            end,
            hold_callback = edit,
        })
    end

    -- Lays the buttons out in rows of `columns`, outer ones flush to the edges like KOReader's own rows.
    local function buildSection(columns, button_width)
        local gap = math.floor((self.inner_width - columns * button_width) / (columns - 1))
        local row_gap = math.floor(self.span * 1.5 + 0.5) -- as around the brightness bar
        local section = VerticalGroup:new{
            align = "center",
            -- Same gap and caption style as between "Brightness" and "Warmth"
            VerticalSpan:new{ width = Size.span.vertical_large * 4 },
            TextWidget:new{
                text = L.profiles,
                face = self.medium_font_face,
                bold = true,
                max_width = self.inner_width,
            },
        }
        local buttons = {}
        local focus_rows = {} -- for keyboard / D-pad navigation
        local row
        for i, spec in ipairs(specs) do
            if (i - 1) % columns == 0 then
                row = HorizontalGroup:new{ align = "center" }
                table.insert(section, VerticalSpan:new{ width = row_gap })
                table.insert(section, row)
                table.insert(focus_rows, {})
            else
                table.insert(row, HorizontalSpan:new{ width = gap })
            end
            buttons[i] = Button:new{
                text = spec.text,
                width = button_width,
                callback = spec.callback,
                hold_callback = spec.hold_callback,
                -- An empty slot is drawn disabled (grey), but still reacts.
                allow_tap_when_disabled = true,
                allow_hold_when_disabled = true,
                show_parent = self,
            }
            table.insert(row, buttons[i])
            table.insert(focus_rows[#focus_rows], buttons[i])
        end
        table.insert(section, VerticalSpan:new{ width = self.span * 2 })
        return section, buttons, focus_rows
    end

    -- Rows of full-size buttons when the dialog stays on screen that way (portrait),
    -- otherwise everything on one row of narrower buttons (landscape).
    local section, buttons, focus_rows = buildSection(COLUMNS, self.button_width)
    if base_height + section:getSize().h > self.screen_height then
        section:free()
        local gap = Size.padding.large
        section, buttons, focus_rows = buildSection(#specs, math.floor((self.inner_width - (#specs - 1) * gap) / #specs))
    end
    for _i, focus_row in ipairs(focus_rows) do
        table.insert(self.layout, focus_row)
    end

    -- frame_group is left-aligned: center our section over the full width, like the controls above it.
    table.insert(frame_group, CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = section:getSize().h },
        section,
    })
    frame_group:resetLayout() -- its size changed

    self.nm_button = table.remove(buttons, 1)
    self.profile_buttons = buttons
    refreshButtons(self) -- grey for empty slots, highlights
    open_dialog = self
end

-- self.layout is a method only until the original has run: it then becomes a table (the focus rows).
local orig_layout = FrontLightWidget.layout
FrontLightWidget.layout = function(self)
    orig_layout(self)
    -- If a KOReader update ever changes the dialog's structure, keep the plain dialog working.
    local ok, err = pcall(addProfileSection, self)
    if not ok then
        logger.warn("light-profiles: could not add the profiles section:", err)
        self.profile_buttons = nil
    end
end

-- KOReader calls this after every change made in the dialog (＋/−, the bars, Min/Max...):
-- keep the highlights in sync with the light.
local orig_update = FrontLightWidget.update
function FrontLightWidget:update(...)
    refreshButtons(self)
    return orig_update(self, ...)
end

local orig_onCloseWidget = FrontLightWidget.onCloseWidget
function FrontLightWidget:onCloseWidget(...)
    if open_dialog == self then
        open_dialog = nil
    end
    if orig_onCloseWidget then
        return orig_onCloseWidget(self, ...)
    end
end
