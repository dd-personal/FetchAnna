local helper = require("helper")

-- Trimmed-down response from https://api.github.com/repos/example-owner/FetchAnna.koplugin/releases/latest.
local LATEST_RELEASE = [[{
  "html_url": "https://github.com/example-owner/FetchAnna.koplugin/releases/tag/%s",
  "tag_name": "%s",
  "name": "%s",
  "body": "Bug fixes\r\n- fixed updates on android"
}]]

-- Where KOReader keeps its data and user plugins on each kind of device.
local LAYOUTS = {
    {
        name = "kindle/kobo",
        absolute = false, -- data dir is "."
        plugins_dir = "/plugins/",
    },
    {
        name = "android",
        absolute = true, -- data dir is "/sdcard/koreader", plugins are found through "<data dir>/plugins/"
        plugins_dir = "/plugins//",
    },
}

for _, layout in ipairs(LAYOUTS) do
    describe("PluginUpdater on " .. layout.name, function()
        local data_dir, plugin_path, CurlUtil, PluginUpdater, Settings
        -- Where the build says its releases are (see ReleaseSource).
        local release_source
        -- GitHub's answer when asked for the latest release (nil when it can't be reached), and each time it was asked.
        local release_response, release_lookups
        -- How the release itself is downloaded, set by the specs about updating.
        local downloadRelease

        local function latestRelease(tag)
            release_response = LATEST_RELEASE:format(tag, tag, tag)
        end

        -- Checks for updates, and waits for the latest release to be looked up in the background.
        local function checkForUpdates(user_requested)
            PluginUpdater.checkForUpdates(user_requested)
            helper.runScheduled()
        end

        before_each(function()
            helper.reset()
            data_dir = helper.tmpdir("data")
            if layout.absolute then
                data_dir = helper.abs(data_dir)
            end
            helper.state.data_dir = data_dir

            -- Loads PathUtil from an installed copy of the plugin, so updates never touch this repository.
            plugin_path = data_dir .. layout.plugins_dir .. "fetchanna.koplugin"
            helper.stub(
                "fetchanna.util.pathutil",
                helper.loadPluginFileFrom(plugin_path, "fetchanna/util/pathutil.lua")
            )
            helper.writeFile(plugin_path .. "/version.txt", "0.3\n")

            helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))

            -- A build that updates itself from a repository of its own, unless a spec says it has none.
            release_source = { repo = "example-owner/FetchAnna.koplugin" }
            helper.stub("fetchanna.updater.releasesource", release_source)

            CurlUtil = require("fetchanna.util.curlutil")
            Settings = require("fetchanna.settings.settings")
            PluginUpdater = require("fetchanna.updater.pluginupdater")
            -- A curl that can look the latest release up, unless a spec says there isn't one.
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )

            -- Pretends to be curl, which looks up the latest release in the background and has finished by the time
            -- it's checked on.
            release_response, release_lookups = nil, {}
            downloadRelease = function(url)
                error("unexpected download of " .. url)
            end
            CurlUtil.download = function(url, filepath)
                return downloadRelease(url, filepath)
            end
            CurlUtil.startDownload = function(url, filepath, max_time)
                table.insert(release_lookups, {
                    url = url,
                    background = true,
                    max_time = max_time,
                })
                local exit_file = CurlUtil.createExitFile()
                if release_response then
                    helper.writeFile(filepath, release_response)
                end
                helper.writeFile(exit_file, release_response and "0" or "6")
                return 4000, exit_file
            end
            CurlUtil.isPidRunning = function()
                return false
            end
        end)

        after_each(helper.cleanup)

        describe("checkForUpdates", function()
            it("does nothing when the installed version is the latest", function()
                latestRelease("v0.3")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            it("does nothing when the installed version is newer", function()
                helper.writeFile(plugin_path .. "/version.txt", "0.10\n")
                latestRelease("v0.9")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            it("offers newer releases along with their release notes", function()
                latestRelease("v0.4")
                checkForUpdates()

                local dialog = helper.state.shown[1]
                assert.are.equal("Update FetchAnna?", dialog.title)
                assert.matches("FetchAnna v0.3 is installed.", dialog.input, 1, true)
                assert.matches("New version available: v0.4", dialog.input, 1, true)
                assert.matches("Bug fixes\n- fixed updates on android", dialog.input, 1, true)
            end)

            -- KOReader is in use while it checks, e.g. right after starting.
            it("looks up the latest release in the background, for at most 15 seconds", function()
                latestRelease("v0.4")
                PluginUpdater.checkForUpdates()

                assert.are.same({
                    {
                        url = "https://api.github.com/repos/example-owner/FetchAnna.koplugin/releases/latest",
                        background = true,
                        max_time = 15,
                    },
                }, release_lookups)
                assert.are.equal(0, #helper.state.shown)

                helper.runScheduled()
                assert.are.equal("Update FetchAnna?", helper.state.shown[1].title)
            end)

            it("waits for curl to finish looking up the latest release", function()
                local exit_file, release_file
                CurlUtil.startDownload = function(_, filepath)
                    release_file = filepath
                    exit_file = CurlUtil.createExitFile()
                    return 4000, exit_file
                end
                CurlUtil.isPidRunning = function()
                    return true
                end
                PluginUpdater.checkForUpdates()

                helper.tick()
                helper.tick()
                assert.are.equal(0, #helper.state.shown)

                helper.writeFile(release_file, LATEST_RELEASE:format("v0.4", "v0.4", "v0.4"))
                helper.writeFile(exit_file, "0")
                helper.runScheduled()
                assert.are.equal("Update FetchAnna?", helper.state.shown[1].title)
                assert.is_false(helper.exists(release_file))
            end)

            it("reads release notes with quotes in them", function()
                release_response = [[{"tag_name": "v0.4", "body": "Fixed \"Load more\"\r\n- and \"Read now\""}]]
                checkForUpdates()

                assert.matches('Fixed "Load more"\n- and "Read now"', helper.state.shown[1].input, 1, true)
            end)

            it("offers updates without release notes", function()
                release_response = '{"tag_name": "v0.4", "body": ""}'
                checkForUpdates()
                assert.matches("New version available: v0.4", helper.state.shown[1].input, 1, true)

                release_response = '{"tag_name": "v0.4", "body": null}'
                checkForUpdates()
                assert.matches("New version available: v0.4", helper.state.shown[2].input, 1, true)
            end)

            it("treats a missing version file as 0.0.0", function()
                os.remove(plugin_path .. "/version.txt")
                latestRelease("v0.3")
                checkForUpdates()

                assert.matches("FetchAnna v0.0.0 is installed.", helper.state.shown[1].input, 1, true)
            end)

            it("quietly gives up when the latest release cannot be fetched", function()
                checkForUpdates(false)
                assert.are.equal(0, #helper.state.shown)
                assert.are.equal(0, #helper.state.notifications)
                assert.is_nil(helper.lastError())
                assert.matches(
                    "curl exit code 6 %(could not resolve host%)",
                    helper.logged("warn", "^could not look up")
                )
            end)

            it("reports when the latest release cannot be fetched, if the user asked", function()
                checkForUpdates(true)
                assert.are.equal("Checking for updates failed: could not resolve host", helper.lastError())
            end)

            -- KOReader would otherwise exit on it.
            it("reports when looking up the latest release goes wrong, if the user asked", function()
                latestRelease("v0.4")
                CurlUtil.getExitCode = function()
                    error("unexpected")
                end
                checkForUpdates(true)
                assert.are.equal("Checking for updates failed: something went wrong, see crash.log", helper.lastError())
                assert.is_truthy(helper.logged("err", "^looking up the latest release went wrong:.*unexpected"))
            end)

            it("gives up when curl cannot be started", function()
                CurlUtil.startDownload = function()
                    return nil, "could not start curl"
                end
                checkForUpdates(true)
                assert.are.equal("Checking for updates failed: could not start curl", helper.lastError())
            end)

            -- E.g. when GitHub limits how often it can be asked.
            it("gives up when the answer isn't a release", function()
                release_response = '{"message": "API rate limit exceeded for 203.0.113.7."}'
                checkForUpdates(true)

                -- And nothing else, such as an offer to update.
                assert.are.equal(1, #helper.state.shown)
                assert.are.equal(
                    "Checking for updates failed: GitHub says: API rate limit exceeded for 203.0.113.7.",
                    helper.lastError()
                )
                assert.matches("API rate limit exceeded", helper.logged("warn", "^could not read the latest release"))
            end)

            it("gives up when the answer can't be read at all", function()
                release_response = "<html>Bad gateway</html>"
                checkForUpdates(true)
                assert.are.equal(
                    "Checking for updates failed: GitHub didn't answer with the latest release",
                    helper.lastError()
                )

                -- KOReader's json gives an error, not nothing.
                helper.stub("json", {
                    decode = function()
                        error("invalid json")
                    end,
                })
                package.loaded["fetchanna.updater.pluginupdater"] = nil
                PluginUpdater = require("fetchanna.updater.pluginupdater")
                helper.state.shown = {}
                checkForUpdates(true)
                assert.are.equal(
                    "Checking for updates failed: GitHub didn't answer with the latest release",
                    helper.lastError()
                )
            end)

            -- Two lookups would write the latest release to the same file.
            it(
                "doesn't look it up again while it's being looked up, saying how it went once it has, if asked",
                function()
                    latestRelease("v0.3")
                    local lookups, exit_file = 0, nil
                    CurlUtil.startDownload = function(_, filepath)
                        lookups = lookups + 1
                        exit_file = CurlUtil.createExitFile()
                        helper.writeFile(filepath, release_response)
                        return 4000, exit_file
                    end
                    CurlUtil.isPidRunning = function()
                        return true
                    end

                    PluginUpdater.checkForUpdates(false)
                    helper.tick()
                    PluginUpdater.checkForUpdates(true)
                    assert.are.equal(1, lookups)

                    helper.writeFile(exit_file, "0")
                    helper.runScheduled()
                    assert.are.equal("FetchAnna is up to date", helper.lastNotification())
                    -- And it can be looked up again once it has been.
                    PluginUpdater.checkForUpdates(true)
                    assert.are.equal(2, lookups)
                end
            )

            it("says it is up to date, if the user asked", function()
                latestRelease("v0.3")
                checkForUpdates(true)
                assert.are.equal("FetchAnna is up to date", helper.lastNotification())

                helper.state.notifications = {}
                checkForUpdates(false)
                assert.are.equal(0, #helper.state.notifications)
            end)

            it("ignores release tags that are not version numbers", function()
                latestRelease("nightly")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            -- So a fork never installs another project's releases over itself, such as KindleFetch's.
            describe("in a build that doesn't say where its releases are", function()
                before_each(function()
                    release_source.repo = nil
                end)

                it("doesn't ask GitHub", function()
                    latestRelease("v0.4")
                    checkForUpdates(false)
                    assert.are.equal(0, #release_lookups)
                    assert.are.equal(0, #helper.state.popen_calls)
                    assert.are.equal(0, #helper.state.shown)
                    assert.are.equal(0, #helper.state.notifications)
                    assert.is_truthy(helper.logged("info", "^not checking for updates"))
                end)

                it("says it doesn't update itself, if the user asked", function()
                    latestRelease("v0.4")
                    checkForUpdates(true)
                    assert.are.equal(0, #release_lookups)
                    assert.are.equal(
                        "This build of FetchAnna doesn't update itself. Install new versions by hand.",
                        helper.lastNotification()
                    )
                    assert.are.equal(0, #helper.state.shown)
                end)
            end)

            -- It goes into the URLs GitHub is asked at.
            it("only takes a repository that's an owner and a name", function()
                for _, repo in ipairs({
                    "",
                    "owner",
                    "owner/",
                    "/name",
                    "owner/name/releases",
                    "owner/na me",
                    "owner/../name",
                    "https://github.com/owner/name",
                    "owner/name?x=1",
                    42,
                }) do
                    release_source.repo = repo
                    assert.is_nil(PluginUpdater.getRepo(), tostring(repo))
                end
                release_source.repo = "some-owner/Fetch_Anna.koplugin"
                assert.are.equal("some-owner/Fetch_Anna.koplugin", PluginUpdater.getRepo())
            end)

            it("skips the check in the emulator", function()
                helper.stubs.device.sdl = true
                checkForUpdates()
                assert.are.equal(0, #release_lookups)
                assert.are.equal(0, #helper.state.popen_calls)
            end)

            -- So automatic checks can wait a day before the next one.
            it("remembers when the latest release was last looked up", function()
                helper.state.time = 1234567
                latestRelease("v0.3")
                checkForUpdates()
                assert.are.equal(1234567, Settings:getLastUpdateCheck())
            end)

            it("doesn't count a check that couldn't reach github", function()
                checkForUpdates()
                assert.is_nil(Settings:getLastUpdateCheck())
            end)

            -- A Kindle's own curl can be too old to connect to GitHub (KindleFetch #57).
            describe("where curl can't look up the latest release", function()
                local requests

                before_each(function()
                    helper.stubCommand("curl --version", "")
                    requests = {}
                    helper.stubs.http.request = function(request)
                        table.insert(requests, request.url)
                        if not release_response then
                            return nil, "No address associated with hostname"
                        end
                        request.sink(release_response)
                        return 1, 200
                    end
                end)

                it("looks it up with KOReader's own HTTP when asked to check for updates", function()
                    latestRelease("v0.4")
                    checkForUpdates(true)

                    assert.are.same(
                        { "https://api.github.com/repos/example-owner/FetchAnna.koplugin/releases/latest" },
                        requests
                    )
                    assert.are.same({}, release_lookups)
                    assert.are.equal("Update FetchAnna?", helper.lastShown().title)
                end)

                it("reports when it cannot be looked up", function()
                    checkForUpdates(true)
                    assert.are.equal("Checking for updates failed: could not resolve host", helper.lastError())
                end)

                -- That would block KOReader while it's in use.
                it("doesn't look it up by itself", function()
                    latestRelease("v0.4")
                    checkForUpdates()

                    assert.are.same({}, requests)
                    assert.are.same({}, release_lookups)
                    assert.are.equal(0, #helper.state.shown)
                end)
            end)

            describe("once an update is turned down", function()
                before_each(function()
                    latestRelease("v0.4")
                    checkForUpdates()
                    helper.state.shown[1].buttons[1][1].callback()
                end)

                it("doesn't offer that release again", function()
                    assert.are.equal("0.4", Settings:getSkippedVersion())

                    checkForUpdates(false)
                    assert.are.equal(1, #helper.state.shown)
                    assert.matches("was turned down before", helper.logged("info", "^FetchAnna 0.4"))
                end)

                it("offers it again when the user asks to check for updates", function()
                    checkForUpdates(true)
                    assert.are.equal(2, #helper.state.shown)
                    assert.matches("New version available: v0.4", helper.state.shown[2].input, 1, true)
                end)

                it("offers the release after it", function()
                    latestRelease("v0.5")
                    checkForUpdates(false)
                    assert.are.equal(2, #helper.state.shown)
                    assert.matches("New version available: v0.5", helper.state.shown[2].input, 1, true)
                end)
            end)
        end)

        describe("updating", function()
            local release_zip, downloaded_url

            local function acceptUpdate()
                checkForUpdates()
                local update_button = helper.state.shown[1].buttons[1][2]
                assert.are.equal("Update", update_button.text)
                update_button.callback()
            end

            before_each(function()
                -- Builds a release zip laid out like the ones published on GitHub.
                local build_dir = helper.tmpdir("release")
                helper.writeFile(build_dir .. "/fetchanna.koplugin/main.lua", "-- v0.4\n")
                helper.writeFile(build_dir .. "/fetchanna.koplugin/version.txt", "0.4\n")
                release_zip = helper.abs(build_dir) .. "/fetchanna.koplugin.zip"
                helper.run(
                    string.format(
                        "cd %s && zip -qr %s fetchanna.koplugin",
                        helper.quote(build_dir),
                        helper.quote(release_zip)
                    )
                )

                downloaded_url = nil
                downloadRelease = function(url, filepath)
                    downloaded_url = url
                    helper.run(string.format("cp %s %s", helper.quote(release_zip), helper.quote(filepath)))
                    return true
                end

                latestRelease("v0.4")
            end)

            it("downloads the release asset for the new version", function()
                acceptUpdate()
                assert.are.equal(
                    "https://github.com/example-owner/FetchAnna.koplugin/releases/download/v0.4/"
                        .. "fetchanna.koplugin.zip",
                    downloaded_url
                )
            end)

            it("replaces the installed plugin with the new release", function()
                acceptUpdate()

                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
                assert.are.equal("0.4", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. "/util/pathutil.lua"))
                -- Offers to restart KOReader, which uses the new version once it has.
                assert.are.same(
                    { "FetchAnna has updated to v0.4, which KOReader will use once it restarts." },
                    helper.state.restart_prompts
                )
            end)

            -- In case the new version doesn't work on this device (see Rollback).
            it("keeps the version installed before to go back to, in place of any kept before", function()
                helper.writeFile(plugin_path .. "/main.lua", "-- v0.3\n")
                helper.writeFile(plugin_path .. ".previous/version.txt", "0.2\n")
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. ".previous/version.txt"))
                assert.is_true(helper.exists(plugin_path .. ".previous/fetchanna/util/pathutil.lua"))
                assert.are.equal("0.3", require("fetchanna.updater.rollback").previousVersion(plugin_path))
            end)

            it("cleans up the backup and downloaded files", function()
                acceptUpdate()

                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.is_false(helper.exists(plugin_path .. ".new"))
                assert.is_false(helper.exists(data_dir .. "/cache/fetchanna"))
            end)

            -- Unzipping over it would keep files the release no longer has.
            it("removes what's left of an install that didn't finish first", function()
                helper.writeFile(plugin_path .. ".new/fetchanna.koplugin/stale.lua", "-- v0.2")
                acceptUpdate()

                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
                assert.is_false(helper.exists(plugin_path .. "/stale.lua"))
            end)

            -- Not every device has unzip (stock Android before 9 doesn't).
            it("unzips the release with KOReader's own archiver where it has one", function()
                local opened = {}
                helper.stub("ffi/archiver", {
                    Reader = {
                        new = function(self)
                            return setmetatable({}, { __index = self })
                        end,
                        open = function(self, path)
                            table.insert(opened, path)
                            self.path = path
                            return true
                        end,
                        iterate = function(self)
                            local pipe = io.popen("unzip -Z1 " .. helper.quote(self.path))
                            local entries = {}
                            for line in pipe:lines() do
                                table.insert(entries, { path = line })
                            end
                            pipe:close()
                            local i = 0
                            return function()
                                i = i + 1
                                return entries[i]
                            end
                        end,
                        extractToPath = function(self, entry, dest)
                            if entry:find("/$") then
                                helper.run("mkdir -p " .. helper.quote(dest))
                            else
                                helper.run(
                                    string.format(
                                        "mkdir -p %s && unzip -p %s %s > %s",
                                        helper.quote(dest:match("^(.*)/")),
                                        helper.quote(self.path),
                                        helper.quote(entry),
                                        helper.quote(dest)
                                    )
                                )
                            end
                            return true
                        end,
                        close = function() end,
                    },
                })
                helper.stubExecute("unzip -q", function()
                    error("unzipped with unzip")
                end)
                acceptUpdate()

                assert.are.equal(1, #opened)
                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
            end)

            -- A release could otherwise write anywhere KOReader can.
            it("refuses a release with a file that would unzip outside its folder, before unzipping any", function()
                local extracted = {}
                helper.stub("ffi/archiver", {
                    Reader = {
                        new = function(self)
                            return setmetatable({}, { __index = self })
                        end,
                        open = function()
                            return true
                        end,
                        iterate = function()
                            local entries = {
                                { path = "fetchanna.koplugin/main.lua", mode = "file" },
                                { path = "fetchanna.koplugin/../../evil.lua", mode = "file" },
                            }
                            local i = 0
                            return function()
                                i = i + 1
                                return entries[i]
                            end
                        end,
                        extractToPath = function(_, entry)
                            table.insert(extracted, entry)
                            return true
                        end,
                        close = function() end,
                    },
                })
                acceptUpdate()

                assert.are.same({}, extracted)
                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal(
                    "Updating FetchAnna failed: it has a file that would unzip outside FetchAnna's folder",
                    helper.lastError()
                )
            end)

            it("only unzips files and folders whose paths stay inside the folder", function()
                local safe = PluginUpdater.isSafeEntry
                assert.is_true(safe({ path = "fetchanna.koplugin/main.lua", mode = "file" }))
                assert.is_true(safe({ path = "fetchanna.koplugin/", mode = "directory" }))
                assert.is_true(safe({ path = "fetchanna.koplugin/a..b.lua" }))
                assert.is_false(safe({ path = "../main.lua", mode = "file" }))
                assert.is_false(safe({ path = "fetchanna.koplugin/../../main.lua" }))
                assert.is_false(safe({ path = "/etc/passwd", mode = "file" }))
                assert.is_false(safe({ path = "fetchanna.koplugin\\..\\main.lua" }))
                assert.is_false(safe({ path = "fetchanna.koplugin/settings", mode = "link" }))
                assert.is_false(safe({ path = "fetchanna.koplugin/fifo", mode = "named pipe" }))
                assert.is_false(safe({ path = "" }))
                assert.is_false(safe({}))
            end)

            it("does nothing when the user cancels", function()
                checkForUpdates()
                local dialog = helper.state.shown[1]
                dialog.buttons[1][1].callback()

                assert.is_true(helper.wasClosed(dialog))
                assert.is_nil(downloaded_url)
            end)

            it("keeps the installed plugin when the release has no plugin folder", function()
                local build_dir = helper.tmpdir("bad-release")
                helper.writeFile(build_dir .. "/FetchAnna-main/main.lua", "-- v0.4\n")
                local bad_zip = helper.abs(build_dir) .. "/release.zip"
                helper.run(
                    string.format("cd %s && zip -qr %s FetchAnna-main", helper.quote(build_dir), helper.quote(bad_zip))
                )
                release_zip = bad_zip
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Updating FetchAnna failed: it has no FetchAnna in it", helper.lastError())
            end)

            -- Makes moving a folder to the given place fail, as KOReader's os.rename does.
            local function failMovesTo(to, err)
                local rename = os.rename
                os.rename = function(from, dest)
                    if dest == to then
                        return nil, err
                    end
                    return rename(from, dest)
                end
                finally(function()
                    os.rename = rename
                end)
            end

            it("keeps the installed plugin when it cannot be moved aside", function()
                failMovesTo(plugin_path .. ".backup", "Permission denied")
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal(
                    "Updating FetchAnna failed: the installed version couldn't be moved aside (Permission denied)",
                    helper.lastError()
                )
                assert.is_false(helper.exists(plugin_path .. ".new"))
            end)

            it("restores the installed plugin when the new one cannot be moved into place", function()
                local rename = os.rename
                os.rename = function(from, to)
                    if from == plugin_path .. ".new/fetchanna.koplugin" then
                        return nil, "Device or resource busy"
                    end
                    return rename(from, to)
                end
                finally(function()
                    os.rename = rename
                end)
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.are.equal(
                    "Updating FetchAnna failed: the new version couldn't be moved into place (Device or resource "
                        .. "busy)",
                    helper.lastError()
                )
            end)

            -- That leaves FetchAnna out of KOReader's menu.
            it("says where the installed plugin is when it can't be put back", function()
                failMovesTo(plugin_path, "No space left on device")
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. ".backup/version.txt"))
                assert.are.equal(
                    "Updating FetchAnna failed: the new version couldn't be moved into place (No space left on "
                        .. "device), and the installed version couldn't be put back from "
                        .. plugin_path
                        .. ".backup",
                    helper.lastError()
                )
                assert.is_truthy(helper.logged("err", "^could not put the installed version back from"))
            end)

            -- A Kindle's own curl can be too old to connect to GitHub (KindleFetch #57).
            it("downloads it with KOReader's own HTTP where curl can't", function()
                helper.stubCommand("curl --version", "")
                local requests = {}
                helper.stubs.http.request = function(request)
                    table.insert(requests, request.url)
                    if request.url:find("/releases/latest", 1, true) then
                        request.sink(release_response)
                    else
                        request.sink(helper.readFile(release_zip))
                    end
                    return 1, 200
                end

                checkForUpdates(true)
                helper.lastShown().buttons[1][2].callback()

                assert.are.same({
                    "https://api.github.com/repos/example-owner/FetchAnna.koplugin/releases/latest",
                    "https://github.com/example-owner/FetchAnna.koplugin/releases/download/v0.4/"
                        .. "fetchanna.koplugin.zip",
                }, requests)
                assert.is_nil(downloaded_url)
                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
            end)

            it("keeps the installed plugin when the download leaves no file", function()
                downloadRelease = function()
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Updating FetchAnna failed: nothing downloaded", helper.lastError())
            end)

            it("keeps the installed plugin when the download fails", function()
                downloadRelease = function()
                    return nil, "request timed out"
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal(
                    "Updating FetchAnna failed: it couldn't be downloaded (request timed out)",
                    helper.lastError()
                )
            end)

            it("keeps the installed plugin when the download is not a valid zip", function()
                downloadRelease = function(_, filepath)
                    helper.writeFile(filepath, "<html>rate limited</html>")
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                -- With what unzip said, for crash.log.
                assert.matches("^Updating FetchAnna failed: it couldn't be unzipped %(.+%)", helper.lastError())
                assert.is_truthy(helper.logged("warn", "^could not unzip the release:"))
            end)
        end)
    end)
end
