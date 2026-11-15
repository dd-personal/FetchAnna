local helper = require("helper")

describe("LogUtil", function()
    before_each(helper.reset)

    it("prefixes messages with the plugin name", function()
        local LogUtil = require("fetchanna.util.logutil")
        LogUtil.warn("download failed", 22)
        LogUtil.debug("searching")

        assert.are.same({ "warn", "FetchAnna:", "download failed", 22 }, helper.state.logs[1])
        assert.are.same({ "dbg", "FetchAnna:", "searching" }, helper.state.logs[2])

        LogUtil.info("found 12 books")
        LogUtil.err("crashed")
        assert.are.same({ "info", "FetchAnna:", "found 12 books" }, helper.state.logs[3])
        assert.are.same({ "err", "FetchAnna:", "crashed" }, helper.state.logs[4])
    end)

    -- For the diagnostics, as crash.log can be hard to get at on a device.
    it("keeps the last 200 lines logged at info and above, with when", function()
        local LogUtil = require("fetchanna.util.logutil")
        helper.state.time = os.time({ year = 2026, month = 10, day = 15, hour = 16, min = 5, sec = 9 })
        LogUtil.debug("fetching a page")
        LogUtil.err("crashed", nil, 3)
        assert.are.same({ "16:05:09 ERROR crashed nil 3" }, LogUtil.recent())

        for i = 1, 200 do
            LogUtil.info("line", i)
        end
        local recent = LogUtil.recent()
        assert.are.equal(200, #recent)
        assert.are.equal("16:05:09 INFO line 1", recent[1])
        assert.are.equal("16:05:09 INFO line 200", recent[200])
    end)

    -- Download links carry a temporary key, so only the site is logged.
    it("gives the site a url is on", function()
        local LogUtil = require("fetchanna.util.logutil")
        assert.are.equal("libgen.li", LogUtil.site("https://libgen.li/get.php?md5=abc&key=SECRET"))
        assert.are.equal("libgen.li", LogUtil.site("https://libgen.li"))
        assert.are.equal("nil", LogUtil.site(nil))
    end)

    -- crash.log and the diagnostics are shared to get help, so nothing that logs into the account is ever in them.
    describe("redacting secrets", function()
        -- Not a real key: as long as one, in the same alphabet.
        local KEY = "AbCdEfG2hJkLmNoPqRsTuVwXyZ23456"
        local LogUtil

        before_each(function()
            LogUtil = require("fetchanna.util.logutil")
        end)

        local function everythingLogged()
            local parts = {}
            for _, log in ipairs(helper.state.logs) do
                for i = 2, #log do
                    table.insert(parts, tostring(log[i]))
                end
            end
            for _, line in ipairs(LogUtil.recent()) do
                table.insert(parts, line)
            end
            return table.concat(parts, "\n")
        end

        it("leaves out the whole query of an address with a key in it", function()
            local url = "https://annas-archive.gl/dyn/api/fast_download.json?md5=0123456789abcdef0123456789abcdef&key="
                .. KEY
            assert.are.equal(
                "fetching https://annas-archive.gl/dyn/api/fast_download.json?[redacted] now",
                LogUtil.redact("fetching " .. url .. " now")
            )
            assert.are.equal(
                "https://libgen.li/get.php?[redacted]",
                LogUtil.redact("https://libgen.li/get.php?md5=abc&KEY=SECRET")
            )
            -- The query of a URL with no secret in it is kept.
            assert.are.equal(
                "https://annas-archive.gl/search?q=dune&page=2",
                LogUtil.redact("https://annas-archive.gl/search?q=dune&page=2")
            )
        end)

        it("leaves out the values of secret fields and login cookies wherever they are", function()
            assert.are.equal("posting key=[redacted]&lang=en", LogUtil.redact("posting key=" .. KEY .. "&lang=en"))
            assert.are.equal(
                "Cookie: aa_account_id2=[redacted]; __ddg1_=x",
                LogUtil.redact("Cookie: aa_account_id2=eyJhIjoiYWJjIn0.sig-nature_1; __ddg1_=x")
            )
            assert.are.equal("password=[redacted]", LogUtil.redact("password=hunter22"))
            assert.are.equal("monkey=1 keyboard=2", LogUtil.redact("monkey=1 keyboard=2"))
        end)

        it("leaves out each secret it's told of, however it's written", function()
            LogUtil.addSecret(KEY)
            LogUtil.addSecret("https://yqrii5.org/f/abc/1794447200/50000/a b.epub~sig")
            assert.are.equal("the key is [redacted].", LogUtil.redact("the key is " .. KEY .. "."))
            assert.are.equal(
                "got [redacted]",
                LogUtil.redact("got https://yqrii5.org/f/abc/1794447200/50000/a b.epub~sig")
            )
            assert.are.equal(
                "got [redacted]",
                LogUtil.redact("got https%3A%2F%2Fyqrii5.org%2Ff%2Fabc%2F1794447200%2F50000%2Fa%20b.epub~sig")
            )
            -- Too short to redact everywhere without garbling everything else.
            LogUtil.addSecret("abc")
            assert.are.equal("abc", LogUtil.redact("abc"))
        end)

        it("redacts everything logged, at every level, and what the diagnostics keep", function()
            LogUtil.addSecret(KEY)
            LogUtil.err("crashed with", KEY)
            LogUtil.warn("could not fetch", "https://annas-archive.pk/dyn/api/fast_download.json?key=" .. KEY)
            LogUtil.info({ url = "https://x.example/?token=abc", nested = { KEY } })
            LogUtil.debug("posting key=" .. KEY, 42, nil, true)

            local logged = everythingLogged()
            assert.is_nil(logged:find(KEY, 1, true))
            assert.is_nil(logged:find("token=abc", 1, true))
            assert.are.same({ "dbg", "FetchAnna:", "posting key=[redacted]", 42, nil, true }, helper.state.logs[4])
            assert.are.same(
                { url = "https://x.example/?[redacted]", nested = { "[redacted]" } },
                helper.state.logs[3][3]
            )
            assert.matches("ERROR crashed with %[redacted%]$", LogUtil.recent()[1])
        end)
    end)
end)

describe("NotifyUtil", function()
    before_each(helper.reset)

    it("shows a notification", function()
        local NotifyUtil = require("fetchanna.util.notifyutil")
        NotifyUtil.info("Searching...")
        assert.are.same({ "Searching..." }, helper.state.notifications)
    end)
end)
