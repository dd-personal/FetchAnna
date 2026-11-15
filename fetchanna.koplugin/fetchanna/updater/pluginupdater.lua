local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local FileUtil = require("fetchanna.util.fileutil")
local CurlUtil = require("fetchanna.util.curlutil")
local HttpUtil = require("fetchanna.util.httputil")
local LogUtil = require("fetchanna.util.logutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local VersionUtil = require("fetchanna.util.versionutil")
local StringUtil = require("fetchanna.util.stringutil")
local PathUtil = require("fetchanna.util.pathutil")
local ShellUtil = require("fetchanna.util.shellutil")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local Guard = require("fetchanna.util.guard")
local Rollback = require("fetchanna.updater.rollback")
local ReleaseSource = require("fetchanna.updater.releasesource")
local T = require("ffi/util").template
local _ = require("gettext")

local PLUGIN_NAME = "fetchanna.koplugin"
local GITHUB_API_URL = "https://api.github.com/repos/"
local GITHUB_URL = "https://github.com/"
local POLL_INTERVAL = 0.5
-- KOReader is in use while the latest release is looked up, so don't keep at it for long.
local CHECK_MAX_TIME = 15

local PluginUpdater = {}

-- Returns the repository updates come from (see ReleaseSource), or nil when the build has none or it isn't only an
-- owner and a name, as it goes into URLs.
function PluginUpdater.getRepo()
    local repo = ReleaseSource.repo
    if type(repo) == "string" and repo:find("^[%w%-%._]+/[%w%-%._]+$") and not repo:find("%.%.") then
        return repo
    end
    return nil
end

-- Where GitHub says what the latest release is, and where releases are downloaded from.
local function repoVersionUrl()
    return GITHUB_API_URL .. PluginUpdater.getRepo()
end
local function repoDownloadUrl()
    return GITHUB_URL .. PluginUpdater.getRepo()
end

-- The check for updates under way, if any, so another isn't started meanwhile: they'd write the same file.
local checking

-- Returns the version and release notes in GitHub's description of the latest release, or nil and why not.
local function parseUpdateInfo(output)
    local ok, release = pcall(JSON.decode, output)
    if not ok or type(release) ~= "table" or type(release.tag_name) ~= "string" then
        -- E.g. GitHub's rate limit, which says so.
        LogUtil.warn("could not read the latest release from GitHub:", output:gsub("%s+", " "):sub(1, 300))
        local message = ok and type(release) == "table" and type(release.message) == "string" and release.message
        return nil, message and T(_("GitHub says: %1"), message) or _("GitHub didn't answer with the latest release")
    end
    local tag = release.tag_name:gsub("^v", "")

    local version = VersionUtil.parseVersion(tag)
    if not version then
        LogUtil.warn("could not read the version of the latest release, tagged", tag)
        return nil, T(_("the latest release's version can't be read (%1)"), tag)
    end

    return {
        version = version,
        -- A release without notes has null here, which isn't a string once read.
        notes = type(release.body) == "string" and release.body or nil,
    }
end

-- Looks up the latest release on GitHub in the background. Calls callback with its version and release notes, or nil
-- and why not.
local function fetchUpdateInfo(callback)
    -- Where curl can't fetch (KindleFetch #57), KOReader's own HTTP does, which blocks KOReader, so it's only done on a
    -- requested check.
    if not CurlUtil.canFetch() then
        local body, err = HttpUtil.getBody(repoVersionUrl() .. "/releases/latest")
        if not body then
            LogUtil.warn("could not look up the latest release on GitHub:", err)
            callback(nil, err)
            return
        end
        callback(parseUpdateInfo(body))
        return
    end

    local release_file = PathUtil.getTmpPath() .. "/latest_release.json"
    local pid, exit_file = CurlUtil.startDownload(repoVersionUrl() .. "/releases/latest", release_file, CHECK_MAX_TIME)
    if not pid then
        -- exit_file is then why not.
        LogUtil.warn("could not start curl to look up the latest release:", exit_file)
        callback(nil, exit_file)
        return
    end

    -- An error while polling (see Guard) counts as a failed lookup.
    local function failed(err)
        callback(nil, err)
    end
    local function poll()
        local exit_code = CurlUtil.getExitCode(exit_file)
        if not exit_code then
            if CurlUtil.isPidRunning(pid) then
                Guard.scheduleIn(POLL_INTERVAL, "looking up the latest release", poll, failed)
                return
            end
            -- curl may have finished between the check for its exit code and the check that it's running.
            exit_code = CurlUtil.getExitCode(exit_file)
        end

        local output = FileUtil.readFile(release_file)
        FileUtil.removeFile(release_file)
        if exit_code ~= 0 or not output then
            -- E.g. GitHub's rate limit, or no connection.
            LogUtil.warn(
                "could not look up the latest release on GitHub: curl exit code",
                tostring(exit_code),
                "(" .. CurlUtil.getErrorMeaning(exit_code) .. ")"
            )
            callback(nil, exit_code and CurlUtil.explainExitCode(exit_code) or _("GitHub didn't answer"))
            return
        end

        callback(parseUpdateInfo(output))
    end
    Guard.scheduleIn(POLL_INTERVAL, "looking up the latest release", poll, failed)
end

-- Returns the installed version, from version.txt, or nil.
local function getInstalledVersion(plugin_path)
    local version_file = plugin_path .. "/version.txt"
    if not FileUtil.isValidFile(version_file) then
        return nil
    end

    local version_str = FileUtil.readFile(version_file)
    if not version_str then
        return nil
    end

    return VersionUtil.parseVersion(version_str)
end

-- Downloads the release from GitHub. Returns where it downloaded to, or nil and what went wrong.
local function downloadPluginRelease(version_str)
    LogUtil.info("downloading FetchAnna", version_str)
    local download_url = string.format(repoDownloadUrl() .. "/releases/download/v%s/%s.zip", version_str, PLUGIN_NAME)
    local zip_path = PathUtil.getTmpPath() .. "/" .. PLUGIN_NAME .. ".zip"

    LogUtil.debug("plugin download url", download_url)

    -- With KOReader's own HTTP where curl can't fetch, as when looking the release up.
    local success, err = HttpUtil.downloadFile(download_url, zip_path)
    if not success then
        LogUtil.warn("could not download FetchAnna", version_str, "from", download_url, "error:", err)
        return nil, T(_("it couldn't be downloaded (%1)"), err)
    end

    if not FileUtil.isValidFile(zip_path) then
        LogUtil.warn(
            "downloaded FetchAnna",
            version_str,
            "is not a valid file:",
            zip_path,
            FileUtil.getSize(zip_path),
            "bytes"
        )
        return nil, _("nothing downloaded")
    end

    LogUtil.debug("plugin release downloaded successfully", zip_path)
    return zip_path
end

-- Whether a zip entry stays inside the folder it's unzipped into: a relative path with no ".." in it, to a file or
-- folder. A link could point anywhere, so it's refused too. mode is nil where the archiver doesn't say.
function PluginUpdater.isSafeEntry(entry)
    local path = type(entry) == "table" and entry.path
    if type(path) ~= "string" or path == "" or path:find("^/") or path:find("[\\%z]") then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            return false
        end
    end
    return entry.mode == nil or entry.mode == "file" or entry.mode == "directory"
end

-- Unzips the release into folder, with KOReader's own archiver where it has one, as not every device has unzip (stock
-- Android before 9 doesn't). With the archiver, the whole release is refused if any entry would land outside folder
-- (see isSafeEntry). unzip skips such entries itself. Returns true, or nil and why not.
local function extract(zip_path, folder)
    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if has_archiver and type(Archiver) == "table" and Archiver.Reader then
        local archive = Archiver.Reader:new()
        if not archive:open(zip_path) then
            LogUtil.warn("could not open", zip_path, "to unzip it:", archive.err)
            return nil, T(_("it couldn't be opened (%1)"), tostring(archive.err))
        end
        local entries = {}
        for entry in archive:iterate() do
            if not PluginUpdater.isSafeEntry(entry) then
                LogUtil.warn("the release has an entry that would unzip outside its folder:", tostring(entry.path))
                archive:close()
                return nil, _("it has a file that would unzip outside FetchAnna's folder")
            end
            table.insert(entries, entry)
        end
        local extracted = true
        for __, entry in ipairs(entries) do
            if not archive:extractToPath(entry.path, folder .. "/" .. entry.path) then
                extracted = false
                break
            end
        end
        local err = archive.err
        archive:close()
        if not extracted or err then
            LogUtil.warn("could not unzip", zip_path, err)
            return nil, T(_("it couldn't be unzipped (%1)"), tostring(err))
        end
        return true
    end

    local ok, err = ShellUtil.run(
        "unzip the release",
        string.format("unzip -q -o %s -d %s", CurlUtil.shellQuote(zip_path), CurlUtil.shellQuote(folder))
    )
    if not ok then
        return nil, T(_("it couldn't be unzipped (%1)"), err)
    end
    return true
end

-- Installs the release from the zip. The installed plugin is put back if the new one can't be moved into place, and
-- otherwise kept to go back to (see Rollback). Returns true, or nil and what went wrong.
local function installPluginRelease(plugin_path, zip_path, version_str)
    LogUtil.info("installing FetchAnna from", zip_path, "to", plugin_path)

    -- Unzipped next to the plugin, not in KOReader's cache, as renaming into place only works within a file system.
    -- KOReader only loads folders named *.koplugin, so it ignores this one. Leftovers of an unfinished install are
    -- removed first.
    local staging = plugin_path .. ".new"
    local backup = plugin_path .. ".backup"
    FileUtil.removeDir(staging)
    lfs.mkdir(staging)

    local ok, err = extract(zip_path, staging)
    local extracted = staging .. "/" .. PLUGIN_NAME
    if ok and not FileUtil.isValidFile(extracted .. "/main.lua") then
        LogUtil.warn("the release has no", PLUGIN_NAME, "folder with a main.lua in it")
        ok, err = nil, _("it has no FetchAnna in it")
    end

    if ok then
        -- Its version, in case the release doesn't say. Written before the move, so a failure here doesn't fail an
        -- install that worked.
        local written, write_err = FileUtil.writeFile(extracted .. "/version.txt", version_str)
        if not written then
            LogUtil.warn("could not write", extracted .. "/version.txt:", write_err)
        end

        FileUtil.removeDir(backup)
        local moved, move_err = os.rename(plugin_path, backup)
        if not moved then
            LogUtil.warn("could not move", plugin_path, "aside to", backup .. ":", move_err)
            ok, err = nil, T(_("the installed version couldn't be moved aside (%1)"), move_err)
        else
            moved, move_err = os.rename(extracted, plugin_path)
            if moved then
                -- Replaces any kept before, in case the new version doesn't work on this device.
                local previous = Rollback.previousPath(plugin_path)
                FileUtil.removeDir(previous)
                local kept, keep_err = os.rename(backup, previous)
                if not kept then
                    LogUtil.warn("could not keep", backup, "as", previous, "to go back to:", keep_err)
                    FileUtil.removeDir(backup)
                end
            else
                LogUtil.warn("could not move", extracted, "to", plugin_path .. ":", move_err)
                local restored, restore_err = os.rename(backup, plugin_path)
                if restored then
                    ok, err = nil, T(_("the new version couldn't be moved into place (%1)"), move_err)
                else
                    -- That leaves FetchAnna out of KOReader's menu, so the error says where it is.
                    LogUtil.err("could not put the installed version back from", backup .. ":", restore_err)
                    ok, err =
                        nil,
                        T(
                            _(
                                "the new version couldn't be moved into place (%1), and the installed version couldn't "
                                    .. "be put back from %2"
                            ),
                            move_err,
                            backup
                        )
                end
            end
        end
    end

    -- Removes what's left of the release, installed or not.
    FileUtil.removeDir(staging)
    FileUtil.removeDir(PathUtil.getTmpPath())
    if ok then
        LogUtil.info("installed FetchAnna", version_str)
    end
    return ok, err
end

-- Downloads and installs a new version. Returns true, or nil and what went wrong.
local function updatePlugin(plugin_path, version_str)
    LogUtil.debug("updating plugin to version", version_str)
    NotifyUtil.info(T(_("Downloading FetchAnna v%1..."), version_str))

    local zip_path, err = downloadPluginRelease(version_str)
    if not zip_path then
        FileUtil.removeDir(PathUtil.getTmpPath())
        return nil, err
    end
    return installPluginRelease(plugin_path, zip_path, version_str)
end

local function promptPluginUpdate(plugin_path, installed_version, available_update)
    local message = T(
        _("FetchAnna v%1 is installed.\nNew version available: v%2\n\n%3\n\nUpdate FetchAnna now?"),
        installed_version,
        available_update.version.str,
        StringUtil.replaceCarriageReturns(available_update.notes)
    )

    LogUtil.debug("showing update message:", message)

    local confirm_dialog
    confirm_dialog = InputDialog:new {
        title = _("Update FetchAnna?"),
        input_type = "text",
        input = message,
        readonly = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        LogUtil.info("FetchAnna update declined")
                        -- So this release isn't offered again every day, only on a requested check.
                        FetchAnnaSettings:setSkippedVersion(available_update.version.str)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        local version_str = available_update.version.str
                        local ok, err = updatePlugin(plugin_path, version_str)
                        if not ok then
                            NotifyUtil.error(T(_("Updating FetchAnna failed: %1"), err))
                            return
                        end
                        -- KOReader loads plugins as it starts, so offer a restart. A notification would be gone in a
                        -- couple of seconds.
                        UIManager:askForRestart(
                            T(_("FetchAnna has updated to v%1, which KOReader will use once it restarts."), version_str)
                        )
                    end,
                },
            },
        },
    }

    UIManager:show(confirm_dialog)
