--[[--
Self-update for wizlight.koplugin from its GitHub releases.

Checks the latest release, and if it is newer than the installed
_meta.lua version, downloads the release zip, unpacks it next to the
plugin, and swaps the plugin directory for the new one. Settings live in
KOReader's settings dir (wizlight.lua, G_reader_settings), not in the
plugin directory, so replacing the directory loses nothing.

@module koplugin.wizlight.updater
--]]--

local ConfirmBox  = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr  = require("ui/network/manager")
local Trapper     = require("ui/trapper")
local UIManager   = require("ui/uimanager")
local ffiUtil     = require("ffi/util")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local rapidjson   = require("rapidjson")
local util        = require("util")
local _           = require("gettext")

local REPO       = "Tasty-Murder/wizlight.koplugin"
local LATEST_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
-- The release workflow publishes exactly this file, with a single
-- top-level `wizlight.koplugin/` directory inside.
local ASSET_NAME = "wizlight.koplugin.zip"
local ZIP_ROOT   = "wizlight.koplugin"
local USER_AGENT = "KOReader-wizlight-plugin"

local Updater = {}

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- Read `version` out of a plugin directory's _meta.lua, or nil.
local function readVersion(plugin_dir)
    local ok, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string" then
        return meta.version
    end
    logger.warn("wizlight updater: could not read version from", plugin_dir, meta)
end

--- Split "v1.3.0" / "1.3.0" into { 1, 3, 0 }, or nil if it isn't one.
local function parseVersion(text)
    local core = type(text) == "string" and text:match("^v?(%d+[%.%d]*)")
    if not core then return nil end
    local parts = {}
    for n in core:gmatch("%d+") do table.insert(parts, tonumber(n)) end
    return parts
end

--- True when version `a` is strictly older than `b`.
local function isOlder(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y end
    end
    return false
end

--- GET `url` into `sink`. Returns the HTTP status code, or (nil, err).
local function httpGet(url, sink, headers)
    local http       = require("socket.http")
    local socket     = require("socket")
    local socketutil = require("socketutil")

    headers = headers or {}
    headers["User-Agent"] = USER_AGENT
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url     = url,
            headers = headers,
            sink    = sink,
            -- Release assets on github.com 302 to a CDN host.
            redirect = true,
        })
    end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    if type(code) ~= "number" then return nil, tostring(status or code or "network unreachable") end
    if code ~= 200 then
        logger.warn("wizlight updater: HTTP", code, "for", url, resp_headers)
        -- Unauthenticated GitHub API calls are limited to 60 an hour per
        -- address, and a shared Wi-Fi can use that up for everyone on it.
        if code == 403 or code == 429 then
            return code, "GitHub's request limit was reached; try again in an hour"
        end
        return code, "HTTP " .. code
    end
    return code
end

--- Fetch and decode the latest release. Returns the release table, or (nil, err).
local function fetchLatestRelease()
    local ltn12 = require("ltn12")
    local chunks = {}
    local code, err = httpGet(LATEST_URL, ltn12.sink.table(chunks),
        { ["Accept"] = "application/vnd.github+json" })
    if code ~= 200 then
        return nil, err or ("HTTP " .. tostring(code))
    end
    local release = rapidjson.decode(table.concat(chunks))
    if type(release) ~= "table" or type(release.tag_name) ~= "string" then
        return nil, "unexpected response from GitHub"
    end
    return release
end

--- Pick the plugin archive out of a release's assets: by exact name, so a
--- checksum or second archive added later can't be picked up by accident.
local function findAsset(release)
    for _i, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        if type(asset) == "table" and asset.name == ASSET_NAME
                and type(asset.browser_download_url) == "string" then
            return asset.browser_download_url
        end
    end
end

--- Download `url` to `path`. Returns true, or (nil, err).
local function download(url, path)
    local ltn12 = require("ltn12")
    local file, open_err = io.open(path, "wb")
    if not file then return nil, open_err end
    -- ltn12.sink.file closes the handle at end of stream; a request that
    -- fails before any data arrives never gets there, hence the pcall.
    local code, err = httpGet(url, ltn12.sink.file(file))
    pcall(file.close, file)
    if code ~= 200 then
        os.remove(path)
        return nil, err or ("HTTP " .. tostring(code))
    end
    return true
end

--- Extract `zip` into `dest`, keeping the archive's own top directory.
--- KOReader v2026.07 removed Device:unpackArchive in favour of the
--- ffi/archiver module; older builds only have the former, so prefer the
--- module and fall back.
local function unpack(zip, dest)
    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if has_archiver and Archiver.Reader then
        local arc = Archiver.Reader:new()
        if not arc:open(zip) then
            return nil, arc.err or "could not open archive"
        end
        local ok = true
        for entry in arc:iterate() do
            if not arc:extractToPath(entry.path, dest .. "/" .. entry.path) then
                ok = false
                break
            end
        end
        local err = arc.err
        arc:close()
        if not ok then return nil, err or "extraction failed" end
        return true
    end

    local Device = require("device")
    if Device.unpackArchive then
        local ok, err = Device:unpackArchive(zip, dest, false)
        if not ok then return nil, tostring(err or "extraction failed") end
        return true
    end
    return nil, "this KOReader build has no archive support"
