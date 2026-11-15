local util = require("util")
local HttpUtil = require("fetchanna.util.httputil")
local LogUtil = require("fetchanna.util.logutil")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local SearchCache = require("fetchanna.cache.searchcache")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local AnnasAccount = require("fetchanna.api.annasaccount")
local AnnasParser = require("fetchanna.api.annasparser")
local Errors = require("fetchanna.util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- Searches Anna's Archive as the logged-in account (see AnnasAccount), on the sites trusted with the key (see
-- AnnasMirrors), as its search page does for a member's browser (see docs/annas-protocol.md).
-- Only members whose membership skips the browser check can search without one. FetchAnna never tries to get past it,
-- and says so instead (see Errors.ANNAS_BLOCKED). See Sources for the fields.
local AnnasSearch = {
    NAME = "Anna's Archive",
    SOURCE = "annas",
    -- Searching needs the key (see AccountPage).
    NEEDS_KEY = true,
    -- Saved searches are only shown again by the AnnasParser version that read them (see SearchCache).
    CACHE_VERSION = 1,
    -- Download links are signed: each downloads its book by itself until it expires, two hours after it was given (see
    -- docs/annas-protocol.md). They're never logged or put on curl's command line (see Downloader).
    SECRET_LINKS = true,
    LINKS_EXPIRE = true,
    -- When a link stops working or its server fails, one more is asked for, from another server (see findDownloadLink).
    -- That's free, as the book has just been downloaded.
    NEW_LINK_WHEN_SERVER_FAILS = true,
}

local FAILURE = AnnasMirrors.FAILURE

-- How old a session is before a browser check in place of results may mean the session is no longer taken. Then
-- FetchAnna logs in again and asks once more. With a newer session, the account can't search (or has used up this
-- hour), and asking again would only count against it.
local SESSION_RECHECK_AGE = 60 * 60
-- How long the member API's last count of fast downloads is shown for. They're counted by the day.
local ALLOWANCE_SHOWN_FOR = 12 * 60 * 60

-- The download server each book's link was last asked from, by md5 (see findDownloadLink).
local download_servers = {}

-- Returns the path and query of a search for query, from the given results page. Languages are left out when all are
-- chosen, which searches any.
function AnnasSearch.searchPath(query, page, languages, file_types)
    local params = { "q=" .. util.urlEncode(query) }
    if #languages < #FetchAnnaSettings:getAvailableLanguages() then
        for __, code in ipairs(languages) do
            table.insert(params, "lang=" .. util.urlEncode(code))
        end
    end
    for __, file_type in ipairs(file_types) do
        table.insert(params, "ext=" .. util.urlEncode(file_type))
    end
    if page > 1 then
        table.insert(params, "page=" .. tostring(page))
    end
    return "/search?" .. table.concat(params, "&")
end

-- Returns origin's page of results as AnnasParser reads it, logged in there, or nil, a FAILURE and details, as an
-- AnnasMirrors:run attempt does.
local function searchOn(origin, path, page)
    if not AnnasAccount:sessionCookie(origin) then
        local ok, failure, info = AnnasAccount:loginAt(origin)
        if not ok then
            return nil, failure, info
        end
    end
    local logged_in_again = false
    while true do
        local body, err, status, headers = HttpUtil.getBody(origin .. path, {
            cookies = AnnasAccount:sessionCookie(origin),
            follow_redirects = false,
        })
        local parsed, why
        if body and status == 200 then
            parsed, why = AnnasParser.parseResults(body, page)
            if parsed then
                return parsed
            end
        end
        local failure, info
        if why == AnnasParser.TIMED_OUT then
            failure, info = FAILURE.SERVER, { detail = "its search gave up" }
        elseif why == AnnasParser.UNRECOGNIZED then
            LogUtil.warn("Anna's Archive answered a search with a page that isn't results:", LogUtil.excerpt(body))
            failure, info = FAILURE.UNEXPECTED, { detail = "not a page of results" }
        else
            failure, info = AnnasMirrors.classify(body, err, status, headers)
        end
        -- An old session may no longer be taken, which is also answered with the browser check, so it's swapped for a
        -- new one, once.
        local made_at = AnnasAccount:sessionMadeAt(origin)
        if
            failure == FAILURE.CHALLENGE
            and not logged_in_again
            and (not made_at or os.time() - made_at >= SESSION_RECHECK_AGE)
        then
            LogUtil.info(
                "Anna's Archive asked for a browser check, so logging in on",
                origin,
                "again to see if that's why"
            )
            logged_in_again = true
            AnnasAccount:dropSession(origin)
            local ok, login_failure, login_info = AnnasAccount:loginAt(origin)
            if not ok then
                return nil, login_failure, login_info
            end
        else
            return nil, failure, info
        end
    end
end

-- Returns the error for a search no site could do (see AnnasMirrors:run), as the search box says it (see
-- FetchAnna:explainFailure and FetchAnna:fixes).
function AnnasSearch.errorFor(outcome)
    local failure = outcome.failure
    if failure == FAILURE.CANCELLED then
        return HttpUtil.CANCELLED
    elseif failure == FAILURE.CHALLENGE then
        return Errors.ANNAS_BLOCKED
    elseif failure == FAILURE.INVALID_KEY then
        return Errors.ANNAS_KEY_REJECTED
    elseif failure == FAILURE.UNEXPECTED then
        return Errors.UNREADABLE
    elseif failure == FAILURE.UNRESOLVED and not outcome.mixed then
        return Errors.ANNAS_UNFOUND
    end
    -- Without its full stop, as it's said after "Search failed:".
    return (AnnasMirrors.describe(outcome):gsub("%.$", ""))
end

