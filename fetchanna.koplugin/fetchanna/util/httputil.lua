local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local Trapper = require("ui/trapper")
local CurlUtil = require("fetchanna.util.curlutil")
local FileUtil = require("fetchanna.util.fileutil")
local LogUtil = require("fetchanna.util.logutil")
local ProxyUtil = require("fetchanna.util.proxyutil")
local Errors = require("fetchanna.util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

local HttpUtil = {}

-- The error when a request was called off by a tap on the trap widget (see setTrapWidget).
HttpUtil.CANCELLED = Errors.CANCELLED
-- The error when a site's name couldn't be looked up, as when the network blocks the site, in curl's words (see
-- explainFailure).
HttpUtil.UNRESOLVED = CurlUtil.getErrorMeaning(6)

-- Seconds a site has to answer, and to send the whole page. Search results are large and Library Genesis sends them
-- slowly.
local ANSWER_TIMEOUT = 10
local PAGE_TIMEOUT = 60
-- Seconds a file has to download. A file can be several megabytes, and an e-reader's Wi-Fi slow.
local FILE_TIMEOUT = 300
-- With curl, seconds a download can stall before it's given up on.
local FILE_STALL_TIME = 30

-- Returns a KOReader HTTP failure in curl's words, logging the original.
local function explainFailure(err)
    err = tostring(err or _("no response"))
    local exit_code = CurlUtil.exitCodeFor(err)
    local explained = exit_code and CurlUtil.getErrorMeaning(exit_code) or err
    if explained ~= err then
        LogUtil.info("KOReader's HTTP said:", err)
    end
    return explained
end

-- Calls luasocket's http.request, which can raise an error, e.g. from the TLS library. KOReader would exit on that,
-- without its timeouts being put back.
local function request(options)
    local requested, ok, status, headers = pcall(http.request, options)
    if not requested then
        LogUtil.warn("KOReader's HTTP raised an error rather than returning it:", tostring(ok))
        return nil, ok
    end
    return ok, status, headers
end

-- Whether requests made inside Trapper:wrap can be called off (see setTrapWidget). curl's can.
function HttpUtil.canCancel()
    return CurlUtil.canFetch()
end

-- The widget that calls off pending requests when tapped, per coroutine (or MAIN outside one). Searches, downloads and
-- logins each wait in their own, so one's Cancel mustn't call off another's.
local trap_widgets = setmetatable({}, { __mode = "k" })
local MAIN = {}

-- Sets the widget that calls off requests made from now on in the calling coroutine, or nil once they're over.
function HttpUtil.setTrapWidget(widget)
    trap_widgets[coroutine.running() or MAIN] = widget
end

-- Returns the widget that calls off requests made in the calling coroutine.
function HttpUtil.getTrapWidget()
    return trap_widgets[coroutine.running() or MAIN]
end

-- Shows text as what's being waited for on that widget, where it shows such things (see DownloadProgress:setStatus).
-- nil puts back what it said before.
function HttpUtil.sayStatus(text)
    local widget = HttpUtil.getTrapWidget()
    if widget and widget.setStatus then
        widget:setStatus(text)
    end
end

-- Encodes a form, a list of each field's name and value, as it's sent.
local function formBody(form)
    local fields = {}
    for __, field in ipairs(form) do
        table.insert(fields, util.urlEncode(field[1]) .. "=" .. util.urlEncode(tostring(field[2])))
    end
    return table.concat(fields, "&")
end

