local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local util = require("util")
local PluginShare = require("pluginshare")
local Trapper = require("ui/trapper")
local ConfirmBox = require("ui/widget/confirmbox")
local LogUtil = require("fetchanna.util.logutil")
local DownloadProgress = require("fetchanna.ui.downloadprogress")
local DownloadPrompt = require("fetchanna.ui.downloadprompt")
local HttpUtil = require("fetchanna.util.httputil")
local FileUtil = require("fetchanna.util.fileutil")
local CurlUtil = require("fetchanna.util.curlutil")
local HttpDownload = require("fetchanna.util.httpdownload")
local FileCheck = require("fetchanna.util.filecheck")
local ProxyUtil = require("fetchanna.util.proxyutil")
local Sources = require("fetchanna.api.sources")
local CoverCache = require("fetchanna.cache.covercache")
local Errors = require("fetchanna.util.errors")
local Guard = require("fetchanna.util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- Downloads books in the background from the site they were found on (see Sources).
local Downloader = {}
Downloader.active_downloads = {}
-- Downloads started this session, to list them in order (see getActiveDownloads).
local downloads_started = 0

local DOWNLOAD_POLL_INTERVAL = 0.5
-- Seconds without data before a download is given up on.
local DOWNLOAD_STALL_TIME = 30
-- Seconds without data before the progress says it has stalled, as curl may take a while to retry.
local STALL_NOTICE_TIME = 10
-- curl exit codes that mean the download server failed, not e.g. full storage: not found, no connection, stalled, empty
-- reply, broken connection.
local SERVER_FAILURES = { [6] = true, [7] = true, [28] = true, [52] = true, [56] = true }
-- What a server answers a link it no longer takes with, e.g. an expired signed link. Where links expire (see
-- LINKS_EXPIRE in Sources), another can be asked for.
local LINK_REFUSED = { [401] = true, [403] = true, [404] = true, [410] = true }
-- Room kept free besides the book, as a full disk stops KOReader saving its settings.
local SPARE_BYTES = 1024 * 1024
-- How often a download waiting for Wi-Fi checks for it, as KOReader doesn't announce it on every device.
local RECONNECT_POLL_INTERVAL = 2

-- Returns the md5 (lower case) and bytes the site listed for the file (see findDownloadLink in Sources), each only when
-- valid, to check the download against.
local function expectedFile(listed)
    listed = type(listed) == "table" and listed or {}
    local md5 = type(listed.md5) == "string" and #listed.md5 == 32 and listed.md5:match("^%x+$")
    local bytes = tonumber(listed.bytes)
    return {
        md5 = md5 and md5:lower() or nil,
        bytes = bytes and bytes > 0 and bytes or nil,
    }
end

-- Keeps the device awake while books download, as sleep turns Wi-Fi off: no standby, and no suspending by KOReader's
-- AutoSuspend or a Kindle's screensaver. Each is put back after the last download, unless something else (e.g. AutoTurn
-- or Keep alive) has changed it since.
local awake
local function keepAwake()
    if awake then
        return
    end
    awake = { pause_auto_suspend = PluginShare.pause_auto_suspend }
    if UIManager.preventStandby then
        UIManager:preventStandby()
    end
    PluginShare.pause_auto_suspend = true
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
        awake.screensaver_prevented = true
    end
    LogUtil.info("keeping the device awake while books download")
end
local function allowSleep()
    if not awake then
        return
    end
    if UIManager.allowStandby then
        UIManager:allowStandby()
    end
    if PluginShare.pause_auto_suspend == true then
        PluginShare.pause_auto_suspend = awake.pause_auto_suspend
    end
    if awake.screensaver_prevented and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    awake = nil
    LogUtil.info("letting the device sleep again, as no books are downloading")
end

-- Tracks a started download (see active_downloads), keeping the device awake while there are any.
function Downloader:track(id, download)
    downloads_started = downloads_started + 1
    download.order = downloads_started
    self.active_downloads[id] = download
    keepAwake()
end

