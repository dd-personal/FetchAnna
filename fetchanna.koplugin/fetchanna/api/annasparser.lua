local StringUtil = require("fetchanna.util.stringutil")
local LogUtil = require("fetchanna.util.logutil")

-- Reads Anna's Archive's search results pages, as sent to a logged-in member in the default list view (see
-- docs/annas-protocol.md and spec/data/annas/search-results-member.html).
-- Only the first list on the page is read. A second has partial matches, and a bar above it has the site's recent
-- downloads.
-- Each book is found by the link to its page (/md5/ and the file's md5, its identity). Fields are found by what they
-- are, not by layout: the title by the js-vim-focus link, the author and publisher by their icons, and the rest from
-- the details line under them.
-- Nothing on the page is ever run.
local AnnasParser = {}

-- Why a page isn't a page of results.
AnnasParser.CHALLENGE = "challenge"
AnnasParser.TIMED_OUT = "timed_out"
AnnasParser.UNRECOGNIZED = "unrecognized"

local LIST_MARKER = 'class="js-aarecord-list-outer"'
-- The most pages Anna's Archive has for a search, and the most bytes of a page that are read.
AnnasParser.MAX_PAGES = 100
local MAX_PAGE_BYTES = 8 * 1024 * 1024
-- Separates the fields on a result's details line (a middle dot).
local SEPARATOR = "\194\183"

-- Returns html as one line of text, without tags or entities.
local function text(html)
    if type(html) ~= "string" then
        return ""
    end
    local plain = StringUtil.convertHtmlToText(html:gsub("<[^>]+>", " "))
    plain = plain:gsub("&nbsp;", " "):gsub("\194\160", " ")
    return StringUtil.trim(StringUtil.collapseWhitespace(plain))
end

-- Whether a page is a browser check (DDoS-Guard's, which Anna's Archive is behind, or Cloudflare's). FetchAnna never
-- tries to get past one. Not "/cdn-cgi/challenge-platform/" alone: Cloudflare adds its bot-detection script, from
-- there, to ordinary pages too, such as SLUM's (see spec/data/annas/cloudflare-jsd-beacon.html).
function AnnasParser.isChallenge(body)
    return type(body) == "string"
        and (
            body:find("check.ddos-guard.net", 1, true) ~= nil
            or body:find("<title>DDoS%-Guard</title>") ~= nil
            or body:find("Checking your browser", 1, true) ~= nil
            or body:find("cf-chl", 1, true) ~= nil
            or body:find("_cf_chl_opt", 1, true) ~= nil
            or body:find("/cdn-cgi/challenge-platform/h/", 1, true) ~= nil
        )
end

-- Whether the page is Anna's Archive's search page, going by its search form.
function AnnasParser.isSearchPage(html)
    return html:find('<form[^>]-action="/search"') ~= nil and html:find('name="q"', 1, true) ~= nil
end

-- Returns the page's own results: from the first list up to a second (partial matches) or the pagination.
local function primaryList(html)
    local start = html:find(LIST_MARKER, 1, true)
    if not start then
        return nil
    end
    local finish = html:find(LIST_MARKER, start + #LIST_MARKER, true)
        or html:find('aria-label="Pagination"', start, true)
        or #html + 1
    return html:sub(start, finish - 1)
end

-- Returns the results in the list. Each runs from the first link to a book's page to the first link to the next book's.
local function resultsIn(list)
    local results = {}
    local position = 1
    while true do
        local start, finish, md5 = list:find('href="[^"]-/md5/(%x+)"', position)
        if not start then
            break
        end
        local last = results[#results]
        if last and last.md5 == md5:lower() then
            position = finish + 1
        else
            if last then
                last.html = list:sub(last.start, start - 1)
            end
            table.insert(results, { md5 = md5:lower(), start = start })
            position = finish + 1
        end
    end
    if #results > 0 then
        results[#results].html = list:sub(results[#results].start)
    end
    return results
end

-- Returns the text of the first link in html whose tag or contents match pattern.
local function linkText(html, pattern)
    for tag, inner in html:gmatch("<a([^>]*)>(.-)</a>") do
        if tag:find(pattern) or inner:find(pattern) then
            return text(inner)
        end
    end
end

-- Reads a result's details line, e.g. "English [en] · EPUB · 0.6MB · 2024 · 📕 Book (fiction) · 🚀/lgli/zlib". Any field
-- can be missing.
local function readDetails(line)
    local details = {}
    for part in (line .. SEPARATOR):gmatch("(.-)" .. SEPARATOR) do
        part = StringUtil.trim(part)
        if part:find("%[[%a%-]+%]") and not details.language then
            local names, codes = {}, {}
            for name, code in part:gmatch("([^,%[]-)%s*%[([%a%-]+)%]") do
                name = StringUtil.trim(name)
                table.insert(names, name ~= "" and name or code)
                table.insert(codes, code:lower())
            end
            details.language = table.concat(names, ", ")
            details.language_codes = codes
        elseif part:find("^[%u%d]+$") and #part <= 6 and not part:find("^%d+$") and not details.file_type then
            details.file_type = part:lower()
        elseif part:find("^%d+%.?%d*%s?[KMGT]?B$") and not details.file_size then
            details.file_size = part:gsub("^([%d%.]+)%s?([KMGT]?B)$", "%1 %2")
        elseif part:find("^%d%d%d%d$") and not details.year then
            details.year = part
        elseif part ~= "" and not part:find("/") and not details.book_type then
            -- The kind of book, after its emoji, e.g. "Book (fiction)".
            local kind = part:gsub("^[^%w]+", "")
            if kind ~= "" then
                details.book_type = kind
            end
        end
    end
    return details
end

-- Returns a book from a result, or nil and why it couldn't be read.
local function readResult(result)
    local html = result.html
    if not result.md5:find("^" .. string.rep("%x", 32) .. "$") then
        return nil, "its link isn't to a file's md5"
    end
    local raw_title = linkText(html, "js%-vim%-focus")
    local filename = text(html:match('<div class="[^"]*font%-mono[^"]*">(.-)</div>'))
    if not raw_title or raw_title == "" then
        -- The file's name, without its folder and extension.
        raw_title = filename:match("([^/]+)$")
        raw_title = raw_title and raw_title:gsub("%.%w+$", "")
    end
    local line = html:match('<div class="text%-gray%-800[^"]*"[^>]*>(.-)<a ')
        or html:match('<div class="text%-gray%-800[^"]*"[^>]*>(.-)</div>')
    local details = readDetails(text(line))
    if not raw_title or raw_title == "" or not details.file_type then
        return nil, "it has no title or file type"
    end

    local cover = html:match('<img[^>]-src="([^"]+)"')
    cover = cover and cover:gsub("&amp;", "&")
    local authors = linkText(html, "icon%-%[mdi%-%-user%-edit%]")
    local publisher = linkText(html, "icon%-%[mdi%-%-company%]")
    return {
        source = "annas",
        id = result.md5,
        md5 = result.md5,
        -- The book's page, on whichever site is in use when it's needed.
        detail_path = "/md5/" .. result.md5,
        title = StringUtil.cleanFileName(raw_title) ~= "" and StringUtil.cleanFileName(raw_title) or result.md5,
        display_title = StringUtil.cleanTitle(raw_title),
        authors = authors and authors ~= "" and authors or "Unknown author",
        publisher = publisher ~= "" and publisher or nil,
        year = details.year,
        language = details.language,
        language_codes = details.language_codes,
        file_type = details.file_type,
        -- As Anna's Archive rounds it, so not the size in bytes.
        file_size = details.file_size,
        book_type = details.book_type,
        filename = filename ~= "" and filename or nil,
        -- Shown without a cover rather than giving curl an unsafe URL.
        image_url = StringUtil.isSafeUrl(cover) and cover or nil,
    }
end

-- Returns the next page's number from the page's own link, when it goes forward.
local function nextPage(html, page)
    local href = html:match('<a href="([^"]*)" class="[^"]*js%-pagination%-next%-page')
    local next_page = href and tonumber(href:match("[?&;]page=(%d+)"))
    if next_page and next_page > page and next_page <= AnnasParser.MAX_PAGES then
        return next_page
    end
    if next_page then
        LogUtil.warn("Anna's Archive's link to the next page goes to page", next_page, "from page", page)
    end
    return nil
end

-- Returns { books, results (how many the page had), unreadable (how many couldn't be read), next_page (or nil) } for
-- results page number page, or nil and why it isn't a page of results (CHALLENGE, TIMED_OUT or UNRECOGNIZED).
-- A book's id is its file's md5, and it has the path of its page, not a URL on one site.
function AnnasParser.parseResults(html, page)
    if type(html) ~= "string" or #html > MAX_PAGE_BYTES then
        return nil, AnnasParser.UNRECOGNIZED
    end
    -- Anna's search form makes it a search page, whatever scripts a CDN has added to it.
    if not AnnasParser.isSearchPage(html) then
        return nil, AnnasParser.isChallenge(html) and AnnasParser.CHALLENGE or AnnasParser.UNRECOGNIZED
    end
    local list = primaryList(html)
    if not list then
        -- The search page without a list: Anna's Archive's search gave up.
        return nil, AnnasParser.TIMED_OUT
    end

    local results = resultsIn(list)
    if #results == 0 then
        -- No results, as Anna's Archive says, or its search gave up first, which it marks with a cross.
        local before_list = html:sub(1, html:find(LIST_MARKER, 1, true))
        local warning = before_list:match('<div class="mt%-4 px%-2">(.-)</div>')
        if warning and warning:find("\226\157\140") then
            return nil, AnnasParser.TIMED_OUT
        end
        return { books = {}, results = 0, unreadable = 0 }
    end

    local books, seen, unreadable = {}, {}, 0
    for __, result in ipairs(results) do
        local book, why = readResult(result)
        if not book then
            unreadable = unreadable + 1
            LogUtil.warn("couldn't read Anna's Archive's result for", result.md5, "as", why)
        elseif not seen[book.md5] then
            seen[book.md5] = true
            table.insert(books, book)
        end
    end
    if #books == 0 then
        LogUtil.warn("couldn't read any of the", #results, "results on Anna's Archive's page")
        return nil, AnnasParser.UNRECOGNIZED
    end
    return {
        books = books,
        results = #results,
        unreadable = unreadable,
        next_page = nextPage(html, page),
    }
end

return AnnasParser
