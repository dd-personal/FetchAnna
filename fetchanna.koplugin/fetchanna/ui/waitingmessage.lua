local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local HttpUtil = require("fetchanna.util.httputil")
local _ = require("gettext")

local WaitingMessage = {}

-- Adds setStatus(status), which shows what the wait is on (see HttpUtil.sayStatus) beneath the message's
-- text, so a long wait doesn't look stuck. rebuild lays the message out again. A nil status changes nothing, as
-- laying out a message that's about to change or close would only flash the screen.
local function addStatus(message, text, field, rebuild)
    function message:setStatus(status)
        if not status or self.closed or self.cancelled then
            return
        end
        self[field] = text .. "\n\n" .. status
        rebuild(self)
        -- The whole screen, as the message may have grown.
        UIManager:setDirty("all", "ui")
        UIManager:forceRePaint()
    end
    return message
end

-- Returns a message saying what's being waited for, with a Cancel button where the wait can be cancelled (see
-- HttpUtil.setTrapWidget). A tap elsewhere doesn't cancel, as it may have been meant for something else. Cancel
-- sets message.cancelled.
function WaitingMessage.new(text)
    if not HttpUtil.canCancel() then
        return addStatus(
            InfoMessage:new {
                text = text,
            },
            text,
            "text",
            function(self)
                self:free()
                self:init()
            end
        )
    end

    local message
    -- dismiss_callback is set by Trapper:dismissablePopen while it waits.
    local function cancel()
        if message.cancelled then
            return
        end
        message.cancelled = true
        if message.dismiss_callback then
            message.dismiss_callback()
        end
    end
    message = ButtonDialog:new {
        title = text,
        title_align = "center",
        dismissable = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(message)
                        cancel()
                    end,
                },
            },
        },
        -- KOReader's Home key closes the dialog. Without this the wait would go on, and its result still be shown.
        tap_close_callback = cancel,
    }
    return addStatus(message, text, "title", function(self)
        self:reinit()
    end)
end

return WaitingMessage
