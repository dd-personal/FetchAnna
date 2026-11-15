local helper = require("helper")

describe("AnnasAccount", function()
    -- These are not real keys or sessions, only shaped like them.
    local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
    local SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6MX0.c2lnbmF0dXJlLXZhbHVl_x-y"
    local GL, PK, GD = "https://annas-archive.gl", "https://annas-archive.pk", "https://annas-archive.gd"
    local NOW = 1794440000

    -- Both as captured on 2026-11-11 (see spec/data/annas/PROVENANCE.md).
    local invalid_key_answer = helper.readFile("spec/data/annas/fast-download-401-invalid-key.json")
    local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")
    -- The answer for a file it can't find, made from the one for a bad md5 with the error changed.
    local not_found_answer = helper
        .readFile("spec/data/annas/fast-download-400-invalid-md5.json")
        :gsub('"Invalid md5"', '"Record not found"')
    -- SYNTHESIZED, not captured: no live page could be had without a key. Follows the structure of Anna's Archive's
    -- account page template (allthethings/account/templates/account/index.html at a15b123c), with placeholder text.
    local logged_out_page = [[<html><body><h2>Log in</h2>
<form autocomplete="on" method="post" action="/account/" class="mb-4">
<input type="password" autofocus autocomplete="current-password" id="key" name="key" required placeholder="Key" />
<p class="mb-1 text-red-500">Placeholder: the key wasn't accepted.</p>
<button type="submit">Log in</button></form></body></html>]]
    local function loggedInPage(memberships)
        return [[<html><body><h2>Account</h2><script>window.globalUpdateAaLoggedIn(1);</script>
<div>Placeholder account id</div>]] .. memberships .. [[
<form autocomplete="on" onsubmit="window.submitForm(event, '/dyn/account/logout/', (r) => {})" class="mb-4">
<button>Log out</button></form></body></html>]]
    end
    local member_page = loggedInPage([[
<div class="line-through text-xs ">Placeholder <a href="/donate?tier=5" class="text-sm hidden">tier</a> over</div>
<div class=" ">Placeholder <a href="/donate?tier=3" class="text-sm hidden">tier</a> until later</div>
<!-- Replace "24" in the actual counts with "<span>2</span>4" so it doesn't get broken up when replaced with "18". -->
<div class="">Placeholder: 3 of 50 used</div>
<div class="my-4">Placeholder <a href="/donate">upgrade</a></div>]])
    local non_member_page = loggedInPage([[<div class="mb-4">Placeholder <a href="/donate">become a member</a></div>]])
    local SET_COOKIE = "__ddg8_=a1; Domain=.annas-archive.gl; Path=/; Expires=Wed, 11-Nov-2026 23:35:54 GMT, "
        .. "aa_account_id2="
        .. SESSION
        .. "; Domain=annas-archive.gl; Expires=Wed, 10 Feb 2027 23:13:20 GMT; HttpOnly; Path=/; SameSite=Lax, "
        .. "__ddg1_=X0fszw14; Domain=.annas-archive.gl; HttpOnly; Path=/"

    local data_dir, AnnasAccount, AnnasMirrors, KeyStore, FAILURE, STATUS
    -- What each request is answered with, by method and URL without the query, and each request made.
    local answers, requests

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        answers, requests = {}, {}

        local HttpUtil = require("fetchanna.util.httputil")
        HttpUtil.getBody = function(url, opts)
            opts = opts or {}
            table.insert(requests, { url = url, opts = opts })
            local answer = answers[(opts.form and "POST " or "GET ") .. url:gsub("%?.*$", "")]
            if type(answer) == "function" then
                answer = answer(url, opts)
            end
            answer = answer or { nil, "failed to connect to server" }
            return answer[1], answer[2], answer[3], answer[4] or {}
        end
        require("fetchanna.util.originpolicy").resolve = function()
            return nil
        end
        AnnasAccount = require("fetchanna.api.annasaccount")
        AnnasMirrors = require("fetchanna.api.annasmirrors")
        KeyStore = require("fetchanna.api.keystore")
        FAILURE, STATUS = AnnasMirrors.FAILURE, AnnasAccount.STATUS
    end)

    after_each(helper.cleanup)

    local function apiAnswers(origin, answer)
        answers["GET " .. origin .. "/dyn/api/fast_download.json"] = answer
    end
    local function everythingLogged()
        local parts = {}
        for _, log in ipairs(helper.state.logs) do
            for i = 2, #log do
                table.insert(parts, tostring(log[i]))
            end
        end
        return table.concat(parts, "\n")
    end

    describe("its key", function()
        it("is taken without the space around it, once it's as Anna's Archive's keys are", function()
            assert.are.equal(STATUS.NO_KEY, AnnasAccount:status().status)
            assert.is_true(AnnasAccount:setKey("  " .. KEY .. "\n"))
            assert.are.equal(KEY, KeyStore.getKey())
            assert.are.equal(STATUS.UNVERIFIED, AnnasAccount:status().status)

            local ok, err = AnnasAccount:setKey("my password")
            assert.is_nil(ok)
            assert.are.equal("That isn't a secret key: it's letters and digits, at least 20 of them.", err)
        end)

        it("is forgotten with its sessions", function()
            AnnasAccount:setKey(KEY)
            KeyStore.setSession(GL, SESSION, NOW + 60)
            AnnasAccount:forget()
            assert.are.equal(STATUS.NO_KEY, AnnasAccount:status().status)
            assert.is_nil(KeyStore.getSession(GL))
        end)
    end)

    -- Without using any of the account's downloads.
    describe("checking the key", function()
        before_each(function()
            AnnasAccount:setKey(KEY)
        end)

        it("asks the member API for a file no one has, which it can't find once it has taken the key", function()
            apiAnswers(GD, { not_found_answer, nil, 404 })
            assert.is_true(AnnasAccount:verify())

            local url = requests[1].url
            local md5, key = url:match("^https://annas%-archive%.gd/dyn/api/fast_download%.json%?md5=(%x+)&key=(%w+)$")
            assert.are.equal(32, #md5)
            assert.are.equal(string.format("%08x", NOW), md5:sub(1, 8))
            assert.are.equal(KEY, key)
            -- To curl in a file, with no redirect followed, and never logged.
            assert.is_true(requests[1].opts.sensitive)
            assert.is_nil(everythingLogged():find(KEY, 1, true))
            local status = AnnasAccount:status()
            assert.are.equal(STATUS.VALID, status.status)
            assert.are.equal(NOW, status.verified_at)
        end)

        it("asks for a different file each time", function()
            apiAnswers(GD, { not_found_answer, nil, 404 })
            AnnasAccount:verify()
            AnnasAccount:verify()
            assert.are_not.equal(requests[1].url, requests[2].url)
        end)

        it("says the key isn't accepted, without asking other sites", function()
            apiAnswers(GD, { invalid_key_answer, nil, 401 })
            KeyStore.setSession(GL, SESSION, NOW + 60)
            local ok, outcome = AnnasAccount:verify()
            assert.is_nil(ok)
            assert.are.equal(FAILURE.INVALID_KEY, outcome.failure)
            assert.are.equal(1, #requests)
            assert.are.equal(STATUS.INVALID, AnnasAccount:status().status)
            assert.is_nil(KeyStore.getSession(GL))
        end)

        it("says when Anna's Archive couldn't be asked, rather than that the key is wrong", function()
            for _, origin in ipairs({ GL, PK, GD }) do
                apiAnswers(origin, { challenge, nil, 403 })
            end
            local ok, outcome = AnnasAccount:verify()
            assert.is_nil(ok)
            assert.are.equal(FAILURE.CHALLENGE, outcome.failure)
            local status = AnnasAccount:status()
            assert.are.equal(STATUS.UNREACHABLE, status.status)
            assert.are.equal(FAILURE.CHALLENGE, status.failure)
        end)

        it("only ever sends the key to sites trusted with it", function()
            for _, origin in ipairs({ GL, PK, GD }) do
                AnnasMirrors:revoke(origin)
            end
            local ok, outcome = AnnasAccount:verify()
            assert.is_nil(ok)
            assert.are.equal(FAILURE.NO_TRUSTED, outcome.failure)
            assert.are.equal(0, #requests)
        end)

        it("doesn't take an answer that isn't the member API's", function()
            apiAnswers(GD, { "<html>Record not found</html>", nil, 404 })
            apiAnswers(GL, { not_found_answer, nil, 404 })
            assert.is_true(AnnasAccount:verify())
            assert.are.equal(2, #requests)
        end)
    end)

    describe("logging in", function()
        before_each(function()
            AnnasAccount:setKey(KEY)
        end)

        it("posts the key, keeping the session it's answered with for that site only", function()
            answers["POST " .. GD .. "/account/"] =
                { "", nil, 302, { location = "/account/", ["set-cookie"] = SET_COOKIE } }
            answers["GET " .. GD .. "/account/"] = { member_page, nil, 200 }
            assert.are.equal(GD, AnnasAccount:login())

            assert.are.same({ { "key", KEY } }, requests[1].opts.form)
            assert.is_true(requests[1].opts.sensitive)
            assert.are.equal(SESSION, KeyStore.getSession(GD))
            assert.are.equal("aa_account_id2=" .. SESSION, AnnasAccount:sessionCookie(GD))
            -- Never sent to another site, even one of Anna's Archive's own.
            assert.is_nil(AnnasAccount:sessionCookie(GL))
            -- The account page is read with it, and only it.
            assert.are.equal("aa_account_id2=" .. SESSION, requests[2].opts.cookies)
            assert.is_nil(everythingLogged():find(SESSION, 1, true))
            assert.is_nil(everythingLogged():find(KEY, 1, true))

            local status = AnnasAccount:status()
            assert.are.equal(STATUS.LOGGED_IN, status.status)
            assert.are.equal(3, status.tier)
            assert.are.same({ downloads = 50, searches = 180 }, status.allows)
            assert.are.same({ { origin = GD, expires_at = 1802301200, created_at = NOW } }, status.sessions)
        end)

        it("says the key isn't accepted when the login page is shown again", function()
            answers["POST " .. GD .. "/account/"] = { logged_out_page, nil, 200 }
            local origin, outcome = AnnasAccount:login()
            assert.is_nil(origin)
            assert.are.equal(FAILURE.INVALID_KEY, outcome.failure)
            assert.are.equal(1, #requests)
            assert.are.equal(STATUS.INVALID, AnnasAccount:status().status)
        end)

        it("tries the next site when one asks for a browser check", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { location = "/account/?check=1" } }
            answers["POST " .. GL .. "/account/"] = { "", nil, 302, { ["set-cookie"] = SET_COOKIE } }
            answers["GET " .. GL .. "/account/"] = { non_member_page, nil, 200 }
            assert.are.equal(GL, AnnasAccount:login())
            local status = AnnasAccount:status()
            assert.are.equal(0, status.tier)
            -- Tier 0 allows nothing.
            assert.is_nil(status.allows)
        end)

        it("isn't logged in on a site once it's revoked, which forgets its session", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { ["set-cookie"] = SET_COOKIE } }
            AnnasAccount:login()
            AnnasMirrors:revoke(GD)
            assert.is_nil(AnnasAccount:sessionCookie(GD))
            assert.is_nil(KeyStore.getSession(GD))
            assert.are.equal(STATUS.VALID, AnnasAccount:status().status)
        end)

        it("isn't logged in once the session has expired", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { ["set-cookie"] = SET_COOKIE } }
            AnnasAccount:login()
            helper.state.time = 1802301200
            assert.are.equal(STATUS.VALID, AnnasAccount:status().status)
        end)

        it("forgets a session the account page no longer takes", function()
            answers["POST " .. GD .. "/account/"] = { "", nil, 302, { ["set-cookie"] = SET_COOKIE } }
            answers["GET " .. GD .. "/account/"] = { logged_out_page, nil, 200 }
            AnnasAccount:login()
            assert.is_nil(KeyStore.getSession(GD))
        end)

        it("doesn't take a page that logs in without a session to have logged in", function()
            answers["POST " .. GD .. "/account/"] = { "<html>Welcome!</html>", nil, 200 }
            answers["POST " .. GL .. "/account/"] = { "", nil, 302, { location = "https://elsewhere.example/" } }
            local origin, outcome = AnnasAccount:login()
            assert.is_nil(origin)
            assert.are.same(
                { origin = GD, failure = FAILURE.UNEXPECTED, detail = "no login session" },
                outcome.tried[1]
            )
            assert.are.equal(FAILURE.REDIRECTED, outcome.tried[2].failure)
        end)
    end)

    describe("connecting", function()
        before_each(function()
            AnnasAccount:setKey(KEY)
        end)

        -- The member API can be asked there, but not the account page.
        it("checks the key when no site lets FetchAnna log in, saying why it couldn't", function()
            for _, origin in ipairs({ GL, PK, GD }) do
                answers["POST " .. origin .. "/account/"] = { challenge, nil, 403 }
            end
            apiAnswers(GD, { not_found_answer, nil, 404 })
            local ok, outcome = AnnasAccount:connect()
            assert.is_true(ok)
            assert.are.equal(FAILURE.CHALLENGE, outcome.failure)
            local status = AnnasAccount:status()
            assert.are.equal(STATUS.VALID, status.status)
            assert.are.equal(FAILURE.CHALLENGE, status.failure)
        end)

        it("doesn't check the key again once logging in said it's wrong", function()
            answers["POST " .. GD .. "/account/"] = { logged_out_page, nil, 200 }
            local ok, outcome = AnnasAccount:connect()
            assert.is_nil(ok)
            assert.are.equal(FAILURE.INVALID_KEY, outcome.failure)
            assert.are.equal(1, #requests)
        end)
    end)

    describe("sessionFrom", function()
        it("reads the session and when it expires from the cookies a response sets", function()
            assert.are.same({ SESSION, 1802301200 }, { AnnasAccount.sessionFrom(SET_COOKIE, NOW) })
            assert.are.same(
                { SESSION, NOW + 600 },
                { AnnasAccount.sessionFrom("aa_account_id2=" .. SESSION .. "; Max-Age=600; Path=/", NOW) }
            )
            -- Without an expiry, as long as Anna's Archive's last.
            assert.are.same(
                { SESSION, NOW + 90 * 86400 },
                { AnnasAccount.sessionFrom("aa_account_id2=" .. SESSION, NOW) }
            )
        end)

        it("doesn't take a cookie that clears the session, has expired, or isn't Anna's", function()
            for _, header in ipairs({
                "aa_account_id2=; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                "aa_account_id2=" .. SESSION .. "; Max-Age=0",
                "aa_account_id2=" .. SESSION .. "; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                "xaa_account_id2=" .. SESSION,
                "path=/aa_account_id2=" .. SESSION,
                'aa_account_id2=bad"value',
                "__ddg1_=abc",
            }) do
                assert.is_nil(AnnasAccount.sessionFrom(header, NOW), header)
            end
            assert.is_nil(AnnasAccount.sessionFrom(nil, NOW))
        end)
    end)

    describe("parseAccountPage", function()
        it("reads the highest membership that isn't over", function()
            assert.are.same({ logged_in = true, tier = 3, memberships = 2 }, AnnasAccount.parseAccountPage(member_page))
        end)

        it("reads that there's no membership when it asks to become a member", function()
            assert.are.same(
                { logged_in = true, tier = 0, memberships = 0 },
                AnnasAccount.parseAccountPage(non_member_page)
            )
        end)

        -- Unknown, not none.
        it("can't tell the membership of a member's page it can't read the memberships of", function()
            local changed = member_page:gsub("/donate%?tier=", "/upgrade?to=")
            assert.are.same({ logged_in = true, tier = nil, memberships = 0 }, AnnasAccount.parseAccountPage(changed))
        end)

        it("isn't logged in on the page to log in with, or anything else", function()
            assert.is_false(AnnasAccount.parseAccountPage(logged_out_page).logged_in)
            assert.is_false(AnnasAccount.parseAccountPage(challenge).logged_in)
            assert.is_false(AnnasAccount.parseAccountPage(nil).logged_in)
            assert.is_true(AnnasAccount.isLoginPage(logged_out_page))
            assert.is_false(AnnasAccount.isLoginPage(member_page))
        end)
    end)

    describe("asking for a download link", function()
        local MD5 = "0123456789abcdef0123456789abcdef"
        local LINK = "https://dl.example/d3/y/1794440000/c2lnbmVk/" .. MD5 .. ".epub"
        -- SYNTHESIZED from the member API's documented answer (see docs/annas-protocol.md), as no real download link
        -- was captured: the fields its code sets, around one of its documentation lines.
        local function linkAnswer(link, left)
            return string.format(
                '{"download_url": "%s", "account_fast_download_info": {"downloads_left": %d, "downloads_per_day": 25, '
                    .. '"downloads_done_today": %d, "recently_downloaded_md5s": ["%s"]}, '
                    .. '"///download_url": ["Placeholder documentation line."]}',
                link,
                left,
                25 - left,
                MD5
            )
        end
        local function errorAnswer(err)
            return not_found_answer:gsub('"Record not found"', '"' .. err .. '"')
        end

        before_each(function()
            AnnasAccount:setKey(KEY)
        end)

        it("asks the member API for the file's link, with the key, as a secret that's never logged", function()
            apiAnswers(GD, { linkAnswer(LINK, 21), nil, 200 })
            local answer = AnnasAccount:fastDownload(MD5)
            assert.are.equal(LINK, answer.download_url)

            assert.are.equal(
                "https://annas-archive.gd/dyn/api/fast_download.json?md5=" .. MD5 .. "&key=" .. KEY,
                requests[1].url
            )
            assert.is_true(requests[1].opts.sensitive)
            local logged = everythingLogged()
            assert.is_nil(logged:find(KEY, 1, true))
            assert.is_nil(logged:find("c2lnbmVk", 1, true))
            assert.is_truthy(helper.logged("info", "^Anna's Archive gave a download link to dl%.example"))
            -- It notes how many downloads are left.
            local status = AnnasAccount:status()
            assert.are.equal(21, status.downloads_left)
            assert.are.equal(25, status.downloads_per_day)
            assert.are.equal(STATUS.VALID, status.status)
            -- And where the link came from and went to, by name only (see Diagnostics).
            assert.is_number(status.last_link.at)
            assert.are.equal("annas-archive.gd", status.last_link.site)
            assert.are.equal("dl.example", status.last_link.server)
        end)

        it("notes nothing of a link it didn't get", function()
            apiAnswers(GD, { errorAnswer("No downloads left"), nil, 429 })
            AnnasAccount:fastDownload(MD5)
            assert.is_nil(AnnasAccount:status().last_link)
        end)

        it("asks for the link to another of its download servers when told to", function()
            apiAnswers(GD, { linkAnswer(LINK, 21), nil, 200 })
            AnnasAccount:fastDownload(MD5, 2)
            assert.matches("&domain_index=2$", requests[1].url)
        end)

        it("doesn't take a link that isn't https on the internet", function()
            for _, link in ipairs({ "http://dl.example/x.epub", "https://192.168.1.1/x.epub", "file:///etc/passwd" }) do
                requests = {}
                for _, origin in ipairs({ GL, PK, GD }) do
                    apiAnswers(origin, { linkAnswer(link, 21), nil, 200 })
                end
                local answer, outcome = AnnasAccount:fastDownload(MD5)
                assert.is_nil(answer, link)
                assert.are.equal(FAILURE.UNEXPECTED, outcome.failure, link)
            end
        end)

        it("says what the account can't do, without asking other sites", function()
            for err, failure in pairs({
                ["Not a member"] = FAILURE.NOT_MEMBER,
                ["No downloads left"] = FAILURE.QUOTA,
                ["Record not found"] = FAILURE.NOT_FOUND,
                ["Invalid domain_index or path_index"] = FAILURE.UNAVAILABLE,
            }) do
                requests = {}
                apiAnswers(GD, { errorAnswer(err), nil, 400 })
                local answer, outcome = AnnasAccount:fastDownload(MD5)
                assert.is_nil(answer, err)
                assert.are.equal(failure, outcome.failure, err)
                assert.are.equal(1, #requests, err)
            end
        end)

        it("notes that the account has no downloads left, or no membership", function()
            AnnasAccount:noteFastDownloadInfo({ downloads_left = 3, downloads_per_day = 25 })
            apiAnswers(GD, { errorAnswer("No downloads left"), nil, 429 })
            AnnasAccount:fastDownload(MD5)
            assert.are.equal(0, AnnasAccount:status().downloads_left)

            apiAnswers(GD, { errorAnswer("Not a member"), nil, 403 })
            AnnasAccount:fastDownload(MD5)
            assert.are.equal(FAILURE.NOT_MEMBER, AnnasAccount:status().failure)
        end)

        it("forgets the sessions when the key isn't accepted", function()
            KeyStore.setSession(GL, SESSION, NOW + 60)
            apiAnswers(GD, { invalid_key_answer, nil, 401 })
            local _, outcome = AnnasAccount:fastDownload(MD5)
            assert.are.equal(FAILURE.INVALID_KEY, outcome.failure)
            assert.are.equal(STATUS.INVALID, AnnasAccount:status().status)
            assert.is_nil(KeyStore.getSession(GL))
        end)

        -- The site may have counted the download already. Asking again for the same file won't count again.
        it("says when a site took too long to answer after being asked", function()
            apiAnswers(GD, { nil, require("fetchanna.util.curlutil").getErrorMeaning(28), nil })
            apiAnswers(GL, { nil, "failed to connect to server", nil })
            apiAnswers(PK, { nil, "failed to connect to server", nil })
            local answer, outcome = AnnasAccount:fastDownload(MD5)
            assert.is_nil(answer)
            assert.is_true(outcome.may_have_counted)

            requests = {}
            for _, origin in ipairs({ GL, PK, GD }) do
                apiAnswers(origin, { nil, "failed to connect to server", nil })
            end
            answer, outcome = AnnasAccount:fastDownload(MD5)
            assert.is_nil(answer)
            assert.is_nil(outcome.may_have_counted)
        end)

        it("isn't asked for without a key, or for anything but an md5", function()
            AnnasAccount:forget()
            local _, outcome = AnnasAccount:fastDownload(MD5)
            assert.are.equal(FAILURE.INVALID_KEY, outcome.failure)
            AnnasAccount:setKey(KEY)
            for _, md5 in ipairs({ MD5:upper(), MD5 .. "0", "../../account", nil }) do
                _, outcome = AnnasAccount:fastDownload(md5)
                assert.are.equal(FAILURE.NOT_FOUND, outcome.failure)
            end
            assert.are.equal(0, #requests)
        end)
    end)

    it("notes how many fast downloads the member API says are left", function()
        AnnasAccount:setKey(KEY)
        local info = { downloads_left = 47, downloads_per_day = 50, recently_downloaded_md5s = {} }
        AnnasAccount:noteFastDownloadInfo(info)
        local status = AnnasAccount:status()
        assert.are.equal(47, status.downloads_left)
        assert.are.equal(50, status.downloads_per_day)
        assert.are.equal(NOW, status.downloads_checked_at)
    end)
end)
