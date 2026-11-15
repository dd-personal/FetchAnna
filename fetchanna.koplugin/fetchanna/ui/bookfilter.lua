local Sources = require("fetchanna.api.sources")
local MultiSearch = require("fetchanna.api.multisearch")
local StringUtil = require("fetchanna.util.stringutil")
local T = require("ffi/util").template
local _ = require("gettext")

-- Filters for the books found, applied without searching again. Each lists the books' values, to untick those to
-- hide (see FetchAnna:chooseShown). What's hidden is kept as unticked values by filter id, e.g.
-- { language = { french = true } }, so books that arrive afterwards with other values are shown.
local BookFilter = {}

-- The value of a book that doesn't say, e.g. one with no language.
local UNKNOWN = ""
local function unknown()
    return { code = UNKNOWN, text = _("Unknown") }
end

-- Returns the site's place among those offered, for listing in that order.
local function siteRank(code)
    for i, source in ipairs(MultiSearch.SOURCES) do
        if source == code then
            return i
        end
    end
    return #MultiSearch.SOURCES + 1
end

-- Most common first, then by name, with Unknown last.
local function byCount(a, b)
    if (a.code == UNKNOWN) ~= (b.code == UNKNOWN) then
        return b.code == UNKNOWN
    end
    if a.count ~= b.count then
        return a.count > b.count
    end
    return a.text < b.text
end

-- Returns a sort by first(a.code, b.code), with Unknown last.
local function inOrder(first)
    return function(a, b)
        if (a.code == UNKNOWN) ~= (b.code == UNKNOWN) then
            return b.code == UNKNOWN
        end
        return first(a.code, b.code)
    end
end

-- Returns a size in bytes from a site's text, e.g. Z-Library's "2.06 MB" or Library Genesis' "752 kB", or nil.
local UNITS = { [""] = 1, k = 1024, m = 1024 * 1024, g = 1024 * 1024 * 1024 }
local function bytes(size)
    local number, unit = tostring(size or ""):lower():match("^%s*([%d%.]+)%s*([kmg]?)i?b%s*$")
    number = tonumber(number)
    return number and number > 0 and number * UNITS[unit] or nil
end

-- The size bands: each holds books smaller than below, the last all the rest.
local SIZES = {
    { code = "1", below = bytes("1 MB"), text = _("Under 1 MB") },
    { code = "2", below = bytes("10 MB"), text = _("1 to 10 MB") },
    { code = "3", below = bytes("100 MB"), text = _("10 to 100 MB") },
    { code = "4", text = _("Over 100 MB") },
}

-- Returns the value for a name, so that sites' spellings (e.g. Z-Library's "english") match, or Unknown.
local function named(text)
    text = text and StringUtil.trim(text)
    if not text or text == "" then
        return unknown()
    end
    return { code = text:lower(), text = (text:gsub("^%l", string.upper)) }
end

