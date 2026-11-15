local LogUtil = require("fetchanna.util.logutil")
local ProxyUtil = require("fetchanna.util.proxyutil")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local FileUtil = require("fetchanna.util.fileutil")
local StringUtil = require("fetchanna.util.stringutil")
local VersionUtil = require("fetchanna.util.versionutil")
local Errors = require("fetchanna.util.errors")
local T = require("ffi/util").template
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Device = require("device")

local CurlUtil = {}

-- The curl CurlUpdater installs on a Kindle, whose own is too old to connect to Library Genesis and lacks later
-- security fixes.
CurlUtil.MIN_VERSION = "8.21.0"

-- FetchAnna's own, as removeLeftovers clears it at start-up. In a shared folder (KindleFetch's is settings/tmp/) other
-- plugins' files would go too.
local TMP_DIR = DataStorage:getSettingsDir() .. "/fetchanna_tmp/"
-- Seconds a page can stall before it's given up on. Library Genesis' sites have accepted a connection and never
-- answered.
local FETCH_STALL_TIME = 20
local CURL_ERRORS = {
    [1] = _("unsupported protocol"),
    [3] = _("malformed URL"),
    [5] = _("could not resolve proxy"),
    [6] = _("could not resolve host"),
    [7] = _("failed to connect to server"),
    [16] = _("HTTP/2 error"),
    [18] = _("partial file transfer (download interrupted)"),
    [19] = _("HTTP range request error"),
    [22] = _("HTTP error response"),
    [23] = _("failed writing downloaded data"),
    [26] = _("failed reading local data"),
    [27] = _("out of memory"),
    [28] = _("request timed out"),
    [33] = _("the site can't carry on from where the download stopped"),
    [35] = _("TLS/SSL connection failed"),
    [36] = _("transfer was stopped"),
    [37] = _("failed to open local file"),
    [47] = _("too many redirects"),
    [51] = _("the site's TLS certificate isn't for its address"),
    [52] = _("server returned an empty response"),
    [55] = _("failed sending network data"),
    [56] = _("failed receiving network data"),
    [58] = _("problem with the TLS client certificate"),
    [59] = _("couldn't use the TLS ciphers asked for"),
    [60] = _("TLS certificate verification failed"),
    [61] = _("unsupported TLS/SSL feature"),
    [67] = _("authentication failed"),
    [77] = _("problem reading the TLS certificates to check sites' against"),
    [78] = _("requested resource was not found"),
    [83] = _("TLS certificate issuer check failed"),
    [92] = _("HTTP/2 stream error"),
    -- From the shell, not curl, when it can't run curl or can't find it.
    [126] = _("curl can't be run on this device"),
    [127] = _("curl isn't installed on this device"),
}

local function ensureTmpDir()
    if lfs.attributes(TMP_DIR, "mode") ~= "directory" and not lfs.mkdir(TMP_DIR) then
        LogUtil.warn("could not create", TMP_DIR, "for curl's files")
    end
end

-- os.time() is in seconds, and a book and its cover can start in the same one, so temporary files are numbered too.
local tmp_files_created = 0
local function tmpFile(name, extension)
    ensureTmpDir()
    tmp_files_created = tmp_files_created + 1
    return string.format("%s%s_%d_%d%s", TMP_DIR, name, os.time(), tmp_files_created, extension)
end

