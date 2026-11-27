local helper = require("helper")

describe("AnnasParser", function()
    local AnnasParser
    -- A member's results page, as it was on 2026-11-11 (see spec/data/annas/PROVENANCE.md).
    local page = helper.readFile("spec/data/annas/search-results-member.html")
    local challenge = helper.readFile("spec/data/annas/ddos-guard-403-challenge.html")
    local FIRST = "fbde8a9d82dc45577420e2034beece43"

    before_each(function()
        helper.reset()
        AnnasParser = require("fetchanna.api.annasparser")
    end)

    local function md5s(result)
        local list = {}
        for _, book in ipairs(result.books) do
            table.insert(list, book.md5)
        end
        return list
    end

    -- Returns the page with its results list changed by change(list).
    local function withList(change)
        local start = page:find('<div class="js-aarecord-list-outer">', 1, true)
        local finish = page:find("<nav", start, true)
        return page:sub(1, start - 1) .. change(page:sub(start, finish - 1)) .. page:sub(finish)
    end

    describe("reading a page of results", function()
        it("finds each book, by the md5 of its file", function()
            local result = assert(AnnasParser.parseResults(page, 1))
            assert.are.same({
                FIRST,
                "38c608e62b343809a645c01b50163ad9",
                "0d146f92908aa6ece29ae572f3dc0485",
                "4b3dff72611ec3d95348f12f95b8c493",
                "c4a746048c3a833b8bfc38fc73c2da13",
                "83c25234ecb2264d9b9e29e70b1373df",
                "3ee8503b2725ce808b44d80f0c9f6bcd",
                "14fa564810e675a6236e6fd7ad507be2",
                "066035c627795df28f259e386c200cd7",
                "83a51c118a8f7bb803aad2b6850b0b62",
                "7dc284b589530d38be995709c946e4c5",
                "44a92663fa147722e749d0df6f1c65a1",
            }, md5s(result))
            assert.are.equal(12, result.results)
            assert.are.equal(0, result.unreadable)
        end)

        it("reads each book's details", function()
            local book = assert(AnnasParser.parseResults(page, 1)).books[1]
            assert.are.equal("annas", book.source)
            assert.are.equal(FIRST, book.id)
            assert.are.equal("/md5/" .. FIRST, book.detail_path)
            assert.matches("^The Godparents: A Pride and Prejudice Variation", book.display_title)
            assert.matches("^The Godparents", book.title)
            assert.are.equal("Iris Lim", book.authors)
            assert.are.equal("2024", book.publisher)
            assert.are.equal("2024", book.year)
            assert.are.equal("English", book.language)
            assert.are.same({ "en" }, book.language_codes)
            assert.are.equal("epub", book.file_type)
            assert.are.equal("0.6 MB", book.file_size)
            assert.are.equal("Book (fiction)", book.book_type)
            assert.matches("^lgli/Iris Lim %- The Godparents", book.filename)
            assert.are.equal("https://covers.example/1.jpg", book.image_url)
        end)

        it("reads each file type, as KOReader names them", function()
            local types = {}
            for _, book in ipairs(assert(AnnasParser.parseResults(page, 1)).books) do
                table.insert(types, book.file_type)
            end
            assert.are.same(
                { "epub", "epub", "mobi", "mobi", "epub", "epub", "epub", "epub", "lit", "mobi", "epub", "epub" },
                types
            )
        end)

        it("keeps authors and publishers as they're written", function()
            local books = assert(AnnasParser.parseResults(page, 1)).books
            assert.are.equal("Ayr, Bray; Lady, a", books[5].authors)
            assert.are.equal("Song Sparrow Press, Sweet Pride and Prejudice Variations, 2023", books[2].publisher)
            assert.are.equal("Book (non-fiction)", books[3].book_type)
        end)

        it("reads the page after it from its own link to it", function()
            assert.are.equal(2, assert(AnnasParser.parseResults(page, 1)).next_page)
        end)

        -- As a browser saves them.
        it("reads links to the site's own pages written in full", function()
            local absolute = page:gsub('href="/', 'href="https://annas-archive.gl/')
            assert.are.same(
                md5s(assert(AnnasParser.parseResults(page, 1))),
                md5s(assert(AnnasParser.parseResults(absolute, 1)))
            )
        end)
    end)

    describe("reading only the page's own results", function()
        it("leaves out the partial matches listed after them", function()
            local partial = withList(function(list)
                return list
                    .. '<div class="js-aarecord-list-outer"><div class="flex"><a href="/md5/'
                    .. string.rep("a", 32)
                    .. '" class="js-vim-focus">Partial</a><div class="text-gray-800">English [en] · EPUB · 1MB ·<a '
                    .. 'href="#">Save</a></div></div></div>'
            end)
            assert.are.equal(12, #assert(AnnasParser.parseResults(partial, 1)).books)
        end)

        it("leaves out the site's recent downloads above them", function()
            local recent = page:gsub(
                "<form",
                'Recent downloads: <a href="/md5/'
                    .. string.rep("b", 32)
                    .. '" class="truncate">Someone else\'s</a><form',
                1
            )
            assert.are.equal(FIRST, assert(AnnasParser.parseResults(recent, 1)).books[1].md5)
            assert.are.equal(12, #assert(AnnasParser.parseResults(recent, 1)).books)
        end)

        it("lists a book once, however many times the page lists it", function()
            local doubled = withList(function(list)
                local first = list:match('(<div class="flex.-)<div class="flex')
                return list .. first
            end)
            assert.are.equal(12, #assert(AnnasParser.parseResults(doubled, 1)).books)
        end)
    end)

    describe("with fields that are missing or written oddly", function()
        it("says who wrote a book is unknown when it isn't said", function()
            local no_author = page:gsub('<a href="/search%?q=Iris%%20Lim".-</a>', "", 1)
            local book = assert(AnnasParser.parseResults(no_author, 1)).books[1]
            assert.are.equal("Unknown author", book.authors)
        end)

        -- Anna's Archive escapes only what it has to, and writes the rest as UTF-8.
        it("reads entities and other alphabets", function()
            -- Everywhere it's written: cover, file name and link.
            local renamed =
                page:gsub("One Night with Mr%. Darcy", "Café &amp; Crème &#x2014; 日本の本 &#39;&#232;&#39;")
            local book = assert(AnnasParser.parseResults(renamed, 1)).books[3]
            assert.are.equal("Café & Crème — 日本の本 'è'", book.display_title)
        end)

        it("leaves out a result it can't read, counting it, and reads the rest", function()
            local broken = page:gsub("English %[en%] · EPUB · 0%.6MB · 2024 · ", "", 1)
                :gsub("📕&nbsp;Book %(fiction%) · 🚀/lgli/zlib ·", "", 1)
            local result = assert(AnnasParser.parseResults(broken, 1))
            assert.are.equal(11, #result.books)
            assert.are.equal(1, result.unreadable)
            assert.is_truthy(helper.logged("warn", "^couldn't read Anna's Archive's result for " .. FIRST))
        end)

        it("doesn't go back or loop from page to page", function()
            assert.is_nil(assert(AnnasParser.parseResults(page, 2)).next_page)
            assert.is_truthy(helper.logged("warn", "next page goes to page 2 from page 2"))
            assert.is_nil(assert(AnnasParser.parseResults(page:gsub("page=2", "page=101"), 1)).next_page)
            assert.is_nil(
                assert(AnnasParser.parseResults(page:gsub("js%-pagination%-next%-page", "other"), 1)).next_page
            )
        end)
    end)

    -- Never reported as finding none.
    describe("with a page that isn't results", function()
        it("finds none where Anna's Archive found none", function()
            local none = withList(function()
                return '<div class="js-aarecord-list-outer"></div>'
            end)
            assert.are.same({ books = {}, results = 0, unreadable = 0 }, AnnasParser.parseResults(none, 1))
        end)

        it("says when Anna's Archive's search gave up, rather than that it found none", function()
            local gave_up = withList(function()
                return '<div class="mt-4 px-2">\226\157\140 Placeholder: the search took too long.</div>'
                    .. '<div class="js-aarecord-list-outer"></div>'
            end)
            assert.are.same({ nil, AnnasParser.TIMED_OUT }, { AnnasParser.parseResults(gave_up, 1) })
            local no_list = withList(function()
                return '<p class="mt-4 mb-4 px-2 italic">Placeholder: the search failed.</p>'
            end)
            assert.are.same({ nil, AnnasParser.TIMED_OUT }, { AnnasParser.parseResults(no_list, 1) })
        end)

        it("says when it's a bot check", function()
            assert.are.same({ nil, AnnasParser.CHALLENGE }, { AnnasParser.parseResults(challenge, 1) })
        end)

        it("says when it's Cloudflare's bot check", function()
            local cloudflare = helper.readFile("spec/data/annas/cloudflare-403-challenge.html")
            assert.is_true(AnnasParser.isChallenge(cloudflare))
            assert.are.same({ nil, AnnasParser.CHALLENGE }, { AnnasParser.parseResults(cloudflare, 1) })
        end)

        -- Cloudflare adds its bot-detection script to ordinary pages too.
        it("reads the results on a page with Cloudflare's bot-detection script", function()
            local beacon = helper.readFile("spec/data/annas/cloudflare-jsd-beacon.html")
            local with_beacon, added = page:gsub("</body>", function()
                return beacon .. "</body>"
            end)
            assert.are.equal(1, added)
            assert.is_false(AnnasParser.isChallenge(with_beacon))
            assert.are.same(md5s(AnnasParser.parseResults(page, 1)), md5s(AnnasParser.parseResults(with_beacon, 1)))
        end)

        -- Whatever a CDN adds, Anna's search form makes it a search page.
        it("reads the results on a page that also looks like a bot check", function()
            local marked = page:gsub("</body>", function()
                return "<script>window._cf_chl_opt = {};</script></body>"
            end)
            assert.are.same(md5s(AnnasParser.parseResults(page, 1)), md5s(AnnasParser.parseResults(marked, 1)))
        end)

        it("says when it doesn't know the page", function()
            for _, other in ipairs({ "<html>Welcome</html>", "", page:gsub('action="/search"', 'action="/other"') }) do
                assert.are.same({ nil, AnnasParser.UNRECOGNIZED }, { AnnasParser.parseResults(other, 1) })
            end
            assert.are.same({ nil, AnnasParser.UNRECOGNIZED }, { AnnasParser.parseResults(nil, 1) })
            assert.are.same(
                { nil, AnnasParser.UNRECOGNIZED },
                { AnnasParser.parseResults(page .. string.rep(" ", 8 * 1024 * 1024), 1) }
            )
        end)

        it("says when none of the results it lists can be read, as when the page has changed", function()
            local changed = page:gsub('class="text%-gray%-800', 'class="details')
            assert.are.same({ nil, AnnasParser.UNRECOGNIZED }, { AnnasParser.parseResults(changed, 1) })
            assert.is_truthy(helper.logged("warn", "^couldn't read any of the 12 results"))
        end)
    end)
end)