-- Stops tracking a download, letting the device sleep once none are left.
function Downloader:untrack(id)
    self.active_downloads[id] = nil
    if next(self.active_downloads) == nil then
        allowSleep()
    end
end

-- Starts the download in the background with curl, or with KOReader's own HTTP where curl can't (see
-- CurlUtil.canFetch), as on a Kobo with no curl (KindleFetch #63). Returns whether it started, and why not.
local function startCurl(transfer)
    local pid, exit_file_or_err
    if CurlUtil.canFetch() then
        pid, exit_file_or_err = CurlUtil.startDownload(transfer.download_url, transfer.part_path, nil, {
            headers_file = transfer.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            -- Carry on from where a stalled download got to.
            resume = transfer.resume,
            -- Only if the file is still the same one (see resumeTransfer).
            if_range = transfer.resume and transfer.if_range or nil,
            -- The link is itself a secret (see SECRET_LINKS in Sources).
            sensitive = transfer.sensitive,
        })
    else
        -- From the beginning, as KOReader's HTTP can't resume.
        LogUtil.info("downloading with KOReader's own HTTP, as curl can't")
        pid, exit_file_or_err = HttpDownload.start(transfer.download_url, transfer.part_path, {
            headers_file = transfer.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            proxy = ProxyUtil.get(),
            sensitive = transfer.sensitive,
        })
    end
    if not pid then
        return false, exit_file_or_err
    end
    transfer.pid, transfer.exit_file = pid, exit_file_or_err
    return true
end

-- Stops the download while the device sleeps or Wi-Fi is off, so it doesn't fail as if the site had. What has arrived
-- is kept (see resumeTransfer).
local function pauseTransfer(transfer, why)
    -- Not once it has all arrived and is being checked (see checkBook).
    if transfer.paused or transfer.checksum or not transfer.download_url or transfer.progress_widget.cancelled then
        return
    end
    transfer.paused = true
    -- Its exit code isn't looked at.
    CurlUtil.killPid(transfer.pid)
    HttpDownload.collect(transfer.pid)
    transfer.pid = nil
    LogUtil.info(
        string.format(
            "pausing the download of %q at %d bytes, as %s",
            transfer.book.title,
            FileUtil.getSize(transfer.part_path),
            why
        )
    )
    transfer.progress_widget:update(transfer.progress_widget.percentage or 0, _("Waiting for Wi-Fi..."))
end

-- Carries on once the device is awake and connected, from what had arrived, with the same link. Asking for another can
-- count as another fast download.
-- It only resumes when the server gave a validator showing the file is unchanged (see CurlUtil.getValidator). Otherwise
-- what arrived could be joined to the rest of another file, so it starts again from the beginning.
-- Returns false when curl couldn't be restarted and the download has failed.
local function resumeTransfer(transfer)
    if not transfer.paused then
        return true
    end
    LogUtil.info(string.format("carrying on with the download of %q, now Wi-Fi is back", transfer.book.title))
    transfer.paused = nil
    transfer.resume = true
    transfer.if_range = CurlUtil.getValidator(transfer.headers_file)
    if not transfer.if_range and (FileUtil.getSize(transfer.part_path) or 0) > 0 then
        LogUtil.info("starting it again from the beginning, as the server didn't say what shows the file is the same")
        FileUtil.removeFile(transfer.part_path)
        transfer.last_size = nil
    end
    transfer.quiet_polls = 0
    FileUtil.removeFile(transfer.exit_file)
    local started, err = startCurl(transfer)
    if not started then
        LogUtil.warn("could not start curl to carry on with the download:", err)
        FileUtil.removeFile(transfer.part_path)
        transfer.on_finish(false, err)
        return false
    end
    transfer.progress_widget:update(
        transfer.progress_widget.percentage or 0,
        T(_("Waiting for %1..."), Sources[transfer.book.source].NAME)
    )
    return true
end

local pollDownload

-- Checks on the download again in seconds (see pollDownload), abandoning it if that goes wrong.
local function pollIn(seconds, transfer)
    Guard.scheduleIn(seconds, "checking on a download", function()
        pollDownload(transfer)
    end, transfer.abandon)
end

-- Tries again after a download failed, or what arrived wasn't the book (bad_book). From the beginning when the site
-- can't resume, or with another link when the server failed and the site gives one. Returns whether it's being tried
-- again.
local function retry(transfer, exit_code, http_status, bad_book)
    if bad_book then
        -- It can't be resumed.
        FileUtil.removeFile(transfer.part_path)
    elseif exit_code == 33 and transfer.resume then
        LogUtil.info("downloading the book again from the beginning, as the site can't carry on from where it stopped")
        transfer.resume = false
        FileUtil.removeFile(transfer.part_path)
        local started, spawn_err = startCurl(transfer)
        if not started then
            LogUtil.warn("could not start curl to try again:", spawn_err)
            FileUtil.removeFile(transfer.part_path)
            transfer.on_finish(false, spawn_err or _("download failed and could not be tried again"))
            return true
        end
        pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
        return true
    end

    local refused = transfer.links_expire and http_status and LINK_REFUSED[http_status]
    if
        transfer.relink
        and (bad_book or refused or http_status and http_status >= 500 or SERVER_FAILURES[exit_code])
    then
        LogUtil.info(
            "asking for another download link, as the server the link went to",
            bad_book and "didn't send the book" or refused and "no longer takes it" or "failed"
        )
        transfer.relink()
        return true
    end
    return false
end

-- What arrived isn't the book (see checkBook): tries again (see retry), or fails with err.
local function rejectBook(transfer, err)
    if not retry(transfer, nil, nil, true) then
        transfer.on_finish(false, err)
    end
end

-- Works out the md5 of what arrived, a piece at a time, as a large book takes a while, then checks it against the one
-- listed.
local function pollChecksum(transfer)
    local book, checksum = transfer.book, transfer.checksum
    if transfer.progress_widget.cancelled then
        LogUtil.info(string.format("download of %q cancelled while checking it", book.title))
        checksum:close()
        transfer.checksum = nil
        FileUtil.removeFile(transfer.part_path)
        transfer.on_finish(false, Errors.CANCELLED)
        return
    end

    local md5, err = checksum:step()
    if md5 == nil then
        Guard.nextTick("checking a downloaded book", function()
            pollChecksum(transfer)
        end, transfer.abandon)
        return
    end
    transfer.checksum = nil
    if not md5 then
        -- Not a failure to report, as the book has arrived.
        LogUtil.warn(string.format("could not read %q to check it: %s", book.title, tostring(err)))
        transfer.on_finish(true)
    elseif md5 ~= transfer.expected.md5 then
        LogUtil.warn(
            string.format("%q has the md5 %s, rather than the %s listed", book.title, md5, transfer.expected.md5)
        )
        rejectBook(transfer, _("the file that downloaded doesn't match the one listed, and may be damaged"))
    else
        LogUtil.info("it has the md5 listed")
        transfer.on_finish(true)
    end
end

-- Checks that what arrived is the book, not e.g. a web page saying the site is busy: by how it starts, then by its md5
-- where the site lists one.
local function checkBook(transfer)
    local book = transfer.book
    -- The download has finished, so there's nothing for Cancel to stop. This collects KOReader's own process, where
    -- that downloaded it.
    HttpDownload.collect(transfer.pid)
    transfer.pid = nil

    local problem, start = FileCheck.problem(transfer.part_path, book.file_type)
    if problem == "web page" then
        LogUtil.warn(string.format("a web page arrived in place of %q: %s", book.title, start))
        rejectBook(
            transfer,
            T(_("%1 sent a web page rather than the book, try again later"), Sources[book.source].NAME)
        )
        return
    elseif problem then
        LogUtil.warn(string.format("what arrived of %q isn't %s: %s", book.title, book.file_type, start))
        rejectBook(transfer, T(_("the file that downloaded isn't the %1 it should be"), book.file_type:upper()))
        return
    end

    local checksum = transfer.expected.md5 and FileCheck.md5(transfer.part_path)
    if not checksum then
        transfer.on_finish(true)
        return
    end
    transfer.checksum = checksum
    transfer.progress_widget:update(1, _("Checking the book..."))
    Guard.nextTick("checking a downloaded book", function()
        pollChecksum(transfer)
    end, transfer.abandon)
end

-- Checks on a download until it finishes, showing progress. transfer.on_finish gets whether the book downloaded, and
-- what went wrong.
function pollDownload(transfer)
    local book, part_path, progress_widget = transfer.book, transfer.part_path, transfer.progress_widget
    if progress_widget.cancelled then
        LogUtil.info(
            string.format("download of %q cancelled at %d bytes", book.title, FileUtil.getSize(part_path) or 0)
        )
        CurlUtil.killPid(transfer.pid)
        FileUtil.removeFile(part_path)
        transfer.on_finish(false, Errors.CANCELLED)
        return
    end

    -- Waiting for Wi-Fi (see pauseTransfer), which is checked for here too, as KOReader doesn't announce it on every
    -- device.
    if transfer.paused then
        if not transfer.sleeping and NetworkMgr:isConnected() and not resumeTransfer(transfer) then
            return
        end
        pollIn(transfer.paused and RECONNECT_POLL_INTERVAL or DOWNLOAD_POLL_INTERVAL, transfer)
        return
    end

    local bytes_downloaded = FileUtil.getSize(part_path)
    -- Counts checks that found nothing new, to tell when the download stalls. Not timed by the clock, which can be put
    -- back or jump forward.
    if bytes_downloaded ~= transfer.last_size then
        transfer.last_size = bytes_downloaded
        transfer.quiet_polls = 0
    else
        transfer.quiet_polls = (transfer.quiet_polls or 0) + 1
    end
    local stalled = bytes_downloaded > 0 and transfer.quiet_polls * DOWNLOAD_POLL_INTERVAL >= STALL_NOTICE_TIME

    -- curl writes the headers, with the book's size, before the book starts to arrive.
    if not transfer.total_size and bytes_downloaded > 0 then
        transfer.total_size = CurlUtil.getDownloadSize(transfer.headers_file)
        if transfer.total_size then
            LogUtil.info("the file is", transfer.total_size, "bytes")
            -- Stop now if it won't fit, rather than once the device is full.
            local short = Downloader.lackOfRoom(part_path, transfer.total_size - bytes_downloaded)
            if short then
                LogUtil.warn(string.format("%q won't fit on the device: %d bytes more are needed", book.title, short))
                CurlUtil.killPid(transfer.pid)
                HttpDownload.collect(transfer.pid)
                FileUtil.removeFile(part_path)
                transfer.on_finish(
                    false,
                    T(
                        _("there isn't room for the book on the device: %1 MB more is needed"),
                        string.format("%.1f", short / (1024 * 1024))
                    )
                )
                return
            end
        end
    end
    local total_size = transfer.total_size

    -- Cap at 99% while in progress.
    if total_size and total_size > 0 and bytes_downloaded <= total_size then
        local percentage = math.min(bytes_downloaded / total_size, 0.99)
        progress_widget:update(
            percentage,
            stalled and T(_("Stalled at %1%, retrying..."), math.floor(percentage * 100))
                or string.format(
                    "%d%% · %.1f / %.1f MB",
                    math.floor(percentage * 100),
                    bytes_downloaded / (1024 * 1024),
                    total_size / (1024 * 1024)
                )
        )
    elseif bytes_downloaded > 0 then
        -- The size wasn't known, or was wrong.
        local megabytes = bytes_downloaded / (1024 * 1024)
        progress_widget:update(
            progress_widget.percentage or 0,
            stalled and T(_("Stalled at %1 MB, retrying..."), string.format("%.1f", megabytes))
                or string.format("%.1f MB", megabytes)
        )
    end

    LogUtil.debug("download progress", {
        title = book.title,
        id = book.id,
        bytes_downloaded = bytes_downloaded,
        total_size = total_size,
    })

    -- Check again if curl has stopped, as it may have finished between the two checks.
    local exit_code = CurlUtil.getExitCode(transfer.exit_file)
    if not exit_code and not CurlUtil.isPidRunning(transfer.pid) then
        exit_code = CurlUtil.getExitCode(transfer.exit_file)
    end
    if exit_code then
        local final_size = FileUtil.getSize(part_path)

        local download = Downloader.active_downloads[book.id]
        local seconds = download and download.started and os.time() - download.started or 0
        if exit_code == 0 and final_size and final_size > 0 then
            -- The size the site listed, or said when it last sent the file (a retry can differ from the first). curl
            -- doesn't always notice a site stopping partway.
            total_size = CurlUtil.getDownloadSize(transfer.headers_file) or total_size
            local expected_size = transfer.expected.bytes or total_size
            if expected_size and final_size < expected_size then
                LogUtil.warn(
                    string.format("only %d of the %d bytes of %q arrived", final_size, expected_size, book.title)
                )
                -- curl's exit code for that, when it does notice.
                exit_code = 18
            else
                progress_widget:update(1, "100%")
                LogUtil.info(
                    string.format(
                        "downloaded %q: %d bytes%s in %ds",
                        book.title,
                        final_size,
                        expected_size and expected_size ~= final_size and " (expected " .. expected_size .. ")" or "",
                        seconds
                    )
                )
                checkBook(transfer)
                return
            end
        end

        -- The site's HTTP error, when that's why curl gave up.
        local http_status = exit_code == 22 and CurlUtil.getDownloadStatus(transfer.headers_file) or nil
        if http_status and http_status < 400 then
            http_status = nil
        end
        LogUtil.warn(
            string.format(
                "download of %q from %s failed after %ds: curl exit code %d (%s%s), %d of %s bytes",
                book.title,
                LogUtil.site(transfer.download_url),
                seconds,
                exit_code,
                exit_code == 0 and "empty file" or CurlUtil.getErrorMeaning(exit_code),
                http_status and ", HTTP " .. http_status or "",
                final_size or 0,
                tostring(total_size or "unknown")
            )
        )

        -- Wi-Fi went off, not the site, and KOReader didn't say so. Trying again now can't work, so wait and carry on
        -- from what has arrived.
        if SERVER_FAILURES[exit_code] and not NetworkMgr:isConnected() then
            -- curl has stopped, so there's nothing to stop.
            transfer.pid = nil
            pauseTransfer(transfer, "Wi-Fi is off")
            pollIn(RECONNECT_POLL_INTERVAL, transfer)
            return
        end

        if retry(transfer, exit_code, http_status) then
            return
        end

        FileUtil.removeFile(part_path)
        local err = exit_code == 0 and _("download produced empty file") or CurlUtil.explainExitCode(exit_code)
        if http_status then
            -- Its servers failing, as they do when very busy, not e.g. a missing book.
            err = http_status >= 500
                    and T(
                        _("%1 is too busy to send books right now, try again in a few minutes"),
                        Sources[book.source].NAME
                    )
                or T(_("%1 (HTTP %2)"), err, http_status)
        end
        transfer.on_finish(false, err)
        return
    end

    -- curl stopped without leaving an exit code.
    if not CurlUtil.isPidRunning(transfer.pid) then
        LogUtil.warn(
            string.format(
                "curl stopped without reporting back while downloading %q, at %d bytes",
                book.title,
                bytes_downloaded or 0
            )
        )
        FileUtil.removeFile(part_path)
        transfer.on_finish(false, _("download process ended unexpectedly"))
        return
    end

    pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
end

-- failed_url is the link that failed, when asking for another (see transfer.relink). hidden keeps the progress hidden
-- when trying again.
function Downloader:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
    local source = Sources[book.source]
    LogUtil.info(
        string.format(
            "downloading %q (%s, %s, id %s) to %s%s",
            book.title,
            tostring(book.file_type),
            tostring(book.file_size),
            tostring(book.id),
            filepath,
            retrying and ", after looking its link up again" or ""
        )
    )

    -- What's known about the download as it goes. The book downloads to a .part file beside its destination and is
    -- moved once complete, so half a book never looks whole, and a book being replaced is kept until then.
    local transfer = {
        book = book,
        part_path = filepath .. ".part",
        resume = true,
        expected = {},
    }
    local part_path = transfer.part_path

    local progress_widget = DownloadProgress.new(book.display_title or book.title, function()
        if transfer.pid then
            CurlUtil.killPid(transfer.pid)
        end
    end, hidden)
    transfer.progress_widget = progress_widget

    progress_widget:show()
    -- This can mean trying several sites.
    progress_widget:update(0, _("Finding a download link..."))
    UIManager:forceRePaint()

    Downloader:track(book.id, {
        book = book,
        filepath = filepath,
        part_path = part_path,
        progress_widget = progress_widget,
        callback = callback,
        started = os.time(),
    })

    -- Looks the link up without blocking KOReader, where curl is used (see HttpUtil), as it can mean trying several
    -- sites, and lets Cancel call it off. Where it blocks, Cancel and Hide can't be tapped, as the taps would only
    -- arrive afterwards. An error is passed on, not left to Trapper, which would leave the progress showing.
    local can_cancel = HttpUtil.canCancel()
    if not can_cancel then
        progress_widget:setCancellable(false)
        UIManager:forceRePaint()
    end
    HttpUtil.setTrapWidget(progress_widget)
    local looked_up, download_url, lookup_err, mirror_failed, listed =
        Guard.pcall("looking up the download link", source.findDownloadLink, book, retrying, failed_url)
    HttpUtil.setTrapWidget(nil)
    progress_widget.dismiss_callback = nil
    if not can_cancel then
        progress_widget:setCancellable(true)
    end
    if not looked_up then
        download_url, lookup_err, mirror_failed, listed = nil, Errors.UNEXPECTED, false, nil
    end

    if not download_url then
        progress_widget:close()
        Downloader:untrack(book.id)

        if lookup_err == HttpUtil.CANCELLED then
            LogUtil.info(string.format("download of %q cancelled while looking up its link", book.title))
            callback(false, Errors.CANCELLED)
            return
        end
        LogUtil.warn("found no download link:", lookup_err)
        -- Look the sites up again if any failed, in case they've moved, and try once more.
        if not retrying and mirror_failed then
            return Downloader:_startDownload(book, filepath, callback, true, nil, not progress_widget.is_visible)
        end

        callback(false, lookup_err)
        return
    end
    transfer.download_url = download_url
    transfer.expected = expectedFile(listed)
    -- See Sources.
    transfer.sensitive = source.SECRET_LINKS or nil
    transfer.links_expire = source.LINKS_EXPIRE or nil

    -- curl writes the headers it's sent, which give the book's size.
    local headers_file = CurlUtil.createHeadersFile()
    transfer.headers_file = headers_file
    Downloader.active_downloads[book.id].headers_file = headers_file
    -- Stops the download and cleans up after an error in FetchAnna while checking on it (see Guard).
    transfer.abandon = function(err)
        -- Except once it has finished, when handling the book went wrong: it did download, and there's nothing to stop.
        if transfer.finished then
            return
        end
        if transfer.checksum then
            transfer.checksum:close()
        end
        CurlUtil.killPid(transfer.pid)
        HttpDownload.collect(transfer.pid)
        FileUtil.removeFile(part_path)
        FileUtil.removeFile(headers_file)
        progress_widget:close()
        Downloader:untrack(book.id)
        callback(false, err)
    end
    Downloader.active_downloads[book.id].transfer = transfer
    transfer.on_finish = function(ok, err)
        transfer.finished = true
        progress_widget:close()
        Downloader:untrack(book.id)
        FileUtil.removeFile(headers_file)
        -- Where KOReader's own process downloaded it, not curl.
        HttpDownload.collect(transfer.pid)
        if ok and not os.rename(part_path, filepath) then
            LogUtil.warn("could not move the downloaded book from", part_path, "to", filepath)
            FileUtil.removeFile(part_path)
            ok, err = false, _("could not save the book")
        end
        UIManager:forceRePaint()
        callback(ok, err, filepath)
    end
    -- The site's links each go to one of its servers, so it can give one more link when that server fails (see
    -- pollDownload).
    if source.NEW_LINK_WHEN_SERVER_FAILS and not retrying then
        transfer.relink = function()
            progress_widget:close()
            Downloader:untrack(book.id)
            FileUtil.removeFile(headers_file)
            FileUtil.removeFile(part_path)
            UIManager:forceRePaint()
            -- Looked up without blocking KOReader, as when the download started.
            self:_startDownloadInBackground(
                book,
                filepath,
                callback,
                true,
                transfer.download_url,
                not progress_widget.is_visible
            )
        end
    end

    -- Remove what's left of an earlier download with the same name. It could be another book, so curl mustn't resume
    -- from it.
    FileUtil.removeFile(part_path)

    local started, spawn_err = startCurl(transfer)
    if not started then
        LogUtil.warn("could not start curl to download:", spawn_err)
        FileUtil.removeFile(headers_file)
        progress_widget:close()
        Downloader:untrack(book.id)
        callback(false, spawn_err or Errors.START_FAILED)
        return
    end

    -- It can take a few seconds, sometimes many more, before the book starts to arrive.
    progress_widget:update(0, T(_("Waiting for %1..."), source.NAME))
    pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