end

local function purge(path)
    if lfs.attributes(path, "mode") then ffiUtil.purgeDir(path) end
end

--- Replace `plugin_dir` with the freshly extracted copy in `staged_dir`.
--- Renames rather than copies over the top: a copy that dies halfway
--- leaves a plugin that is half one version and half another, while a
--- failed rename leaves the old directory untouched (and is undone if the
--- second rename fails). Staging and backup sit beside the plugin so both
--- renames stay on one filesystem, and neither name ends in ".koplugin",
--- so KOReader's plugin loader won't try to load them.
local function swapIn(plugin_dir, staged_dir)
    local backup = plugin_dir .. ".old"
    purge(backup)
    local ok, err = os.rename(plugin_dir, backup)
    if not ok then return nil, err end
    ok, err = os.rename(staged_dir, plugin_dir)
    if not ok then
        os.rename(backup, plugin_dir)
        return nil, err
    end
    purge(backup)
    return true
end

--- Download, verify and install `url` over `plugin_dir`. Runs inside Trapper.
local function install(plugin_dir, url, version)
    local staging = plugin_dir .. ".update"
    local zip = DataStorage:getDataDir() .. "/cache/wizlight-update.zip"
    util.makePath(DataStorage:getDataDir() .. "/cache")
    purge(staging)

    Trapper:info(_("Downloading update…"))
    local ok, err = download(url, zip)
    if ok then
        Trapper:info(_("Installing update…"))
        util.makePath(staging)
        ok, err = unpack(zip, staging)
    end
    os.remove(zip)

    local staged = staging .. "/" .. ZIP_ROOT
    if ok then
        -- An archive can unpack "successfully" and still not be a plugin
        -- (wrong asset, truncated download). Insist on a loadable
        -- _meta.lua carrying the version we were promised before touching
        -- the installed copy.
        local staged_version = util.fileExists(staged .. "/main.lua") and readVersion(staged)
        if not staged_version then
            ok, err = nil, "downloaded archive is not a wizlight plugin"
        elseif staged_version ~= version then
            ok, err = nil, string.format("archive contains version %s, expected %s",
                staged_version, version)
        end
    end
    if ok then
        ok, err = swapIn(plugin_dir, staged)
    end
    purge(staging)
    Trapper:clear()

    if not ok then
        logger.warn("wizlight updater: install failed:", err)
        notify(string.format(_("Update failed: %s\nThe installed version was left unchanged."),
            tostring(err)), 6)
        return
    end
    logger.info("wizlight updater: installed", version)
    UIManager:askForRestart(string.format(
        _("WiZ Light updated to %s.\nRestart KOReader to use the new version."), version))
end

--- Show at most the first `limit` characters of the release notes.
local function shortNotes(body, limit)
    if type(body) ~= "string" or body == "" then return "" end
    body = body:gsub("\r", "")
    if #body > limit then body = body:sub(1, limit):gsub("%s*[^%s]*$", "") .. "…" end
    return "\n\n" .. body
end

--- Check GitHub for a newer release and offer to install it.
-- `plugin_dir` is the plugin's own directory (the loader's `self.path`).
function Updater.checkForUpdates(plugin_dir)
    if NetworkMgr:willRerunWhenOnline(function() Updater.checkForUpdates(plugin_dir) end) then
        return
    end
    if not coroutine.running() then
        Trapper:wrap(function() Updater.checkForUpdates(plugin_dir) end)
        return
    end

    local installed = readVersion(plugin_dir)
    Trapper:info(_("Checking for updates…"))
    local release, err = fetchLatestRelease()
    Trapper:clear()

    if not release then
        logger.warn("wizlight updater: release check failed:", err)
        notify(string.format(_("Could not check for updates: %s"), tostring(err)), 5)
        return
    end

    local latest = release.tag_name:gsub("^v", "")
    local latest_parts, installed_parts = parseVersion(latest), parseVersion(installed)
    if not latest_parts then
        notify(string.format(_("Unrecognised release version: %s"), release.tag_name), 5)
        return
    end
    if installed_parts and not isOlder(installed_parts, latest_parts) then
        notify(string.format(_("WiZ Light is up to date (%s)."), installed), 3)
        return
    end

    local url = findAsset(release)
    if not url then
        notify(string.format(_("Release %s has no %s to install."), release.tag_name, ASSET_NAME), 5)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = string.format(_("WiZ Light %s is available (you have %s).\nDownload and install it?"),
            latest, installed or _("an unknown version")) .. shortNotes(release.body, 500),
        ok_text = _("Update"),
        ok_callback = function()
            Trapper:wrap(function() install(plugin_dir, url, latest) end)
        end,
    })
end

return Updater