-- Removes files left by downloads that were running when KOReader last closed. For start-up only, while nothing uses
-- them.
function CurlUtil.removeLeftovers()
    if lfs.attributes(TMP_DIR, "mode") ~= "directory" then
        return
    end

    local leftovers = {}
    for __, file in ipairs(FileUtil.listDir(TMP_DIR) or {}) do
        if file:find("^curl_download") then
            table.insert(leftovers, file)
        end
    end
    for __, file in ipairs(leftovers) do
        FileUtil.removeFile(TMP_DIR .. file)
    end
    if #leftovers > 0 then
        LogUtil.info("removed", #leftovers, "files left by earlier downloads")
    end
end

function CurlUtil.shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- Where running processes are listed. The tests change it.
CurlUtil.PROC_DIR = "/proc"

function CurlUtil.isPidRunning(pid)
    if not pid then
        return false
    end

    -- Checked twice a second, so read /proc instead of starting a shell to ask kill.
    local stat_file = io.open(string.format("%s/%d/stat", CurlUtil.PROC_DIR, pid), "r")
    if stat_file then
        local stat = stat_file:read("*l") or ""
        stat_file:close()
        -- A zombie isn't running.
        return stat:match(".*%)%s+(%a)") ~= "Z"
    end
    local self_stat = io.open(CurlUtil.PROC_DIR .. "/self/stat", "r")
    if self_stat then
        self_stat:close()
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

-- Stops a background download. Its shell passes the signal on to curl (see saveExitCode).
function CurlUtil.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

-- Returns the installed curl's first --version line, e.g. "curl 8.17.0 (arm-unknown-linux-musleabihf) libcurl/8.17.0
-- OpenSSL/3.5.4 zlib/1.3.1", or nil if there's no curl. Looked up once per session (see forgetVersion).
local curl_description, curl_protocols
local function describeCurl()
    if curl_description == nil then
        local pipe = io.popen("curl --version 2>/dev/null", "r")
        local output = pipe and pipe:read("*a") or ""
        if pipe then
            pipe:close()
        end
        -- false when there's no curl, so it isn't looked for again.
        curl_description = output:match("^[^\n]+") or false
        -- Its protocols, e.g. "dict file ftp http https". A curl built without TLS leaves https out.
        curl_protocols = output:match("\nProtocols:%s*([^\n]*)")
    end
    return curl_description or nil
end

-- Returns the installed curl's version, e.g. "8.17.0", or nil if there's no curl.
function CurlUtil.getVersion()
    local description = describeCurl()
    -- "curl X.Y.Z (platform) ..."
    return description and description:match("^curl%s+([%d%.]+)")
end

-- Whether the installed curl is at least min_version, e.g. "7.68.0", for options older ones fail on.
local function curlIsAtLeast(min_version)
    local version = VersionUtil.parseVersion(CurlUtil.getVersion())
    return version ~= nil and VersionUtil.compareVersions(version, VersionUtil.parseVersion(min_version)) >= 0
end

-- Cloudflare's DNS over HTTPS (see applyEncryptedDns), by IP address, so it isn't itself looked up with the network's
-- DNS.
local DOH_URL = "https://1.1.1.1/dns-query"
local DOH_MIN_VERSION = "7.62.0"

-- Whether curl can fetch pages, and ask for them compressed. Worked out once per session.
local can_fetch, can_decompress
local function checkCurl()
    if can_fetch ~= nil then
        return
    end

    local description = describeCurl()
    local version = VersionUtil.parseVersion(description and description:match("^curl%s+([%d%.]+)"))
    -- Every site is HTTPS, which a curl built without TLS can't fetch.
    local has_tls = not curl_protocols or (" " .. curl_protocols .. " "):find(" https ", 1, true) ~= nil
    -- On a Kindle, only once curl has been updated: the one it comes with can't connect to Library Genesis.
    can_fetch = version ~= nil
        and has_tls
        and (
            not Device:isKindle()
            or VersionUtil.compareVersions(version, VersionUtil.parseVersion(CurlUtil.MIN_VERSION)) >= 0
        )
    can_decompress = description ~= nil and description:find("zlib", 1, true) ~= nil
    LogUtil.info(
        "fetching pages with",
        can_fetch and "curl"
            or version and not has_tls and "KOReader, as curl can't make secure connections,"
            or "KOReader, as curl is missing or too old,",
        can_fetch and can_decompress and "compressed" or "uncompressed"
    )
end

-- Fetches pages with KOReader's own HTTP for the rest of the session, as curl failed to connect where it could (see
-- HttpUtil.requestBody).
function CurlUtil.stopFetching(why)
    checkCurl()
    if can_fetch then
        LogUtil.warn("fetching pages with KOReader from now on, as", why)
        can_fetch = false
    end
end

function CurlUtil.canFetch()
    checkCurl()
    return can_fetch
end

-- Looks curl up again when it's next needed, e.g. after a newer one is installed.
function CurlUtil.forgetVersion()
    curl_description = nil
    can_fetch, can_decompress = nil, nil
end

