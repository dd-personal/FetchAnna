local helper = require("helper")

describe("OriginPolicy", function()
    local OriginPolicy

    before_each(function()
        helper.reset()
        OriginPolicy = require("fetchanna.util.originpolicy")
    end)

    describe("canonicalOrigin", function()
        it("is https and the site's name, in lower case, without anything after it", function()
            assert.are.equal("https://annas-archive.gl", OriginPolicy.canonicalOrigin("https://annas-archive.gl"))
            assert.are.equal("https://annas-archive.gl", OriginPolicy.canonicalOrigin("HTTPS://Annas-Archive.GL/faq"))
            assert.are.equal("https://annas-archive.gl", OriginPolicy.canonicalOrigin("https://annas-archive.gl:443/"))
            assert.are.equal("https://annas-archive.gl", OriginPolicy.canonicalOrigin("https://annas-archive.gl./"))
            assert.are.equal("https://annas-archive.gl", OriginPolicy.canonicalOrigin("https://annas-archive.gl?x#y"))
        end)

        -- As SLUM lists them.
        it("takes a bare name to be an https site", function()
            assert.are.equal("https://annas-archive.pk", OriginPolicy.canonicalOrigin("annas-archive.pk"))
            assert.are.equal(
                "https://software.annas-archive.gl",
                OriginPolicy.canonicalOrigin("software.annas-archive.gl")
            )
        end)

        it("takes internationalised names", function()
            assert.are.equal(
                "https://xn--nnas-archive-6bb.xn--p1ai",
                OriginPolicy.canonicalOrigin("xn--nnas-archive-6bb.xn--p1ai")
            )
        end)

        local turned_down = {
            { "http://annas-archive.gl", "NOT_HTTPS" },
            { "ftp://annas-archive.gl", "NOT_HTTPS" },
            { "javascript:alert(1)", "INVALID" },
            { "https://user:secret@annas-archive.gl", "CREDENTIALS" },
            { "https://annas-archive.gl@evil.example", "CREDENTIALS" },
            { "https://annas-archive.gl:8443", "PORT" },
            { "https://annas-archive.gl:", "PORT" },
            { "https://annas-archive.gl:80", "PORT" },
            { "https://192.168.1.1", "ADDRESS" },
            { "https://127.0.0.1/", "ADDRESS" },
            { "https://[::1]/", "ADDRESS" },
            { "https://localhost", "NAME" },
            { "https://annas-archive", "NAME" },
            { "https://-annas.gl", "NAME" },
            { "https://annas-.gl", "NAME" },
            { "https://annas..gl", "NAME" },
            { "https://annas_archive.gl", "NAME" },
            { "https://annas%2Earchive.gl", "NAME" },
            { "https://1.2.3.4.5", "ADDRESS" },
            { "https://example.123", "NAME" },
            { "https://annas archive.gl", "INVALID" },
            { "https://annas-archive.gl\\@evil.example", "INVALID" },
            { "https://annas-archive.gl\n.evil.example", "INVALID" },
            { "", "INVALID" },
            { 42, "INVALID" },
            { "https://" .. string.rep("a", 64) .. ".gl", "NAME" },
        }
        for _, case in ipairs(turned_down) do
            it("turns down " .. tostring(case[1]):gsub("\n", "\\n") .. " as " .. case[2], function()
                local origin, err = OriginPolicy.canonicalOrigin(case[1])
                assert.is_nil(origin)
                assert.are.equal(OriginPolicy[case[2]], err)
            end)
        end
    end)

    describe("sameOrigin", function()
        it("is only the exact same site", function()
            assert.is_true(OriginPolicy.sameOrigin("https://annas-archive.gl/search", "annas-archive.gl"))
            assert.is_false(
                OriginPolicy.sameOrigin("https://annas-archive.gl", "https://annas-archive.gl.evil.example")
            )
            assert.is_false(OriginPolicy.sameOrigin("https://annas-archive.gl", "https://evilannas-archive.gl"))
            assert.is_false(OriginPolicy.sameOrigin("https://annas-archive.gl", "https://software.annas-archive.gl"))
            assert.is_false(OriginPolicy.sameOrigin("https://annas-archive.gl", "http://annas-archive.gl"))
            assert.is_false(OriginPolicy.sameOrigin("not a site", "not a site"))
        end)
    end)

    describe("isPublicAddress", function()
        local public = {
            "45.151.91.208",
            "179.43.143.162",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.1",
            "172.15.255.255",
            "172.32.0.1",
            "192.169.0.1",
            "2606:4700:4700::1111",
            "2a00:1450:4001:82a::200e",
            "::ffff:45.151.91.208",
            "64:ff9b::8.8.8.8",
        }
        for _, ip in ipairs(public) do
            it("takes " .. ip .. " to be public", function()
                assert.is_true((OriginPolicy.isPublicAddress(ip)))
            end)
        end

        local private = {
            { "127.0.0.1", "loopback" },
            { "127.255.255.254", "loopback" },
            { "0.0.0.0", "reserved" },
            { "10.1.2.3", "private" },
            { "100.64.0.1", "shared (carrier-grade NAT)" },
            { "169.254.169.254", "link-local" },
            { "172.16.0.1", "private" },
            { "172.31.255.255", "private" },
            { "192.168.1.1", "private" },
            { "192.0.0.8", "reserved" },
            { "192.0.2.1", "documentation" },
            { "198.18.0.1", "benchmarking" },
            { "198.51.100.7", "documentation" },
            { "203.0.113.9", "documentation" },
            { "224.0.0.1", "multicast" },
            { "255.255.255.255", "reserved" },
            { "::", "reserved" },
            { "::1", "loopback" },
            { "::192.168.1.1", "reserved" },
            { "::ffff:127.0.0.1", "loopback" },
            { "::ffff:7f00:1", "loopback" },
            { "::ffff:192.168.0.10", "private" },
            { "64:ff9b::10.0.0.1", "private" },
            { "2002:c0a8:0101::1", "private" },
            { "fc00::1", "private" },
            { "fd12:3456:789a::1", "private" },
            { "fe80::1%wlan0", "link-local" },
            { "FE80::abcd", "link-local" },
            { "ff02::1", "multicast" },
            { "2001:db8::1", "documentation" },
        }
        for _, case in ipairs(private) do
            it("takes " .. case[1] .. " to be " .. case[2], function()
                local is_public, kind = OriginPolicy.isPublicAddress(case[1])
                assert.is_false(is_public)
                assert.are.equal(case[2], kind)
            end)
        end

        it("doesn't take what isn't an address to be public", function()
            for _, value in ipairs({ "256.1.1.1", "1.2.3", "::g", "1:2:3:4:5:6:7:8:9", "1::2::3", "annas.gl", "" }) do
                assert.is_false((OriginPolicy.isPublicAddress(value)), value)
            end
            assert.is_false((OriginPolicy.isPublicAddress(nil)))
        end)
    end)

    describe("checkHost", function()
        it("passes a name that leads to public addresses", function()
            OriginPolicy.resolve = function()
                return { "45.151.91.208", "2606:4700::1" }
            end
            assert.is_true(OriginPolicy.checkHost("annas-archive.gl"))
        end)

        -- Such as a page pointing FetchAnna at the device's own router.
        it("turns down a name that leads to any private address", function()
            OriginPolicy.resolve = function()
                return { "45.151.91.208", "192.168.1.1" }
            end
            local ok, err = OriginPolicy.checkHost("router.example")
            assert.is_nil(ok)
            assert.are.equal(OriginPolicy.PRIVATE, err)
            assert.is_truthy(helper.logged("warn", "router%.example leads to a private address: 192%.168%.1%.1"))
        end)

        -- curl may look it up with encrypted DNS, where the network's own blocks it.
        it("passes a name that can't be looked up here", function()
            OriginPolicy.resolve = function()
                return nil
            end
            assert.is_true(OriginPolicy.checkHost("annas-archive.gl"))
        end)

        it("looks names up with luasocket", function()
            helper.stub("socket", {
                dns = {
                    getaddrinfo = function(host)
                        assert.are.equal("annas-archive.gl", host)
                        return { { family = "inet", addr = "10.0.0.5" } }
                    end,
                },
            })
            assert.are.same({ "10.0.0.5" }, OriginPolicy.resolve("annas-archive.gl"))
            assert.is_nil((OriginPolicy.checkHost("annas-archive.gl")))
        end)

        it("looks names up with toip where luasocket can't list them all", function()
            helper.stub("socket", {
                dns = {
                    toip = function()
                        return "45.151.91.208"
                    end,
                },
            })
            assert.are.same({ "45.151.91.208" }, OriginPolicy.resolve("annas-archive.gl"))
        end)

        it("can't look names up without luasocket's DNS", function()
            helper.stub("socket", {})
            assert.is_nil(OriginPolicy.resolve("annas-archive.gl"))
            helper.stub("socket", {
                dns = {
                    getaddrinfo = function()
                        error("no network")
                    end,
                },
            })
            assert.is_nil(OriginPolicy.resolve("annas-archive.gl"))
        end)
    end)

    describe("resolveRedirect", function()
        it("follows the site's own paths, and says they're on the same site", function()
            local url, same =
                OriginPolicy.resolveRedirect("https://annas-archive.pk/search?q=dune", "/search?q=dune&check=1")
            assert.are.equal("https://annas-archive.pk/search?q=dune&check=1", url)
            assert.is_true(same)
        end)

        it("follows full addresses, saying when they're on another site", function()
            local url, same =
                OriginPolicy.resolveRedirect("https://open-slum.org/annas", "https://open-slum.org/annas.html")
            assert.are.equal("https://open-slum.org/annas.html", url)
            assert.is_true(same)

            url, same = OriginPolicy.resolveRedirect("https://annas-archive.pk/", "//annas-archive.gl/")
            assert.are.equal("https://annas-archive.gl/", url)
            assert.is_false(same)
        end)

        it("doesn't follow redirects to insecure, numeric or logged-in addresses", function()
            local from = "https://annas-archive.pk/dyn/api/fast_download.json"
            for location, why in pairs({
                ["http://annas-archive.pk/"] = OriginPolicy.NOT_HTTPS,
                ["https://10.0.0.1/"] = OriginPolicy.ADDRESS,
                ["https://u:p@annas-archive.pk/"] = OriginPolicy.CREDENTIALS,
                ["https://annas-archive.pk:8443/"] = OriginPolicy.PORT,
                ["relative/path"] = OriginPolicy.INVALID,
                [""] = OriginPolicy.INVALID,
            }) do
                local url, err = OriginPolicy.resolveRedirect(from, location)
                assert.is_nil(url, location)
                assert.are.equal(why, err, location)
            end
            assert.is_nil((OriginPolicy.resolveRedirect("http://annas-archive.pk/", "/x")))
        end)
    end)
end)
