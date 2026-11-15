local helper = require("helper")
local fixtures = require("fixtures")

describe("DownloadPrompt", function()
    local data_dir, book, downloads, DownloadPrompt

    local function newPrompt()
        return DownloadPrompt.new(book, "/mnt/us/documents/Dune.epub", function(filepath)
            table.insert(downloads, filepath)
        end)
    end

    local function cacheCover()
        fixtures.cacheCover(helper, book.id)
    end

    -- Returns the book's details, from the group beside the cover, as label and value pairs.
    local function details(prompt)
        local rows = {}
        for _, row in ipairs(prompt.details_group) do
            if row[1] and row[3] then
                table.insert(rows, { row[1].text, row[3].text })
            end
        end
        return rows
    end

    -- Taps one of the buttons along the bottom.
    local function tapButton(prompt, id)
        for _, button in ipairs(prompt.button_table.buttons[1]) do
            if button.id == id then
                return button.callback()
            end
        end
        error("no button " .. id)
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        book = {
            id = fixtures.DUNE.md5,
            display_title = "Dune",
            authors = "Frank Herbert",
            year = "1990",
            language = "English [en]",
            book_type = "Book (fiction)",
            file_type = "epub",
            file_size = "1.2MB",
        }
        downloads = {}
        DownloadPrompt = require("fetchanna.ui.downloadprompt")
    end)

    after_each(helper.cleanup)

    it("shows the book's details and where it will be saved", function()
        local prompt = newPrompt()

        assert.are.equal("Dune", prompt.title.text)
        assert.are.equal("Frank Herbert", prompt.author.text)
        -- The folder, which can be tapped to change it, and the file name.
        assert.are.equal("/mnt/us/documents", prompt.path_widget.text)
        assert.are.equal("Dune.epub", prompt.filename_widget.text)
        assert.are.same({
            { "Format", "EPUB · 1.2MB" },
            { "Language", "English [en]" },
            { "Year", "1990" },
            { "Type", "Book (fiction)" },
        }, details(prompt))
    end)

    -- In greys dark enough to read on e-ink (KindleFetch #3).
    it("shows the title and details in black, and the author and labels in grey", function()
        local prompt = newPrompt()
        assert.are.equal("gray 4", prompt.author.fgcolor)
        assert.are.equal("gray 6", prompt.details_group[1][1].fgcolor)
        assert.are.equal("black", prompt.details_group[1][3].fgcolor)
        assert.is_true(prompt.title.bold)
    end)

    -- So the prompt fits on the screen whatever the book is called.
    it("shows at most 4 lines of a long title, and 2 of a long list of authors", function()
        local prompt = newPrompt()
        assert.is_nil(prompt.title.height)
        assert.is_nil(prompt.author.height)

        book.display_title = string.rep("A very long title ", 20)
        book.authors = string.rep("Author, Another; ", 20)
        prompt = newPrompt()
        assert.are.equal(string.rep("A very long title ", 20), prompt.title.text)
        assert.are.equal(4 * 20, prompt.title.height)
        assert.is_true(prompt.title.height_overflow_show_ellipsis)
        assert.are.equal(2 * 20, prompt.author.height)
        assert.is_true(prompt.author.height_overflow_show_ellipsis)
    end)

    it("leaves out missing details", function()
        book.year = nil
        book.file_size = nil
        local prompt = newPrompt()
        assert.are.same(
            { { "Format", "EPUB" }, { "Language", "English [en]" }, { "Type", "Book (fiction)" } },
            details(prompt)
        )
    end)

    -- Each download from there uses one of the day's fast downloads.
    it("says how many fast downloads the account has left, where the site counts them", function()
        book.source = "annas"
        local Sources = require("fetchanna.api.sources")
        Sources.annas.allowance = function()
            return "20 of 25 a day left"
        end
        assert.are.same({ "Fast downloads", "20 of 25 a day left" }, details(newPrompt())[5])

        -- Not shown while it isn't known.
        Sources.annas.allowance = function()
            return nil
        end
        assert.are.equal(4, #details(newPrompt()))
        book.source = "libgen"
        assert.are.equal(4, #details(newPrompt()))
    end)

    it("shows and closes", function()
        local prompt = newPrompt()
        prompt:show()
        assert.are.equal(prompt.outer_container, helper.lastShown())

        prompt:close()
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    -- As KOReader's own dialogs do, not flashing the whole screen.
    it("only refreshes the part of the screen it takes up when shown and closed", function()
        local prompt = newPrompt()
        prompt.frame.dimen = { x = 50, y = 200, w = 500, h = 400 }

        prompt:show()
        assert.are.same({ "ui", prompt.frame.dimen }, helper.state.refreshes[#helper.state.refreshes])

        helper.state.refreshes = {}
        prompt:close()
        assert.are.same({ { "ui", prompt.frame.dimen } }, helper.state.refreshes)
    end)

    it("downloads to the chosen path when confirmed", function()
        local prompt = newPrompt()
        prompt:show()
        tapButton(prompt, "download")

        assert.are.same({ "/mnt/us/documents/Dune.epub" }, downloads)
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("closes without downloading when cancelled", function()
        local prompt = newPrompt()
        prompt:show()
        tapButton(prompt, "cancel")

        assert.are.same({}, downloads)
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("lets the download folder be changed", function()
        local books = helper.tmpdir("books")
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm(books)

        assert.are.equal(books .. "/Dune.epub", prompt.filepath)
        assert.are.equal(books, prompt.path_widget.text)
        assert.are.equal("Dune.epub", prompt.filename_widget.text)

        tapButton(prompt, "download")
        assert.are.same({ books .. "/Dune.epub" }, downloads)
    end)

    -- FAT forbids some characters that the name kept for the folder before could have.
    it("names the book safely for the folder chosen", function()
        local folders = {}
        require("util").getSafeFilename = function(name, folder)
            table.insert(folders, folder)
            return (name:gsub(":", "_"))
        end
        book.title = "Dune: Messiah"
        local fat = helper.tmpdir("fat")
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm(fat)

        assert.are.same({ fat }, folders)
        assert.are.equal(fat .. "/Dune_ Messiah.epub", prompt.filepath)
    end)

    -- Otherwise it's only found out after the link lookup, once the download starts.
    it("keeps the folder it was when the one chosen can't be written to", function()
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm("/proc")

        assert.are.equal("/mnt/us/documents/Dune.epub", prompt.filepath)
        assert.matches("^Books can't be downloaded to /proc: it can't be written to", helper.lastError())
    end)

    -- Sharing a button with the folder, the name would be cut off by a long one.
    it("shows the name the book is saved as on its own, however long the folder", function()
        local folder = "/mnt/us/documents/" .. string.rep("a folder with a long name/", 6)
        local prompt = DownloadPrompt.new(book, folder .. "Dune Messiah.epub", function() end)
        assert.are.equal("Dune Messiah.epub", prompt.filename_widget.text)
        assert.are.equal(folder:gsub("/$", ""), prompt.path_widget.text)

        prompt = DownloadPrompt.new(book, "/Dune.epub", function() end)
        assert.are.equal("/", prompt.path_widget.text)
        assert.are.equal("Dune.epub", prompt.filename_widget.text)
    end)

    it("lets the download folder be changed more than once", function()
        local comics = helper.tmpdir("comics")
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm(helper.tmpdir("books"))
        prompt.path_widget.callback()
        helper.state.dir_choosers[2].onConfirm(comics)

        assert.are.equal(comics .. "/Dune.epub", prompt.filepath)
    end)

    it("closes when tapping outside of it", function()
        local prompt = newPrompt()
        prompt:show()

        local inside = helper.stubs.geometry:new { outside = false }
        assert.is_false(prompt.outer_container:onTapOutside(nil, { pos = inside }))
        assert.is_false(helper.wasClosed(prompt.outer_container))

        local outside = helper.stubs.geometry:new { outside = true }
        assert.is_true(prompt.outer_container:onTapOutside(nil, { pos = outside }))
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    describe("cover", function()
        it("is left out when the book doesn't have one, giving its details the whole width", function()
            local prompt = newPrompt()
            assert.is_nil(prompt.cover)
            assert.are.equal(380, prompt.title.width)

            prompt:showFullscreenCover()
            assert.is_false(prompt.fullscreen_cover_shown)
        end)

        it("is a placeholder while it downloads", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()

            assert.is_true(prompt.cover[1].is_cover_placeholder)
            assert.is_nil(prompt.cover_container)
            assert.are.equal(380 - 192 - 10, prompt.title.width)
        end)

        it("is shown once it has downloaded", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()
            prompt:show()

            cacheCover()
            prompt.outer_container:onFetchAnnaCoversDownloaded()
            assert.are.equal(prompt.cover_container, prompt.cover)
            assert.are.equal(prompt.cover, prompt.header[1])
        end)

        -- They arrive several times a second while the results behind it load theirs.
        it("isn't redrawn when other books' covers arrive", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()
            prompt:show()
            helper.state.refreshes = {}

            fixtures.cacheCover(helper, "another-book")
            prompt.outer_container:onFetchAnnaCoversDownloaded()
            assert.are.equal(0, #helper.state.refreshes)

            cacheCover()
            prompt.outer_container:onFetchAnnaCoversDownloaded()
            assert.are.equal(1, #helper.state.refreshes)
            assert.are.equal(prompt.cover_container, prompt.cover)
        end)

        it("is taken away when it couldn't be downloaded", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()
            require("fetchanna.util.curlutil").canFetch = function()
                return true
            end
            require("fetchanna.util.curlutil").downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end
            require("fetchanna.cache.covercache"):downloadMultiple({ book }, 1)

            prompt.outer_container:onFetchAnnaCoversDownloaded()
            assert.is_nil(prompt.cover)
            assert.are.equal(380, prompt.title.width)
        end)

        it("is shown when it has been downloaded", function()
            cacheCover()
            local prompt = newPrompt()
            assert.are.equal(prompt.cover_container, prompt.cover)
        end)

        it("opens fullscreen when tapped, and closes when tapped again", function()
            cacheCover()
            local prompt = newPrompt()

            prompt.cover_container:onTapCover()
            assert.is_true(prompt.fullscreen_cover_shown)
            assert.are.equal(prompt.fullscreen_container, helper.lastShown())

            prompt.cover_container:onTapCover()
            assert.is_false(prompt.fullscreen_cover_shown)
            prompt:toggleFullscreenCover()
            assert.is_true(prompt.fullscreen_cover_shown)

            prompt.fullscreen_container:onTapClose()
            assert.is_false(prompt.fullscreen_cover_shown)
            assert.is_true(helper.wasClosed(prompt.fullscreen_container))

            local closed = #helper.state.closed
            prompt:closeFullscreenCover()
            assert.are.equal(closed, #helper.state.closed)
        end)

        describe("full-size", function()
            local CoverCache, runs

            -- Returns the notices shown saying the full-size cover is loading.
            local function loadingNotices()
                local notices = {}
                for _, widget in ipairs(helper.state.shown) do
                    if widget.is_notification and widget.text == "Loading full-size cover..." then
                        table.insert(notices, widget)
                    end
                end
                return notices
            end

            before_each(function()
                CoverCache = require("fetchanna.cache.covercache")
                runs = {}
                local CurlUtil = require("fetchanna.util.curlutil")
                CurlUtil.canFetch = function()
                    return true
                end
                CurlUtil.downloadMultiple = function(urls, paths)
                    local run = {
                        urls = urls,
                        paths = paths,
                        exit_file = CurlUtil.createExitFile(),
                    }
                    table.insert(runs, run)
                    return 4000, run.exit_file, data_dir .. "/curl_config.txt"
                end
                CurlUtil.isPidRunning = function()
                    return true
                end
                book.image_url = "https://libgen.example/fictioncovers/1000/dune_small.jpg"
                cacheCover()
            end)

            it("is only downloaded once the cover is enlarged, showing the thumbnail until then", function()
                local prompt = newPrompt()
                assert.are.equal(0, #runs)

                prompt.cover_container:onTapCover()
                assert.are.same({ "https://libgen.example/fictioncovers/1000/dune.jpg" }, runs[1].urls)
                assert.are.equal(CoverCache:get(book.id), prompt.fullscreen_file)
                -- It says so until it arrives, as the thumbnail shows meanwhile.
                local notice = loadingNotices()[1]
                assert.is_false(notice.timeout)
                assert.is_false(helper.wasClosed(notice))
            end)

            it("replaces the thumbnail once it arrives", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                local thumbnail = prompt.fullscreen_container

                fixtures.cacheCover(helper, book.id .. "_full")
                prompt.outer_container:onFetchAnnaCoversDownloaded()
                assert.is_true(helper.wasClosed(thumbnail))
                assert.is_true(prompt.fullscreen_cover_shown)
                assert.are.equal(prompt.fullscreen_container, helper.lastShown())
                assert.are.equal(CoverCache:getFullSize(book), prompt.fullscreen_file)
                assert.are.equal(CoverCache:getFullSize(book), prompt.cover_container[1][1].file)
                assert.are.equal(1, #runs)
                -- It no longer says it's loading.
                assert.is_true(helper.wasClosed(loadingNotices()[1]))

                -- It says nothing once the cover is there.
                prompt:closeFullscreenCover()
                prompt.cover_container:onTapCover()
                assert.are.equal(1, #loadingNotices())
            end)

            it("keeps saying it's loading while other covers download", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                local thumbnail = prompt.fullscreen_container

                prompt.outer_container:onFetchAnnaCoversDownloaded()
                assert.is_false(helper.wasClosed(thumbnail))
                assert.are.equal(CoverCache:get(book.id), prompt.fullscreen_file)
                assert.is_false(helper.wasClosed(loadingNotices()[1]))
            end)

            it("leaves the thumbnail showing when it couldn't be downloaded, no longer saying it's loading", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()

                helper.writeFile(runs[1].exit_file, "22")
                helper.tick()
                prompt.outer_container:onFetchAnnaCoversDownloaded()
                assert.is_true(prompt.fullscreen_cover_shown)
                assert.are.equal(CoverCache:get(book.id), prompt.fullscreen_file)
                assert.is_true(helper.wasClosed(loadingNotices()[1]))
            end)

            -- Nothing would say it had stopped, so the notice would stay for good.
            it("doesn't say it's loading when it couldn't even be started", function()
                require("fetchanna.util.curlutil").downloadMultiple = function()
                    return nil, nil, nil, "could not start curl"
                end
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                assert.is_true(prompt.fullscreen_cover_shown)
                assert.are.same({}, loadingNotices())
            end)

            it("stops saying it's loading when the cover is closed", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                prompt:closeFullscreenCover()
                assert.is_true(helper.wasClosed(loadingNotices()[1]))
            end)
        end)

        it("closes along with the prompt", function()
            cacheCover()
            local prompt = newPrompt()
            prompt:toggleFullscreenCover()

            prompt:close()
            assert.is_true(helper.wasClosed(prompt.fullscreen_container))
            assert.is_true(helper.wasClosed(prompt.outer_container))
        end)
    end)
end)
