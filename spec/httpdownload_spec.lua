local helper = require("helper")

-- Downloads with KOReader's own HTTP where curl can't, as on a Kobo without curl (KindleFetch #63).
describe("HttpDownload", function()
    local data_dir, path, headers_file, requests, CurlUtil, HttpDownload

    -- Has KOReader's HTTP answer with body, and return the rest.
    local function answer(body, ...)
        local returned = { ... }
        helper.stubs.http.request = function(request)
            table.insert(requests, request)
            request.timeouts = helper.state.http_timeouts
            if body then
                request.sink(body)
            end
            return unpack(returned, 1, 4)
        end
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        path = data_dir .. "/Dune.epub.part"
        headers_file = data_dir .. "/headers"
        requests = {}
        CurlUtil = require("fetchanna.util.curlutil")
        HttpDownload = require("fetchanna.util.httpdownload")
    end)

    after_each(helper.cleanup)

    it("downloads the file in a process of its own, followed as curl's downloads are", function()
        answer("epub data", 1, 200, { ["content-length"] = "9" }, "HTTP/1.1 200 OK")
        local pid, exit_file = HttpDownload.start("https://libgen.example/get.php?md5=abc", path, {
            headers_file = headers_file,
            stall_time = 30,
        })

        assert.are.equal(helper.state.subprocesses[1], pid)
        assert.are.equal(0, CurlUtil.getExitCode(exit_file))
        assert.are.equal("epub data", helper.readFile(path))
        -- It writes the headers curl would, for the size.
        assert.are.equal(9, CurlUtil.getDownloadSize(headers_file))
        assert.are.equal(200, CurlUtil.getDownloadStatus(headers_file))
        -- Sent as curl sends them. Gives up once nothing has arrived for a while, however long it all takes.
        assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
        assert.are.equal("https://libgen.example/", requests[1].headers["Referer"])
        assert.are.same({ 30, -1 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
    end)

    it("says the site answered with an error as curl does", function()
        answer("<html>Not Found</html>", 1, 404, {}, "HTTP/1.1 404 Not Found")
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path, { headers_file = headers_file })
        assert.are.equal(22, CurlUtil.getExitCode(exit_file))
        assert.are.equal(404, CurlUtil.getDownloadStatus(headers_file))
    end)

    it("says what went wrong as curl would have", function()
        for luasocket_err, exit_code in pairs({
            ["timeout"] = 28,
            ["host not found"] = 6,
            ["connection refused"] = 7,
            ["wantread"] = 35,
            ["something else"] = 56,
        }) do
            answer(nil, nil, luasocket_err)
            local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path)
            assert.are.equal(exit_code, CurlUtil.getExitCode(exit_file), luasocket_err)
        end

        -- Including an error it raises instead of returning.
        helper.stubs.http.request = function()
            error("closed")
        end
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path)
        assert.are.equal(56, CurlUtil.getExitCode(exit_file))
    end)

    it("says when the file can't be written, as curl does", function()
        answer("epub data", 1, 200)
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", data_dir .. "/missing/Dune.epub")
        assert.are.equal(23, CurlUtil.getExitCode(exit_file))
    end)

    describe("a link that's a secret itself", function()
        -- Has KOReader's HTTP answer each request with the next of responses: { body, code, headers }.
        local function answerInTurn(responses)
            helper.stubs.http.request = function(request)
                table.insert(requests, request)
                local response = responses[#requests] or responses[#responses]
                request.sink(response[1])
                request.sink(nil)
                return 1, response[2], response[3] or {}, "HTTP/1.1 " .. response[2]
            end
        end
        local LINK = "https://dl.example/d3/y/1763000000/abcdef0123456789/Dune.epub"

        it("isn't sent as the referer, and redirects aren't left to KOReader's HTTP", function()
            answer("epub data", 1, 200, {}, "HTTP/1.1 200 OK")
            local _, exit_file = HttpDownload.start(LINK, path, { sensitive = true })
            assert.are.equal(0, CurlUtil.getExitCode(exit_file))
            assert.is_nil(requests[1].headers["Referer"])
            assert.is_false(requests[1].redirect)
        end)

        it("is followed through redirects to https, keeping only what's at the end", function()
            answerInTurn({
                { "moved", 302, { location = "https://cdn.example/f/Dune.epub" } },
                { "moved again", 301, { location = "/g/Dune.epub" } },
                { "epub data", 200 },
            })
            local _, exit_file = HttpDownload.start(LINK, path, { sensitive = true, headers_file = headers_file })
            assert.are.equal(0, CurlUtil.getExitCode(exit_file))
            assert.are.equal("epub data", helper.readFile(path))
            assert.are.same(
                { LINK, "https://cdn.example/f/Dune.epub", "https://cdn.example/g/Dune.epub" },
                { requests[1].url, requests[2].url, requests[3].url }
            )
            assert.are.equal(200, CurlUtil.getDownloadStatus(headers_file))
            for __, request in ipairs(requests) do
                assert.is_nil(request.headers["Referer"])
            end
        end)

        it("isn't followed anywhere but https, as curl's --proto-redir has it", function()
            local locations = { "http://dl.example/Dune.epub", "ftp://dl.example/Dune.epub", "//x.example/" }
            for __, location in ipairs(locations) do
                requests = {}
                answerInTurn({ { "moved", 302, { location = location } }, { "epub data", 200 } })
                local _, exit_file = HttpDownload.start(LINK, path, { sensitive = true })
                assert.are.equal(1, CurlUtil.getExitCode(exit_file), location)
                assert.are.equal(1, #requests, location)
                assert.is_false(helper.exists(path), location)
            end
        end)

        it("gives up after as many redirects as curl would", function()
            answerInTurn({ { "moved", 302, { location = "https://dl.example/again" } } })
            local _, exit_file = HttpDownload.start(LINK, path, { sensitive = true })
            assert.are.equal(47, CurlUtil.getExitCode(exit_file))
            assert.are.equal(6, #requests)
        end)

        it("is never logged", function()
            require("fetchanna.util.logutil").addSecret(LINK)
            answer(nil, nil, "timeout")
            HttpDownload.start(LINK, path, { sensitive = true })
            assert.is_nil(helper.allLogged():find("abcdef0123456789", 1, true))
        end)
    end)

    it("says when its process couldn't be started", function()
        helper.state.fork_fails = true
        local pid, err = HttpDownload.start("https://libgen.example/get.php", path)
        assert.is_nil(pid)
        assert.are.equal("could not start downloading", err)
    end)

    it("downloads several files one after another, saying how each went as curl does", function()
        local covers = { data_dir .. "/a.jpg", data_dir .. "/b.jpg" }
        helper.stubs.http.request = function(request)
            if request.url:find("a.jpg", 1, true) then
                request.sink("jpeg")
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end
            return nil, "timeout"
        end

        local pid, exit_file, config_file =
            HttpDownload.startMultiple({ "https://covers.example/a.jpg", "https://covers.example/b.jpg" }, covers)
        assert.is_not_nil(pid)
        local results = CurlUtil.getTransferResults(CurlUtil.getResultsFile(config_file))
        assert.are.same({ [covers[1]] = 0, [covers[2]] = 28 }, results)
        assert.are.equal("jpeg", helper.readFile(covers[1]))
        assert.is_false(helper.exists(covers[2]))
        assert.are.equal(28, CurlUtil.getExitCode(exit_file))
    end)

    -- Otherwise KOReader keeps it as a zombie until it closes.
    it("collects a download's process once it has finished", function()
        helper.state.subprocesses_running[5000000] = true
        HttpDownload.collect(5000000)
        assert.is_nil(helper.state.subprocesses_collected[5000000])

        helper.state.subprocesses_running[5000000] = nil
        helper.runScheduled()
        assert.is_true(helper.state.subprocesses_collected[5000000])
    end)
end)