-- Returns a page of results as search does.
local function fetchPage(query, page, languages, file_types)
    if #file_types == 0 then
        return nil, Errors.NO_FILE_TYPES
    end
    if not AnnasAccount:hasKey() then
        return nil, Errors.ANNAS_NO_KEY
    end
    AnnasMirrors:ensureDiscovery()

    local path = AnnasSearch.searchPath(query, page, languages, file_types)
    local result, outcome = AnnasMirrors:run(AnnasMirrors.SEARCH, function(origin)
        return searchOn(origin, path, page)
    end, { stop_on = { [FAILURE.CHALLENGE] = true } })
    if not result then
        return nil, AnnasSearch.errorFor(outcome)
    end

    -- Only the chosen file types, in case Anna's Archive didn't narrow to them, and only those KOReader can open.
    local chosen = {}
    for __, file_type in ipairs(file_types) do
        chosen[file_type] = true
    end
    local books = {}
    for __, book in ipairs(result.books) do
        if chosen[book.file_type] and FetchAnnaSettings:isOpenableFileType(book.file_type) then
            table.insert(books, book)
        end
    end
    LogUtil.info(
        string.format(
            "page %d of Anna's Archive's results: kept %d of its %d%s",
            page,
            #books,
            result.results,
            result.next_page and "" or ", the last"
        )
    )
    return books, nil, result.next_page, result.results
end

-- Whether the page is saved from an earlier search, so it can be shown offline.
function AnnasSearch:isCached(query, page)
    return SearchCache:hasPage(self, query, page)
end

-- Searches the given results page. Returns the books, an error, the next page (nil at the end) and how many results
-- were read (see MultiSearch.start).
function AnnasSearch:search(query, page)
    return SearchCache:search(self, query, page, nil, function(languages, file_types)
        return fetchPage(query, page, languages, file_types)
    end)
end

-- Returns the error for a download link that couldn't be had (see AnnasAccount:fastDownload), said after "Download
-- failed:" (see FetchAnna:fixes).
function AnnasSearch.downloadErrorFor(outcome)
    local failure = outcome.failure
    if failure == FAILURE.NOT_MEMBER then
        return Errors.ANNAS_NOT_MEMBER
    elseif failure == FAILURE.QUOTA then
        return Errors.ANNAS_NO_DOWNLOADS_LEFT
    elseif failure == FAILURE.NOT_FOUND then
        return Errors.ANNAS_FILE_GONE
    elseif outcome.may_have_counted and failure ~= FAILURE.CANCELLED and failure ~= FAILURE.INVALID_KEY then
        return Errors.ANNAS_LINK_TIMED_OUT
    end
    return AnnasSearch.errorFor(outcome)
end

-- Returns a book's download link from the member API (see AnnasAccount:fastDownload), nil, false, and its md5 to check
-- the download against, as Downloader takes them (see Sources). Returns nil, an error and false otherwise.
-- When the last link failed (failed_url), asks for one from the next download server: changing the server in a signed
-- link would only spoil it.
-- The third result is always false, so Downloader never asks the sites again straight away. AnnasMirrors:run has tried
-- each it can, and one that timed out may have counted the download.
function AnnasSearch.findDownloadLink(book, retrying, failed_url)
    local md5 = type(book) == "table" and type(book.md5) == "string" and book.md5:lower() or nil
    if not AnnasAccount.isMd5(md5) then
        LogUtil.warn("the book has no md5 to ask Anna's Archive for it by:", tostring(md5))
        return nil, Errors.UNEXPECTED, false
    end
    if not AnnasAccount:hasKey() then
        return nil, Errors.ANNAS_NO_KEY, false
    end
    AnnasMirrors:ensureDiscovery()

    local domain_index
    if failed_url then
        domain_index = (download_servers[md5] or 0) + 1
        LogUtil.info("asking Anna's Archive for a link to its download server", domain_index, "instead")
    end
    local answer, outcome = AnnasAccount:fastDownload(md5, domain_index)
    if not answer and domain_index and outcome.failure == FAILURE.UNAVAILABLE then
        LogUtil.info("Anna's Archive has no download server", domain_index, "so leaving it to choose one")
        domain_index = nil
        answer, outcome = AnnasAccount:fastDownload(md5)
    end
    if not answer then
        return nil, AnnasSearch.downloadErrorFor(outcome), false
    end
    download_servers[md5] = domain_index or 0
    return answer.download_url, nil, false, { md5 = md5 }
end

-- Returns the md5, in lower case, that text is or links to (a file's page is ".../md5/" and its md5), or nil. It's for
-- downloading a book found in a browser (see FetchAnna:downloadByMd5).
-- Only the md5 is taken from a link. The link is never followed, as it could go anywhere.
function AnnasSearch.md5From(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local md5 = text:match("^(%x+)$") or text:match("^[Mm][Dd]5:(%x+)$")
    if not md5 then
        local rest
        md5, rest = text:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/%s]+/md5/(%x+)(.*)$")
        if rest and rest ~= "" and not rest:find("^[/?#]") then
            md5 = nil
        end
    end
    return md5 and #md5 == 32 and md5:lower() or nil
end

-- Returns how many fast downloads are left, as the member API last said within ALLOWANCE_SHOWN_FOR, for DownloadPrompt.
-- nil when unknown.
function AnnasSearch.allowance(now)
    local status = AnnasAccount:status()
    local left, checked_at = tonumber(status.downloads_left), tonumber(status.downloads_checked_at)
    if not left or not checked_at or (now or os.time()) - checked_at > ALLOWANCE_SHOWN_FOR then
        return nil
    end
    local per_day = tonumber(status.downloads_per_day)
    return per_day and T(_("%1 of %2 a day left"), left, per_day) or T(_("%1 left"), left)
end

return AnnasSearch