-- KOReader's own HTTP errors (luasocket and LuaSec), in lower case, with curl's exit code for each, so both report
-- failures alike.
local LUASOCKET_ERRORS = {
    { "host or service not provided, or not known", 6 },
    { "no address associated with hostname", 6 },
    { "name or service not known", 6 },
    { "temporary failure in name resolution", 6 },
    { "host not found", 6 },
    { "timeout", 28 },
    { "connection refused", 7 },
    { "no route to host", 7 },
    { "network is unreachable", 7 },
    { "certificate", 60 },
    { "wantread", 35 },
    { "wantwrite", 35 },
    { "handshake", 35 },
    { "ssl", 35 },
    { "tls", 35 },
    { "closed", 56 },
    { "connection reset", 56 },
}

-- Returns curl's exit code for an error from KOReader's own HTTP, or nil if curl has none for it.
function CurlUtil.exitCodeFor(luasocket_err)
    local lower = tostring(luasocket_err):lower()
    for __, known in ipairs(LUASOCKET_ERRORS) do
        if lower:find(known[1], 1, true) then
            return known[2]
        end
    end
end

function CurlUtil.getErrorMeaning(exit_code)
    return CURL_ERRORS[exit_code] or T(_("(curl exit code %1)"), tostring(exit_code))
end

-- What a Kindle's own curl fails with when connecting to Library Genesis, which it's too old for.
local TLS_ERRORS = { [35] = true, [51] = true, [58] = true, [59] = true, [60] = true, [77] = true, [83] = true }
CurlUtil.OUTDATED_ERROR = Errors.OUTDATED_CURL

-- Whether err (as getErrorMeaning words it) was a failed secure connection, as when the device's clock is wrong.
function CurlUtil.isTlsFailure(err)
    for exit_code in pairs(TLS_ERRORS) do
        if err == CurlUtil.getErrorMeaning(exit_code) then
            return true
        end
    end
    return false
end

-- Whether this is a Kindle whose curl is older than the oldest known to connect to Library Genesis.
function CurlUtil.isOutdated()
    return Device:isKindle() and CurlUtil.getVersion() ~= nil and not curlIsAtLeast(CurlUtil.MIN_VERSION)
end

-- Returns what exit_code means. For a TLS failure on a Kindle whose curl is too old to connect to Library Genesis, that
-- and how to update it.
function CurlUtil.explainExitCode(exit_code)
    if TLS_ERRORS[exit_code] and CurlUtil.isOutdated() then
        return CurlUtil.OUTDATED_ERROR
    end
    return CurlUtil.getErrorMeaning(exit_code)
end

-- Returns the size of the file being sent, from the response headers. There are several responses after a redirect or a
-- resume.
function CurlUtil.parseContentLength(headers)
    -- From the last response that sent something: the file's, not a redirect's. nil when the file's doesn't say.
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        if block:match("^HTTP[/%d%.]+ 2%d%d") then
            -- The whole file's size, when only the rest of it was sent.
            local size = block:match("[Cc]ontent%-[Rr]ange:%s*bytes%s+%d+%-%d+/(%d+)")
                or block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
            file_size = tonumber(size)
        end
    end
    return file_size
end

-- Returns a file for curl to write a download's headers to (see downloadCommand).
function CurlUtil.createHeadersFile()
    local headers_file = tmpFile("curl_download", ".headers")
    FileUtil.removeFile(headers_file)

    return headers_file
end

-- Returns the size of the download, from the headers curl wrote, or nil if the site hasn't said. They're complete
-- before the file starts to arrive.
function CurlUtil.getDownloadSize(headers_file)
    local f = io.open(headers_file, "r")
    if not f then
        return nil
    end
    local headers = f:read("*a")
    f:close()

    return CurlUtil.parseContentLength(headers or "")
end

-- Returns the download's last HTTP status, from the headers curl wrote, or nil if the site hasn't answered.
function CurlUtil.getDownloadStatus(headers_file)
    local f = io.open(headers_file, "r")
    if not f then
        return nil
    end
    local headers = f:read("*a")
    f:close()

    local last_status
    for status in (headers or ""):gmatch("HTTP[/%d%.]+ (%d%d%d)") do
        last_status = tonumber(status)
    end
    return last_status
end

-- Returns a file to fetch a page into (see fetchCommand).
function CurlUtil.createPageFile()
    local page_file = tmpFile("curl_download", ".page")
    FileUtil.removeFile(page_file)

    return page_file