end

-- Starts the download without blocking KOReader while the link is looked up, and reports an error in FetchAnna
-- meanwhile (see Guard).
function Downloader:_startDownloadInBackground(book, filepath, callback, retrying, failed_url, hidden)
    Trapper:wrap(Guard.wrap("starting the download of " .. tostring(book.title), function()
        self:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
    end, function(err)
        local download = Downloader.active_downloads[book.id]
        if download and download.transfer then
            download.transfer.abandon(err)
            return
        end
        if download then
            download.progress_widget:close()
            Downloader:untrack(book.id)
        end
        callback(false, err)
    end))
end

-- Returns why a book can't be downloaded to filepath, or nil when it can. Its folder is missing (deleted, or on a
-- removed SD card) or can't be written to, or another book is downloading to the same name: they'd share a .part file,
-- and one would be saved as the other.
function Downloader:cantDownloadTo(filepath)
    local folder, name = filepath:match("^(.*)/([^/]*)$")
    folder = folder ~= "" and folder or "/"
    local ok, err = FileUtil.checkWritableDir(folder)
    if not ok then
        LogUtil.warn("can't download to", folder, "as", err)
        return T(_("books can't be saved in %1, as %2, so choose another folder"), folder, err)
    end
    local taken = false
    for __, download in pairs(self.active_downloads) do
        taken = taken or download.filepath == filepath
    end
    if taken then
        LogUtil.warn("another book is already downloading to", filepath)
        return T(
            _("another book is already downloading as %1, so wait for it to finish, or choose another folder"),
            name
        )
    end
