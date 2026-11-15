local helper = require("helper")

describe("SettingsPage", function()
    local data_dir, Settings, SettingsPage

    -- Returns the menu on top.
    local function lastMenu()
        for i = #helper.state.shown, 1, -1 do
            local widget = helper.state.shown[i]
            if widget.item_table and not helper.wasClosed(widget) then
                return widget
            end
        end
    end

    local function itemTexts(menu)
        local texts = {}
        for _, item in ipairs(menu.item_table) do
            table.insert(texts, item.text)
        end
        return texts
    end

    -- Taps the menu item whose text contains text.
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

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"] = {
            download_dir = helper.abs(data_dir),
        }
        Settings = require("fetchanna.settings.settings")
        SettingsPage = require("fetchanna.settings.settingspage")
    end)

    after_each(helper.cleanup)

    -- The menu's own way to close must be kept, or a Kindle is stuck on it (see newMenu).
    it("opens Anna's Archive's sites, which close again, back to the settings as they are then", function()
        SettingsPage:showSettings()
        local settings = lastMenu()
        tap("Anna's Archive Sites")
        local sites = lastMenu()
        assert.are.equal("Anna's Archive Sites", sites.title)
        require("fetchanna.api.annasmirrors"):revoke("https://annas-archive.gl")

        sites:onClose()
        assert.is_true(helper.wasClosed(sites))
        assert.are.equal(settings, lastMenu())
        assert.are.equal("Anna's Archive Sites: 2 sent your key", settings.item_table[9].text)
    end)

    it("shows the current settings", function()
        SettingsPage:showSettings()

        assert.are.same({
            "Show Book Covers: ☑",
            "Download Folder: " .. SettingsPage.shortenFolder(helper.abs(data_dir)),
            -- By name, not the codes they're saved as.
            "Preferred Languages: English",
            "Preferred File Types: epub",
            "Check for Updates Automatically: ☑",
            "Keep Searches For: 14 days",
            "HTTP Proxy: Off",
            "Encrypted DNS: ☐",
            "Anna's Archive Sites: 3 sent your key",
            "Clear Cache",
        }, itemTexts(lastMenu()))
        assert.are.equal("FetchAnna Settings", lastMenu().title)
    end)

    -- Not a list too long to fit, or codes.
    it("names the file types chosen, when they aren't all", function()
        Settings:setPreferredFileTypes({ "pdf", "epub" })
        SettingsPage:showSettings()

        -- In the order they're listed in.
        assert.are.equal("Preferred File Types: epub, pdf", lastMenu().item_table[4].text)
    end)

    -- The end of a folder says the most about it, and the menu would cut it off.
    it("shows the end of a long download folder", function()
        assert.are.equal("/mnt/us/documents/books", SettingsPage.shortenFolder("/mnt/us/documents/books"))
        assert.are.equal(
            "…/e2e/kindle-paperwhite/books",
            SettingsPage.shortenFolder("/home/someone/Documents/dev/projects/FetchAnna/e2e/kindle-paperwhite/books")
        )
        local long_name = "/" .. string.rep("a very long folder name ", 3)
        assert.are.equal("…" .. long_name, SettingsPage.shortenFolder("/mnt/us/documents" .. long_name))
    end)

    -- Rounded corners aren't painted, so KOReader's menu would show through the settings' corners.
    it("fills the screen to its corners, as do the menus it opens", function()
        SettingsPage:showSettings()
        local settings = lastMenu()
        tap("Preferred Languages")
        local languages = lastMenu()

        assert.are_not.equal(settings, languages)
        for _, menu in ipairs({ settings, languages }) do
            assert.is_true(menu.covers_fullscreen)
            assert.is_false(menu.is_popout)
        end
    end)

    it("toggles book covers", function()
        SettingsPage:showSettings()
        tap("Show Book Covers")

        assert.is_false(Settings:getShowBookCovers())
        assert.are.equal("Show Book Covers: ☐", lastMenu().item_table[1].text)
        -- No notification as well: each one refreshes the screen twice.
        assert.are.equal(0, #helper.state.notifications)
    end)

    -- Reopening the menu for every change would flash the whole screen twice.
    it("shows a change in the menu that's open, on the page it's on", function()
        SettingsPage:showSettings()
        local menu = lastMenu()
        tap("Show Book Covers")
        tap("Check for Updates Automatically")

        assert.are.equal(1, #helper.state.shown)
        assert.is_false(helper.wasClosed(menu))
        assert.are.equal(-1, menu.switched_to_item)
        for _, refresh in ipairs(helper.state.refreshes) do
            assert.are_not.equal("full", refresh[1])
        end
    end)

    it("turns automatic update checks off and on", function()
        SettingsPage:showSettings()
        tap("Check for Updates Automatically")

        assert.is_false(Settings:getCheckForUpdates())
        assert.are.equal("Check for Updates Automatically: ☐", lastMenu().item_table[5].text)
        assert.are.equal(0, #helper.state.notifications)

        tap("Check for Updates Automatically")
        assert.is_true(Settings:getCheckForUpdates())
    end)

    describe("cache expiry", function()
        it("sets how long searches are kept", function()
            SettingsPage:showSettings()
            tap("Keep Searches For")
            assert.are.equal("Keep Searches For", lastMenu().title)
            assert.are.same(
                { "○ 1 day", "○ 3 days", "○ 7 days", "◉ 14 days", "○ 30 days" },
                itemTexts(lastMenu())
            )

            local choices = lastMenu()
            tap("30 days")
            assert.are.equal(30, Settings:getSearchCacheExpiryDays())
            assert.are.equal(0, #helper.state.notifications)
            -- Back in the settings, which were open underneath.
            assert.is_true(helper.wasClosed(choices))
            assert.are.equal("Keep Searches For: 30 days", lastMenu().item_table[6].text)
            assert.are.equal(2, #helper.state.shown)
        end)
    end)

    -- KOReader's proxy, which FetchAnna goes through for everything.
    describe("HTTP proxy", function()
        it("turns KOReader's on, saying which it is, without who it's logged into as", function()
            SettingsPage:showSettings()
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            assert.are.equal("http://", dialog.input)
            assert.is_true(dialog.keyboard_shown)
            assert.is_false(button(dialog, "Turn off").enabled)

            dialog.input_text = " http://reader:secret@proxy.example:8080 "
            button(dialog, "Turn on").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.equal("http://reader:secret@proxy.example:8080", require("socket.http").PROXY)
            assert.is_true(helper.state.reader_settings.http_proxy_enabled)
            assert.are.equal("HTTP Proxy: http://proxy.example:8080", lastMenu().item_table[7].text)
            for _, log in ipairs(helper.state.logs) do
                for i = 3, #log do
                    assert.is_nil(tostring(log[i]):find("secret", 1, true))
                end
            end
        end)

        it("turns it off, keeping its address for next time", function()
            require("ui/network/manager"):setHTTPProxy("http://proxy.example:8080")
            SettingsPage:showSettings()
            assert.are.equal("HTTP Proxy: http://proxy.example:8080", lastMenu().item_table[7].text)
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            assert.are.equal("http://proxy.example:8080", dialog.input)

            button(dialog, "Turn off").callback()
            assert.is_nil(require("socket.http").PROXY)
            assert.is_false(helper.state.reader_settings.http_proxy_enabled)
            assert.are.equal("http://proxy.example:8080", helper.state.reader_settings.http_proxy)
            assert.are.equal("HTTP Proxy: Off", lastMenu().item_table[7].text)
        end)

        it("only turns on what's an address", function()
            SettingsPage:showSettings()
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            dialog.input_text = "proxy.example:8080"
            button(dialog, "Turn on").callback()

            assert.is_false(helper.wasClosed(dialog))
            assert.is_nil(require("socket.http").PROXY)
            assert.are.equal("Enter the proxy's address, e.g. http://proxy.example:8080", helper.lastNotification())
        end)
    end)

    -- For where the network's own DNS blocks the sites (KindleFetch #55).
    describe("encrypted DNS", function()
        it("can't be turned on where curl can't look names up with it", function()
            SettingsPage:showSettings()
            assert.are.equal("Encrypted DNS: ☐", lastMenu().item_table[8].text)
            assert.is_false(lastMenu().item_table[8].enabled)
        end)

        it("turns on and off, where curl can", function()
            helper.stubCommand("curl --version", "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0\n")
            SettingsPage:showSettings()
            assert.is_true(lastMenu().item_table[8].enabled)

            tap("Encrypted DNS")
            assert.is_true(Settings:getEncryptedDns())
            assert.are.equal("Encrypted DNS: ☑", lastMenu().item_table[8].text)
            tap("Encrypted DNS")
            assert.is_false(Settings:getEncryptedDns())
        end)
    end)

    -- The setting would go back to what it was.
    it("says when a change couldn't be saved", function()
        SettingsPage:showSettings()
        helper.state.settings_unwritable = true
        tap("Show Book Covers")
        assert.are.equal("FetchAnna's settings couldn't be saved", helper.lastError())
    end)

    describe("download folder", function()
        it("can be changed", function()
            local books = helper.tmpdir("books")
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(books)

            assert.are.equal(books, Settings:getDownloadDir())
            assert.are.equal(0, #helper.state.notifications)
            assert.are.equal("Download Folder: " .. books, lastMenu().item_table[2].text)
        end)

        it("must exist", function()
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(data_dir .. "/missing")

            assert.are.equal(helper.abs(data_dir), Settings:getDownloadDir())
            assert.are.equal(
                "Books can't be downloaded to " .. data_dir .. "/missing: it doesn't exist",
                helper.lastError()
            )
        end)

        it("must be one books can be saved in", function()
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm("/proc")

            assert.matches("^Books can't be downloaded to /proc: it can't be written to", helper.lastError())
        end)
    end)

    describe("preferred languages", function()
        it("lists every language, with the preferred ones ticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")

            local texts = itemTexts(lastMenu())
            assert.are.equal(#Settings:getAvailableLanguages(), #texts)
            assert.are.equal("☑ English", texts[1])
            assert.are.equal("☐ Spanish", texts[2])
        end)

        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("Spanish")
            tap("English")
            tap("French")
            lastMenu().onClose()

            assert.are.same({ "es", "fr" }, Settings:getPreferredLanguages())
            assert.are.equal(0, #helper.state.notifications)
            assert.are.equal("Preferred Languages: Spanish, French", lastMenu().item_table[3].text)
        end)

        -- There are eight pages of languages. A tick mustn't go back to the first.
        it("are ticked in the menu that's open, on the page it's on", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("Welsh")
            tap("Welsh")
            tap("Zulu")

            assert.are.equal(languages, lastMenu())
            assert.are.equal(2, #helper.state.shown)
            assert.are.equal(-1, languages.switched_to_item)
            local ticked = {}
            for _, text in ipairs(itemTexts(languages)) do
                if text:find("☑", 1, true) then
                    table.insert(ticked, text)
                end
            end
            assert.are.same({ "☑ English", "☑ Zulu" }, ticked)
        end)

        it("stay as they were, with their menu still open, while none are ticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("English")
            languages.onClose()

            assert.is_false(helper.wasClosed(languages))
            tap("French")
            languages.onClose()
            assert.is_true(helper.wasClosed(languages))
            assert.are.same({ "fr" }, Settings:getPreferredLanguages())
        end)

        -- From the results, not the settings (see FetchAnna:changeChoices).
        it("can be chosen on their own, saying once chosen whether they've changed", function()
            local changes = {}
            local function onClosed(changed)
                table.insert(changes, changed)
            end
            SettingsPage:changeLanguages(onClosed)
            local languages = lastMenu()
            -- Filling the screen.
            assert.are.equal(600, languages.width)
            assert.are.equal(800, languages.height)
            languages.onClose()
            assert.are.same({ false }, changes)

            SettingsPage:changeLanguages(onClosed)
            tap("English")
            tap("French")
            lastMenu().onClose()
            assert.are.same({ false, true }, changes)
            assert.are.same({ "fr" }, Settings:getPreferredLanguages())

            -- Once there are some ticked.
            SettingsPage:changeLanguages(onClosed)
            tap("French")
            lastMenu().onClose()
            assert.are.same({ false, true }, changes)
        end)

        -- For example from the results, after the settings were opened and closed.
        it("leave the settings alone once they've been closed", function()
            SettingsPage:showSettings()
            local settings = lastMenu()
            helper.stubs.uimanager:close(settings)
            SettingsPage:changeLanguages()
            tap("French")
            lastMenu().onClose()

            assert.is_nil(settings.switched_to_item)
        end)

        -- The settings show what's chosen.
        it("are saved without saying anything", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("English")
            tap("French")
            lastMenu().onClose()

            assert.are.same({ "fr" }, Settings:getPreferredLanguages())
            for _, widget in ipairs(helper.state.shown) do
                assert.are_not.equal("notice-warning", widget.icon)
            end
        end)

        -- KOReader's Home key closes the menu, then sends Home again until what's on top changes, which it never would
        -- with the menu held open and nothing ticked.
        it("are left as they were when KOReader's Home key closes their menu with none ticked", function()
            local Menu = require("ui/widget/menu")
            Menu.onHome = function(self)
                self:onClose()
                return true
            end
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("English")
            languages:onHome()

            assert.is_true(helper.wasClosed(languages))
            assert.are.same({ "en" }, Settings:getPreferredLanguages())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("English")
            lastMenu().onClose()

            assert.are.same({ "en" }, Settings:getPreferredLanguages())
            assert.are.equal("Select at least one language", helper.lastNotification())
        end)
    end)

    -- For example for the books found, where what's ticked would hide all of them.
    describe("a list of choices to tick", function()
        local saves, closes, refuse

        local function tickSites()
            SettingsPage:tickSeveral(
                "Sites",
                { { text = "Z-Library", code = "zlib" }, { text = "Internet Archive", code = "archive" } },
                { "zlib", "archive" },
                function(codes)
                    table.insert(saves, codes)
                    if refuse then
                        return false
                    end
                end,
                "Tick at least one",
                function(changed)
                    table.insert(closes, changed)
                end
            )
            return lastMenu()
        end

        before_each(function()
            saves, closes, refuse = {}, {}, true
        end)

        it("stays open where what's ticked can't be saved", function()
            local list = tickSites()
            tap("Z-Library")
            list.onClose()
            assert.are.same({ { "archive" } }, saves)
            assert.is_false(helper.wasClosed(list))
            assert.are.same({}, closes)

            refuse = false
            list.onClose()
            assert.is_true(helper.wasClosed(list))
            assert.are.same({ true }, closes)
        end)

        -- KOReader's Home key closes it, then sends Home again until what's on top changes.
        it("closes, as it was, where KOReader's Home key closes it and what's ticked can't be saved", function()
            local Menu = require("ui/widget/menu")
            Menu.onHome = function(self)
                self:onClose()
                return true
            end
            local list = tickSites()
            tap("Z-Library")
            list:onHome()
            assert.is_true(helper.wasClosed(list))
            assert.are.same({ false }, closes)
        end)
    end)

    describe("preferred file types", function()
        it("are grouped by category", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")

            local menu = lastMenu()
            assert.are.equal("── Ebooks ──", menu.item_table[1].text)
            assert.is_false(menu.item_table[1].enabled)
            -- Only epub is ticked by default.
            assert.are.equal("☑ epub", menu.item_table[2].text)
            assert.are.equal("☐ mobi", menu.item_table[3].text)
        end)

        -- Anna's Archive has others (azw3, lit, lrf...) that KOReader can't open.
        it("are only those KOReader can open", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            local offered = {}
            for _, item in ipairs(lastMenu().item_table) do
                if item.text:find("☑", 1, true) == 1 or item.text:find("☐", 1, true) == 1 then
                    table.insert(offered, item.text:match(" (%w+)$"))
                end
            end
            assert.are.equal(21, #offered)
            for _, ext in ipairs(offered) do
                assert.is_true(Settings:isOpenableFileType(ext), ext)
            end
            for _, ext in ipairs({ "azw3", "lit", "lrf", "exe", "zip", "rar" }) do
                assert.is_false(Settings:isOpenableFileType(ext), ext)
            end
        end)

        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            tap("☐ mobi")
            tap("☐ pdf")
            lastMenu().onClose()

            assert.are.same({ "epub", "mobi", "pdf" }, Settings:getPreferredFileTypes())
            assert.are.equal(0, #helper.state.notifications)
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            local all = Settings:getPreferredFileTypes()
            for _, ext in ipairs(all) do
                tap("☑ " .. ext)
            end
            lastMenu().onClose()

            assert.are.same(all, Settings:getPreferredFileTypes())
            assert.are.equal("Select at least one file type", helper.lastNotification())
        end)
    end)

    -- Otherwise they'd have to be deleted by hand once they no longer matched the site.
    describe("clearing the cache", function()
        local cleared

        before_each(function()
            cleared = {}
            for _, name in ipairs({ "search", "cover" }) do
                helper.stub("fetchanna.cache." .. name .. "cache", {
                    clear = function()
                        table.insert(cleared, name)
                    end,
                })
            end
            package.loaded["fetchanna.settings.settingspage"] = nil
            SettingsPage = require("fetchanna.settings.settingspage")
        end)

        it("asks first", function()
            SettingsPage:showSettings()
            tap("Clear Cache")

            local confirm = helper.lastShown()
            assert.are.equal("Clear the searches and book covers that FetchAnna has saved?", confirm.text)
            assert.are.equal("Clear", confirm.ok_text)
            assert.are.same({}, cleared)
        end)

        it("forgets the searches and book covers that are saved", function()
            Settings:addRecentSearch("dune")
            SettingsPage:showSettings()
            tap("Clear Cache")
            helper.lastShown().ok_callback()

            assert.are.same({ "search", "cover" }, cleared)
            -- And the searches made recently.
            assert.are.same({}, Settings:getRecentSearches())
            assert.are.equal("Cache cleared", helper.lastNotification())
        end)
    end)

    -- In case the last update doesn't work on this device.
    describe("going back to the version before", function()
        local plugin_dir

        before_each(function()
            plugin_dir = helper.tmpdir("plugin")
            helper.writeFile(plugin_dir .. "/version.txt", "0.4\n")
            helper.writeFile(plugin_dir .. ".previous/main.lua", "-- v0.3")
            helper.writeFile(plugin_dir .. ".previous/version.txt", "0.3\n")
            -- A temporary folder stands in for the plugin's own.
            helper.stub(
                "fetchanna.util.pathutil",
                setmetatable({
                    getPluginPath = function()
                        return plugin_dir
                    end,
                }, { __index = require("fetchanna.util.pathutil") })
            )
            package.loaded["fetchanna.ui.diagnostics"] = nil
            package.loaded["fetchanna.settings.settingspage"] = nil
            SettingsPage = require("fetchanna.settings.settingspage")
        end)

        it("is offered at the end of the settings, while a version is kept from before", function()
            SettingsPage:showSettings()
            local texts = itemTexts(lastMenu())
            assert.are.equal("Go back to v0.3", texts[#texts])
        end)

        it("isn't offered when there's no version kept from before", function()
            helper.run("rm -rf " .. helper.quote(plugin_dir .. ".previous"))
            SettingsPage:showSettings()
            local texts = itemTexts(lastMenu())
            assert.are.equal("Clear Cache", texts[#texts])
        end)

        it("swaps the versions once confirmed, then offers to restart KOReader", function()
            SettingsPage:showSettings()
            tap("Go back to v0.3")
            local confirm = helper.lastShown()
            assert.are.equal(
                "Go back to FetchAnna v0.3? v0.4, the version installed now, is kept to go forward to again.",
                confirm.text
            )

            confirm.ok_callback()
            assert.are.equal("0.3\n", helper.readFile(plugin_dir .. "/version.txt"))
            assert.are.equal("0.4\n", helper.readFile(plugin_dir .. ".previous/version.txt"))
            assert.are.same(
                { "FetchAnna has gone back to v0.3, which KOReader will use once it restarts." },
                helper.state.restart_prompts
            )
            -- And it isn't offered again every day.
            assert.are.equal("0.4", Settings:getSkippedVersion())
        end)

        it("says why it couldn't", function()
            local rename = os.rename
            os.rename = function(from, to)
                if from == plugin_dir .. ".previous" then
                    return nil, "Permission denied"
                end
                return rename(from, to)
            end
            finally(function()
                os.rename = rename
            end)
            SettingsPage:showSettings()
            tap("Go back to v0.3")
            helper.lastShown().ok_callback()

            assert.are.equal("Going back failed: Permission denied", helper.lastError())
            assert.are.equal("0.4\n", helper.readFile(plugin_dir .. "/version.txt"))
            assert.are.same({}, helper.state.restart_prompts)
        end)
    end)
end)
