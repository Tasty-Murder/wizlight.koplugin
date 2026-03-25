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
-- kind = "static"  → brightness + color temperature are editable
-- kind = "dynamic" → brightness + animation speed are editable
local SCENES = {
    { id = 11, name = _("Warm White"),  kind = "static"  },
    { id = 12, name = _("Daylight"),    kind = "static"  },
    { id = 13, name = _("Cool White"),  kind = "static"  },
    { id = 14, name = _("Night Light"), kind = "static"  },
    { id = 15, name = _("Focus"),       kind = "static"  },
    { id =  6, name = _("Cozy"),        kind = "dynamic" },
    { id = 16, name = _("Relax"),       kind = "dynamic" },
    { id = 29, name = _("Candlelight"), kind = "dynamic" },
    { id =  5, name = _("Fireplace"),   kind = "dynamic" },
    { id =  9, name = _("Wake Up"),     kind = "dynamic" },
    { id = 10, name = _("Bedtime"),     kind = "dynamic" },
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
function WizLight:toggleBulb(ip)
    local state, err = Wiz.getPilot(ip)
    if not state then
        logger.warn("wizlight: getPilot failed –", err)
        self:notify(self:errMsg(err), 4)
        return
    end

    local is_on = state.result and state.result.state
    if is_on then
        local result, err2 = Wiz.turnOff(ip)
        if result then self:notify(_("WiZ Light: Off")) else self:notify(self:errMsg(err2), 4) end
    else
        local result, err2 = Wiz.turnOn(ip)
        if result then self:notify(_("WiZ Light: On")) else self:notify(self:errMsg(err2), 4) end
    end
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