end

-- open_existing, where given, is called with the path of a book that's already there, when the user chooses to read it
-- instead.
function Downloader:downloadBook(book, filepath, callback, open_existing)
    callback = callback or function() end

    -- Show the progress of a book that's already downloading, in case it was hidden.
    if self:showDownload(book.id) then
        return
    end

    -- Get the cover in the background. The prompt shows a placeholder until it arrives.
    if book.image_url and not CoverCache:cacheExists(book.id) then
        LogUtil.debug("downloading book cover", {
            title = book.title,
            id = book.id,
        })
        CoverCache:downloadMultiple({ book }, 1)
    end

    -- The prompt lets the user choose the folder and confirm.
    local prompt = DownloadPrompt.new(book, filepath, function(confirmed_filepath)
        local function start()
            -- Checked before the link is looked up, which can use up a fast download.
            local err = self:cantDownloadTo(confirmed_filepath)
            if err then
                callback(false, err)
                return
            end
            -- Turns Wi-Fi on first if needed, as KOReader is set up to. KOReader says so itself if it can't connect.
            NetworkMgr:runWhenConnected(function()
                self:_startDownloadInBackground(book, confirmed_filepath, callback, false)
            end)
        end

        if not FileUtil.isValidFile(confirmed_filepath) then
            start()
            return
        end

        -- Ask before downloading over a book that's already there, which may be another edition, as KOReader does for
        -- its own downloads.
        LogUtil.info("asking before downloading over", confirmed_filepath)
        UIManager:show(ConfirmBox:new {
            text = T(_("%1 already exists."), confirmed_filepath),
            ok_text = _("Overwrite"),
            ok_callback = start,
            other_buttons = open_existing and {
                {
                    {
                        text = _("Read existing book"),
                        callback = function()
                            open_existing(confirmed_filepath)
                        end,
                    },
                },
            },
        })
    end)

    prompt:show()
