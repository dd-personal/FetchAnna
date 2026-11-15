local Device = require("device")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local TextViewer = require("ui/widget/textviewer")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local AnnasAccount = require("fetchanna.api.annasaccount")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local KeyStore = require("fetchanna.api.keystore")
local OriginPolicy = require("fetchanna.util.originpolicy")
local WaitingMessage = require("fetchanna.ui.waitingmessage")
local CurlUtil = require("fetchanna.util.curlutil")
local HttpUtil = require("fetchanna.util.httputil")
local FileUtil = require("fetchanna.util.fileutil")
local LogUtil = require("fetchanna.util.logutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local PathUtil = require("fetchanna.util.pathutil")
local ProxyUtil = require("fetchanna.util.proxyutil")
local Guard = require("fetchanna.util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- A report on FetchAnna, KOReader, the device and the connection to the sites, with the recent log, for whoever's
-- helping with a problem.
local Diagnostics = {}

-- The saved report's file name. It goes in KOReader's data folder, reachable over USB but not among the books.
local REPORT_NAME = "fetchanna-diagnostics.txt"

-- Returns the installed FetchAnna version, or nil if it can't be read.
function Diagnostics.version()
    local version = FileUtil.readFile(PathUtil.getPluginPath() .. "/version.txt")
    return version and version:match("^%s*(.-)%s*$")
end

-- Returns the kind of device KOReader is on.
local function deviceKind()
    return Device:isKindle() and "Kindle"
        or (Device.isKobo and Device:isKobo()) and "Kobo"
        or Device:isAndroid() and "Android"
        or Device:isSDL() and "computer"
        or "device"
end

-- Returns one line with the FetchAnna, KOReader and curl versions and the device. Logged when KOReader starts.
function Diagnostics.summary()
    local ok, koreader_version = pcall(function()
        return require("version"):getCurrentRevision()
    end)
    return string.format(
        "FetchAnna %s on KOReader %s, %s %s, curl %s%s",
        Diagnostics.version() or "unknown",
        ok and koreader_version or "unknown",
        deviceKind(),
        tostring(Device.model),
        CurlUtil.getVersion() or "not found",
        ProxyUtil.get() and ", through KOReader's HTTP proxy" or ""
    )
end

-- Returns the report's text, in English, as it's for whoever helps. tested is the connection test's results, if
-- any. It says how the Anna's Archive account is, but never its key or sessions, and the whole text is redacted as
-- well (see LogUtil.redact).
function Diagnostics.report(tested)
    local lines = { Diagnostics.summary() }
    local function add(label, value)
        table.insert(lines, label .. ": " .. tostring(value))
    end
    local function list(values)
        return #values > 0 and table.concat(values, ", ") or "none"
    end
    local function onOff(on)
        return on and "on" or "off"
    end

    add("Time", os.date("%Y-%m-%d %H:%M") .. " (secure connections fail when it's far off)")
    add("Fetching with", CurlUtil.canFetch() and "curl" or "KOReader's own HTTP, as curl can't")
    local folder = FetchAnnaSettings:getDownloadDir()
    local writable, err = FileUtil.checkWritableDir(folder)
    add("Download folder", folder .. (writable and "" or " (which can't be written to: " .. tostring(err) .. ")"))
    add("Languages", list(FetchAnnaSettings:getPreferredLanguages()))
    add("File types", list(FetchAnnaSettings:getPreferredFileTypes()))
    add(
        "Encrypted DNS",
        onOff(FetchAnnaSettings:getEncryptedDns()) .. (CurlUtil.canUseEncryptedDns() and "" or " (which curl can't do)")
    )
    add("Covers", onOff(FetchAnnaSettings:getShowBookCovers()))
    add("Update checks", onOff(FetchAnnaSettings:getCheckForUpdates()))

    local account = AnnasAccount:status()
    add(
        "Anna's Archive account",
        account.status
            .. (account.tier and ", membership tier " .. account.tier or "")
            .. (account.downloads_left and string.format(
                ", fast downloads left: %s of %s",
                tostring(account.downloads_left),
                tostring(account.downloads_per_day or "?")
            ) or "")
            .. (account.failure and ", last failure: " .. account.failure or "")
            .. (KeyStore.isRemembered() and ", key remembered on the device" or ", key kept until KOReader restarts")
    )
    -- Shows that the link came from the member API, by host names only, never the link.
    local last_link = account.last_link
    add(
        "Last download link",
        last_link
                and string.format(
                    "%s, a fast download from the member API on %s, served by %s",
                    os.date("%Y-%m-%d %H:%M", last_link.at),
                    last_link.site or "?",
                    last_link.server or "?"
                )
            or "none yet"
    )
    local logged_in_on = {}
    for __, session in ipairs(account.sessions) do
        table.insert(logged_in_on, OriginPolicy.hostOf(session.origin))
    end
    add("Logged into Anna's Archive on", list(logged_in_on))
    local sites = {}
    for __, record in ipairs(AnnasMirrors:list("catalogue")) do
        table.insert(sites, record.host .. " (" .. record.trust .. ")")
    end
    add("Anna's Archive sites", list(sites))
    local discovery = AnnasMirrors:discovery()
    add(
        "Looked up on SLUM",
        (discovery.fetched_at and os.date("%Y-%m-%d %H:%M", discovery.fetched_at) or "never")
            .. (discovery.last_error and ", last failed: " .. discovery.last_error or "")
    )

    if tested then
        table.insert(lines, "")
        table.insert(lines, "Connection test:")
        for __, result in ipairs(tested) do
            table.insert(lines, "  " .. result)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Recent log:")
    for __, line in ipairs(LogUtil.recent()) do
        table.insert(lines, line)
    end
    return LogUtil.redact(table.concat(lines, "\n"))
end

-- Saves the report's text to a file (see REPORT_NAME) and says where.
function Diagnostics.save(text)
    local path = DataStorage:getDataDir() .. "/" .. REPORT_NAME
    local ok, err = FileUtil.writeFile(path, text)
    if not ok then
        LogUtil.warn("could not save the diagnostics to", path, "as", err)
        NotifyUtil.error(T(_("The diagnostics couldn't be saved: %1"), err))
        return
    end
    LogUtil.info("saved the diagnostics to", path)
    NotifyUtil.info(T(_("Saved to %1"), path))
end

-- Shows the report, with buttons to test the connection, copy it or save it.
function Diagnostics.show(tested)
    local text = Diagnostics.report(tested)
    local viewer
    viewer = TextViewer:new {
        title = _("FetchAnna diagnostics"),
        text = text,
        text_type = "code",
        -- KOReader's own buttons (Find, Close, top and bottom) come after these.
        add_default_buttons = true,
        buttons_table = {
            {
                {
                    text = _("Test connection"),
                    callback = function()
                        UIManager:close(viewer)
                        Diagnostics.testConnection()
                    end,
                },
                {
                    text = _("Copy"),
                    callback = function()
                        Device.input.setClipboardText(text)
                        NotifyUtil.info(_("Copied"))
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        Diagnostics.save(text)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

-- Returns the URLs to test: SLUM, and each known site's home page, which is sent nothing of the account's.
local function testUrls()
    local urls = { AnnasMirrors.SLUM_URL }
    for __, record in ipairs(AnnasMirrors:list("catalogue")) do
        table.insert(urls, record.origin .. "/")
    end
    return urls
end

-- Returns the report's line for one test. Any answer counts, whatever its status.
local function result(url, body, err, status)
    local site = LogUtil.site(url)
    if status then
        return string.format("%s answered (HTTP %s)", site, tostring(status))
    elseif body then
        return site .. " answered"
    end
    return string.format("%s didn't answer: %s", site, tostring(err))
end

-- Tests each URL in turn (see testUrls), then shows the report with the results. Cancel stops it and shows the
-- results so far.
function Diagnostics.testConnection()
    local message
    local function closeMessage()
        HttpUtil.setTrapWidget(nil)
        if message and not message.cancelled and not message.closed then
            message.closed = true
            UIManager:close(message)
        end
    end

    Trapper:wrap(Guard.wrap("testing the connection", function()
        message = WaitingMessage.new(_("Testing the connection to the sites FetchAnna uses..."))
        UIManager:show(message)
        UIManager:forceRePaint()
        HttpUtil.setTrapWidget(message)

        local results = {}
        for __, url in ipairs(testUrls()) do
            local body, err, status = HttpUtil.getBody(url)
            if err == HttpUtil.CANCELLED then
                LogUtil.info("the connection test was called off at", LogUtil.site(url))
                table.insert(results, "(called off at " .. LogUtil.site(url) .. ")")
                break
            end
            table.insert(results, result(url, body, err, status))
        end
        closeMessage()
        LogUtil.info("tested the connection:", table.concat(results, "; "))
        Diagnostics.show(results)
    end, function(err)
        closeMessage()
        Guard.say(err)
    end))
end

return Diagnostics
