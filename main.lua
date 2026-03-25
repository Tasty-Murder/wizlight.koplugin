--[[--
KOReader plugin for controlling WiZ smart lights over the local network.

Adds a "WiZ Light" entry to the Tools menu with controls for power,
brightness, colour temperature, reading mode, and built-in scenes.

@module koplugin.wizlight
--]]--

local Dispatcher       = require("dispatcher")  -- luacheck:ignore
local InputDialog      = require("ui/widget/inputdialog")
local InfoMessage      = require("ui/widget/infomessage")
local SpinWidget       = require("ui/widget/spinwidget")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local logger           = require("logger")
local _                = require("gettext")

local Wiz = require("wizlight.wiz")

-- Curated list of WiZ scenes relevant to reading and relaxation.
local SCENES = {
    { id = 11, name = _("Warm White")  },
    { id = 12, name = _("Daylight")    },
    { id = 13, name = _("Cool White")  },
    { id = 14, name = _("Night Light") },
    { id = 15, name = _("Focus")       },
    { id = 16, name = _("Relax")       },
    { id =  6, name = _("Cozy")        },
    { id = 29, name = _("Candlelight") },
    { id =  5, name = _("Fireplace")   },
    { id =  9, name = _("Wake Up")     },
    { id = 10, name = _("Bedtime")     },
}

local WizLight = WidgetContainer:extend{
    name        = "wizlight",
    is_doc_only = false,
}

-- ── lifecycle ────────────────────────────────────────────────────────────────

function WizLight:onDispatcherRegisterActions()
    Dispatcher:registerAction("wizlight_toggle", {
        category = "none",
        event    = "WizLightToggle",
        title    = _("WiZ Light: Toggle On/Off"),
        general  = true,
    })
    Dispatcher:registerAction("wizlight_panel", {
        category = "none",
        event    = "WizLightPanel",
        title    = _("WiZ Light: Open Controls"),
        general  = true,
    })
end

function WizLight:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- ── helpers ──────────────────────────────────────────────────────────────────

function WizLight:getIP()
    return G_reader_settings:readSetting("wizlight_ip") or ""
end

--- Show a short informational toast to the user.
function WizLight:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

--- Guard helper: run `callback(ip)` only when an IP is configured.
function WizLight:withIP(callback)
    local ip = self:getIP()
    if ip == "" then
        self:notify(_("No WiZ light IP configured.\nGo to WiZ Light → Settings to add one."), 4)
        return
    end
    callback(ip)
end

--- Run a Wiz action and surface any error to the user.
function WizLight:send(action_fn, ip)
    local result, err = action_fn(ip)
    if not result then
        logger.warn("wizlight: command failed –", err)
        self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
    end
    return result
end

-- ── gesture actions ──────────────────────────────────────────────────────────

--- Fetch the current bulb state, flip it, and notify the user of the result.
function WizLight:toggleBulb(ip)
    local state, err = Wiz.getPilot(ip)
    if not state then
        logger.warn("wizlight: getPilot failed –", err)
        self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
        return
    end

    local is_on = state.result and state.result.state
    local result, err2
    if is_on then
        result, err2 = Wiz.turnOff(ip)
        if result then self:notify(_("WiZ Light: Off")) end
    else
        result, err2 = Wiz.turnOn(ip)
        if result then self:notify(_("WiZ Light: On")) end
    end

    if not result then
        self:notify(string.format(_("WiZ light unreachable: %s"), err2 or "unknown error"), 4)
    end
end

--- Gesture handler: toggle the bulb and show the new state.
function WizLight:onWizLightToggle()
    self:withIP(function(ip) self:toggleBulb(ip) end)
end

--- Gesture handler: open the quick-access control panel.
function WizLight:onWizLightPanel()
    self:withIP(function(ip) self:showControlPanel(ip) end)
end

