--[[--
Firewall handling for wizlight.koplugin.

WiZ bulbs answer over UDP, and on a locked-down device those answers can
be dropped on the way back in — the command still reaches the bulb and
takes effect, but the plugin never hears the reply. That failure mode
looks identical to a bulb ignoring a command, which makes it worth
handling explicitly rather than hoping the default policy is permissive.

@module koplugin.wizlight.firewall
--]]--

local logger = require("logger")

local WIZ_PORT = 38899

-- Bulb traffic arrives in two shapes, and both have to be let through:
--
--   --dport 38899  replies to a socket *bound* to the WiZ port. Discovery
--                  and probe bind it, because registration replies are
--                  addressed to phoneIp:38899 rather than to the sender's
--                  port.
--   --sport 38899  replies from a bulb to whatever ephemeral port an
--                  ordinary command happened to use. getPilot/setPilot
--                  don't bind anything, so their answers come back to a
--                  random local port — which the --dport rule never
--                  matched.
--
-- Only the first rule existed, and only while discovery was running, so
-- every ordinary command was relying on the INPUT policy being permissive
-- or on conntrack recognising the reply. Neither is guaranteed on a
-- stripped embedded kernel.
local RULES = {
    "INPUT -p udp --dport " .. WIZ_PORT .. " -j ACCEPT",
    "INPUT -p udp --sport " .. WIZ_PORT .. " -j ACCEPT",
}

local Firewall = {}

local is_open = false

--- Open the rules once per session. Cheap to call before every command:
--- it does nothing after the first time, which also means the rules can't
--- stack up the way an unbalanced open/close pair did.
function Firewall.ensureOpen()
    if is_open then return end
    for _, rule in ipairs(RULES) do
        os.execute("iptables -I " .. rule .. " 2>/dev/null")
    end
    is_open = true
    logger.info("wizlight: opened firewall for UDP port", WIZ_PORT)
end

--- Remove the rules again. Called from the plugin's shutdown hooks; if the
--- process dies without getting there the rules simply don't survive the
--- next reboot, and an extra ACCEPT for one UDP port is harmless meanwhile.
function Firewall.close()
    if not is_open then return end
    for _, rule in ipairs(RULES) do
        os.execute("iptables -D " .. rule .. " 2>/dev/null")
    end
    is_open = false
    logger.info("wizlight: closed firewall for UDP port", WIZ_PORT)
end

--- Whether the rules are currently believed to be in place (for diagnostics).
function Firewall.isOpen()
    return is_open
end

return Firewall
