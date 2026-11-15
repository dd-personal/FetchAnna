local helper = require("helper")

describe("AnnasSearch", function()
    -- These are not real keys or sessions, only shaped like them.
    local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
    local SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6MX0.c2lnbmF0dXJlLXZhbHVl_x-y"
    local NEW_SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6Mn0.bmV3LXNpZ25hdHVyZQ_z"
    local GL, PK, GD = "https://annas-archive.gl", "https://annas-archive.pk", "https://annas-archive.gd"
    local NOW = 1794440000
    -- A member's results page, as it was on 2026-11-11 (see spec/data/annas/PROVENANCE.md).
    local results_page = helper.readFile("spec/data/annas/search-results-member.html")
    -- How Anna's Archive sends a search it won't allow to its browser check (see docs/annas-protocol.md).
    local CHECK = { "", nil, 302, { location = "/search?q=dune&check=1" } }

    local data_dir, AnnasSearch, AnnasMirrors, KeyStore, Settings, Errors, HttpUtil
    -- What's answered, by method and URL without the query, and each request. A list of answers is given in turn, the
    -- last one repeating.
    local answers, requests

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        answers, requests = {}, {}

        HttpUtil = require("fetchanna.util.httputil")
        local asked = {}
        HttpUtil.getBody = function(url, opts)
            opts = opts or {}
            table.insert(requests, { url = url, opts = opts })
            local key = (opts.form and "POST " or "GET ") .. url:gsub("%?.*$", "")
            local list = answers[key]
            if type(list) ~= "table" or type(list[1]) ~= "table" then
                list = { list }
            end
            asked[key] = (asked[key] or 0) + 1
            local answer = list[math.min(asked[key], #list)] or { nil, "failed to connect to server" }
            return answer[1], answer[2], answer[3], answer[4] or {}
        end
        require("fetchanna.util.originpolicy").resolve = function()
            return nil
        end
        Errors = require("fetchanna.util.errors")
        Settings = require("fetchanna.settings.settings")
        KeyStore = require("fetchanna.api.keystore")
        AnnasMirrors = require("fetchanna.api.annasmirrors")
        AnnasSearch = require("fetchanna.api.annassearch")
        require("fetchanna.api.annasaccount"):setKey(KEY)
        -- Logged in a moment ago on annas-archive.gd, the site tried first.
        KeyStore.setSession(GD, SESSION, NOW + 90 * 86400)
    end)

    after_each(helper.cleanup)

    -- Returns the search requests, without the SLUM lookups.
    local function searches()
        local list = {}
        for _, request in ipairs(requests) do
            if request.url:find("/search?", 1, true) then
                table.insert(list, request)
            end
        end
        return list
    end
    local function md5s(books)
        local list = {}
        for _, book in ipairs(books) do
            table.insert(list, book.md5)
        end
        return list
    end

    describe("searchPath", function()
        it("asks for the query, in the languages and as the file types chosen, from the page given", function()
            assert.are.equal(
                "/search?q=pride%20and%20prejudice&lang=en&lang=fr&ext=epub&ext=mobi&page=3",
                AnnasSearch.searchPath("pride and prejudice", 3, { "en", "fr" }, { "epub", "mobi" })
            )
        end)

        it("asks for any language when every one is chosen, and leaves out the first page's number", function()
            local every = {}
            for _, language in ipairs(Settings:getAvailableLanguages()) do
                table.insert(every, language.code)
            end
            assert.are.equal("/search?q=dune&ext=epub", AnnasSearch.searchPath("dune", 1, every, { "epub" }))
        end)

        it("asks for queries in any alphabet, as UTF-8", function()
            assert.are.equal(
                "/search?q=Caf%C3%A9%20%E6%97%A5%E6%9C%AC&lang=en&ext=epub",
                AnnasSearch.searchPath("Café 日本", 1, { "en" }, { "epub" })
            )
        end)
    end)

    describe("searching", function()
        it("searches as the account, on the site logged into, finding the books in the file types chosen", function()
            answers["GET " .. GD .. "/search"] = { results_page, nil, 200 }
            local books, err, next_page, read = AnnasSearch:search("pride and prejudice.", 1)

            assert.is_nil(err)
            -- EPUB only, the default.
            assert.are.same({
                "fbde8a9d82dc45577420e2034beece43",
                "38c608e62b343809a645c01b50163ad9",
                "c4a746048c3a833b8bfc38fc73c2da13",
                "83c25234ecb2264d9b9e29e70b1373df",
                "3ee8503b2725ce808b44d80f0c9f6bcd",
                "14fa564810e675a6236e6fd7ad507be2",
                "7dc284b589530d38be995709c946e4c5",
                "44a92663fa147722e749d0df6f1c65a1",
            }, md5s(books))
            assert.are.equal(2, next_page)
            assert.are.equal(12, read)

            local search = searches()[1]
            assert.are.equal(GD .. "/search?q=pride%20and%20prejudice.&lang=en&ext=epub", search.url)
            assert.are.equal("aa_account_id2=" .. SESSION, search.opts.cookies)
            assert.is_false(search.opts.follow_redirects)
            assert.is_truthy(helper.logged("info", "^page 1 of Anna's Archive's results: kept 8 of its 12$"))
        end)

        -- Anna's Archive has others, such as LIT, which some of these results are in.
        it("never keeps a file type KOReader can't open", function()
            Settings:setPreferredFileTypes({ "epub", "mobi", "lit" })
            answers["GET " .. GD .. "/search"] = { results_page, nil, 200 }
            local books = AnnasSearch:search("pride and prejudice.", 1)
            assert.are.equal(11, #books)
            for _, book in ipairs(books) do
                assert.are_not.equal("lit", book.file_type)
            end
        end)

        it("logs in on the site first, where it isn't yet", function()
            KeyStore.dropSession()
            answers["POST " .. GD .. "/account/"] =
                { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. NEW_SESSION } }
            answers["GET " .. GD .. "/search"] = { results_page, nil, 200 }
            assert.are.equal(8, #AnnasSearch:search("pride and prejudice.", 1))
            assert.are.equal("aa_account_id2=" .. NEW_SESSION, searches()[1].opts.cookies)
        end)

        it("finds none where Anna's Archive found none", function()
            local none = results_page:gsub(
                '<div class="js%-aarecord%-list%-outer">.*</div>%s*<nav',
                '<div class="js-aarecord-list-outer"></div><nav'
            )
            answers["GET " .. GD .. "/search"] = { none, nil, 200 }
            local books, err, next_page, read = AnnasSearch:search("zzzz", 1)
            assert.are.same({}, books)
            assert.is_nil(err)
            assert.is_nil(next_page)
            assert.are.equal(0, read)
        end)

        it("shows the books saved from the same search, without asking again", function()
            answers["GET " .. GD .. "/search"] = { results_page, nil, 200 }
            AnnasSearch:search("pride and prejudice.", 1)
            assert.is_true(AnnasSearch:isCached("pride and prejudice.", 1))
            local books = AnnasSearch:search("pride and prejudice.", 1)
            assert.are.equal(8, #books)
            assert.are.equal(1, #searches())
            -- The cache key has the parser's version.
            local cache = helper.state.settings_files[data_dir .. "/settings/fetchanna_searchcache.lua"]
            local key = next(cache.data or cache)
            assert.matches("^annas#1|", tostring(key == "data" and next(cache.data) or key))
        end)
    end)

    -- FetchAnna never tries to get past the browser check.
    describe("when Anna's Archive asks for its browser check", function()
        it("says so, without asking its other sites", function()
            answers["GET " .. GD .. "/search"] = CHECK
            answers["GET " .. GL .. "/search"] = { results_page, nil, 200 }
            local books, err = AnnasSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(Errors.ANNAS_BLOCKED, err)
            assert.are.equal(1, #searches())
            -- Nor is it held against the site.
            assert.are.same({ GD, GL, PK }, AnnasMirrors:candidates(AnnasMirrors.SEARCH))
        end)

        it("logs in again and asks once more, where the session is old enough to maybe no longer be taken", function()
            helper.state.time = NOW + 2 * 3600
            answers["GET " .. GD .. "/search"] = { CHECK, { results_page, nil, 200 } }
            answers["POST " .. GD .. "/account/"] =
                { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. NEW_SESSION } }
            local books = AnnasSearch:search("pride and prejudice.", 1)
            assert.are.equal(8, #books)
            assert.are.equal(2, #searches())
            assert.are.equal("aa_account_id2=" .. NEW_SESSION, searches()[2].opts.cookies)
        end)

        it("says so when it asks again after logging in again", function()
            helper.state.time = NOW + 2 * 3600
            answers["GET " .. GD .. "/search"] = CHECK
            answers["POST " .. GD .. "/account/"] =
                { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. NEW_SESSION } }
            local books, err = AnnasSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(Errors.ANNAS_BLOCKED, err)
            assert.are.equal(2, #searches())
        end)

        it("says so when it's the check's page that answers", function()
            answers["GET " .. GD .. "/search"] =
                { helper.readFile("spec/data/annas/ddos-guard-403-challenge.html"), nil, 403 }
            assert.are.equal(Errors.ANNAS_BLOCKED, select(2, AnnasSearch:search("dune", 1)))
        end)
    end)

    describe("when it can't search", function()
        it("asks for the key first", function()
            require("fetchanna.api.annasaccount"):forget()
            local books, err = AnnasSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(Errors.ANNAS_NO_KEY, err)
            assert.are.equal(0, #searches())
        end)

        it("says when the key isn't accepted", function()
            KeyStore.dropSession()
            answers["POST " .. GD .. "/account/"] =
                { '<form method="post" action="/account/"><input name="key"></form>', nil, 200 }
            assert.are.equal(Errors.ANNAS_KEY_REJECTED, select(2, AnnasSearch:search("dune", 1)))
        end)

        -- Never reported as finding nothing.
        it("says a page it can't read can't be read, trying the other sites", function()
            answers["GET " .. GD .. "/search"] = { "<html>Maintenance</html>", nil, 200 }
            answers["GET " .. GL .. "/search"] = { "<html>Maintenance</html>", nil, 200 }
            answers["GET " .. PK .. "/search"] = { "<html>Maintenance</html>", nil, 200 }
            for _, origin in ipairs({ GL, PK }) do
                answers["POST " .. origin .. "/account/"] =
                    { "", nil, 302, { ["set-cookie"] = "aa_account_id2=" .. NEW_SESSION } }
            end
            local books, err = AnnasSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(Errors.UNREADABLE, err)
            assert.are.equal(3, #searches())
        end)

        it("says when Anna's Archive's search gave up", function()
            answers["GET " .. GD .. "/search"] = {
                results_page:gsub('<div class="js%-aarecord%-list%-outer">.*</div>%s*<nav', "<nav"),
                nil,
                200,
            }
            local _, err = AnnasSearch:search("dune", 1)
            assert.matches("^Anna's Archive answered with an error", err)
        end)

        it("says when its sites can't be found on the network", function()
            for _, origin in ipairs({ GD, GL, PK }) do
                answers["GET " .. origin .. "/search"] = { nil, HttpUtil.UNRESOLVED }
                KeyStore.setSession(origin, SESSION, NOW + 86400)
            end
            assert.are.equal(Errors.ANNAS_UNFOUND, select(2, AnnasSearch:search("dune", 1)))
        end)

        it("searches none of its sites but those trusted with the key", function()
            for _, origin in ipairs({ GD, GL, PK }) do
                AnnasMirrors:revoke(origin)
            end
            local books, err = AnnasSearch:search("dune", 1)
            assert.is_nil(books)
            assert.matches("^None of Anna's Archive's sites is approved", err)
            assert.are.equal(0, #searches())
        end)

        it("says it was called off", function()
            answers["GET " .. GD .. "/search"] = { nil, HttpUtil.CANCELLED }
            assert.are.equal(HttpUtil.CANCELLED, select(2, AnnasSearch:search("dune", 1)))
        end)
    end)

    describe("md5From", function()
        local MD5 = "0123456789abcdef0123456789abcdef"

        it("takes an md5, or a link to the file's page on any of Anna's Archive's sites", function()
            assert.are.equal(MD5, AnnasSearch.md5From(MD5))
            assert.are.equal(MD5, AnnasSearch.md5From("  " .. MD5:upper() .. "\n"))
            assert.are.equal(MD5, AnnasSearch.md5From("md5:" .. MD5))
            assert.are.equal(MD5, AnnasSearch.md5From("https://annas-archive.gd/md5/" .. MD5))
            assert.are.equal(MD5, AnnasSearch.md5From("https://annas-archive.gl/md5/" .. MD5 .. "?lang=en#downloads"))
            assert.are.equal(MD5, AnnasSearch.md5From("HTTP://mirror.example/md5/" .. MD5 .. "/"))
        end)

        it("takes nothing else, so that a search for anything else is still a search", function()
            for _, text in ipairs({
                "dune",
                "",
                MD5 .. "0",
                MD5:sub(2),
                "https://annas-archive.gd/md5/" .. MD5 .. "x",
                "https://annas-archive.gd/search?q=" .. MD5,
                "https://annas-archive.gd/isbn/9780441013593",
                "ftp://annas-archive.gd/md5/" .. MD5,
                "see https://annas-archive.gd/md5/" .. MD5,
            }) do
                assert.is_nil(AnnasSearch.md5From(text), text)
            end
            assert.is_nil(AnnasSearch.md5From(nil))
        end)
    end)

    describe("a book's download link", function()
        local MD5 = "0123456789abcdef0123456789abcdef"
        local API = "GET " .. GD .. "/dyn/api/fast_download.json"
        -- SYNTHESIZED from the member API's documented answer (see annasaccount_spec.lua).
        local function linkAnswer(n)
            return {
                string.format(
                    '{"download_url": "https://dl%d.example/d3/y/1794440000/c2lnbmVk/%s.epub", '
                        .. '"account_fast_download_info": {"downloads_left": 20, "downloads_per_day": 25}, '
                        .. '"///download_url": ["Placeholder."]}',
                    n,
                    MD5
                ),
                nil,
                200,
            }
        end
        local function errorAnswer(err, status)
            return {
                string.format('{"error": "%s", "///download_url": ["Placeholder."]}', err),
                nil,
                status,
            }
        end
        local function apiRequests()
            local list = {}
            for _, request in ipairs(requests) do
                if request.url:find("/dyn/api/fast_download.json", 1, true) then
                    table.insert(list, request.url)
                end
            end
            return list
        end

        it("is the member API's, with the md5 to check what arrives against", function()
            answers[API] = linkAnswer(1)
            local url, err, mirror_failed, listed = AnnasSearch.findDownloadLink({ md5 = MD5:upper() })
            assert.are.equal("https://dl1.example/d3/y/1794440000/c2lnbmVk/" .. MD5 .. ".epub", url)
            assert.is_nil(err)
            assert.is_false(mirror_failed)
            assert.are.same({ md5 = MD5 }, listed)
            assert.matches("?md5=" .. MD5 .. "&key=", apiRequests()[1], 1, true)
            assert.is_nil(apiRequests()[1]:find("domain_index", 1, true))
            -- The link is a secret, kept off curl's command line, and it can expire (see Downloader).
            assert.is_true(AnnasSearch.SECRET_LINKS)
            assert.is_true(AnnasSearch.LINKS_EXPIRE)
            assert.is_true(AnnasSearch.NEW_LINK_WHEN_SERVER_FAILS)
        end)

        -- Changing the server in a signed link would spoil it.
        it("is from the next download server once the last link failed", function()
            answers[API] = { linkAnswer(1), linkAnswer(2), linkAnswer(3) }
            local first = AnnasSearch.findDownloadLink({ md5 = MD5 })
            AnnasSearch.findDownloadLink({ md5 = MD5 }, true, first)
            AnnasSearch.findDownloadLink({ md5 = MD5 }, true, first)
            local asked = apiRequests()
            assert.matches("&domain_index=1$", asked[2])
            assert.matches("&domain_index=2$", asked[3])
        end)

        it("is left to Anna's Archive where it has no such download server", function()
            answers[API] = { errorAnswer("Invalid domain_index or path_index", 400), linkAnswer(2) }
            local url = AnnasSearch.findDownloadLink({ md5 = MD5 }, true, "https://dl1.example/x")
            assert.matches("^https://dl2%.example/", url)
            local asked = apiRequests()
            assert.matches("&domain_index=1$", asked[1])
            assert.is_nil(asked[2]:find("domain_index", 1, true))
        end)

        it("says what the account can't do", function()
            for err, said in pairs({
                ["Not a member"] = Errors.ANNAS_NOT_MEMBER,
                ["No downloads left"] = Errors.ANNAS_NO_DOWNLOADS_LEFT,
                ["Record not found"] = Errors.ANNAS_FILE_GONE,
                ["Invalid secret key"] = Errors.ANNAS_KEY_REJECTED,
            }) do
                answers[API] = errorAnswer(err, 400)
                local url, why, mirror_failed = AnnasSearch.findDownloadLink({ md5 = MD5 })
                assert.is_nil(url, err)
                assert.are.equal(said, why, err)
                assert.is_false(mirror_failed, err)
                require("fetchanna.api.annasaccount"):setKey(KEY)
            end
        end)

        it("says a site that took too long may have counted it, which asking again for the same book won't", function()
            answers[API] = { nil, require("fetchanna.util.curlutil").getErrorMeaning(28) }
            local url, err = AnnasSearch.findDownloadLink({ md5 = MD5 })
            assert.is_nil(url)
            assert.are.equal(Errors.ANNAS_LINK_TIMED_OUT, err)
        end)

        it("says why when no site could be asked", function()
            local url, err = AnnasSearch.findDownloadLink({ md5 = MD5 })
            assert.is_nil(url)
            assert.are.equal("Anna's Archive didn't answer. Check the Wi-Fi connection, or try again later", err)

            answers[API] = { nil, HttpUtil.CANCELLED }
            assert.are.equal(HttpUtil.CANCELLED, select(2, AnnasSearch.findDownloadLink({ md5 = MD5 })))
        end)

        it("isn't asked for without the key, or for a book without an md5", function()
            assert.are.equal(Errors.UNEXPECTED, select(2, AnnasSearch.findDownloadLink({ md5 = "x" })))
            assert.are.equal(Errors.UNEXPECTED, select(2, AnnasSearch.findDownloadLink({})))
            require("fetchanna.api.annasaccount"):forget()
            assert.are.equal(Errors.ANNAS_NO_KEY, select(2, AnnasSearch.findDownloadLink({ md5 = MD5 })))
            assert.are.same({}, apiRequests())
        end)

        it("says how many fast downloads are left, while that's recent", function()
            assert.is_nil(AnnasSearch.allowance())
            answers[API] = linkAnswer(1)
            AnnasSearch.findDownloadLink({ md5 = MD5 })
            assert.are.equal("20 of 25 a day left", AnnasSearch.allowance())
            assert.is_nil(AnnasSearch.allowance(NOW + 13 * 60 * 60))
        end)
    end)
end)