--- Full-screen control panel launched by the gesture (no menu navigation needed).
function WizLight:showControlPanel(ip)
    local ButtonDialog = require("ui/widget/buttondialog")

    self._control_panel = ButtonDialog:new{
        title = _("WiZ Light Controls"),
        buttons = {
            {{
                text     = _("Toggle On / Off"),
                callback = function() self:toggleBulb(ip) end,
            }},
            {{
                text     = _("Reading Mode"),
                callback = function()
                    local result, err = Wiz.setPilot(ip, { state = true, temp = 3000, dimming = 70 })
                    if result then
                        self:notify(_("Reading Mode activated"))
                    else
                        self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                    end
                end,
            }},
            {{
                text     = _("Brightness…"),
                callback = function()
                    local saved = G_reader_settings:readSetting("wizlight_brightness") or 70
                    UIManager:show(SpinWidget:new{
                        title_text      = _("Brightness"),
                        value           = saved,
                        value_min       = 10,
                        value_max       = 100,
                        value_step      = 5,
                        value_hold_step = 20,
                        ok_text         = _("Set"),
                        callback = function(spin)
                            G_reader_settings:saveSetting("wizlight_brightness", spin.value)
                            local result, err = Wiz.setBrightness(ip, spin.value)
                            if not result then
                                self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                            end
                        end,
                    })
                end,
            }},
            {{
                text     = _("Color Temperature…"),
                callback = function()
                    local saved = G_reader_settings:readSetting("wizlight_colortemp") or 3000
                    UIManager:show(SpinWidget:new{
                        title_text      = _("Color Temperature (K)"),
                        value           = saved,
                        value_min       = 2200,
                        value_max       = 6500,
                        value_step      = 100,
                        value_hold_step = 500,
                        ok_text         = _("Set"),
                        callback = function(spin)
                            G_reader_settings:saveSetting("wizlight_colortemp", spin.value)
                            local result, err = Wiz.setColorTemp(ip, spin.value)
                            if not result then
                                self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                            end
                        end,
                    })
                end,
            }},
            {{
                text     = _("Scenes…"),
                callback = function() self:showScenesPanel(ip) end,
            }},
            {{
                text     = _("Close"),
                callback = function() UIManager:close(self._control_panel) end,
            }},
        },
    }
    UIManager:show(self._control_panel)
end

--- Scene picker panel, opened from the control panel.
function WizLight:showScenesPanel(ip)
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}
    for _i, scene in ipairs(SCENES) do
        local scene_id   = scene.id
        local scene_name = scene.name
        table.insert(buttons, {{
            text     = scene_name,
            callback = function()
                UIManager:close(self._scenes_panel)
                local ok, result, err = pcall(Wiz.setScene, ip, scene_id)
                if not ok then
                    -- ok=false means a Lua error was thrown; result holds the message
                    logger.warn("wizlight: setScene threw:", result)
                    self:notify(string.format(_("WiZ error: %s"), tostring(result)), 6)
                elseif result then
                    self:notify(string.format(_("Scene: %s"), scene_name))
                else
                    self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                end
            end,
        }})
    end
    table.insert(buttons, {{
        text     = _("Close"),
        callback = function() UIManager:close(self._scenes_panel) end,
    }})

    self._scenes_panel = ButtonDialog:new{
        title   = _("Scenes"),
        buttons = buttons,
    }
    UIManager:show(self._scenes_panel)
end

-- ── menu ─────────────────────────────────────────────────────────────────────

function WizLight:addToMainMenu(menu_items)
    menu_items.wizlight = {
        text         = _("WiZ Light"),
        sorting_hint = "more_tools",
        sub_item_table = self:buildMenu(),
    }
end

function WizLight:buildMenu()
    return {
        self:menuItemPower(),
        self:menuItemReadingMode(),
        self:menuItemBrightness(),
        self:menuItemColorTemp(),
        { text = _("Scenes"), sub_item_table = self:buildScenesMenu() },
        { text = _("Settings"), sub_item_table = self:buildSettingsMenu() },
    }
end

function WizLight:menuItemPower()
    return {
        text_func = function()
            -- Label flips so the action is always clear to the user.
            return _("Toggle On / Off")
        end,
        callback = function()
            self:withIP(function(ip)
                local state, err = Wiz.getPilot(ip)
                if not state then
                    logger.warn("wizlight: getPilot failed –", err)
                    self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                    return
                end
                local is_on = state.result and state.result.state
                if is_on then
                    self:send(Wiz.turnOff, ip)
                else
                    self:send(Wiz.turnOn, ip)
                end
            end)
        end,
    }
end

function WizLight:menuItemReadingMode()
    return {
        text = _("Reading Mode"),
        callback = function()
            self:withIP(function(ip)
                -- Warm 3 000 K at 70 % – comfortable for extended reading.
                local result, err = Wiz.setPilot(ip, { state = true, temp = 3000, dimming = 70 })
                if not result then
                    logger.warn("wizlight: reading mode failed –", err)
                    self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                end
            end)
        end,
    }
end

function WizLight:menuItemBrightness()
    return {
        text = _("Brightness…"),
        callback = function()
            self:withIP(function(ip)
                local saved = G_reader_settings:readSetting("wizlight_brightness") or 70
                UIManager:show(SpinWidget:new{
                    title_text     = _("Brightness"),
                    value          = saved,
                    value_min      = 10,
                    value_max      = 100,
                    value_step     = 5,
                    value_hold_step = 20,
                    ok_text        = _("Set"),
                    callback = function(spin)
                        G_reader_settings:saveSetting("wizlight_brightness", spin.value)
                        local result, err = Wiz.setBrightness(ip, spin.value)
                        if not result then
                            self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                        end
                    end,
                })
            end)
        end,
    }
