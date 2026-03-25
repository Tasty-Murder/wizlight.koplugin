--[[--
Bulb registry for wizlight.koplugin.

Stores named WiZ bulbs and per-scene parameter overrides,
persisted in a LuaSettings file at DataStorage:getSettingsDir()/wizlight.lua.

@module koplugin.wizlight.bulbs
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/wizlight.lua"

local Bulbs = {}
local _s = nil  -- LuaSettings handle, lazily opened

local function s()
    if not _s then
        _s = LuaSettings:open(SETTINGS_PATH)
    end
    return _s
end

--- Open or create the settings file. Call once at plugin init.
function Bulbs.load()
    local settings = s()
    if not settings:readSetting("bulbs") then
        settings:saveSetting("bulbs", {})
        settings:saveSetting("order", {})
        settings:flush()
    end
end

--- Write current state to disk.
function Bulbs.flush()
    s():flush()
end

--- Return all bulbs in insertion order as an array of {name, ip, mac}.
function Bulbs.getAll()
    local order = s():readSetting("order") or {}
    local bulbs = s():readSetting("bulbs") or {}
    local result = {}
    for _i, mac in ipairs(order) do
        if bulbs[mac] then
            table.insert(result, bulbs[mac])
        end
    end
    return result
end

--- Return the active bulb as {name, ip, mac}, or nil if none configured.
function Bulbs.getActive()
    local mac = s():readSetting("active")
    if not mac then return nil end
    local bulbs = s():readSetting("bulbs") or {}
    return bulbs[mac]
end

--- Set the active bulb by MAC address.
function Bulbs.setActive(mac)
    s():saveSetting("active", mac):flush()
end

--- Add or update a bulb entry. Sets it as active if it is the first bulb.
function Bulbs.add(name, ip, mac)
    local settings = s()
    local bulbs = settings:readSetting("bulbs") or {}
    local order = settings:readSetting("order") or {}

    -- Append to order only if this is a new MAC
    if not bulbs[mac] then
        table.insert(order, mac)
        settings:saveSetting("order", order)
    end

    bulbs[mac] = { name = name, ip = ip, mac = mac }
    settings:saveSetting("bulbs", bulbs)

    -- Auto-select first bulb added
    if not settings:readSetting("active") then
        settings:saveSetting("active", mac)
    end

    settings:flush()
end

--- Remove a bulb by MAC. Promotes next bulb as active (or clears active) if needed.
function Bulbs.remove(mac)
    local settings = s()
    local bulbs = settings:readSetting("bulbs") or {}
    local order = settings:readSetting("order") or {}

    bulbs[mac] = nil
    settings:saveSetting("bulbs", bulbs)

    local new_order = {}
    for _i, m in ipairs(order) do
        if m ~= mac then
            table.insert(new_order, m)
        end
    end
    settings:saveSetting("order", new_order)

    if settings:readSetting("active") == mac then
        -- Promote first remaining bulb, or clear if none left
        settings:saveSetting("active", new_order[1])
    end

    settings:flush()
end

--- Update the stored IP for a known MAC (called after DHCP re-discovery).
function Bulbs.updateIP(mac, ip)
    local settings = s()
    local bulbs = settings:readSetting("bulbs") or {}
    if bulbs[mac] then
        bulbs[mac].ip = ip
        settings:saveSetting("bulbs", bulbs):flush()
    end
end

--- Return stored override params for a scene, or {} if none saved.
function Bulbs.getSceneOverride(scene_id)
    local overrides = s():readSetting("scene_overrides") or {}
    return overrides[scene_id] or {}
end

--- Save override params for a scene (replaces any existing override).
function Bulbs.setSceneOverride(scene_id, params)
    local settings = s()
    local overrides = settings:readSetting("scene_overrides") or {}
    overrides[scene_id] = params
    settings:saveSetting("scene_overrides", overrides):flush()
end

--- Remove all stored overrides for a scene.
function Bulbs.clearSceneOverride(scene_id)
    local settings = s()
    local overrides = settings:readSetting("scene_overrides") or {}
    overrides[scene_id] = nil
    settings:saveSetting("scene_overrides", overrides):flush()
end

return Bulbs
