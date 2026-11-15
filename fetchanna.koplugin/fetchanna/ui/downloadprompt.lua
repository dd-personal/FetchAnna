local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Notification = require("ui/widget/notification")
local DownloadMgr = require("ui/downloadmgr")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local util = require("util")
local LogUtil = require("fetchanna.util.logutil")
local FileUtil = require("fetchanna.util.fileutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local StringUtil = require("fetchanna.util.stringutil")
local CoverCache = require("fetchanna.cache.covercache")
local CoverPlaceholder = require("fetchanna.ui.coverplaceholder")
local Sources = require("fetchanna.api.sources")
local Guard = require("fetchanna.util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

local DownloadPrompt = {}
DownloadPrompt.__index = DownloadPrompt

local CONTENT_WIDTH = Screen:scaleBySize(380)
local COVER_SIZE = Screen:scaleBySize(192)
-- Black for the title and details, greys still readable on e-ink for the rest (KindleFetch #3).
local AUTHOR_COLOR = Blitbuffer.COLOR_GRAY_4
local LABEL_COLOR = Blitbuffer.COLOR_GRAY_6
-- Line limits, so the prompt always fits on the screen.
local TITLE_MAX_LINES = 4
local AUTHOR_MAX_LINES = 2
local FILENAME_MAX_LINES = 2
local TITLE_FACE = Font:getFace("cfont", 20)
local AUTHOR_FACE = Font:getFace("cfont", 17)
local DETAIL_FACE = Font:getFace("cfont", 15)
local LABEL_FACE = Font:getFace("cfont", 14)

function DownloadPrompt.new(book, filepath, on_download)
    local self = setmetatable({}, DownloadPrompt)

    LogUtil.debug("params given to DownloadPrompt", book, filepath)

    self.book = book
    self.filepath = filepath
    self.on_download = on_download
    self.fullscreen_cover_shown = false

    -- Handles taps outside the prompt.
    local parent_ref = self
    self.outer_container = InputContainer:new {}
    self.outer_container.dimen = Geom:new {
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.outer_container.ges_events = {
        TapOutside = {
            GestureRange:new {
                ges = "tap",
                range = self.outer_container.dimen,
            },
        },
    }
    function self.outer_container.onTapOutside(__, __, ges)
        if ges.pos:notIntersectWith(parent_ref.frame.dimen) then
            parent_ref:close()
            return true
        end
        return false
    end
    -- Shows the cover once it has downloaded, or removes its placeholder if it couldn't be. Ignores other books'
    -- covers, which can arrive several times a second. Errors are only logged, as KOReader doesn't catch them (see
    -- Guard).
    self.outer_container.onFetchAnnaCoversDownloaded = Guard.wrap("showing the book's cover", function()
        if parent_ref:coverState() ~= parent_ref.cover_state then
            parent_ref:refreshCover()
        end
    end, Guard.quiet)

    self:buildCover()
    self:buildPathButton()

    -- As in KOReader's own dialogs.
    self.button_table = ButtonTable:new {
        width = CONTENT_WIDTH + Size.padding.large * 2,
        zero_sep = true,
        show_parent = self.outer_container,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "cancel",
                    callback = function()
                        self:close()
                    end,
                },
                {
                    text = _("Download"),
                    id = "download",
                    callback = function()
                        self:download()
                    end,
                },
            },
        },
    }

    self.body = FrameContainer:new {
        bordersize = 0,
        padding = Size.padding.large,
        self:buildContent(),
    }

    self.frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        VerticalGroup:new {
            align = "left",
            self.body,
            self.button_table,
        },
    }

    self.container = CenterContainer:new {
        dimen = Geom:new {
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        self.frame,
    }
    self.outer_container[1] = self.container

    return self
end

function DownloadPrompt:download()
    self:close()

    if self.on_download then
        self.on_download(self.filepath)
    end
end

-- Returns the full-size cover once it has downloaded, otherwise the thumbnail.
function DownloadPrompt:coverFile()
    return CoverCache:getFullSize(self.book) or CoverCache:get(self.book.id)
end

-- Returns a string that changes when the book's covers do.
function DownloadPrompt:coverState()
    return string.format(
        "%s|%s|%s",
        tostring(self:coverFile()),
        tostring(CoverCache:isComing(self.book)),
        tostring(CoverCache:isFullSizeComing(self.book))
    )
end

-- Builds the cover (tap for fullscreen), a placeholder while it downloads, or nothing.
function DownloadPrompt:buildCover()
    self.cover = nil
    self.cover_container = nil
    self.cover_state = self:coverState()

    local cover_file = self:coverFile()
    if cover_file then
        local cover_image = ImageWidget:new {
            file = cover_file,
            width = COVER_SIZE,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true,
        }

        local parent_ref = self
        self.cover_container = InputContainer:new {}
        self.cover_container.dimen = Geom:new {
            w = COVER_SIZE,
            h = COVER_SIZE,
        }
        self.cover_container.ges_events = {
            TapCover = {
                GestureRange:new {
                    ges = "tap",
                    range = self.cover_container.dimen,
                },
            },
        }
        function self.cover_container:onTapCover()
            parent_ref:toggleFullscreenCover()
            return true
        end
        self.cover_container[1] = CenterContainer:new {
            dimen = Geom:new {
                w = COVER_SIZE,
                h = COVER_SIZE,
            },
            cover_image,
        }
        self.cover = self.cover_container
    elseif CoverCache:isComing(self.book) then
        self.cover = CenterContainer:new {
            dimen = Geom:new {
                w = COVER_SIZE,
                h = COVER_SIZE,
            },
            CoverPlaceholder.new(math.floor(COVER_SIZE * 2 / 3), COVER_SIZE),
        }
    end
end

function DownloadPrompt:refreshCover()
    self:buildCover()
    self.body[1] = self:buildContent()
    UIManager:setDirty(self.outer_container, "ui")

    -- Closes the loading notice once the full-size cover has arrived or failed.
    if not CoverCache:isFullSizeComing(self.book) then
        self:closeLoadingNotice()
    end

    -- Swaps in the full-size cover if it arrived while the thumbnail was fullscreen.
    if self.fullscreen_cover_shown and self.fullscreen_file ~= self:coverFile() then
        self:closeFullscreenCover()
        self:showFullscreenCover()
    end
end

-- Returns the book's details as { label, value } pairs.
function DownloadPrompt:details()
    local book = self.book
    local details = {}
    local function add(label, value)
        if value and value ~= "" then
            table.insert(details, { label, value })
        end
    end

    add(_("Format"), StringUtil.joinDetails(book.file_type and book.file_type:upper(), book.file_size))
    add(_("Language"), book.language)
    add(_("Year"), book.year)
    add(_("Type"), book.book_type)
    -- Fast downloads left today, where the site counts them (see Sources).
    local source = Sources[book.source]
    if source and source.allowance then
        add(_("Fast downloads"), source.allowance())
    end
    return details
end

-- Builds the details in two columns, labels in grey.
function DownloadPrompt:buildDetails(width)
    local details = self:details()

    local label_width = 0
    for __, detail in ipairs(details) do
        local label = TextWidget:new {
            text = detail[1],
            face = LABEL_FACE,
        }
        label_width = math.max(label_width, label:getSize().w)
        label:free()
    end
    local gap = Size.padding.large

    local rows = VerticalGroup:new {
        align = "left",
    }
    for i, detail in ipairs(details) do
        if i > 1 then
            table.insert(
                rows,
                VerticalSpan:new {
                    width = Size.padding.small,
                }
            )
        end
        table.insert(
            rows,
            HorizontalGroup:new {
                align = "center",
                TextBoxWidget:new {
                    width = label_width + Size.padding.small,
                    face = LABEL_FACE,
                    text = detail[1],
                    fgcolor = LABEL_COLOR,
                },
                HorizontalSpan:new {
                    width = gap,
                },
                TextBoxWidget:new {
                    width = width - label_width - Size.padding.small - gap,
                    face = DETAIL_FACE,
                    text = detail[2],
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            }
        )
    end
    return rows
end

-- Returns text wrapped over up to max_lines lines, ending in an ellipsis if cut.
local function wrappedText(max_lines, options)
    local function build(height)
        return TextBoxWidget:new {
            width = options.width,
            face = options.face,
            text = options.text,
            bold = options.bold,
            fgcolor = options.fgcolor,
            height = height,
            height_adjust = height and true or nil,
            height_overflow_show_ellipsis = height and true or nil,
        }
    end

    local widget = build()
    if widget:getVisLineCount() > max_lines then
        local height = widget:getLineHeight() * max_lines
        widget:free()
        widget = build(height)
    end
    return widget
end

function DownloadPrompt:buildContent()
    -- The text takes the whole width when there's no cover.
    local text_width = self.cover and CONTENT_WIDTH - COVER_SIZE - Size.padding.large or CONTENT_WIDTH

    self.title = wrappedText(TITLE_MAX_LINES, {
        width = text_width,
        face = TITLE_FACE,
        text = self.book.display_title or "",
        bold = true,
    })

    self.author = wrappedText(AUTHOR_MAX_LINES, {
        width = text_width,
        face = AUTHOR_FACE,
        text = self.book.authors or "",
        fgcolor = AUTHOR_COLOR,
    })

    self.details_group = self:buildDetails(text_width)

    local about = VerticalGroup:new {
        align = "left",
        self.title,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.author,
        VerticalSpan:new {
            width = Size.padding.large,
        },
        self.details_group,
    }

    self.header = about
    if self.cover then
        self.header = HorizontalGroup:new {
            align = "top",
            self.cover,
            HorizontalSpan:new {
                width = Size.padding.large,
            },
            about,
        }
    end

    -- The file name gets its own line, as a long folder would leave it no room.
    self.filename_widget = wrappedText(FILENAME_MAX_LINES, {
        width = CONTENT_WIDTH,
        face = DETAIL_FACE,
        text = self:filename(),
        fgcolor = Blitbuffer.COLOR_BLACK,
    })

    return VerticalGroup:new {
        align = "left",
        self.header,
        VerticalSpan:new {
            width = Size.padding.large * 2,
        },
        TextBoxWidget:new {
            width = CONTENT_WIDTH,
            face = LABEL_FACE,
            text = _("Download to"),
            fgcolor = LABEL_COLOR,
        },
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.path_widget,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.filename_widget,
    }
end

-- The folder the book is saved in, and its file name.
function DownloadPrompt:folder()
    local folder = self.filepath:match("^(.*)/[^/]*$")
    return folder ~= "" and folder or "/"
end
function DownloadPrompt:filename()
    return self.filepath:match("([^/]+)$") or ""
end

-- Builds the folder button. Tapping it chooses another folder.
function DownloadPrompt:buildPathButton()
    self.path_widget = Button:new {
        text = self:folder(),
        callback = function()
            self:choosePath()
        end,
        text_font_size = 16,
        text_font_bold = false,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        padding = Size.padding.default,
        width = CONTENT_WIDTH,
        max_width = CONTENT_WIDTH,
    }
end

function DownloadPrompt:choosePath()
    DownloadMgr:new {
        title = _("Choose download directory"),
        onConfirm = function(dir)
            -- Keeps the old folder, which can be written to.
            local ok, err = FileUtil.checkWritableDir(dir)
            if not ok then
                LogUtil.warn("not downloading to", dir, "as", err)
                NotifyUtil.error(T(_("Books can't be downloaded to %1: %2"), dir, err))
                return
            end
            -- Named safely for this folder's file system, as a FAT card allows fewer names.
            local name = self.book.title and self.book.file_type and self.book.title .. "." .. self.book.file_type
            self.filepath = dir .. "/" .. (name and util.getSafeFilename(name, dir) or self:filename())

            -- Recreated, as setting its text would keep the old text's size.
            self:buildPathButton()
            self.body[1]:free()
            self.body[1] = self:buildContent()

            UIManager:forceRePaint()
        end,
    }:chooseDir()
end

function DownloadPrompt:toggleFullscreenCover()
    if self.fullscreen_cover_shown then
        self:closeFullscreenCover()
    else
        self:showFullscreenCover()
    end
end

function DownloadPrompt:showFullscreenCover()
    local cover_file = self:coverFile()
    if not cover_file then
        return
    end

    self.fullscreen_cover_shown = true
    self.fullscreen_file = cover_file
    -- The full-size cover is only fetched once it's wanted. The thumbnail shows until it arrives or fails.
    CoverCache:downloadFullSize(self.book)
    local loading_full_size = CoverCache:isFullSizeComing(self.book)

    local fullscreen_image = ImageWidget:new {
        file = cover_file,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        scale_factor = 0,
        alpha = true,
    }

    self.fullscreen_frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        CenterContainer:new {
            dimen = Geom:new {
                w = Screen:getWidth(),
                h = Screen:getHeight(),
            },
            fullscreen_image,
        },
    }

    local parent_ref = self
    self.fullscreen_container = InputContainer:new {}
    self.fullscreen_container.dimen = Geom:new {
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.fullscreen_container.ges_events = {
        TapClose = {
            GestureRange:new {
                ges = "tap",
                range = self.fullscreen_container.dimen,
            },
        },
    }
    function self.fullscreen_container:onTapClose()
        parent_ref:closeFullscreenCover()
        return true
    end
    self.fullscreen_container[1] = self.fullscreen_frame

    UIManager:show(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
    -- Stays up until the full-size cover arrives, unlike other notifications, so it's clear something is happening.
    if loading_full_size then
        self.loading_notice = Notification:new {
            text = _("Loading full-size cover..."),
            timeout = false,
        }
        UIManager:show(self.loading_notice)
    end
end

function DownloadPrompt:closeLoadingNotice()
    if self.loading_notice then
        UIManager:close(self.loading_notice)
        self.loading_notice = nil
    end
end

function DownloadPrompt:closeFullscreenCover()
    if not self.fullscreen_cover_shown then
        return
    end

    self.fullscreen_cover_shown = false
    self:closeLoadingNotice()
    UIManager:close(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
end

-- Refreshes only the prompt's part of the screen, as KOReader's own dialogs do.
function DownloadPrompt:show()
    UIManager:show(self.outer_container)
    UIManager:setDirty(self.outer_container, function()
        return "ui", self.frame.dimen
    end)
end

function DownloadPrompt:close()
    if self.fullscreen_cover_shown then
        self:closeFullscreenCover()
    end
    UIManager:close(self.outer_container)
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

return DownloadPrompt
