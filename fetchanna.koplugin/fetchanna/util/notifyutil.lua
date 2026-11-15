local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local NotifyUtil = {}

function NotifyUtil.info(...)
    Notification:notify(..., Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()
end

-- Shows a message that stays until dismissed, for what mustn't be missed.
function NotifyUtil.message(text)
    UIManager:show(InfoMessage:new {
        text = text,
    })
end

-- Shows an error in a message that stays until dismissed. A notification is gone in a couple of seconds, read or not.
function NotifyUtil.error(text)
    UIManager:show(InfoMessage:new {
        text = text,
        icon = "notice-warning",
    })
end

return NotifyUtil
