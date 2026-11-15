local util = require("util")

local StringUtil = {}

function StringUtil.assertValidString(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    return true
end

-- Joins the parts that are non-empty text with " · ", as a book's details are shown.
function StringUtil.joinDetails(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if StringUtil.assertValidString(part) then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, " · ")
end

function StringUtil.trim(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

function StringUtil.collapseWhitespace(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("%s+", " ")
end

function StringUtil.collapseDots(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("%.+", ".")
end

function StringUtil.collapseDashes(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("-+", "-")
end

function StringUtil.convertHtmlToText(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return util.htmlEntitiesToUtf8(text)
end

function StringUtil.removeParentheses(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    text = text:gsub("%s*%([^)]*%)", "") -- remove (...)
    text = text:gsub("%s*%[[^%]]*%]", "") -- remove [...]
    return text
end

-- Returns a title for showing on screen, without what Library Genesis adds in brackets (such as its series).
function StringUtil.cleanTitle(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    local title = StringUtil.trim(StringUtil.collapseWhitespace(StringUtil.removeParentheses(text)))
    -- Unless that's all there is of it.
    if title == "" then
        title = StringUtil.trim(StringUtil.collapseWhitespace(text))
    end
    return title
end

-- Whether text is a URL that can be passed on as it is. Sites are looked up on a page anyone can edit, so what one
-- sends can't be trusted: a line break or quote in a URL written to curl's config file would add options of its own,
-- such as where on the device to save a file.
function StringUtil.isSafeUrl(text)
    return type(text) == "string" and text:find('^https?://[^%c%s"\\]+$') ~= nil
end

local function safeFileName(text)
    text = text:gsub('[<>:"/\\|?*]', "-") -- replace invalid chars with dash
    text = text:gsub("^[%s%.]+", "") -- remove leading spaces/dots
    text = text:gsub("[%s%.]+$", "") -- remove trailing spaces/dots
    return StringUtil.collapseWhitespace(StringUtil.collapseDashes(StringUtil.collapseDots(text)))
end

-- Returns a title for naming a book's file, without what Library Genesis adds in brackets, unless that's all there is.
-- A title such as "[Poems]" would otherwise name the file ".epub", which is hidden, and the same for every such book.
-- "" only when there's nothing to name it after.
function StringUtil.cleanFileName(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    local name = safeFileName(StringUtil.removeParentheses(text))
    if name == "" then
        name = safeFileName(text)
    end
    return name
end

function StringUtil.replaceCarriageReturns(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    return text:gsub("\r\n", "\n")
end

return StringUtil