end

function CurlUtil.createExitFile()
    local exit_file = tmpFile("curl_download", ".exitcode")
    FileUtil.removeFile(exit_file)

    return exit_file
end

-- Returns curl's exit code once it has finished, or nil until then, including while the shell is still writing it.
function CurlUtil.getExitCode(exit_file)
    local exit_code_str = FileUtil.readFile(exit_file)
    local exit_code = exit_code_str and tonumber(exit_code_str)
    if not exit_code then
        return nil
    end
    FileUtil.removeFile(exit_file)
    return exit_code
end

-- Starts cmd in the background (see echoPid). Returns its pid, or nil and Errors.START_FAILED.
function CurlUtil.spawnCurlPid(cmd)
    local pipe = io.popen(cmd, "r")
    if not pipe then
        LogUtil.warn("could not start a shell to run curl")
        return nil, Errors.START_FAILED
    end

    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        LogUtil.warn("curl was started, but its pid wasn't given:", tostring(pid_str))
        return nil, Errors.START_FAILED
    end

    return pid
end

-- download_url is nil when it goes to curl in a config file instead (see downloadCommand).
function CurlUtil.getDownloadCMD(download_url, filepath)
    local cmd = string.format("curl -sL -f -o %s", CurlUtil.shellQuote(filepath))
    if download_url then
        cmd = cmd .. " " .. CurlUtil.shellQuote(download_url)
    end
    return cmd
end

