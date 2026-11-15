local helper = require("helper")

describe("SlumParser", function()
    local SlumParser
    -- SLUM's page about Anna's Archive as it was on 2026-11-11 (see spec/data/annas/PROVENANCE.md).
    local page = helper.readFile("spec/data/annas/slum-annas.html")

    before_each(function()
        helper.reset()
        SlumParser = require("fetchanna.api.slumparser")
    end)

    -- Returns the page with site id's card changed by change(card).
    local function withCard(id, change)
        local start = assert(page:find('<div class="card" id="' .. id .. '">', 1, true))
        local finish = page:find('<div class="card" id="', start + 1, true) or #page + 1
        return page:sub(1, start - 1) .. change(page:sub(start, finish - 1)) .. page:sub(finish)
    end

    local function origins(result)
        local list = {}
        for _, record in ipairs(result.records) do
            table.insert(list, record.origin)
        end
        return list
    end

    describe("reading SLUM's page", function()
        it("finds each of Anna's sites, and what it's for", function()
            local result = assert(SlumParser.parse(page))
            assert.are.same({
                "https://annas-archive.gl",
                "https://annas-archive.pk",
                "https://annas-archive.gd",
                "https://software.annas-archive.gl",
                "https://yqrii5.org",
                "https://wbsg8v.xyz",
            }, origins(result))
            local roles = {}
            for _, record in ipairs(result.records) do
                roles[record.host] = record.role
            end
            assert.are.same({
                ["annas-archive.gl"] = "catalogue",
                ["annas-archive.pk"] = "catalogue",
                ["annas-archive.gd"] = "catalogue",
                ["software.annas-archive.gl"] = "software",
                ["yqrii5.org"] = "download",
                ["wbsg8v.xyz"] = "download",
            }, roles)
            assert.are.same({}, result.skipped)
        end)

        it("reads each site's status, and what SLUM expected of it and found", function()
            local result = assert(SlumParser.parse(page))
            assert.are.same({
                origin = "https://annas-archive.gl",
                host = "annas-archive.gl",
                slum_id = "annas.gl",
                role = "catalogue",
                status = "protected",
                expected_status = 200,
                actual_status = 200,
                latency_ms = 2629,
            }, result.records[1])
            local download = result.records[5]
            assert.are.equal("up", download.status)
            assert.are.equal(403, download.expected_status)
            assert.are.equal(403, download.actual_status)
        end)

        it("reads when SLUM made the page, in seconds since 1970 (UTC)", function()
            assert.are.equal(1794438778, assert(SlumParser.parse(page)).generated_at)
            assert.is_nil(assert(SlumParser.parse((page:gsub("Generated at", "Made at")))).generated_at)
        end)
    end)

    describe("when a site's status changes", function()
        it("reads down, degraded and unknown statuses", function()
            for _, status in ipairs({ "down", "degraded", "unknown", "up" }) do
                local changed = withCard("annas.pk", function(card)
                    return (card:gsub('status%-badge protected"', "status-badge " .. status .. '"'))
                end)
                assert.are.equal(status, assert(SlumParser.parse(changed)).records[2].status)
            end
        end)

        it("takes a status it doesn't know of to be unknown", function()
            local changed = withCard("annas.pk", function(card)
                return (card:gsub('status%-badge protected"', 'status-badge on-fire"'))
            end)
            assert.are.equal("unknown", assert(SlumParser.parse(changed)).records[2].status)
        end)
    end)

    it("leaves out a site SLUM no longer lists", function()
        local removed = withCard("annas.gd", function()
            return ""
        end)
        local result = assert(SlumParser.parse(removed))
        assert.are.equal(5, #result.records)
        for _, record in ipairs(result.records) do
            assert.are_not.equal("https://annas-archive.gd", record.origin)
        end
    end)

    it("lists a site only once, however many cards it has", function()
        local doubled = withCard("annas.pk", function(card)
            return card .. card:gsub('id="annas%.pk"', 'id="annas.pk2"')
        end)
        local result = assert(SlumParser.parse(doubled))
        assert.are.equal(6, #result.records)
        assert.are.same({ { slum_id = "annas.pk2", reason = "it lists a site listed before it" } }, result.skipped)
    end)

    -- Whoever can change the page could point FetchAnna, and someone's key, anywhere.
    describe("with links that can't be trusted", function()
        local bad_links = {
            { "http://annas-archive.gl", "its link isn't a secure (https) address" },
            { "https://user:pass@annas-archive.gl", "its link has a login in it" },
            { "https://annas-archive.gl:8443", "its link uses a port other than https's own" },
            { "https://10.0.0.1", "its link is a numeric address rather than a name" },
            { "javascript:alert(1)", "its link isn't a web address" },
            { "https://annas-archive.gl.evil.example", "its link doesn't go to the site it names" },
            { "https://evil.example", "its link doesn't go to the site it names" },
        }
        for _, case in ipairs(bad_links) do
            it("leaves out a card linking to " .. case[1], function()
                local changed = withCard("annas.gl", function(card)
                    return (
                        card:gsub('href="https://annas%-archive%.gl"', 'href="' .. case[1]:gsub("%%", "%%%%") .. '"')
                    )
                end)
                local result = assert(SlumParser.parse(changed))
                assert.are.same({ { slum_id = "annas.gl", reason = case[2] } }, result.skipped)
                assert.are.equal("https://annas-archive.pk", result.records[1].origin)
            end)
        end

        it("only reads each card's own link as a site, never any other link on the page", function()
            local links = '<a href="https://annas-archive.fake">annas</a>'
                .. '<a class="card-title" href="https://other.example">x</a>'
            local changed = page:gsub("<header>", links .. "<header>")
            assert.are.equal(6, #assert(SlumParser.parse(changed)).records)
        end)

        it("reads links written with entities", function()
            local changed = withCard("annas.gl", function(card)
                return (card:gsub('href="https://annas%-archive%.gl"', 'href="https://annas-archive.gl/?a=1&amp;b=2"'))
            end)
            assert.are.equal("https://annas-archive.gl", assert(SlumParser.parse(changed)).records[1].origin)
        end)
    end)

    describe("working out what a site is for", function()
        it("goes by what SLUM expects it to answer", function()
            local changed = withCard("annas.gd", function(card)
                return (card:gsub('id="annas%.gd"', 'id="annas.new-mirror"'))
            end)
            assert.are.equal("catalogue", assert(SlumParser.parse(changed)).records[3].role)
        end)

        it("goes by its id where nothing is expected of it", function()
            local changed = withCard("annas.dl1", function(card)
                return (card:gsub("<div>Content:.-</div>", ""))
            end)
            assert.are.equal("download", assert(SlumParser.parse(changed)).records[5].role)
        end)

        -- An id alone never makes a site one to search and log in on.
        it("leaves out a site whose id says it's a download server but whose content says it's a catalogue", function()
            local changed = withCard("annas.dl1", function(card)
                return (card:gsub("Link expired or invalid", "in one place - Anna"))
            end)
            local result = assert(SlumParser.parse(changed))
            assert.are.same({
                { slum_id = "annas.dl1", reason = "its id and what it's expected to answer say different things" },
            }, result.skipped)
        end)

        it("leaves out a site it can't tell the purpose of", function()
            local changed = withCard("annas.gd", function(card)
                return (card:gsub("in one place %- Anna", "something else"))
            end)
            assert.are.same(
                { { slum_id = "annas.gd", reason = "it isn't said what it's for" } },
                assert(SlumParser.parse(changed)).skipped
            )
        end)
    end)

    -- Never taken to mean Anna's Archive has no sites.
    describe("when the page can't be read", function()
        it("says when it isn't SLUM's page, such as a bot check in front of it", function()
            local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")
            local result, err = SlumParser.parse(challenge)
            assert.is_nil(result)
            assert.are.equal(SlumParser.NOT_SLUM, err)
            assert.is_nil((SlumParser.parse("")))
            assert.is_nil((SlumParser.parse(nil)))
        end)

        it("says when the page has changed, so that no site can be read from it", function()
            for _, changed in ipairs({
                (page:gsub('<div class="card" id=', '<section class="card" id=')),
                (page:gsub('class="card%-title"', 'class="site-title"')),
                (page:gsub("<body>.*</body>", "<body>Shadow Library Uptime Monitor</body>")),
            }) do
                local result, err = SlumParser.parse(changed)
                assert.is_nil(result)
                assert.are.equal(SlumParser.CHANGED, err)
            end
            assert.is_truthy(helper.logged("warn", "^read no sites from SLUM's page"))
        end)

        it("reads the sites it can, saying which it couldn't", function()
            local changed = withCard("annas.pk", function(card)
                return (card:gsub('class="card%-title"', 'class="site-title"'))
            end)
            local result = assert(SlumParser.parse(changed))
            assert.are.equal(5, #result.records)
            assert.are.same({ { slum_id = "annas.pk", reason = "it has no link" } }, result.skipped)
            assert.is_truthy(helper.logged("warn", "^left out SLUM's card annas%.pk as it has no link$"))
        end)
    end)
end)
