std = "luajit"

-- Tooling LuaRocks installs into the working directory in CI
-- (leafo/gh-actions-luarocks), not part of this plugin.
exclude_files = {
    ".luarocks/",
}

-- Lua's colon-method idiom: `function Obj:method()` is used for interface
-- consistency even when a given method body doesn't happen to touch `self`.
-- Not a real bug, so don't warn on it.
self = false

-- Provided by the KOReader host app at runtime, not defined by this plugin.
globals = {
    "G_reader_settings",
}

-- `_i` marks a deliberately unused for-in loop index. It's spelled `_i`
-- rather than the more common bare `_` because ui.lua and menu.lua alias
-- gettext to `_` (`local _ = require("gettext")`) — a loop-local `_` would
-- shadow that for the whole loop body, silently breaking any `_("...")`
-- call inside it or in a closure defined within it (confirmed: this is a
-- real crash, not just a style nit — "attempt to call local '_' (a number
-- value)" — and luacheck does not warn about it, since it exempts bare `_`
-- from unused-variable checks the same way this ignore now exempts `_i`).
ignore = {
    "213/_i",
}