-- Returns the validator a resume sends as If-Range (see downloadCommand's opts.if_range), so the rest only arrives if
-- the file is still the same: its ETag if strong, otherwise its Last-Modified. Returns nil where the server sent
-- neither, or can't send part of a file. A stopped download then starts again, as what arrived can't be shown to be
-- part of the same file.
function CurlUtil.getValidator(headers_file)
    local text = headers_file and FileUtil.readFile(headers_file)
    local headers = CurlUtil.parseHeaders(text)
    if (headers["accept-ranges"] or ""):lower():find("none", 1, true) then
        return nil
    end
    local etag = headers["etag"]
    if etag and etag:find('^"[^"]*"$') then
        return etag
    end
    local modified = headers["last-modified"]
    if modified and modified:find("%d%d:%d%d:%d%d") then
        return modified
    end
    return nil
end

function CurlUtil.pretendBrowser(curl_cmd)
    return curl_cmd .. " -A 'Mozilla/5.0'"
end

-- Sends the site as the Referer, like a browser. Library Genesis sends empty covers without one.
function CurlUtil.setReferer(curl_cmd, url)
    local site = tostring(url):match("^(https?://[^/]+)")
    if not site then
        return curl_cmd
    end
    return string.format("%s -e %s", curl_cmd, CurlUtil.shellQuote(site .. "/"))
end

function CurlUtil.enableRetry(curl_cmd, count, delay)
    return string.format("%s --retry %d --retry-delay %d", curl_cmd, count, delay)
end

function CurlUtil.setTimeout(curl_cmd, seconds)
    return string.format("%s --connect-timeout %d", curl_cmd, seconds)
end

-- Gives up once nothing has arrived for this many seconds.
function CurlUtil.abortWhenStalled(curl_cmd, seconds)
    return string.format("%s --speed-limit 1 --speed-time %d", curl_cmd, seconds)
end

function CurlUtil.dumpHeaders(curl_cmd, headers_file)
    return string.format("%s -D %s", curl_cmd, CurlUtil.shellQuote(headers_file))
end

function CurlUtil.enableParallel(curl_cmd, max_parallel)
    -- curl older than 7.66 has no --parallel and fails on it, so it downloads them one after another.
    if not curlIsAtLeast("7.66.0") then
        return curl_cmd
    end
    local cmd = string.format("%s --parallel --parallel-max %d", curl_cmd, max_parallel)
    -- Opens a connection per file at once. Library Genesis' sites never let them share one, and covers arrive in a
    -- third of the time.
    if curlIsAtLeast("7.68.0") then
        cmd = cmd .. " --parallel-immediate"
    end
    return cmd
end

-- Whether curl can look names up with encrypted DNS (see applyEncryptedDns).
function CurlUtil.canUseEncryptedDns()
    return CurlUtil.canFetch() and curlIsAtLeast(DOH_MIN_VERSION)
end

-- Returns curl_cmd with DNS over HTTPS, where the setting is on and curl can. A network's own DNS can be what blocks
-- the sites (KindleFetch #55).
function CurlUtil.applyEncryptedDns(curl_cmd)
    if FetchAnnaSettings:getEncryptedDns() and CurlUtil.canUseEncryptedDns() then
        return string.format("%s --doh-url %s", curl_cmd, DOH_URL)
    end
    return curl_cmd
end

-- Returns curl_cmd going through KOReader's HTTP proxy, where it's on, and the config file to remove once curl has read
-- it. The proxy can hold a password, so it goes in a config file, not on the command line, where any program on the
-- device can read it. Returns curl_cmd as it was without a proxy, or if the file can't be written.
function CurlUtil.applyProxy(curl_cmd)
    local proxy = ProxyUtil.get()
    if not proxy then
        return curl_cmd
    end
    local config_file = CurlUtil.createConfigFile({ { "proxy", proxy } })
    if not config_file then
        LogUtil.warn("could not give curl the proxy, so it's going without")
        return curl_cmd
    end
    return string.format("%s -K %s", curl_cmd, CurlUtil.shellQuote(config_file)), config_file
end

-- Returns a file of options for curl, for what mustn't be on its command line, where any program on the device can read
-- it. options is a list of names and values, e.g. { { "data", "password=..." } }. Returns nil when a value has a
-- control character in it, as a line break would end the option early.
function CurlUtil.createConfigFile(options)
    local lines = {}
    for __, option in ipairs(options) do
        local name, value = option[1], tostring(option[2])
        if value:find("%c") then
            return nil
        end
        table.insert(lines, string.format('%s = "%s"', name, (value:gsub('[\\"]', "\\%0"))))
    end

    local config_file = tmpFile("curl_download", ".config")
    local f = io.open(config_file, "w")
    if not f then
        return nil
    end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return config_file
end

-- Returns a command that has curl fetch a page into page_file, then print the HTTP status (000 if the site didn't
-- answer) and its exit code, e.g. "200 0". A page with an error status is kept, as what it says is useful.
-- answer_timeout and page_timeout are seconds. config_file gives curl more options, and is removed once curl has
-- finished, even if nothing is waiting any more. KOReader's HTTP proxy is used where it's on.
-- opts.follow_redirects = false has curl stop at a redirect. opts.headers_file has it write the response headers there.
-- url is nil when it's in the config file instead (as "url"), as it is when it has a secret in it, and then isn't sent
-- as the Referer either.
function CurlUtil.fetchCommand(url, page_file, answer_timeout, page_timeout, config_file, opts)
    checkCurl()
    opts = opts or {}

    local cmd =
        string.format("curl %s -o %s", opts.follow_redirects == false and "-s" or "-sL", CurlUtil.shellQuote(page_file))
    if url then
        cmd = cmd .. " " .. CurlUtil.shellQuote(url)
    end
    if opts.headers_file then
        cmd = CurlUtil.dumpHeaders(cmd, opts.headers_file)
    end
    if can_decompress then
        -- A page of search results is a tenth of the size compressed, and Library Genesis sends them slowly.
        cmd = cmd .. " --compressed"
    end
    cmd = CurlUtil.pretendBrowser(cmd)
    if url then
        cmd = CurlUtil.setReferer(cmd, url)
    end
    cmd = string.format("%s --connect-timeout %d --max-time %d", cmd, answer_timeout, page_timeout)
    cmd = CurlUtil.abortWhenStalled(cmd, FETCH_STALL_TIME)
    cmd = CurlUtil.applyEncryptedDns(cmd)
    -- Each config file curl is given, to remove once it has finished.
    local config_files = {}
    local proxy_config
    cmd, proxy_config = CurlUtil.applyProxy(cmd)
    if proxy_config then
        table.insert(config_files, CurlUtil.shellQuote(proxy_config))
    end
    if config_file then
        cmd = string.format("%s -K %s", cmd, CurlUtil.shellQuote(config_file))
        table.insert(config_files, CurlUtil.shellQuote(config_file))
    end
    if #config_files > 0 then
        return string.format(
            '(%s -w %s; exit_code=$?; rm -f %s; echo " $exit_code") 2>/dev/null',
            cmd,
            CurlUtil.shellQuote("%{http_code}"),
            table.concat(config_files, " ")
        )
    end

    return string.format('(%s -w %s; echo " $?") 2>/dev/null', cmd, CurlUtil.shellQuote("%{http_code}"))
end

-- Returns the last response's headers from what curl wrote, by lower-case name. One sent more than once (as Set-Cookie
-- is) has its values joined by ", ", as KOReader's own HTTP does.
function CurlUtil.parseHeaders(text)
    local last
    for block in ((text or "") .. "\r\n\r\n"):gmatch("(HTTP/[%d%.]+%s+%d%d%d.-)\r?\n\r?\n") do
        last = block
    end
    local headers = {}
    for name, value in (last or ""):gmatch("\n([%w%-]+):[ \t]*([^\r\n]*)") do
        name = name:lower()
        headers[name] = headers[name] and headers[name] .. ", " .. value or value
    end
    return headers
end

-- Returns the file downloadMultiple has curl write each transfer's result to.
function CurlUtil.getResultsFile(config_file)
    return config_file .. ".results"
end

-- Returns the exit code of each file downloadMultiple downloaded, by path.
function CurlUtil.getTransferResults(results_file)
    local results = {}
    local f = io.open(results_file, "r")
    if not f then
        return results
    end
    for line in f:lines() do
        local exit_code, path = line:match("^(%d+) (.+)$")
        if exit_code then
            results[path] = tonumber(exit_code)
        end
    end
    f:close()
    return results
end

-- Whether a file from downloadMultiple downloaded, by curl's own exit code when it gave no result per file.
function CurlUtil.isTransferComplete(results, filepath, exit_code)
    if next(results) then
        return results[filepath] == 0 and FileUtil.getSize(filepath) > 0
    end
    return exit_code == 0 and FileUtil.getSize(filepath) > 0
end

-- Returns cmd wrapped in a shell that saves its exit code to exit_file. A background download is stopped by the shell's
-- pid (see killPid), so the shell passes a kill on to cmd and waits for it before saving the code. config_files, one or
-- a list, are removed once cmd has finished.
function CurlUtil.saveExitCode(cmd, exit_file, config_files)
    if type(config_files) ~= "table" then
        config_files = { config_files }
    end
    local quoted = {}
    for i = 1, table.maxn(config_files) do
        if config_files[i] then
            table.insert(quoted, CurlUtil.shellQuote(config_files[i]))
        end
    end
    local command = string.format(
        "(trap 'kill $c 2>/dev/null' TERM; %s & c=$!; wait $c; s=$?; "
            .. "if kill -0 $c 2>/dev/null; then wait $c; s=$?; fi; %secho $s > %s)",
        cmd,
        #quoted > 0 and string.format("rm -f %s; ", table.concat(quoted, " ")) or "",
        CurlUtil.shellQuote(exit_file)
    )
    command = string.format("%s >/dev/null 2>&1", command) -- do not print errors to terminal

    return command
end

function CurlUtil.echoPid(cmd)
    return string.format("%s & echo $!", cmd)
end

-- Returns the command that has curl download download_url to filepath, and the file its exit code is saved in, or nil
-- when the options can't be given to curl. KOReader's HTTP proxy is used where it's on.
-- max_time limits each attempt, and retrying, in seconds. opts.headers_file has curl write the response headers there.
-- opts.stall_time gives up after that many seconds with nothing arriving.
-- opts.resume carries on from what's in filepath, where the site allows it. opts.if_range does so only if the file is
-- still the one that validator is for (see getValidator), and otherwise fails with exit code 33, as when the site can't
-- resume.
-- opts.sensitive says the link is itself a secret, such as Anna's Archive's signed download link. It goes to curl in a
-- config file, not on the command line, where any program on the device can read it. It isn't sent as the Referer, and
-- is only followed to HTTPS.
local function downloadCommand(download_url, filepath, max_time, opts)
    opts = opts or {}

    local options = {}
    if opts.sensitive then
        table.insert(options, { "url", download_url })
    end
    if opts.if_range then
        table.insert(options, { "header", "If-Range: " .. opts.if_range })
    end
    local config_file
    if #options > 0 then
        config_file = CurlUtil.createConfigFile(options)
        if not config_file then
            LogUtil.warn("could not give curl the download's options in a file")
            return nil
        end
    end

    local cmd = CurlUtil.getDownloadCMD(not opts.sensitive and download_url or nil, filepath)
    if opts.sensitive then
        cmd = cmd .. " --proto =https --proto-redir =https"
    end
    if opts.resume then
        cmd = cmd .. " -C -"
    end
    cmd = CurlUtil.pretendBrowser(cmd)
    if not opts.sensitive then
        cmd = CurlUtil.setReferer(cmd, download_url)
    end
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, 15)
    if max_time then
        cmd = string.format("%s --max-time %d --retry-max-time %d", cmd, max_time, max_time)
    end
    if opts.headers_file then
        cmd = CurlUtil.dumpHeaders(cmd, opts.headers_file)
    end
    if opts.stall_time then
        cmd = CurlUtil.abortWhenStalled(cmd, opts.stall_time)
    end
    cmd = CurlUtil.applyEncryptedDns(cmd)
    if config_file then
        cmd = string.format("%s -K %s", cmd, CurlUtil.shellQuote(config_file))
    end
    local proxy_config
    cmd, proxy_config = CurlUtil.applyProxy(cmd)

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file, { config_file, proxy_config })

    -- Without the link, which can carry a temporary key.
    LogUtil.debug("curl downloading from", LogUtil.site(download_url), "to", filepath)
    return cmd, exit_file, config_file
