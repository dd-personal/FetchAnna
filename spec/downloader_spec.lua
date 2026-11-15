local helper = require("helper")
local fixtures = require("fixtures")

describe("Downloader", function()
    local MB = 1024 * 1024
    local data_dir, filepath, book, web, mirrors, prompts, spawned, running, killed, results, remote_size
    -- The ETag the server sends with the book, if any (see CurlUtil.getValidator).
    local remote_etag
    -- The md5 of what arrived, where it isn't the one the site listed (see FileCheck).
    local arrived_md5
    -- Whether curl can fetch, and the downloads started with KOReader's own HTTP.
    local can_fetch, koreader_downloads
    local cover_downloads
    local CurlUtil, Downloader
    -- What the site lists the book's file as, if anything (see testSource).
    local listed_by_site

    local function adsUrl(mirror)
        return mirror .. "/ads.php?md5=" .. book.id
    end

    local function getUrl(mirror)
        return mirror .. "/get.php?md5=" .. book.id .. "&key=ABC123"
    end

    local function hasBook(mirror)
        web.pages[adsUrl(mirror)] = fixtures.adsPage(book.id)
    end

    -- The site these specs download from: none FetchAnna uses is as simple. Its mirrors, listed on MIRRORS_PAGE, are
    -- tried in turn, as KindleFetch's Library Genesis was. Each has a page per book linking to its file, and lists the
    -- file by its md5, which is its id. When a mirror lacks the book, the link is looked up again (see Downloader).
    local MIRRORS_PAGE = "https://mirrors.example/list"
    local MIRRORS = { "https://books1.example", "https://books2.example" }
    local function testSource()
        local HttpUtil = require("fetchanna.util.httputil")
        return {
            NAME = "Test Library",
            findDownloadLink = function(found)
                local list, list_err = HttpUtil.getBody(MIRRORS_PAGE)
                if list_err == HttpUtil.CANCELLED then
                    return nil, HttpUtil.CANCELLED
                end
                local listed = {}
                for mirror in (list or ""):gmatch("%S+") do
                    table.insert(listed, mirror)
                end
                local mirror_failed = false
                for i, mirror in ipairs(listed) do
                    -- The download's progress says this (see HttpUtil.sayStatus).
                    HttpUtil.sayStatus(
                        string.format("Trying %s (mirror %d of %d)...", mirror:match("[^/]+$"), i, #listed)
                    )
                    local page, err = HttpUtil.getBody(adsUrl(mirror))
                    if err == HttpUtil.CANCELLED then
                        return nil, HttpUtil.CANCELLED
                    end
                    local link = page and page:match('href="(get%.php[^"]+)"')
                    if link then
                        HttpUtil.sayStatus(nil)
                        return mirror .. "/" .. link, nil, mirror_failed, listed_by_site or { md5 = found.id }
                    end
                    mirror_failed = true
                end
                HttpUtil.sayStatus(nil)
                return nil, "no mirror has the book", mirror_failed
            end,
        }
    end
    -- Returns how many times the mirrors have been looked up.
    local function scrapes()
        local count = 0
        for _, url in ipairs(web.fetched) do
            if url == MIRRORS_PAGE then
                count = count + 1
            end
        end
        return count
    end

    local saved_filepath, opened_existing

    local function onResult(ok, err, path)
        table.insert(results, {
            ok = ok,
            err = err,
        })
        saved_filepath = path
    end

    local function onOpenExisting(path)
        opened_existing = path
    end

    -- Asks to download the book, then confirms the download prompt.
    local function download()
        local shown = #prompts
        Downloader:downloadBook(book, filepath, onResult, onOpenExisting)
        if #prompts > shown then
            prompts[#prompts].on_download(prompts[#prompts].filepath)
        end
    end

    local function progress()
        return Downloader.active_downloads[book.id].progress_widget
    end

    -- Simulates curl saving the headers, writing the book and exiting.
    local function curlWrote(bytes, exit_code)
        if remote_size then
            helper.writeFile(
                spawned[#spawned].headers_file,
                "HTTP/2 200\r\ncontent-type: application/epub+zip\r\ncontent-length: "
                    .. remote_size
                    .. "\r\n"
                    .. (remote_etag and "etag: " .. remote_etag .. "\r\n" or "")
                    .. "\r\n"
            )
        end
        helper.writeFile(spawned[#spawned].path, fixtures.bookFile(book.file_type, bytes))
        if exit_code then
            helper.writeFile(spawned[#spawned].exit_file, tostring(exit_code))
        end
    end

    -- What a site sends in place of a book, for example to say it's busy.
    local PAGE = "<!DOCTYPE html>\n<html><head><title>Please wait</title></head><body>Busy</body></html>"

    -- Simulates curl downloading what the site sent in place of the book, then exiting.
    local function curlSent(content)
        helper.writeFile(spawned[#spawned].headers_file, "HTTP/2 200\r\ncontent-length: " .. #content .. "\r\n\r\n")
        helper.writeFile(spawned[#spawned].path, content)
        helper.writeFile(spawned[#spawned].exit_file, "0")
    end

    -- Makes the md5 check take steps: no md5 until the given step, then the one listed.
    local function checkTakesSteps(steps)
        local checks = { steps = 0 }
        require("fetchanna.util.filecheck").md5 = function()
            return {
                step = function()
                    checks.steps = checks.steps + 1
                    return checks.steps >= steps and book.id:lower() or nil
                end,
                close = function()
                    checks.closed = true
                end,
            }
        end
        return checks
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/Books"))
        filepath = data_dir .. "/Dune.epub"
        book = {
            source = "test",
            id = fixtures.DUNE.md5,
            title = "Dune",
            display_title = "Dune",
            image_url = fixtures.DUNE.image_url,
            file_type = "epub",
        }

        prompts, spawned, running, killed, results = {}, {}, {}, {}, {}
        opened_existing = nil
        remote_size = MB
        remote_etag = nil
        web = fixtures.fakeWeb(helper)

        CurlUtil = require("fetchanna.util.curlutil")
        can_fetch, koreader_downloads = true, {}
        CurlUtil.canFetch = function()
            return can_fetch
        end
        CurlUtil.startDownload = function(url, path, _, opts)
            local exit_file = CurlUtil.createExitFile()
            table.insert(spawned, {
                url = url,
                path = path,
                pid = 1000 + #spawned,
                exit_file = exit_file,
                headers_file = opts.headers_file,
                stall_time = opts.stall_time,
                resume = opts.resume,
                if_range = opts.if_range,
                sensitive = opts.sensitive,
            })
            return spawned[#spawned].pid, exit_file
        end
        -- Followed the same way as a curl download (see HttpDownload).
        require("fetchanna.util.httpdownload").start = function(url, path, opts)
            table.insert(koreader_downloads, url)
            return CurlUtil.startDownload(url, path, nil, opts)
        end
        -- Book covers download in the background, and fail here.
        cover_downloads = {}
        CurlUtil.downloadMultiple = function(urls)
            table.insert(cover_downloads, urls)
            return nil, nil, nil, "unable to launch curl"
        end
        CurlUtil.isPidRunning = function(pid)
            return running[pid] ~= false
        end
        CurlUtil.killPid = function(pid)
            table.insert(killed, pid)
        end
        -- Worked out a piece at a time, all at once here.
        arrived_md5 = nil
        require("fetchanna.util.filecheck").md5 = function()
            return {
                step = function()
                    return arrived_md5 or book.id:lower()
                end,
                close = function() end,
            }
        end

        helper.stub("fetchanna.ui.downloadprompt", {
            new = function(prompt_book, prompt_filepath, on_download)
                return {
                    book = prompt_book,
                    filepath = prompt_filepath,
                    on_download = on_download,
                    show = function(self)
                        table.insert(prompts, self)
                    end,
                }
            end,
        })

        require("fetchanna.api.sources").test = testSource()
        listed_by_site = nil
        Downloader = require("fetchanna.api.downloader")
        Downloader.active_downloads = {}

        mirrors = MIRRORS
        web.pages[MIRRORS_PAGE] = table.concat(MIRRORS, "\n")
        hasBook(mirrors[1])
    end)

    after_each(helper.cleanup)

    describe("downloadBook", function()
        it("asks where to save the book, getting its cover in the background", function()
            Downloader:downloadBook(book, filepath, onResult)

            assert.are.equal(1, #prompts)
            assert.are.equal(filepath, prompts[1].filepath)
            assert.are.same({ { book.image_url } }, cover_downloads)
            assert.are.equal(0, #spawned)
        end)

        it("does not download covers it already has", function()
            fixtures.cacheCover(helper, book.id)
            CurlUtil.downloadMultiple = function()
                error("should not download")
            end

            Downloader:downloadBook(book, filepath, onResult)
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the book has no cover", function()
            book.image_url = nil
            Downloader:downloadBook(book, filepath, onResult)

            assert.is_false(require("fetchanna.cache.covercache"):cacheExists(book.id))
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the cover cannot be fetched", function()
            Downloader:downloadBook(book, filepath, onResult)
            helper.runScheduled()

            assert.are.equal(1, #prompts)
            assert.is_false(require("fetchanna.cache.covercache"):cacheExists(book.id))
        end)

        it("downloads to the folder chosen in the prompt", function()
            Downloader:downloadBook(book, filepath, onResult)
            prompts[1].on_download(data_dir .. "/Books/Dune.epub")

            assert.are.equal(data_dir .. "/Books/Dune.epub.part", spawned[1].path)
        end)

        it("says where the book was saved", function()
            Downloader:downloadBook(book, filepath, onResult)
            filepath = data_dir .. "/Books/Dune.epub"
            prompts[1].on_download(filepath)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(data_dir .. "/Books/Dune.epub", saved_filepath)
        end)

        describe("when the book is already there", function()
            local confirm

            before_each(function()
                helper.writeFile(filepath, "another edition of Dune")
                download()
                confirm = helper.lastShown()
            end)

            -- It may be another edition with the same title.
            it("asks before downloading over it", function()
                assert.are.equal(filepath .. " already exists.", confirm.text)
                assert.are.equal("Overwrite", confirm.ok_text)
                assert.are.equal(0, #spawned)
                assert.are.equal("another edition of Dune", helper.readFile(filepath))
            end)

            it("downloads over it once told to", function()
                confirm.ok_callback()
                assert.are.equal(1, #spawned)

                -- The old file is kept until the new one has all arrived.
                curlWrote(MB / 2)
                helper.tick()
                assert.are.equal("another edition of Dune", helper.readFile(filepath))

                curlWrote(MB, 0)
                helper.runScheduled()
                assert.are.same({ { ok = true } }, results)
                assert.are.equal(MB, #helper.readFile(filepath))
            end)

            it("keeps it when downloading over it fails", function()
                confirm.ok_callback()
                curlWrote(MB / 2, 28)
                helper.runScheduled()

                assert.are.same({ { ok = false, err = "request timed out" } }, results)
                assert.are.equal("another edition of Dune", helper.readFile(filepath))
            end)

            it("can open it instead", function()
                local read_existing = confirm.other_buttons[1][1]
                assert.are.equal("Read existing book", read_existing.text)

                read_existing.callback()
                assert.are.equal(filepath, opened_existing)
                assert.are.equal(0, #spawned)
                assert.are.same({}, results)
            end)

            it("only offers to open it when it can be", function()
                Downloader:downloadBook(book, filepath, onResult)
                prompts[#prompts].on_download(filepath)

                assert.are.equal("Overwrite", helper.lastShown().ok_text)
                assert.is_nil(helper.lastShown().other_buttons)
            end)

            it("doesn't ask when another folder is chosen in the prompt", function()
                Downloader:downloadBook(book, filepath, onResult, onOpenExisting)
                prompts[#prompts].on_download(data_dir .. "/Books/Dune.epub")

                assert.is_nil(helper.lastShown().ok_text)
                assert.are.equal(data_dir .. "/Books/Dune.epub.part", spawned[1].path)
            end)
        end)

        -- Otherwise it's only found out after the link lookup, which can count as a fast download.
        it("doesn't look up the link when the folder chosen can't be found", function()
            Downloader:downloadBook(book, filepath, onResult)
            prompts[1].on_download(data_dir .. "/SD card/Dune.epub")

            assert.are.same({
                {
                    ok = false,
                    err = "books can't be saved in "
                        .. data_dir
                        .. "/SD card, as it doesn't exist, so choose another folder",
                },
            }, results)
            assert.are.equal(0, #spawned)
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.are.equal(0, #web.fetched)
        end)

        -- For example another edition with the same title. Sharing a .part file, one would be saved as the other.
        it("doesn't download two books to the same name at once", function()
            download()
            local other_edition = {
                source = "test",
                id = fixtures.DUNE.md5:gsub("^.", "f"),
                title = "Dune",
                file_type = "epub",
            }
            Downloader:downloadBook(other_edition, filepath, onResult)
            prompts[2].on_download(filepath)

            assert.are.same({
                {
                    ok = false,
                    err = "another book is already downloading as Dune.epub, so wait for it to finish, or choose "
                        .. "another folder",
                },
            }, results)
            assert.are.equal(1, #spawned)
            assert.is_nil(Downloader.active_downloads[other_edition.id])
        end)

        it("shows the progress again when a book that is already downloading is chosen", function()
            download()
            local widget = progress()
            widget.hide_button.callback()
            assert.is_false(widget.is_visible)

            download()
            assert.is_true(widget.is_visible)
            assert.are.equal(widget.container, helper.lastShown())
            assert.are.equal(1, #spawned)
            assert.are.same({}, results)
        end)

        it("leaves visible progress alone when a book that is already downloading is chosen", function()
            download()
            local shown = #helper.state.shown

            download()
            assert.is_true(progress().is_visible)
            assert.are.equal(shown, #helper.state.shown)
            assert.are.equal(1, #spawned)
        end)
    end)

    describe("downloading", function()
        it("downloads the book through the link on the mirror's ads page", function()
            download()

            assert.are.same({
                url = getUrl(mirrors[1]),
                path = filepath .. ".part",
                pid = 1000,
                exit_file = spawned[1].exit_file,
                headers_file = spawned[1].headers_file,
                -- So a stalled download isn't waited on forever.
                stall_time = 30,
                -- And curl's retries carry on from where it stopped.
                resume = true,
            }, spawned[1])
            assert.is_string(spawned[1].headers_file)
        end)

        -- This can mean trying several mirrors, each taking a while to answer.
        describe("while looking up the download link", function()
            local HttpUtil, Trapper, getBody

            before_each(function()
                HttpUtil = require("fetchanna.util.httputil")
                Trapper = require("ui/trapper")
                getBody = HttpUtil.getBody
            end)

            it("doesn't hold KOReader up, letting the progress's Cancel call it off", function()
                local waits = {}
                HttpUtil.getBody = function(url)
                    table.insert(waits, { wrapped = Trapper:isWrapped(), trap_widget = HttpUtil.getTrapWidget() })
                    return getBody(url)
                end

                download()
                -- The site's list of mirrors, then the mirror's page for the book.
                assert.are.equal(2, #waits)
                for _, wait in ipairs(waits) do
                    assert.is_true(wait.wrapped)
                    assert.are.equal(progress(), wait.trap_widget)
                end
                assert.is_nil(HttpUtil.getTrapWidget())
                assert.are.equal(1, #spawned)
            end)

            -- Taps would only arrive once it's over.
            it("can't be cancelled or hidden while KOReader's own HTTP holds KOReader up", function()
                can_fetch = false
                local enabled = {}
                HttpUtil.getBody = function(url)
                    table.insert(enabled, progress().cancel_button.enabled)
                    table.insert(enabled, progress().hide_button.enabled)
                    return getBody(url)
                end

                download()
                assert.are.same({ false, false, false, false }, enabled)
                assert.is_true(progress().cancel_button.enabled)
                assert.is_true(progress().hide_button.enabled)
            end)

            it("can be cancelled and hidden while curl looks it up in the background", function()
                HttpUtil.canCancel = function()
                    return true
                end
                local enabled = {}
                HttpUtil.getBody = function(url)
                    table.insert(enabled, progress().cancel_button.enabled ~= false)
                    return getBody(url)
                end

                download()
                assert.are.same({ true, true }, enabled)
            end)

            it("can be called off, which says nothing about the mirrors", function()
                HttpUtil.getBody = function(url)
                    if url:find("/ads.php", 1, true) then
                        progress().cancel_button.callback()
                        return nil, HttpUtil.CANCELLED
                    end
                    return getBody(url)
                end

                download()
                assert.are.same({ { ok = false, err = "request cancelled" } }, results)
                assert.are.equal(0, #spawned)
                assert.are.same({}, Downloader:getActiveDownloads())
                assert.is_nil(HttpUtil.getTrapWidget())
                -- Nor looked up again.
                assert.are.equal(1, scrapes())
            end)

            -- A new download's progress would show again. This one stays hidden.
            it("stays hidden when hidden while a mirror fails, and the mirrors are looked up again", function()
                local failed = false
                HttpUtil.getBody = function(url)
                    if url:find("/ads.php", 1, true) and not failed then
                        failed = true
                        progress().hide_button.callback()
                        return nil, "HTTP error response", 500
                    end
                    return getBody(url)
                end

                download()
                assert.are.equal(2, scrapes())
                assert.are.equal(1, #spawned)
                assert.is_false(progress().is_visible)
            end)

            it("says something went wrong, rather than leaving the progress showing", function()
                local widget
                HttpUtil.getBody = function()
                    widget = progress()
                    error("unexpected")
                end

                download()
                assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
                assert.is_true(helper.wasClosed(widget.container))
                assert.are.same({}, Downloader:getActiveDownloads())
                assert.is_nil(HttpUtil.getTrapWidget())
                assert.is_truthy(helper.logged("err", "^looking up the download link went wrong:.*unexpected"))
            end)
        end)

        -- Unhandled, KOReader would exit, leaving curl running and the progress up.
        it("stops the download, and says something went wrong, when checking on it goes wrong", function()
            download()
            local widget = progress()
            CurlUtil.getDownloadSize = function()
                error("unexpected")
            end
            curlWrote(MB / 2)
            helper.tick()

            assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
            assert.are.same({ 1000 }, killed)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_false(helper.exists(spawned[1].headers_file))
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.is_truthy(helper.logged("err", "^checking on a download went wrong:.*unexpected"))
            -- It isn't checked on again.
            assert.are.equal(0, helper.tick())
        end)

        -- For example offering to read it. The book did download.
        it("doesn't say a download failed once it has finished, when what's done with the book goes wrong", function()
            Downloader:downloadBook(book, filepath, function(ok, err)
                table.insert(results, { ok = ok, err = err })
                if ok then
                    error("unexpected")
                end
            end, onOpenExisting)
            prompts[1].on_download(prompts[1].filepath)
            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({ { ok = true } }, results)
            assert.is_true(helper.exists(filepath))
            -- Once it was checked.
            assert.is_truthy(helper.logged("err", "^checking a downloaded book went wrong:.*unexpected"))
        end)

        -- Trapper drops errors once its function has waited on something, so this one would be lost.
        it("says something went wrong when starting the download goes wrong once its link is found", function()
            CurlUtil.createHeadersFile = function()
                error("unexpected")
            end
            Downloader:downloadBook(book, filepath, onResult)
            local widget
            local show = require("fetchanna.ui.downloadprogress").show
            require("fetchanna.ui.downloadprogress").show = function(self)
                widget = self
                return show(self)
            end
            prompts[1].on_download(filepath)

            assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.is_truthy(helper.logged("err", "^starting the download of Dune went wrong:.*unexpected"))
        end)

        -- Otherwise every download fails on a device without curl, as a Kobo can be (KindleFetch #63).
        it("downloads with KOReader's own HTTP where curl can't", function()
            can_fetch = false
            download()
            assert.are.same({ getUrl(mirrors[1]) }, koreader_downloads)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(MB, #helper.readFile(filepath))
            -- Its process is collected once it's over.
            assert.is_true(helper.state.subprocesses_collected[1000])
        end)

        -- It could be another book entirely, with the same title.
        it("doesn't carry on from what's left of an earlier download of a book of the same name", function()
            helper.writeFile(filepath .. ".part", "another book")
            download()
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_true(spawned[1].resume)
        end)

        it("starts again from the beginning when the site can't carry on from where the download stopped", function()
            download()
            curlWrote(MB / 2, 33)
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.is_false(spawned[2].resume)
            assert.is_false(helper.exists(filepath .. ".part"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        -- So half a book never looks like a whole one.
        it("downloads next to where the book is wanted, moving it there once it has all arrived", function()
            download()
            curlWrote(MB / 2)
            helper.tick()
            assert.is_false(helper.exists(filepath))
            assert.is_true(helper.exists(filepath .. ".part"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.equal(MB, #helper.readFile(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
        end)

        it("fails when the book can't be moved to where it's wanted", function()
            download()
            -- Something else is in the way.
            helper.run("mkdir -p " .. helper.quote(filepath .. "/folder"))
            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({ { ok = false, err = "could not save the book" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_truthy(helper.logged("warn", "^could not move the downloaded book from"))
        end)

        it("shows the download progress", function()
            download()
            local widget = progress()
            assert.are.same(widget.container, helper.lastShown())

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal(0.5, widget.bar_widget.percentage)
            assert.are.equal("50% · 0.5 / 1.0 MB", widget.status_widget.text)
        end)

        -- Not in a notification of its own.
        it("says what it's waiting for until the book starts to arrive", function()
            local HttpUtil = require("fetchanna.util.httputil")
            local getBody = HttpUtil.getBody
            local while_finding_the_link
            HttpUtil.getBody = function(url)
                if url:find("/ads.php", 1, true) then
                    while_finding_the_link = progress().status_text
                end
                return getBody(url)
            end

            download()
            -- Once the mirrors are looked up, it says which one is being asked.
            assert.are.equal("Trying books1.example (mirror 1 of 2)...", while_finding_the_link)
            assert.are.equal("Waiting for Test Library...", progress().status_widget.text)
            helper.tick()
            assert.are.equal("Waiting for Test Library...", progress().status_widget.text)

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal("50% · 0.5 / 1.0 MB", progress().status_widget.text)
        end)

        -- Otherwise KOReader looks stuck, as curl only retries after a while. Stalled means 20 checks (10 seconds) with
        -- nothing new, counted so clock changes don't matter.
        it("says when the download has stalled", function()
            helper.state.time = 1000
            download()
            curlWrote(MB / 2)
            helper.tick()
            helper.state.time = 5000
            for _ = 1, 19 do
                helper.tick()
            end
            assert.are.equal("50% · 0.5 / 1.0 MB", progress().status_widget.text)

            helper.state.time = 10
            helper.tick()
            assert.are.equal("Stalled at 50%, retrying...", progress().status_widget.text)
            assert.are.equal(0.5, progress().bar_widget.percentage)

            -- Until more arrives.
            curlWrote(MB * 3 / 4)
            helper.tick()
            assert.are.equal("75% · 0.8 / 1.0 MB", progress().status_widget.text)
        end)

        it("says when a download of unknown size has stalled", function()
            remote_size = nil
            download()
            curlWrote(MB / 2)
            for _ = 1, 21 do
                helper.tick()
            end
            assert.are.equal("Stalled at 0.5 MB, retrying...", progress().status_widget.text)
        end)

        -- No separate request for the size is made before downloading.
        it("works out the book's size from the headers curl notes down as the book starts to arrive", function()
            download()
            local widget = progress()

            helper.tick()
            assert.are.equal("Waiting for Test Library...", widget.status_widget.text)

            helper.writeFile(
                spawned[1].headers_file,
                "HTTP/1.1 302 Found\r\nLocation: https://cdn.example/dune\r\nContent-Length: 0\r\n\r\n"
                    .. "HTTP/2 200\r\ncontent-length: "
                    .. 2 * MB
                    .. "\r\n\r\n"
            )
            helper.writeFile(spawned[1].path, fixtures.bookFile(book.file_type, MB / 2))
            helper.tick()
            assert.are.equal("25% · 0.5 / 2.0 MB", widget.status_widget.text)
            assert.is_truthy(helper.logged("info", "^the file is " .. 2 * MB .. " bytes$"))
        end)

        it("removes the headers curl noted down once the download is over", function()
            download()
            curlWrote(MB, 0)
            assert.is_true(helper.exists(spawned[1].headers_file))

            helper.runScheduled()
            assert.is_false(helper.exists(spawned[1].headers_file))
        end)

        it("stays below 100% until curl has finished", function()
            remote_size = 2 * MB
            download()
            local widget = progress()

            curlWrote(2 * MB)
            helper.tick()
            assert.are.equal(0.99, widget.bar_widget.percentage)
        end)

        it("shows how much has downloaded when the file is bigger than its size said", function()
            remote_size = 638
            download()
            local widget = progress()

            curlWrote(2 * MB)
            helper.tick()
            assert.are.equal("2.0 MB", widget.status_widget.text)
        end)

        it("shows how much has downloaded when the size is unknown", function()
            remote_size = nil
            download()
            local widget = progress()

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal("0.5 MB", widget.status_widget.text)
        end)

        describe("checking what arrived is the book", function()
            it("checks it's the file listed, by its md5", function()
                download()
                curlWrote(MB, 0)
                helper.runScheduled()

                assert.are.same({ { ok = true } }, results)
                assert.is_truthy(helper.logged("info", "^it has the md5 listed$"))
            end)

            it("fails when it isn't the file listed, which may be damaged", function()
                arrived_md5 = string.rep("0", 32)
                download()
                curlWrote(MB, 0)
                helper.runScheduled()

                assert.are.same({
                    { ok = false, err = "the file that downloaded doesn't match the one listed, and may be damaged" },
                }, results)
                assert.is_false(helper.exists(filepath))
                assert.is_false(helper.exists(filepath .. ".part"))
                assert.is_truthy(
                    helper.logged("warn", '^"Dune" has the md5 0+, rather than the ' .. book.id .. " listed$")
                )
            end)

            it("says when a web page arrived in place of the book", function()
                download()
                curlSent(PAGE)
                helper.runScheduled()

                assert.are.same({
                    { ok = false, err = "Test Library sent a web page rather than the book, try again later" },
                }, results)
                assert.is_false(helper.exists(filepath))
                assert.is_false(helper.exists(filepath .. ".part"))
                assert.is_truthy(helper.logged("warn", '^a web page arrived in place of "Dune": Please wait$'))
            end)

            it("says when what arrived isn't in the book's file type", function()
                download()
                curlSent(fixtures.bookFile("pdf", MB))
                helper.runScheduled()

                assert.are.same(
                    { { ok = false, err = "the file that downloaded isn't the EPUB it should be" } },
                    results
                )
                assert.is_false(helper.exists(filepath))
            end)

            -- curl doesn't always notice.
            it("fails when less arrived than the site said it would send", function()
                download()
                curlWrote(MB / 2, 0)
                helper.runScheduled()

                assert.are.same({ { ok = false, err = "partial file transfer (download interrupted)" } }, results)
                assert.is_false(helper.exists(filepath))
                assert.is_truthy(helper.logged("warn", '^only 524288 of the 1048576 bytes of "Dune" arrived$'))
            end)

            it("says it's checking the book, which takes a while for a large one, and can be cancelled", function()
                local checks = checkTakesSteps(10)
                download()
                local widget = progress()
                curlWrote(MB, 0)
                helper.tick()
                helper.tick()
                assert.are.equal("Checking the book...", widget.status_widget.text)
                assert.are.equal(1, widget.bar_widget.percentage)
                assert.are.same({}, results)

                widget.cancel_button.callback()
                helper.runScheduled()
                assert.are.same({ { ok = false, err = "request cancelled" } }, results)
                -- curl had finished, so there's nothing to kill.
                assert.are.same({}, killed)
                assert.is_true(checks.closed)
                assert.is_true(checks.steps < 10)
                assert.is_false(helper.exists(filepath .. ".part"))
                assert.is_false(helper.exists(filepath))
                assert.are.same({}, Downloader:getActiveDownloads())
            end)

            -- It has all arrived.
            it("carries on checking the book while the device sleeps", function()
                checkTakesSteps(3)
                download()
                curlWrote(MB, 0)
                helper.tick()
                Downloader:onSuspend()
                Downloader:onNetworkDisconnected()
                Downloader:onResume()
                helper.runScheduled()

                assert.are.same({ { ok = true } }, results)
                assert.are.equal(1, #spawned)
            end)
        end)

        it("finishes once curl exits successfully", function()
            download()
            local widget = progress()

            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({ { ok = true } }, results)
            assert.are.equal(1, widget.bar_widget.percentage)
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.are.equal(MB, #helper.readFile(filepath))
            -- For reading crash.log from a device.
            assert.is_truthy(helper.logged("info", '^downloading "Dune" %(epub, .-, id %x+%) to '))
            assert.is_truthy(helper.logged("info", '^downloaded "Dune": ' .. MB .. " bytes in %d+s$"))
        end)

        it("works without knowing the file size", function()
            remote_size = nil
            download()

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        -- Rather than failing, as the device may only be offline for a moment.
        it("turns on wifi first when offline, then downloads once connected", function()
            hasBook(mirrors[1])
            helper.stubs.network.connected = false

            download()
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.same({}, spawned)

            helper.stubs.network.connected = true
            helper.stubs.network.when_connected()
            assert.are.equal(getUrl(mirrors[1]), spawned[1].url)
        end)

        it("fails when curl cannot be started", function()
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end

            download()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
            assert.are.same({}, Downloader:getActiveDownloads())
        end)

        it("fails and removes the partial file when curl fails", function()
            download()

            curlWrote(MB / 2, 22)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "HTTP error response" } }, results)
            assert.is_false(helper.exists(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
            -- With what's needed to work out why from crash.log.
            assert.matches(
                'download of "Dune" from [%w%.]+ failed after %d+s: curl exit code 22 %(HTTP error '
                    .. "response%), "
                    .. MB / 2
                    .. " of %d+ bytes",
                helper.logged("warn", "failed after")
            )
        end)

        -- "TLS connection failed" alone doesn't say what to do about it.
        it("says when a Kindle's curl is too old to download the book, and how to update it", function()
            helper.stubCommand("curl --version", "curl 7.68.0 (arm-kindle-linux-gnueabi) libcurl/7.68.0\n")
            CurlUtil.forgetVersion()
            download()
            curlWrote(0, 35)
            helper.runScheduled()

            assert.are.same({ { ok = false, err = CurlUtil.OUTDATED_ERROR } }, results)
            assert.matches("Check for updates", CurlUtil.OUTDATED_ERROR, 1, true)
        end)

        -- The mirrors can link to the book, then answer with an error.
        it("says Test Library is too busy when its servers fail to send the book", function()
            download()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 503 \r\ncontent-length: 212\r\n\r\n")
            helper.writeFile(spawned[1].exit_file, "22")
            helper.runScheduled()

            assert.are.same({
                {
                    ok = false,
                    err = "Test Library is too busy to send books right now, try again in a few minutes",
                },
            }, results)
            assert.matches("curl exit code 22 %(HTTP error response, HTTP 503%)", helper.logged("warn", "failed after"))
        end)

        it("says which HTTP error stopped the download when it isn't Test Library' servers failing", function()
            download()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 404 \r\ncontent-length: 9\r\n\r\n")
            helper.writeFile(spawned[1].exit_file, "22")
            helper.runScheduled()

            assert.are.same({ { ok = false, err = "HTTP error response (HTTP 404)" } }, results)
        end)

        it("fails when the downloaded file is empty", function()
            download()

            curlWrote(0, 0)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "download produced empty file" } }, results)
        end)

        -- curl can finish after its exit code was checked but before the check that it's running.
        it("finishes when curl exits between checks", function()
            download()
            CurlUtil.isPidRunning = function()
                curlWrote(MB, 0)
                return false
            end
            helper.runScheduled()

            assert.are.same({ { ok = true } }, results)
        end)

        it("fails when curl stops without reporting back", function()
            download()

            running[spawned[1].pid] = false
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "download process ended unexpectedly" } }, results)
        end)

        it("fails when it can't be started again from the beginning", function()
            download()
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end

            -- The site can't carry on from where it stopped.
            curlWrote(MB / 2, 33)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
        end)

        it("can be cancelled from the progress widget", function()
            download()
            curlWrote(MB / 2)

            progress().cancel_button.callback()
            helper.runScheduled()

            assert.are.same({ spawned[1].pid, spawned[1].pid }, killed)
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
            assert.is_false(helper.exists(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
        end)
    end)

    -- As from Test Library, but the link is looked up on the site the book was found on.
    describe("a book whose site lists its file's md5 and size", function()
        local LISTED = "0123456789ABCDEF0123456789ABCDEF"

        before_each(function()
            listed_by_site = { md5 = LISTED, bytes = tostring(2 * MB) }
            remote_size = 2 * MB
        end)

        it("checks its md5", function()
            arrived_md5 = LISTED:lower()
            download()
            curlWrote(2 * MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        it("fails when its md5 isn't the one listed", function()
            arrived_md5 = string.rep("0", 32)
            download()
            curlWrote(2 * MB, 0)
            helper.runScheduled()
            assert.are.same({
                { ok = false, err = "the file that downloaded doesn't match the one listed, and may be damaged" },
            }, results)
        end)

        -- However big the site said it was when sending it.
        it("fails when it's smaller than listed", function()
            remote_size = MB
            download()
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "partial file transfer (download interrupted)" } }, results)
        end)

        it("doesn't check an md5 that isn't one", function()
            listed_by_site = { md5 = "not an md5" }
            local checks = checkTakesSteps(1)
            download()
            curlWrote(2 * MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(0, checks.steps)
        end)
    end)

    -- Some of its servers can fail for a while.
    describe("a book from a site whose links each go to one of its servers", function()
        local links

        -- Simulates curl being answered with the HTTP status and giving up.
        local function serverAnswered(status)
            helper.writeFile(spawned[#spawned].headers_file, "HTTP/2 " .. status .. " \r\ncontent-length: 0\r\n\r\n")
            helper.writeFile(spawned[#spawned].exit_file, "22")
        end

        before_each(function()
            local md5 = "0123456789abcdef0123456789abcdef"
            book = {
                source = "annas",
                id = md5,
                md5 = md5,
                title = "1984",
                display_title = "1984",
                file_type = "epub",
            }
            -- As Anna's Archive's member API gives them (see AnnasSearch), each to one download server.
            links = 0
            require("fetchanna.api.sources").annas.findDownloadLink = function()
                links = links + 1
                return string.format("https://dl%d.example/1984.epub", links), nil, false, { md5 = md5 }
            end
        end)

        it("asks for another link once the server the link went to fails", function()
            download()
            assert.are.equal("https://dl1.example/1984.epub", spawned[1].url)
            serverAnswered(522)
            helper.tick()

            assert.are.equal(2, links)
            assert.are.equal("https://dl2.example/1984.epub", spawned[2].url)
            assert.are.same({}, results)
            assert.is_truthy(helper.logged("info", "^asking for another download link"))
            assert.are.equal("Waiting for Anna's Archive...", progress().status_widget.text)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(MB, #helper.readFile(filepath))
        end)

        it("asks for another link once the server the link went to sends a web page in place of the book", function()
            download()
            curlSent(PAGE)
            helper.tick()

            assert.are.equal(2, links)
            assert.are.equal("https://dl2.example/1984.epub", spawned[2].url)
            assert.are.same({}, results)
            assert.is_truthy(helper.logged("info", "^asking for another download link, .* didn't send the book$"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        -- Another link can count as another fast download, except for a book just downloaded.
        it("doesn't ask for another link when Wi-Fi went off, carrying on with the same one once it's back", function()
            download()
            require("ui/network/manager").connected = false
            curlWrote(MB / 2, 6)
            helper.tick()
            assert.are.equal(1, links)

            require("ui/network/manager").connected = true
            helper.tick()
            assert.are.equal(1, links)
            assert.are.equal("https://dl1.example/1984.epub", spawned[2].url)
        end)

        -- A new download's progress would show again. This one stays hidden.
        it("keeps a hidden download's progress hidden while it asks for another link", function()
            download()
            progress().hide_button.callback()
            local shown = #helper.state.shown
            serverAnswered(522)
            helper.tick()

            assert.are.equal(2, #spawned)
            assert.is_false(progress().is_visible)
            assert.are.equal(shown, #helper.state.shown)
            -- It can still be shown again.
            assert.is_true(Downloader:showDownload(book.id))
            assert.are.equal(progress().container, helper.lastShown())
        end)

        it("asks for another link when the server doesn't answer at all", function()
            download()
            helper.writeFile(spawned[1].exit_file, "7")
            helper.tick()

            assert.are.equal(2, #spawned)
        end)

        it("gives up when the server the second link went to fails too", function()
            download()
            serverAnswered(522)
            helper.tick()
            serverAnswered(522)
            helper.runScheduled()

            assert.are.equal(2, links)
            assert.are.same({
                { ok = false, err = "Anna's Archive is too busy to send books right now, try again in a few minutes" },
            }, results)
        end)

        -- Another link wouldn't change that.
        it("doesn't ask for another link when the server turns down how it was asked", function()
            download()
            serverAnswered(400)
            helper.runScheduled()

            assert.are.equal(1, links)
            assert.are.same({ { ok = false, err = "HTTP error response (HTTP 400)" } }, results)
        end)
    end)

    describe("a book found on Anna's Archive", function()
        local MD5 = "0123456789abcdef0123456789abcdef"
        local lookups

        -- Simulates curl being answered with the HTTP status and giving up.
        local function serverAnswered(status)
            helper.writeFile(spawned[#spawned].headers_file, "HTTP/2 " .. status .. " \r\ncontent-length: 0\r\n\r\n")
            helper.writeFile(spawned[#spawned].exit_file, "22")
        end

        before_each(function()
            book = {
                source = "annas",
                id = MD5,
                md5 = MD5,
                title = "Emma",
                display_title = "Emma",
                file_type = "epub",
            }
            lookups = {}
            -- As the member API gives them (see AnnasSearch): a signed link to a download server.
            require("fetchanna.api.sources").annas.findDownloadLink = function(found, retrying, failed_url)
                table.insert(lookups, { md5 = found.md5, retrying = retrying, failed_url = failed_url })
                return string.format("https://dl%d.example/d3/y/1763000000/signature/%s.epub", #lookups, MD5),
                    nil,
                    false,
                    { md5 = MD5 }
            end
        end)

        it("gives curl its signed link as the secret it is, and checks the md5 of what arrives", function()
            local checks = checkTakesSteps(1)
            download()
            assert.is_true(spawned[1].sensitive)
            assert.is_nil(helper.allLogged():find("signature", 1, true))
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(1, checks.steps)
        end)

        -- A signed link expires after two hours, and asking again for the same book is free.
        it("asks for another link once when the server no longer takes the one it has", function()
            download()
            serverAnswered(403)
            helper.tick()

            assert.are.equal(2, #lookups)
            assert.are.same({ md5 = MD5, retrying = true, failed_url = spawned[1].url }, lookups[2])
            assert.are.equal("https://dl2.example/d3/y/1763000000/signature/" .. MD5 .. ".epub", spawned[2].url)
            assert.is_truthy(helper.logged("info", "^asking for another download link, .* no longer takes it$"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        it("gives up once the second link isn't taken either", function()
            download()
            serverAnswered(410)
            helper.tick()
            serverAnswered(403)
            helper.runScheduled()

            assert.are.equal(2, #lookups)
            assert.are.same({ { ok = false, err = "HTTP error response (HTTP 403)" } }, results)
        end)

        -- The lookup may already have counted as a fast download, and tried every site.
        it("doesn't ask for a link again straight away when none could be had", function()
            require("fetchanna.api.sources").annas.findDownloadLink = function()
                table.insert(lookups, {})
                return nil, "Anna's Archive took too long", false
            end
            download()
            helper.runScheduled()
            assert.are.equal(1, #lookups)
            assert.are.same({ { ok = false, err = "Anna's Archive took too long" } }, results)
        end)
    end)

    describe("a book that won't fit on the device", function()
        it("stops downloading it as soon as its size is known, saying how much more room it needs", function()
            helper.stubs.util.diskUsage = function()
                return { total = 8 * MB, used = 7 * MB, available = MB }
            end
            remote_size = 3 * MB
            download()
            curlWrote(MB / 2)
            helper.tick()

            assert.are.same({ 1000 }, killed)
            assert.are.same({
                { ok = false, err = "there isn't room for the book on the device: 2.5 MB more is needed" },
            }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.are.same({}, Downloader:getActiveDownloads())
        end)

        it("downloads it where it fits, or the room left can't be told", function()
            helper.stubs.util.diskUsage = function()
                return { total = 8 * MB, used = 4 * MB, available = 4 * MB }
            end
            download()
            curlWrote(MB / 2)
            helper.tick()
            assert.are.same({}, killed)

            assert.is_nil(Downloader.lackOfRoom(filepath, MB))
            assert.are.equal(2 * MB, Downloader.lackOfRoom(filepath, 5 * MB))
            helper.stubs.util.diskUsage = function()
                return { total = nil, used = nil, available = nil }
            end
            assert.is_nil(Downloader.lackOfRoom(filepath, 5 * MB))
            helper.stubs.util.diskUsage = function()
                error("df failed")
            end
            assert.is_nil(Downloader.lackOfRoom(filepath, 5 * MB))
        end)
    end)

    -- Treated as the site's failure, this would discard what had arrived and ask for another link, which can count as
    -- another fast download.
    describe("when Wi-Fi goes off, or the device goes to sleep", function()
        local network

        before_each(function()
            network = require("ui/network/manager")
            remote_etag = '"v1"'
            download()
            curlWrote(MB / 2)
            helper.tick()
        end)

        local function progressText()
            return progress().status_text
        end

        it("waits for Wi-Fi to come back, then carries on from what had arrived with the same link", function()
            network.connected = false
            curlWrote(MB / 2, 6)
            helper.tick()
            assert.are.same({}, results)
            assert.are.equal("Waiting for Wi-Fi...", progressText())
            assert.are.equal(MB / 2, #helper.readFile(filepath .. ".part"))
            assert.are.same({}, killed)
            -- Still waiting.
            helper.tick()
            assert.are.equal(1, #spawned)

            -- Found by checking, as KOReader doesn't announce it on every device.
            network.connected = true
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.are.equal(spawned[1].url, spawned[2].url)
            assert.is_true(spawned[2].resume)
            -- Resumed only if the file is still the one that had arrived partway (If-Range).
            assert.are.equal('"v1"', spawned[2].if_range)
            assert.are.equal(MB / 2, #helper.readFile(filepath .. ".part"))
            assert.are.equal("Waiting for Test Library...", progressText())

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(MB, #helper.readFile(filepath))
        end)

        it("stops curl as soon as KOReader says Wi-Fi went off, and starts it again once it says it's back", function()
            Downloader:onNetworkDisconnected()
            assert.are.same({ 1000 }, killed)
            assert.are.equal("Waiting for Wi-Fi...", progressText())
            helper.tick()
            assert.are.same({}, results)

            Downloader:onNetworkConnected()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].resume)
        end)

        it("stops curl while the device sleeps, carrying on once it's awake", function()
            Downloader:onSuspend()
            assert.are.same({ 1000 }, killed)
            assert.is_true(helper.exists(filepath .. ".part"))
            -- Not while it's asleep, whatever it says about Wi-Fi.
            Downloader:onNetworkConnected()
            helper.tick()
            assert.are.equal(1, #spawned)

            Downloader:onResume()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].resume)
        end)

        it("waits once the device is awake for Wi-Fi to reconnect", function()
            Downloader:onSuspend()
            network.connected = false
            Downloader:onResume()
            helper.tick()
            assert.are.equal(1, #spawned)

            network.connected = true
            Downloader:onNetworkConnected()
            assert.are.equal(2, #spawned)
        end)

        -- Without a validator, what arrived can't be shown to be part of the same file.
        it("starts again from the beginning where the server didn't say what shows the file is the same", function()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 200\r\ncontent-length: " .. MB .. "\r\n\r\n")
            Downloader:onNetworkDisconnected()
            Downloader:onNetworkConnected()

            assert.are.equal(2, #spawned)
            assert.is_nil(spawned[2].if_range)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_truthy(helper.logged("info", "^starting it again from the beginning"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        it("can be cancelled while it waits", function()
            Downloader:onNetworkDisconnected()
            progress().cancel_button.callback()
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
        end)

        it("fails when curl can't be started again", function()
            Downloader:onNetworkDisconnected()
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end
            Downloader:onNetworkConnected()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.are.same({}, Downloader:getActiveDownloads())
        end)
    end)

    -- Going to sleep turns Wi-Fi off, which would stop the download.
    describe("keeping the device awake", function()
        local PluginShare

        before_each(function()
            PluginShare = require("pluginshare")
        end)

        it("while a book downloads, letting it sleep again once it has", function()
            download()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.is_true(PluginShare.pause_auto_suspend)
            assert.are.same({ "lipc-set-prop com.lab126.powerd preventScreenSaver 1" }, helper.state.lipc)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(0, helper.state.standby_prevented)
            assert.is_nil(PluginShare.pause_auto_suspend)
            assert.are.equal("lipc-set-prop com.lab126.powerd preventScreenSaver 0", helper.state.lipc[2])
        end)

        it("until every book has downloaded", function()
            download()
            local first = book
            book = {
                source = "test",
                id = fixtures.DUNE.md5:gsub("^.", "f"),
                title = "Dune Messiah",
                file_type = "epub",
            }
            hasBook(mirrors[1])
            filepath = data_dir .. "/Dune Messiah.epub"
            download()
            assert.are.equal(2, #spawned)
            assert.are.equal(1, helper.state.standby_prevented)
            assert.are.equal(1, #helper.state.lipc)

            curlWrote(MB, 0)
            helper.tick()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.is_not_nil(Downloader.active_downloads[first.id])
        end)

        it("putting auto-suspend back as it was, unless something else has changed it since", function()
            PluginShare.pause_auto_suspend = false
            download()
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.is_false(PluginShare.pause_auto_suspend)

            -- For example AutoTurn, turned off meanwhile.
            PluginShare.pause_auto_suspend = nil
            download()
            PluginShare.pause_auto_suspend = false
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.is_false(PluginShare.pause_auto_suspend)
        end)

        it("leaving a Kindle's screensaver to Keep alive, when that's keeping it awake", function()
            PluginShare.keepalive = true
            download()
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({}, helper.state.lipc)
        end)

        it("only holding off a Kindle's own screensaver on a Kindle", function()
            helper.stubs.device.kindle = false
            download()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.are.same({}, helper.state.lipc)
        end)

        it("letting it sleep again however downloads end", function()
            -- No link.
            web.pages[adsUrl(mirrors[1])] = "<html>nothing</html>"
            download()
            assert.are.equal(0, helper.state.standby_prevented)

            -- Cancelled.
            hasBook(mirrors[1])
            download()
            progress().cancel_button.callback()
            helper.runScheduled()
            assert.are.equal(0, helper.state.standby_prevented)

            -- All cancelled at once, as when KOReader closes.
            download()
            Downloader:cancelAllDownloads()
            assert.are.equal(0, helper.state.standby_prevented)
            assert.is_nil(PluginShare.pause_auto_suspend)
        end)
    end)

    describe("active downloads", function()
        it("lists downloads in progress", function()
            download()

            local downloads = Downloader:getActiveDownloads()
            assert.are.equal(1, #downloads)
            assert.are.equal(book.id, downloads[1].id)
            assert.are.equal("Dune", downloads[1].title)
            assert.are.equal(filepath, downloads[1].filepath)
            assert.are.equal(progress(), downloads[1].widget)
        end)

        -- Even once the clock is put back, as when an e-reader's battery runs flat.
        it("are listed in the order they were started", function()
            helper.state.time = 3000
            for i, title in ipairs({ "Zebra", "Apple" }) do
                Downloader:track("other" .. i, {
                    book = { id = "other" .. i, title = title },
                    progress_widget = {},
                })
                helper.state.time = helper.state.time - 1000
            end
            download()

            local titles = {}
            for _, active_download in ipairs(Downloader:getActiveDownloads()) do
                table.insert(titles, active_download.title)
            end
            assert.are.same({ "Zebra", "Apple", "Dune" }, titles)
        end)

        -- For example from the Downloads entry in FetchAnna's menu.
        it("can have their progress shown again once hidden", function()
            download()
            local widget = progress()
            widget.hide_button.callback()

            assert.is_true(Downloader:showDownload(book.id))
            assert.is_true(widget.is_visible)
            assert.are.equal(widget.container, helper.lastShown())

            -- Nothing happens when it's showing already.
            local shown = #helper.state.shown
            assert.is_true(Downloader:showDownload(book.id))
            assert.are.equal(shown, #helper.state.shown)
        end)

        it("can't have their progress shown once they're over", function()
            assert.is_false(Downloader:showDownload(book.id))
        end)

        it("can all be cancelled at once", function()
            download()
            local widget = progress()
            curlWrote(MB / 2)

            Downloader:cancelAllDownloads()
            assert.is_true(widget.cancelled)
            assert.are.same({ spawned[1].pid }, killed)
            assert.is_true(helper.wasClosed(widget.container))
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_false(helper.exists(spawned[1].headers_file))
            assert.are.same({}, Downloader:getActiveDownloads())

            helper.runScheduled()
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
        end)
    end)
end)
