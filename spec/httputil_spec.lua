local helper = require("helper")

describe("HttpUtil", function()
    local data_dir, requests, responses, http, HttpUtil

    -- Queues up luasocket responses: {body, ok, status, headers}.
    local function respond(...)
        responses = { ... }
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        requests = {}
        responses = {}
        http = helper.stubs.http
        http.request = function(request)
            table.insert(requests, request)
            request.timeouts = helper.state.http_timeouts
            local response = table.remove(responses, 1) or { "", nil, "connection refused" }
            if response[1] ~= "" then
                request.sink(response[1])
            end
            return response[2], response[3], response[4]
        end
        HttpUtil = require("fetchanna.util.httputil")
    end)

    after_each(helper.cleanup)

    it("fetches a page with a browser user agent, following redirects", function()
        respond({ "<html>results</html>", 1, 200 })

        assert.are.equal("<html>results</html>", HttpUtil.getBody("https://libgen.example/index.php?req=dune"))
        assert.are.equal("https://libgen.example/index.php?req=dune", requests[1].url)
        assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
        assert.is_true(requests[1].redirect)
        assert.is_nil(requests[1].proxy)
    end)

    -- HTTPS requests ignore luasocket's own timeout, and would wait a minute for a site that is down.
    it("waits 10 seconds for an answer and a minute for the page, then puts KOReader's timeouts back", function()
        respond({ "<html>results</html>", 1, 200 })
        HttpUtil.getBody("https://libgen.example")

        assert.are.same({ 10, 60 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
        assert.is_nil(http.TIMEOUT)
    end)

    it("puts KOReader's timeouts back when the request fails", function()
        respond({ "", nil, "timeout" })
        HttpUtil.getBody("https://libgen.example")

        assert.are.same({ 10, 60 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
    end)

    -- E.g. from the TLS library. KOReader would exit on it, without its timeouts being put back.
    it("says what went wrong when KOReader's HTTP raises it rather than returning it", function()
        http.request = function()
            error("wantread")
        end

        local body, err = HttpUtil.getBody("https://libgen.example")
        assert.is_nil(body)
        assert.are.equal("TLS/SSL connection failed", err)
        assert.is_nil(helper.state.http_timeouts)
        assert.is_truthy(helper.logged("warn", "^KOReader's HTTP raised an error rather than returning it"))
    end)

    it("returns the HTTP status, e.g. of an error page", function()
        respond({ "<html>Forbidden</html>", 1, 403 })

        local body, err, status = HttpUtil.getBody("https://libgen.example")
        assert.are.equal("<html>Forbidden</html>", body)
        assert.is_nil(err)
        assert.are.equal(403, status)
    end)

    -- In curl's words, so it can be told apart from other failures, e.g. when the network blocks a site (KindleFetch
    -- #55).
    it("says that a site's name couldn't be looked up as curl does", function()
        for _, said in ipairs({
            "host or service not provided, or not known",
            "No address associated with hostname",
            "temporary failure in name resolution",
        }) do
            respond({ "", nil, said })
            local body, err = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("could not resolve host", err)
            assert.are.equal(HttpUtil.UNRESOLVED, err)
        end
    end)

    it("returns the error when the request fails, and logs it", function()
        respond({ "", nil, "timeout" })

        local body, err = HttpUtil.getBody("https://libgen.example")
        assert.is_nil(body)
        assert.are.equal("request timed out", err)
        assert.are.equal(
            "could not fetch https://libgen.example error: request timed out",
            helper.logged("warn", "^could not fetch")
        )
        -- And logs what KOReader's HTTP said itself.
        assert.is_truthy(helper.logged("info", "^KOReader's HTTP said: timeout"))
    end)

    -- Not in luasocket's and its TLS library's own words, e.g. "wantread".
    it("says what went wrong as curl says it", function()
        for luasocket_err, said in pairs({
            ["timeout"] = "request timed out",
            ["connection refused"] = "failed to connect to server",
            ["Network is unreachable"] = "failed to connect to server",
            ["wantread"] = "TLS/SSL connection failed",
            ["certificate verify failed"] = "TLS certificate verification failed",
            ["closed"] = "failed receiving network data",
            -- And as it was, when curl has no words of its own for it.
            ["something else"] = "something else",
        }) do
            respond({ "", nil, luasocket_err })
            local _, err = HttpUtil.getBody("https://libgen.example")
            assert.are.equal(said, err)
        end
    end)

    it("treats an empty page as a failure", function()
        respond({ "", 1, 200 })
        assert.is_nil(HttpUtil.getBody("https://libgen.example"))
    end)

    -- Where it's turned on, as for KOReader's own requests.
    it("goes through KOReader's HTTP proxy", function()
        helper.stubs.http.PROXY = "http://koreader.example:3128"
        respond({ "<html>ok</html>", 1, 200 })

        assert.are.equal("<html>ok</html>", HttpUtil.getBody("https://libgen.example"))
        assert.are.equal("http://koreader.example:3128", requests[1].proxy)
    end)

    it("goes without a proxy where there's none, asking once", function()
        respond({ "", nil, "connection refused" })

        assert.is_nil(HttpUtil.getBody("https://libgen.example"))
        assert.are.equal(1, #requests)
        assert.is_nil(requests[1].proxy)
    end)

    -- curl asks for pages compressed, which Library Genesis sends several times sooner, and doesn't block KOReader
    -- while it waits.
    describe("posting a form", function()
        local form = { { "email", "reader@example.com" }, { "password", "p@ss word" }, { "languages[]", "english" } }

        it("sends its fields, as a browser does", function()
            respond({ '{"success":1}', 1, 200 })

            assert.are.equal(
                '{"success":1}',
                HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = form })
            )
            assert.are.equal("POST", requests[1].method)
            local body = "email=reader%40example.com&password=p%40ss%20word&languages%5B%5D=english"
            assert.are.equal(body, requests[1].source.text)
            assert.are.equal("application/x-www-form-urlencoded", requests[1].headers["Content-Type"])
            assert.are.equal(tostring(#body), requests[1].headers["Content-Length"])
        end)

        -- A field can be a password.
        it("logs the names of its fields, but not what's in them", function()
            respond({ '{"success":1}', 1, 200 })
            HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = form })

            assert.is_truthy(
                helper.logged(
                    "dbg",
                    "^posting email, password, languages%[%] to https://z%-lib%.example/eapi/user/login$"
                )
            )
            for _, log in ipairs(helper.state.logs) do
                for i = 2, #log do
                    assert.is_nil(tostring(log[i]):find("p@ss", 1, true))
                end
            end
        end)
    end)

    it("sends the cookies it's given", function()
        respond({ "<html>profile</html>", 1, 200 })
        HttpUtil.getBody("https://z-lib.example/eapi/user/profile", { cookies = "remix_userid=1; remix_userkey=abc" })

        assert.are.equal("GET", requests[1].method)
        assert.are.equal("remix_userid=1; remix_userkey=abc", requests[1].headers["Cookie"])
    end)

    -- A site's browser check can do that. luasocket can't follow it by itself, as it doesn't keep cookies.
    it("asks again with the cookie a site answers with, along with a redirect back to where it was", function()
        respond({
            "",
            1,
            307,
            {
                location = "https://z-lib.example/eapi/user/login",
                ["set-cookie"] = "__wall=xyz; Path=/; Expires=Fri, 09 Oct 2026 12:00:00 GMT; Secure",
            },
        }, { '{"success":1}', 1, 200 })

        local body = HttpUtil.getBody(
            "https://z-lib.example/eapi/user/login",
            { form = { { "email", "a@b.c" } }, cookies = "remix_userid=1" }
        )
        assert.are.equal('{"success":1}', body)
        assert.are.equal(2, #requests)
        assert.is_false(requests[1].redirect)
        assert.are.equal("remix_userid=1; __wall=xyz", requests[2].headers["Cookie"])
        assert.are.equal("POST", requests[2].method)
        assert.are.equal("email=a%40b.c", requests[2].source.text)
    end)

    -- For a caller that checks where a redirect goes before going there (see OriginPolicy.resolveRedirect).
    describe("asked not to follow redirects", function()
        it("answers with the redirect itself, and where it goes", function()
            respond({ "", 1, 302, { location = "/search?q=dune&check=1" } })

            local body, err, status, headers =
                HttpUtil.getBody("https://annas.example/search?q=dune", { follow_redirects = false })
            assert.are.equal("", body)
            assert.is_nil(err)
            assert.are.equal(302, status)
            assert.are.equal("/search?q=dune&check=1", headers.location)
            assert.is_false(requests[1].redirect)
            assert.are.equal(1, #requests)
        end)

        it("doesn't ask again with a cookie the redirect sets", function()
            respond({
                "",
                1,
                307,
                { location = "https://annas.example/account/", ["set-cookie"] = "aa=1; Path=/" },
            }, { "<html>account</html>", 1, 200 })

            local body, _, status = HttpUtil.getBody(
                "https://annas.example/account/",
                { form = { { "key", "x" } }, follow_redirects = false }
            )
            assert.are.equal("", body)
            assert.are.equal(307, status)
            assert.are.equal(1, #requests)
        end)

        it("still takes an empty page that isn't a redirect to be no answer", function()
            respond({ "", 1, 200, {} })
            local body, err, status = HttpUtil.getBody("https://annas.example/", { follow_redirects = false })
            assert.is_nil(body)
            assert.are.equal("empty response (HTTP 200)", err)
            assert.are.equal(200, status)
        end)
    end)

    it("never follows a redirect with a secret in the address, even when asked to", function()
        respond({ "", 1, 302, { location = "https://elsewhere.example/" } })
        local body, _, status = HttpUtil.getBody(
            "https://annas.example/dyn/api/fast_download.json?key=AbCdEfG2hJkLmNoPqRsTuVwXyZ23456",
            { sensitive = true, follow_redirects = true }
        )
        assert.are.equal("", body)
        assert.are.equal(302, status)
        assert.is_false(requests[1].redirect)
        assert.are.equal(1, #requests)
    end)

    it("answers with the headers it was sent, by their names in lower case", function()
        respond({ '{"error":"No downloads left"}', 1, 429, { ["retry-after"] = "3600" } })
        local body, _, status, headers = HttpUtil.getBody("https://annas.example/dyn/api", { headers = true })
        assert.are.equal('{"error":"No downloads left"}', body)
        assert.are.equal(429, status)
        assert.are.equal("3600", headers["retry-after"])
    end)

    describe("with a curl that can fetch pages", function()
        local fetches

        -- Pretends to be curl: saves the page in the file it was told to, then prints the status and its exit code.
        local function curlAnswers(answer)
            helper.stubCommand("curl -sL -o", function(cmd)
                table.insert(fetches, cmd)
                local page, status, exit_code = answer(cmd)
                if page then
                    helper.writeFile(cmd:match("%-o '([^']+)'"), page)
                end
                return string.format("%s %d\n", status or "000", exit_code or 0)
            end)
        end

        before_each(function()
            fetches = {}
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
        end)

        -- A curl built without TLS, or too old for a site's, can't.
        describe("when curl can't connect securely", function()
            before_each(function()
                curlAnswers(function()
                    return nil, nil, 35
                end)
            end)

            it("fetches the page with KOReader's own HTTP instead", function()
                respond({ "<html>results</html>", 1, 200 })
                local body, err, status = HttpUtil.getBody("https://libgen.example")
                assert.are.equal("<html>results</html>", body)
                assert.is_nil(err)
                assert.are.equal(200, status)
                assert.are.equal(1, #fetches)
                assert.are.equal(1, #requests)
                assert.is_truthy(helper.logged("warn", "^curl couldn't connect to libgen.example securely"))
            end)

            it("says curl's error when KOReader's own HTTP can't either", function()
                respond({ "", nil, "certificate verify failed" })
                local body, err = HttpUtil.getBody("https://libgen.example")
                assert.is_nil(body)
                assert.are.equal("TLS/SSL connection failed", err)
            end)

            -- Not after the first: one site's certificate can have expired, which KOReader's HTTP may not check, and
            -- curl would be given up on when it works.
            it("fetches pages with KOReader's own HTTP from then on, once curl couldn't 3 times in a row", function()
                for i = 1, 3 do
                    respond({ "<html>page " .. i .. "</html>", 1, 200 })
                    HttpUtil.getBody("https://libgen.example/" .. i)
                end
                assert.is_false(require("fetchanna.util.curlutil").canFetch())
                respond({ "<html>page 4</html>", 1, 200 })
                HttpUtil.getBody("https://libgen.example/4")
                assert.are.equal(3, #fetches)
            end)

            it("keeps fetching pages with curl when it connects in between", function()
                for i = 1, 4 do
                    if i == 3 then
                        curlAnswers(function()
                            return "<html>curl</html>", 200, 0
                        end)
                    else
                        curlAnswers(function()
                            return nil, nil, 35
                        end)
                    end
                    respond({ "<html>page " .. i .. "</html>", 1, 200 })
                    HttpUtil.getBody("https://libgen.example/" .. i)
                end
                assert.is_true(require("fetchanna.util.curlutil").canFetch())
            end)
        end)

        it("fetches the page with curl rather than luasocket, within the same time limits", function()
            curlAnswers(function()
                return "<html>results</html>\n", 200
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example/index.php?req=dune")
            assert.are.equal("<html>results</html>", body)
            assert.is_nil(err)
            assert.are.equal(200, status)
            assert.are.equal(0, #requests)
            assert.matches("'https://libgen.example/index.php?req=dune' --compressed", fetches[1], 1, true)
            assert.matches("--connect-timeout 10 --max-time 60", fetches[1], 1, true)
            -- And removes the file the page was fetched into.
            assert.are.same({}, helper.readDir(data_dir .. "/settings/fetchanna_tmp"))
        end)

        it("returns the HTTP status and page of an error", function()
            curlAnswers(function()
                return "<html>Forbidden</html>", 403
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.are.equal("<html>Forbidden</html>", body)
            assert.is_nil(err)
            assert.are.equal(403, status)
        end)

        describe("asked not to follow redirects", function()
            -- Pretends to be curl without -L, writing the headers where it was told to.
            local function curlAnswersWithHeaders(page, status, headers)
                helper.stubCommand("curl -s -o", function(cmd)
                    table.insert(fetches, cmd)
                    if page then
                        helper.writeFile(cmd:match("%-o '([^']+)'"), page)
                    end
                    helper.writeFile(cmd:match("%-D '([^']+)'"), headers)
                    return string.format("%d 0\n", status)
                end)
            end

            it("has curl stop at the redirect, answering with where it goes", function()
                curlAnswersWithHeaders(
                    nil,
                    302,
                    "HTTP/1.1 302 FOUND\r\nServer: ddos-guard\r\nLocation: /search?q=dune&check=1\r\n\r\n"
                )

                local body, err, status, headers =
                    HttpUtil.getBody("https://annas.example/search?q=dune", { follow_redirects = false })
                assert.are.equal("", body)
                assert.is_nil(err)
                assert.are.equal(302, status)
                assert.are.equal("/search?q=dune&check=1", headers.location)
                assert.are.equal("ddos-guard", headers.server)
                assert.is_nil(fetches[1]:find("-sL", 1, true))
                -- And removes the files curl wrote.
                assert.are.same({}, helper.readDir(data_dir .. "/settings/fetchanna_tmp"))
            end)

            it("answers with the page and headers of an error", function()
                curlAnswersWithHeaders(
                    '{"error":"Invalid md5"}',
                    400,
                    "HTTP/1.1 400 BAD REQUEST\r\nContent-Type: text/json; charset=utf-8\r\n\r\n"
                )
                local body, _, status, headers =
                    HttpUtil.getBody("https://annas.example/dyn/api/fast_download.json", { follow_redirects = false })
                assert.are.equal('{"error":"Invalid md5"}', body)
                assert.are.equal(400, status)
                assert.are.equal("text/json; charset=utf-8", headers["content-type"])
            end)
        end)

        it("notes the headers down when asked for them, still following redirects", function()
            curlAnswers(function(cmd)
                helper.writeFile(
                    cmd:match("%-D '([^']+)'"),
                    "HTTP/1.1 301 Moved\r\nLocation: /b\r\n\r\nHTTP/2 200\r\ncontent-type: text/html\r\n"
                        .. "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"
                )
                return "<html>b</html>", 200
            end)
            local body, _, status, headers = HttpUtil.getBody("https://annas.example/a", { headers = true })
            assert.are.equal("<html>b</html>", body)
            assert.are.equal(200, status)
            -- With each cookie, as KOReader's own HTTP has them.
            assert.are.same({ ["content-type"] = "text/html", ["set-cookie"] = "a=1, b=2" }, headers)
        end)

        -- As the member API takes the key in its query (not a real key).
        describe("with a secret in the address", function()
            local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
            local URL = "https://annas.example/dyn/api/fast_download.json?md5=0123456789abcdef0123456789abcdef&key="
                .. KEY

            it("gives it to curl in a file, never on its command line, nor as the referer", function()
                local config
                helper.stubCommand("curl -s -o", function(cmd)
                    table.insert(fetches, cmd)
                    config = helper.readFile(cmd:match("%-K '([^']+)'"))
                    helper.writeFile(cmd:match("%-o '([^']+)'"), '{"error":"Record not found"}')
                    helper.writeFile(cmd:match("%-D '([^']+)'"), "HTTP/1.1 404 NOT FOUND\r\n\r\n")
                    return "404 0\n"
                end)

                local body, _, status = HttpUtil.getBody(URL, { sensitive = true })
                assert.are.equal('{"error":"Record not found"}', body)
                assert.are.equal(404, status)
                assert.are.equal('url = "' .. URL .. '"\n', config)
                assert.is_nil(fetches[1]:find(KEY, 1, true))
                assert.is_nil(fetches[1]:find("annas.example", 1, true))
                assert.is_nil(fetches[1]:find(" -e ", 1, true))
            end)

            it("never follows a redirect, even when asked to", function()
                helper.stubCommand("curl -s -o", function(cmd)
                    table.insert(fetches, cmd)
                    helper.writeFile(
                        cmd:match("%-D '([^']+)'"),
                        "HTTP/1.1 302 FOUND\r\nLocation: https://elsewhere.example/\r\n\r\n"
                    )
                    return "302 0\n"
                end)
                local body, _, status, headers = HttpUtil.getBody(URL, { sensitive = true, follow_redirects = true })
                assert.are.equal("", body)
                assert.are.equal(302, status)
                assert.are.equal("https://elsewhere.example/", headers.location)
                assert.is_nil(fetches[1]:find("-sL", 1, true))
            end)

            it("logs nothing of it", function()
                helper.stubCommand("curl -s -o", " 6\n")
                HttpUtil.getBody(URL, { sensitive = true })
                for _, log in ipairs(helper.state.logs) do
                    for i = 2, #log do
                        assert.is_nil(tostring(log[i]):find(KEY, 1, true))
                    end
                end
                assert.is_truthy(helper.logged("warn", "fast_download%.json%?%[redacted%]"))
            end)
        end)

        it("fails without a status when the site doesn't answer", function()
            curlAnswers(function()
                return nil, "000", 6
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("could not resolve host", err)
            assert.is_nil(status)
        end)

        -- Part of a page of search results would be taken for all of them.
        it("fails when the site stops part of the way through the page", function()
            curlAnswers(function()
                return "<html><table id='tablelibgen'><tbody><tr>", 200, 28
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("request timed out", err)
            assert.is_nil(status)
            assert.are.same({}, helper.readDir(data_dir .. "/settings/fetchanna_tmp"))
        end)

        it("treats an empty page as a failure", function()
            curlAnswers(function()
                return nil, 200
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("empty response (HTTP 200)", err)
            assert.are.equal(200, status)
        end)

        it("says when curl has gone since it was last looked for", function()
            helper.stubCommand("curl -sL -o", " 127\n")

            local body, err = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("curl isn't installed on this device", err)
        end)

        it("holds KOReader up while it waits, when it wasn't asked to wait in the background", function()
            curlAnswers(function()
                return "<html>results</html>", 200
            end)
            HttpUtil.getBody("https://libgen.example")

            assert.are.same({}, helper.state.trapped)
        end)

        -- In a file of its own, not on curl's command line, where any program on the device can read them.
        it("passes curl the form and cookies in a file", function()
            local config
            curlAnswers(function(cmd)
                config = helper.readFile(cmd:match("%-K '([^']+)'"))
                return '{"success":1}', 200
            end)

            local body = HttpUtil.getBody("https://z-lib.example/eapi/user/login", {
                form = { { "email", "a@b.c" }, { "password", "secret" } },
                cookies = "remix_userid=1",
            })
            assert.are.equal('{"success":1}', body)
            assert.are.equal(
                'cookie = ""\nheader = "Cookie: remix_userid=1"\ndata = "email=a%40b.c&password=secret"\n',
                config
            )
            assert.is_nil(fetches[1]:find("secret", 1, true))
        end)

        -- So curl keeps the cookie a site's browser check answers with, which it only does when given no cookies of its
        -- own to send.
        it("has curl keep cookies, even when there are none to send", function()
            local config
            curlAnswers(function(cmd)
                config = helper.readFile(cmd:match("%-K '([^']+)'"))
                return "{}", 200
            end)

            HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = { { "email", "a@b.c" } } })
            assert.are.equal('cookie = ""\ndata = "email=a%40b.c"\n', config)
        end)

        -- Otherwise nothing would be said at all, and the password would be left in a file.
        it("says when curl couldn't be started, rather than that it was called off", function()
            local popen = io.popen
            io.popen = function(cmd, ...)
                if cmd:find(" -w '%{http_code}'", 1, true) then
                    return nil
                end
                return popen(cmd, ...)
            end
            local body, err = HttpUtil.getBody("https://z-lib.example/eapi/user/login", {
                form = { { "password", "secret" } },
            })
            io.popen = popen
            assert.is_nil(body)
            assert.are.equal("could not start curl", err)
            assert.are.same({}, helper.readDir(data_dir .. "/settings/fetchanna_tmp"))

            -- As it does when waiting in the background with a message that wasn't tapped.
            helper.stubs.trapper.wrapped = true
            HttpUtil.setTrapWidget({ text = "Logging in..." })
            helper.state.dismiss = true
            body, err = HttpUtil.getBody("https://z-lib.example/eapi/user/login")
            assert.is_nil(body)
            assert.are.equal("could not start curl", err)
        end)

        it("fetches other pages without a file of options", function()
            curlAnswers(function()
                return "<html>results</html>", 200
            end)

            HttpUtil.getBody("https://libgen.example")
            assert.is_nil(fetches[1]:find(" -K ", 1, true))
        end)

        describe("asked to wait in the background", function()
            local message

            before_each(function()
                helper.stubs.trapper.wrapped = true
                message = { text = "Searching..." }
                HttpUtil.setTrapWidget(message)
                curlAnswers(function()
                    return "<html>results</html>", 200
                end)
            end)

            it("lets KOReader carry on, with a tap on the message given calling it off", function()
                assert.are.equal("<html>results</html>", HttpUtil.getBody("https://libgen.example"))
                assert.are.equal(1, #helper.state.trapped)
                assert.are.equal(message, helper.state.trapped[1].trap_widget)
                assert.are.equal(fetches[1], helper.state.trapped[1].cmd)
            end)

            -- Each search, download and login waits in a coroutine of its own. With one widget for all, hiding a
            -- download while it looked up its link, then starting another, would have the second's Cancel call off the
            -- first.
            it("calls off each coroutine's requests with its own widget", function()
                local first_message, second_message = { text = "Finding a download link..." }, { text = "Searching..." }
                local first = coroutine.create(function()
                    HttpUtil.setTrapWidget(first_message)
                    coroutine.yield()
                    HttpUtil.getBody("https://libgen.example/ads.php")
                    HttpUtil.setTrapWidget(nil)
                end)
                local second = coroutine.create(function()
                    HttpUtil.setTrapWidget(second_message)
                    coroutine.yield()
                    HttpUtil.getBody("https://libgen.example/index.php")
                    HttpUtil.setTrapWidget(nil)
                end)

                assert.is_true(coroutine.resume(first))
                assert.is_true(coroutine.resume(second))
                assert.is_true(coroutine.resume(first))
                assert.is_true(coroutine.resume(second))
                assert.are.equal(first_message, helper.state.trapped[1].trap_widget)
                assert.are.equal(second_message, helper.state.trapped[2].trap_widget)
                -- And what's waited for outside them still has the one given there.
                assert.are.equal(message, HttpUtil.getTrapWidget())
            end)

            it("says so when it's called off", function()
                -- A tap on its Cancel.
                message.cancelled = true
                helper.state.dismiss = true

                local body, err, status = HttpUtil.getBody("https://libgen.example")
                assert.is_nil(body)
                assert.are.equal(HttpUtil.CANCELLED, err)
                assert.is_nil(status)
                assert.are.equal(1, #helper.state.trapped)
                -- It's what was asked for, so not a warning.
                assert.is_nil(helper.logged("warn", "could not fetch"))
            end)
        end)
    end)

    describe("downloading a file", function()
        local path

        before_each(function()
            path = data_dir .. "/curl-armhf"
        end)

        -- A Kindle's own curl is too old to connect to many sites, such as GitHub (KindleFetch #57).
        it("downloads it with KOReader's own HTTP where curl can't fetch, following redirects", function()
            respond({ "\127ELF\0binary", 1, 200 })

            assert.is_true(HttpUtil.downloadFile("https://github.example/releases/curl-armhf", path))
            assert.are.equal("\127ELF\0binary", helper.readFile(path))
            assert.are.equal("https://github.example/releases/curl-armhf", requests[1].url)
            assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
            assert.is_true(requests[1].redirect)
        end)

        -- A file can be several megabytes, and an e-reader's Wi-Fi slow.
        it(
            "waits 10 seconds for an answer and five minutes for the file, then puts KOReader's timeouts back",
            function()
                respond({ "binary", 1, 200 })
                HttpUtil.downloadFile("https://github.example/curl-armhf", path)

                assert.are.same({ 10, 300 }, requests[1].timeouts)
                assert.is_nil(helper.state.http_timeouts)
            end
        )

        it("leaves nothing behind when the download fails", function()
            respond({ "", nil, "timeout" })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("request timed out", err)
            assert.is_false(helper.exists(path))
        end)

        it("leaves nothing behind when KOReader's HTTP raises what went wrong", function()
            http.request = function()
                error("closed")
            end

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("failed receiving network data", err)
            assert.is_false(helper.exists(path))
            assert.is_nil(helper.state.http_timeouts)
        end)

        -- The page saying what's wrong isn't kept in place of the file.
        it("says that the site's name couldn't be looked up as curl does", function()
            respond({ "", nil, "No address associated with hostname" })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("could not resolve host", err)
        end)

        it("leaves nothing behind when the site answers with an error", function()
            respond({ "<html>Not Found</html>", 1, 404 })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("HTTP error response (404)", err)
            assert.is_false(helper.exists(path))
        end)

        it("downloads it with curl where curl can fetch", function()
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
            local CurlUtil = require("fetchanna.util.curlutil")
            local download
            CurlUtil.download = function(url, filepath, max_time, opts)
                download = { url, filepath, max_time, opts }
                return nil, "request timed out"
            end

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("request timed out", err)
            -- For at most 5 minutes, and 30 seconds with nothing arriving, as it blocks KOReader meanwhile.
            assert.are.same({ "https://github.example/curl-armhf", path, 300, { stall_time = 30 } }, download)
            assert.are.equal(0, #requests)
        end)
    end)
end)
