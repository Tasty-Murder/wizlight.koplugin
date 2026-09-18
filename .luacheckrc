std = "luajit"

-- Lua's colon-method idiom: `function Obj:method()` is used for interface
-- consistency even when a given method body doesn't happen to touch `self`.
-- Not a real bug, so don't warn on it.
self = false

-- Provided by the KOReader host app at runtime, not defined by this plugin.
globals = {
    "G_reader_settings",
}
