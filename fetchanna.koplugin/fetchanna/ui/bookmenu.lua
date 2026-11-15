local Menu = require("ui/widget/menu")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local StringUtil = require("fetchanna.util.stringutil")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local CoverCache = require("fetchanna.cache.covercache")
local CoverPlaceholder = require("fetchanna.ui.coverplaceholder")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local LogUtil = require("fetchanna.util.logutil")
local Guard = require("fetchanna.util.guard")
local _ = require("gettext")

local COVER_SIZE = Screen:scaleBySize(100)
-- The cover column's width: a 2:3 cover as tall as COVER_SIZE. Covers are fitted inside it, so a wider one (as
-- many of Anna's Archive's are) is smaller, not drawn over the text.
local COVER_WIDTH = math.floor(COVER_SIZE * 2 / 3)

-- Returns the book's details and the site it was found on, where given.
local function formatBookDetails(book, site)
    return StringUtil.joinDetails(book.year, book.language, book.book_type, book.file_type, book.file_size, site)
end

local BookMenuItem = InputContainer:extend {}

function BookMenuItem:init()
    self.ges_events = {
        TapSelect = { GestureRange:new {
            ges = "tap",
            range = self.dimen,
        } },
    }
end

function BookMenuItem:onTapSelect(arg, ges)
    if not self[1].dimen then
        return
    end

    if G_reader_settings:isFalse("flash_ui") then
        self.menu:onMenuSelect(self.entry)
    else
        self[1].invert = true
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "fast", self[1].dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        self[1].invert = false
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "ui", self[1].dimen)

        self.menu:onMenuSelect(self.entry)
        UIManager:forceRePaint()
    end
    return true
end

-- is_downloaded(book), if set, says whether a book is already downloaded. source_name(book), if set, names its
-- site, to show in its details.
local BookMenu = Menu:extend {}

-- Whether KOReader's Menu has what the cover layout builds on. On older versions without it, the results were blank.
function BookMenu.isSupported()
    return Menu.setupItemHeights ~= nil
        and Menu._recalculateDimen ~= nil
        and Menu.updatePageInfo ~= nil
        and Menu.mergeTitleBarIntoLayout ~= nil
end

function BookMenu:onMenuSelect(entry)
    if entry and entry.callback then
        return entry.callback()
    end
    return true
end

