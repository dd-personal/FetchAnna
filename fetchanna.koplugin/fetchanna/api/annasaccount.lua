local JSON = require("json")
local HttpUtil = require("fetchanna.util.httputil")
local LogUtil = require("fetchanna.util.logutil")
local TimeUtil = require("fetchanna.util.timeutil")
local OriginPolicy = require("fetchanna.util.originpolicy")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local KeyStore = require("fetchanna.api.keystore")
local _ = require("gettext")

-- The Anna's Archive account, by its key (kept in KeyStore). The key goes in two places (see docs/annas-protocol.md):
-- the account page's login form, which answers with a session for searching, and the member API's URL, for download
-- links.
-- It's only sent to sites trusted with it (see AnnasMirrors), over https, without following redirects, and never on
-- curl's command line or in the log (see HttpUtil.getBody's opts.sensitive). Checking the key never uses up a download.
local AnnasAccount = {}

-- What's known of the account.
AnnasAccount.STATUS = {
    -- No key entered.
    NO_KEY = "no_key",
    -- A key that hasn't been checked.
    UNVERIFIED = "unverified",
    -- A key Anna's Archive couldn't be asked about (see failure).
    UNREACHABLE = "unreachable",
    -- The key is accepted, but nothing is logged in with it.
    VALID = "valid",
    -- Logged in on at least one site, with a session that hasn't expired.
    LOGGED_IN = "logged_in",
    -- The key isn't accepted: it was mistyped, or the account is gone.
    INVALID = "invalid",
}
local STATUS = AnnasAccount.STATUS

-- What each membership tier allows, per Anna's Archive's code (see docs/annas-protocol.md): fast downloads a day, and
-- searches an hour without a browser check.
AnnasAccount.TIERS = {
    [1] = { downloads = 0, searches = 0 },
    [2] = { downloads = 25, searches = 36 },
    [3] = { downloads = 50, searches = 180 },
    [4] = { downloads = 200, searches = 180 },
    [5] = { downloads = 1000, searches = 180 },
}

-- The cookie Anna's Archive keeps a session in.
local SESSION_COOKIE = "aa_account_id2"
-- How long a session is kept when it doesn't say: as long as Anna's Archive's.
local SESSION_LIFETIME = 90 * 24 * 60 * 60

local FAILURE = AnnasMirrors.FAILURE

function AnnasAccount:hasKey()
    return KeyStore.getKey() ~= nil
end

-- Uses key from now on (see KeyStore.setKey), if it looks like a key. Returns true, or nil and why not.
function AnnasAccount:setKey(key)
    key = type(key) == "string" and key:gsub("^%s+", ""):gsub("%s+$", "") or key
    if not KeyStore.isValidKey(key) then
        return nil, _("That isn't a secret key: it's letters and digits, at least 20 of them.")
    end
    KeyStore.setKey(key)
    return true
end

-- Forgets the key and its sessions (see KeyStore.forget). Anna's Archive can't end a session on its side, as it only
-- checks its own signature on it, so forgetting it on the device is what logs out.
function AnnasAccount:forget()
    return KeyStore.forget()
end

-- Returns what's known of the account: status, tier and what it allows (see TIERS), downloads_left and
-- downloads_per_day as the member API last said, when it was verified, logged into or turned down, the last failure,
-- the sessions, and last_link ({ at, site, server }).
function AnnasAccount:status()
    local info = KeyStore.getInfo()
    local result = {
        tier = info.tier,
        allows = info.tier and AnnasAccount.TIERS[info.tier],
        downloads_left = info.downloads_left,
        downloads_per_day = info.downloads_per_day,
        downloads_checked_at = info.downloads_checked_at,
        last_link = info.last_link_at
            and { at = info.last_link_at, site = info.last_link_site, server = info.last_link_server },
        verified_at = info.verified_at,
        logged_in_at = info.logged_in_at,
        tier_checked_at = info.tier_checked_at,
        invalid_at = info.invalid_at,
        failure = info.failure,
        failure_at = info.failure_at,
        sessions = {},
    }
    if not self:hasKey() then
        result.status = STATUS.NO_KEY
        return result
    end
    for __, session in ipairs(KeyStore.sessions()) do
        if KeyStore.getSession(session.origin) then
            table.insert(result.sessions, session)
        end
    end
    if info.invalid_at then
        result.status = STATUS.INVALID
    elseif #result.sessions > 0 then
        result.status = STATUS.LOGGED_IN
    elseif info.verified_at then
        result.status = STATUS.VALID
    elseif info.failure_at then
        result.status = STATUS.UNREACHABLE
    else
        result.status = STATUS.UNVERIFIED
    end
    return result
