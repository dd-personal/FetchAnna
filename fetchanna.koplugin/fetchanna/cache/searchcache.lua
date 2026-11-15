local FetchAnnaCache = require("fetchanna.cache.cache")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local LogUtil = require("fetchanna.util.logutil")

local SearchCache = FetchAnnaCache:new {
    filename = "fetchanna_searchcache.lua",
    expiry = function()
        return FetchAnnaSettings:getSearchCacheExpiryDays() * 24 * 60 * 60
    end,
    -- Each search is around 25KB, and the whole cache is read and written at once.
    max_entries = 100,

    -- The site searched (see Sources), as each finds different books, and the scope, if any (e.g. only authors).
    -- Searches without a scope keep their old keys.
    makeKey = function(...)
        LogUtil.debug("data for makeKey:", ...)
        local source, query, page, languages, file_types, book_types, scope = ...

        local parts = {
            source,
            query,
            tostring(page),
            table.concat(languages, ","),
            table.concat(file_types, ","),
            table.concat(book_types, ","),
        }
        if scope then
            table.insert(parts, scope)
        end
        return table.concat(parts, "|")
    end,
}

-- Returns the languages and file types chosen in the settings, then the book types. No site has book types any
-- more, but they stay in the key so that saved searches are still found.
local function choices()
    return FetchAnnaSettings:getPreferredLanguages(), FetchAnnaSettings:getPreferredFileTypes(), {}
end

-- Returns the name a site's searches are saved under: its own, with CACHE_VERSION if it has one (see Sources), so
-- results read by an older parser aren't shown.
local function keyOf(site)
    return site.CACHE_VERSION and site.SOURCE .. "#" .. tostring(site.CACHE_VERSION) or site.SOURCE
end

-- Whether a page of site's results is saved, to show offline.
function SearchCache:hasPage(site, query, page, scope)
    local languages, file_types, book_types = choices()
    local cached = self:get(keyOf(site), query, page, languages, file_types, book_types, scope)
    return cached ~= nil and cached.books ~= nil
end

-- Searches site from the given page, within scope if given. Returns what fetch(languages, file_types, book_types)
-- does: the books, or nil and why not, then the next page (or nil) and how many results were read. Saved books
-- are returned instead where there are any, with no count. Otherwise the books found are saved.
function SearchCache:search(site, query, page, scope, fetch)
    local languages, file_types, book_types = choices()
    LogUtil.info(
        string.format(
            "searching %s for %q%s from page %d, in %s, as %s",
            site.NAME,
            query,
            scope and " by " .. scope or "",
            page,
            table.concat(languages, "/"),
            table.concat(file_types, "/")
        )
    )

    local cached = self:get(keyOf(site), query, page, languages, file_types, book_types, scope)
    if cached and cached.books then
        LogUtil.info("showing", #cached.books, "books saved from an earlier search")
        return cached.books, nil, cached.next_page
    end

    local books, err, next_page, results_read = fetch(languages, file_types, book_types)
    -- Unless none were found, as the page may have been an error.
    if books and #books > 0 then
        self:set({
            books = books,
            next_page = next_page,
        }, keyOf(site), query, page, languages, file_types, book_types, scope)
    end
    return books, err, next_page, results_read
end

return SearchCache
