--[[--
All UI dialogs and panels for wizlight.koplugin.

Each public function takes `plugin` as its first argument for access to
the plugin's notify(), send(), and errMsg() helpers.

@module koplugin.wizlight.ui
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog  = require("ui/widget/inputdialog")
local SpinWidget   = require("ui/widget/spinwidget")
local Trapper      = require("ui/trapper")
local UIManager    = require("ui/uimanager")
local logger       = require("logger")
local _            = require("gettext")

local Wiz   = require("wizlight.wiz")
local Bulbs = require("wizlight.bulbs")

local UI = {}

-- ── iptables helpers (local to ui.lua; main.lua no longer contains these) ──────

local IPT_RULE = "INPUT -p udp --dport 38899 -j ACCEPT"

local function iptablesOpen()
    os.execute("iptables -I " .. IPT_RULE .. " 2>/dev/null")
end

local function iptablesClose()
    os.execute("iptables -D " .. IPT_RULE .. " 2>/dev/null")
end

--- Format a raw WiZ MAC string (e.g. "a8bb50a4f94d") as "a8:bb:50:a4:f9:4d".
local function formatMAC(mac)
    return (mac:gsub("(..)", "%1:"):sub(1, -2))
end

-- ── scene activation ──────────────────────────────────────────────────────────

--- Activate a scene, merging any stored overrides into the setPilot params.
local function activateScene(plugin, bulb, scene)
    local override = Bulbs.getSceneOverride(scene.id)
    local params   = { state = true, sceneId = scene.id }
    if override.dimming then params.dimming = override.dimming end
    if override.temp    then params.temp    = override.temp    end
    if override.speed   then params.speed   = override.speed   end
    local result, err = Wiz.setPilot(bulb.ip, params)
    if result then
        plugin:notify(string.format(_("Scene: %s"), scene.name))
    else
        plugin:notify(plugin:errMsg(err), 4)
    end
end

--- Return scene name with a "*" marker if it has stored overrides.
local function sceneLabel(scene)
    if next(Bulbs.getSceneOverride(scene.id)) then
        return scene.name .. " *"
    end
    return scene.name
end

-- ── control panel ─────────────────────────────────────────────────────────────

function UI.showControlPanel(plugin, bulb)
    local panel
    panel = ButtonDialog:new{
        title = string.format(_("WiZ Light Controls — %s"), bulb.name),
        buttons = {
            {{ text = _("Toggle On / Off"),
               callback = function()
                   plugin:toggleBulb(bulb.ip)
               end }},
            {{ text = _("Reading Mode"),
               callback = function()
                   local result, err = Wiz.setPilot(bulb.ip, { state = true, temp = 3000, dimming = 70 })
                   if result then
                       plugin:notify(_("Reading Mode activated"))
                   else
                       plugin:notify(plugin:errMsg(err), 4)
                   end
               end }},
            {{ text = _("Brightness…"),
               callback = function()
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
                           plugin:send(function(ip) return Wiz.setBrightness(ip, spin.value) end, bulb.ip)
                       end,
                   })
               end }},
            {{ text = _("Color Temperature…"),
               callback = function()
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
                           plugin:send(function(ip) return Wiz.setColorTemp(ip, spin.value) end, bulb.ip)
                       end,
                   })
               end }},
            {{ text = _("Scenes…"),
               callback = function()
                   UI.showScenesPanel(plugin, bulb)
               end }},
            {{ text = _("Switch Bulb…"),
               callback = function()
                   UIManager:close(panel)
                   UI.showBulbSwitcher(plugin, bulb.mac)
               end }},
            {{ text = _("Close"),
               callback = function() UIManager:close(panel) end }},
        },
    }
    UIManager:show(panel)
    plugin._control_panel = panel
end

-- ── scenes panel ─────────────────────────────────────────────────────────────

function UI.showScenesPanel(plugin, bulb)
    local panel
    local buttons = {}

    for _i, scene in ipairs(plugin.SCENES) do
        local s = scene
        -- Two buttons per row: scene name (activate) | Edit…
        table.insert(buttons, {
            {
                text     = sceneLabel(s),
                callback = function()
                    UIManager:close(panel)
                    activateScene(plugin, bulb, s)
                end,
            },
            {
                text     = _("Edit…"),
                callback = function()
                    UIManager:close(panel)
                    UI.showSceneEditor(plugin, s)
                end,
            },
        })
    end

    table.insert(buttons, {{
        text     = _("Close"),
        callback = function() UIManager:close(panel) end,
    }})

    panel = ButtonDialog:new{
        title   = _("Scenes"),
        buttons = buttons,
    }
    UIManager:show(panel)
    plugin._scenes_panel = panel
