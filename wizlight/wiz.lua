--[[--
Low-level WiZ light UDP protocol implementation.

WiZ bulbs communicate over UDP port 38899 using JSON-encoded messages.
All public functions return `(result_table, nil)` on success or
`(nil, error_string)` on failure.

@module koplugin.wizlight.wiz
--]]--

local rapidjson = require("rapidjson")
local logger    = require("logger")
local socket    = require("socket")

local WIZ_PORT = 38899
local TIMEOUT  = 3  -- seconds

local Wiz = {}

--- Send a raw JSON string to a bulb and return the parsed response.
local function sendUDP(ip, message)
    local udp = socket.udp()
    udp:settimeout(TIMEOUT)

    local ok, err = udp:sendto(message, ip, WIZ_PORT)
    if not ok then
        udp:close()
        return nil, err
    end

    local data = udp:receive()
    udp:close()

    if not data then
        return nil, "timeout – bulb did not respond"
    end

    local decoded, decode_err = rapidjson.decode(data)
    if not decoded then
        return nil, "invalid JSON from bulb: " .. (decode_err or "?")
    end

    return decoded
end

--- Determine this device's local IP via KOReader's NetworkMgr + UDP routing
--- trick (connect a UDP socket to a public address and read back the local
--- address the kernel picked for the route, without sending any packet).
local function resolveLocalIP()
    local local_ip = "1.2.3.4"
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:getNetworkInterfaceName() then
        local probe = socket.udp()
        if probe then
            if probe:setpeername("203.0.113.1", 53) then
                local addr = probe:getsockname()
                if addr and addr ~= "0.0.0.0" and addr ~= "*" then
                    local_ip = addr
                end
            end
            probe:close()
        end
    end
    return local_ip
end

--- Build the UDP "registration" message bulbs treat as a discovery probe.
--- `register = false` tells the bulb to remove any prior registration for
--- this phoneIp/phoneMac rather than actually pairing — the IP/MAC given
--- don't need to be real for that reason.
local function buildRegistrationMessage(local_ip)
    return rapidjson.encode({
        method = "registration",
        params = { phoneMac = "AAAAAAAAAAAA", register = false,
                   phoneIp = local_ip, id = "1" },
    })
end

--- Send a `getPilot` request and return the bulb state table.
function Wiz.getPilot(ip)
    local msg = rapidjson.encode({
        method = "getPilot",
        params = rapidjson.object({}),
    })
    return sendUDP(ip, msg)
end

--- Send a `setPilot` request with the given params table.
function Wiz.setPilot(ip, params)
    local msg = rapidjson.encode({
        method = "setPilot",
        params = params,
    })
    return sendUDP(ip, msg)
end

--- Turn the bulb on (preserving its last colour/scene).
function Wiz.turnOn(ip)
    return Wiz.setPilot(ip, { state = true })
end

--- Turn the bulb off.
function Wiz.turnOff(ip)
    return Wiz.setPilot(ip, { state = false })
end

--- Set brightness.  `dimming` is an integer in the range 10–100.
function Wiz.setBrightness(ip, dimming)
    return Wiz.setPilot(ip, { state = true, dimming = dimming })
end

--- Set white colour temperature.  `temp` is in Kelvin (2200–6500).
function Wiz.setColorTemp(ip, temp)
    return Wiz.setPilot(ip, { state = true, temp = temp })
end

--- Set the animation speed for dynamic scenes. speed is an integer 10–200.
-- Design note: unlike the other setters, this deliberately does NOT send
-- `state = true` alongside `speed`. The WiZ firmware ignores a speed change
-- bundled in the same setPilot call as `state` (this matches pywizlight's
-- own set_speed(), which carries the same warning) — the typical use of
-- this call is nudging the speed of a scene that's already running, where
-- `state` isn't needed anyway.
function Wiz.setSpeed(ip, speed)
    return Wiz.setPilot(ip, { speed = speed })
end

-- Keys from a getPilot `.result` table that are valid to pass straight back
-- into a setPilot call.
local PILOT_PARAM_KEYS = {
    "state", "sceneId", "temp", "dimming", "speed", "r", "g", "b", "c", "w",
}

--- Convert a decoded getPilot `.result` table into a setPilot-safe params
--- table, passing through only the known controllable keys that are
--- present. Used to snapshot a bulb's current state so it can be restored
--- later (Reading Mode revert, Default Scene "save current").
function Wiz.pilotToParams(result)
    local params = {}
    for _, key in ipairs(PILOT_PARAM_KEYS) do
        if result[key] ~= nil then
            params[key] = result[key]
        end
    end
    return params
end