end

-- Downloads download_url to filepath in the background (see downloadCommand for the options). Returns the pid and exit
-- file, or nil and why not.
function CurlUtil.startDownload(download_url, filepath, max_time, opts)
    local cmd, exit_file, config_file = downloadCommand(download_url, filepath, max_time, opts)
    if not cmd then
        return nil, Errors.START_FAILED
    end
    local pid, err = CurlUtil.spawnCurlPid(CurlUtil.echoPid(cmd))
    if not pid then
        -- The shell would have removed it once curl had finished.
        FileUtil.removeFile(config_file)
        return nil, err
    end
    return pid, exit_file
end

-- Downloads download_url to filepath, blocking until it's done (see downloadCommand for the options). Returns true, or
-- nil and what went wrong, leaving nothing behind.
function CurlUtil.download(download_url, filepath, max_time, opts)
    local cmd, exit_file, config_file = downloadCommand(download_url, filepath, max_time, opts)
    if not cmd then
        return nil, Errors.START_FAILED
    end
    os.execute(cmd)

    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code then
        LogUtil.warn("could not start curl to download from", LogUtil.site(download_url))
        FileUtil.removeFile(exit_file)
        FileUtil.removeFile(config_file)
        FileUtil.removeFile(filepath)
        return nil, Errors.START_FAILED
    end
    if exit_code == 0 then
        local file_size = FileUtil.getSize(filepath)
        if file_size and file_size > 0 then
            LogUtil.debug("download completed successfully", {
                filepath = filepath,
                file_size = file_size,
            })
            return true
        else
            LogUtil.warn("download from", LogUtil.site(download_url), "to", filepath, "produced an empty file")
            FileUtil.removeFile(filepath)
            return nil, _("download produced empty file")
        end
    else
        LogUtil.warn(
            "download from",
            LogUtil.site(download_url),
            "to",
            filepath,
            "failed: curl exit code",
            exit_code,
            "(" .. CurlUtil.getErrorMeaning(exit_code) .. ")"
        )
        FileUtil.removeFile(filepath)
        return nil, CurlUtil.getErrorMeaning(exit_code)
    end