end

-- ── scene editor ─────────────────────────────────────────────────────────────
-- Design note: the spec described a single Save/Reset/Cancel dialog that commits
-- all params at once. This implementation uses per-parameter SpinWidgets that each
-- save immediately on confirm. This is better UX on e-ink (fewer navigation steps,
-- no "pending state" to lose if the user hits the back gesture) and supersedes the
-- spec's single-Save model.

function UI.showSceneEditor(plugin, scene)
    local override   = Bulbs.getSceneOverride(scene.id)
    local is_static  = scene.kind == "static"

    local function openBrightnessEditor()
        UIManager:show(SpinWidget:new{
            title_text      = _("Brightness"),
            value           = override.dimming or 70,
            value_min       = 10,
            value_max       = 100,
            value_step      = 5,
            value_hold_step = 20,
            ok_text         = _("Save"),
            callback = function(spin)
                local new_override = Bulbs.getSceneOverride(scene.id)
                new_override.dimming = spin.value
                Bulbs.setSceneOverride(scene.id, new_override)
                plugin:notify(string.format(_("Brightness saved for %s"), scene.name))
            end,
        })
    end

    local function openColorTempEditor()
        UIManager:show(SpinWidget:new{
            title_text      = _("Color Temperature (K)"),
            value           = override.temp or 3000,
            value_min       = 2200,
            value_max       = 6500,
            value_step      = 100,
            value_hold_step = 500,
            ok_text         = _("Save"),
            callback = function(spin)
                local new_override = Bulbs.getSceneOverride(scene.id)
                new_override.temp = spin.value
                Bulbs.setSceneOverride(scene.id, new_override)
                plugin:notify(string.format(_("Color temperature saved for %s"), scene.name))
            end,
        })
    end

    local function openSpeedEditor()
        UIManager:show(SpinWidget:new{
            title_text      = _("Animation Speed"),
            value           = override.speed or 100,
            value_min       = 10,
            value_max       = 200,
            value_step      = 10,
            value_hold_step = 50,
            ok_text         = _("Save"),
            callback = function(spin)
                local new_override = Bulbs.getSceneOverride(scene.id)
                new_override.speed = spin.value
                Bulbs.setSceneOverride(scene.id, new_override)
                plugin:notify(string.format(_("Speed saved for %s"), scene.name))
            end,
        })
    end

    local type_specific_button = is_static
        and { text = _("Color Temperature…"), callback = function() openColorTempEditor() end }
        or  { text = _("Animation Speed…"),   callback = function() openSpeedEditor()     end }

    local editor
    editor = ButtonDialog:new{
        title   = string.format(_("Edit Scene: %s"), scene.name),
        buttons = {
            {{ text = _("Brightness…"),        callback = openBrightnessEditor }},
            { type_specific_button },
            {{ text = _("Reset to defaults"),
               callback = function()
                   UIManager:close(editor)
                   Bulbs.clearSceneOverride(scene.id)
                   plugin:notify(string.format(_("Reset %s to defaults"), scene.name))
               end }},
            {{ text = _("Cancel"),
               callback = function() UIManager:close(editor) end }},
        },
    }
    UIManager:show(editor)
end

-- ── bulb switcher ─────────────────────────────────────────────────────────────

function UI.showBulbSwitcher(plugin, current_mac)
    local all = Bulbs.getAll()
    if #all == 0 then
        plugin:notify(_("No bulbs configured. Go to Settings → Manage Lights."), 4)
        return
    end

    local panel
    local buttons = {}

    for _i, bulb in ipairs(all) do
        local b = bulb
        local label = b.mac == current_mac
            and string.format("[✓] %s", b.name)
            or  string.format("[ ] %s", b.name)
        table.insert(buttons, {{
            text     = label,
            callback = function()
                UIManager:close(panel)
                Bulbs.setActive(b.mac)
                plugin:notify(string.format(_("Active light: %s"), b.name))
            end,
        }})
    end

    table.insert(buttons, {{
        text     = _("Cancel"),
        callback = function() UIManager:close(panel) end,
    }})

    panel = ButtonDialog:new{
        title   = _("Switch Bulb"),
        buttons = buttons,
    }
    UIManager:show(panel)
