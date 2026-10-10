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

local Wiz      = require("wizlight.wiz")
local Bulbs    = require("wizlight.bulbs")
local Menu     = require("wizlight.menu")
local UI       = require("wizlight.ui")
local Firewall = require("wizlight.firewall")

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

--- Take the firewall rules back down on the way out. The rules are opened
--- lazily on first contact with a bulb rather than here, so a KOReader
--- session that never touches the plugin never touches iptables either.
--- Both hooks are wired because whichever fires first wins and the second
--- is a no-op; if neither does (a crash), the rules don't survive a reboot.
function WizLight:onCloseWidget()
    Firewall.close()
    Bulbs.close()
end

function WizLight:onExit()
    Firewall.close()
    Bulbs.close()
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
--- Design note: a *silent* failure for the active registry bulb triggers the DHCP
--- dialog, including transient errors (timeouts, packet loss). This is intentional: in
--- practice the overwhelming majority of "bulb unreachable" events on a home LAN are DHCP
--- changes after a router restart, not transient packet loss. The user can always tap
--- "Dismiss" for a transient failure. Distinguishing DHCP-change from transient error at
--- the protocol level would require retry logic that adds complexity without much benefit
--- for a single-user home-network plugin.
---
--- A bulb that *answered* and refused the command is a different story: it's plainly
--- reachable, so offering to hunt for a new IP would be nonsense. Those get the error
--- text instead, which is also what makes a refusal legible while debugging.
---
--- `retry` is what to run once re-discovery has found the bulb again. Multi-step
--- actions must pass it: by default only `action_fn` is repeated, and for
--- something like toggleBulb() that's the getPilot that failed, not the
--- setPilot the user actually asked for.
function WizLight:send(action_fn, ip, retry)
    local result, err, code = action_fn(ip)
    if not result then
        logger.warn("wizlight: command failed –", err)
        local active = Bulbs.getActive()
        if Wiz.isRefusal(code) then
            -- Not "unreachable": it answered. Show what it actually said.
            self:notify(string.format(_("WiZ light: %s"), err or "unknown error"), 5)
        elseif active and active.ip == ip then
            -- Offer re-discovery in case IP changed via DHCP
            UI.showDHCPDialog(self, active.name, active.mac, retry or function()
                -- Retry with fresh IP after re-discovery
                local refreshed = Bulbs.getActive()
                if refreshed then self:send(action_fn, refreshed.ip) end
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
    local state = self:send(Wiz.getPilot, ip, function()
        local refreshed = Bulbs.getActive()
        if refreshed then self:toggleBulb(refreshed.ip) end
    end)
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
    local retry = function() self:toggleReadingMode(bulb) end
    local reading = Bulbs.getReadingModeState(bulb.mac)
    if reading.active then
        -- An empty snapshot means the capture never got a usable answer
        -- from the bulb. setPilot({}) would be accepted and change
        -- nothing, so say so rather than reporting a restore that didn't
        -- happen; clear the flag either way so it can't get stuck on.
        if not next(reading.saved or {}) then
            Bulbs.setReadingModeState(bulb.mac, false, nil)
            self:notify(_("Reading Mode off (no previous state to restore)"), 4)
            return
        end
        -- Re-normalise: snapshots stored by older versions copied every
        -- getPilot key, scene and colour temperature together.
        local restore = Wiz.pilotToParams(reading.saved)
        if self:send(function(ip) return Wiz.setPilot(ip, restore) end, bulb.ip, retry) then
            Bulbs.setReadingModeState(bulb.mac, false, nil)
            self:notify(string.format(_("Reading Mode deactivated (restored: %s)"),
                Wiz.describeParams(restore)), 4)
        end
    else
        local state = self:send(Wiz.getPilot, bulb.ip, retry)
        if not state then return end
        local saved = Wiz.pilotToParams(state.result or {})
        if self:send(function(ip) return Wiz.setPilot(ip, READING_MODE_PARAMS) end, bulb.ip, retry) then
            Bulbs.setReadingModeState(bulb.mac, true, saved)
            self:notify(string.format(_("Reading Mode activated (was: %s)"),
                Wiz.describeParams(saved)), 4)
        end
    end
end

--- Reading Mode is marked "on" until something else fully replaces what it
--- set; after that its checkmark/label would lie, and toggling it "off"
--- would revert to the wrong thing. Only called once the replacement has
--- actually landed — a command that never reached the bulb changed
--- nothing, so Reading Mode is still what's showing.
local function clearReadingMode(bulb)
    if Bulbs.getReadingModeState(bulb.mac).active then
        Bulbs.setReadingModeState(bulb.mac, false, nil)
    end
end

--- Activate `scene` on `bulb`.
function WizLight:activateScene(bulb, scene)
    local params = Bulbs.buildSceneParams(scene.id)
    if self:send(function(ip) return Wiz.setPilot(ip, params) end, bulb.ip,
            function() self:activateScene(bulb, scene) end) then
        clearReadingMode(bulb)
        self:notify(string.format(_("Scene: %s"), scene.name))
    end
end

--- Activate the configured Default Scene, or point the user at how to set
--- one if they haven't yet.
function WizLight:activateDefaultScene(bulb)
    local saved = Bulbs.getDefaultScene()
    if not saved then
        self:notify(_([[No default scene set yet.
Hold "Default Scene" to save your current light settings as the default.]]), 5)
        return
    end
    -- Self-healing for defaults saved by older versions, without touching
    -- the stored value: those copied every getPilot key, so a default
    -- captured during a scene asks for the scene *and* a colour
    -- temperature, and one captured with the bulb off would switch it off.
    -- pilotToParams keeps one coherent mode (and adds sceneId=0 to plain
    -- white, which very old saves lacked).
    local params = Wiz.pilotToParams(saved)
    params.state = true
    if self:send(function(ip) return Wiz.setPilot(ip, params) end, bulb.ip,
            function() self:activateDefaultScene(bulb) end) then
        clearReadingMode(bulb)
        self:notify(string.format(_("Default scene activated: %s"), Wiz.describeParams(params)), 4)
    end
end

--- Query the bulb's live state and return one field from it, or nil if
--- unreachable or the field isn't present (e.g. a scene without that
--- override, like Night Light's missing dimming/temp). Used to pre-fill
--- the Brightness/Color Temperature dials with the bulb's true current
--- value instead of the last value locally *requested* — those can
--- silently diverge, since some WiZ bulbs clamp a requested color
--- temperature to their own hardware minimum without any error.
function WizLight:queryLiveField(bulb, field)
    local state = self:send(Wiz.getPilot, bulb.ip)
    return state and state.result and state.result[field]
end

--- Snapshot the bulb's current live state and save it as the Default Scene.
function WizLight:saveDefaultScene(bulb)
    local state = self:send(Wiz.getPilot, bulb.ip, function() self:saveDefaultScene(bulb) end)
    if not state then return end
    local params = Wiz.pilotToParams(state.result or {})
    -- Activating a default means "light the room like this". Saving the
    -- bulb's off state would make the button switch the light off instead.
    params.state = true
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
