local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local DownloadProgress = {}
DownloadProgress.__index = DownloadProgress

-- A fixed width for the widget's contents, to prevent overdrawing.
local CONTENT_WIDTH = Screen:scaleBySize(280)

-- on_cancel is called when the user taps Cancel. hidden starts it hidden, as when retrying a hidden download.
function DownloadProgress.new(title, on_cancel, hidden)
    local self = setmetatable({}, DownloadProgress)

    self.title = title
    self.cancelled = false
    self.on_cancel = on_cancel
    self.is_visible = not hidden
    self.percentage = 0
    self.status_text = ""
    self:build()

    return self
end

-- Creates the widgets, again whenever it's shown after being hidden, as KOReader frees closed widgets.
function DownloadProgress:build()
    self.text_widget = TextBoxWidget:new {
        text = self.title,
        face = Font:getFace("cfont", 18),
        width = CONTENT_WIDTH,
        alignment = "center",
    }

    -- The download percentage.
    self.status_widget = TextWidget:new {
        text = self.status_text,
        face = Font:getFace("cfont", 16),
        width = CONTENT_WIDTH,
        alignment = "center",
    }

    self.status_container = CenterContainer:new {
        dimen = Geom:new {
            w = CONTENT_WIDTH,
            -- As tall as its text, whose font is bigger on denser screens.
            h = self.status_widget:getSize().h,
        },
        self.status_widget,
    }

    self.bar_widget = ProgressWidget:new {
        width = CONTENT_WIDTH,
        height = Screen:scaleBySize(16),
        percentage = self.percentage,
    }

    self.cancel_button = Button:new {
        text = _("Cancel"),
        enabled = self.cancellable ~= false,
        callback = function()
            self:cancel()
        end,
        padding = Size.padding.default,
    }

    self.hide_button = Button:new {
        text = _("Hide"),
        enabled = self.cancellable ~= false,
        callback = function()
            self:toggleVisibility()
        end,
        padding = Size.padding.default,
    }

    self.button_group = HorizontalGroup:new {
        align = "center",
        self.cancel_button,
        HorizontalSpan:new {
            width = Size.padding.default,
        },
        self.hide_button,
    }

    self.frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        width = CONTENT_WIDTH + Size.padding.large * 2,

        VerticalGroup:new {
            align = "center",
            self.text_widget,
            VerticalSpan:new {
                width = Size.padding.default,
            },
            self.bar_widget,
            VerticalSpan:new {
                width = Size.padding.small,
            },
            self.status_container,
            VerticalSpan:new {
                width = Size.padding.large,
            },
            self.button_group,
        },
    }

    -- Lets keys move between the buttons and press them, and Back hide it, on devices with keys.
    local progress = self
    self.container = FocusManager:new {
        dimen = Geom:new {
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        layout = { { self.cancel_button, self.hide_button } },
        CenterContainer:new {
            dimen = Geom:new {
                w = Screen:getWidth(),
                h = Screen:getHeight(),
            },
            self.frame,
        },
    }
    if Device:hasKeys() then
        self.container.key_events = self.container.key_events or {}
        self.container.key_events.Close = { { Device.input.group.Back } }
    end
    function self.container.onClose()
        if progress.is_visible then
            progress:toggleVisibility()
        end
        return true
    end
end

-- Shows the widget, refreshing only its part of the screen, as it's refreshed twice a second and e-ink is slow.
function DownloadProgress:_show()
    UIManager:show(self.container)
    UIManager:setDirty(self.container, function()
        return "ui", self.frame.dimen
    end)
end

-- Takes the widget off the screen, refreshing only where it was.
function DownloadProgress:_close()
    local frame = self.frame
    UIManager:close(self.container)
    UIManager:setDirty(nil, function()
        return "ui", frame.dimen
    end)
end

function DownloadProgress:show()
    if not self.is_visible then
        return
    end
    self:_show()
end

function DownloadProgress:toggleVisibility()
    self.is_visible = not self.is_visible
    if self.is_visible then
        self:build()
        self:_show()
    else
        self:_close()
    end
end

-- Sets whether Cancel and Hide can be tapped. They can't while the wait holds KOReader up (see
-- HttpUtil.canCancel), as taps would only arrive once it's over.
function DownloadProgress:setCancellable(cancellable)
    self.cancellable = cancellable
    for __, button in ipairs({ self.cancel_button, self.hide_button }) do
        if cancellable then
            button:enable()
        else
            button:disable()
        end
    end
    if self.is_visible and not self.closed then
        UIManager:setDirty(self.container, function()
            return "ui", self.frame.dimen
        end)
    end
end

-- Shows what's being waited for (see HttpUtil.sayStatus) straight away, as the wait may hold KOReader up. nil
-- restores the earlier text.
function DownloadProgress:setStatus(status_text)
    if status_text then
        self.status_before = self.status_before or self.status_text
    else
        status_text, self.status_before = self.status_before, nil
    end
    self:update(self.percentage or 0, status_text)
    UIManager:forceRePaint()
end

-- Updates the percentage and, if given, the status text.
function DownloadProgress:update(percentage, status_text)
    if self.cancelled then
        return
    end

    -- Tracked while hidden, for when it's shown again.
    local changed = percentage ~= self.percentage or (status_text ~= nil and status_text ~= self.status_text)
    self.percentage = percentage
    if status_text then
        self.status_text = status_text
    end
    -- Nothing to redraw when it's off screen or unchanged.
    if not self.is_visible or not changed then
        return
    end

    self.bar_widget.percentage = percentage
    if status_text then
        self.status_widget:setText(status_text)
    end
    UIManager:setDirty(self.container, function()
        return "ui", self.frame.dimen
    end)
end

function DownloadProgress:cancel()
    if self.cancelled then
        return
    end
    self.cancelled = true

    if self.on_cancel then
        self.on_cancel()
    end

    self:close()

    -- Stops the wait, such as a download link lookup. dismiss_callback is set by Trapper:dismissablePopen (see
    -- HttpUtil.setTrapWidget).
    local dismiss = self.dismiss_callback
    self.dismiss_callback = nil
    if dismiss then
        dismiss()
    end
end

-- Closes the widget for good, once, as a cancelled wait may close it too.
function DownloadProgress:close()
    if self.closed then
        return
    end
    self.closed = true
    if not self.is_visible then
        return
    end
    self:_close()
end

return DownloadProgress