end

-- Returns how many more bytes of room are needed to save bytes more to path, with SPARE_BYTES kept free. nil when
-- there's room, or the free space can't be told.
function Downloader.lackOfRoom(path, bytes)
    if not util.diskUsage or not bytes or bytes <= 0 then
        return nil
    end
    local folder = path:match("^(.*)/[^/]*$")
    local ok, usage = pcall(util.diskUsage, folder ~= "" and folder or "/")
    local available = ok and type(usage) == "table" and tonumber(usage.available)
    if not available then
        return nil
    end
    local needed = bytes + SPARE_BYTES - available
    return needed > 0 and needed or nil
end

-- Calls fn for each download that has started transferring, whose curl can be stopped and restarted.
local function eachTransfer(active_downloads, fn)
    for __, download in pairs(active_downloads) do
        if download.transfer then
            fn(download.transfer)
        end
    end
end

-- The device is going to sleep, which turns Wi-Fi off, so pause each download. KOReader sends this and the events below
-- through the plugin (see main.lua).
function Downloader:onSuspend()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = true
        pauseTransfer(transfer, "the device is going to sleep")
    end)
end

-- Carries on each download once the device is awake and connected (see pollDownload).
function Downloader:onResume()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = nil
        if transfer.paused and NetworkMgr:isConnected() then
            resumeTransfer(transfer)
        end
    end)