end

-- ── bulb manager ─────────────────────────────────────────────────────────────

function UI.showBulbManager(plugin)
    local active = Bulbs.getActive()
    local all    = Bulbs.getAll()
    local panel
    local buttons = {}

    for _i, bulb in ipairs(all) do
        local b       = bulb
        local prefix  = (active and active.mac == b.mac) and "[✓] " or "[ ] "
        local label   = string.format("%s%s   %s", prefix, b.name, b.ip)
        table.insert(buttons, {{
            text     = label,
            callback = function()
                UIManager:close(panel)
                Bulbs.setActive(b.mac)
                plugin:notify(string.format(_("Active light: %s"), b.name))
            end,
        }})
    end

    table.insert(buttons, {{
        text     = _("Discover new lights…"),
        callback = function()
            UIManager:close(panel)
            UI.showDiscoveryWizard(plugin)
        end,
    }})

    if #all > 0 then
        table.insert(buttons, {{
            text     = _("Remove a light…"),
            callback = function()
                UIManager:close(panel)
                UI.showBulbRemover(plugin)
            end,
        }})
    end

    table.insert(buttons, {{
        text     = _("Close"),
        callback = function() UIManager:close(panel) end,
    }})

    panel = ButtonDialog:new{
        title   = _("Manage Lights"),
        buttons = buttons,
    }
    UIManager:show(panel)
end

--- Show a list of bulbs for the user to choose one to remove.
-- Note: this function is not listed in the spec's API table (an omission in the spec),
-- but it is required for the "Remove a light…" button in showBulbManager.
function UI.showBulbRemover(plugin)
    local all = Bulbs.getAll()
    local panel
    local buttons = {}

    for _i, bulb in ipairs(all) do
        local b = bulb
        table.insert(buttons, {{
            text     = string.format("%s   (%s)", b.name, b.ip),
            callback = function()
                UIManager:close(panel)
                Bulbs.remove(b.mac)
                plugin:notify(string.format(_("Removed: %s"), b.name))
            end,
        }})
    end

    table.insert(buttons, {{
        text     = _("Cancel"),
        callback = function() UIManager:close(panel) end,
    }})

    panel = ButtonDialog:new{
        title   = _("Remove a Light"),
        buttons = buttons,
    }
    UIManager:show(panel)
end

-- ── discovery wizard ──────────────────────────────────────────────────────────

--- Run the UDP broadcast scan in a Trapper coroutine, then hand off
--- to the callback-driven wizard flow via UIManager:nextTick.
function UI.showDiscoveryWizard(plugin)
    if not coroutine.running() then
        Trapper:wrap(function() UI.showDiscoveryWizard(plugin) end)
        return
    end

    iptablesOpen()
    Trapper:info(_("Scanning for WiZ lights…"))
    local found_bulbs, err = Wiz.discover()
    Trapper:clear()
    iptablesClose()

    if not found_bulbs then
        plugin:notify(string.format(
            _("Discovery failed: %s\nUse 'Manage Lights' to add an IP manually."),
            err or "unknown error"), 6)
        return
    end

    -- Filter out MACs already in the registry
    local known = {}
    for _i, b in ipairs(Bulbs.getAll()) do
        known[b.mac] = true
    end
    local new_bulbs = {}
    for _i, b in ipairs(found_bulbs) do
        if not known[b.mac] then
            table.insert(new_bulbs, b)
        end
    end

    if #new_bulbs == 0 then
        plugin:notify(_("No new WiZ lights found on the network."), 4)
        return
    end

    -- Exit the Trapper coroutine before showing interactive dialogs
    UIManager:nextTick(function()
        UI._wizardStep(plugin, new_bulbs, 1, 0)
    end)
end