end

-- Returns origin's session as a cookie to send, or nil. Only for a site trusted with the key (see
-- AnnasMirrors:isTrusted), and only that site's own.
function AnnasAccount:sessionCookie(origin)
    if not AnnasMirrors:isTrusted(origin) then
        return nil
    end
    local session = KeyStore.getSession(origin)
    return session and SESSION_COOKIE .. "=" .. session or nil
end

-- Returns the session in a response's Set-Cookie headers (joined by ", ", as HttpUtil has them) and when it expires, or
-- nil when there's none or it's cleared.
function AnnasAccount.sessionFrom(set_cookie, now)
    if type(set_cookie) ~= "string" then
        return nil
    end
    local start, finish, value = set_cookie:find("%f[%w_]" .. SESSION_COOKIE .. "=([^;,%s]*)")
    if not start or (start > 1 and not set_cookie:sub(1, start - 1):find("[,;]%s*$")) then
        return nil
    end
    -- Its attributes, up to the next cookie. An Expires date has ", " in it, but not followed by name=.
    local rest = set_cookie:sub(finish + 1)
    local attributes = rest:match("^(.-), [%w_%-]+=") or rest
    if not KeyStore.isValidSession(value) then
        return nil
    end
    local max_age = tonumber(attributes:match(";%s*[Mm]ax%-[Aa]ge=(%-?%d+)"))
    local expires = TimeUtil.parseHttpDate(attributes:match(";%s*[Ee]xpires=([^;]+)"))
    if max_age then
        expires = now + max_age
    end
    expires = expires or now + SESSION_LIFETIME
    if expires <= now then
        return nil
    end
    return value, expires
end

-- Whether a page is the account page as shown when not logged in, with its key form.
function AnnasAccount.isLoginPage(body)
    return type(body) == "string"
        and body:find('action="/account/"', 1, true) ~= nil
        and body:find('name="key"', 1, true) ~= nil
end