-- Each has an id, a name, valuesOf(book) (a book is shown where any of its values is) and, where the order isn't
-- byCount, before.
BookFilter.FILTERS = {
    {
        id = "site",
        name = _("Sites"),
        valuesOf = function(book)
            local site = Sources[book.source]
            return { site and { code = book.source, text = site.NAME } or unknown() }
        end,
        before = function(a, b)
            return siteRank(a.code) < siteRank(b.code)
        end,
    },
    {
        id = "language",
        name = _("Languages"),
        -- Several at once, e.g. Internet Archive's "English, Latin".
        valuesOf = function(book)
            local values = {}
            for name in (book.language or ""):gmatch("[^,;/]+") do
                if StringUtil.trim(name) ~= "" then
                    table.insert(values, named(name))
                end
            end
            return #values > 0 and values or { unknown() }
        end,
    },
    {
        id = "file_type",
        name = _("File types"),
        valuesOf = function(book)
            return { book.file_type and { code = book.file_type:lower(), text = book.file_type:upper() } or unknown() }
        end,
    },
    {
        id = "book_type",
        name = _("Book types"),
        -- Only Library Genesis sorts its books into types.
        valuesOf = function(book)
            return { named(book.book_type) }
        end,
    },
    {
        id = "year",
        name = _("Years"),
        -- By decade, e.g. the 1990s.
        valuesOf = function(book)
            local year = tonumber(tostring(book.year or ""):match("^%d%d%d%d$"))
            if not year or year == 0 then
                return { unknown() }
            end
            local decade = tostring(year - year % 10)
            return { { code = decade, text = T(_("%1s"), decade) } }
        end,
        -- Latest first.
        before = inOrder(function(a, b)
            return a > b
        end),
    },
    {
        id = "size",
        name = _("Sizes"),
        -- Only Library Genesis and Z-Library give sizes.
        valuesOf = function(book)
            local size = bytes(book.file_size)
            if not size then
                return { unknown() }
            end
            for __, band in ipairs(SIZES) do
                if not band.below or size < band.below then
                    return { band }
                end
            end
        end,
        -- Smallest first.
        before = inOrder(function(a, b)
            return a < b
        end),
    },
    {
        id = "downloaded",
        name = _("Downloaded"),
        -- Fixed, as telling which the books have means looking in the download folder, only done when asked.
        fixed = { { code = "yes", text = _("Yes") }, { code = "no", text = _("No") } },
        valuesOf = function(book, is_downloaded)
            return { { code = is_downloaded(book) and "yes" or "no" } }
        end,
    },
}

-- Returns the filter's values among the books, in listing order, each { code, text, count }. is_downloaded(book)
-- says whether a book is in the download folder.
function BookFilter.values(books, filter, is_downloaded)
    local values, by_code = {}, {}
    local function add(value)
        by_code[value.code] = { code = value.code, text = value.text, count = 0 }
        table.insert(values, by_code[value.code])
    end
    for __, value in ipairs(filter.fixed or {}) do
        add(value)
    end
    for __, book in ipairs(books) do
        local counted = {}
        for __, value in ipairs(filter.valuesOf(book, is_downloaded)) do
            if not counted[value.code] then
                counted[value.code] = true
                if not by_code[value.code] then
                    add(value)
                end
                by_code[value.code].count = by_code[value.code].count + 1
            end
        end
    end
    if not filter.fixed then
        table.sort(values, filter.before or byCount)
    end
    return values
end

-- Whether to offer the filter: when the books' values differ, or always when its values are fixed.
function BookFilter.isOffered(filter, values)
    return filter.fixed ~= nil or #values > 1
end

-- Returns the codes hidden ({ code = true }) when only those in shown are ticked, or nil if none are.
function BookFilter.hiding(values, shown)
    local ticked = {}
    for __, code in ipairs(shown) do
        ticked[code] = true
    end
    local hidden
    for __, value in ipairs(values) do
        if not ticked[value.code] then
            hidden = hidden or {}
            hidden[value.code] = true
        end
    end
    return hidden
end

-- Whether the book is shown: for each filter with hidden values, it has one that isn't hidden.
function BookFilter.isShown(book, hidden, is_downloaded)
    for __, filter in ipairs(BookFilter.FILTERS) do
        local hidden_values = hidden[filter.id]
        if hidden_values then
            local shown = false
            for __, value in ipairs(filter.valuesOf(book, is_downloaded)) do
                if not hidden_values[value.code] then
                    shown = true
                    break
                end
            end
            if not shown then
                return false
            end
        end
    end
    return true
end

-- Whether anything is hidden.
function BookFilter.isHiding(hidden)
    return next(hidden) ~= nil
end

-- Returns the filter's button text: All, or the values shown, e.g. "English, French".
function BookFilter.describe(values, hidden_values)
    if not hidden_values then
        return _("All")
    end
    local names = {}
    for __, value in ipairs(values) do
        if not hidden_values[value.code] then
            table.insert(names, value.text)
        end
    end
    return table.concat(names, ", ")
end

return BookFilter
