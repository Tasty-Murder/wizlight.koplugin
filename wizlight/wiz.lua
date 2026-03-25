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

--- Activate one of the 35 built-in WiZ scenes by ID.
function Wiz.setScene(ip, scene_id)
    return Wiz.setPilot(ip, { state = true, sceneId = scene_id })
end

--- Broadcast a registration message and collect all responding WiZ bulbs.
-- Runs for `timeout` seconds (default 5) and returns an array of
-- `{ ip = "...", mac = "..." }` tables.  The caller is responsible for
-- opening the firewall before calling this (see WizLight:discoverBulbs).
function Wiz.discover(timeout)
    timeout = timeout or 5

    -- Determine the local IP via KOReader's NetworkMgr + UDP routing trick.
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
    logger.info("wizlight discover: local_ip =", local_ip)

    local broadcast_ip = "255.255.255.255"
    local prefix = local_ip:match("^(%d+%.%d+%.%d+)%.")
    if prefix then broadcast_ip = prefix .. ".255" end
    logger.info("wizlight discover: broadcast_ip =", broadcast_ip)

    local msg = rapidjson.encode({
        method = "registration",
        params = { phoneMac = "AAAAAAAAAAAA", register = false,
                   phoneIp = local_ip, id = "1" },
    })

    local udp = socket.udp()
    -- WiZ bulbs reply to phoneIp:38899 (not the sender's ephemeral port).
    -- Bind to WIZ_PORT so those unicast replies reach this socket.
    -- reuseaddr allows re-running discovery in quick succession.
    udp:setoption("reuseaddr", true)
    udp:setsockname("*", WIZ_PORT)
    local ok, err = udp:setoption("broadcast", true)
    if not ok then
        udp:close()
        return nil, "broadcast not supported: " .. (err or "?")
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
    end

    udp:close()
    return bulbs
end

--- Blink the bulb off then on so the user can identify it physically.
-- Short-circuits and returns (nil, err) if turnOff fails.
function Wiz.blink(ip)
    local ok, err = Wiz.turnOff(ip)
    if not ok then return nil, err end
    socket.sleep(0.6)
    return Wiz.turnOn(ip)
end

--- Set the animation speed for dynamic scenes. speed is an integer 10–200.
function Wiz.setSpeed(ip, speed)
    return Wiz.setPilot(ip, { state = true, speed = speed })
end

return Wiz
