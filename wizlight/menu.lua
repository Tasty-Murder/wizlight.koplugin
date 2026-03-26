--[[--
Menu builders for wizlight.koplugin.

All functions return menu item tables compatible with KOReader's menu system.
Call buildMenu(plugin) from WizLight:addToMainMenu.

@module koplugin.wizlight.menu
--]]--

local SpinWidget = require("ui/widget/spinwidget")
local UIManager  = require("ui/uimanager")
local _          = require("gettext")

local Wiz   = require("wizlight.wiz")
local Bulbs = require("wizlight.bulbs")
local UI    = require("wizlight.ui")

local Menu = {}

local function menuItemPower(plugin)
    return {
        text     = _("Toggle On / Off"),
        callback = function()
            plugin:withBulb(function(bulb)
                local state, err = Wiz.getPilot(bulb.ip)
                if not state then
                    plugin:notify(plugin:errMsg(err), 4)
                    return
                end
                local is_on = state.result and state.result.state
                if is_on then
                    plugin:send(Wiz.turnOff, bulb.ip)
                else
                    plugin:send(Wiz.turnOn, bulb.ip)
                end
            end)
        end,
    }
end

local function menuItemReadingMode(plugin)
    return {
        text     = _("Reading Mode"),
        callback = function()
            plugin:withBulb(function(bulb)
                -- Warm 3 000 K at 70 % – comfortable for extended reading.
                local result, err = Wiz.setPilot(bulb.ip, { state = true, temp = 3000, dimming = 70 })
                if not result then
                    plugin:notify(plugin:errMsg(err), 4)
                end
            end)
        end,
    }
end

local function menuItemBrightness(plugin)
    return {
        text     = _("Brightness…"),
        callback = function()
            plugin:withBulb(function(bulb)
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
                        plugin:send(
                            function(ip) return Wiz.setBrightness(ip, spin.value) end,
                            bulb.ip)
                    end,
                })
            end)
        end,
    }
end

local function menuItemColorTemp(plugin)
    return {
        text     = _("Color Temperature…"),
        callback = function()
            plugin:withBulb(function(bulb)
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
                        plugin:send(
                            function(ip) return Wiz.setColorTemp(ip, spin.value) end,
                            bulb.ip)
                    end,
                })
            end)
        end,
    }
end

local function menuItemEffectSpeed(plugin)
    return {
        text     = _("Effect Speed…"),
        callback = function()
            plugin:withBulb(function(bulb)
                local saved = G_reader_settings:readSetting("wizlight_speed") or 100
                UIManager:show(SpinWidget:new{
                    title_text      = _("Effect Speed"),
                    value           = saved,
                    value_min       = 10,
                    value_max       = 200,
                    value_step      = 10,
                    value_hold_step = 50,
                    ok_text         = _("Set"),
                    callback = function(spin)
                        G_reader_settings:saveSetting("wizlight_speed", spin.value)
                        plugin:send(
                            function(ip) return Wiz.setSpeed(ip, spin.value) end,
                            bulb.ip)
                    end,
                })
            end)
        end,
    }
end

local function buildScenesMenu(plugin)
    local items = {}
    for _i, scene in ipairs(plugin.SCENES) do
        local s = scene
        table.insert(items, {
            text     = scene.name,
            callback = function()
                plugin:withBulb(function(bulb)
                    local params      = Bulbs.buildSceneParams(s.id)
                    local result, err = Wiz.setPilot(bulb.ip, params)
                    if not result then
                        plugin:notify(plugin:errMsg(err), 4)
                    end
                end)
            end,
        })
    end
    return items
end

local function menuItemDiscoveryTimeout()
    return {
        text     = _("Discovery Timeout…"),
        callback = function()
            local saved = G_reader_settings:readSetting("wizlight_discovery_timeout") or 10
            UIManager:show(SpinWidget:new{
                title_text      = _("Discovery Timeout (seconds)"),
                value           = saved,
                value_min       = 3,
                value_max       = 30,
                value_step      = 1,
                value_hold_step = 5,
                ok_text         = _("Set"),
                callback        = function(spin)
                    G_reader_settings:saveSetting("wizlight_discovery_timeout", spin.value)
                end,
            })
        end,
    }
end

local function buildSettingsMenu(plugin)
    return {
        {
            text     = _("Manage Lights…"),
            callback = function() UI.showBulbManager(plugin) end,
        },
        menuItemDiscoveryTimeout(),
    }
end

--- Build the full WiZ Light menu subtree.
function Menu.buildMenu(plugin)
    return {
        menuItemPower(plugin),
        menuItemReadingMode(plugin),
        menuItemBrightness(plugin),
        menuItemColorTemp(plugin),
        menuItemEffectSpeed(plugin),
        { text = _("Scenes"),   sub_item_table = buildScenesMenu(plugin) },
        { text = _("Settings"), sub_item_table = buildSettingsMenu(plugin) },
    }
end

return Menu