--- Broadcast a registration message and collect all responding WiZ bulbs.
-- Runs for `timeout` seconds (default 10) and returns an array of
-- `{ ip = "...", mac = "..." }` tables.  The caller is responsible for
-- opening the firewall before calling this (see UI.showDiscoveryWizard).
function Wiz.discover(timeout)
    timeout = timeout or 10

    local local_ip = resolveLocalIP()
    logger.info("wizlight discover: local_ip =", local_ip)

    local broadcast_ip = "255.255.255.255"
    local prefix = local_ip:match("^(%d+%.%d+%.%d+)%.")
    if prefix then broadcast_ip = prefix .. ".255" end
    logger.info("wizlight discover: broadcast_ip =", broadcast_ip)

    local msg = buildRegistrationMessage(local_ip)

    local udp = socket.udp()
    -- WiZ bulbs reply to phoneIp:38899 (not the sender's ephemeral port).
    -- Bind to WIZ_PORT so those unicast replies reach this socket.
    -- reuseaddr allows re-running discovery in quick succession.
    udp:setoption("reuseaddr", true)
    local bind_ok, bind_err = udp:setsockname("*", WIZ_PORT)
    if not bind_ok then
        udp:close()
        logger.warn("wizlight discover: bind failed:", bind_err)
        return nil, "could not bind UDP port " .. WIZ_PORT .. ": " .. (bind_err or "?")
    end
    local bcast_ok, bcast_err = udp:setoption("broadcast", true)
    if not bcast_ok then
        udp:close()
        return nil, "broadcast not supported: " .. (bcast_err or "?")
    end
    udp:settimeout(1)

    local sent, send_err = udp:sendto(msg, broadcast_ip, WIZ_PORT)
    if not sent then
        udp:close()
        logger.warn("wizlight discover: sendto failed:", send_err)
        return nil, send_err
    end
    logger.info("wizlight discover: broadcast sent to", broadcast_ip)

    local bulbs    = {}
    local seen     = {}
    local deadline = socket.gettime() + timeout
    -- Re-send the broadcast every second for the whole window: a single
    -- broadcast frame is easy to lose on Wi-Fi, and bulbs that miss it
    -- would otherwise sit out the entire scan.
    local next_broadcast = socket.gettime() + 1

    while socket.gettime() < deadline do
        local data, src_ip = udp:receivefrom()
        if data then
            logger.info("wizlight discover: received", #data, "bytes from", src_ip, ":", data)
            local decoded, dec_err = rapidjson.decode(data)
            if decoded then
                local result = decoded.result or decoded.r
                local mac = result and result.mac
                if mac and not seen[mac] then
                    seen[mac] = true
                    logger.info("wizlight discover: found bulb mac=" .. mac .. " ip=" .. src_ip)
                    table.insert(bulbs, { ip = src_ip, mac = mac })
                end
            else
                logger.warn("wizlight discover: JSON decode failed:", dec_err)
            end
        end

        local now = socket.gettime()
        if now >= next_broadcast then
            udp:sendto(msg, broadcast_ip, WIZ_PORT)
            next_broadcast = now + 1
        end
    end

    udp:close()
    return bulbs
end

--- Send a unicast registration message to a single IP and return its identity.
-- Useful for adding a bulb by known IP when broadcast discovery is not desired.
-- The caller is responsible for opening the firewall before calling this.
-- Returns `{ ip = ip, mac = "..." }` on success or `(nil, error_string)` on failure.
function Wiz.probe(ip, timeout)
    timeout = timeout or 10

    local local_ip = resolveLocalIP()
    local msg = buildRegistrationMessage(local_ip)

    local udp = socket.udp()
    udp:setoption("reuseaddr", true)
    local bind_ok, bind_err = udp:setsockname("*", WIZ_PORT)
    if not bind_ok then
        udp:close()
        logger.warn("wizlight probe: bind failed:", bind_err)
        return nil, "could not bind UDP port " .. WIZ_PORT .. ": " .. (bind_err or "?")
    end
    udp:settimeout(1)

    local sent, send_err = udp:sendto(msg, ip, WIZ_PORT)
    if not sent then
        udp:close()
        logger.warn("wizlight probe: sendto failed:", send_err)
        return nil, send_err
    end
    logger.info("wizlight probe: sent registration to", ip)

    local deadline = socket.gettime() + timeout
    while socket.gettime() < deadline do
        local data, src_ip = udp:receivefrom()
        if data then
            logger.info("wizlight probe: received", #data, "bytes from", src_ip)
            local decoded, dec_err = rapidjson.decode(data)
            if decoded then
                local result = decoded.result or decoded.r
                local mac = result and result.mac
                if mac then
                    udp:close()
                    return { ip = src_ip, mac = mac }
                end
            else
                logger.warn("wizlight probe: JSON decode failed:", dec_err)
            end
        end
    end

    udp:close()
    return nil, "timeout – bulb did not respond"
end

--- Blink the bulb off then on so the user can identify it physically.
-- Short-circuits and returns (nil, err) if turnOff fails.
function Wiz.blink(ip)
    local ok, err = Wiz.turnOff(ip)
    if not ok then return nil, err end
    socket.sleep(0.6)
    return Wiz.turnOn(ip)
end

return Wiz