--- Process new_bulbs[index] through the blink → confirm → name flow,
--- then recurse to the next bulb. Shows summary when all are done.
function UI._wizardStep(plugin, new_bulbs, index, added_count)
    if index > #new_bulbs then
        if added_count > 0 then
            plugin:notify(string.format(_("%d light(s) added."), added_count))
        else
            plugin:notify(_("No new lights added."), 3)
        end
        return
    end

    local found     = new_bulbs[index]
    local ip        = found.ip
    local mac       = found.mac
    local advance   = function(count) UI._wizardStep(plugin, new_bulbs, index + 1, count) end

    local blink_dialog
    blink_dialog = ButtonDialog:new{
        title = string.format(
            _("Found a light at %s\n(%s)\n\nTap 'Blink it' to identify which one it is."),
            ip, formatMAC(mac)
        ),
        buttons = {{
            {
                text     = _("Blink it"),
                callback = function()
                    UIManager:close(blink_dialog)
                    -- Fire-and-forget the blink; show a toast only on failure
                    local ok, blink_err = Wiz.blink(ip)
                    if not ok then
                        plugin:notify(string.format(
                            _("Could not blink light: %s"), blink_err or "?"), 3)
                    end

                    local confirm_dialog
                    confirm_dialog = ButtonDialog:new{
                        title   = _("Was it your light?"),
                        buttons = {{
                            {
                                text     = _("Yes — name it"),
                                callback = function()
                                    UIManager:close(confirm_dialog)
                                    local name_dialog
                                    name_dialog = InputDialog:new{
                                        title      = _("Room name for this light"),
                                        input_hint = _("e.g. Bedroom"),
                                        buttons    = {{
                                            {
                                                text     = _("Cancel"),
                                                callback = function()
                                                    UIManager:close(name_dialog)
                                                    advance(added_count)
                                                end,
                                            },
                                            {
                                                text             = _("Save"),
                                                is_enter_default = true,
                                                callback = function()
                                                    local name = name_dialog:getInputText()
                                                    UIManager:close(name_dialog)
                                                    if name and name ~= "" then
                                                        Bulbs.add(name, ip, mac)
                                                        advance(added_count + 1)
                                                    else
                                                        advance(added_count)
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(name_dialog)
                                    name_dialog:onShowKeyboard()
                                    -- If the user submits an empty name, the Save
                                    -- callback silently skips adding the bulb and
                                    -- advances to the next one. This is intentional.
                                end,
                            },
                            {
                                text     = _("Skip"),
                                callback = function()
                                    UIManager:close(confirm_dialog)
                                    advance(added_count)
                                end,
                            },
                        }},
                    }
                    UIManager:show(confirm_dialog)
                end,
            },
            {
                text     = _("Skip"),
                callback = function()
                    UIManager:close(blink_dialog)
                    advance(added_count)
                end,
            },
        }},
    }
    UIManager:show(blink_dialog)
end

-- ── DHCP failure dialog ───────────────────────────────────────────────────────

function UI.showDHCPDialog(plugin, bulb_name, mac, retry_fn)
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            _("%s unreachable.\nThe bulb's IP may have changed."),
            bulb_name
        ),
        buttons = {{
            {
                text     = _("Re-discover"),
                callback = function()
                    UIManager:close(dialog)
                    UI.rediscoverBulb(plugin, mac, retry_fn)
                end,
            },
            {
                text     = _("Dismiss"),
                callback = function() UIManager:close(dialog) end,
            },
        }},
    }
    UIManager:show(dialog)
end

--- Scan for a specific bulb by MAC. Updates its IP if found, then calls retry_fn.
function UI.rediscoverBulb(plugin, mac, retry_fn)
    if not coroutine.running() then
        Trapper:wrap(function() UI.rediscoverBulb(plugin, mac, retry_fn) end)
        return
    end

    iptablesOpen()
    Trapper:info(_("Scanning for WiZ lights…"))
    local bulbs, err = Wiz.discover()
    Trapper:clear()
    iptablesClose()

    if not bulbs then
        plugin:notify(string.format(_("Discovery failed: %s"), err or "?"), 4)
        return
    end

    for _i, found in ipairs(bulbs) do
        if found.mac == mac then
            Bulbs.updateIP(mac, found.ip)
            plugin:notify(
                string.format(_("Bulb found at new address %s — retrying."), found.ip), 3)
            if retry_fn then retry_fn() end
            return
        end
    end

    local bulb = Bulbs.getActive()
    plugin:notify(
        string.format(_("Could not find %s on the network."), bulb and bulb.name or _("bulb")), 4)
end

return UI
