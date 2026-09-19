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
local TIMEOUT  = 3    -- total seconds to wait for a reply, across retries
local POLL     = 0.25 -- how long each individual receive blocks for
local RESEND   = 0.5  -- resend the datagram this often while waiting

-- Error codes the bulb reports JSON-RPC style.
local ERR_INVALID_PARAMS = -32602

local Wiz = {}

--- Send a raw JSON string to a bulb and return the parsed response.
-- Returns (decoded, nil) on success, or (nil, message, code) on failure,
-- where `code` is the bulb's error code when it actively rejected the
-- command rather than staying silent.
--
-- `expect_method` is the method name the reply must carry. A bulb that has
-- been registered (which discovery does) pushes unsolicited `syncPilot`
-- heartbeats to this port; those parse perfectly well but carry `params`
-- instead of `result`, so treating one as our answer silently yields an
-- empty state. Anything that isn't the reply we asked for is skipped.
local function sendUDP(ip, message, expect_method)
    local udp = socket.udp()
    udp:settimeout(POLL)

    local ok, send_err = udp:sendto(message, ip, WIZ_PORT)
    if not ok then
        udp:close()
        return nil, send_err
    end

    local last_err  = "timeout – bulb did not respond"
    local deadline  = socket.gettime() + TIMEOUT
    local next_send = socket.gettime() + RESEND

    while socket.gettime() < deadline do
        local data = udp:receive()
        if data then
            local decoded, decode_err = rapidjson.decode(data)
            if not decoded then
                last_err = "invalid JSON from bulb: " .. (decode_err or "?")
            elseif decoded.error then
                -- An outright rejection. Reporting this as success is what
                -- made failed commands look like they had worked.
                local err = decoded.error
                udp:close()
                logger.warn("wizlight: bulb rejected command:", err.message, err.code)
                return nil,
                    string.format("bulb rejected the command: %s (code %s)",
                        tostring(err.message), tostring(err.code)),
                    err.code
            elseif decoded.method == expect_method then
                udp:close()
                return decoded
            end
            -- Otherwise it's a heartbeat or a stray reply: keep waiting.
        end

        -- Retransmit periodically rather than trusting one datagram to
        -- survive the trip. The total wait stays bounded by TIMEOUT.
        local now = socket.gettime()
        if now >= next_send then
            udp:sendto(message, ip, WIZ_PORT)
            next_send = now + RESEND
        end
    end

    udp:close()
    return nil, last_err
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
    return sendUDP(ip, msg, "getPilot")
end

--- Send a `setPilot` request with the given params table.
-- Firmware disagrees about `sceneId = 0` ("no scene, plain white"): older
-- builds want it spelled out to leave scene mode, while newer ones reject
-- the whole command with "Invalid params" when it's present. Neither is
-- detectable up front, so send the explicit form first and fall back to
-- dropping sceneId if — and only if — the bulb rejects it outright. A
-- rejection is detectable; "accepted but ignored" would not be.
function Wiz.setPilot(ip, params)
    local msg = rapidjson.encode({ method = "setPilot", params = params })
    local decoded, err, code = sendUDP(ip, msg, "setPilot")

    if not decoded and code == ERR_INVALID_PARAMS and params.sceneId == 0 then
        local retry = {}
        for key, value in pairs(params) do retry[key] = value end
        retry.sceneId = nil
        logger.info("wizlight: bulb rejected sceneId=0, retrying without it")
        decoded, err = sendUDP(ip, rapidjson.encode({ method = "setPilot", params = retry }),
            "setPilot")
    end

    if not decoded then return nil, err end

    -- A successful setPilot answers {"result":{"success":true}}. Only treat
    -- an explicit false as failure: firmware that omits the field entirely
    -- shouldn't be reported as broken.
    if decoded.result and decoded.result.success == false then
        logger.warn("wizlight: bulb reported setPilot success=false")
        return nil, "bulb did not apply the command"
    end

    return decoded
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
-- sceneId = 0 is required, not optional: a colour temperature is
-- meaningless while a scene is rendering its own colours, and the official
-- WiZ per-scene compatibility table has an "Adjustable dimming" column but
-- no adjustable-temp one at all. Without explicitly leaving scene mode,
-- a temp-only setPilot has nothing to act on and the scene keeps playing,
-- so the change silently never lands.
function Wiz.setColorTemp(ip, temp)
    return Wiz.setPilot(ip, { state = true, sceneId = 0, temp = temp })
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

--- Render a setPilot params table as a short human-readable summary, e.g.
--- "scene 14, 70%" or "70%, 3000K". Used in notifications for Reading Mode
--- and Default Scene so a captured/sent snapshot is visible and checkable
--- instead of an opaque "it worked" toast — if this ever prints just "on"
--- or "off" where you expected brightness/temp/scene to show up, that
--- means getPilot's response didn't include the field you expected, not
--- that setPilot silently failed.
function Wiz.describeParams(params)
    local parts = {}
    if params.sceneId then table.insert(parts, "scene " .. params.sceneId) end
    if params.dimming then table.insert(parts, params.dimming .. "%") end
    if params.temp then table.insert(parts, params.temp .. "K") end
    if params.speed then table.insert(parts, "speed " .. params.speed) end
    if params.r or params.g or params.b then
        table.insert(parts, string.format("rgb(%s,%s,%s)", params.r or 0, params.g or 0, params.b or 0))
    end
    if params.c then table.insert(parts, "cold " .. params.c) end
    if params.w then table.insert(parts, "warm " .. params.w) end
    if #parts == 0 then
        if params.state == false then return "off" end
        return "on"
    end
    return table.concat(parts, ", ")
end

--- Render every key/value a getPilot `.result` actually contains, sorted,
--- one per line — including fields this plugin doesn't otherwise use
--- (mac, rssi, src, schdPsetId, …). Unlike describeParams(), which only
--- reports the handful of keys we control, this shows the unfiltered
--- truth, so "the bulb ignored my change" can be told apart from "the
--- plugin captured the wrong thing" without guessing.
function Wiz.dumpPilot(result)
    local keys = {}
    for key in pairs(result) do
        table.insert(keys, key)
    end
    if #keys == 0 then return "(empty response)" end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do
        table.insert(lines, key .. " = " .. tostring(result[key]))
    end
    return table.concat(lines, "\n")
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