end

-- Checks for a newer version and offers to update, reporting the result if the user asked. Returns before the lookup is
-- over, as it runs in the background.
function PluginUpdater.checkForUpdates(user_requested)
    if Device:isSDL() then
        LogUtil.debug("running in emulator, skipping plugin version check")
        return
    end
    -- A build that doesn't say where its releases are doesn't ask GitHub at all (see ReleaseSource).
    if not PluginUpdater.getRepo() then
        LogUtil.info("not checking for updates, as this build doesn't say where its releases are")
        if user_requested then
            NotifyUtil.info(_("This build of FetchAnna doesn't update itself. Install new versions by hand."))
        end
        return
    end
    -- Without a curl to look it up in the background, it's only looked up on request, as KOReader's own HTTP would
    -- block.
    if not user_requested and not CurlUtil.canFetch() then
        LogUtil.info("only looking up the latest release when asked to check, as curl can't look it up")
        return
    end
    LogUtil.debug("checking for plugin updates from", repoVersionUrl())

    -- A check already under way reports its result if this one was asked for.
    if checking then
        LogUtil.info("already checking for updates")
        checking.user_requested = checking.user_requested or user_requested
        return
    end
    local check = { user_requested = user_requested }
    checking = check

    local plugin_path = PathUtil.getPluginPath()

    local installed_version = getInstalledVersion(plugin_path)
    if not installed_version then
        LogUtil.warn("could not determine installed version, setting to 0.0.0")
        installed_version = VersionUtil.parseVersion("0.0.0")
    end

    fetchUpdateInfo(function(repo_update, err)
        checking = nil
        user_requested = check.user_requested
        if not repo_update then
            LogUtil.warn("could not check for FetchAnna updates")
            if user_requested then
                NotifyUtil.error(T(_("Checking for updates failed: %1"), err or _("GitHub didn't answer")))
            end
            return
        end
        -- Automatic checks wait a day from here.
        FetchAnnaSettings:setLastUpdateCheck(os.time())

        LogUtil.info(
            "FetchAnna",
            installed_version.str,
            "is installed, and the latest release is",
            repo_update.version.str
        )

        local cmp = VersionUtil.compareVersions(installed_version, repo_update.version)
        if cmp >= 0 then
            LogUtil.debug("plugin is up to date")
            if user_requested then
                NotifyUtil.info(_("FetchAnna is up to date"))
            end
            return
        end

        -- Not offered again once turned down, unless asked to check.
        if not user_requested and repo_update.version.str == FetchAnnaSettings:getSkippedVersion() then
            LogUtil.info("FetchAnna", repo_update.version.str, "was turned down before, so not offering it again")
            return
        end

        LogUtil.info("offering to update FetchAnna to", repo_update.version.str)
        promptPluginUpdate(plugin_path, installed_version.str, repo_update)
    end)
end

return PluginUpdater
