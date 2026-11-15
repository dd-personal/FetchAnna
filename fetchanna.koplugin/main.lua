local logger = require("logger")
local SafeMode = require("fetchanna.safemode")

-- KOReader loads a plugin from its main.lua. This loads FetchAnna, or a menu with what's left (see SafeMode) when it
-- can't be loaded or started, e.g. after an update to a version that doesn't work with this KOReader. Otherwise
-- FetchAnna would vanish from KOReader's menu, update check included, until it was copied over USB.
local loaded, FetchAnna = xpcall(require, debug.traceback, "fetchanna.plugin")
if not loaded then
    logger.err("FetchAnna:", "could not load FetchAnna:", FetchAnna)
    return SafeMode.new(FetchAnna)
end

-- Likewise when starting it fails, which KOReader would leave it out of its menu for.
local init = FetchAnna.init
function FetchAnna:init()
    local started, err = xpcall(init, debug.traceback, self)
    if not started then
        logger.err("FetchAnna:", "could not start FetchAnna:", err)
        SafeMode.takeOver(self, err)
    end
end

return FetchAnna