function BookMenu:createBookItemWidget(book)
    -- The cover, a placeholder while it downloads, or an empty space so the books line up. Nothing when covers are off.
    local cover_widget
    local show_covers = FetchAnnaSettings:getShowBookCovers()
    if show_covers and CoverCache:cacheExists(book.id) then
        cover_widget = ImageWidget:new {
            file = CoverCache:get(book.id),
            width = COVER_WIDTH,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true,
        }
    elseif show_covers and CoverCache:isComing(book) then
        cover_widget = CoverPlaceholder.new(COVER_WIDTH, COVER_SIZE)
        -- So the page is redrawn once the cover arrives.
        self.awaited_covers = self.awaited_covers or {}
        self.awaited_covers[book.id] = book
    elseif show_covers then
        cover_widget = HorizontalSpan:new {
            width = COVER_WIDTH,
        }
    end

    -- The room for text beside the cover.
    local text_width = (self.inner_dimen or self.dimen).w - 2 * Size.padding.default - Size.padding.large
    if cover_widget then
        text_width = text_width - COVER_WIDTH
    end

    -- The title, on one line, with an ellipsis if it doesn't fit.
    local title_widget = TextWidget:new {
        max_width = text_width,
        face = Font:getFace("cfont", 18),
        text = book.display_title or "",
        bold = true,
    }

    -- The authors, likewise.
    local author_widget = TextWidget:new {
        max_width = text_width,
        face = Font:getFace("cfont", 15),
        text = book.authors or "",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- The details, then Downloaded in bold (see is_downloaded).
    local details = formatBookDetails(book, self.source_name and self.source_name(book))
    if self.is_downloaded and self.is_downloaded(book) then
        details = string.format(
            "%s%s%s%s%s",
            TextBoxWidget.PTF_HEADER,
            details ~= "" and details .. " · " or "",
            TextBoxWidget.PTF_BOLD_START,
            _("Downloaded"),
            TextBoxWidget.PTF_BOLD_END
        )
    end
    -- Wraps beside the cover, rather than running off the screen.
    local details_widget = TextBoxWidget:new {
        width = text_width,
        face = Font:getFace("cfont", 14),
        text = details,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Left-aligned, as the title and authors are only as wide as their text.
    local content_group = VerticalGroup:new {
        align = "left",
        title_widget,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        author_widget,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        details_widget,
    }

    local book_item
    if cover_widget then
        book_item = HorizontalGroup:new {
            CenterContainer:new {
                dimen = Geom:new {
                    w = COVER_WIDTH,
                    h = COVER_SIZE,
                },
                cover_widget,
            },
            HorizontalSpan:new {
                width = Size.padding.large,
            },
            content_group,
        }
    else
        book_item = HorizontalGroup:new {
            HorizontalSpan:new {
                width = Size.padding.large,
            },
            content_group,
        }
    end

    local framed_item = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = Size.padding.default,
        book_item,
    }

    return framed_item
end

function BookMenu:onGotoPage(page)
    local result = Menu.onGotoPage(self, page)

    if self.onPageChange then
        self.onPageChange(page)
    end

    return result
end

function BookMenu:getNumberBooksPerPage()
    return math.floor(self.available_height / (COVER_SIZE * 5 / 4))
end

function BookMenu:setupItemHeights()
    if #self.item_table == 0 then
        self.page_items = { {} }
        return
    end

    self.page_items = {}
    local items = {}
    local items_per_page = self:getNumberBooksPerPage()

    for i = 1, #self.item_table do
        local item = self.item_table[i]
        item.height = COVER_SIZE

        table.insert(items, i)

        if #items > items_per_page then
            table.insert(self.page_items, items)
            items = {}
        end
    end

    -- The remaining items make the last page.
    if #items > 0 then
        table.insert(self.page_items, items)
    end
end

function BookMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.awaited_covers = {}
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)

    if not self.page_items or not self.page_items[self.page] then
        return
    end

    local items_nb = #self.page_items[self.page]

    for idx = 1, items_nb do
        local index = self.page_items[self.page][idx]
        local item = self.item_table[index]
        if item == nil then
            break
        end

        item.idx = index

        if index == self.itemnumber then
            select_number = idx
        end

        local item_widget
        if item.book then
            item_widget = self:createBookItemWidget(item.book)
        elseif item.text then
            local text_widget = TextWidget:new {
                text = item.text,
                face = Font:getFace("cfont", 20),
                bold = true,
            }

            item_widget = FrameContainer:new {
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                CenterContainer:new {
                    dimen = Geom:new {
                        w = self.dimen.w,
                        h = item.height - 2 * Size.padding.default,
                    },
                    text_widget,
                },
            }
        end

        if item_widget then
            local menu_item = BookMenuItem:new {
                menu = self,
                entry = item,
                dimen = Geom:new {
                    w = self.inner_dimen.w,
                    h = item.height,
                },
                item_widget,
            }
            table.insert(self.item_group, menu_item)
            table.insert(self.layout, { menu_item })
        end
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)
end

-- Returns the books on a page whose covers haven't been downloaded.
function BookMenu:booksWithoutCovers(page)
    local items_per_page = self:getNumberBooksPerPage() + 1
    local start_idx = (page - 1) * items_per_page + 1
    local end_idx = math.min(start_idx + items_per_page - 1, #self.item_table)

    local books = {}
    for idx = start_idx, end_idx do
        local item = self.item_table[idx]
        if item and item.book and item.book.image_url and not CoverCache:cacheExists(item.book.id) then
            table.insert(books, item.book)
        end
    end
    return books
end

function BookMenu:loadCoversForPage(current_page)
    local items_per_page = self:getNumberBooksPerPage() + 1

    -- Then gets the next page's covers, so they're there when it's turned to.
    local function loadNextPage()
        -- Unless the page has been turned since, or the menu has closed.
        if self.page ~= current_page or self.closed then
            return
        end
        local next_books = self:booksWithoutCovers(current_page + 1)
        if #next_books > 0 then
            LogUtil.debug("downloading", #next_books, "covers for the next page")
            CoverCache:downloadMultiple(next_books, items_per_page)
        end
    end

    local books_to_download = self:booksWithoutCovers(current_page)
    if #books_to_download > 0 then
        -- All at once, in parallel, in the background.
        LogUtil.debug("downloading", #books_to_download, "covers in parallel")
        if CoverCache:downloadMultiple(books_to_download, items_per_page, loadNextPage) then
            return
        end
    end
    -- Nothing to download for this page, or it's downloading already.
    loadNextPage()
end

function BookMenu:onCloseWidget()
    self.closed = true
    return Menu.onCloseWidget(self)
end

-- Redraws once any of this page's covers has downloaded or been given up on. Covers for other pages are ignored,
-- as covers arrive several times a page. KOReader doesn't catch errors here, so they're only logged (see Guard).
BookMenu.onFetchAnnaCoversDownloaded = Guard.wrap("showing the covers that arrived", function(self)
    for __, book in pairs(self.awaited_covers or {}) do
        if not CoverCache:isComing(book) then
            self:updateItems()
            return
        end
    end
end, Guard.quiet)

return BookMenu
