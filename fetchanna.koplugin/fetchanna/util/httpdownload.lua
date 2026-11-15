local ffiutil = require("ffi/util")
local http = require("socket.http")
local socketutil = require("socketutil")
local CurlUtil = require("fetchanna.util.curlutil")
local FileUtil = require("fetchanna.util.fileutil")
local LogUtil = require("fetchanna.util.logutil")
local Guard = require("fetchanna.util.guard")
local _ = require("gettext")

-- Downloads with KOReader's own HTTP where curl can't (see CurlUtil.canFetch): no curl, as on a Kobo (KindleFetch #63),
-- or a Kindle whose curl is too old.
-- Each runs in its own process and leaves what a curl download leaves: the file as it arrives, a headers file and
-- curl's exit code. So what follows and stops curl's downloads handles these too.
local HttpDownload = {}

-- Seconds between checks on a process waiting to be collected.
local COLLECT_INTERVAL = 1

-- Returns the exit code curl would have given for a KOReader HTTP error. The caller logs the error, as curl may have no
-- code for it.
local function exitCode(err)
    return CurlUtil.exitCodeFor(err) or 56
end

-- Most redirects followed for a link with a secret in it (see download).
local MAX_SENSITIVE_REDIRECTS = 5

-- Returns where a redirect from url to location goes, or nil unless that's HTTPS, as with curl's --proto-redir.
local function httpsRedirect(url, location)
    if type(location) ~= "string" then
        return nil
    end
    if location:find("^/[^/]") or location == "/" then
        local site = url:match("^(https://[^/]+)")
        return site and site .. location
    end
    return location:lower():find("^https://[^/]") and location or nil
end

-- Requests url and writes the body to path. Returns what pcall(http.request, ...) returned.
-- With opts.sensitive (the link has a secret in it), no Referer is sent and redirects aren't followed here: download
-- follows them itself, and only to HTTPS.
local function request(url, path, opts)
    local file, open_err = io.open(path, "wb")
    if not file then
        LogUtil.warn("could not write", path, "to download to:", open_err)
        return nil, 23
    end
    local site = url:match("^(https?://[^/]+)")
    local requested, ok, code, headers, status_line = pcall(http.request, {
        url = url,
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
            -- As curl sends it. Library Genesis sends empty covers without one.
            ["Referer"] = not opts.sensitive and site and site .. "/" or nil,
        },
        sink = socketutil.file_sink(file),
        redirect = not opts.sensitive,
        proxy = opts.proxy,
    })
    if io.type(file) == "file" then
        file:close()
    end
    return requested, ok, code, headers, status_line
end

-- Downloads url to path, inside the download's process. Returns the exit code curl would have given. Writes the headers
-- to opts.headers_file, as curl -D does.
local function download(url, path, opts)
    -- Gives up once nothing has arrived for stall_time, with no limit on the whole download, as a book can be large.
    socketutil:set_timeout(opts.stall_time or 30, opts.max_time or -1)
    local requested, ok, code, headers, status_line = request(url, path, opts)
    local redirects = 0
    while
        opts.sensitive
        and requested
        and ok
        and type(code) == "number"
        and code >= 300
        and code < 400
        and type(headers) == "table"
        and headers.location
    do
        local location = httpsRedirect(url, headers.location)
        if not location or redirects >= MAX_SENSITIVE_REDIRECTS then
            socketutil:reset_timeout()
            FileUtil.removeFile(path)
            LogUtil.warn("not following a redirect from", LogUtil.site(url), "to", LogUtil.site(headers.location))
            -- curl's codes: 47 for too many redirects, 1 for one it isn't allowed to follow.
            return location and 47 or 1
        end
        redirects = redirects + 1
        url = location
        requested, ok, code, headers, status_line = request(url, path, opts)
    end
    socketutil:reset_timeout()
    if requested == nil and ok == 23 then
        return 23
    end

    if not requested or not ok then
        local err = requested and code or ok
        LogUtil.warn("KOReader's HTTP couldn't download from", LogUtil.site(url) .. ":", tostring(err))
        return exitCode(err)
    end
    if opts.headers_file then
        local length = type(headers) == "table" and headers["content-length"]
        FileUtil.writeFile(
            opts.headers_file,
            string.format(
                "%s\r\n%s\r\n",
                type(status_line) == "string" and status_line or "HTTP/1.1 " .. tostring(code),
                length and "content-length: " .. length .. "\r\n" or ""
            )
        )
    end
    -- curl -f exits with 22 for an HTTP error.
    if type(code) ~= "number" or code >= 400 then
        return 22
    end
    return 0
end

-- Runs fn in its own process. Returns the pid and exit file, or nil and why not. An exit code is saved even if fn
-- fails.
local function start(fn)
    local exit_file = CurlUtil.createExitFile()
    local pid, err = ffiutil.runInSubProcess(function()
        local ok, exit_code = pcall(fn, exit_file)
        if not ok then
            LogUtil.err("downloading with KOReader's HTTP went wrong:", tostring(exit_code))
            exit_code = 1
        end
        FileUtil.writeFile(exit_file, tostring(exit_code) .. "\n")
    end)
    if not pid then
        LogUtil.warn("could not start a process to download with KOReader's HTTP:", tostring(err))
        return nil, _("could not start downloading")
    end
    return pid, exit_file
end

-- Downloads download_url to filepath in the background, with opts as CurlUtil.startDownload's, plus opts.proxy. Starts
-- from the beginning, as KOReader's HTTP can't resume. Returns the pid and exit file, or nil and why not.
function HttpDownload.start(download_url, filepath, opts)
    opts = opts or {}
    LogUtil.debug("KOReader's HTTP downloading from", LogUtil.site(download_url), "to", filepath)
    return start(function()
        return download(download_url, filepath, opts)
    end)
end

-- Downloads each URL to the matching path in filepaths, in the background, one after another, as
-- CurlUtil.downloadMultiple does. Returns the pid, exit file and config file (whose results file gets each exit code as
-- it finishes), or nil, nil, nil and why not.
function HttpDownload.startMultiple(download_urls, filepaths, opts)
    opts = opts or {}
    local config_file = CurlUtil.createExitFile() .. ".config"
    local results_file = CurlUtil.getResultsFile(config_file)
    local pid, exit_file = start(function()
        local last_failure = 0
        for i, download_url in ipairs(download_urls) do
            local exit_code = download(download_url, filepaths[i], opts)
            if exit_code ~= 0 then
                last_failure = exit_code
                FileUtil.removeFile(filepaths[i])
            end
            local f = io.open(results_file, "a")
            if f then
                f:write(string.format("%d %s\n", exit_code, filepaths[i]))
                f:close()
            end
        end
        return last_failure
    end)
    if not pid then
        return nil, nil, nil, exit_file
    end
    return pid, exit_file, config_file
end

-- Collects a download's process once it has finished or been stopped. Otherwise KOReader keeps it as a zombie until it
-- closes. A curl download's process isn't KOReader's own to collect, and is reported as done straight away.
function HttpDownload.collect(pid)
    if not pid or ffiutil.isSubProcessDone(pid) then
        return
    end
    Guard.scheduleIn(COLLECT_INTERVAL, "collecting a download's process", function()
        HttpDownload.collect(pid)
    end, Guard.quiet)
end

return HttpDownload
