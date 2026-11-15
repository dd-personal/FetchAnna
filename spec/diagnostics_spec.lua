local helper = require("helper")

describe("Diagnostics", function()
    local Diagnostics, Settings, LogUtil, data_dir, plugin_dir
    -- What each URL answers, as getBody returns it, and the URLs asked.
    local answers, asked
    local can_fetch

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        plugin_dir = helper.tmpdir("plugin")
        helper.writeFile(plugin_dir .. "/version.txt", "0.8\n")
        helper.stub("fetchanna.util.pathutil", {
            getPluginPath = function()
                return plugin_dir
            end,
        })
        can_fetch = true
        helper.stub("fetchanna.util.curlutil", {
            getVersion = function()
                return "8.21.0"
            end,
            canFetch = function()
                return can_fetch
            end,
            canUseEncryptedDns = function()
                return can_fetch
            end,
        })
        answers, asked = {}, {}
        helper.stub("fetchanna.util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return true
            end,
            setTrapWidget = function(widget)
                helper.state.trap_widget = widget
            end,
            sayStatus = function() end,
            getBody = function(url)
                table.insert(asked, url)
                local answer = answers[url] or { nil, "could not resolve host" }
                return answer[1], answer[2], answer[3]
            end,
        })

        Settings = require("fetchanna.settings.settings")
        Settings:load()
        LogUtil = require("fetchanna.util.logutil")
        Diagnostics = require("fetchanna.ui.diagnostics")
    end)

    after_each(helper.cleanup)

    local function viewer()
        local shown = helper.lastShown()
        assert.are.equal("FetchAnna diagnostics", shown.title)
        return shown
    end

    local function button(text)
        for _, row in ipairs(viewer().buttons_table) do
            for _, b in ipairs(row) do
                if b.text == text then
                    return b
                end
            end
        end
        error("no button " .. text)
    end

    describe("report", function()
        it("says which versions, device and settings are in use", function()
            local report = Diagnostics.report()

            assert.matches("^FetchAnna 0.8 on KOReader .*, curl 8.21.0\n", report)
            assert.matches("\nTime: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d", report)
            assert.matches("\nFetching with: curl\n", report)
            assert.matches("\nDownload folder: [^\n]+\n", report)
            assert.matches("\nLanguages: en\n", report, 1, true)
            assert.matches("\nFile types: epub\n", report, 1, true)
            assert.matches("\nEncrypted DNS: off\n", report, 1, true)
            assert.matches("\nCovers: on\n", report, 1, true)
        end)

        it("says when KOReader's own HTTP fetches, as curl can't", function()
            can_fetch = false
            assert.matches("\nFetching with: KOReader's own HTTP, as curl can't\n", Diagnostics.report(), 1, true)
        end)

        it("ends with what was logged this session, at info and above", function()
            LogUtil.debug("fetching a page")
            LogUtil.info("downloaded", '"Dune"')
            LogUtil.warn("could not fetch", "https://libgen.vg")

            local log = Diagnostics.report():match("\nRecent log:\n(.*)$")
            assert.matches('%d%d:%d%d:%d%d INFO downloaded "Dune"\n', log)
            assert.matches("\n%d%d:%d%d:%d%d WARN could not fetch https://libgen.vg$", log)
            assert.is_nil(log:find("fetching a page", 1, true))
        end)

        -- Only the seeds, as SLUM hasn't been asked.
        it("says which of Anna's Archive's sites are known, and how the account is", function()
            local report = Diagnostics.report()
            assert.matches("\nAnna's Archive account: no_key, ", report, 1, true)
            assert.matches("\nAnna's Archive sites: annas-archive.gd (seed), ", report, 1, true)
            assert.matches("\nLooked up on SLUM: never\n", report, 1, true)
        end)

        -- Shows a book came through the member API, the only source of download links (see
        -- AnnasSearch.findDownloadLink).
        it("says where the last download link came from and went to", function()
            assert.matches("\nLast download link: none yet\n", Diagnostics.report(), 1, true)

            local at = os.time()
            require("fetchanna.api.keystore").setInfo({
                last_link_at = at,
                last_link_site = "annas-archive.gd",
                last_link_server = "dl.example",
            })
            assert.matches(
                "\nLast download link: "
                    .. os.date("%Y-%m-%d %H:%M", at)
                    .. ", a fast download from the member API on annas-archive.gd, served by dl.example\n",
                Diagnostics.report(),
                1,
                true
            )
        end)
    end)

    describe("the page", function()
        it("shows the report, with KOReader's own buttons too", function()
            Diagnostics.show()

            assert.are.equal(Diagnostics.report(), viewer().text)
            assert.are.equal("code", viewer().text_type)
            assert.is_true(viewer().add_default_buttons)
        end)

        it("copies the report", function()
            Diagnostics.show()
            button("Copy").callback()

            assert.are.equal(viewer().text, helper.state.clipboard)
            assert.are.equal("Copied", helper.lastNotification())
        end)

        -- It can be copied from there over USB, and isn't listed among the books.
        it("saves the report in KOReader's folder, saying where", function()
            Diagnostics.show()
            button("Save").callback()

            local path = data_dir .. "/fetchanna-diagnostics.txt"
            assert.are.equal(viewer().text, helper.readFile(path))
            assert.are.equal("Saved to " .. path, helper.lastNotification())
        end)
    end)

    -- It sends the sites nothing of the account's.
    describe("testing the connection", function()
        local SLUM = "https://open-slum.org/annas.html"

        it("asks SLUM, then each of Anna's Archive's sites known, then shows how it went", function()
            answers[SLUM] = { "<html></html>", nil, 200 }
            answers["https://annas-archive.gd/"] = { "<html></html>", nil, 200 }
            answers["https://annas-archive.gl/"] = { "<html>Bad gateway</html>", nil, 502 }
            Diagnostics.show()
            button("Test connection").callback()

            assert.are.same(
                { SLUM, "https://annas-archive.gd/", "https://annas-archive.gl/", "https://annas-archive.pk/" },
                asked
            )
            local tested = viewer().text:match("\nConnection test:\n(.-)\n\n")
            assert.matches("^  open%-slum%.org answered %(HTTP 200%)\n", tested)
            assert.matches("\n  annas-archive.gd answered (HTTP 200)\n", tested, 1, true)
            assert.matches("\n  annas-archive.gl answered (HTTP 502)\n", tested, 1, true)
            assert.matches("\n  annas-archive.pk didn't answer: could not resolve host", tested, 1, true)
            assert.is_truthy(helper.logged("info", "^tested the connection: open%-slum%.org answered"))
            -- The testing message has closed.
            assert.is_nil(helper.state.trap_widget)
        end)

        -- Each site that doesn't answer takes a while.
        it("can be called off, saying how it went with the sites tested by then", function()
            answers[SLUM] = { "<html></html>", nil, 200 }
            answers["https://annas-archive.gd/"] = { nil, "request cancelled" }
            Diagnostics.testConnection()

            assert.are.equal(2, #asked)
            local tested = viewer().text:match("\nConnection test:\n(.-)\n\n")
            assert.are.equal("  open-slum.org answered (HTTP 200)\n  (called off at annas-archive.gd)", tested)
            assert.is_nil(helper.state.trap_widget)
        end)
    end)
end)