-- Fetches a page with curl, which asks for it compressed and doesn't block KOReader inside Trapper:wrap. The form and
-- cookies go to curl in a file, not on its command line, where any program on the device can read them. So does the URL
-- when it has a secret in it (opts.sensitive).
local function requestBodyWithCurl(request_url, opts)
    local config_file
    local options = {}
    if opts.form or opts.cookies then
        -- The empty cookie option has curl keep cookies: a site's browser check can answer with a cookie and a redirect
        -- back. curl only keeps them when given none to send, so ours go in a header, which it only sends to the same
        -- site.
        table.insert(options, { "cookie", "" })
        if opts.cookies and opts.cookies ~= "" then
            table.insert(options, { "header", "Cookie: " .. opts.cookies })
        end
        if opts.form then
            table.insert(options, { "data", formBody(opts.form) })
        end
    end
    if opts.sensitive then
        table.insert(options, { "url", request_url })
    end
    if #options > 0 then
        config_file = CurlUtil.createConfigFile(options)
        if not config_file then
            return nil, _("could not write the request for curl")
        end
    end

    local page_file = CurlUtil.createPageFile()
    -- Headers are written when asked for, and always when a redirect isn't followed, as they say where it goes.
    local follow = opts.follow_redirects ~= false
    local headers_file = (opts.headers or not follow) and CurlUtil.createHeadersFile() or nil
    local cmd = CurlUtil.fetchCommand(
        not opts.sensitive and request_url or nil,
        page_file,
        ANSWER_TIMEOUT,
        PAGE_TIMEOUT,
        config_file,
        {
            follow_redirects = follow,
            headers_file = headers_file,
        }
    )

    local completed, output
    local trap_widget = HttpUtil.getTrapWidget()
    if Trapper:isWrapped() then
        completed, output = Trapper:dismissablePopen(cmd, trap_widget)
    else
        local pipe = io.popen(cmd, "r")
        if pipe then
            completed, output = true, pipe:read("*a")
            pipe:close()
        end
    end
    if not completed then
        -- Called off by a tap on the widget's Cancel, which marks it cancelled, or with no widget, a tap anywhere. curl
        -- carries on until it finishes or times out, and its files are removed at the next start-up.
        if Trapper:isWrapped() and (not trap_widget or trap_widget.cancelled) then
            return nil, HttpUtil.CANCELLED
        end
        -- Otherwise the shell that runs curl couldn't be started, which is an error to report.
        LogUtil.warn("could not start curl to fetch", LogUtil.site(request_url))
        FileUtil.removeFile(page_file)
        FileUtil.removeFile(config_file)
        FileUtil.removeFile(headers_file)
        return nil, Errors.START_FAILED
    end

    local body = FileUtil.readFile(page_file)
    FileUtil.removeFile(page_file)
    local headers
    if headers_file then
        headers = CurlUtil.parseHeaders(FileUtil.readFile(headers_file))
        FileUtil.removeFile(headers_file)
    end

    -- The HTTP status and curl's exit code, e.g. "200 0", or only " 127" when curl couldn't be run.
    local status, exit_code = (output or ""):match("(%d*) (%d+)%s*$")
    status, exit_code = tonumber(status), tonumber(exit_code)
    if not exit_code then
        return nil, _("no response")
    end
    -- The site didn't answer, or stopped partway through the page.
    if exit_code ~= 0 or not status or status == 0 then
        return nil, CurlUtil.getErrorMeaning(exit_code)
    end
    if not body or body == "" then
        -- A redirect that isn't followed is an answer in itself, and needn't have a body.
        if not follow and status >= 300 and status < 400 then
            return "", nil, status, headers
        end
        return nil, T(_("empty response (HTTP %1)"), tostring(status)), status, headers
    end

    return body, nil, status, headers
end

-- Returns the first cookie a response sets, e.g. "name=value" from "name=value; Path=/; Secure".
local function setCookie(headers)
    local set_cookie = type(headers) == "table" and headers["set-cookie"]
    return type(set_cookie) == "string" and set_cookie:match("^%s*([^;,%s]+=[^;,]*)") or nil
end

