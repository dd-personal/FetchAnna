local helper = require("helper")

-- Follows the key and a session through the real HttpUtil, with curl and with KOReader's own HTTP (see
-- docs/annas-protocol.md).
describe("Anna's Archive's key and sessions", function()
    -- These are not real keys or sessions, only shaped like them.
    local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
    local SESSION = "eyJhIjoiYWJjZGVmZyIsImlhdCI6MX0.c2lnbmF0dXJlLXZhbHVl_x-y"
    local GD = "https://annas-archive.gd"
    local NOW = 1794440000
    local not_found_answer = helper
        .readFile("spec/data/annas/fast-download-400-invalid-md5.json")
        :gsub('"Invalid md5"', '"Record not found"')
    -- SYNTHESIZED from Anna's Archive's account page template (see annasaccount_spec.lua).
    local member_page = [[<form onsubmit="window.submitForm(event, '/dyn/account/logout/')"></form>
<div class=" ">Placeholder <a href="/donate?tier=3" class="text-sm hidden">tier</a></div>]]

    local data_dir, AnnasAccount
    -- The member API's answer. While nil, it can't find the file.
    local api_answer

    -- Returns the body, status and headers for a request, or nil.
    local function answerFor(method, url)
        local path = url:gsub("%?.*$", "")
        if method == "POST" and path == GD .. "/account/" then
            return "", 302, { location = "/account/", ["set-cookie"] = "aa_account_id2=" .. SESSION .. "; Path=/" }
        elseif method == "GET" and path == GD .. "/account/" then
            return member_page, 200, {}
        elseif method == "GET" and path == GD .. "/dyn/api/fast_download.json" then
            if api_answer then
                return api_answer, 200, {}
            end
            return not_found_answer, 404, {}
        end
    end

    -- Returns everywhere a secret mustn't be: command lines, the log, settings files, Diagnostics.
    local function everywhereElse()
        local parts = {}
        for _, cmd in ipairs(helper.state.popen_calls) do
            table.insert(parts, cmd)
        end
        for _, log in ipairs(helper.state.logs) do
            for i = 2, #log do
                table.insert(parts, tostring(log[i]))
            end
        end
        for _, settings in pairs(helper.state.settings_files) do
            for name, value in pairs(settings) do
                table.insert(parts, name .. "=" .. tostring(value))
            end
        end
        table.insert(parts, require("fetchanna.ui.diagnostics").report())
        return table.concat(parts, "\n")
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        require("fetchanna.util.originpolicy").resolve = function()
            return nil
        end
        AnnasAccount = require("fetchanna.api.annasaccount")
        AnnasAccount:setKey(KEY)
        api_answer = nil
    end)

    after_each(helper.cleanup)

    describe("with curl", function()
        local fetched

        before_each(function()
            fetched = {}
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
            -- Stands in for curl: reads its config file, then removes it.
            helper.stubCommand("curl -s -o", function(cmd)
                local config_file = cmd:match("%-K '([^']+)'")
                local config = config_file and helper.readFile(config_file) or ""
                if config_file then
                    os.remove(config_file)
                end
                local url = config:match('url = "([^"]+)"') or cmd:match("%-o '[^']+' '([^']+)'")
                local method = config:find('\ndata = "', 1, true) and "POST" or "GET"
                table.insert(fetched, { method = method, url = url, config = config })
                local body, status, headers = answerFor(method, url)
                if not body then
                    return " 6\n"
                end
                helper.writeFile(cmd:match("%-o '([^']+)'"), body)
                local header_lines = { "HTTP/1.1 " .. status .. " X" }
                for name, value in pairs(headers) do
                    table.insert(header_lines, name .. ": " .. value)
                end
                helper.writeFile(cmd:match("%-D '([^']+)'"), table.concat(header_lines, "\r\n") .. "\r\n\r\n")
                return status .. " 0\n"
            end)
        end)

        it("are only ever given to curl in a file, which is removed with everything else it wrote", function()
            assert.is_true(AnnasAccount:connect())
            assert.is_true(AnnasAccount:verify())

            -- Each went to the trusted site only.
            assert.are.same({ "POST", GD .. "/account/" }, { fetched[1].method, fetched[1].url })
            assert.matches('\ndata = "key=' .. KEY .. '"\n', fetched[1].config, 1, true)
            assert.matches('header = "Cookie: aa_account_id2=' .. SESSION .. '"', fetched[2].config, 1, true)
            assert.matches(GD .. "/dyn/api/fast_download.json?md5=", fetched[3].url, 1, true)
            for _, fetch in ipairs(fetched) do
                assert.are.equal(GD, fetch.url:match("^https://[^/]+"))
            end

            local elsewhere = everywhereElse()
            assert.is_nil(elsewhere:find(KEY, 1, true))
            assert.is_nil(elsewhere:find(SESSION, 1, true))
            assert.are.same({}, helper.readDir(data_dir .. "/settings/fetchanna_tmp"))
        end)

        -- The download link is a secret too: it downloads the book until it expires.
        it("leave the signed download link only in the file curl downloads the book with", function()
            local MD5 = "0123456789abcdef0123456789abcdef"
            local LINK = "https://dl.example/d3/y/1794440000/c2lnbmVkLWxpbms/" .. MD5 .. ".epub"
            -- SYNTHESIZED from the member API's documented answer (see annasaccount_spec.lua).
            api_answer = '{"download_url": "'
                .. LINK
                .. '", "account_fast_download_info": {"downloads_left": 20, "downloads_per_day": 25}, '
                .. '"///download_url": ["Placeholder."]}'
            local url = require("fetchanna.api.annassearch").findDownloadLink({ md5 = MD5 })
            assert.are.equal(LINK, url)

            helper.stubCommand("& echo $!", "4242\n")
            local CurlUtil = require("fetchanna.util.curlutil")
            local pid = CurlUtil.startDownload(url, data_dir .. "/Emma.epub.part", nil, { sensitive = true })
            assert.are.equal(4242, pid)
            local cmd = helper.state.popen_calls[#helper.state.popen_calls]
            local config_file = cmd:match("%-K '([^']+)'")
            assert.are.equal('url = "' .. LINK .. '"\n', helper.readFile(config_file))
            os.remove(config_file)

            local elsewhere = everywhereElse()
            assert.is_nil(elsewhere:find("c2lnbmVkLWxpbms", 1, true))
            assert.is_nil(elsewhere:find(KEY, 1, true))
            assert.matches("fast downloads left: 20 of 25", elsewhere, 1, true)
        end)

        -- A redirect curl followed (-L) would take the key or session with it.
        it("never have a redirect followed", function()
            AnnasAccount:connect()
            for _, cmd in ipairs(helper.state.popen_calls) do
                if cmd:find("curl %-s") then
                    assert.is_nil(cmd:find("-sL", 1, true))
                end
            end
        end)
    end)

    describe("with KOReader's own HTTP", function()
        local requests

        before_each(function()
            requests = {}
            helper.stubs.http.request = function(request)
                table.insert(requests, request)
                local body, status, headers = answerFor(request.method, request.url)
                if not body then
                    return nil, "host not found"
                end
                if body ~= "" then
                    request.sink(body)
                end
                return 1, status, headers
            end
        end)

        it("are only ever sent to the site trusted with them, never following a redirect", function()
            assert.is_true(AnnasAccount:connect())
            assert.is_true(AnnasAccount:verify())

            assert.are.equal("POST", requests[1].method)
            assert.are.equal("key=" .. KEY, requests[1].source.text)
            assert.are.equal("aa_account_id2=" .. SESSION, requests[2].headers.Cookie)
            for _, request in ipairs(requests) do
                assert.are.equal(GD, request.url:match("^https://[^/]+"))
                assert.is_false(request.redirect)
            end

            local elsewhere = everywhereElse()
            assert.is_nil(elsewhere:find(KEY, 1, true))
            assert.is_nil(elsewhere:find(SESSION, 1, true))
        end)
    end)

    -- Diagnostics says how the account is, without the key or session (checked above).
    it("leave the diagnostics saying how the account is", function()
        helper.stubs.http.request = function(request)
            local body, status, headers = answerFor(request.method, request.url)
            if body and body ~= "" then
                request.sink(body)
            end
            return body and 1, status or "host not found", headers
        end
        AnnasAccount:connect()
        local report = require("fetchanna.ui.diagnostics").report()
        assert.matches(
            "\nAnna's Archive account: logged_in, membership tier 3, key kept until KOReader restarts\n",
            report,
            1,
            true
        )
        assert.matches("\nLogged into Anna's Archive on: annas-archive.gd\n", report, 1, true)
        assert.matches("\nAnna's Archive sites: annas-archive.gd (seed), ", report, 1, true)
        assert.matches("\nLooked up on SLUM: never\n", report, 1, true)
    end)

    it("are never sent anywhere when no site is trusted with them", function()
        local AnnasMirrors = require("fetchanna.api.annasmirrors")
        for _, origin in ipairs({ "https://annas-archive.gl", "https://annas-archive.pk", GD }) do
            AnnasMirrors:revoke(origin)
        end
        local requested = false
        helper.stubs.http.request = function()
            requested = true
            return nil, "host not found"
        end
        assert.is_nil((AnnasAccount:connect()))
        assert.is_false(requested)
    end)
end)
