--[[--
KOReader plugin for controlling WiZ smart lights over the local network.

Adds a "WiZ Light" entry to the Tools menu with controls for power,
brightness, colour temperature, reading mode, effect speed, and built-in scenes.
Supports multiple named bulbs with a blink-to-verify discovery wizard.

@module koplugin.wizlight
--]]--

local Dispatcher      = require("dispatcher")  -- luacheck:ignore
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")

local Wiz   = require("wizlight.wiz")
local Bulbs = require("wizlight.bulbs")
local Menu  = require("wizlight.menu")
local UI    = require("wizlight.ui")

-- Curated list of WiZ scenes relevant to reading and relaxation.
--
-- Each scene declares which setPilot overrides actually do something on the
-- bulb, per the official WiZ Pro API reference's per-scene "Adjustable
-- speed"/"Adjustable dimming" compatibility table (docs.pro.wizconnected.com):
--   dimming → brightness override is honoured
--   speed   → animation speed override is honoured (true "dynamic" scenes)
--   temp    → colour-temperature override is honoured; kept only for the
--             plain white-tone scenes, where "pick a different colour
--             temperature" is what the scene name literally means — there's
--             no first-party confirmation it does anything for a
--             mood/function scene like Relax or Bedtime, so those don't
--             claim it.
-- Night Light has neither adjustable dimming nor speed (a fixed low glow by
-- design), so it gets no overrides at all. The original list's "Fireplace"
-- is RGB-only (no TW/DW row in the compatibility table) and can't work on
-- this plugin's dimming+colour-temp-only control surface, so it's replaced
-- with Golden White, which is genuinely dynamic and TW/DW-compatible.
local SCENES = {
    { id = 11, name = _("Warm White"),   dimming = true, temp = true,  speed = false },
    { id = 12, name = _("Daylight"),     dimming = true, temp = true,  speed = false },
    { id = 13, name = _("Cool White"),   dimming = true, temp = true,  speed = false },
    { id = 14, name = _("Night Light"),  dimming = false, temp = false, speed = false },
    { id = 15, name = _("Focus"),        dimming = true, temp = true,  speed = false },
    { id = 16, name = _("Relax"),        dimming = true, temp = false, speed = false },
    { id =  9, name = _("Wake Up"),      dimming = true, temp = false, speed = false },
    { id = 10, name = _("Bedtime"),      dimming = true, temp = false, speed = false },
    { id =  6, name = _("Cozy"),         dimming = true, temp = false, speed = true  },
    { id = 29, name = _("Candlelight"),  dimming = true, temp = false, speed = true  },
    { id = 30, name = _("Golden White"), dimming = true, temp = false, speed = true  },
}

