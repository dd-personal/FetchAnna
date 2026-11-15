local UIManager = require("ui/uimanager")
local LogUtil = require("fetchanna.util.logutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local Errors = require("fetchanna.util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- KOReader doesn't catch errors in what it runs later: scheduled tasks, functions Trapper wraps, and event handlers of
-- widgets other than the plugin's own (which PluginLoader's HandlerSandbox catches). A bug in one would exit KOReader,
-- or vanish without a trace. These run them, log any error with where it happened, then clean up.
local Guard = {}

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Says that something went wrong, for when the failed task has nothing of its own to clean up or say.
function Guard.say(err)
    NotifyUtil.error(T(_("FetchAnna: %1"), err))
end

-- Like pcall, but logs the error with a traceback. what names the task, e.g. "searching".
function Guard.pcall(what, fn, ...)
    local results = pack(xpcall(fn, debug.traceback, ...))
    if not results[1] then
        LogUtil.err(what, "went wrong:", tostring(results[2]))
    end
    return unpack(results, 1, results.n)
end

-- Calls fn and returns what it returns. If it fails, calls on_error (Guard.say by default) with Errors.UNEXPECTED to
-- clean up and say so, and returns nothing.
function Guard.call(what, fn, on_error, ...)
    local results = pack(Guard.pcall(what, fn, ...))
    if results[1] then
        return unpack(results, 2, results.n)
    end
    Guard.pcall("cleaning up after " .. what, on_error or Guard.say, Errors.UNEXPECTED)
end

-- Returns fn wrapped in Guard.call, for KOReader to call later.
function Guard.wrap(what, fn, on_error)
    return function(...)
        return Guard.call(what, fn, on_error, ...)
    end
end

-- UIManager:scheduleIn and nextTick, with fn wrapped in Guard.call.
function Guard.scheduleIn(seconds, what, fn, on_error)
    UIManager:scheduleIn(seconds, Guard.wrap(what, fn, on_error))
end
function Guard.nextTick(what, fn, on_error)
    UIManager:nextTick(Guard.wrap(what, fn, on_error))
end

-- An on_error for when nothing needs saying, e.g. an update check nobody asked for.
function Guard.quiet() end

return Guard
