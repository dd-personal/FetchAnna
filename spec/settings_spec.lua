local helper = require("helper")

describe("FetchAnnaSettings", function()
    local data_dir, Settings

    local function pluginSettings()
        return helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"]
    end

    local function setReaderHomeDir(path)
        helper.state.reader_settings.home_dir = path
    end

    -- Counts reads and writes of the settings file.
    local function countFileAccess()
        local count = {
            opens = 0,
            flushes = 0,
        }
        local open = helper.stubs.luasettings.open
        helper.stubs.luasettings.open = function(...)
            count.opens = count.opens + 1
            local file = open(...)
            local flush = file.flush
            function file:flush()
                count.flushes = count.flushes + 1
                return flush(self)
            end
            return file
        end
        return count
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        -- The host machine mustn't decide whether the Kindle documents folder exists.
        helper.state.fs["/mnt/us/documents"] = false
        Settings = require("fetchanna.settings.settings")
    end)

    after_each(helper.cleanup)

    -- For example edited by hand. Reading them mustn't fail as KOReader starts.
    it("ignores settings saved as something they can't be", function()
        helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
            show_book_covers = "yes",
            search_cache_expiry_days = {},
            preferred_languages = "en",
            preferred_file_types = { "epub", 7, { "pdf" } },
            recent_searches = { "dune", false, "emma" },
            last_update_check = "yesterday",
        }
        assert.is_true(Settings:getShowBookCovers())
        assert.are.equal(14, Settings:getSearchCacheExpiryDays())
        assert.are.same({ "en" }, Settings:getPreferredLanguages())
        assert.are.same({ "epub" }, Settings:getPreferredFileTypes())
        assert.are.same({ "dune", "emma" }, Settings:getRecentSearches())
        assert.is_nil(Settings:getLastUpdateCheck())
        assert.is_truthy(
            helper.logged("warn", "^ignoring show_book_covers as it's saved as a string rather than a boolean")
        )
    end)

    -- LuaSettings doesn't say, so an unsaved setting would be reported as saved.
    it("says when a setting couldn't be saved, as when the storage is full", function()
        assert.is_true(Settings:setShowBookCovers(false))
        helper.state.settings_unwritable = true
        local ok, err = Settings:setShowBookCovers(true)
        assert.is_nil(ok)
        assert.are.equal("FetchAnna's settings couldn't be saved", err)
        assert.is_truthy(helper.logged("warn", "^could not save show_book_covers"))
    end)

    describe("getDownloadDir", function()
        it("uses the saved download folder", function()
            helper.state.fs["/mnt/us/books"] = "directory"
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                download_dir = "/mnt/us/books",
            }
            assert.are.equal("/mnt/us/books", Settings:getDownloadDir())
        end)

        -- For example deleted, or on an SD card taken out. Downloading there anyway would fail after the link lookup.
        it("uses the default while the saved download folder can't be found, keeping it for when it's back", function()
            local home = helper.tmpdir("home")
            setReaderHomeDir(home)
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                download_dir = "/mnt/sd/books",
            }
            assert.are.equal(home, Settings:getDownloadDir())
            assert.are.equal("/mnt/sd/books", pluginSettings().download_dir)
            assert.is_truthy(helper.logged("warn", "^the download folder /mnt/sd/books can't be found"))

            helper.state.fs["/mnt/sd/books"] = "directory"
            assert.are.equal("/mnt/sd/books", Settings:getDownloadDir())
        end)

        it("defaults to koreader's home folder", function()
            local home = helper.tmpdir("home")
            setReaderHomeDir(home)
            assert.are.equal(home, Settings:getDownloadDir())
        end)

        it("uses the kindle documents folder when no home folder is set", function()
            helper.state.fs["/mnt/us/documents"] = "directory"
            assert.are.equal("/mnt/us/documents", Settings:getDownloadDir())
        end)

        it("falls back to the device home dir when the home folder is missing", function()
            setReaderHomeDir("/storage/emulated/0/Books")
            helper.stubs.device.home_dir = "/storage/emulated/0"
            assert.are.equal("/storage/emulated/0", Settings:getDownloadDir())
        end)

        it("falls back to the koreader dir on devices without a home dir", function()
            helper.stubs.device.home_dir = nil
            assert.are.equal(helper.ROOT, Settings:getDownloadDir())
        end)
    end)

    describe("setDownloadDir", function()
        it("saves folders that exist", function()
            local books = helper.tmpdir("books")
            assert.is_true(Settings:setDownloadDir(books))
            assert.are.equal(books, Settings:getDownloadDir())
        end)

        it("refuses folders that do not exist", function()
            local ok, err = Settings:setDownloadDir(data_dir .. "/missing")
            assert.is_nil(ok)
            assert.are.equal("it doesn't exist", err)
        end)

        it("refuses folders books can't be saved in", function()
            local ok, err = Settings:setDownloadDir("/proc")
            assert.is_nil(ok)
            assert.matches("^it can't be written to", err)
        end)
    end)

    describe("preferences", function()
        it("are saved", function()
            Settings:setShowBookCovers(false)
            Settings:setCheckForUpdates(false)
            Settings:setPreferredLanguages({ "fr", "de" })
            Settings:setPreferredFileTypes({ "mobi" })

            assert.is_false(Settings:getShowBookCovers())
            assert.is_false(Settings:getCheckForUpdates())
            assert.are.same({ "fr", "de" }, Settings:getPreferredLanguages())
            assert.are.same({ "mobi" }, Settings:getPreferredFileTypes())
        end)

        -- Only file types KOReader can open.
        it("offer every language and file type there is to choose from", function()
            assert.are.same({ text = "English", code = "en" }, Settings:getAvailableLanguages()[1])
            assert.are.equal(100, #Settings:getAvailableLanguages())
            assert.are.same({ "cbr", "cbz" }, Settings:getComicFileTypes())
            assert.are.same({ "epub", "mobi", "azw", "fb2", "prc" }, Settings:getEbookFileTypes())
            assert.are.same({ "pdf", "txt", "rtf", "doc", "docx", "odt", "djvu" }, Settings:getDocumentFileTypes())
            assert.are.same({ "jpg", "tif", "pdb" }, Settings:getImageFileTypes())
            assert.are.same({ "chm", "htm", "html", "htmlz" }, Settings:getWebFileTypes())
        end)
    end)

    describe("cache expiry", function()
        it("keeps searches for two weeks by default", function()
            assert.are.equal(14, Settings:getSearchCacheExpiryDays())
        end)

        it("can be changed", function()
            assert.are.same({ 1, 3, 7, 14, 30 }, Settings:getAvailableCacheExpiryDays())
            Settings:setSearchCacheExpiryDays(30)
            assert.are.equal(30, Settings:getSearchCacheExpiryDays())
        end)
    end)

    describe("recent searches", function()
        it("are none to begin with", function()
            assert.are.same({}, Settings:getRecentSearches())
        end)

        it("are remembered most recent first, once each whatever their capitals, up to 10", function()
            Settings:addRecentSearch("dune")
            Settings:addRecentSearch("emma")
            Settings:addRecentSearch("Dune")
            assert.are.same({ "Dune", "emma" }, Settings:getRecentSearches())
            assert.are.same({ "Dune", "emma" }, pluginSettings().recent_searches)

            for i = 1, 12 do
                Settings:addRecentSearch("search " .. i)
            end
            local searches = Settings:getRecentSearches()
            assert.are.equal(10, #searches)
            assert.are.equal("search 12", searches[1])
            assert.are.equal("search 3", searches[10])
        end)

        it("can be forgotten", function()
            Settings:addRecentSearch("dune")
            Settings:clearRecentSearches()
            assert.are.same({}, Settings:getRecentSearches())
        end)
    end)

    it("remembers the plugin version it last ran", function()
        assert.is_nil(Settings:getLastVersion())
        Settings:setLastVersion("0.4")
        assert.are.equal("0.4", Settings:getLastVersion())
    end)

    it("remembers when updates were last checked for, and the updates that were turned down", function()
        assert.is_nil(Settings:getLastUpdateCheck())
        assert.is_nil(Settings:getSkippedVersion())
        assert.is_nil(Settings:getCurlUpdateDeclined())

        Settings:setLastUpdateCheck(1234567)
        Settings:setSkippedVersion("0.5")
        Settings:setCurlUpdateDeclined("8.21.0")

        assert.are.equal(1234567, Settings:getLastUpdateCheck())
        assert.are.equal("0.5", Settings:getSkippedVersion())
        assert.are.equal("8.21.0", Settings:getCurlUpdateDeclined())

        -- Cleared once curl has been updated.
        Settings:setCurlUpdateDeclined(nil)
        assert.is_nil(Settings:getCurlUpdateDeclined())
        -- As older versions saved it.
        helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"].curl_update_declined = true
        package.loaded["fetchanna.settings.settings"] = nil
        assert.is_true(require("fetchanna.settings.settings"):getCurlUpdateDeclined())
    end)

    describe("preferred file types", function()
        it("leave out ones KOReader can't open, which can no longer be chosen", function()
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                preferred_file_types = { "epub", "azw3", "kfx", "pdf" },
            }
            assert.are.same({ "epub", "pdf" }, Settings:getPreferredFileTypes())
        end)

        it("fall back to the defaults when none of those chosen are left", function()
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                preferred_file_types = { "azw3", "lit" },
            }
            assert.are.same({ "epub" }, Settings:getPreferredFileTypes())
        end)

        -- An older KOReader may not open everything on the list.
        it("are only those the KOReader installed can open, as its document registry says", function()
            helper.stub("document/documentregistry", {
                hasProvider = function(_, file)
                    if file == "book.chm" then
                        error("no such provider")
                    end
                    return file ~= "book.htmlz"
                end,
            })
            assert.is_false(Settings:isOpenableFileType("htmlz"))
            assert.is_true(Settings:isOpenableFileType("EPUB"))
            -- Where it can't say, the list stands.
            assert.is_true(Settings:isOpenableFileType("chm"))
            assert.are.same({ "chm", "htm", "html" }, Settings:getWebFileTypes())
            Settings:setPreferredFileTypes({ "epub", "htmlz", "azw3" })
            assert.are.same({ "epub" }, Settings:getPreferredFileTypes())
        end)

        it("can all be turned off", function()
            Settings:setPreferredFileTypes({})
            assert.are.same({}, Settings:getPreferredFileTypes())
        end)
    end)

    describe("load", function()
        it("saves a usable download folder on devices without a home dir", function()
            helper.stubs.device.home_dir = nil
            Settings:load()
            assert.are.equal(helper.ROOT, pluginSettings().download_dir)
        end)

        -- Books in English, as EPUB.
        it("fills in default preferences", function()
            Settings:load()
            assert.are.same({ "en" }, pluginSettings().preferred_languages)
            assert.are.same({ "epub" }, pluginSettings().preferred_file_types)
            assert.is_true(pluginSettings().show_book_covers)
            assert.is_true(pluginSettings().check_for_updates)
        end)

        -- KindleFetch's default, saved when its settings were first filled in. It's taken as a default, not a choice.
        describe("with every file type chosen", function()
            local every = {
                "epub",
                "mobi",
                "azw",
                "fb2",
                "prc",
                "cbr",
                "cbz",
                "pdf",
                "txt",
                "rtf",
                "doc",
                "docx",
                "odt",
                "djvu",
                "jpg",
                "tif",
                "pdb",
                "chm",
                "htm",
                "html",
                "htmlz",
            }

            it("chooses epub only instead, once", function()
                local shuffled = { "htmlz" }
                for i = 1, #every - 1 do
                    shuffled[i + 1] = every[i]
                end
                helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                    preferred_file_types = shuffled,
                }
                Settings:load()
                assert.are.same({ "epub" }, pluginSettings().preferred_file_types)
                assert.are.equal(2, pluginSettings().file_types_default)
                assert.is_truthy(helper.logged("info", "^choosing epub only"))

                -- Every one chosen after that is kept.
                Settings:setPreferredFileTypes(every)
                Settings:load()
                assert.are.same(every, pluginSettings().preferred_file_types)
            end)

            it("keeps file types that were chosen", function()
                helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                    preferred_file_types = { "epub", "pdf" },
                }
                Settings:load()
                assert.are.same({ "epub", "pdf" }, pluginSettings().preferred_file_types)
            end)
        end)

        -- It runs every time the file manager or a book is opened.
        it("only writes the settings file when something changed", function()
            local count = countFileAccess()

            Settings:load()
            assert.are.equal(1, count.flushes)

            Settings:load()
            Settings:load()
            assert.are.equal(1, count.flushes)
        end)

        it("writes the settings file again once a saved setting is out of date", function()
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                preferred_file_types = { "epub", "azw3" },
            }
            local count = countFileAccess()

            Settings:load()
            assert.are.equal(1, count.flushes)
            assert.are.same({ "epub" }, pluginSettings().preferred_file_types)
        end)

        it("leaves a download folder that has gone missing as it was saved", function()
            helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
                download_dir = data_dir .. "/missing",
            }
            Settings:load()
            assert.are.equal(data_dir .. "/missing", pluginSettings().download_dir)
        end)
    end)

    -- And again only to check that each change was saved.
    it("reads the settings file from storage once", function()
        local count = countFileAccess()

        Settings:getShowBookCovers()
        Settings:getPreferredLanguages()
        Settings:getDownloadDir()
        Settings:setShowBookCovers(false)
        Settings:getShowBookCovers()

        assert.are.equal(2, count.opens)
        assert.are.equal(1, count.flushes)
    end)
end)