local WizLight = WidgetContainer:extend{
    name        = "wizlight",
    is_doc_only = false,
    SCENES      = SCENES,  -- exposed for menu.lua and ui.lua
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
    Bulbs.load()
    self.ui.menu:registerToMainMenu(self)
end

-- ── helpers ──────────────────────────────────────────────────────────────────

--- Show a short informational toast.
function WizLight:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

--- Return a formatted unreachable-error string.
function WizLight:errMsg(err)
    return string.format(_("WiZ light unreachable: %s"), err or "unknown error")
end

--- Run callback(bulb) only when an active bulb is configured.
function WizLight:withBulb(callback)
    local bulb = Bulbs.getActive()
    if not bulb then
        self:notify(_("No WiZ light configured.\nGo to WiZ Light → Settings → Manage Lights."), 4)
        return
    end
    callback(bulb)
end

--- Call action_fn(ip). On failure, show DHCP dialog if a registry bulb is active,
--- or a plain toast for non-registry errors.
---
--- Design note: any failure for the active registry bulb triggers the DHCP dialog,
--- including transient errors (timeouts, packet loss). This is intentional: in practice
--- the overwhelming majority of "bulb unreachable" events on a home LAN are DHCP changes
--- after a router restart, not transient packet loss. The user can always tap "Dismiss"
--- for a transient failure. Distinguishing DHCP-change from transient error at the
--- protocol level would require retry logic that adds complexity without much benefit
--- for a single-user home-network plugin.
function WizLight:send(action_fn, ip)
    local result, err = action_fn(ip)
    if not result then
        logger.warn("wizlight: command failed –", err)
        local active = Bulbs.getActive()
        if active and active.ip == ip then
            -- Offer re-discovery in case IP changed via DHCP
            UI.showDHCPDialog(self, active.name, active.mac, function()
                -- Retry with fresh IP after re-discovery
                local refreshed = Bulbs.getActive()
                if refreshed then action_fn(refreshed.ip) end
            end)
        else
            self:notify(self:errMsg(err), 4)
        end
    end
    return result
end

--- Fetch the current bulb state, flip it, and notify the user.
-- Routes both calls through send() so a stale IP after a router restart
-- still triggers the DHCP re-discovery dialog, same as every other action
-- (Brightness, Color Temperature, Effect Speed, Scenes).
function WizLight:toggleBulb(ip)
    local state = self:send(Wiz.getPilot, ip)
    if not state then return end

    local is_on = state.result and state.result.state
    if is_on then
        if self:send(Wiz.turnOff, ip) then self:notify(_("WiZ Light: Off")) end
    else
        if self:send(Wiz.turnOn, ip) then self:notify(_("WiZ Light: On")) end
    end
end

-- Warm white 3000K at 70% brightness – comfortable for extended reading.
-- sceneId = 0 is deliberate: WiZ represents "no scene, plain white" as an
-- explicit sceneId of 0, not the absence of the field (confirmed against
-- real getPilot dumps for bulbs in plain CCT mode). Without it, activating
-- Reading Mode while a scene is running can leave the bulb still rendering
-- that scene — some scenes (Night Light among them) don't even report
-- dimming/temp back while active, so there's nothing to visibly change.
local READING_MODE_PARAMS = { state = true, sceneId = 0, temp = 3000, dimming = 70 }

--- Toggle Reading Mode for `bulb`. Activating snapshots the bulb's current
--- state so it can be restored; deactivating restores that snapshot.
function WizLight:toggleReadingMode(bulb)
    local reading = Bulbs.getReadingModeState(bulb.mac)
    if reading.active then
        if self:send(function(ip) return Wiz.setPilot(ip, reading.saved) end, bulb.ip) then
            Bulbs.setReadingModeState(bulb.mac, false, nil)
            self:notify(string.format(_("Reading Mode deactivated (restored: %s)"),
                Wiz.describeParams(reading.saved)), 4)
        end
    else
        local state = self:send(Wiz.getPilot, bulb.ip)
        if not state then return end
        local saved = Wiz.pilotToParams(state.result or {})
        if self:send(function(ip) return Wiz.setPilot(ip, READING_MODE_PARAMS) end, bulb.ip) then
            Bulbs.setReadingModeState(bulb.mac, true, saved)
            self:notify(string.format(_("Reading Mode activated (was: %s)"),
                Wiz.describeParams(saved)), 4)
        end
    end
end

--- Activate `scene` on `bulb`. Clears Reading Mode's active state first —
--- the scene now fully replaces whatever Reading Mode had set, so leaving
--- Reading Mode marked "on" would be stale (its checkmark/label would lie,
--- and toggling it "off" would revert to the wrong thing).
function WizLight:activateScene(bulb, scene)
    if Bulbs.getReadingModeState(bulb.mac).active then
        Bulbs.setReadingModeState(bulb.mac, false, nil)
    end
    local params = Bulbs.buildSceneParams(scene.id)
    if self:send(function(ip) return Wiz.setPilot(ip, params) end, bulb.ip) then
        self:notify(string.format(_("Scene: %s"), scene.name))
    end
end

--- Activate the configured Default Scene, or point the user at how to set
--- one if they haven't yet. Clears Reading Mode's active state first, same
--- reasoning as activateScene() — Default Scene fully replaces whatever
--- was showing.
function WizLight:activateDefaultScene(bulb)
    local saved = Bulbs.getDefaultScene()
    if not saved then
        self:notify(_([[No default scene set yet.
Hold "Default Scene" to save your current light settings as the default.]]), 5)
        return
    end
    if Bulbs.getReadingModeState(bulb.mac).active then
        Bulbs.setReadingModeState(bulb.mac, false, nil)
    end
    -- Self-healing: a default saved before the sceneId=0 fix (or one
    -- captured while getPilot happened not to report sceneId at all) may
    -- have no sceneId of its own. Default Scene means "plain white, no
    -- scene" unless it was explicitly captured while a scene was showing
    -- (in which case saved.sceneId is already that scene's real id), so
    -- default the outgoing copy to 0 without touching the stored value.
    local params = {}
    for k, v in pairs(saved) do params[k] = v end
    if params.sceneId == nil then params.sceneId = 0 end
    if self:send(function(ip) return Wiz.setPilot(ip, params) end, bulb.ip) then
        self:notify(string.format(_("Default scene activated: %s"), Wiz.describeParams(params)), 4)
    end
end

--- Snapshot the bulb's current live state and save it as the Default Scene.
function WizLight:saveDefaultScene(bulb)
    local state = self:send(Wiz.getPilot, bulb.ip)
    if not state then return end
    local params = Wiz.pilotToParams(state.result or {})
    Bulbs.setDefaultScene(params)
    self:notify(string.format(_("Default scene saved: %s"), Wiz.describeParams(params)), 4)
end

-- ── gesture actions ──────────────────────────────────────────────────────────

function WizLight:onWizLightToggle()
    self:withBulb(function(bulb) self:toggleBulb(bulb.ip) end)
end

function WizLight:onWizLightPanel()
    self:withBulb(function(bulb) UI.showControlPanel(self, bulb) end)
end

-- ── menu ─────────────────────────────────────────────────────────────────────

function WizLight:addToMainMenu(menu_items)
    menu_items.wizlight = {
        text         = _("WiZ Light"),
        sorting_hint = "more_tools",
        sub_item_table = Menu.buildMenu(self),
    }
end

return WizLight
