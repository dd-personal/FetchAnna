local Trapper = require("ui/trapper")
local Sources = require("fetchanna.api.sources")
local HttpUtil = require("fetchanna.util.httputil")
local Guard = require("fetchanna.util.guard")
local Errors = require("fetchanna.util.errors")

-- Searches several sites at once (see Sources), each in its own coroutine (see Trapper), so each one's books show as
-- soon as they're found.
-- With KOReader's own HTTP, which blocks until a page arrives, the sites are searched one after another, and KOReader
-- shows what's been found in between.
local MultiSearch = {}
MultiSearch.__index = MultiSearch

-- The sites, in the order they're offered and searched.
MultiSearch.SOURCES = { "annas" }

-- Whether the site can narrow a search to scope, e.g. "author" (see SCOPES in Sources).
function MultiSearch.canNarrow(source, scope)
    for __, site_scope in ipairs(Sources[source].SCOPES or {}) do
        if site_scope == scope then
            return true
        end
    end
    return false
end

-- Whether every site's page (see start) is saved from an earlier search, so it can be shown offline.
function MultiSearch.isCached(query, pages, scope)
    for source, page in pairs(pages) do
        if not Sources[source]:isCached(query, page, MultiSearch.canNarrow(source, scope) and scope or nil) then
            return false
        end
    end
    return true
end

-- Searches the sites in pages (the results page to start from, by site, e.g. { annas = 1 }) for query, narrowed to
-- scope where a site can (see canNarrow).
-- Calls handlers.on_result(source, books, err, next_page, results_read) as each site finishes (see AnnasSearch:search),
-- then handlers.on_done(). handlers.on_status(text), where given, gets what a search is waiting for (see
-- HttpUtil.sayStatus).
-- Returns the search, which cancel calls off.
function MultiSearch.start(query, pages, scope, handlers)
    local search = setmetatable({
        query = query,
        pages = pages,
        scope = scope,
        handlers = handlers,
        -- Sites being searched, sites not started, and what calls each search off (see searchSite).
        pending = {},
        queue = {},
        traps = {},
    }, MultiSearch)
    for __, source in ipairs(MultiSearch.SOURCES) do
        if pages[source] then
            search.pending[source] = true
            table.insert(search.queue, source)
        end
    end
    if #search.queue == 0 then
        Guard.nextTick("finishing a search of no sites", handlers.on_done)
        return search
    end
    -- All at once where waiting doesn't block KOReader, otherwise one after another (see finish).
    repeat
        search:startNext()
    until #search.queue == 0 or not HttpUtil.canCancel()
    return search
end

-- Starts the next site, once KOReader has shown what's been found so far.
function MultiSearch:startNext()
    local source = table.remove(self.queue, 1)
    if not source then
        return
    end
    Guard.nextTick("starting a search of " .. Sources[source].NAME, function()
        self:searchSite(source)
    end, function(err)
        self:finish(source, nil, err)
    end)
end

function MultiSearch:searchSite(source)
    if self.cancelled then
        self:finish(source, nil, HttpUtil.CANCELLED)
        return
    end
    local site = Sources[source]
    local handlers = self.handlers
    -- Stands in for the "searching" message, and is told what the search is waiting for. Trapper puts each wait's way
    -- to be called off on the widget it waits with, and the message's Cancel calls them all (see cancel).
    local trap = {
        setStatus = function(__, status)
            if status and handlers.on_status then
                handlers.on_status(status)
            end
        end,
    }
    self.traps[source] = trap
    local what = string.format("search of %s for %q", site.NAME, self.query)
    Trapper:wrap(Guard.wrap(what, function()
        HttpUtil.setTrapWidget(trap)
        local scope = MultiSearch.canNarrow(source, self.scope) and self.scope or nil
        local ok, books, err, next_page, results_read =
            Guard.pcall(what, site.search, site, self.query, self.pages[source], scope)
        HttpUtil.setTrapWidget(nil)
        if not ok then
            books, err, next_page, results_read = nil, Errors.UNEXPECTED, nil, nil
        end
        self:finish(source, books, err, next_page, results_read)
    end, function(err)
        HttpUtil.setTrapWidget(nil)
        self:finish(source, nil, err)
    end))
end

-- Passes on what the site found, or why it didn't, and starts the next site where they go one after another.
function MultiSearch:finish(source, books, err, next_page, results_read)
    if not self.pending[source] then
        return
    end
    self.pending[source] = nil
    -- The wait is over, so it mustn't be called off again. Trapper leaves its dismiss_callback on the stand-in.
    if self.traps[source] then
        self.traps[source].dismiss_callback = nil
    end
    Guard.call("showing what a search found", self.handlers.on_result, nil, source, books, err, next_page, results_read)
    if next(self.pending) == nil then
        Guard.call("finishing a search", self.handlers.on_done)
    else
        self:startNext()
    end
end

-- Returns the sites still being searched, in the order they're offered.
function MultiSearch:pendingSources()
    local sources = {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        if self.pending[source] then
            table.insert(sources, source)
        end
    end
    return sources
end

function MultiSearch:isDone()
    return next(self.pending) == nil
end

-- Calls off the searches still going, as the message's Cancel does. Once stopped, each reports HttpUtil.CANCELLED, or
-- what it had found by then (as Library Genesis does, from the pages it had read). So do those not started.
function MultiSearch:cancel()
    if self.cancelled then
        return
    end
    self.cancelled = true
    for source, trap in pairs(self.traps) do
        if self.pending[source] then
            trap.cancelled = true
            if trap.dismiss_callback then
                trap.dismiss_callback()
            end
        end
    end
end

return MultiSearch