-- Reads the account page: { logged_in, tier, memberships }. tier is the highest current membership (not struck
-- through), 0 when the page says there's none, or nil when it can't be told.
function AnnasAccount.parseAccountPage(body)
    if type(body) ~= "string" or not body:find("/dyn/account/logout/", 1, true) then
        return { logged_in = false }
    end
    local tier, rows = nil, 0
    for class, row in body:gmatch('<div class="([^"]*)">(.-)</div>') do
        local row_tier = tonumber(row:match('href="/donate%?tier=(%d+)"'))
        if row_tier then
            rows = rows + 1
            if not class:find("line-through", 1, true) and (not tier or row_tier > tier) then
                tier = row_tier
            end
        end
    end
    -- No current membership: the page asks to become a member. A member's page asks to upgrade the same way, so not
    -- when the page shows fast downloads used (marked by a comment that's only there then): then the tier can't be
    -- told.
    local shows_fast_downloads = body:find('Replace "24" in the actual counts', 1, true) ~= nil
    if not tier and rows == 0 and not shows_fast_downloads and body:find(' href="/donate"', 1, true) then
        tier = 0
    end
    return { logged_in = true, tier = tier, memberships = rows }
end

-- What the member API's errors mean (see docs/annas-protocol.md).
local API_ERRORS = {
    ["Invalid secret key"] = FAILURE.INVALID_KEY,
    ["Not a member"] = FAILURE.NOT_MEMBER,
    ["No downloads left"] = FAILURE.QUOTA,
    ["Record not found"] = FAILURE.NOT_FOUND,
    ["Error during fetching"] = FAILURE.SERVER,
    -- A download server it doesn't have (see fastDownload).
    ["Invalid domain_index or path_index"] = FAILURE.UNAVAILABLE,
    ["Invalid md5"] = FAILURE.NOT_FOUND,
}

-- Returns the member API's answer decoded, or nil when it isn't one.
function AnnasAccount.readApiAnswer(body)
    local ok, data = false, nil
    if type(body) == "string" then
        ok, data = pcall(JSON.decode, body)
    end
    if ok and type(data) == "table" and type(data["///download_url"]) == "table" then
        return data
    end
    return nil
end

-- Returns an md5 (32 hex digits) no file has: the time, then 96 random bits.
function AnnasAccount.unusedMd5()
    local parts = { string.format("%08x", os.time() % 4294967296) }
    for i = 2, 4 do
        parts[i] = string.format("%04x%04x", math.random(0, 65535), math.random(0, 65535))
    end
    return table.concat(parts)
end

local function noteFailure(outcome)
    if outcome.failure == FAILURE.INVALID_KEY then
        LogUtil.warn("Anna's Archive doesn't accept the key")
        KeyStore.setInfo({ invalid_at = os.time(), verified_at = false, failure = false, failure_at = false })
        KeyStore.dropSession()
    elseif outcome.failure ~= FAILURE.CANCELLED then
        KeyStore.setInfo({ failure = outcome.failure, failure_at = os.time() })
    end
end

-- Checks that Anna's Archive accepts the key, without using a download. The member API is asked for a file no one has:
-- it says it can't find it once it accepts the key, and that the key is wrong otherwise (see docs/annas-protocol.md).
-- That doesn't say whether the account is a member.
-- Returns true, or nil and an outcome (see AnnasMirrors:run).
function AnnasAccount:verify()
    local key = KeyStore.getKey()
    if not key then
        return nil, { failure = FAILURE.INVALID_KEY, stopped = true, tried = {} }
    end
    local md5 = AnnasAccount.unusedMd5()
    local ok, outcome = AnnasMirrors:run(AnnasMirrors.API, function(origin)
        local url = string.format("%s/dyn/api/fast_download.json?md5=%s&key=%s", origin, md5, key)
        local body, err, status, headers = HttpUtil.getBody(url, { sensitive = true })
        local data = AnnasAccount.readApiAnswer(body)
        if data then
            local failure = API_ERRORS[data.error]
            if failure == FAILURE.NOT_FOUND then
                return true
            end
            return nil, failure or FAILURE.UNEXPECTED, { detail = tostring(data.error) }
        end
        return nil, AnnasMirrors.classify(body, err, status, headers)
    end)
    if ok then
        LogUtil.info("Anna's Archive accepts the key")
        KeyStore.setInfo({ verified_at = os.time(), invalid_at = false, failure = false, failure_at = false })
        return true
    end
    noteFailure(outcome)
    return nil, outcome
end

-- Reads the account page on origin, logged in (see parseAccountPage), and saves the tier it shows. Returns the page, or
-- nil when it can't be read.
function AnnasAccount:readMembership(origin)
    local cookie = self:sessionCookie(origin)
    if not cookie then
        return nil
    end
    local body = HttpUtil.getBody(origin .. "/account/", { cookies = cookie, sensitive = true })
    local page = AnnasAccount.parseAccountPage(body)
    if not page.logged_in then
        -- The session is no longer taken, or the page has changed.
        if AnnasAccount.isLoginPage(body) then
            LogUtil.warn("Anna's Archive no longer takes the login session on", origin)
            KeyStore.dropSession(origin)
        end
        return nil
    end
    if page.tier then
        LogUtil.info("Anna's Archive's account page shows a membership of tier", page.tier)
        KeyStore.setInfo({ tier = page.tier, tier_checked_at = os.time() })
    else
        LogUtil.warn("Anna's Archive's account page doesn't say what membership the account has")
    end
    return page
end

-- Logs in on site with the key and keeps the session for that site alone. site must be trusted with the key (see
-- AnnasMirrors:isTrusted). Returns true, or nil, a FAILURE and details, as an AnnasMirrors:run attempt does.
function AnnasAccount:loginAt(site)
    local key = KeyStore.getKey()
    if not key then
        return nil, FAILURE.INVALID_KEY
    end
    if not AnnasMirrors:isTrusted(site) then
        return nil, FAILURE.NO_TRUSTED
    end
    local body, err, status, headers = HttpUtil.getBody(site .. "/account/", {
        form = { { "key", key } },
        sensitive = true,
    })
    local value, expires = AnnasAccount.sessionFrom(headers and headers["set-cookie"], os.time())
    if value then
        KeyStore.setSession(site, value, expires)
        LogUtil.info("logged into Anna's Archive on", site)
        local now = os.time()
        KeyStore.setInfo({
            logged_in_at = now,
            verified_at = now,
            invalid_at = false,
            failure = false,
            failure_at = false,
        })
        return true
    end
    if body and status == 200 and AnnasAccount.isLoginPage(body) then
        noteFailure({ failure = FAILURE.INVALID_KEY })
        return nil, FAILURE.INVALID_KEY
    end
    if body and status and status >= 200 and status < 300 then
        return nil, FAILURE.UNEXPECTED, { detail = "no login session" }
    end
    return nil, AnnasMirrors.classify(body, err, status, headers)
end

-- Forgets site's session, as when it's no longer taken.
function AnnasAccount:dropSession(site)
    KeyStore.dropSession(site)
end

-- Returns when site's session was made (by os.time), or nil.
function AnnasAccount:sessionMadeAt(site)
    for __, session in ipairs(KeyStore.sessions()) do
        if session.origin == site then
            return session.created_at
        end
    end
end

-- Logs in on the first trusted site that works (see loginAt), then reads the membership. Returns the site, or nil and
-- an outcome (see AnnasMirrors:run).
function AnnasAccount:login()
    if not KeyStore.getKey() then
        return nil, { failure = FAILURE.INVALID_KEY, stopped = true, tried = {} }
    end
    local origin, outcome = AnnasMirrors:run(AnnasMirrors.ACCOUNT, function(site)
        local ok, failure, info = self:loginAt(site)
        if ok then
            return site
        end
        return nil, failure, info
    end)
    if not origin then
        noteFailure(outcome)
        return nil, outcome
    end
    self:readMembership(origin)
    return origin
end

-- Logs in (see login). Where no site allows that, checks the key instead (see verify), as the member API may still
-- work. Returns true when the key was accepted either way, or nil and an outcome.
function AnnasAccount:connect()
    local origin, outcome = self:login()
    if origin then
        return true
    end
    if outcome.stopped then
        return nil, outcome
    end
    local verified, verify_outcome = self:verify()
    if verified then
        -- Kept, to say what stopped the login.
        KeyStore.setInfo({ failure = outcome.failure, failure_at = os.time() })
        return true, outcome
    end
    return nil, verify_outcome
end

-- Saves what the member API said of the account's downloads.
function AnnasAccount:noteFastDownloadInfo(info)
    if type(info) ~= "table" then
        return
    end
    KeyStore.setInfo({
        downloads_left = tonumber(info.downloads_left) or false,
        downloads_per_day = tonumber(info.downloads_per_day) or false,
        downloads_checked_at = os.time(),
    })
end

-- Whether text is an md5 as the member API takes it: 32 hex digits, lower case.
function AnnasAccount.isMd5(text)
    return type(text) == "string" and #text == 32 and text:find("^[0-9a-f]+$") ~= nil
end

-- Whether the member API's download link can be followed: an https URL on the internet (see OriginPolicy). It may be on
-- another site, as the download servers are, and is only sent what's in it (see SECRET_LINKS in Sources). Returns true,
-- or nil and why not.
function AnnasAccount.checkDownloadUrl(url)
    local parts, why = OriginPolicy.parse(url)
    if not parts or not url:lower():find("^https://") then
        return nil, why or OriginPolicy.NOT_HTTPS
    end
    return OriginPolicy.checkHost(parts.host)
end

-- Asks the member API for a link to download md5 (see isMd5), trying each trusted site in turn (see AnnasMirrors:run).
-- domain_index picks the download server, or nil lets Anna's Archive choose.
-- Uses up one fast download, unless the file was downloaded recently: then it's free (see docs/annas-protocol.md), so
-- an expired link can be asked for again.
-- Returns { download_url, account_fast_download_info }, or nil and an outcome. outcome.may_have_counted is set when a
-- site timed out after it was asked, since it may still have counted the download.
function AnnasAccount:fastDownload(md5, domain_index)
    local key = KeyStore.getKey()
    if not key then
        return nil, { failure = FAILURE.INVALID_KEY, stopped = true, tried = {} }
    end
    if not AnnasAccount.isMd5(md5) then
        return nil, { failure = FAILURE.NOT_FOUND, stopped = true, tried = {} }
    end
    local timed_out, answered_on = false, nil
    local answer, outcome = AnnasMirrors:run(AnnasMirrors.API, function(origin)
        local url = string.format(
            "%s/dyn/api/fast_download.json?md5=%s&key=%s%s",
            origin,
            md5,
            key,
            domain_index and "&domain_index=" .. math.floor(domain_index) or ""
        )
        local body, err, status, headers = HttpUtil.getBody(url, { sensitive = true })
        local data = AnnasAccount.readApiAnswer(body)
        if data and data.error == nil and type(data.download_url) == "string" then
            -- Never logged, as it downloads the book by itself until it expires.
            LogUtil.addSecret(data.download_url)
            local ok, why = AnnasAccount.checkDownloadUrl(data.download_url)
            if not ok then
                LogUtil.warn("Anna's Archive's member API gave a download link that isn't followed:", why)
                return nil, FAILURE.UNEXPECTED, { detail = "its download link isn't https on the internet" }
            end
            answered_on = origin
            return data
        elseif data then
            return nil, API_ERRORS[data.error] or FAILURE.UNEXPECTED, { detail = tostring(data.error) }
        end
        local failure, info = AnnasMirrors.classify(body, err, status, headers)
        if failure == FAILURE.TIMEOUT then
            timed_out = true
        end
        return nil, failure, info
    end)

    if answer then
        local info = answer.account_fast_download_info
        self:noteFastDownloadInfo(info)
        KeyStore.setInfo({ verified_at = os.time(), invalid_at = false, failure = false, failure_at = false })
        -- Where it came from and goes to, to show the book came through the member API (see Diagnostics).
        KeyStore.setInfo({
            last_link_at = os.time(),
            last_link_site = OriginPolicy.hostOf(answered_on) or false,
            last_link_server = OriginPolicy.hostOf(answer.download_url) or false,
        })
        LogUtil.info(
            "Anna's Archive gave a download link to",
            LogUtil.site(answer.download_url),
            type(info) == "table"
                    and info.downloads_left
                    and string.format("(%s fast downloads left today)", tostring(info.downloads_left))
                or ""
        )
        return answer
    end
    outcome.may_have_counted = timed_out or nil
    -- Failures that are the account's, not this file's or the sites'.
    if outcome.failure == FAILURE.INVALID_KEY then
        noteFailure(outcome)
    elseif outcome.failure == FAILURE.NOT_MEMBER then
        KeyStore.setInfo({ failure = outcome.failure, failure_at = os.time() })
    elseif outcome.failure == FAILURE.QUOTA then
        KeyStore.setInfo({ downloads_left = 0, downloads_checked_at = os.time() })
    end
    return nil, outcome
end

return AnnasAccount
