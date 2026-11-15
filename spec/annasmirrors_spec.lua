local helper = require("helper")

describe("AnnasMirrors", function()
    local GL, PK, GD = "https://annas-archive.gl", "https://annas-archive.pk", "https://annas-archive.gd"
    local SOFTWARE, NEW = "https://software.annas-archive.gl", "https://annas-archive.se"
    local SLUM = "https://open-slum.org/annas.html"
    local NOW = 1794440000
    -- All as captured on 2026-11-11 (see spec/data/annas/PROVENANCE.md).
    local slum_page = helper.readFile("spec/data/annas/slum-annas.html")
    local api_doc = helper.readFile("spec/data/annas/fast-download-400-invalid-md5.json")
    local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")

    local data_dir, AnnasMirrors, Settings, HttpUtil, OriginPolicy, FAILURE
    -- What each URL answers (body, err, status, headers, or a function of the request returning them), and each
    -- request.
    local answers, requests

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        answers, requests = {}, {}

        HttpUtil = require("fetchanna.util.httputil")
        HttpUtil.getBody = function(url, opts)
            table.insert(requests, { url = url, opts = opts })
            local answer = answers[url] or { nil, "failed to connect to server" }
            if type(answer) == "function" then
                answer = answer(url, opts)
            end
            return answer[1], answer[2], answer[3], answer[4] or {}
        end
        OriginPolicy = require("fetchanna.util.originpolicy")
        OriginPolicy.resolve = function()
            return nil
        end
        Settings = require("fetchanna.settings.settings")
        AnnasMirrors = require("fetchanna.api.annasmirrors")
        FAILURE = AnnasMirrors.FAILURE
    end)

    after_each(helper.cleanup)

    -- Returns SLUM's page with id's card changed by change(card).
    local function withCard(page, id, change)
        local start = assert(page:find('<div class="card" id="' .. id .. '">', 1, true))
        local finish = page:find('<div class="card" id="', start + 1, true) or #page + 1
        return page:sub(1, start - 1) .. change(page:sub(start, finish - 1)) .. page:sub(finish)
    end
    local function without(page, id)
        return withCard(page, id, function()
            return ""
        end)
    end
    -- Returns the page with another catalogue site, annas-archive.se.
    local function withNewSite(page)
        return withCard(page, "annas.gd", function(card)
            return card .. card:gsub('id="annas%.gd"', 'id="annas.se"'):gsub("annas%-archive%.gd", "annas-archive.se")
        end)
    end
    local function slumAnswers(page)
        answers[SLUM] = { page, nil, 200 }
    end
    local function apiAnswersAsAnnas(origin)
        answers[origin .. "/dyn/api/fast_download.json"] = { api_doc, nil, 400 }
    end
    local function saved()
        return helper.state.settings_files[data_dir .. "/settings/fetchanna_mirrors.lua"]
    end

    describe("before SLUM has been asked", function()
        it("knows the sites FetchAnna was released with, trusting its catalogue sites with the key", function()
            assert.are.same({ GD, GL, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            for _, origin in ipairs({ GL, PK, GD }) do
                assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(origin))
            end
            assert.are.equal(AnnasMirrors.TRUST.UNTRUSTED, AnnasMirrors:trustOf(SOFTWARE))
            assert.are.equal("2026-11-11", AnnasMirrors.SEEDS_REVIEWED)
        end)

        it("knows no download servers, which only the member API gives", function()
            assert.are.same({}, AnnasMirrors:candidates(AnnasMirrors.TRANSFER))
        end)
    end)

    describe("looking the sites up on SLUM", function()
        it("takes in every site it lists, with what each is for", function()
            slumAnswers(slum_page)
            assert.is_true(AnnasMirrors:refresh())

            local hosts = {}
            for _, record in ipairs(AnnasMirrors:list(AnnasMirrors.TRANSFER == "transfer" and "download")) do
                table.insert(hosts, record.host)
            end
            assert.are.same({ "wbsg8v.xyz", "yqrii5.org" }, hosts)
            local gl = AnnasMirrors:list("catalogue")[2]
            assert.are.equal("annas-archive.gl", gl.host)
            assert.are.equal("protected", gl.slum.status)
            assert.are.equal(1794438778, gl.slum.checked_at)
            assert.are.equal(NOW, AnnasMirrors:discovery().fetched_at)
            assert.are.equal(1794438778, AnnasMirrors:discovery().generated_at)
            -- No redirect is followed.
            assert.is_false(requests[1].opts.follow_redirects)
            assert.is_table(saved().records[GL])
        end)

        -- Discovery is not trust.
        it("doesn't trust a site it only found on SLUM with the key", function()
            slumAnswers(withNewSite(slum_page))
            AnnasMirrors:refresh()

            assert.are.equal(AnnasMirrors.TRUST.UNTRUSTED, AnnasMirrors:trustOf(NEW))
            assert.is_falsy(
                table.concat(AnnasMirrors:candidates(AnnasMirrors.SEARCH, { limit = 9 }), " "):find(NEW, 1, true)
            )
            assert.is_truthy(
                table.concat(AnnasMirrors:candidates(AnnasMirrors.PROBE, { limit = 9 }), " "):find(NEW, 1, true)
            )
            assert.is_truthy(helper.logged("info", "SLUM lists a site not known before: annas%-archive%.se"))
        end)

        it("follows a redirect within SLUM, but not to another site", function()
            answers["https://open-slum.org/annas"] = { slum_page, nil, 200 }
            answers[SLUM] = { "", nil, 301, { location = "/annas" } }
            assert.is_true(AnnasMirrors:refresh())

            answers[SLUM] = { "", nil, 302, { location = "https://open-slum.example/annas.html" } }
            local ok, err = AnnasMirrors:refresh()
            assert.is_nil(ok)
            assert.are.equal("SLUM sent FetchAnna to another site", err)
        end)

        describe("when SLUM can't be read", function()
            local function keepsWhatItKnew(answer, why)
                helper.state.time = NOW
                slumAnswers(withNewSite(slum_page))
                AnnasMirrors:refresh()
                helper.state.time = NOW + 100
                answers[SLUM] = answer

                local ok, err = AnnasMirrors:refresh()
                assert.is_nil(ok)
                assert.are.equal(why, err)
                assert.is_table(AnnasMirrors:list("catalogue")[4])
                assert.is_nil(AnnasMirrors:list("catalogue")[1].delisted_at)
                assert.are.equal(NOW, AnnasMirrors:discovery().fetched_at)
                assert.are.equal(why, AnnasMirrors:discovery().last_error)
                assert.are.equal(NOW + 100, AnnasMirrors:discovery().last_error_at)
            end

            it("keeps the sites it knew when a bot check answers instead", function()
                keepsWhatItKnew({ challenge, nil, 200 }, "SLUM answered with a page that isn't its list of sites")
            end)

            it("keeps the sites it knew when the page has changed", function()
                keepsWhatItKnew(
                    { slum_page:gsub('class="card%-title"', 'class="title"'), nil, 200 },
                    "SLUM's page has changed, so its sites couldn't be read"
                )
            end)

            -- An empty list would leave nothing to use.
            it("keeps the sites it knew when SLUM lists none of Anna's catalogue sites", function()
                local only_downloads =
                    without(without(without(without(slum_page, "annas.gl"), "annas.pk"), "annas.gd"), "annas.software")
                keepsWhatItKnew({ only_downloads, nil, 200 }, "SLUM lists none of Anna's Archive's own sites")
            end)

            it("keeps the sites it knew when SLUM answers with an error or doesn't answer", function()
                keepsWhatItKnew({ "<html>oops</html>", nil, 500 }, "SLUM answered with an error (HTTP 500)")
                keepsWhatItKnew({ nil, "could not resolve host" }, "could not resolve host")
            end)
        end)

        describe("when SLUM stops listing a site", function()
            before_each(function()
                slumAnswers(slum_page)
                AnnasMirrors:refresh()
                helper.state.time = NOW + 3600
                slumAnswers(without(slum_page, "annas.gd"))
                AnnasMirrors:refresh()
            end)

            it("stops using it, and stops trusting it with the key", function()
                assert.are.same({ GL, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
                local trust, since = AnnasMirrors:trustOf(GD)
                assert.are.equal(AnnasMirrors.TRUST.SUSPENDED, trust)
                assert.are.equal(NOW + 3600, since)
                assert.is_truthy(helper.logged("warn", "^SLUM no longer lists annas%-archive%.gd$"))
            end)

            it("trusts it again once SLUM lists it again", function()
                helper.state.time = NOW + 7200
                slumAnswers(slum_page)
                AnnasMirrors:refresh()
                assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(GD))
                assert.are.same({ GD, GL, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            end)

            it("trusts it again once approved again, after it has been checked", function()
                helper.state.time = NOW + 7200
                apiAnswersAsAnnas(GD)
                assert.is_true(AnnasMirrors:probe(GD))
                assert.is_true(AnnasMirrors:approve(GD))
                assert.are.equal(AnnasMirrors.TRUST.APPROVED, AnnasMirrors:trustOf(GD))
            end)
        end)

        it("forgets a site it found itself once SLUM hasn't listed it for a month", function()
            slumAnswers(withNewSite(slum_page))
            AnnasMirrors:refresh()
            slumAnswers(slum_page)
            helper.state.time = NOW + 60
            AnnasMirrors:refresh()
            assert.are.equal(4, #AnnasMirrors:list("catalogue"))
            helper.state.time = NOW + 31 * 24 * 3600
            AnnasMirrors:refresh()
            assert.are.equal(3, #AnnasMirrors:list("catalogue"))
        end)

        -- Anyone could change SLUM's page, so it can't change a seed's role.
        it("doesn't change what a site FetchAnna was released with is for", function()
            slumAnswers(withCard(slum_page, "annas.gl", function(card)
                return (card:gsub("in one place %- Anna", "AnnaArchivist"))
            end))
            AnnasMirrors:refresh()
            assert.are.equal("catalogue", AnnasMirrors:list("catalogue")[2].role)
            assert.is_truthy(helper.logged("warn", "^SLUM lists annas%-archive%.gl as a software site"))
        end)
    end)

    describe("ensureDiscovery", function()
        it("looks the sites up when they never have been, then not again for a day", function()
            slumAnswers(slum_page)
            assert.is_true(AnnasMirrors:ensureDiscovery())
            assert.is_true(AnnasMirrors:ensureDiscovery())
            assert.are.equal(1, #requests)
            helper.state.time = NOW + 25 * 3600
            assert.is_true(AnnasMirrors:ensureDiscovery())
            assert.are.equal(2, #requests)
        end)

        it("doesn't ask SLUM again for an hour after it couldn't be read", function()
            local ok, err = AnnasMirrors:ensureDiscovery()
            assert.is_false(ok)
            assert.are.equal("failed to connect to server", err)
            helper.state.time = NOW + 1800
            assert.is_false((AnnasMirrors:ensureDiscovery()))
            assert.are.equal(1, #requests)
            helper.state.time = NOW + 3601
            AnnasMirrors:ensureDiscovery()
            assert.are.equal(2, #requests)
        end)
    end)

    describe("checking a site is Anna's Archive", function()
        it("asks its member API for nothing, sending nothing of the account's", function()
            apiAnswersAsAnnas(GL)
            assert.is_true(AnnasMirrors:probe(GL))
            assert.are.equal(GL .. "/dyn/api/fast_download.json", requests[1].url)
            assert.is_false(requests[1].opts.follow_redirects)
            assert.is_nil(requests[1].opts.cookies)
            assert.are.equal(NOW, AnnasMirrors:list("catalogue")[2].verified_at)
        end)

        -- As a site that has been taken over might.
        it("stops trusting a site that answers as Anna's Archive doesn't, until it does again", function()
            answers[GL .. "/dyn/api/fast_download.json"] = { "<html>This domain is for sale</html>", nil, 200 }
            local ok, failure = AnnasMirrors:probe(GL)
            assert.is_nil(ok)
            assert.are.equal(FAILURE.UNEXPECTED, failure)
            assert.are.equal(AnnasMirrors.TRUST.SUSPENDED, AnnasMirrors:trustOf(GL))
            assert.are.same({ GD, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            assert.is_truthy(
                helper.logged("warn", "^annas%-archive%.gl answered the member API as Anna's Archive doesn't")
            )

            apiAnswersAsAnnas(GL)
            assert.is_true(AnnasMirrors:probe(GL))
            assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(GL))
        end)

        it("doesn't take a bot check or no answer to mean the site isn't Anna's Archive", function()
            answers[GL .. "/dyn/api/fast_download.json"] = { challenge, nil, 403 }
            assert.are.equal(FAILURE.CHALLENGE, select(2, AnnasMirrors:probe(GL)))
            assert.are.equal(FAILURE.CONNECT, select(2, AnnasMirrors:probe(PK)))
            assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(GL))
            assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(PK))
        end)

        it("doesn't ask a site whose name leads to a private network", function()
            OriginPolicy.resolve = function()
                return { "192.168.1.1" }
            end
            assert.are.equal(FAILURE.BLOCKED, select(2, AnnasMirrors:probe(GL)))
            assert.are.equal(0, #requests)
        end)
    end)

    describe("trusting a site with the key", function()
        before_each(function()
            slumAnswers(withNewSite(slum_page))
            AnnasMirrors:refresh()
        end)

        it("only approves a site once it has been checked to be Anna's Archive", function()
            local ok, err = AnnasMirrors:approve(NEW)
            assert.is_nil(ok)
            assert.are.equal("This site hasn't been checked to be Anna's Archive yet.", err)

            apiAnswersAsAnnas(NEW)
            AnnasMirrors:probe(NEW)
            assert.is_true(AnnasMirrors:approve(NEW))
            assert.are.equal(AnnasMirrors.TRUST.APPROVED, AnnasMirrors:trustOf(NEW))
            assert.are.same({ approved_at = NOW }, Settings:getMirrorTrust()[NEW])
            assert.is_truthy(
                table.concat(AnnasMirrors:candidates(AnnasMirrors.SEARCH, { limit = 9 }), " "):find(NEW, 1, true)
            )
        end)

        it("only approves Anna's catalogue sites", function()
            local ok, err = AnnasMirrors:approve(SOFTWARE)
            assert.is_nil(ok)
            assert.are.equal("Only Anna's Archive's own sites can be sent your key.", err)
            assert.is_nil((AnnasMirrors:approve("https://yqrii5.org")))
            assert.is_nil((AnnasMirrors:approve("https://unknown.example")))
        end)

        it("never sends a revoked site the key, even one FetchAnna was released with", function()
            AnnasMirrors:recordSuccess(GL, AnnasMirrors.SEARCH)
            assert.is_true(AnnasMirrors:revoke(GL))
            assert.are.equal(AnnasMirrors.TRUST.REVOKED, AnnasMirrors:trustOf(GL))
            assert.are.same({ GD, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            -- It can still be probed, which sends it nothing.
            assert.is_truthy(table.concat(AnnasMirrors:candidates(AnnasMirrors.PROBE), " "):find(GL, 1, true))
        end)

        it("goes back to the sites FetchAnna was released with when reset", function()
            apiAnswersAsAnnas(NEW)
            AnnasMirrors:probe(NEW)
            AnnasMirrors:approve(NEW)
            AnnasMirrors:revoke(GL)
            assert.is_true(AnnasMirrors:reset())

            assert.are.same({}, Settings:getMirrorTrust())
            assert.are.equal(3, #AnnasMirrors:list("catalogue"))
            assert.are.equal(AnnasMirrors.TRUST.SEED, AnnasMirrors:trustOf(GL))
            assert.is_nil(AnnasMirrors:discovery().fetched_at)
            assert.is_nil(saved().records[NEW])
        end)
    end)

    -- The files can be edited by hand, or cut short.
    describe("with saved files that can't be used", function()
        it("leaves out decisions that aren't approvals or revocations", function()
            Settings:setSetting("mirror_trust", {
                [NEW] = { approved_at = "yes" },
                ["https://x.example"] = true,
                [PK] = { revoked_at = 5, approved_at = 9 },
            })
            assert.are.same({ [PK] = { revoked_at = 5 } }, Settings:getMirrorTrust())
            assert.are.equal(AnnasMirrors.TRUST.UNTRUSTED, AnnasMirrors:trustOf(NEW))
        end)

        it("leaves out sites that aren't https sites, or aren't for anything it knows", function()
            helper.state.settings_files[data_dir .. "/settings/fetchanna_mirrors.lua"] = {
                records = {
                    ["http://annas-archive.gl"] = { role = "catalogue" },
                    ["https://admin.example"] = { role = "admin" },
                    ["https://x.example"] = "nonsense",
                    [GL] = { role = "download", source = "slum", health = { search = { cooldown_until = "never" } } },
                },
                discovery = "broken",
                last_working = { search = "https://admin.example" },
            }
            local catalogue = AnnasMirrors:list("catalogue")
            assert.are.equal(3, #catalogue)
            -- A seed's role is always the one it came with.
            assert.are.equal("catalogue", catalogue[2].role)
            assert.are.equal(0, #AnnasMirrors:list("download"))
            assert.are.same({ GD, GL, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
        end)
    end)

    describe("trying the sites in turn", function()
        local tried

        -- Answers attempts from by_origin: a result, or nil, a failure and anything more. Records each origin tried.
        local function attempts(by_origin)
            tried = {}
            return function(origin)
                table.insert(tried, origin)
                local answer = by_origin[origin] or { nil, FAILURE.CONNECT }
                return answer[1], answer[2], answer[3]
            end
        end

        it("gives what the first site that works gives, trying it first from then on", function()
            local result, origin = AnnasMirrors:run(AnnasMirrors.SEARCH, attempts({ [GL] = { "books" } }))
            assert.are.equal("books", result)
            assert.are.equal(GL, origin)
            assert.are.same({ GD, GL }, tried)
            assert.are.same({ GL, PK, GD }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            assert.are.equal(GL, saved().last_working.search)
        end)

        it("tries a site that failed after the others for a minute, doubling with each failure", function()
            AnnasMirrors:run(AnnasMirrors.SEARCH, attempts({ [GL] = { "books" } }))
            assert.are.equal(NOW + 60, saved().records[GD].health.search.cooldown_until)
            assert.are.same({ GL, PK, GD }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))

            AnnasMirrors:recordFailure(GD, AnnasMirrors.SEARCH, FAILURE.TIMEOUT)
            AnnasMirrors:recordFailure(GD, AnnasMirrors.SEARCH, FAILURE.TIMEOUT)
            assert.are.equal(NOW + 240, AnnasMirrors:list("catalogue")[1].health.search.cooldown_until)
            for _ = 1, 10 do
                AnnasMirrors:recordFailure(GD, AnnasMirrors.SEARCH, FAILURE.TIMEOUT)
            end
            assert.are.equal(NOW + 3600, AnnasMirrors:list("catalogue")[1].health.search.cooldown_until)
        end)

        it("still tries sites that are resting when there are none others", function()
            for _, origin in ipairs({ GL, PK, GD }) do
                AnnasMirrors:recordFailure(origin, AnnasMirrors.SEARCH, FAILURE.CONNECT)
            end
            assert.are.equal(3, #AnnasMirrors:candidates(AnnasMirrors.SEARCH))
        end)

        it("leaves a site that asked to be left for as long as it asked, up to 6 hours", function()
            AnnasMirrors:recordFailure(GL, AnnasMirrors.SEARCH, FAILURE.RATE_LIMITED, { retry_after = 900 })
            assert.are.equal(NOW + 900, AnnasMirrors:list("catalogue")[2].health.search.cooldown_until)
            AnnasMirrors:recordFailure(PK, AnnasMirrors.SEARCH, FAILURE.RATE_LIMITED, { retry_after = 10 ^ 9 })
            assert.are.equal(NOW + 6 * 3600, AnnasMirrors:list("catalogue")[3].health.search.cooldown_until)
        end)

        it("keeps track of each thing asked of a site separately", function()
            AnnasMirrors:recordFailure(GD, AnnasMirrors.SEARCH, FAILURE.CHALLENGE)
            assert.are.same({ GL, PK, GD }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
            assert.are.same({ GD, GL, PK }, AnnasMirrors:candidates(AnnasMirrors.API))
        end)

        -- Other sites would answer the same, and asking them would only use up more of the allowance.
        for _, failure in ipairs({ "INVALID_KEY", "NOT_MEMBER", "QUOTA", "NOT_FOUND", "UNAVAILABLE" }) do
            it("stops at a failure that isn't the site's doing: " .. failure, function()
                local result, outcome =
                    AnnasMirrors:run(AnnasMirrors.API, attempts({ [GD] = { nil, FAILURE[failure] } }))
                assert.is_nil(result)
                assert.are.equal(FAILURE[failure], outcome.failure)
                assert.is_true(outcome.stopped)
                assert.are.same({ GD }, tried)
                assert.is_nil(saved().records[GD].health.api)
            end)
        end

        it("stops when called off, without counting it against the site", function()
            local result, outcome =
                AnnasMirrors:run(AnnasMirrors.SEARCH, attempts({ [GD] = { nil, FAILURE.CANCELLED } }))
            assert.is_nil(result)
            assert.are.equal(FAILURE.CANCELLED, outcome.failure)
            assert.are.same({ GD }, tried)
            assert.is_nil(AnnasMirrors:list("catalogue")[1].health.search)
        end)

        it("says why when every site failed", function()
            local result, outcome = AnnasMirrors:run(
                AnnasMirrors.SEARCH,
                attempts({
                    [GD] = { nil, FAILURE.TIMEOUT },
                    [GL] = { nil, FAILURE.SERVER },
                    [PK] = { nil, FAILURE.SERVER },
                })
            )
            assert.is_nil(result)
            assert.are.equal(FAILURE.SERVER, outcome.failure)
            assert.is_true(outcome.mixed)
            assert.are.equal(3, #outcome.tried)
            assert.are.same({ origin = GD, failure = FAILURE.TIMEOUT }, outcome.tried[1])
            assert.are.equal("Anna's Archive answered with an error. Try again later.", AnnasMirrors.describe(outcome))
        end)

        it("tries at most three sites", function()
            slumAnswers(withNewSite(slum_page))
            AnnasMirrors:refresh()
            AnnasMirrors:run(AnnasMirrors.PROBE, attempts({}))
            assert.are.equal(3, #tried)
        end)

        it("doesn't try another site once its time is up", function()
            local result, outcome = AnnasMirrors:run(AnnasMirrors.SEARCH, function(origin)
                helper.state.time = helper.state.time + 31
                return nil, FAILURE.TIMEOUT, { detail = origin }
            end)
            assert.is_nil(result)
            assert.is_true(outcome.timed_out)
            assert.are.equal(1, #outcome.tried)
        end)

        it("doesn't ask a site whose name leads to a private network", function()
            OriginPolicy.resolve = function(host)
                return host == "annas-archive.gd" and { "127.0.0.1" } or nil
            end
            local result = AnnasMirrors:run(AnnasMirrors.SEARCH, attempts({ [GL] = { "books" } }))
            assert.are.equal("books", result)
            assert.are.same({ GL }, tried)
            assert.are.equal(FAILURE.BLOCKED, saved().records[GD].health.search.failure)
        end)

        it("says when none of the sites is trusted with the key", function()
            for _, origin in ipairs({ GL, PK, GD }) do
                AnnasMirrors:revoke(origin)
            end
            local result, outcome = AnnasMirrors:run(AnnasMirrors.SEARCH, attempts({}))
            assert.is_nil(result)
            assert.are.equal(FAILURE.NO_TRUSTED, outcome.failure)
            assert.are.same({}, tried)
            assert.matches("Approve one under Mirrors", AnnasMirrors.describe(outcome))
            -- What's asked without the key still can be.
            assert.are.equal("ok", (AnnasMirrors:run(AnnasMirrors.PROBE, attempts({ [GD] = { "ok" } }))))
        end)

        it("says when there's no site to ask at all", function()
            local result, outcome = AnnasMirrors:run(AnnasMirrors.TRANSFER, attempts({}))
            assert.is_nil(result)
            assert.are.equal(FAILURE.NO_MIRRORS, outcome.failure)
        end)

        it("says how long a site asked to be left for", function()
            local _, outcome = AnnasMirrors:run(AnnasMirrors.SEARCH, function()
                return nil, FAILURE.RATE_LIMITED, { retry_after = 90 }
            end)
            assert.are.equal(
                "Anna's Archive asked FetchAnna to wait before asking again. Try again in 2 minutes.",
                AnnasMirrors.describe(outcome)
            )
        end)
    end)

    describe("classify", function()
        local CurlUtil

        before_each(function()
            CurlUtil = require("fetchanna.util.curlutil")
        end)

        it("tells apart why a request didn't get what it asked for", function()
            local classify = AnnasMirrors.classify
            assert.are.equal(FAILURE.CANCELLED, classify(nil, HttpUtil.CANCELLED))
            assert.are.equal(FAILURE.CHALLENGE, classify(challenge, nil, 403, {}))
            assert.are.equal(FAILURE.CHALLENGE, classify("", nil, 302, { location = "/search?q=x&check=1" }))
            assert.are.equal(FAILURE.REDIRECTED, classify("", nil, 302, { location = "https://elsewhere.example/" }))
            assert.are.equal(FAILURE.SERVER, classify("<html>", nil, 502, {}))
            assert.are.equal(FAILURE.SERVER, classify(nil, "empty response (HTTP 503)", 503, {}))
            assert.are.equal(FAILURE.UNRESOLVED, classify(nil, HttpUtil.UNRESOLVED))
            assert.are.equal(FAILURE.TLS, classify(nil, CurlUtil.getErrorMeaning(35)))
            assert.are.equal(FAILURE.TIMEOUT, classify(nil, CurlUtil.getErrorMeaning(28)))
            assert.are.equal(FAILURE.CONNECT, classify(nil, CurlUtil.getErrorMeaning(7)))
            assert.are.equal(FAILURE.UNEXPECTED, classify("<html>parked</html>", nil, 200, {}))
        end)

        it("reads how long a site asked to be left for", function()
            local failure, info = AnnasMirrors.classify("slow down", nil, 429, { ["retry-after"] = "120" })
            assert.are.equal(FAILURE.RATE_LIMITED, failure)
            assert.are.same({ retry_after = 120 }, info)
            failure, info = AnnasMirrors.classify("", nil, 503, { ["retry-after"] = "Wed, 11 Nov 2026 23:15:54 GMT" })
            assert.are.equal(FAILURE.RATE_LIMITED, failure)
            assert.are.same({ retry_after = 0 }, info)
        end)
    end)
end)