end

function WizLight:menuItemColorTemp()
    return {
        text = _("Color Temperature…"),
        callback = function()
            self:withIP(function(ip)
                local saved = G_reader_settings:readSetting("wizlight_colortemp") or 3000
                UIManager:show(SpinWidget:new{
                    title_text      = _("Color Temperature (K)"),
                    value           = saved,
                    value_min       = 2200,
                    value_max       = 6500,
                    value_step      = 100,
                    value_hold_step = 500,
                    ok_text         = _("Set"),
                    callback = function(spin)
                        G_reader_settings:saveSetting("wizlight_colortemp", spin.value)
                        local result, err = Wiz.setColorTemp(ip, spin.value)
                        if not result then
                            self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                        end
                    end,
                })
            end)
        end,
    }
end

function WizLight:buildScenesMenu()
    local items = {}
    for _i, scene in ipairs(SCENES) do
        local scene_id = scene.id
        table.insert(items, {
            text = scene.name,
            callback = function()
                self:withIP(function(ip)
                    local ok, result, err = pcall(Wiz.setScene, ip, scene_id)
                    if not ok then
                        logger.warn("wizlight: setScene threw:", result)
                        self:notify(string.format(_("WiZ error: %s"), tostring(result)), 6)
                    elseif not result then
                        self:notify(string.format(_("WiZ light unreachable: %s"), err or "unknown error"), 4)
                    end
                end)
            end,
        })
    end
    return items
end

function WizLight:buildSettingsMenu()
    return {
        {
            text = _("Discover Lights…"),
            callback = function() self:discoverBulbs() end,
        },
        {
            text = _("Set Light IP Address…"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title       = _("WiZ Light IP Address"),
                    input       = self:getIP(),
                    input_hint  = "192.168.1.100",
                    buttons = {{
                        {
                            text     = _("Cancel"),
                            id       = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text             = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local ip = dialog:getInputText()
                                if ip and ip ~= "" then
                                    G_reader_settings:saveSetting("wizlight_ip", ip)
                                    G_reader_settings:flush()
                                    self:notify(_("IP address saved."))
                                end
                                UIManager:close(dialog)
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    }
end

-- ── discovery ─────────────────────────────────────────────────────────────────

--- Format a raw WiZ MAC string (e.g. "a8bb50a4f94d") as "a8:bb:50:a4:f9:4d".
local function formatMAC(mac)
    return (mac:gsub("(..)", "%1:"):sub(1, -2))
end

-- iptables rule inserted around discovery so Kindle's firewall lets responses through.
local IPT_RULE = "INPUT -p udp --dport 38899 -j ACCEPT"

local function iptablesOpen()
    os.execute("iptables -I " .. IPT_RULE .. " 2>/dev/null")
end

local function iptablesClose()
    os.execute("iptables -D " .. IPT_RULE .. " 2>/dev/null")
end

--- Scan the local network for WiZ bulbs (blocks ~5 s; runs inside a Trapper coroutine).
function WizLight:discoverBulbs()
    local Trapper = require("ui/trapper")

    -- Trapper requires a running coroutine; wrap ourselves if needed.
    if not coroutine.running() then
        Trapper:wrap(function() self:discoverBulbs() end)
        return
    end

    iptablesOpen()
    Trapper:info(_("Scanning for WiZ lights…"))
    local bulbs, err = Wiz.discover()
    Trapper:clear()
    iptablesClose()

    if not bulbs then
        self:notify(string.format(_("Discovery failed: %s\nUse 'Set Light IP Address' instead."), err or "unknown error"), 6)
        return
    end

    if #bulbs == 0 then
        self:notify(_("No WiZ lights found on the network."), 4)
        return
    end

    self:showBulbPicker(bulbs)
end

--- Show a dialog listing discovered bulbs; tapping one saves its IP.
function WizLight:showBulbPicker(bulbs)
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}
    for _i, bulb in ipairs(bulbs) do
        local ip = bulb.ip
        local label = string.format("%s   (%s)", ip, formatMAC(bulb.mac))
        table.insert(buttons, {{
            text     = label,
            callback = function()
                UIManager:close(self._bulb_picker)
                G_reader_settings:saveSetting("wizlight_ip", ip)
                G_reader_settings:flush()
                self:notify(string.format(_("Selected: %s"), ip))
            end,
        }})
    end

    table.insert(buttons, {{
        text     = _("Cancel"),
        callback = function() UIManager:close(self._bulb_picker) end,
    }})

    self._bulb_picker = ButtonDialog:new{
        title   = _("Select a WiZ Light"),
        buttons = buttons,
    }
    UIManager:show(self._bulb_picker)
end

return WizLight
