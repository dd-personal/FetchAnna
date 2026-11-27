local helper = require("helper")

-- Anna's Archive as it is now, to notice when it changes. The Canary workflow runs these daily (busted --tags=live), as
-- on every push they'd fail whenever a site is down. They never get the key: they read SLUM and probe each site's
-- member API (see AnnasMirrors:probe), which uses up nothing.
describe("Anna's Archive, live", function()
    local AnnasMirrors, SlumParser

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.run("mkdir -p " .. helper.quote(helper.state.data_dir .. "/settings"))
        -- The specs reach the sites with KOReader's own HTTP (see helper.useLiveHttp).
        helper.stubs.http.request = helper.useLiveHttp().request
        require("fetchanna.util.curlutil").canFetch = function()
            return false
        end
        AnnasMirrors = require("fetchanna.api.annasmirrors")
        SlumParser = require("fetchanna.api.slumparser")
        -- No key was entered, so there's none to send.
        assert.is_false(require("fetchanna.api.annasaccount"):hasKey())
    end)

    after_each(helper.cleanup)

    it("is listed on SLUM as FetchAnna reads it #live", function()
        local html, err, status, headers = require("fetchanna.util.httputil").getBody(AnnasMirrors.SLUM_URL)
        assert.is_string(html, err)
        local parsed, why = SlumParser.parse(html)
        -- SLUM's Cloudflare puts a bot check in front of datacenter addresses, GitHub's runners included, and FetchAnna
        -- never tries to get past one. Pending rather than failed, as it says nothing about SLUM's list: run it from a
        -- home connection to check that. Going by Cloudflare's header, which only comes with a check.
        if not parsed and headers and headers["cf-mitigated"] == "challenge" then
            pending(
                string.format(
                    "SLUM answered with a bot check (HTTP %s), so its list can't be checked here",
                    tostring(status)
                )
            )
        end
        assert.is_table(parsed, why)

        local catalogue = {}
        for _, record in ipairs(parsed.records) do
            if record.role == SlumParser.CATALOGUE then
                assert.matches("^https://[%w%.%-]+$", record.origin)
                table.insert(catalogue, record.origin)
            end
        end
        assert.is_true(#catalogue > 0, "SLUM lists none of Anna's Archive's own sites")
    end)

    -- The seeds get the key without asking (see docs/mirrors.md).
    it("answers on at least one of the sites FetchAnna is released with, as Anna's Archive does #live", function()
        local answered, failures = {}, {}
        for _, record in ipairs(AnnasMirrors:list(SlumParser.CATALOGUE)) do
            if record.source == "seed" then
                local ok, failure = AnnasMirrors:probe(record.origin)
                if ok then
                    table.insert(answered, record.origin)
                else
                    table.insert(failures, record.origin .. ": " .. tostring(failure))
                end
            end
        end
        assert.is_true(#answered > 0, "none answered: " .. table.concat(failures, "; "))
    end)
end)