-- Fetches a page with KOReader's own HTTP, which blocks KOReader, through its HTTP proxy where it's on.
local function requestBodyWithKOReader(request_url, opts)
    -- Set through KOReader, as HTTPS requests ignore luasocket's own timeout and wait a minute.
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local form_body = opts.form and formBody(opts.form)
    local cookies = opts.cookies
    local url = request_url
    local follow = opts.follow_redirects ~= false
    local response_body, ok, status, headers
    -- Twice, for a site that answers with a cookie and a redirect back, as a browser check can. luasocket can't follow
    -- that itself, as it keeps no cookies.
    for __ = 1, 2 do
        response_body = {}
        local request_headers = {
            ["User-Agent"] = "Mozilla/5.0",
        }
        if form_body then
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
            request_headers["Content-Length"] = tostring(#form_body)
        end
        if cookies and cookies ~= "" then
            request_headers["Cookie"] = cookies
        end
        ok, status, headers = request {
            url = url,
            method = form_body and "POST" or "GET",
            source = form_body and ltn12.source.string(form_body),
            proxy = ProxyUtil.get(),
            sink = socketutil.table_sink(response_body),
            headers = request_headers,
            redirect = follow and not (opts.form or opts.cookies),
        }

        local cookie = follow
            and ok
            and type(status) == "number"
            and status >= 300
            and status < 400
            and setCookie(headers)
        local location = type(headers) == "table" and headers.location
        if not (cookie and type(location) == "string" and location:find("^https?://")) then
            break
        end
        cookies = (cookies and cookies ~= "" and cookies .. "; " or "") .. cookie
        url = location
    end
    socketutil:reset_timeout()

    -- status is the HTTP status code, or what went wrong if there was no response.
    local body = table.concat(response_body)
    if not ok then
        return nil, explainFailure(status)
    end
    -- luasocket's are already named in lower case.
    headers = type(headers) == "table" and headers or {}
    if body == "" then
        -- As with curl, a redirect that isn't followed is an answer in itself.
        if not follow and type(status) == "number" and status >= 300 and status < 400 then
            return "", nil, status, headers
        end
        return nil, T(_("empty response (HTTP %1)"), tostring(status)), status, headers
    end

    return body, nil, status, headers
end

-- How many pages in a row curl must fail to connect to securely, where KOReader's own HTTP could, before KOReader's is
-- used for the rest of the session. More than one, as a site's certificate can have expired, which KOReader's HTTP may
-- not check.
local TLS_FALLBACKS = 3
local tls_fallbacks = 0

-- Fetches a page with curl, or with KOReader's own HTTP where curl can't, through KOReader's HTTP proxy where it's on.
function HttpUtil.requestBody(request_url, opts)
    opts = opts or {}
    if not CurlUtil.canFetch() then
        return requestBodyWithKOReader(request_url, opts)
    end

    local body, err, status, headers = requestBodyWithCurl(request_url, opts)
    if body or not CurlUtil.isTlsFailure(err) then
        if body then
            tls_fallbacks = 0
        end
        return body, err, status, headers
    end
    -- A curl built without TLS, or too old for the site's, can't connect securely. KOReader's own HTTP tries instead.
    LogUtil.warn(
        "curl couldn't connect to",
        LogUtil.site(request_url),
        "securely:",
        err .. ", so trying KOReader's own HTTP"
    )
    local fetched, fetch_err, fetch_status, fetch_headers = requestBodyWithKOReader(request_url, opts)
    if not fetched then
        return nil, err, status
    end
    tls_fallbacks = tls_fallbacks + 1
    if tls_fallbacks >= TLS_FALLBACKS then
        CurlUtil.stopFetching(
            string.format("curl couldn't connect securely %d times in a row where it could", tls_fallbacks)
        )
    end
    return fetched, fetch_err, fetch_status, fetch_headers
end

-- Returns a page's body, HTTP status and headers, or nil and what went wrong, with the status and headers if the site
-- answered. Headers are a table by lower-case name, given where opts.headers asks or a redirect isn't followed.
-- opts.form is a form to post, as a list of names and values. opts.cookies is the cookies to send, e.g. "a=1; b=2".
-- Neither is logged, as they can be a password and a session.
-- opts.follow_redirects = false returns a redirect as it is, with an empty body when it has none, so the caller can
-- check where it goes first (see OriginPolicy.resolveRedirect).
-- opts.sensitive says the URL has a secret in it, as the member API takes the key in its query. curl gets it in a file,
-- not on its command line, and a redirect is never followed, so the secret only goes where it was meant to. Nothing
-- logged has the secret in it (see LogUtil.redact).
function HttpUtil.getBody(url, opts)
    if opts and opts.sensitive and opts.follow_redirects ~= false then
        local copy = {}
        for key, value in pairs(opts) do
            copy[key] = value
        end
        copy.follow_redirects = false
        opts = copy
    end
    if opts and opts.form then
        local names = {}
        for __, field in ipairs(opts.form) do
            table.insert(names, field[1])
        end
        LogUtil.debug("posting", table.concat(names, ", "), "to", url)
    else
        LogUtil.debug("fetching", url)
    end
    local body, err, status, headers = HttpUtil.requestBody(url, opts)
    if body then
        LogUtil.debug("fetched", #body, "bytes, HTTP", status, "from", url)
        return body, nil, status, headers
    end
    if err == HttpUtil.CANCELLED then
        LogUtil.info("stopped waiting for", LogUtil.site(url), "when asked to")
        return nil, err
    end
    LogUtil.warn("could not fetch", url, "error:", err)
    return nil, err, status, headers
end

-- Downloads a file with KOReader's own HTTP, leaving nothing behind if it fails.
local function downloadWithKOReader(url, path)
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, T(_("could not write the file: %1"), tostring(open_err))
    end

    socketutil:set_timeout(ANSWER_TIMEOUT, FILE_TIMEOUT)
    local ok, status = request {
        url = url,
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
        },
        sink = socketutil.file_sink(file),
        redirect = true,
    }
    socketutil:reset_timeout()
    -- KOReader's sink closes it once the whole file has arrived, but not when none of it did.
    if io.type(file) == "file" then
        file:close()
    end

    if ok and status == 200 then
        return true
    end
    FileUtil.removeFile(path)
    -- status is the HTTP status code, or what went wrong if there was no response.
    if not ok then
        return nil, explainFailure(status)
    end
    return nil, string.format("%s (%s)", CurlUtil.getErrorMeaning(22), tostring(status))
end

-- Downloads a file to path, with curl where it can fetch, otherwise KOReader's own HTTP: a Kindle's own curl is too old
-- to connect to many sites, such as GitHub. Blocks KOReader, so it's time-limited. Returns true, or nil and what went
-- wrong.
function HttpUtil.downloadFile(url, path)
    LogUtil.debug("downloading", url, "to", path)
    if not CurlUtil.canFetch() then
        return downloadWithKOReader(url, path)
    end
    local ok, err = CurlUtil.download(url, path, FILE_TIMEOUT, { stall_time = FILE_STALL_TIME })
    if not ok then
        return nil, err
    end
    return true
end

return HttpUtil
