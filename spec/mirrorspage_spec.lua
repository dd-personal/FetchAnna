local helper = require("helper")

describe("MirrorsPage", function()
    local GL, NEW = "https://annas-archive.gl", "https://annas-archive.se"
    local SLUM = "https://open-slum.org/annas.html"
    local NOW = 1794440000
    local slum_page = helper.readFile("spec/data/annas/slum-annas.html")
    local api_doc = helper.readFile("spec/data/annas/fast-download-400-invalid-md5.json")
    local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")

    local data_dir, MirrorsPage, AnnasMirrors, answers, requests

    -- Returns the menu on top.
    local function lastMenu()
        for i = #helper.state.shown, 1, -1 do
            local widget = helper.state.shown[i]
            if widget.item_table and not helper.wasClosed(widget) then
                return widget
            end
        end
    end

    local function itemTexts()
        local texts = {}
        for _, item in ipairs(lastMenu().item_table) do
            table.insert(texts, item.mandatory and item.text .. " | " .. item.mandatory or item.text)
        end
        return texts
    end

    local function tap(text)
        for _, item in ipairs(lastMenu().item_table) do
            if item.text:find(text, 1, true) then
                return item.callback()
            end
        end
        error("no menu item containing " .. text)
    end

    local function button(dialog, text)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do
                if b.text == text then
                    return b
                end
            end
        end
        error("no button " .. text)
    end

    -- Returns the page with another catalogue site, annas-archive.se.
    local function withNewSite(page)
        local start = assert(page:find('<div class="card" id="annas.gd">', 1, true))
        local finish = page:find('<div class="card" id="', start + 1, true)
        local card = page:sub(start, finish - 1)
        local new_card = card:gsub('id="annas%.gd"', 'id="annas.se"'):gsub("annas%-archive%.gd", "annas-archive.se")
        return page:sub(1, finish - 1) .. new_card .. page:sub(finish)
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.state.time = NOW
        helper.stubs.network.connected = true
        answers, requests = {}, {}

        local HttpUtil = require("fetchanna.util.httputil")
        HttpUtil.getBody = function(url, opts)
            table.insert(requests, { url = url, opts = opts })
            local answer = answers[url] or { nil, "failed to connect to server" }
            return answer[1], answer[2], answer[3], answer[4] or {}
        end
        require("fetchanna.util.originpolicy").resolve = function()
            return nil
        end
        AnnasMirrors = require("fetchanna.api.annasmirrors")
        MirrorsPage = require("fetchanna.ui.mirrorspage")
        local SettingsPage = require("fetchanna.settings.settingspage")
        MirrorsPage:show(function(title, items)
            return SettingsPage:newMenu(title, items)
        end)
    end)

    after_each(helper.cleanup)

    it("lists the sites FetchAnna was released with, and each one's trust", function()
        assert.are.equal("Anna's Archive Sites", lastMenu().title)
        assert.are.same({
            "Refresh from SLUM (never looked up)",
            "annas-archive.gd | Built in",
            "annas-archive.gl | Built in",
            "annas-archive.pk | Built in",
            "Reset to Built-in Sites",
        }, itemTexts())
    end)

    describe("refreshing from SLUM", function()
        it("looks the sites up, and lists them", function()
            answers[SLUM] = { withNewSite(slum_page), nil, 200 }
            tap("Refresh from SLUM")

            assert.are.equal("Anna's Archive has 4 sites", helper.lastNotification())
            assert.are.same({
                "Refresh from SLUM (looked up just now)",
                "annas-archive.gd | Built in",
                "annas-archive.gl | Built in",
                "annas-archive.pk | Built in",
                "annas-archive.se | Not approved",
                "Download servers: wbsg8v.xyz, yqrii5.org",
                "Reset to Built-in Sites",
            }, itemTexts())
        end)

        it("says how long ago they were looked up", function()
            answers[SLUM] = { slum_page, nil, 200 }
            tap("Refresh from SLUM")
            helper.state.time = NOW + 3 * 3600 + 5
            MirrorsPage:refreshMenu()
            assert.are.equal("Refresh from SLUM (looked up 3 hours ago)", lastMenu().item_table[1].text)
        end)

        it("keeps the sites known before when SLUM can't be read, saying why", function()
            answers[SLUM] = { challenge, nil, 403 }
            tap("Refresh from SLUM")

            assert.are.equal(
                "SLUM couldn't be read: SLUM answered with an error (HTTP 403). The sites known before are kept.",
                helper.lastError()
            )
            assert.are.equal("SLUM couldn't be read just now", lastMenu().item_table[2].text)
            assert.are.equal(6, #lastMenu().item_table)
            tap("SLUM couldn't be read")
            assert.are.equal("SLUM couldn't be read: SLUM answered with an error (HTTP 403)", helper.lastShown().text)
        end)

        it("turns wifi on first", function()
            helper.stubs.network.connected = false
            tap("Refresh from SLUM")
            assert.are.equal(0, #requests)
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
        end)
    end)

    describe("a site", function()
        local function showSite(host)
            tap(host)
            return helper.lastShown()
        end

        it("says what's known about it", function()
            answers[SLUM] = { slum_page, nil, 200 }
            tap("Refresh from SLUM")
            answers[GL .. "/dyn/api/fast_download.json"] = { api_doc, nil, 400 }
            AnnasMirrors:probe(GL)
            helper.state.time = NOW + 7200

            assert.are.equal(
                table.concat({
                    "annas-archive.gl",
                    "Sent your key: FetchAnna was released with it, checked by hand on 2026-11-11.",
                    "SLUM: protected, as of 2 hours ago",
                    "Checked to be Anna's Archive 2 hours ago",
                    "Last worked 2 hours ago (check)",
                }, "\n"),
                showSite("annas-archive.gl").title
            )
        end)

        it("can be checked to be Anna's Archive", function()
            answers[GL .. "/dyn/api/fast_download.json"] = { api_doc, nil, 400 }
            button(showSite("annas-archive.gl"), "Check").callback()
            assert.are.equal("annas-archive.gl answers as Anna's Archive does", helper.lastNotification())
            assert.is_false(requests[1].opts.follow_redirects)
        end)

        it("says why it couldn't be checked", function()
            answers[GL .. "/dyn/api/fast_download.json"] = { challenge, nil, 403 }
            button(showSite("annas-archive.gl"), "Check").callback()
            assert.matches(
                "^annas%-archive%.gl couldn't be checked: Anna's Archive asked for a browser check",
                helper.lastError()
            )
        end)

        it("can be revoked, after asking", function()
            button(showSite("annas-archive.gl"), "Revoke").callback()
            local confirm = helper.lastShown()
            assert.are.equal("Stop sending your key to annas-archive.gl? It can be approved again later.", confirm.text)
            confirm.ok_callback()

            assert.are.equal("annas-archive.gl revoked", helper.lastNotification())
            assert.are.equal(AnnasMirrors.TRUST.REVOKED, AnnasMirrors:trustOf(GL))
            assert.are.equal("Revoked", lastMenu().item_table[3].mandatory)
        end)

        describe("found on SLUM", function()
            before_each(function()
                answers[SLUM] = { withNewSite(slum_page), nil, 200 }
                tap("Refresh from SLUM")
            end)

            it("is checked, then approved once asked", function()
                answers[NEW .. "/dyn/api/fast_download.json"] = { api_doc, nil, 400 }
                button(showSite("annas-archive.se"), "Approve").callback()

                local confirm = helper.lastShown()
                assert.matches("^annas%-archive%.se answers as Anna's Archive does%. Approve it", confirm.text)
                assert.are.equal(AnnasMirrors.TRUST.UNTRUSTED, AnnasMirrors:trustOf(NEW))
                confirm.ok_callback()
                assert.are.equal("annas-archive.se approved", helper.lastNotification())
                assert.are.equal(AnnasMirrors.TRUST.APPROVED, AnnasMirrors:trustOf(NEW))
                assert.are.equal("Approved", lastMenu().item_table[5].mandatory)
            end)

            it("isn't approved when it doesn't answer as Anna's Archive does", function()
                answers[NEW .. "/dyn/api/fast_download.json"] = { "<html>Buy this domain</html>", nil, 200 }
                button(showSite("annas-archive.se"), "Approve").callback()

                assert.are.equal(
                    "annas-archive.se couldn't be checked: Anna's Archive answered with something FetchAnna couldn't "
                        .. "read. It may have changed.",
                    helper.lastError()
                )
                assert.are.equal(AnnasMirrors.TRUST.UNTRUSTED, AnnasMirrors:trustOf(NEW))
            end)
        end)
    end)

    it("goes back to the built-in sites, after asking", function()
        answers[SLUM] = { withNewSite(slum_page), nil, 200 }
        tap("Refresh from SLUM")
        AnnasMirrors:revoke(GL)
        tap("Reset to Built-in Sites")
        helper.lastShown().ok_callback()

        assert.are.equal("Sites reset", helper.lastNotification())
        assert.are.same({
            "Refresh from SLUM (never looked up)",
            "annas-archive.gd | Built in",
            "annas-archive.gl | Built in",
            "annas-archive.pk | Built in",
            "Reset to Built-in Sites",
        }, itemTexts())
    end)

    it("says how long ago things were", function()
        assert.are.equal("just now", MirrorsPage.ago(NOW, NOW + 59))
        assert.are.equal("1 minute ago", MirrorsPage.ago(NOW, NOW + 60))
        assert.are.equal("59 minutes ago", MirrorsPage.ago(NOW, NOW + 3599))
        assert.are.equal("1 hour ago", MirrorsPage.ago(NOW, NOW + 3600))
        assert.are.equal("2 days ago", MirrorsPage.ago(NOW, NOW + 2 * 86400 + 5))
        -- Or after the clock was put back.
        assert.are.equal("just now", MirrorsPage.ago(NOW, NOW - 100))
    end)
end)
