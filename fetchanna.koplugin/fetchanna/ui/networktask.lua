local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local NetworkMgr = require("ui/network/manager")
local HttpUtil = require("fetchanna.util.httputil")
local WaitingMessage = require("fetchanna.ui.waitingmessage")
local Errors = require("fetchanna.util.errors")
local Guard = require("fetchanna.util.guard")

-- A network task asked for on screen, such as logging in. Wi-Fi is turned on first if need be (as KOReader is set
-- up to), and a message with a Cancel button shows until it's done.
local NetworkTask = {}

-- Runs fn (named what, for the log) under a message saying text, then calls done with what fn returned, or nil and
-- why not. Errors are caught here, as Trapper would lose them and leave the message up.
function NetworkTask.run(what, text, fn, done)
    NetworkMgr:runWhenConnected(function()
        local message
        local function closeMessage()
            if message and not message.cancelled and not message.closed then
                message.closed = true
                UIManager:close(message)
            end
        end
        Trapper:wrap(Guard.wrap(what, function()
            message = WaitingMessage.new(text)
            UIManager:show(message)
            UIManager:forceRePaint()
            HttpUtil.setTrapWidget(message)
            local ok, result, err, info = Guard.pcall(what, fn)
            HttpUtil.setTrapWidget(nil)
            closeMessage()
            if not ok then
                result, err = nil, Errors.UNEXPECTED
            end
            done(result, err, info)
        end, function(err)
            HttpUtil.setTrapWidget(nil)
            closeMessage()
            Guard.say(err)
        end))
    end)
end

return NetworkTask