end

-- opts.stall_time optionally gives up on a file once nothing has arrived for that many seconds.
function CurlUtil.downloadMultiple(download_urls, filepaths, background, num_parallel_jobs, enable_retry, timeout, opts)
    opts = opts or {}
    ensureTmpDir()

    -- Backslashes and quotes are special inside the quotes of curl's config file.
    local function quote(value)
        return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    local lines = {}
    -- KOReader's HTTP proxy goes in the file too, not on curl's command line (see applyProxy).
    local proxy = ProxyUtil.get()
    if proxy and not proxy:find("%c") then
        table.insert(lines, string.format('proxy = "%s"\n', quote(proxy)))
    end
    for i, download_url in ipairs(download_urls) do
        -- A URL with a line break in it would add lines of its own to the config file, so it's left out.
        if StringUtil.isSafeUrl(download_url) and not filepaths[i]:find("%c") then
            table.insert(lines, string.format('url = "%s"\n', quote(download_url)))
            table.insert(lines, string.format('output = "%s"\n', quote(filepaths[i])))
        else
            LogUtil.warn("left out a download whose address can't be used:", download_url)
        end
    end

    -- Writing it fails when the device's storage is full, or read-only.
    local config_file = tmpFile("curl_download_config", ".txt")
    local f, open_err = io.open(config_file, "w")
    local written, write_err = false, open_err
    if f then
        written, write_err = f:write(table.concat(lines))
        local closed, close_err = f:close()
        written, write_err = written and closed, write_err or close_err
    end
    if not written then
        LogUtil.warn("could not write curl's list of files to download to", config_file .. ":", write_err)
        FileUtil.removeFile(config_file)
        if background then
            return nil, nil, nil, _("could not write the list of files for curl")
        end
        return 0
    end

    local results_file = CurlUtil.getResultsFile(config_file)
    local cmd = string.format('curl -sL -f --config "%s"', config_file)
    cmd = CurlUtil.pretendBrowser(cmd)
    -- Covers for a page of search results all come from the same site.
    cmd = CurlUtil.setReferer(cmd, download_urls[1])
    if enable_retry then
        cmd = CurlUtil.enableRetry(cmd, 2, 2)
    end
    cmd = CurlUtil.setTimeout(cmd, timeout)
    -- Gives up on files that take too long, so they don't hold up the rest.
    cmd = string.format("%s --max-time %d", cmd, timeout * 2)
    if opts.stall_time then
        cmd = CurlUtil.abortWhenStalled(cmd, opts.stall_time)
    end
    cmd = CurlUtil.enableParallel(cmd, num_parallel_jobs)
    cmd = CurlUtil.applyEncryptedDns(cmd)
    -- Writes each file's result, as some may download when others fail. To stderr where curl can: it isn't buffered, so
    -- each result is there as soon as its file is done.
    local write_out = "%{exitcode} %{filename_effective}\\n"
    if curlIsAtLeast("7.63.0") then
        cmd = string.format(
            "%s -w %s 2> %s",
            cmd,
            CurlUtil.shellQuote("%{stderr}" .. write_out),
            CurlUtil.shellQuote(results_file)
        )
    else
        cmd = string.format("%s -w %s > %s", cmd, CurlUtil.shellQuote(write_out), CurlUtil.shellQuote(results_file))
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl parallel download command", cmd)

    if background then
        cmd = CurlUtil.echoPid(cmd)

        local pid, err = CurlUtil.spawnCurlPid(cmd)
        if not pid then
            FileUtil.removeFile(config_file)
            FileUtil.removeFile(exit_file)
            return nil, nil, nil, err
        end

        LogUtil.debug("spawned parallel download", {
            pid = pid,
            exit_file = exit_file,
            config_file = config_file,
            file_count = #download_urls,
        })
        return pid, exit_file, config_file
    end

    os.execute(cmd)

    local exit_code = CurlUtil.getExitCode(exit_file)
    if exit_code ~= 0 then
        local reason = CurlUtil.getErrorMeaning(exit_code)
        LogUtil.warn("parallel download command failed", {
            exit_code = exit_code,
            reason = reason,
        })
    end

    local results = CurlUtil.getTransferResults(results_file)
    local successful_count = 0
    for __, filepath in ipairs(filepaths) do
        if CurlUtil.isTransferComplete(results, filepath, exit_code) then
            successful_count = successful_count + 1
            LogUtil.debug("file downloaded successfully", filepath)
        else
            LogUtil.warn("file download failed", filepath)
            FileUtil.removeFile(filepath)
        end
    end

    FileUtil.removeFile(config_file)
    FileUtil.removeFile(results_file)

    LogUtil.debug("parallel download completed", {
        total_requested = #download_urls,
        successful = successful_count,
    })

    return successful_count
end

return CurlUtil
