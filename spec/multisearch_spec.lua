local helper = require("helper")

describe("MultiSearch", function()
    local MultiSearch, sites, searches, results, statuses, done, can_cancel

    -- A site whose searches wait, as curl's do (see Trapper:dismissablePopen), until answered (see answer) or called
    -- off.
    local function fakeSite(name, scopes)
        local site = { NAME = name, SCOPES = scopes }
        function site:search(query, page, scope)
            local waiting = coroutine.running()
            local trap = require("fetchanna.util.httputil").getTrapWidget()
            table.insert(searches, { site = name, query = query, page = page, scope = scope, trap = trap })
            trap.dismiss_callback = function()
                coroutine.resume(waiting, false)
            end
            site.answer = function(...)
                coroutine.resume(waiting, true, ...)
            end
            if site.status then
                trap:setStatus(site.status)
            end
            local answered, books, err, next_page, results_read = coroutine.yield()
            if not answered then
                return site.found_by_then, site.found_by_then == nil and "request cancelled" or nil
            end
            if site.fails then
                error("site went wrong")
            end
            return books, err, next_page, results_read
        end
        return site
    end

    local handlers = {
        on_result = function(source, books, err, next_page, results_read)
            table.insert(results, {
                source = source,
                books = books,
                err = err,
                next_page = next_page,
                results_read = results_read,
            })
        end,
        on_done = function()
            done = done + 1
        end,
        on_status = function(text)
            table.insert(statuses, text)
        end,
    }

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        searches, results, statuses, done, can_cancel = {}, {}, {}, 0, true
        -- Each search gets its own coroutine, as under KOReader's Trapper.
        helper.stub("ui/trapper", {
            wrap = function(_, fn)
                assert(coroutine.resume(coroutine.create(fn)))
                return true
            end,
            isWrapped = function()
                return coroutine.running() ~= nil
            end,
        })
        local trap_widgets = {}
        helper.stub("fetchanna.util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return can_cancel
            end,
            setTrapWidget = function(widget)
                trap_widgets[coroutine.running() or "main"] = widget
            end,
            getTrapWidget = function()
                return trap_widgets[coroutine.running() or "main"]
            end,
        })
        sites = {
            beta = fakeSite("Beta Books", { "title", "author" }),
            gamma = fakeSite("Gamma Books", { "title", "author" }),
            alpha = fakeSite("Alpha Books"),
        }
        helper.stub("fetchanna.api.sources", sites)
        MultiSearch = require("fetchanna.api.multisearch")
        -- MultiSearch handles any number of sites, though FetchAnna has one.
        MultiSearch.SOURCES = { "alpha", "beta", "gamma" }
    end)

    after_each(helper.cleanup)

    local function searched(name)
        local found = {}
        for _, search in ipairs(searches) do
            if search.site == name then
                table.insert(found, search)
            end
        end
        return found
    end

    it("searches each site at once, passing on each one's books as soon as it has them", function()
        MultiSearch.start("dune", { beta = 1, gamma = 2 }, nil, handlers)
        assert.are.equal(0, #searches)
        helper.runScheduled()
        assert.are.equal(1, #searched("Beta Books"))
        assert.are.equal(2, searched("Gamma Books")[1].page)

        sites.gamma.answer({ "Dune" }, nil, 3, 50)
        assert.are.same({
            { source = "gamma", books = { "Dune" }, next_page = 3, results_read = 50 },
        }, results)
        assert.are.equal(0, done)

        sites.beta.answer({}, nil, nil, 25)
        assert.are.equal(2, #results)
        assert.are.equal("beta", results[2].source)
        assert.are.equal(1, done)
    end)

    -- For example authors only. Other sites still search everything.
    it("narrows the search down on the sites that can be", function()
        MultiSearch.start("herbert", { beta = 1, alpha = 1 }, "author", handlers)
        helper.runScheduled()
        assert.are.equal("author", searched("Beta Books")[1].scope)
        assert.is_nil(searched("Alpha Books")[1].scope)
    end)

    it("calls off the sites still being searched, each saying so", function()
        local search = MultiSearch.start("dune", { beta = 1, gamma = 1 }, nil, handlers)
        helper.runScheduled()
        sites.gamma.answer({ "Dune" })

        search:cancel()
        assert.are.equal("request cancelled", results[2].err)
        assert.is_true(searched("Beta Books")[1].trap.cancelled)
        assert.are.equal(1, done)
        assert.is_true(search:isDone())
        -- Cancelling again does nothing.
        search:cancel()
        assert.are.equal(2, #results)
    end)

    -- As Beta Books does, from the pages it had read.
    it("passes on what a site had found by the time it was called off", function()
        local search = MultiSearch.start("dune", { beta = 1 }, nil, handlers)
        helper.runScheduled()
        sites.beta.found_by_then = { "Dune" }

        search:cancel()
        assert.are.same({ "Dune" }, results[1].books)
        assert.is_nil(results[1].err)
    end)

    -- KOReader's own HTTP blocks while it waits.
    describe("one after another, where they can't be waited for at once", function()
        before_each(function()
            can_cancel = false
        end)

        it("starts the next site once the one before has finished", function()
            MultiSearch.start("dune", { beta = 1, gamma = 1, alpha = 1 }, nil, handlers)
            helper.runScheduled()
            assert.are.same({ "Alpha Books" }, { searches[1].site })
            assert.are.equal(1, #searches)

            sites.alpha.answer({ "Dune" })
            assert.are.equal(1, #results)
            helper.runScheduled()
            assert.are.equal("Beta Books", searches[2].site)
        end)

        it("doesn't start the sites not started yet once called off", function()
            local search = MultiSearch.start("dune", { beta = 1, gamma = 1 }, nil, handlers)
            helper.runScheduled()
            search:cancel()
            helper.runScheduled()

            assert.are.equal(1, #searches)
            assert.are.equal("request cancelled", results[2].err)
            assert.are.equal("gamma", results[2].source)
            assert.are.equal(1, done)
        end)
    end)

    it("says which sites are still being searched", function()
        local search = MultiSearch.start("dune", { alpha = 1, beta = 1, gamma = 1 }, nil, handlers)
        helper.runScheduled()
        assert.are.same({ "alpha", "beta", "gamma" }, search:pendingSources())
        sites.gamma.answer({})
        assert.are.same({ "alpha", "beta" }, search:pendingSources())
    end)

    -- For example which address it's trying.
    it("passes on what a site's search says it's waiting for", function()
        sites.beta.status = "Trying beta.li (mirror 1 of 5)..."
        MultiSearch.start("dune", { beta = 1 }, nil, handlers)
        helper.runScheduled()
        assert.are.same({ "Trying beta.li (mirror 1 of 5)..." }, statuses)
    end)

    it("says a site's search failed when something goes wrong in it", function()
        sites.beta.fails = true
        MultiSearch.start("dune", { beta = 1 }, nil, handlers)
        helper.runScheduled()
        sites.beta.answer({})

        assert.are.equal(require("fetchanna.util.errors").UNEXPECTED, results[1].err)
        assert.are.equal(1, done)
    end)

    it("finishes straight away when there are no sites to search", function()
        MultiSearch.start("dune", {}, nil, handlers)
        helper.runScheduled()
        assert.are.equal(0, #results)
        assert.are.equal(1, done)
    end)
end)