end

function Downloader:onNetworkDisconnected()
    eachTransfer(self.active_downloads, function(transfer)
        pauseTransfer(transfer, "Wi-Fi went off")
    end)
end

function Downloader:onNetworkConnected()
    eachTransfer(self.active_downloads, function(transfer)
        if transfer.paused and not transfer.sleeping then
            resumeTransfer(transfer)
        end
    end)
end

-- Shows a download's progress if it was hidden. Returns whether the book with that id is downloading.
function Downloader:showDownload(id)
    local active_download = self.active_downloads[id]
    if not active_download then
        return false
    end

    if not active_download.progress_widget.is_visible then
        active_download.progress_widget:toggleVisibility()
    end
    return true
end

-- Returns the downloads in progress, in the order they were started.
function Downloader:getActiveDownloads()
    local downloads = {}
    for id, download_info in pairs(self.active_downloads) do
        table.insert(downloads, {
            id = id,
            title = download_info.book.display_title or download_info.book.title,
            filepath = download_info.filepath,
            widget = download_info.progress_widget,
            order = download_info.order or 0,
        })
    end
    table.sort(downloads, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.title < b.title
    end)
    return downloads
end

function Downloader:cancelAllDownloads()
    for id, download_info in pairs(self.active_downloads) do
        -- Stops curl straight away, as there may not be another poll to stop it (e.g. when exiting).
        download_info.progress_widget:cancel()
        FileUtil.removeFile(download_info.part_path)
        FileUtil.removeFile(download_info.headers_file)
    end
    self.active_downloads = {}
    allowSleep()
end

return Downloader
