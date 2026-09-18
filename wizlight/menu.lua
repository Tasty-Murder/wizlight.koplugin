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
            plugin:withBulb(function(bulb) plugin:toggleBulb(bulb.ip) end)
        end,
    }
end

local function menuItemDefaultScene(plugin)
    return {
        text     = _("Default Scene"),
        callback = function()
            plugin:withBulb(function(bulb) plugin:activateDefaultScene(bulb) end)
        end,
        hold_callback = function()
            plugin:withBulb(function(bulb) plugin:saveDefaultScene(bulb) end)
        end,
    }
end

local function menuItemReadingMode(plugin)
    return {
        text_func = function()
            local active = Bulbs.getActive()
            local on = active and Bulbs.getReadingModeState(active.mac).active
            return on and _("Reading Mode - On") or _("Reading Mode - Off")
        end,
        checked_func = function()
            local active = Bulbs.getActive()
            return active and Bulbs.getReadingModeState(active.mac).active or false
        end,
        callback = function()
            plugin:withBulb(function(bulb) plugin:toggleReadingMode(bulb) end)
        end,
    }
end

local function menuItemBrightness(plugin)
    return {
        text     = _("Brightness…"),
        callback = function()
            plugin:withBulb(function(bulb)
                local saved = plugin:queryLiveField(bulb, "dimming")
                    or G_reader_settings:readSetting("wizlight_brightness") or 70
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
                local saved = plugin:queryLiveField(bulb, "temp")
                    or G_reader_settings:readSetting("wizlight_colortemp") or 3000
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

local function sceneMenuItem(plugin, scene)
    return {
        text     = scene.name,
        callback = function()
            plugin:withBulb(function(bulb) plugin:activateScene(bulb, scene) end)
        end,
    }
end

--- Split plugin.SCENES into { Lighting Themes, Animated Scenes } menu items,
-- grouped by whether the scene's animation-speed override actually does
-- anything on the bulb (see the SCENES table comment in main.lua).
local function buildScenesMenu(plugin)
    local lighting_themes, animated = {}, {}
    for _i, scene in ipairs(plugin.SCENES) do
        table.insert(scene.speed and animated or lighting_themes, sceneMenuItem(plugin, scene))
    end
    return {
        { text = _("Lighting Themes"), sub_item_table = lighting_themes },
        { text = _("Animated Scenes"), sub_item_table = animated },
    }
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

local function menuItemDefaultSceneSetting(plugin)
    return {
        text_func = function()
            local current = Bulbs.getDefaultScene()
            if current then
                return string.format(_("Default Scene… (%s)"), Wiz.describeParams(current))
            end
            return _("Default Scene… (not set)")
        end,
        callback = function() UI.showDefaultSceneSetting(plugin) end,
    }
end

local function buildSettingsMenu(plugin)
    return {
        {
            text     = _("Manage Lights…"),
            callback = function() UI.showBulbManager(plugin) end,
        },
        menuItemDiscoveryTimeout(),
        menuItemDefaultSceneSetting(plugin),
    }
end

--- Build the full WiZ Light menu subtree.
function Menu.buildMenu(plugin)
    return {
        menuItemPower(plugin),
        menuItemDefaultScene(plugin),
        menuItemReadingMode(plugin),
        menuItemBrightness(plugin),
        menuItemColorTemp(plugin),
        menuItemEffectSpeed(plugin),
        { text = _("Scenes"),   sub_item_table = buildScenesMenu(plugin) },
        { text = _("Settings"), sub_item_table = buildSettingsMenu(plugin) },
    }
end

return Menu
